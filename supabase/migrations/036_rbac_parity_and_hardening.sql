-- 036_rbac_parity_and_hardening.sql
--
-- Part A — Manager / Assistant Manager parity.
--   Assistant Managers (rank 60) get exactly the Manager (rank 70) operational
--   permissions. Every "auth_rank() >= 70" below becomes ">= 60". Partner-only
--   rules (rank 90 / auth_is_partner()) and company scope (auth_company_ok,
--   auth_all_companies = Partner) are unchanged. Senior Executive (50) and
--   below gain nothing.
--
-- Part B — security fixes from the RBAC audit (2026-10-31). Each closes a
--   path where the app's rule existed only in the browser. The rules
--   enforced are the ones the app already applies (CAN.* in index.html);
--   nothing the app does today is blocked.
--     B1 timesheet_entries — own rows only; status changes follow the app
--        (submit → pending; partner self-certify; approver approves/queries/
--        undoes; only approvers record decisions). Fixes self-approval.
--     B2 expense_claims    — draft → submitted (owner) → approved/rejected
--        (rank >= 60, not own) → paid (rank >= 60 not own, or legacy
--        "accounts"). Claim lines only on own DRAFT claims.
--     B3 budget_requests   — inserted as pending only; a decision can only
--        set status/decided_by/decided_at, once.
--     B4 clients           — add/edit rank >= 60; archive (is_active
--        true → false) and delete: Partner.
--     B5 jobs              — delete: Partner (the app never deletes jobs).
--     B6 attendance_punches — insert own (existing trigger); no update or
--        delete through the API.
--     B7 holidays (write: Partner), audit_logs (insert as yourself only,
--        never changed or deleted), review_notes (write own only).
--     B8 tasks             — split FOR ALL; below Assistant Manager only the
--        status of their own tasks (Senior Executive: any visible task, as
--        CAN.editTaskStatus); task cost: Partner.
--     B9 nil_timesheets (own), job_assignments and statutory_compliances
--        (write rank >= 60) — were FOR ALL for anyone who could see the row.
--     B11 leaves_insert    — "auth_rank() = 90" written as ">= 90".
--     B12 TRUNCATE revoked from anon/authenticated (not subject to RLS).
--
-- Guards apply to API users only (current_user authenticated/anon). Edge
-- Functions (service_role), SECURITY DEFINER functions and migrations are
-- not affected.
--
-- Re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/036_rbac_parity_and_hardening.sql

BEGIN;

-- ============================================================================
-- A. Parity: Manager-and-above bars (70) become Assistant-Manager-and-above (60)
-- ============================================================================

-- A1 budget requests: see decided requests of others, approve/reject (not own unless Partner)
DROP POLICY IF EXISTS budget_requests_select ON budget_requests;
CREATE POLICY budget_requests_select ON budget_requests FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(job_id)
         AND (status = 'pending' OR requested_by = auth_profile_id() OR auth_rank() >= 60));
DROP POLICY IF EXISTS budget_requests_update ON budget_requests;
CREATE POLICY budget_requests_update ON budget_requests FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60 AND auth_job_visible(job_id)
         AND (requested_by <> auth_profile_id() OR auth_rank() >= 90))
  WITH CHECK (organization_id = auth_org_id());

-- A2 expense claims: see colleagues' claims, approve/reject/pay (never own)
DROP POLICY IF EXISTS expense_claims_select ON expense_claims;
CREATE POLICY expense_claims_select ON expense_claims FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR (auth_rank() >= 60 AND auth_profile_visible(profile_id))
    OR (auth_role() = 'accounts' AND status IN ('approved', 'paid') AND auth_profile_visible(profile_id))));
DROP POLICY IF EXISTS expense_claims_update ON expense_claims;
CREATE POLICY expense_claims_update ON expense_claims FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR (auth_rank() >= 60 AND profile_id <> auth_profile_id() AND auth_profile_visible(profile_id))
    OR (auth_role() = 'accounts' AND auth_profile_visible(profile_id))))
  WITH CHECK (organization_id = auth_org_id());

-- A3 sites: add/edit, see inactive sites
DROP POLICY IF EXISTS locations_select ON locations;
CREATE POLICY locations_select ON locations FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id) AND (auth_rank() >= 60 OR is_active));
DROP POLICY IF EXISTS locations_insert ON locations;
CREATE POLICY locations_insert ON locations FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60 AND auth_company_ok(company_id));
DROP POLICY IF EXISTS locations_update ON locations;
CREATE POLICY locations_update ON locations FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60 AND auth_company_ok(company_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60 AND auth_company_ok(company_id));

-- A4 + B4 clients: add/edit rank >= 60 (company scope unchanged); delete Partner
DROP POLICY IF EXISTS clients_insert ON clients;
CREATE POLICY clients_insert ON clients FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60);
DROP POLICY IF EXISTS clients_update ON clients;
CREATE POLICY clients_update ON clients FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60);
DROP POLICY IF EXISTS clients_delete ON clients;
CREATE POLICY clients_delete ON clients FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 90);

-- A5 notification emails: an Assistant Manager supervisor receives budget
-- requests, and an Assistant Manager who opened the job is CC'd, as Managers are.
-- Bodies are the live definitions (027) with only the three 70s changed to 60.
CREATE OR REPLACE FUNCTION public.notif_budget_requests()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor UUID := auth_profile_id();
  v_job jobs%ROWTYPE;
  v_client TEXT;
  v_booked NUMERIC;
  v_data JSONB;
  v_to UUID[];
  v_cc UUID[];
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status <> 'pending' THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'UPDATE' AND NOT (OLD.status = 'pending' AND NEW.status IN ('approved', 'rejected')) THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT * INTO v_job FROM jobs WHERE organization_id = NEW.organization_id AND id = NEW.job_id;
    SELECT name INTO v_client FROM clients
      WHERE organization_id = NEW.organization_id AND id = v_job.client_id;
    SELECT COALESCE(sum(hours), 0) INTO v_booked FROM timesheet_entries
      WHERE organization_id = NEW.organization_id AND job_id = NEW.job_id;

    v_data := jsonb_build_object(
      'request_id', NEW.id,
      'job_id', NEW.job_id,
      'job_code', v_job.job_code,
      'job_title', v_job.title,
      'client_name', v_client,
      'employee_id', NEW.requested_by,
      'employee_name', notif_name(NEW.requested_by),
      'original_budget_hours', v_job.budget_hours,
      'from_hours', NEW.from_hours,
      'additional_hours', NEW.to_hours - NEW.from_hours,
      'to_hours', NEW.to_hours,
      'booked_hours', v_booked,
      'reason', NEW.reason,
      'requested_date', NEW.requested_date,
      'status', NEW.status
    );

    IF TG_OP = 'INSERT' THEN
      -- Same approver set as CAN.approveBudget (Assistant Manager, Manager,
      -- Partner — 036), with the job opener kept only when they belong to the
      -- requester's company.
      v_cc := CASE WHEN profile_rank(NEW.requested_by) < 90
                   THEN notif_company_partners(NEW.organization_id, NEW.requested_by)
                   ELSE '{}'::uuid[] END
              || ARRAY[CASE WHEN profile_rank(v_job.opened_by) >= 60
                            THEN notif_if_same_company(NEW.organization_id, NEW.requested_by, v_job.opened_by) END];
      v_to := notif_supervisor(NEW.organization_id, NEW.requested_by, 60);
      IF cardinality(v_to) = 0 THEN
        v_to := v_cc;
      END IF;

      PERFORM notif_enqueue(
        NEW.organization_id, NEW.requested_by, 'budget_requested', 'budget_requests', NEW.id,
        format('budget_requested:%s', NEW.id),
        v_to,
        v_cc,
        v_data,
        COALESCE(v_actor, NEW.requested_by)
      );
    ELSE
      PERFORM notif_enqueue(
        NEW.organization_id, NEW.requested_by,
        CASE WHEN NEW.status = 'approved' THEN 'budget_approved' ELSE 'budget_rejected' END,
        'budget_requests', NEW.id,
        format('budget_%s:%s', NEW.status, NEW.id),
        ARRAY[NEW.requested_by],
        '{}'::uuid[],
        v_data || jsonb_build_object(
          'decided_by_name', notif_name(COALESCE(NEW.decided_by, v_actor)),
          'decided_at', COALESCE(NEW.decided_at, now())
        ),
        COALESCE(v_actor, NEW.decided_by)
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'email notification (budget request) not queued for %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notif_task_assigned()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor UUID;
  v_job jobs%ROWTYPE;
  v_client TEXT;
  v_assignee profiles%ROWTYPE;
  v_prev UUID;
BEGIN
  IF NEW.assigned_to IS NULL OR NEW.status = 'completed' THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.assigned_to IS NOT DISTINCT FROM OLD.assigned_to THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_actor := COALESCE(auth_profile_id(), NEW.assigned_by);
    SELECT * INTO v_job FROM jobs WHERE organization_id = NEW.organization_id AND id = NEW.job_id;
    IF NOT FOUND OR v_job.status = 'closed' THEN
      RETURN NULL;
    END IF;
    SELECT name INTO v_client FROM clients
      WHERE organization_id = NEW.organization_id AND id = v_job.client_id;
    SELECT * INTO v_assignee FROM profiles
      WHERE organization_id = NEW.organization_id AND id = NEW.assigned_to;
    v_prev := CASE WHEN TG_OP = 'UPDATE' THEN OLD.assigned_to END;

    PERFORM notif_enqueue(
      NEW.organization_id, NEW.assigned_to, 'task_assigned', 'tasks', NEW.id,
      format('task_assigned:%s:%s:%s', NEW.id, NEW.assigned_to, txid_current()),
      ARRAY[NEW.assigned_to],
      ARRAY[
        v_actor,
        NEW.assigned_by,
        v_assignee.reports_to,
        CASE WHEN profile_rank(v_job.opened_by) >= 60
             THEN notif_if_same_company(NEW.organization_id, NEW.assigned_to, v_job.opened_by) END
      ],
      jsonb_build_object(
        'task_id', NEW.id,
        'task_title', NEW.title,
        'job_id', v_job.id,
        'job_code', v_job.job_code,
        'job_title', v_job.title,
        'client_name', v_client,
        'employee_id', NEW.assigned_to,
        'employee_name', v_assignee.full_name,
        'assigned_by_name', notif_name(v_actor),
        'due_date', NEW.due_date,
        'estimated_hours', NEW.estimated_hours,
        'job_budget_hours', v_job.budget_hours,
        'is_reassignment', v_prev IS NOT NULL,
        'previous_assignee_name', notif_name(v_prev)
      ),
      v_actor,
      p_cc_include_actor => true
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'email notification (task_assigned) not queued for task %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

-- ============================================================================
-- B. Security fixes
-- ============================================================================

-- B1 timesheet_entries ------------------------------------------------------
-- Who may decide someone's timesheet: same rule as CAN.approveSheet() —
-- their direct supervisor, or any Partner for a non-partner.
CREATE OR REPLACE FUNCTION timesheet_can_decide(p_owner UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth_profile_id() IS NOT NULL
     AND p_owner IS DISTINCT FROM auth_profile_id()
     AND EXISTS (
       SELECT 1 FROM profiles p
        WHERE p.id = p_owner AND p.organization_id = auth_org_id()
          AND (p.reports_to = auth_profile_id() OR (auth_rank() >= 90 AND profile_rank(p.id) < 90)));
$$;
REVOKE ALL ON FUNCTION timesheet_can_decide(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION timesheet_can_decide(uuid) TO authenticated;

DROP POLICY IF EXISTS timesheet_entries_access ON timesheet_entries;
DROP POLICY IF EXISTS timesheet_entries_select ON timesheet_entries;
DROP POLICY IF EXISTS timesheet_entries_insert ON timesheet_entries;
DROP POLICY IF EXISTS timesheet_entries_update ON timesheet_entries;
DROP POLICY IF EXISTS timesheet_entries_delete ON timesheet_entries;
-- Reading is unchanged from 028.
CREATE POLICY timesheet_entries_select ON timesheet_entries FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id() OR auth_profile_visible(profile_id)
    OR EXISTS (SELECT 1 FROM jobs j WHERE j.id = timesheet_entries.job_id AND auth_company_ok(j.company_id))));
CREATE POLICY timesheet_entries_insert ON timesheet_entries FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id());
CREATE POLICY timesheet_entries_update ON timesheet_entries FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND (profile_id = auth_profile_id() OR timesheet_can_decide(profile_id)))
  WITH CHECK (organization_id = auth_org_id() AND (profile_id = auth_profile_id() OR timesheet_can_decide(profile_id)));
CREATE POLICY timesheet_entries_delete ON timesheet_entries FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND profile_id = auth_profile_id() AND status = 'draft');

CREATE OR REPLACE FUNCTION guard_timesheet_entry()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_me UUID := auth_profile_id();
  v_content BOOLEAN;
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.decided_by IS NOT NULL OR NEW.decided_at IS NOT NULL
       OR NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'New time entries start as drafts.' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.profile_id IS DISTINCT FROM OLD.profile_id OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.approved_by IS DISTINCT FROM OLD.approved_by OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    RAISE EXCEPTION 'That change to a time entry is not allowed.' USING ERRCODE = '42501';
  END IF;
  -- Hours, job, date, narration … — everything except the decision columns.
  v_content := (to_jsonb(NEW) - 'status' - 'query_reason' - 'decided_by' - 'decided_at' - 'updated_at')
               IS DISTINCT FROM
               (to_jsonb(OLD) - 'status' - 'query_reason' - 'decided_by' - 'decided_at' - 'updated_at');

  IF OLD.profile_id = v_me THEN
    IF NEW.decided_by IS DISTINCT FROM OLD.decided_by OR NEW.decided_at IS DISTINCT FROM OLD.decided_at THEN
      RAISE EXCEPTION 'You cannot record a decision on your own timesheet.' USING ERRCODE = '42501';
    END IF;
    IF OLD.status NOT IN ('draft', 'queried') THEN
      RAISE EXCEPTION 'Submitted or approved time entries can no longer be changed.' USING ERRCODE = '42501';
    END IF;
    IF NEW.status = OLD.status THEN
      IF NEW.query_reason IS DISTINCT FROM OLD.query_reason THEN
        RAISE EXCEPTION 'Only your approver can query an entry.' USING ERRCODE = '42501';
      END IF;
      RETURN NEW;                                   -- editing a draft / queried entry
    END IF;
    IF NEW.status = 'pending' OR (NEW.status = 'approved' AND auth_is_partner()) THEN
      IF COALESCE(NEW.query_reason, '') <> '' THEN
        RAISE EXCEPTION 'Only your approver can query an entry.' USING ERRCODE = '42501';
      END IF;
      RETURN NEW;                                   -- submit / partner self-certifies
    END IF;
    RAISE EXCEPTION 'Only your approver can approve your timesheet.' USING ERRCODE = '42501';
  END IF;

  IF NOT timesheet_can_decide(OLD.profile_id) THEN
    RAISE EXCEPTION 'You cannot change someone else''s time entries.' USING ERRCODE = '42501';
  END IF;
  IF v_content THEN
    RAISE EXCEPTION 'An approver cannot change the hours, job or narration of an entry.' USING ERRCODE = '42501';
  END IF;
  IF OLD.status = 'pending' AND NEW.status = 'approved' AND NEW.decided_by = v_me THEN RETURN NEW; END IF;
  IF OLD.status = 'pending' AND NEW.status = 'queried' AND NEW.decided_by = v_me
     AND btrim(COALESCE(NEW.query_reason, '')) <> '' THEN RETURN NEW; END IF;
  IF OLD.status IN ('pending', 'approved', 'queried') AND NEW.status = 'pending' AND NEW.decided_by IS NULL THEN
    RETURN NEW;                                     -- undo a decision
  END IF;
  RAISE EXCEPTION 'That timesheet status change is not allowed.' USING ERRCODE = '42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_timesheet_entry ON timesheet_entries;
CREATE TRIGGER trg_guard_timesheet_entry BEFORE INSERT OR UPDATE ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION guard_timesheet_entry();

-- B2 expense_claims / expense_claim_lines -----------------------------------
CREATE OR REPLACE FUNCTION guard_expense_claim()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_me UUID := auth_profile_id();
  v_decision_same BOOLEAN;
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.submitted_at IS NOT NULL OR NEW.approved_by IS NOT NULL
       OR NEW.approved_at IS NOT NULL OR NEW.paid_by IS NOT NULL OR NEW.paid_at IS NOT NULL THEN
      RAISE EXCEPTION 'A new claim starts as a draft.' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.profile_id IS DISTINCT FROM OLD.profile_id OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.claim_month IS DISTINCT FROM OLD.claim_month THEN
    RAISE EXCEPTION 'That change to a claim is not allowed.' USING ERRCODE = '42501';
  END IF;
  v_decision_same := NEW.approved_by IS NOT DISTINCT FROM OLD.approved_by AND NEW.approved_at IS NOT DISTINCT FROM OLD.approved_at
                 AND NEW.paid_by IS NOT DISTINCT FROM OLD.paid_by AND NEW.paid_at IS NOT DISTINCT FROM OLD.paid_at;

  -- owner: edit a draft, submit it
  IF OLD.profile_id = v_me AND OLD.status = 'draft' AND NEW.status IN ('draft', 'submitted') AND v_decision_same THEN
    RETURN NEW;
  END IF;
  -- approver: Assistant Manager and above, never their own (CAN.approveClaim)
  IF OLD.status = 'submitted' AND NEW.status IN ('approved', 'rejected') AND OLD.profile_id <> v_me
     AND auth_rank() >= 60 AND NEW.approved_by = v_me
     AND NEW.paid_by IS NOT DISTINCT FROM OLD.paid_by AND NEW.paid_at IS NOT DISTINCT FROM OLD.paid_at
     AND NEW.submitted_at IS NOT DISTINCT FROM OLD.submitted_at THEN
    RETURN NEW;
  END IF;
  -- payer: Assistant Manager and above (not own), or a legacy "accounts" profile (CAN.payClaim)
  IF OLD.status = 'approved' AND NEW.status = 'paid' AND NEW.paid_by = v_me
     AND (auth_role() = 'accounts' OR (auth_rank() >= 60 AND OLD.profile_id <> v_me))
     AND NEW.approved_by IS NOT DISTINCT FROM OLD.approved_by AND NEW.approved_at IS NOT DISTINCT FROM OLD.approved_at
     AND NEW.submitted_at IS NOT DISTINCT FROM OLD.submitted_at THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'That claim status change is not allowed.' USING ERRCODE = '42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_expense_claim ON expense_claims;
CREATE TRIGGER trg_guard_expense_claim BEFORE INSERT OR UPDATE ON expense_claims
  FOR EACH ROW EXECUTE FUNCTION guard_expense_claim();

DROP POLICY IF EXISTS expense_claim_lines_insert ON expense_claim_lines;
CREATE POLICY expense_claim_lines_insert ON expense_claim_lines FOR INSERT TO authenticated
  WITH CHECK (claim_id IN (SELECT id FROM expense_claims
                            WHERE organization_id = auth_org_id() AND profile_id = auth_profile_id()
                              AND status = 'draft'));

-- B3 budget_requests ---------------------------------------------------------
DROP POLICY IF EXISTS budget_requests_insert ON budget_requests;
CREATE POLICY budget_requests_insert ON budget_requests FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND requested_by = auth_profile_id() AND auth_job_visible(job_id)
              AND status = 'pending' AND decided_by IS NULL AND decided_at IS NULL);

CREATE OR REPLACE FUNCTION guard_budget_request()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - 'status' - 'decided_by' - 'decided_at' - 'updated_at')
     IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'decided_by' - 'decided_at' - 'updated_at')
     OR OLD.status <> 'pending' OR NEW.status NOT IN ('approved', 'rejected')
     OR NEW.decided_by IS DISTINCT FROM auth_profile_id() THEN
    RAISE EXCEPTION 'A budget request can only be approved or rejected, once, by its approver.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_budget_request ON budget_requests;
CREATE TRIGGER trg_guard_budget_request BEFORE UPDATE ON budget_requests
  FOR EACH ROW EXECUTE FUNCTION guard_budget_request();

-- B4 clients: archiving is Partner-only (CAN.removeClient); restoring stays rank >= 60
CREATE OR REPLACE FUNCTION guard_client_archive()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  IF OLD.is_active AND NOT NEW.is_active AND auth_rank() < 90 THEN
    RAISE EXCEPTION 'Only a partner can archive a client.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_client_archive ON clients;
CREATE TRIGGER trg_guard_client_archive BEFORE UPDATE OF is_active ON clients
  FOR EACH ROW EXECUTE FUNCTION guard_client_archive();

-- B5 jobs: deleting a job code is Partner-only
DROP POLICY IF EXISTS jobs_delete ON jobs;
CREATE POLICY jobs_delete ON jobs FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 90);

-- B6 attendance_punches: read unchanged; insert own (trg_validate_attendance_site_punch);
--    no update/delete through the API.
DROP POLICY IF EXISTS attendance_punches_access ON attendance_punches;
DROP POLICY IF EXISTS attendance_punches_select ON attendance_punches;
DROP POLICY IF EXISTS attendance_punches_insert ON attendance_punches;
CREATE POLICY attendance_punches_select ON attendance_punches FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_profile_visible(profile_id));
CREATE POLICY attendance_punches_insert ON attendance_punches FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id());

-- B7 holidays / audit_logs / review_notes
DROP POLICY IF EXISTS authenticated_org_access ON holidays;
DROP POLICY IF EXISTS holidays_select ON holidays;
DROP POLICY IF EXISTS holidays_write ON holidays;
CREATE POLICY holidays_select ON holidays FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
CREATE POLICY holidays_write ON holidays FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 90)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 90);

DROP POLICY IF EXISTS authenticated_org_access ON audit_logs;
DROP POLICY IF EXISTS audit_logs_select ON audit_logs;
DROP POLICY IF EXISTS audit_logs_insert ON audit_logs;
CREATE POLICY audit_logs_select ON audit_logs FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
CREATE POLICY audit_logs_insert ON audit_logs FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND actor_profile_id = auth_profile_id());

DROP POLICY IF EXISTS authenticated_org_access ON review_notes;
DROP POLICY IF EXISTS review_notes_select ON review_notes;
DROP POLICY IF EXISTS review_notes_write ON review_notes;
CREATE POLICY review_notes_select ON review_notes FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
CREATE POLICY review_notes_write ON review_notes FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND profile_id = auth_profile_id())
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id());

-- B8 tasks
DROP POLICY IF EXISTS tasks_access ON tasks;
DROP POLICY IF EXISTS tasks_select ON tasks;
DROP POLICY IF EXISTS tasks_insert ON tasks;
DROP POLICY IF EXISTS tasks_update ON tasks;
DROP POLICY IF EXISTS tasks_delete ON tasks;
CREATE POLICY tasks_select ON tasks FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (assigned_to = auth_profile_id() OR auth_job_visible(job_id)));
-- Creating and deleting tasks already needed rank >= 60 (trg_tasks_assignment_rank); now explicit.
CREATE POLICY tasks_insert ON tasks FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_job_visible(job_id) AND auth_rank() >= 60);
CREATE POLICY tasks_update ON tasks FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND (assigned_to = auth_profile_id() OR auth_job_visible(job_id)))
  WITH CHECK (organization_id = auth_org_id() AND (assigned_to = auth_profile_id() OR auth_job_visible(job_id)));
CREATE POLICY tasks_delete ON tasks FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(job_id) AND auth_rank() >= 60);

CREATE OR REPLACE FUNCTION guard_task_update()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  -- Task cost: Partner only (editTaskCost / saveTaskCost).
  IF (NEW.monthly_cost IS DISTINCT FROM OLD.monthly_cost OR NEW.cost_history IS DISTINCT FROM OLD.cost_history)
     AND NOT auth_is_partner() THEN
    RAISE EXCEPTION 'Only partners can edit task costs.' USING ERRCODE = '42501';
  END IF;
  IF auth_rank() >= 60 THEN RETURN NEW; END IF;
  -- Below Assistant Manager: only the status (CAN.editTaskStatus — own tasks,
  -- or any visible task from Senior Executive up).
  IF (to_jsonb(NEW) - 'status' - 'completed_at' - 'updated_at')
     IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'completed_at' - 'updated_at') THEN
    RAISE EXCEPTION 'Only Assistant Managers, Managers and Partners can change task details.' USING ERRCODE = '42501';
  END IF;
  IF OLD.assigned_to IS DISTINCT FROM auth_profile_id() AND auth_rank() < 50 THEN
    RAISE EXCEPTION 'You can only update the status of your own tasks.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_task_update ON tasks;
CREATE TRIGGER trg_guard_task_update BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION guard_task_update();

-- B9 nil_timesheets / job_assignments / statutory_compliances
DROP POLICY IF EXISTS nil_timesheets_access ON nil_timesheets;
DROP POLICY IF EXISTS nil_timesheets_select ON nil_timesheets;
DROP POLICY IF EXISTS nil_timesheets_insert ON nil_timesheets;
CREATE POLICY nil_timesheets_select ON nil_timesheets FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_profile_visible(profile_id));
CREATE POLICY nil_timesheets_insert ON nil_timesheets FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id());

DROP POLICY IF EXISTS job_assignments_access ON job_assignments;
DROP POLICY IF EXISTS job_assignments_select ON job_assignments;
DROP POLICY IF EXISTS job_assignments_write ON job_assignments;
CREATE POLICY job_assignments_select ON job_assignments FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(job_id));
CREATE POLICY job_assignments_write ON job_assignments FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(job_id) AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_job_visible(job_id) AND auth_rank() >= 60);

DROP POLICY IF EXISTS statutory_compliances_access ON statutory_compliances;
DROP POLICY IF EXISTS statutory_compliances_select ON statutory_compliances;
DROP POLICY IF EXISTS statutory_compliances_write ON statutory_compliances;
CREATE POLICY statutory_compliances_select ON statutory_compliances FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_client_visible(client_id));
CREATE POLICY statutory_compliances_write ON statutory_compliances FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_client_visible(client_id) AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_client_visible(client_id) AND auth_rank() >= 60);

-- (Sites: turning a site on/off stays with locations_update, rank >= 60 after A3 —
--  the Manager permission today, now shared with Assistant Managers.)

-- B11 leaves_insert: same rule, written as ">= 90" instead of "= 90"
DROP POLICY IF EXISTS leaves_insert ON leaves;
CREATE POLICY leaves_insert ON leaves FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id()
              AND (status = 'pending' OR (status = 'approved' AND auth_rank() >= 90)));

-- B12 TRUNCATE bypasses RLS; the API never needs it.
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

REVOKE ALL ON FUNCTION guard_timesheet_entry() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_expense_claim() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_budget_request() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_client_archive() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_task_update() FROM PUBLIC, anon, authenticated;
-- Remove the site guard if an earlier draft of this migration created it.
DROP TRIGGER IF EXISTS trg_guard_site_active ON locations;
DROP FUNCTION IF EXISTS guard_site_active();

COMMIT;
