-- ==============================================================================
-- 057: DAY-WISE TIMESHEET APPROVAL AND QUERIES
-- ==============================================================================
-- Submission already works per date (055). This makes approval and queries
-- work per date too, on the existing timesheet_entries rows - no weekly
-- records, no new status values:
--   pending  = submitted / resubmitted, waiting on the approver
--   queried  = "Query Raised" for that date
--   approved = approved
--
-- 1. timesheet_day_queries - one row per query ROUND on one employee's date.
--    Raised when an approver moves a date's pending entries to queried; the
--    entries as submitted are kept in original_entries. The employee may
--    reply (once per round - never overwritten) and resubmits the date; the
--    entries as resubmitted are kept in resubmitted_entries. The round then
--    closes when the approver approves (resolution approved), queries again
--    (re_queried - a new round opens), undoes (undone) or explicitly resolves
--    it (resolved_by_approver). Rounds are never updated or deleted through
--    the API; earlier rounds stay as history.
-- 2. guard_timesheet_entry (036) - same rules, plus: an approver cannot
--    approve any entry on a date whose query is still open (raised, not yet
--    resubmitted), and may approve a queried entry only after explicitly
--    resolving the query. Who may decide is still timesheet_can_decide ->
--    approval_can_decide (056): Partner, or Assistant Manager / Manager above
--    the employee; never yourself.
-- 3. RPCs: timesheet_query_respond (employee reply) and
--    timesheet_resolve_and_approve_day (approver closes an open query and
--    approves the date in one step).
-- 4. approval_events (056): timesheet events are now one per employee per
--    DATE (request_key <profile>:<date>), plus "responded" / "resolved"
--    actions. Earlier per-job events keep their keys and stay readable.
--
-- Not changed: submitSheet / 055 date lock / day minimum (045) / task
-- completion (040) / attendance, leave, salary, earned leave.
-- Safe to re-run. Apply with:
--   supabase db query --linked -f supabase/migrations/057_timesheet_day_queries.sql
-- ==============================================================================

BEGIN;

-- ---- 1. query rounds --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timesheet_day_queries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL,
  work_date DATE NOT NULL,
  week_start_date DATE NOT NULL,
  round INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'responded', 'resubmitted', 'closed')),
  raised_by UUID,
  raised_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason TEXT NOT NULL,
  original_entries JSONB NOT NULL DEFAULT '[]'::jsonb,
  response TEXT,
  responded_at TIMESTAMPTZ,
  resubmitted_at TIMESTAMPTZ,
  resubmitted_entries JSONB,
  resolution TEXT CHECK (resolution IN ('approved', 're_queried', 'resolved_by_approver', 'undone')),
  resolution_note TEXT,
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  UNIQUE (organization_id, profile_id, work_date, round)
);
CREATE INDEX IF NOT EXISTS idx_ts_day_queries_open
  ON timesheet_day_queries (organization_id, profile_id, work_date) WHERE status <> 'closed';

ALTER TABLE timesheet_day_queries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS timesheet_day_queries_select ON timesheet_day_queries;
CREATE POLICY timesheet_day_queries_select ON timesheet_day_queries FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR approval_can_view(profile_id)
    OR raised_by = auth_profile_id()
    OR resolved_by = auth_profile_id()));
REVOKE ALL ON timesheet_day_queries FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON timesheet_day_queries FROM authenticated;
GRANT SELECT ON timesheet_day_queries TO authenticated;

-- Is a query on this date still waiting on the employee (raised / replied, not resubmitted)?
CREATE OR REPLACE FUNCTION timesheet_day_query_open(p_org UUID, p_profile UUID, p_date DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM timesheet_day_queries q
                  WHERE q.organization_id = p_org AND q.profile_id = p_profile AND q.work_date = p_date
                    AND q.status IN ('open', 'responded'));
$$;
REVOKE ALL ON FUNCTION timesheet_day_query_open(uuid, uuid, date) FROM PUBLIC, anon, authenticated;

-- The submitted entries of one date, for the round snapshots.
CREATE OR REPLACE FUNCTION timesheet_day_snapshot(p_org UUID, p_profile UUID, p_date DATE)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', t.id, 'job_id', t.job_id, 'task_id', t.task_id, 'hours', t.hours,
           'narration', t.narration, 'status', t.status) ORDER BY t.created_at, t.id), '[]'::jsonb)
    FROM timesheet_entries t
   WHERE t.organization_id = p_org AND t.profile_id = p_profile
     AND COALESCE(t.entry_date, t.week_start_date + t.day_index) = p_date
     AND t.status <> 'draft';
$$;
REVOKE ALL ON FUNCTION timesheet_day_snapshot(uuid, uuid, date) FROM PUBLIC, anon, authenticated;

-- ---- 2. guard: 036 rules + day-level query rules ---------------------------------------
CREATE OR REPLACE FUNCTION guard_timesheet_entry()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_me UUID := auth_profile_id();
  v_content BOOLEAN;
  v_open BOOLEAN;
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
  -- Hours, job, date, narration … - everything except the decision columns.
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
      IF NEW.status = 'pending' AND OLD.status = 'queried' THEN
        RETURN NEW;                                 -- resubmitting a queried date (the query text stays on record)
      END IF;
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
  v_open := timesheet_day_query_open(OLD.organization_id, OLD.profile_id,
                                     COALESCE(OLD.entry_date, OLD.week_start_date + OLD.day_index));
  IF NEW.status = 'approved' AND NEW.decided_by = v_me
     AND (OLD.status = 'pending' OR OLD.status = 'queried') THEN
    IF v_open THEN
      RAISE EXCEPTION 'This day has an open query. Wait for the employee to resubmit it, or resolve the query first.'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'pending' AND NEW.status = 'queried' AND NEW.decided_by = v_me
     AND btrim(COALESCE(NEW.query_reason, '')) <> '' THEN RETURN NEW; END IF;
  IF OLD.status IN ('pending', 'approved', 'queried') AND NEW.status = 'pending' AND NEW.decided_by IS NULL THEN
    RETURN NEW;                                     -- undo a decision
  END IF;
  RAISE EXCEPTION 'That timesheet status change is not allowed.' USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION guard_timesheet_entry() FROM PUBLIC, anon, authenticated;

-- ---- 3. approval_events: day-level timesheet events + new actions -----------------------
ALTER TABLE approval_events DROP CONSTRAINT IF EXISTS approval_events_action_check;
ALTER TABLE approval_events ADD CONSTRAINT approval_events_action_check
  CHECK (action IN ('submitted', 'self_certified', 'approved', 'rejected', 'reopened', 'cancelled', 'paid',
                    'responded', 'resolved'));

-- 056's trigger function, grouped per date instead of per job code.
CREATE OR REPLACE FUNCTION approval_events_timesheets()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
  v_action TEXT;
BEGIN
  FOR r IN
    SELECT n.organization_id, n.profile_id,
           COALESCE(n.entry_date, n.week_start_date + n.day_index) AS work_date,
           min(n.week_start_date) AS week_start, n.status AS to_status,
           string_agg(DISTINCT o.status, ',') AS from_status,
           max(n.decided_by::text)::uuid AS decided_by,
           max(n.query_reason) AS query_reason,
           sum(n.hours) AS hours, count(*) AS entries,
           jsonb_agg(DISTINCT n.job_id) AS jobs
      FROM new_rows n JOIN old_rows o ON o.id = n.id
     WHERE n.status IS DISTINCT FROM o.status
     GROUP BY n.organization_id, n.profile_id, COALESCE(n.entry_date, n.week_start_date + n.day_index), n.status
  LOOP
    v_action := CASE r.to_status
      WHEN 'approved' THEN CASE WHEN COALESCE(v_actor, r.decided_by) = r.profile_id THEN 'self_certified' ELSE 'approved' END
      WHEN 'queried'  THEN 'rejected'
      WHEN 'pending'  THEN CASE WHEN COALESCE(v_actor, r.profile_id) = r.profile_id THEN 'submitted' ELSE 'reopened' END
      ELSE NULL END;
    CONTINUE WHEN v_action IS NULL;
    PERFORM approval_log(r.organization_id, 'timesheet', r.profile_id || ':' || r.work_date, r.profile_id, v_action,
      r.from_status, r.to_status, COALESCE(v_actor, r.decided_by, r.profile_id),
      CASE WHEN r.to_status = 'queried' THEN r.query_reason END,
      jsonb_build_object('date', r.work_date, 'week_start', r.week_start, 'jobs', r.jobs,
                         'hours', r.hours, 'entries', r.entries));
  END LOOP;
  RETURN NULL;
END;
$$;

-- ---- 4. query rounds follow the entries' status changes ------------------------------------
CREATE OR REPLACE FUNCTION timesheet_day_query_rounds()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD;
  v_actor UUID := auth_profile_id();
  v_by UUID;
BEGIN
  FOR r IN
    SELECT n.organization_id, n.profile_id,
           COALESCE(n.entry_date, n.week_start_date + n.day_index) AS work_date,
           min(n.week_start_date) AS week_start, n.status AS to_status,
           bool_or(o.status = 'queried') AS from_queried,
           max(n.decided_by::text)::uuid AS decided_by,
           max(NULLIF(btrim(n.query_reason), '')) AS reason
      FROM new_rows n JOIN old_rows o ON o.id = n.id
     WHERE n.status IS DISTINCT FROM o.status
     GROUP BY n.organization_id, n.profile_id, COALESCE(n.entry_date, n.week_start_date + n.day_index), n.status
  LOOP
    v_by := COALESCE(v_actor, r.decided_by);

    IF r.to_status = 'queried' THEN
      -- a resubmitted round that is queried again closes; a new round opens
      UPDATE timesheet_day_queries SET status = 'closed', resolution = 're_queried', resolved_by = v_by, resolved_at = now()
       WHERE organization_id = r.organization_id AND profile_id = r.profile_id AND work_date = r.work_date
         AND status = 'resubmitted';
      IF NOT timesheet_day_query_open(r.organization_id, r.profile_id, r.work_date) THEN
        INSERT INTO timesheet_day_queries (organization_id, profile_id, work_date, week_start_date, round, status,
                                           raised_by, reason, original_entries)
        SELECT r.organization_id, r.profile_id, r.work_date, r.week_start,
               COALESCE((SELECT max(round) FROM timesheet_day_queries
                          WHERE organization_id = r.organization_id AND profile_id = r.profile_id
                            AND work_date = r.work_date), 0) + 1,
               'open', v_by, COALESCE(r.reason, ''),
               timesheet_day_snapshot(r.organization_id, r.profile_id, r.work_date);
      END IF;

    ELSIF r.to_status = 'pending' AND r.from_queried AND COALESCE(v_actor, r.profile_id) = r.profile_id THEN
      -- the employee resubmits the queried date
      UPDATE timesheet_day_queries
         SET status = 'resubmitted', resubmitted_at = now(),
             resubmitted_entries = timesheet_day_snapshot(r.organization_id, r.profile_id, r.work_date)
       WHERE organization_id = r.organization_id AND profile_id = r.profile_id AND work_date = r.work_date
         AND status IN ('open', 'responded');

    ELSIF r.to_status = 'pending' AND COALESCE(v_actor, r.profile_id) <> r.profile_id THEN
      -- an approver undid a decision: any round still running on the date ends
      UPDATE timesheet_day_queries SET status = 'closed', resolution = 'undone', resolved_by = v_by, resolved_at = now()
       WHERE organization_id = r.organization_id AND profile_id = r.profile_id AND work_date = r.work_date
         AND status <> 'closed';

    ELSIF r.to_status = 'approved' THEN
      UPDATE timesheet_day_queries SET status = 'closed', resolution = 'approved', resolved_by = v_by, resolved_at = now()
       WHERE organization_id = r.organization_id AND profile_id = r.profile_id AND work_date = r.work_date
         AND status = 'resubmitted';
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION timesheet_day_query_rounds() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_timesheet_day_query_rounds ON timesheet_entries;
CREATE TRIGGER trg_timesheet_day_query_rounds AFTER UPDATE ON timesheet_entries
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION timesheet_day_query_rounds();

-- ---- 5. RPCs -------------------------------------------------------------------------------
-- The employee replies to the open query on one of their dates. One reply
-- per round; it is never overwritten.
CREATE OR REPLACE FUNCTION timesheet_query_respond(p_date DATE, p_response TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_me UUID := auth_profile_id();
  v_org UUID := auth_org_id();
  q timesheet_day_queries%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Not signed in.' USING ERRCODE = '42501'; END IF;
  IF length(btrim(COALESCE(p_response, ''))) < 3 THEN
    RAISE EXCEPTION 'Write a reply first.' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO q FROM timesheet_day_queries
   WHERE organization_id = v_org AND profile_id = v_me AND work_date = p_date AND status IN ('open', 'responded')
   ORDER BY round DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'There is no open query on that date.' USING ERRCODE = '22023';
  END IF;
  IF q.response IS NOT NULL THEN
    RAISE EXCEPTION 'You have already replied to this query. Resubmit the day to send it back to your approver.'
      USING ERRCODE = '22023';
  END IF;
  UPDATE timesheet_day_queries SET response = btrim(p_response), responded_at = now(), status = 'responded'
   WHERE id = q.id;
  PERFORM approval_log(v_org, 'timesheet', v_me || ':' || p_date, v_me, 'responded', 'queried', 'queried',
                       v_me, btrim(p_response), jsonb_build_object('date', p_date, 'round', q.round));
END;
$$;
REVOKE ALL ON FUNCTION timesheet_query_respond(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION timesheet_query_respond(date, text) TO authenticated;

-- An approver explicitly resolves the open query on a date and approves the
-- date in the same step (pending and queried entries of that date only).
CREATE OR REPLACE FUNCTION timesheet_resolve_and_approve_day(p_profile UUID, p_date DATE, p_note TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_me UUID := auth_profile_id();
  v_org UUID := auth_org_id();
  v_round INT;
BEGIN
  IF NOT approval_can_decide(p_profile) THEN
    RAISE EXCEPTION 'You cannot decide this timesheet.' USING ERRCODE = '42501';
  END IF;
  IF length(btrim(COALESCE(p_note, ''))) < 3 THEN
    RAISE EXCEPTION 'Say how the query was resolved.' USING ERRCODE = '22023';
  END IF;
  UPDATE timesheet_day_queries
     SET status = 'closed', resolution = 'resolved_by_approver', resolution_note = btrim(p_note),
         resolved_by = v_me, resolved_at = now()
   WHERE organization_id = v_org AND profile_id = p_profile AND work_date = p_date AND status <> 'closed'
  RETURNING round INTO v_round;
  PERFORM approval_log(v_org, 'timesheet', p_profile || ':' || p_date, p_profile, 'resolved', 'queried', 'queried',
                       v_me, btrim(p_note), jsonb_build_object('date', p_date, 'round', v_round));
  -- Runs as the function owner, so guard_timesheet_entry is not consulted;
  -- the checks it would make are the ones above (decider, not yourself) and
  -- the content is not touched. Other triggers (task completion, history,
  -- notifications) fire as usual.
  UPDATE timesheet_entries
     SET status = 'approved', decided_by = v_me, decided_at = now()
   WHERE organization_id = v_org AND profile_id = p_profile
     AND COALESCE(entry_date, week_start_date + day_index) = p_date
     AND status IN ('pending', 'queried');
END;
$$;
REVOKE ALL ON FUNCTION timesheet_resolve_and_approve_day(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION timesheet_resolve_and_approve_day(uuid, date, text) TO authenticated;

COMMIT;
