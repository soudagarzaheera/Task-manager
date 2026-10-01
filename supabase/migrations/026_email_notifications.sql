-- ==============================================================================
-- 026: CENTRALIZED EMAIL NOTIFICATIONS (queue + triggers + schedules)
-- ==============================================================================
-- Application emails (task assigned, leave/budget/timesheet decisions, due and
-- overdue reminders, the daily partner summary, job closed, employee status)
-- are decided HERE, in the database, never by the browser:
--
--   business write (unchanged frontend call)
--     -> AFTER trigger compares OLD/NEW, decides whether an email is due,
--        resolves recipients inside the same organization, and inserts ONE
--        row into email_notifications (unique dedupe_key => no duplicates)
--     -> pg_cron calls the send-notifications Edge Function every minute
--        (via pg_net, authenticated with a shared secret held in Vault)
--     -> the Edge Function renders the template and sends through Resend,
--        recording sent / retry / failed on the same row.
--
-- Guarantees:
--   * A notification problem never breaks the business action: every
--     trigger body runs inside BEGIN ... EXCEPTION WHEN OTHERS, which only
--     raises a WARNING. The task/leave/timesheet write always commits.
--   * Only real state changes notify (status pending->approved, assigned_to
--     actually changed, job moved to closed, ...). Reads never notify.
--   * Recipients are always profiles of the row's own organization_id.
--     Partner fan-out is limited to partners of the SAME company_id as the
--     employee concerned; a person's explicit reports_to supervisor is
--     included as the app's existing approval rules (CAN.approveSheet /
--     canApproveLeaveRequest / CAN.approveBudget) already do.
--   * Nobody is emailed about their own action (the actor is excluded).
--   * No secret is stored in any table. RESEND_API_KEY lives only in Edge
--     Function secrets; the dispatch secret/URL live only in Vault.
--
-- Nothing existing is altered: no existing table, column, policy, trigger or
-- function is changed. New objects only. Safe to re-run.
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- ---- 1. per-organization settings (defaults apply when no row exists) ---------
CREATE TABLE IF NOT EXISTS notification_settings (
  organization_id UUID PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
  is_enabled BOOLEAN NOT NULL DEFAULT true,
  timezone TEXT NOT NULL DEFAULT 'Asia/Kolkata',
  reminder_time TIME NOT NULL DEFAULT '09:00',        -- due soon / due today / overdue
  daily_summary_time TIME NOT NULL DEFAULT '19:00',   -- partner daily summary
  due_soon_days INTEGER NOT NULL DEFAULT 2 CHECK (due_soon_days BETWEEN 0 AND 14),
  overdue_repeat_days INTEGER NOT NULL DEFAULT 3 CHECK (overdue_repeat_days BETWEEN 1 AND 30),
  overdue_max_reminders INTEGER NOT NULL DEFAULT 10 CHECK (overdue_max_reminders BETWEEN 1 AND 100),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_notification_settings_updated_at ON notification_settings;
CREATE TRIGGER trg_notification_settings_updated_at
  BEFORE UPDATE ON notification_settings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE FUNCTION validate_notification_settings()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
    RAISE EXCEPTION 'Unknown time zone: %', NEW.timezone USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_notification_settings ON notification_settings;
CREATE TRIGGER trg_validate_notification_settings
  BEFORE INSERT OR UPDATE OF timezone ON notification_settings
  FOR EACH ROW EXECUTE FUNCTION validate_notification_settings();

ALTER TABLE notification_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notification_settings_select ON notification_settings;
CREATE POLICY notification_settings_select ON notification_settings FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
DROP POLICY IF EXISTS notification_settings_write ON notification_settings;
CREATE POLICY notification_settings_write ON notification_settings FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 90)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 90);

-- ---- 2. the notification log / queue ------------------------------------------
-- One row = one email message (one To list + CC list). Recipients are stored
-- as profile ids and resolved to addresses only at send time, re-checked
-- against the row's organization.
CREATE TABLE IF NOT EXISTS email_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  company_id UUID,
  event_type TEXT NOT NULL,
  related_table TEXT,
  related_record_id UUID,
  dedupe_key TEXT NOT NULL,
  recipient_profile_id UUID,
  to_profile_ids UUID[] NOT NULL DEFAULT '{}',
  cc_profile_ids UUID[] NOT NULL DEFAULT '{}',
  recipient_email TEXT,                 -- filled at send time (To addresses)
  cc_emails TEXT[],                     -- filled at send time
  template_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  subject TEXT,                         -- filled at send time
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'retry', 'sent', 'failed', 'skipped', 'expired', 'dry_run')),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '3 days'),
  provider_message_id TEXT,
  error_message TEXT,
  sent_at TIMESTAMPTZ,
  created_by UUID,                      -- actor profile, when there was one
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_email_notifications_dedupe UNIQUE (dedupe_key)
);

CREATE INDEX IF NOT EXISTS idx_email_notifications_queue
  ON email_notifications (next_attempt_at)
  WHERE status IN ('pending', 'retry', 'processing');
CREATE INDEX IF NOT EXISTS idx_email_notifications_org_created
  ON email_notifications (organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_email_notifications_related
  ON email_notifications (related_table, related_record_id);

DROP TRIGGER IF EXISTS trg_email_notifications_updated_at ON email_notifications;
CREATE TRIGGER trg_email_notifications_updated_at
  BEFORE UPDATE ON email_notifications
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Server-side only: no policy for anon/authenticated, and no table grants.
-- Triggers write through SECURITY DEFINER functions; the Edge Function uses
-- the service role.
ALTER TABLE email_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON email_notifications FROM PUBLIC, anon, authenticated;
GRANT ALL ON email_notifications TO service_role;

-- ---- 3. helpers ----------------------------------------------------------------

-- Distinct, non-null profile ids that belong to p_org (and are active unless
-- p_allow_inactive), minus p_exclude, in first-seen order.
CREATE OR REPLACE FUNCTION notif_clean(
  p_org UUID, p_ids UUID[], p_exclude UUID[] DEFAULT '{}', p_allow_inactive BOOLEAN DEFAULT false
)
RETURNS UUID[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(array_agg(x.id ORDER BY x.ord), '{}'::uuid[])
  FROM (
    SELECT u.id, min(u.ord) AS ord
    FROM unnest(COALESCE(p_ids, '{}'::uuid[])) WITH ORDINALITY AS u(id, ord)
    WHERE u.id IS NOT NULL
    GROUP BY u.id
  ) x
  JOIN profiles p ON p.id = x.id AND p.organization_id = p_org AND (p.is_active OR p_allow_inactive)
  WHERE NOT (x.id = ANY (array_remove(COALESCE(p_exclude, '{}'::uuid[]), NULL)));
$$;

CREATE OR REPLACE FUNCTION notif_name(p_id UUID)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT full_name FROM profiles WHERE id = p_id;
$$;

-- Who decides requests from p_subject: their reports_to supervisor (when that
-- supervisor's rank >= p_min_supervisor_rank) plus, for a non-partner, the
-- active partners of the subject's own company. Mirrors CAN.approveSheet(),
-- canApproveLeaveRequest() and CAN.approveBudget() in index.html.
CREATE OR REPLACE FUNCTION notif_approvers(p_org UUID, p_subject UUID, p_min_supervisor_rank INT)
RETURNS UUID[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT notif_clean(
    p_org,
    ARRAY(
      SELECT s.reports_to FROM profiles s
      WHERE s.id = p_subject AND s.organization_id = p_org
        AND profile_rank(s.reports_to) >= p_min_supervisor_rank
    ) || ARRAY(
      SELECT q.id FROM profiles s
      JOIN profiles q ON q.organization_id = s.organization_id AND q.company_id = s.company_id
      WHERE s.id = p_subject AND s.organization_id = p_org
        AND q.role = 'partner' AND q.is_active
        AND profile_rank(p_subject) < 90
      ORDER BY q.created_at, q.id
    ),
    ARRAY[p_subject]
  );
$$;

-- Active partners of the subject's own company.
CREATE OR REPLACE FUNCTION notif_company_partners(p_org UUID, p_subject UUID)
RETURNS UUID[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(array_agg(q.id ORDER BY q.created_at, q.id), '{}'::uuid[])
  FROM profiles s
  JOIN profiles q ON q.organization_id = s.organization_id AND q.company_id = s.company_id
  WHERE s.id = p_subject AND s.organization_id = p_org
    AND q.role = 'partner' AND q.is_active AND q.id <> p_subject;
$$;

-- The single enqueue path used by every trigger and schedule.
--   * drops recipients outside p_org / inactive (unless p_allow_inactive)
--   * never emails the actor about their own action
--   * the same dedupe_key can only ever be queued once
--   * no eligible recipient at all -> a 'skipped' row, kept for investigation
CREATE OR REPLACE FUNCTION notif_enqueue(
  p_org UUID, p_subject UUID, p_type TEXT, p_rel_table TEXT, p_rel_id UUID, p_key TEXT,
  p_to UUID[], p_cc UUID[], p_data JSONB, p_actor UUID DEFAULT NULL,
  p_ttl INTERVAL DEFAULT interval '3 days', p_allow_inactive BOOLEAN DEFAULT false
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_enabled BOOLEAN;
  v_tz TEXT;
  v_org_name TEXT;
  v_to UUID[];
  v_to_final UUID[];
  v_cc UUID[];
  v_company UUID;
  v_company_name TEXT;
BEGIN
  SELECT COALESCE(s.is_enabled, true), COALESCE(s.timezone, 'Asia/Kolkata'), o.name
    INTO v_enabled, v_tz, v_org_name
  FROM organizations o
  LEFT JOIN notification_settings s ON s.organization_id = o.id
  WHERE o.id = p_org;
  IF NOT FOUND OR NOT v_enabled THEN
    RETURN;
  END IF;

  v_to := notif_clean(p_org, p_to, '{}', p_allow_inactive);
  v_to_final := notif_clean(p_org, v_to, ARRAY[p_actor], p_allow_inactive);
  IF cardinality(v_to) > 0 AND cardinality(v_to_final) = 0 THEN
    RETURN;  -- the only recipient was the person who acted
  END IF;
  v_cc := notif_clean(p_org, p_cc, v_to_final || ARRAY[p_actor]);

  SELECT p.company_id, c.name INTO v_company, v_company_name
  FROM profiles p
  LEFT JOIN companies c ON c.organization_id = p.organization_id AND c.id = p.company_id
  WHERE p.id = p_subject AND p.organization_id = p_org;

  INSERT INTO email_notifications (
    organization_id, company_id, event_type, related_table, related_record_id, dedupe_key,
    recipient_profile_id, to_profile_ids, cc_profile_ids, template_data,
    status, error_message, expires_at, created_by
  ) VALUES (
    p_org, v_company, p_type, p_rel_table, p_rel_id, p_key,
    v_to_final[1], v_to_final, v_cc,
    COALESCE(p_data, '{}'::jsonb) || jsonb_build_object(
      'timezone', v_tz,
      'organization_name', v_org_name,
      'company_name', COALESCE(v_company_name, v_org_name),
      'actor_name', notif_name(p_actor)
    ),
    CASE WHEN cardinality(v_to_final) = 0 THEN 'skipped' ELSE 'pending' END,
    CASE WHEN cardinality(v_to_final) = 0
         THEN 'No eligible recipient (inactive, missing, or outside the organization).' END,
    now() + p_ttl, p_actor
  )
  ON CONFLICT (dedupe_key) DO NOTHING;
END;
$$;

-- ---- 4. TASK ASSIGNED / REASSIGNED ------------------------------------------------
-- Fires only when assigned_to is set on insert or actually changes. The
-- previous assignee is never emailed. A closed job cannot get here with a new
-- assignee (trg_tasks_closed_job, 025, rejects it first) — checked again anyway.
CREATE OR REPLACE FUNCTION notif_task_assigned()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
        v_assignee.reports_to,
        NEW.assigned_by,
        CASE WHEN profile_rank(v_job.opened_by) >= 70 THEN v_job.opened_by END
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
      v_actor
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'email notification (task_assigned) not queued for task %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_notif_task_assigned ON tasks;
CREATE TRIGGER trg_notif_task_assigned
  AFTER INSERT OR UPDATE OF assigned_to ON tasks
  FOR EACH ROW EXECUTE FUNCTION notif_task_assigned();

-- ---- 5. LEAVE REQUESTED / APPROVED / REJECTED -------------------------------------
-- A leave request is N day-rows sharing request_id, written in one statement
-- (applyLeave / decideLeaveRequest), so these are statement-level triggers that
-- group by request_id: one email per request, not one per day.

CREATE OR REPLACE FUNCTION notif_leaves_inserted()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
BEGIN
  FOR r IN
    SELECT n.organization_id, n.profile_id, n.request_id,
           min(n.leave_date) AS from_date, max(n.leave_date) AS to_date,
           sum(CASE WHEN n.duration_part = 'half' THEN 0.5 ELSE 1 END) AS days,
           min(n.leave_type) AS leave_type, min(n.reason) AS reason
    FROM new_rows n
    WHERE n.status = 'pending'
    GROUP BY n.organization_id, n.profile_id, n.request_id
  LOOP
    BEGIN
      PERFORM notif_enqueue(
        r.organization_id, r.profile_id, 'leave_requested', 'leaves', r.request_id,
        format('leave_requested:%s', r.request_id),
        notif_approvers(r.organization_id, r.profile_id, 50),
        '{}'::uuid[],
        jsonb_build_object(
          'request_id', r.request_id,
          'employee_id', r.profile_id,
          'employee_name', notif_name(r.profile_id),
          'leave_type', r.leave_type,
          'leave_type_label', (SELECT label FROM leave_types
                               WHERE organization_id = r.organization_id AND code = r.leave_type),
          'from_date', r.from_date,
          'to_date', r.to_date,
          'days', r.days,
          'reason', r.reason,
          'status', 'pending'
        ),
        v_actor
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'email notification (leave_requested) not queued for request %: %', r.request_id, SQLERRM;
    END;
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION notif_leaves_decided()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
BEGIN
  FOR r IN
    SELECT n.organization_id, n.profile_id, n.request_id, n.status,
           min(n.leave_date) AS from_date, max(n.leave_date) AS to_date,
           sum(CASE WHEN n.duration_part = 'half' THEN 0.5 ELSE 1 END) AS days,
           min(n.leave_type) AS leave_type,
           (array_agg(n.approved_by) FILTER (WHERE n.approved_by IS NOT NULL))[1] AS decided_by,
           max(n.approved_at) AS decided_at,
           min(n.rejection_reason) AS rejection_reason
    FROM new_rows n
    JOIN old_rows o ON o.id = n.id
    WHERE o.status = 'pending' AND n.status IN ('approved', 'rejected')
    GROUP BY n.organization_id, n.profile_id, n.request_id, n.status
  LOOP
    BEGIN
      PERFORM notif_enqueue(
        r.organization_id, r.profile_id,
        CASE WHEN r.status = 'approved' THEN 'leave_approved' ELSE 'leave_rejected' END,
        'leaves', r.request_id,
        format('leave_%s:%s', r.status, r.request_id),
        ARRAY[r.profile_id],
        '{}'::uuid[],
        jsonb_build_object(
          'request_id', r.request_id,
          'employee_id', r.profile_id,
          'employee_name', notif_name(r.profile_id),
          'leave_type', r.leave_type,
          'leave_type_label', (SELECT label FROM leave_types
                               WHERE organization_id = r.organization_id AND code = r.leave_type),
          'from_date', r.from_date,
          'to_date', r.to_date,
          'days', r.days,
          'decided_by_name', notif_name(COALESCE(r.decided_by, v_actor)),
          'decided_at', COALESCE(r.decided_at, now()),
          'rejection_reason', NULLIF(trim(COALESCE(r.rejection_reason, '')), ''),
          'status', r.status
        ),
        COALESCE(v_actor, r.decided_by)
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'email notification (leave decision) not queued for request %: %', r.request_id, SQLERRM;
    END;
  END LOOP;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_notif_leaves_insert ON leaves;
CREATE TRIGGER trg_notif_leaves_insert
  AFTER INSERT ON leaves
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION notif_leaves_inserted();

DROP TRIGGER IF EXISTS trg_notif_leaves_update ON leaves;
CREATE TRIGGER trg_notif_leaves_update
  AFTER UPDATE ON leaves
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION notif_leaves_decided();

-- ---- 6. TIMESHEET SUBMITTED / APPROVED / REJECTED (queried) ----------------------
-- submitSheet() moves a week's draft/queried rows to pending in one statement
-- (by the owner); decideLine() moves one job code's pending rows to
-- approved/queried in one statement (by the approver). undoLine() moving rows
-- back to pending is done by the approver, not the owner, so it is NOT a
-- submission. A partner self-certifying (draft -> approved by the owner)
-- emails nobody.
CREATE OR REPLACE FUNCTION notif_timesheets_changed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
BEGIN
  -- submitted
  FOR r IN
    SELECT n.organization_id, n.profile_id, n.week_start_date,
           sum(n.hours) AS hours, count(*) AS entry_count,
           min(n.entry_date) AS first_date, max(n.entry_date) AS last_date,
           jsonb_agg(jsonb_build_object(
             'date', n.entry_date, 'job_code', j.job_code, 'task', t.title,
             'hours', n.hours, 'narration', left(n.narration, 300)
           ) ORDER BY n.entry_date, j.job_code) AS entries
    FROM new_rows n
    JOIN old_rows o ON o.id = n.id
    JOIN jobs j ON j.organization_id = n.organization_id AND j.id = n.job_id
    LEFT JOIN tasks t ON t.organization_id = n.organization_id AND t.id = n.task_id
    WHERE o.status IN ('draft', 'queried') AND n.status = 'pending'
      AND v_actor IS NOT NULL AND n.profile_id = v_actor
    GROUP BY n.organization_id, n.profile_id, n.week_start_date
  LOOP
    BEGIN
      PERFORM notif_enqueue(
        r.organization_id, r.profile_id, 'timesheet_submitted', 'profiles', r.profile_id,
        format('timesheet_submitted:%s:%s:%s', r.profile_id, r.week_start_date, txid_current()),
        notif_approvers(r.organization_id, r.profile_id, 0),
        '{}'::uuid[],
        jsonb_build_object(
          'employee_id', r.profile_id,
          'employee_name', notif_name(r.profile_id),
          'week_start', r.week_start_date,
          'first_date', r.first_date,
          'last_date', r.last_date,
          'hours', r.hours,
          'entry_count', r.entry_count,
          'entries', r.entries
        ),
        v_actor
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'email notification (timesheet_submitted) not queued for %: %', r.profile_id, SQLERRM;
    END;
  END LOOP;

  -- approved / queried (rejected) by someone other than the owner
  FOR r IN
    SELECT n.organization_id, n.profile_id, n.week_start_date, n.status,
           sum(n.hours) AS hours, count(*) AS entry_count,
           (array_agg(n.decided_by) FILTER (WHERE n.decided_by IS NOT NULL))[1] AS decided_by,
           max(n.decided_at) AS decided_at,
           min(NULLIF(trim(n.query_reason), '')) AS query_reason,
           jsonb_agg(jsonb_build_object(
             'date', n.entry_date, 'job_code', j.job_code, 'task', t.title,
             'hours', n.hours, 'narration', left(n.narration, 300)
           ) ORDER BY n.entry_date, j.job_code) AS entries
    FROM new_rows n
    JOIN old_rows o ON o.id = n.id
    JOIN jobs j ON j.organization_id = n.organization_id AND j.id = n.job_id
    LEFT JOIN tasks t ON t.organization_id = n.organization_id AND t.id = n.task_id
    WHERE o.status = 'pending' AND n.status IN ('approved', 'queried')
      AND n.profile_id IS DISTINCT FROM v_actor
    GROUP BY n.organization_id, n.profile_id, n.week_start_date, n.status
  LOOP
    BEGIN
      PERFORM notif_enqueue(
        r.organization_id, r.profile_id,
        CASE WHEN r.status = 'approved' THEN 'timesheet_approved' ELSE 'timesheet_rejected' END,
        'profiles', r.profile_id,
        format('timesheet_%s:%s:%s:%s', r.status, r.profile_id, r.week_start_date, txid_current()),
        ARRAY[r.profile_id],
        '{}'::uuid[],
        jsonb_build_object(
          'employee_id', r.profile_id,
          'employee_name', notif_name(r.profile_id),
          'week_start', r.week_start_date,
          'hours', r.hours,
          'entry_count', r.entry_count,
          'entries', r.entries,
          'decided_by_name', notif_name(COALESCE(r.decided_by, v_actor)),
          'decided_at', COALESCE(r.decided_at, now()),
          'rejection_reason', r.query_reason
        ),
        COALESCE(v_actor, r.decided_by)
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'email notification (timesheet decision) not queued for %: %', r.profile_id, SQLERRM;
    END;
  END LOOP;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_notif_timesheets_update ON timesheet_entries;
CREATE TRIGGER trg_notif_timesheets_update
  AFTER UPDATE ON timesheet_entries
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION notif_timesheets_changed();

-- ---- 7. BUDGETED HOURS REQUEST / APPROVED / REJECTED ------------------------------
-- Partners never request (CAN.requestBudget(), 024) — unchanged; this only
-- reacts to rows that already exist.
CREATE OR REPLACE FUNCTION notif_budget_requests()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_actor UUID := auth_profile_id();
  v_job jobs%ROWTYPE;
  v_client TEXT;
  v_booked NUMERIC;
  v_data JSONB;
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
      PERFORM notif_enqueue(
        NEW.organization_id, NEW.requested_by, 'budget_requested', 'budget_requests', NEW.id,
        format('budget_requested:%s', NEW.id),
        notif_approvers(NEW.organization_id, NEW.requested_by, 70)
          || CASE WHEN profile_rank(v_job.opened_by) >= 70 THEN ARRAY[v_job.opened_by] ELSE '{}'::uuid[] END,
        '{}'::uuid[],
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
$$;

DROP TRIGGER IF EXISTS trg_notif_budget_requests ON budget_requests;
CREATE TRIGGER trg_notif_budget_requests
  AFTER INSERT OR UPDATE OF status ON budget_requests
  FOR EACH ROW EXECUTE FUNCTION notif_budget_requests();

-- ---- 8. JOB CLOSED ------------------------------------------------------------------
-- Only on the transition into 'closed'. Re-saving an already-closed job sends
-- nothing; reopening and closing again is a new closure (new closed_at).
CREATE OR REPLACE FUNCTION notif_job_closed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
$$;

DROP TRIGGER IF EXISTS trg_notif_job_closed ON jobs;
CREATE TRIGGER trg_notif_job_closed
  AFTER UPDATE OF status ON jobs
  FOR EACH ROW EXECUTE FUNCTION notif_job_closed();

-- ---- 9. EMPLOYEE DEACTIVATED / REACTIVATED ----------------------------------------
-- doOffboard() / reactivate() flip profiles.is_active. The employee is told,
-- with the partners of their own company in CC (never the acting partner).
CREATE OR REPLACE FUNCTION notif_employee_status()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_actor UUID := auth_profile_id();
  v_type TEXT;
BEGIN
  IF NEW.is_active IS NOT DISTINCT FROM OLD.is_active THEN
    RETURN NULL;
  END IF;
  v_type := CASE WHEN NEW.is_active THEN 'employee_reactivated' ELSE 'employee_deactivated' END;

  BEGIN
    PERFORM notif_enqueue(
      NEW.organization_id, NEW.id, v_type, 'profiles', NEW.id,
      format('%s:%s:%s', v_type, NEW.id, txid_current()),
      ARRAY[NEW.id],
      notif_company_partners(NEW.organization_id, NEW.id),
      jsonb_build_object(
        'employee_id', NEW.id,
        'employee_name', NEW.full_name,
        'role', NEW.role,
        'exit_date', NEW.exit_date,
        'changed_by_name', notif_name(v_actor),
        'changed_at', now()
      ),
      v_actor,
      interval '3 days',
      true   -- a deactivated employee is still told about their own deactivation
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'email notification (%) not queued for profile %: %', v_type, NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_notif_employee_status ON profiles;
CREATE TRIGGER trg_notif_employee_status
  AFTER UPDATE OF is_active ON profiles
  FOR EACH ROW EXECUTE FUNCTION notif_employee_status();

-- ---- 10. EMPLOYEE INVITED (called by the create-employee Edge Function) ------------
-- create-employee already creates the Supabase Auth account + profile (the
-- existing flow; no second invitation system). It calls this afterwards, with
-- the service role, to queue the "you have been added" email. Never exposed to
-- browsers.
CREATE OR REPLACE FUNCTION notif_employee_invited(p_profile UUID, p_actor UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_p profiles%ROWTYPE;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_profile;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  -- The actor must be a partner of the same organization.
  IF NOT EXISTS (SELECT 1 FROM profiles a WHERE a.id = p_actor AND a.organization_id = v_p.organization_id
                   AND a.role = 'partner' AND a.is_active) THEN
    RETURN;
  END IF;
  PERFORM notif_enqueue(
    v_p.organization_id, v_p.id, 'employee_invited', 'profiles', v_p.id,
    format('employee_invited:%s', v_p.id),
    ARRAY[v_p.id],
    '{}'::uuid[],
    jsonb_build_object(
      'employee_id', v_p.id,
      'employee_name', v_p.full_name,
      'role', v_p.role,
      'joining_date', v_p.joining_date,
      'invited_by_name', notif_name(p_actor)
    ),
    p_actor
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'email notification (employee_invited) not queued for profile %: %', p_profile, SQLERRM;
END;
$$;

-- ---- 11. SCHEDULED: due soon / due today / overdue / partner daily summary --------
-- Run by pg_cron every 15 minutes; every run is idempotent (dedupe_key is per
-- task + assignee + due date [+ overdue bucket], or per partner + local date),
-- so extra or missed runs never double-send or skip a day.
-- "Today" is the organization's local date (notification_settings.timezone,
-- default Asia/Kolkata) — never the UTC date. p_org limits a manual run to
-- one organization (cron passes nothing = all organizations).
DROP FUNCTION IF EXISTS enqueue_scheduled_notifications(timestamptz);
CREATE OR REPLACE FUNCTION enqueue_scheduled_notifications(p_now TIMESTAMPTZ DEFAULT now(), p_org UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
               j.id AS job_id, j.job_code, j.title AS job_title, c.name AS client_name
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
                ARRAY[t.reports_to, t.assigned_by],
                v_data || jsonb_build_object('days_overdue', v_days, 'reminder_number', v_bucket + 1),
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
    -- only appear through one of those explicit relationships.
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
                   OR tk.assigned_by = p.id OR j.opened_by = p.id)
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
$$;

-- ---- 12. dispatcher support (service role only) -------------------------------------

-- Claim a batch to send. Expired rows are closed out first; rows stuck in
-- 'processing' (a crashed run) are reclaimed after 10 minutes — safe, because
-- the Edge Function sends with Resend's Idempotency-Key = row id.
CREATE OR REPLACE FUNCTION claim_email_notifications(p_limit INT DEFAULT 20, p_org UUID DEFAULT NULL)
RETURNS SETOF email_notifications
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE email_notifications
     SET status = 'expired', locked_at = NULL,
         error_message = COALESCE(error_message || ' | ', '') || 'Expired before it could be sent.'
   WHERE status IN ('pending', 'retry', 'processing')
     AND expires_at < now()
     AND (p_org IS NULL OR organization_id = p_org);

  RETURN QUERY
  UPDATE email_notifications e
     SET status = 'processing', locked_at = now(), attempts = e.attempts + 1
   WHERE e.id IN (
     SELECT q.id FROM email_notifications q
     WHERE (p_org IS NULL OR q.organization_id = p_org)
       AND ((q.status IN ('pending', 'retry') AND q.next_attempt_at <= now())
            OR (q.status = 'processing' AND q.locked_at < now() - interval '10 minutes'))
     ORDER BY q.created_at
     LIMIT GREATEST(1, LEAST(p_limit, 100))
     FOR UPDATE SKIP LOCKED
   )
  RETURNING e.*;
END;
$$;

-- Resolve recipient profile ids to addresses, restricted to one organization.
-- contact_email first (what create-employee stores), sign-in email otherwise.
CREATE OR REPLACE FUNCTION notif_recipients(p_org UUID, p_ids UUID[])
RETURNS TABLE (profile_id UUID, full_name TEXT, email TEXT, is_active BOOLEAN, company_id UUID)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.full_name,
         lower(COALESCE(NULLIF(trim(p.contact_email), ''), u.email)),
         p.is_active, p.company_id
  FROM profiles p
  LEFT JOIN auth.users u ON u.id = p.auth_user_id
  WHERE p.organization_id = p_org AND p.id = ANY (COALESCE(p_ids, '{}'::uuid[]));
$$;

-- pg_cron -> Edge Function. URL and shared secret are read from Vault
-- (names below); nothing secret is in this file. Skips the HTTP call when
-- there is nothing due.
CREATE OR REPLACE FUNCTION notif_invoke_dispatcher()
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_url TEXT;
  v_secret TEXT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM email_notifications
    WHERE (status IN ('pending', 'retry') AND next_attempt_at <= now())
       OR (status = 'processing' AND locked_at < now() - interval '10 minutes')
  ) THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'notifications_dispatch_url';
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'notifications_dispatch_secret';
  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE WARNING 'notifications: Vault secrets notifications_dispatch_url / notifications_dispatch_secret are not set';
    RETURN NULL;
  END IF;

  RETURN net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notifications-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
END;
$$;

-- ---- 13. privileges ---------------------------------------------------------------
DO $$
DECLARE
  f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'validate_notification_settings()',
    'notif_clean(uuid, uuid[], uuid[], boolean)',
    'notif_name(uuid)',
    'notif_approvers(uuid, uuid, integer)',
    'notif_company_partners(uuid, uuid)',
    'notif_enqueue(uuid, uuid, text, text, uuid, text, uuid[], uuid[], jsonb, uuid, interval, boolean)',
    'notif_task_assigned()',
    'notif_leaves_inserted()',
    'notif_leaves_decided()',
    'notif_timesheets_changed()',
    'notif_budget_requests()',
    'notif_job_closed()',
    'notif_employee_status()',
    'notif_employee_invited(uuid, uuid)',
    'enqueue_scheduled_notifications(timestamptz, uuid)',
    'claim_email_notifications(integer, uuid)',
    'notif_recipients(uuid, uuid[])',
    'notif_invoke_dispatcher()'
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION notif_employee_invited(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION claim_email_notifications(integer, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION notif_recipients(uuid, uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION enqueue_scheduled_notifications(timestamptz, uuid) TO service_role;

-- ---- 14. schedules (cron.schedule upserts by job name) ------------------------------
SELECT cron.schedule('notifications-dispatch', '* * * * *',
  $cron$ SELECT public.notif_invoke_dispatcher(); $cron$);
SELECT cron.schedule('notifications-scheduled', '*/15 * * * *',
  $cron$ SELECT public.enqueue_scheduled_notifications(); $cron$);
SELECT cron.schedule('notifications-purge', '17 3 * * 0',
  $cron$ DELETE FROM public.email_notifications
         WHERE status IN ('sent', 'skipped', 'expired', 'dry_run', 'failed')
           AND created_at < now() - interval '180 days'; $cron$);

-- ---- 15. one-time setup (run separately; NOT part of this file) --------------------
-- Vault entries used by notif_invoke_dispatcher(). The secret must equal the
-- NOTIFICATIONS_DISPATCH_SECRET Edge Function secret:
--   SELECT vault.create_secret('https://<project-ref>.supabase.co/functions/v1/send-notifications',
--                              'notifications_dispatch_url');
--   SELECT vault.create_secret('<random 64-hex>', 'notifications_dispatch_secret');
