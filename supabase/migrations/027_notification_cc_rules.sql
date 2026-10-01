-- ==============================================================================
-- 027: NOTIFICATION CC RULES
-- ==============================================================================
-- Fixes emails arriving with no CC. Two defects in 026:
--
--   1. notif_enqueue() always removed the actor from CC. For a task
--      assignment the actor IS the assigning Manager/Partner — exactly the
--      person the CC is meant for — so in a company where the assigner is also
--      the employee's supervisor and the job opener, every CC candidate was
--      removed and the CC list was empty.
--   2. leave_requested and budget_requested put the supervisor AND the
--      partners all in To, with an empty CC list, so they could never have a
--      CC at all.
--
-- New rules (recipient SETS are unchanged apart from dropping a job opener
-- from another company; only To vs CC placement changes):
--   task_assigned     To = assignee
--                     CC = assigner (even though they acted), assignee's
--                          supervisor, job opener if manager+ AND same company
--   leave_requested   To = direct supervisor (manager/senior/partner)
--                          — or the company's partners if there is none
--                     CC = partners of the employee's SAME company
--   budget_requested  To = direct supervisor if manager+
--                          — or the company's partners if there is none
--                     CC = partners of the SAME company, plus the job opener
--                          if manager+ and same company
-- Everything else (leave/budget/timesheet decisions, timesheet submitted,
-- employee status, reminders, summaries) is unchanged.
--
-- No table, column or trigger definition changes — function bodies only.
-- CC never includes a To recipient, and never crosses organization_id; the
-- partner fan-out never crosses company_id. Safe to re-run.
-- ==============================================================================

-- ---- notif_enqueue: optional "keep the actor in CC" -----------------------------
DROP FUNCTION IF EXISTS notif_enqueue(uuid, uuid, text, text, uuid, text, uuid[], uuid[], jsonb, uuid, interval, boolean);

CREATE OR REPLACE FUNCTION notif_enqueue(
  p_org UUID, p_subject UUID, p_type TEXT, p_rel_table TEXT, p_rel_id UUID, p_key TEXT,
  p_to UUID[], p_cc UUID[], p_data JSONB, p_actor UUID DEFAULT NULL,
  p_ttl INTERVAL DEFAULT interval '3 days', p_allow_inactive BOOLEAN DEFAULT false,
  p_cc_include_actor BOOLEAN DEFAULT false
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
  -- CC never repeats a To recipient. The actor is left out of CC unless the
  -- rule for this notification says the actor is a CC recipient (the
  -- assigning Manager/Partner on a task assignment).
  v_cc := notif_clean(
    p_org, p_cc,
    v_to_final || CASE WHEN p_cc_include_actor THEN '{}'::uuid[] ELSE ARRAY[p_actor] END
  );

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

-- ---- helpers --------------------------------------------------------------------

-- The subject's direct supervisor, when active and ranked >= p_min_rank.
CREATE OR REPLACE FUNCTION notif_supervisor(p_org UUID, p_subject UUID, p_min_rank INT)
RETURNS UUID[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT notif_clean(
    p_org,
    ARRAY(SELECT s.reports_to FROM profiles s
          WHERE s.id = p_subject AND s.organization_id = p_org
            AND profile_rank(s.reports_to) >= p_min_rank),
    ARRAY[p_subject]
  );
$$;

-- p_candidate if they are in the same company as p_subject, else NULL.
CREATE OR REPLACE FUNCTION notif_if_same_company(p_org UUID, p_subject UUID, p_candidate UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id FROM profiles c
  JOIN profiles s ON s.organization_id = c.organization_id AND s.company_id = c.company_id
  WHERE c.id = p_candidate AND s.id = p_subject AND c.organization_id = p_org;
$$;

-- ---- TASK ASSIGNED: assigner stays in CC; no other-company job opener ---------
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
        v_actor,
        NEW.assigned_by,
        v_assignee.reports_to,
        CASE WHEN profile_rank(v_job.opened_by) >= 70
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
$$;

-- ---- LEAVE REQUESTED: To = supervisor, CC = same-company partners --------------
CREATE OR REPLACE FUNCTION notif_leaves_inserted()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
  v_to UUID[];
  v_partners UUID[];
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
      -- Same approver set as before (canApproveLeaveRequest): the supervisor
      -- (manager/senior/partner) and, for a non-partner, the company's partners.
      v_partners := CASE WHEN profile_rank(r.profile_id) < 90
                         THEN notif_company_partners(r.organization_id, r.profile_id)
                         ELSE '{}'::uuid[] END;
      v_to := notif_supervisor(r.organization_id, r.profile_id, 50);
      IF cardinality(v_to) = 0 THEN
        v_to := v_partners;
      END IF;

      PERFORM notif_enqueue(
        r.organization_id, r.profile_id, 'leave_requested', 'leaves', r.request_id,
        format('leave_requested:%s', r.request_id),
        v_to,
        v_partners,
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

-- ---- BUDGET REQUESTED: To = approver, CC = same-company partners ---------------
CREATE OR REPLACE FUNCTION notif_budget_requests()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
      -- Same approver set as before (CAN.approveBudget: manager/partner), with
      -- the job opener kept only when they belong to the requester's company.
      v_cc := CASE WHEN profile_rank(NEW.requested_by) < 90
                   THEN notif_company_partners(NEW.organization_id, NEW.requested_by)
                   ELSE '{}'::uuid[] END
              || ARRAY[CASE WHEN profile_rank(v_job.opened_by) >= 70
                            THEN notif_if_same_company(NEW.organization_id, NEW.requested_by, v_job.opened_by) END];
      v_to := notif_supervisor(NEW.organization_id, NEW.requested_by, 70);
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
$$;

-- ---- privileges (same rule as 026: never callable by clients) --------------------
REVOKE ALL ON FUNCTION notif_enqueue(uuid, uuid, text, text, uuid, text, uuid[], uuid[], jsonb, uuid, interval, boolean, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_supervisor(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_if_same_company(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_task_assigned() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_leaves_inserted() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notif_budget_requests() FROM PUBLIC, anon, authenticated;
