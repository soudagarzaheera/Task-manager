-- ==============================================================================
-- 042: RESPONSIBLE PARTNER PER JOB CODE
-- ==============================================================================
-- A client keeps ONE Relationship Partner (clients.relationship_partner_id,
-- unchanged and never written here). Each job code now also has its own
-- Responsible Partner, so one client's jobs can sit with different partners:
--
--   ABC Ltd.  Relationship Partner: P1
--     GST Reconciliation  -> P1     Statutory Audit -> P2     Tax Audit -> P3
--
-- jobs.responsible_partner_id
--   * must be an active, not deleted Partner (role 'partner') of the job's own
--     organization (composite FK + trg_jobs_responsible_partner). Any company
--     of the organization is allowed: partners already see every company.
--   * default on insert: the client's Relationship Partner, but only when that
--     person is an active Partner (the client form also accepts AM / Manager).
--     Otherwise it stays NULL and the app asks the user to choose.
--   * existing jobs are backfilled the same way.
--
-- Who may choose a partner other than the default / change it later:
--   Partner                -> any job of the organization
--   Manager (rank 70)      -> jobs of their own company only
--   Assistant Manager and below -> no (they raise jobs with the default)
-- This is deliberately narrower than jobs_update (rank >= 60, 032); every
-- other job field keeps its existing rule. Service-role calls are exempt, as
-- in the other guards. Clearing the partner through the API is refused.
--
-- Every change is written to audit_logs and emailed ('job_partner_changed'):
-- To the new partner, CC the previous one (To the previous one when the new
-- partner made the change themselves). Job emails also follow the CURRENT
-- responsible partner from now on: task_assigned (CC), budget_requested (CC),
-- task_overdue (CC), job_closed (own copy), partner daily summary (scope).
--
-- RLS on jobs is unchanged. org_partners() lets every member list the
-- organization's partners (id, name, company, active) — profiles RLS hides
-- other-company partners from non-partners, which would leave the dropdown and
-- the job card blank.
--
-- Deploy together with the send-notifications Edge Function (new template
-- 'job_partner_changed'; the dispatcher marks unknown types as failed).
-- Safe to re-run.
-- ==============================================================================

-- ---- 0. triggers off while the column is added and backfilled ---------------------
-- (a re-run must not re-validate or e-mail the backfill)
DROP TRIGGER IF EXISTS trg_jobs_responsible_partner ON jobs;
DROP TRIGGER IF EXISTS trg_jobs_responsible_partner_audit ON jobs;
DROP TRIGGER IF EXISTS trg_notif_job_partner_changed ON jobs;

-- ---- 1. column ----------------------------------------------------------------------
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS responsible_partner_id UUID;

ALTER TABLE jobs DROP CONSTRAINT IF EXISTS fk_jobs_responsible_partner;
ALTER TABLE jobs ADD CONSTRAINT fk_jobs_responsible_partner
  FOREIGN KEY (organization_id, responsible_partner_id) REFERENCES profiles(organization_id, id)
  ON DELETE SET NULL (responsible_partner_id);

CREATE INDEX IF NOT EXISTS idx_jobs_responsible_partner ON jobs (organization_id, responsible_partner_id);

COMMENT ON COLUMN jobs.responsible_partner_id IS
  'Partner responsible for this job code (042). Separate from clients.relationship_partner_id, which is the client''s owner.';

-- ---- 2. helpers ---------------------------------------------------------------------
-- An active, not deleted Partner of p_org.
CREATE OR REPLACE FUNCTION is_active_partner(p_org UUID, p_profile UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = p_profile AND p.organization_id = p_org
      AND p.role = 'partner' AND p.is_active AND p.deleted_at IS NULL
  );
$$;

-- The client's Relationship Partner when they are an active Partner, else NULL.
CREATE OR REPLACE FUNCTION client_default_job_partner(p_org UUID, p_client UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.relationship_partner_id FROM clients c
  WHERE c.id = p_client AND c.organization_id = p_org
    AND is_active_partner(p_org, c.relationship_partner_id);
$$;

-- May the signed-in user choose / change the Responsible Partner of a job that
-- belongs to p_company? Partner: yes. Manager: own company only. Others: no.
CREATE OR REPLACE FUNCTION auth_can_set_job_partner(p_company UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth_rank() >= 90
      OR (auth_rank() >= 70 AND p_company IS NOT NULL AND p_company = auth_company_id());
$$;

-- ---- 3. backfill existing jobs ------------------------------------------------------
UPDATE jobs j
   SET responsible_partner_id = client_default_job_partner(j.organization_id, j.client_id)
 WHERE j.responsible_partner_id IS NULL
   AND j.client_id IS NOT NULL
   AND client_default_job_partner(j.organization_id, j.client_id) IS NOT NULL;

-- ---- 4. guard: default, validation, permission ---------------------------------------
-- Runs after trg_jobs_company (alphabetical), so NEW.company_id is already set.
CREATE OR REPLACE FUNCTION guard_job_responsible_partner()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_api BOOLEAN := auth.uid() IS NOT NULL;
  v_default UUID;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_default := client_default_job_partner(NEW.organization_id, NEW.client_id);
    IF NEW.responsible_partner_id IS NULL THEN
      NEW.responsible_partner_id := v_default;
      RETURN NEW;
    END IF;
    -- Choosing someone other than the default needs the change permission —
    -- except when the client has no Partner to default to: then whoever may
    -- raise the job has to name one.
    IF v_api AND v_default IS NOT NULL AND NEW.responsible_partner_id <> v_default
       AND NOT auth_can_set_job_partner(NEW.company_id) THEN
      RAISE EXCEPTION 'Only a Partner, or a Manager for their own company''s jobs, can choose a different responsible partner.'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    IF NEW.responsible_partner_id IS NOT DISTINCT FROM OLD.responsible_partner_id THEN
      RETURN NEW;
    END IF;
    IF v_api THEN
      -- Checked against the job's company both before and after the update.
      IF NOT (auth_can_set_job_partner(OLD.company_id) AND auth_can_set_job_partner(NEW.company_id)) THEN
        RAISE EXCEPTION 'Only a Partner, or a Manager for their own company''s jobs, can change the responsible partner.'
          USING ERRCODE = '42501';
      END IF;
      IF NEW.responsible_partner_id IS NULL THEN
        RAISE EXCEPTION 'A job''s responsible partner cannot be removed — choose another partner instead.'
          USING ERRCODE = '23502';
      END IF;
    END IF;
  END IF;

  IF NEW.responsible_partner_id IS NOT NULL
     AND NOT is_active_partner(NEW.organization_id, NEW.responsible_partner_id) THEN
    RAISE EXCEPTION 'The responsible partner must be an active Partner of this organization.'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_jobs_responsible_partner
  BEFORE INSERT OR UPDATE OF responsible_partner_id ON jobs
  FOR EACH ROW EXECUTE FUNCTION guard_job_responsible_partner();

-- ---- 5. audit trail of changes --------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_job_responsible_partner()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.responsible_partner_id IS NOT DISTINCT FROM OLD.responsible_partner_id THEN
    RETURN NULL;
  END IF;
  INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, old_values, new_values)
  VALUES (NEW.organization_id, auth_profile_id(), 'job_responsible_partner_changed', 'jobs', NEW.id::text,
          jsonb_build_object('responsible_partner_id', OLD.responsible_partner_id, 'job_code', OLD.job_code),
          jsonb_build_object('responsible_partner_id', NEW.responsible_partner_id, 'job_code', NEW.job_code));
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_jobs_responsible_partner_audit
  AFTER UPDATE OF responsible_partner_id ON jobs
  FOR EACH ROW EXECUTE FUNCTION audit_job_responsible_partner();

-- ---- 6. the organization's partners, for every member --------------------------------
-- Active partners (the choices) plus any partner still named on a job of the
-- organization (so an inactive one still shows by name). Names only.
CREATE OR REPLACE FUNCTION org_partners()
RETURNS TABLE (id UUID, full_name TEXT, company_id UUID, is_active BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.full_name, p.company_id, (p.is_active AND p.deleted_at IS NULL)
  FROM profiles p
  WHERE p.organization_id = auth_org_id()
    AND p.role = 'partner'
    AND ((p.is_active AND p.deleted_at IS NULL)
         OR EXISTS (SELECT 1 FROM jobs j WHERE j.organization_id = p.organization_id
                                           AND j.responsible_partner_id = p.id))
  ORDER BY p.full_name;
$$;

-- ---- 7. e-mail: responsible partner changed --------------------------------------------
CREATE OR REPLACE FUNCTION notif_job_partner_changed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_actor UUID := auth_profile_id();
  v_prev UUID;
  v_client clients%ROWTYPE;
  v_to UUID[];
  v_cc UUID[];
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.responsible_partner_id IS NOT DISTINCT FROM OLD.responsible_partner_id THEN
      RETURN NULL;
    END IF;
    v_prev := OLD.responsible_partner_id;
  END IF;

  BEGIN
    SELECT * INTO v_client FROM clients
      WHERE organization_id = NEW.organization_id AND id = NEW.client_id;

    IF TG_OP = 'INSERT' THEN
      -- A new job only e-mails a partner who was explicitly picked instead of
      -- the client's Relationship Partner (the default needs no announcement).
      IF NEW.responsible_partner_id IS NULL
         OR NEW.responsible_partner_id IS NOT DISTINCT FROM v_client.relationship_partner_id THEN
        RETURN NULL;
      END IF;
    END IF;

    IF NEW.responsible_partner_id IS NOT NULL AND NEW.responsible_partner_id IS DISTINCT FROM v_actor THEN
      v_to := ARRAY[NEW.responsible_partner_id];
      v_cc := ARRAY[v_prev];
    ELSE
      -- the new partner made the change themselves (or it was cleared by the
      -- system): tell the previous partner
      v_to := ARRAY[v_prev];
      v_cc := '{}'::uuid[];
    END IF;

    PERFORM notif_enqueue(
      NEW.organization_id, COALESCE(NEW.responsible_partner_id, v_prev), 'job_partner_changed', 'jobs', NEW.id,
      format('job_partner_changed:%s:%s:%s', NEW.id, COALESCE(NEW.responsible_partner_id::text, 'none'), txid_current()),
      v_to,
      v_cc,
      jsonb_build_object(
        'job_id', NEW.id,
        'job_code', NEW.job_code,
        'job_title', NEW.title,
        'job_status', NEW.status,
        'client_name', v_client.name,
        'relationship_partner_name', notif_name(v_client.relationship_partner_id),
        'responsible_partner_name', notif_name(NEW.responsible_partner_id),
        'previous_partner_name', notif_name(v_prev),
        'is_new_job', TG_OP = 'INSERT',
        'internal_due_date', NEW.internal_due_date,
        'statutory_due_date', NEW.statutory_due_date,
        'changed_by_name', notif_name(v_actor),
        'changed_at', now()
      ),
      v_actor
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'email notification (job_partner_changed) not queued for job %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_notif_job_partner_changed
  AFTER INSERT OR UPDATE OF responsible_partner_id ON jobs
  FOR EACH ROW EXECUTE FUNCTION notif_job_partner_changed();

-- ---- 8. existing job e-mails follow the current responsible partner -------------------
-- Bodies are the live definitions (026/027/036) with only the responsible
-- partner added: task_assigned CC, budget_requested CC, job_closed recipient,
-- task_overdue CC, partner daily summary scope, and the partner's name in the data.
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
        v_job.responsible_partner_id,
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
        'previous_assignee_name', notif_name(v_prev),
        'responsible_partner_name', notif_name(v_job.responsible_partner_id)
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
      'status', NEW.status,
      'responsible_partner_name', notif_name(v_job.responsible_partner_id)
    );

    IF TG_OP = 'INSERT' THEN
      -- Same approver set as CAN.approveBudget (Assistant Manager, Manager,
      -- Partner — 036), with the job opener kept only when they belong to the
      -- requester's company.
      v_cc := CASE WHEN profile_rank(NEW.requested_by) < 90
                   THEN notif_company_partners(NEW.organization_id, NEW.requested_by)
                   ELSE '{}'::uuid[] END
              || ARRAY[CASE WHEN profile_rank(v_job.opened_by) >= 60
                            THEN notif_if_same_company(NEW.organization_id, NEW.requested_by, v_job.opened_by) END]
              || ARRAY[v_job.responsible_partner_id];
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

CREATE OR REPLACE FUNCTION public.notif_job_closed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor UUID := auth_profile_id();
  v_client TEXT;
  v_pid UUID;
BEGIN
  IF NOT (NEW.status = 'closed' AND OLD.status IS DISTINCT FROM 'closed') THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT name INTO v_client FROM clients
      WHERE organization_id = NEW.organization_id AND id = NEW.client_id;

    FOR v_pid IN
      SELECT t.assigned_to FROM tasks t
        WHERE t.organization_id = NEW.organization_id AND t.job_id = NEW.id AND t.assigned_to IS NOT NULL
      UNION
      SELECT a.profile_id FROM job_assignments a
        WHERE a.organization_id = NEW.organization_id AND a.job_id = NEW.id
      UNION
      SELECT NEW.responsible_partner_id WHERE NEW.responsible_partner_id IS NOT NULL
    LOOP
      PERFORM notif_enqueue(
        NEW.organization_id, v_pid, 'job_closed', 'jobs', NEW.id,
        format('job_closed:%s:%s:%s', NEW.id, v_pid,
               COALESCE(extract(epoch FROM NEW.closed_at)::bigint::text, txid_current()::text)),
        ARRAY[v_pid],
        '{}'::uuid[],
        jsonb_build_object(
          'job_id', NEW.id,
          'job_code', NEW.job_code,
          'job_title', NEW.title,
          'client_name', v_client,
          'closing_note', NEW.closing_note,
          'closed_at', COALESCE(NEW.closed_at, now()),
          'closed_by_name', notif_name(v_actor),
          'employee_name', notif_name(v_pid),
          'responsible_partner_name', notif_name(NEW.responsible_partner_id),
          'is_responsible_partner', v_pid = NEW.responsible_partner_id,
          'task_count', (SELECT count(*) FROM tasks t
                         WHERE t.organization_id = NEW.organization_id AND t.job_id = NEW.id
                           AND t.assigned_to = v_pid)
        ),
        v_actor
      );
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'email notification (job_closed) not queued for job %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enqueue_scheduled_notifications(p_now timestamp with time zone DEFAULT now(), p_org uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  o RECORD;
  t RECORD;
  p RECORD;
  v_local TIMESTAMP;
  v_today DATE;
  v_days INT;
  v_bucket INT;
  v_data JSONB;
  n_soon INT := 0;
  n_today INT := 0;
  n_overdue INT := 0;
  n_summary INT := 0;
BEGIN
  FOR o IN
    SELECT org.id,
           COALESCE(s.is_enabled, true) AS enabled,
           COALESCE(s.timezone, 'Asia/Kolkata') AS tz,
           COALESCE(s.reminder_time, '09:00'::time) AS reminder_time,
           COALESCE(s.daily_summary_time, '19:00'::time) AS summary_time,
           COALESCE(s.due_soon_days, 2) AS soon_days,
           COALESCE(s.overdue_repeat_days, 3) AS repeat_days,
           COALESCE(s.overdue_max_reminders, 10) AS max_reminders
    FROM organizations org
    LEFT JOIN notification_settings s ON s.organization_id = org.id
    WHERE p_org IS NULL OR org.id = p_org
  LOOP
    CONTINUE WHEN NOT o.enabled;
    v_local := p_now AT TIME ZONE o.tz;
    v_today := v_local::date;

    -- task reminders -------------------------------------------------------
    IF v_local::time >= o.reminder_time THEN
      FOR t IN
        SELECT tk.id, tk.organization_id, tk.title, tk.status, tk.due_date, tk.estimated_hours,
               tk.assigned_to, tk.assigned_by, a.reports_to, a.full_name AS assignee_name,
               j.id AS job_id, j.job_code, j.title AS job_title, c.name AS client_name,
               j.responsible_partner_id
        FROM tasks tk
        JOIN jobs j ON j.organization_id = tk.organization_id AND j.id = tk.job_id AND j.status <> 'closed'
        JOIN profiles a ON a.organization_id = tk.organization_id AND a.id = tk.assigned_to AND a.is_active
        LEFT JOIN clients c ON c.organization_id = tk.organization_id AND c.id = j.client_id
        WHERE tk.organization_id = o.id
          AND tk.status <> 'completed'
          AND tk.due_date <= v_today + o.soon_days
      LOOP
        BEGIN
          v_data := jsonb_build_object(
            'task_id', t.id, 'task_title', t.title, 'task_status', t.status,
            'job_id', t.job_id, 'job_code', t.job_code, 'job_title', t.job_title,
            'client_name', t.client_name, 'employee_id', t.assigned_to,
            'employee_name', t.assignee_name, 'due_date', t.due_date,
            'estimated_hours', t.estimated_hours, 'today', v_today
          );
          IF t.due_date > v_today THEN
            PERFORM notif_enqueue(
              o.id, t.assigned_to, 'task_due_soon', 'tasks', t.id,
              format('task_due_soon:%s:%s:%s', t.id, t.assigned_to, t.due_date),
              ARRAY[t.assigned_to], '{}'::uuid[],
              v_data || jsonb_build_object('days_until_due', t.due_date - v_today),
              NULL, interval '20 hours'
            );
            n_soon := n_soon + 1;
          ELSIF t.due_date = v_today THEN
            PERFORM notif_enqueue(
              o.id, t.assigned_to, 'task_due_today', 'tasks', t.id,
              format('task_due_today:%s:%s:%s', t.id, t.assigned_to, t.due_date),
              ARRAY[t.assigned_to], '{}'::uuid[],
              v_data, NULL, interval '14 hours'
            );
            n_today := n_today + 1;
          ELSE
            v_days := v_today - t.due_date;
            v_bucket := (v_days - 1) / o.repeat_days;   -- 0 on day 1, then every N days
            IF v_bucket < o.max_reminders THEN
              PERFORM notif_enqueue(
                o.id, t.assigned_to, 'task_overdue', 'tasks', t.id,
                format('task_overdue:%s:%s:%s:%s', t.id, t.assigned_to, t.due_date, v_bucket),
                ARRAY[t.assigned_to],
                ARRAY[t.reports_to, t.assigned_by, t.responsible_partner_id],
                v_data || jsonb_build_object('days_overdue', v_days, 'reminder_number', v_bucket + 1,
                                             'responsible_partner_name', notif_name(t.responsible_partner_id)),
                NULL, interval '20 hours'
              );
              n_overdue := n_overdue + 1;
            END IF;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'scheduled task reminder not queued for task %: %', t.id, SQLERRM;
        END;
      END LOOP;
    END IF;

    -- partner daily summary -----------------------------------------------
    -- Scope per partner (same responsibility rules as partner_task_assignments):
    -- tasks of their own company's people, their direct reports, tasks they
    -- assigned or hold, and tasks on jobs they opened. Other companies' tasks
    -- only appear through one of those explicit relationships. Jobs the partner
    -- is the Responsible Partner of are always in scope (042).
    IF v_local::time >= o.summary_time THEN
      FOR p IN
        SELECT pr.id, pr.company_id FROM profiles pr
        WHERE pr.organization_id = o.id AND pr.role = 'partner' AND pr.is_active
      LOOP
        BEGIN
          WITH scope AS (
            SELECT tk.id, tk.title, tk.status, tk.due_date, tk.completed_at,
                   j.job_code, j.status AS job_status, a.full_name AS assignee_name
            FROM tasks tk
            JOIN jobs j ON j.organization_id = tk.organization_id AND j.id = tk.job_id
            LEFT JOIN profiles a ON a.organization_id = tk.organization_id AND a.id = tk.assigned_to
            WHERE tk.organization_id = o.id
              AND (a.company_id = p.company_id OR a.reports_to = p.id OR tk.assigned_to = p.id
                   OR tk.assigned_by = p.id OR j.opened_by = p.id
                   OR j.responsible_partner_id = p.id)
          ),
          open_tasks AS (
            SELECT * FROM scope WHERE status <> 'completed' AND job_status <> 'closed'
          ),
          overdue AS (SELECT * FROM open_tasks WHERE due_date < v_today),
          due AS (SELECT * FROM open_tasks WHERE due_date BETWEEN v_today AND v_today + o.soon_days),
          other_pending AS (SELECT * FROM open_tasks WHERE due_date > v_today + o.soon_days),
          done_today AS (
            SELECT * FROM scope
            WHERE status = 'completed' AND (completed_at AT TIME ZONE o.tz)::date = v_today
          )
          SELECT jsonb_build_object(
            'partner_id', p.id,
            'partner_name', notif_name(p.id),
            'summary_date', v_today,
            'due_window_days', o.soon_days,
            'counts', jsonb_build_object(
              'pending', (SELECT count(*) FROM open_tasks),
              'completed_today', (SELECT count(*) FROM done_today),
              'due', (SELECT count(*) FROM due),
              'overdue', (SELECT count(*) FROM overdue)
            ),
            'overdue', COALESCE((SELECT jsonb_agg(x) FROM (
              SELECT title, job_code, assignee_name, due_date, v_today - due_date AS days_overdue, status
              FROM overdue ORDER BY due_date, job_code LIMIT 25) x), '[]'::jsonb),
            'due', COALESCE((SELECT jsonb_agg(x) FROM (
              SELECT title, job_code, assignee_name, due_date, status
              FROM due ORDER BY due_date, job_code LIMIT 25) x), '[]'::jsonb),
            'pending', COALESCE((SELECT jsonb_agg(x) FROM (
              SELECT title, job_code, assignee_name, due_date, status
              FROM other_pending ORDER BY due_date, job_code LIMIT 25) x), '[]'::jsonb),
            'completed_today', COALESCE((SELECT jsonb_agg(x) FROM (
              SELECT title, job_code, assignee_name, completed_at
              FROM done_today ORDER BY completed_at DESC LIMIT 25) x), '[]'::jsonb)
          ) INTO v_data;

          -- Nothing open and nothing finished today: no email.
          CONTINUE WHEN (v_data->'counts'->>'pending')::int = 0
                    AND (v_data->'counts'->>'completed_today')::int = 0;

          PERFORM notif_enqueue(
            o.id, p.id, 'partner_daily_summary', 'profiles', p.id,
            format('partner_daily_summary:%s:%s', p.id, v_today),
            ARRAY[p.id], '{}'::uuid[],
            v_data, NULL, interval '12 hours'
          );
          n_summary := n_summary + 1;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'daily summary not queued for partner %: %', p.id, SQLERRM;
        END;
      END LOOP;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('due_soon', n_soon, 'due_today', n_today,
                            'overdue', n_overdue, 'daily_summary', n_summary);
END;
$function$;

-- ---- 9. privileges ----------------------------------------------------------------------
REVOKE ALL ON FUNCTION is_active_partner(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION client_default_job_partner(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION auth_can_set_job_partner(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_can_set_job_partner(uuid) TO authenticated;
REVOKE ALL ON FUNCTION guard_job_responsible_partner() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION audit_job_responsible_partner() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION org_partners() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION org_partners() TO authenticated;
REVOKE ALL ON FUNCTION notif_job_partner_changed() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_task_assigned() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_budget_requests() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_job_closed() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enqueue_scheduled_notifications(timestamptz, uuid) FROM PUBLIC, anon, authenticated;
