-- ==============================================================================
-- 056: HIERARCHICAL APPROVALS + APPROVAL AUDIT TRAIL
-- ==============================================================================
-- The Approvals screen is opened to every employee (index.html). What each
-- person may SEE and DECIDE is enforced here, not in the browser.
--
-- One rule decides "who may approve whose request" for timesheets, leave and
-- expense claims (approval_can_decide):
--   * never your own request;
--   * a Partner: any non-partner in the organization (partners self-certify
--     their own timesheet / leave, unchanged);
--   * an Assistant Manager or Manager (rank >= 60): anyone below them in the
--     reporting line - direct reports and their reports, any depth
--     (approval_is_under walks profiles.reports_to);
--   * nobody else. A Senior Executive or below who has direct reports no
--     longer approves; those requests go to the next Assistant Manager /
--     Manager above, and to the partners.
--
-- Who may SEE a request (approval_can_view): its owner, every Partner, and an
-- Assistant Manager / Manager above the owner in the reporting line. Whoever
-- recorded a decision keeps seeing that decision (history stays readable
-- after someone changes manager).
--
-- What changes:
--   1. helpers approval_is_under / approval_can_decide / approval_can_view.
--   2. timesheet_can_decide (036) now uses approval_can_decide, so the
--      existing timesheet_entries policies and guard_timesheet_entry() trigger
--      enforce the new rule without being rewritten. Self-approval stays
--      blocked by that guard.
--   3. leaves: read / decide policies use the same rule; a new guard makes an
--      approver record themselves as approved_by and stops the owner from
--      writing a decision.
--   4. expense_claims: approve / reject follows the rule (guard); reading is
--      narrowed to owner, hierarchy, partners and the people who decided or
--      pay it. Marking paid is unchanged (Assistant Manager+ or "accounts").
--   5. approval_events: an append-only audit trail. Every status change of a
--      timesheet (per person / week / job code), a leave request, an expense
--      claim and a budget request adds ONE row - submitted, approved,
--      rejected, sent back, reopened (undo), cancelled, paid. Rows are never
--      updated or deleted through the API, so a later status change can never
--      overwrite earlier history. Existing records get one "current state"
--      row each (backfill, flagged in detail.backfilled).
--
-- Deliberately NOT changed:
--   * timesheet_entries SELECT. Job codes, Time on jobs and Reports total
--     hours from every employee's entries (see 005); narrowing it would break
--     job budgets for every role. Approval visibility for timesheets is
--     enforced through approval_events and the decision rules above.
--   * budget_requests. A budget increase belongs to a job, not to the
--     requester's reporting line; its rules (036 A1/B3) stay as they are.
--     Its decisions are recorded in approval_events like the others.
--   * timesheet submission, leave balances / calculation, attendance,
--     salary, earned leave - no function or trigger of theirs is touched.
--   * email routing (notif_approvers, 026) - unchanged.
--
-- Safe to re-run. Apply with:
--   supabase db query --linked -f supabase/migrations/056_hierarchical_approvals.sql
-- ==============================================================================

BEGIN;

-- ---- 1. helpers -----------------------------------------------------------------

-- Is p_who below p_boss in the reporting line (direct or indirect)?
CREATE OR REPLACE FUNCTION approval_is_under(p_who UUID, p_boss UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH RECURSIVE chain(id, depth) AS (
    SELECT p.reports_to, 1 FROM profiles p WHERE p.id = p_who
    UNION ALL
    SELECT p.reports_to, c.depth + 1
      FROM chain c JOIN profiles p ON p.id = c.id
     WHERE c.id IS NOT NULL AND c.depth < 20
  )
  SELECT p_who IS NOT NULL AND p_boss IS NOT NULL AND p_who <> p_boss
     AND EXISTS (SELECT 1 FROM chain WHERE id = p_boss);
$$;

-- May the signed-in user approve / reject a request owned by p_owner?
CREATE OR REPLACE FUNCTION approval_can_decide(p_owner UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth_profile_id() IS NOT NULL
     AND p_owner IS DISTINCT FROM auth_profile_id()
     AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = p_owner AND p.organization_id = auth_org_id())
     AND (
       (auth_rank() >= 90 AND profile_rank(p_owner) < 90)
       OR (auth_rank() >= 60 AND approval_is_under(p_owner, auth_profile_id()))
     );
$$;

-- May the signed-in user see requests owned by p_owner?
CREATE OR REPLACE FUNCTION approval_can_view(p_owner UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth_profile_id() IS NOT NULL
     AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = p_owner AND p.organization_id = auth_org_id())
     AND (
       p_owner = auth_profile_id()
       OR auth_rank() >= 90
       OR (auth_rank() >= 60 AND approval_is_under(p_owner, auth_profile_id()))
     );
$$;

REVOKE ALL ON FUNCTION approval_is_under(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION approval_can_decide(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION approval_can_view(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approval_is_under(uuid, uuid), approval_can_decide(uuid), approval_can_view(uuid)
  TO authenticated;

-- ---- 2. timesheets: same signature, new rule --------------------------------------
-- Used by timesheet_entries_update and guard_timesheet_entry() (036).
CREATE OR REPLACE FUNCTION timesheet_can_decide(p_owner UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT approval_can_decide(p_owner);
$$;
REVOKE ALL ON FUNCTION timesheet_can_decide(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION timesheet_can_decide(uuid) TO authenticated;

-- ---- 3. leaves ---------------------------------------------------------------------
-- The "approved leave of people you can see, senior and up" read is kept: the
-- Team today / attendance board shows who is on leave.
DROP POLICY IF EXISTS leaves_select ON leaves;
CREATE POLICY leaves_select ON leaves FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR (status = 'approved' AND auth_rank() >= 50 AND auth_profile_visible(profile_id))
      OR approval_can_view(profile_id)
      OR approved_by = auth_profile_id()
    )
  );

DROP POLICY IF EXISTS leaves_update ON leaves;
CREATE POLICY leaves_update ON leaves FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND (profile_id = auth_profile_id() OR approval_can_decide(profile_id)))
  WITH CHECK (
    organization_id = auth_org_id() AND (
      (profile_id = auth_profile_id() AND status = 'cancelled')
      OR approval_can_decide(profile_id)
    )
  );

CREATE OR REPLACE FUNCTION guard_leave_decision()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_me UUID := auth_profile_id();
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  IF NEW.profile_id IS DISTINCT FROM OLD.profile_id OR NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'That change to a leave request is not allowed.' USING ERRCODE = '42501';
  END IF;
  IF OLD.profile_id = v_me THEN
    -- The owner may only cancel (policy); never write a decision.
    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason THEN
      RAISE EXCEPTION 'You cannot record a decision on your own leave.' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT approval_can_decide(OLD.profile_id) THEN
    RAISE EXCEPTION 'You cannot decide this leave request.' USING ERRCODE = '42501';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('approved', 'rejected')
     AND NEW.approved_by IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'A leave decision must be recorded in your own name.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION guard_leave_decision() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_guard_leave_decision ON leaves;
CREATE TRIGGER trg_guard_leave_decision BEFORE UPDATE ON leaves
  FOR EACH ROW EXECUTE FUNCTION guard_leave_decision();

-- ---- 4. expense claims -------------------------------------------------------------
DROP POLICY IF EXISTS expense_claims_select ON expense_claims;
CREATE POLICY expense_claims_select ON expense_claims FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR approval_can_view(profile_id)
    OR approved_by = auth_profile_id()
    OR paid_by = auth_profile_id()
    -- payment queue: whoever may mark a claim paid sees approved / paid claims
    OR (status IN ('approved', 'paid') AND (auth_rank() >= 60 OR auth_role() = 'accounts')
        AND auth_profile_visible(profile_id))));

-- 036 body with one change: approve / reject needs approval_can_decide()
-- instead of "any Assistant Manager and above".
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
  -- approver: Partner, or Assistant Manager / Manager above the owner; never their own
  IF OLD.status = 'submitted' AND NEW.status IN ('approved', 'rejected')
     AND approval_can_decide(OLD.profile_id) AND NEW.approved_by = v_me
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
REVOKE ALL ON FUNCTION guard_expense_claim() FROM PUBLIC, anon, authenticated;

-- ---- 5. approval_events: append-only audit trail ------------------------------------
CREATE TABLE IF NOT EXISTS approval_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  request_type TEXT NOT NULL CHECK (request_type IN ('timesheet', 'leave', 'expense_claim', 'budget_increase')),
  -- timesheet: <profile>:<week_start>:<job>; leave: request_id; claim / budget: row id
  request_key TEXT NOT NULL,
  employee_id UUID,
  employee_name TEXT,
  employee_designation TEXT,
  action TEXT NOT NULL CHECK (action IN ('submitted', 'self_certified', 'approved', 'rejected',
                                         'reopened', 'cancelled', 'paid')),
  from_status TEXT,
  to_status TEXT NOT NULL,
  actor_id UUID,
  actor_name TEXT,
  actor_designation TEXT,
  reason TEXT,
  detail JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  tx_id BIGINT NOT NULL DEFAULT txid_current()
);
-- One row per request per status change per transaction - never duplicated.
CREATE UNIQUE INDEX IF NOT EXISTS ux_approval_events_once
  ON approval_events (organization_id, request_type, request_key, to_status, tx_id);
CREATE INDEX IF NOT EXISTS idx_approval_events_request ON approval_events (organization_id, request_type, request_key, occurred_at);
CREATE INDEX IF NOT EXISTS idx_approval_events_employee ON approval_events (organization_id, employee_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_approval_events_actor ON approval_events (organization_id, actor_id, occurred_at DESC);

ALTER TABLE approval_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS approval_events_select ON approval_events;
CREATE POLICY approval_events_select ON approval_events FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    employee_id = auth_profile_id()
    OR actor_id = auth_profile_id()
    OR approval_can_view(employee_id)));
-- No insert / update / delete policy, and no write grants: rows are written
-- only by the SECURITY DEFINER triggers below and can never be edited.
REVOKE ALL ON approval_events FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON approval_events FROM authenticated;
GRANT SELECT ON approval_events TO authenticated;

-- Display name for a profile's designation at the time of the event.
CREATE OR REPLACE FUNCTION approval_designation(p_profile UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(d.name, initcap(replace(p.role, '_', ' ')))
    FROM profiles p LEFT JOIN designations d ON d.id = p.designation_id
   WHERE p.id = p_profile;
$$;
REVOKE ALL ON FUNCTION approval_designation(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION approval_log(
  p_org UUID, p_type TEXT, p_key TEXT, p_employee UUID, p_action TEXT,
  p_from TEXT, p_to TEXT, p_actor UUID, p_reason TEXT, p_detail JSONB, p_at TIMESTAMPTZ DEFAULT now())
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO approval_events (organization_id, request_type, request_key, employee_id, employee_name,
                               employee_designation, action, from_status, to_status, actor_id, actor_name,
                               actor_designation, reason, detail, occurred_at)
  SELECT p_org, p_type, p_key, p_employee, (SELECT full_name FROM profiles WHERE id = p_employee),
         approval_designation(p_employee), p_action, p_from, p_to, p_actor,
         (SELECT full_name FROM profiles WHERE id = p_actor), approval_designation(p_actor),
         NULLIF(btrim(COALESCE(p_reason, '')), ''), COALESCE(p_detail, '{}'::jsonb), COALESCE(p_at, now())
  ON CONFLICT (organization_id, request_type, request_key, to_status, tx_id) DO NOTHING;
$$;
REVOKE ALL ON FUNCTION approval_log(uuid, text, text, uuid, text, text, text, uuid, text, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;

-- 5a. timesheets: one event per person / week / job code / new status per statement
CREATE OR REPLACE FUNCTION approval_events_timesheets()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
  v_action TEXT;
BEGIN
  FOR r IN
    SELECT n.organization_id, n.profile_id, n.week_start_date, n.job_id, n.status AS to_status,
           string_agg(DISTINCT o.status, ',') AS from_status,
           max(n.decided_by::text)::uuid AS decided_by,
           max(n.query_reason) AS query_reason,
           sum(n.hours) AS hours, count(*) AS entries
      FROM new_rows n JOIN old_rows o ON o.id = n.id
     WHERE n.status IS DISTINCT FROM o.status
     GROUP BY n.organization_id, n.profile_id, n.week_start_date, n.job_id, n.status
  LOOP
    v_action := CASE r.to_status
      WHEN 'approved' THEN CASE WHEN COALESCE(v_actor, r.decided_by) = r.profile_id THEN 'self_certified' ELSE 'approved' END
      WHEN 'queried'  THEN 'rejected'
      WHEN 'pending'  THEN CASE WHEN COALESCE(v_actor, r.profile_id) = r.profile_id THEN 'submitted' ELSE 'reopened' END
      ELSE NULL END;
    CONTINUE WHEN v_action IS NULL;
    PERFORM approval_log(r.organization_id, 'timesheet',
      r.profile_id || ':' || r.week_start_date || ':' || r.job_id, r.profile_id, v_action,
      r.from_status, r.to_status, COALESCE(v_actor, r.decided_by, r.profile_id),
      CASE WHEN r.to_status = 'queried' THEN r.query_reason END,
      jsonb_build_object('week_start', r.week_start_date, 'job_id', r.job_id,
                         'hours', r.hours, 'entries', r.entries));
  END LOOP;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_approval_events_timesheets ON timesheet_entries;
CREATE TRIGGER trg_approval_events_timesheets AFTER UPDATE ON timesheet_entries
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION approval_events_timesheets();

-- 5b. leave: one event per request (all its day-rows) per statement
CREATE OR REPLACE FUNCTION approval_events_leaves_insert()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT n.organization_id, n.request_id, n.profile_id, n.status, max(n.leave_type) AS leave_type,
           min(n.leave_date) AS start_date, max(n.leave_date) AS end_date,
           sum(CASE WHEN n.duration_part = 'half' THEN 0.5 ELSE 1 END) AS days
      FROM new_rows n
     WHERE n.status IN ('pending', 'approved')
     GROUP BY n.organization_id, n.request_id, n.profile_id, n.status
  LOOP
    PERFORM approval_log(r.organization_id, 'leave', r.request_id::text, r.profile_id,
      CASE WHEN r.status = 'approved' THEN 'self_certified' ELSE 'submitted' END,
      NULL, r.status, COALESCE(auth_profile_id(), r.profile_id), NULL,
      jsonb_build_object('leave_type', r.leave_type, 'start', r.start_date, 'end', r.end_date, 'days', r.days));
  END LOOP;
  RETURN NULL;
END;
$$;
CREATE OR REPLACE FUNCTION approval_events_leaves_update()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
BEGIN
  FOR r IN
    SELECT n.organization_id, n.request_id, n.profile_id, n.status AS to_status,
           string_agg(DISTINCT o.status, ',') AS from_status,
           max(n.approved_by::text)::uuid AS approved_by, max(n.rejection_reason) AS rejection_reason,
           max(n.leave_type) AS leave_type, min(n.leave_date) AS start_date, max(n.leave_date) AS end_date,
           sum(CASE WHEN n.duration_part = 'half' THEN 0.5 ELSE 1 END) AS days
      FROM new_rows n JOIN old_rows o ON o.id = n.id
     WHERE n.status IS DISTINCT FROM o.status
     GROUP BY n.organization_id, n.request_id, n.profile_id, n.status
  LOOP
    PERFORM approval_log(r.organization_id, 'leave', r.request_id::text, r.profile_id,
      CASE r.to_status WHEN 'approved' THEN 'approved' WHEN 'rejected' THEN 'rejected'
                       WHEN 'cancelled' THEN 'cancelled' ELSE 'reopened' END,
      r.from_status, r.to_status, COALESCE(v_actor, r.approved_by, r.profile_id),
      CASE WHEN r.to_status = 'rejected' THEN r.rejection_reason END,
      jsonb_build_object('leave_type', r.leave_type, 'start', r.start_date, 'end', r.end_date, 'days', r.days));
  END LOOP;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_approval_events_leaves_insert ON leaves;
CREATE TRIGGER trg_approval_events_leaves_insert AFTER INSERT ON leaves
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION approval_events_leaves_insert();
DROP TRIGGER IF EXISTS trg_approval_events_leaves_update ON leaves;
CREATE TRIGGER trg_approval_events_leaves_update AFTER UPDATE ON leaves
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION approval_events_leaves_update();

-- 5c. expense claims
CREATE OR REPLACE FUNCTION approval_events_claims()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_action TEXT;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
  v_action := CASE NEW.status WHEN 'submitted' THEN 'submitted' WHEN 'approved' THEN 'approved'
                              WHEN 'rejected' THEN 'rejected' WHEN 'paid' THEN 'paid' ELSE 'reopened' END;
  PERFORM approval_log(NEW.organization_id, 'expense_claim', NEW.id::text, NEW.profile_id, v_action,
    OLD.status, NEW.status,
    COALESCE(auth_profile_id(), CASE WHEN NEW.status = 'paid' THEN NEW.paid_by ELSE NEW.approved_by END, NEW.profile_id),
    NULL, jsonb_build_object('claim_month', NEW.claim_month));
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_approval_events_claims ON expense_claims;
CREATE TRIGGER trg_approval_events_claims AFTER UPDATE OF status ON expense_claims
  FOR EACH ROW EXECUTE FUNCTION approval_events_claims();

-- 5d. budget increase requests
CREATE OR REPLACE FUNCTION approval_events_budgets()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
  PERFORM approval_log(NEW.organization_id, 'budget_increase', NEW.id::text, NEW.requested_by,
    CASE NEW.status WHEN 'pending' THEN CASE WHEN TG_OP = 'INSERT' THEN 'submitted' ELSE 'reopened' END
                    ELSE NEW.status END,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
    COALESCE(auth_profile_id(), NEW.decided_by, NEW.requested_by), NULL,
    jsonb_build_object('job_id', NEW.job_id, 'from_hours', NEW.from_hours, 'to_hours', NEW.to_hours,
                       'request_reason', NEW.reason));
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_approval_events_budgets ON budget_requests;
CREATE TRIGGER trg_approval_events_budgets AFTER INSERT OR UPDATE OF status ON budget_requests
  FOR EACH ROW EXECUTE FUNCTION approval_events_budgets();

REVOKE ALL ON FUNCTION approval_events_timesheets(), approval_events_leaves_insert(),
  approval_events_leaves_update(), approval_events_claims(), approval_events_budgets()
  FROM PUBLIC, anon, authenticated;

-- 5e. backfill: one "current state" event for every existing request that has none
INSERT INTO approval_events (organization_id, request_type, request_key, employee_id, employee_name,
                             employee_designation, action, from_status, to_status, actor_id, actor_name,
                             actor_designation, reason, detail, occurred_at, tx_id)
SELECT g.organization_id, 'timesheet', g.key, g.profile_id, (SELECT full_name FROM profiles WHERE id = g.profile_id),
       approval_designation(g.profile_id),
       CASE g.status WHEN 'approved' THEN CASE WHEN g.decided_by = g.profile_id THEN 'self_certified' ELSE 'approved' END
                     WHEN 'queried' THEN 'rejected' ELSE 'submitted' END,
       NULL, g.status, COALESCE(g.decided_by, g.profile_id),
       (SELECT full_name FROM profiles WHERE id = COALESCE(g.decided_by, g.profile_id)),
       approval_designation(COALESCE(g.decided_by, g.profile_id)),
       NULLIF(btrim(COALESCE(g.query_reason, '')), ''),
       jsonb_build_object('week_start', g.week_start_date, 'job_id', g.job_id, 'hours', g.hours, 'backfilled', true),
       COALESCE(g.decided_at, g.updated_at), 0
  FROM (
    SELECT organization_id, profile_id, week_start_date, job_id,
           profile_id || ':' || week_start_date || ':' || job_id AS key,
           min(status) AS status, max(decided_by::text)::uuid AS decided_by, max(decided_at) AS decided_at,
           max(updated_at) AS updated_at, max(query_reason) AS query_reason, sum(hours) AS hours
      FROM timesheet_entries
     WHERE status IN ('pending', 'approved', 'queried')
     GROUP BY organization_id, profile_id, week_start_date, job_id
    HAVING count(DISTINCT status) = 1
  ) g
 WHERE NOT EXISTS (SELECT 1 FROM approval_events e
                    WHERE e.organization_id = g.organization_id AND e.request_type = 'timesheet' AND e.request_key = g.key)
ON CONFLICT DO NOTHING;

INSERT INTO approval_events (organization_id, request_type, request_key, employee_id, employee_name,
                             employee_designation, action, from_status, to_status, actor_id, actor_name,
                             actor_designation, reason, detail, occurred_at, tx_id)
SELECT g.organization_id, 'leave', g.request_id::text, g.profile_id, (SELECT full_name FROM profiles WHERE id = g.profile_id),
       approval_designation(g.profile_id),
       CASE g.status WHEN 'approved' THEN CASE WHEN g.approved_by IS NULL OR g.approved_by = g.profile_id
                                               THEN 'self_certified' ELSE 'approved' END
                     WHEN 'rejected' THEN 'rejected' WHEN 'cancelled' THEN 'cancelled' ELSE 'submitted' END,
       NULL, g.status, COALESCE(g.approved_by, g.profile_id),
       (SELECT full_name FROM profiles WHERE id = COALESCE(g.approved_by, g.profile_id)),
       approval_designation(COALESCE(g.approved_by, g.profile_id)),
       CASE WHEN g.status = 'rejected' THEN NULLIF(btrim(COALESCE(g.rejection_reason, '')), '') END,
       jsonb_build_object('leave_type', g.leave_type, 'start', g.start_date, 'end', g.end_date, 'days', g.days, 'backfilled', true),
       COALESCE(g.approved_at, g.created_at), 0
  FROM (
    SELECT organization_id, request_id, profile_id, min(status) AS status,
           max(approved_by::text)::uuid AS approved_by, max(approved_at) AS approved_at, min(created_at) AS created_at,
           max(rejection_reason) AS rejection_reason, max(leave_type) AS leave_type,
           min(leave_date) AS start_date, max(leave_date) AS end_date,
           sum(CASE WHEN duration_part = 'half' THEN 0.5 ELSE 1 END) AS days
      FROM leaves
     GROUP BY organization_id, request_id, profile_id
    HAVING count(DISTINCT status) = 1
  ) g
 WHERE NOT EXISTS (SELECT 1 FROM approval_events e
                    WHERE e.organization_id = g.organization_id AND e.request_type = 'leave' AND e.request_key = g.request_id::text)
ON CONFLICT DO NOTHING;

INSERT INTO approval_events (organization_id, request_type, request_key, employee_id, employee_name,
                             employee_designation, action, from_status, to_status, actor_id, actor_name,
                             actor_designation, reason, detail, occurred_at, tx_id)
SELECT c.organization_id, 'expense_claim', c.id::text, c.profile_id, (SELECT full_name FROM profiles WHERE id = c.profile_id),
       approval_designation(c.profile_id), c.status, NULL, c.status,
       COALESCE(CASE WHEN c.status = 'paid' THEN c.paid_by END, c.approved_by, c.profile_id),
       (SELECT full_name FROM profiles WHERE id = COALESCE(CASE WHEN c.status = 'paid' THEN c.paid_by END, c.approved_by, c.profile_id)),
       approval_designation(COALESCE(CASE WHEN c.status = 'paid' THEN c.paid_by END, c.approved_by, c.profile_id)),
       NULL, jsonb_build_object('claim_month', c.claim_month, 'backfilled', true),
       COALESCE(CASE WHEN c.status = 'paid' THEN c.paid_at END, c.approved_at, c.submitted_at, c.updated_at), 0
  FROM expense_claims c
 WHERE c.status IN ('submitted', 'approved', 'rejected', 'paid')
   AND NOT EXISTS (SELECT 1 FROM approval_events e
                    WHERE e.organization_id = c.organization_id AND e.request_type = 'expense_claim' AND e.request_key = c.id::text)
ON CONFLICT DO NOTHING;

INSERT INTO approval_events (organization_id, request_type, request_key, employee_id, employee_name,
                             employee_designation, action, from_status, to_status, actor_id, actor_name,
                             actor_designation, reason, detail, occurred_at, tx_id)
SELECT b.organization_id, 'budget_increase', b.id::text, b.requested_by, (SELECT full_name FROM profiles WHERE id = b.requested_by),
       approval_designation(b.requested_by), CASE b.status WHEN 'pending' THEN 'submitted' ELSE b.status END,
       NULL, b.status, COALESCE(b.decided_by, b.requested_by),
       (SELECT full_name FROM profiles WHERE id = COALESCE(b.decided_by, b.requested_by)),
       approval_designation(COALESCE(b.decided_by, b.requested_by)),
       NULL, jsonb_build_object('job_id', b.job_id, 'from_hours', b.from_hours, 'to_hours', b.to_hours,
                                'request_reason', b.reason, 'backfilled', true),
       COALESCE(b.decided_at, b.created_at), 0
  FROM budget_requests b
 WHERE NOT EXISTS (SELECT 1 FROM approval_events e
                    WHERE e.organization_id = b.organization_id AND e.request_type = 'budget_increase' AND e.request_key = b.id::text)
ON CONFLICT DO NOTHING;

COMMIT;
