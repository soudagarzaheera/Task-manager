-- ==============================================================================
-- 045: OPTIONAL SATURDAYS / HOLIDAYS, EARNED-LEAVE CREDITS, TIMESHEET MINIMUM
-- ==============================================================================
-- Decisions (approved 2026-11-09):
--   * From 2026-11-01 (optional_days_rule_from()) every Saturday and every
--     declared holiday is an OPTIONAL working day. Punching is allowed (it
--     always was — nothing here blocks it). Not working is never an absence;
--     working counts as Present. Sundays keep the weekly-off rule unchanged.
--     Dates before 2026-11-01 keep the old rules (2nd/4th Saturday holiday,
--     other Saturdays mandatory) so past payroll does not change.
--   * Working an optional day earns exactly 1 Earned Leave (EL) day. It no
--     longer also pays an extra day's CTC (that is in index.html's payroll).
--   * A day qualifies only when attendance is complete: a punch-in AND a
--     punch-out on that date (the existing "Present" rule; geofence-flagged
--     days still count). The credit is posted when the punch-out is recorded.
--     A timesheet entry alone no longer earns EL (017's timesheet trigger is
--     removed). Sundays never earn it, even when a holiday falls on Sunday.
--   * One credit per employee per date: the existing UNIQUE
--     (organization_id, profile_id, worked_date) on earned_leave_transactions.
--     Every credit / removal is written to audit_logs.
--   * Timesheets: a submitted day needs >= 8 hours, or >= 4 hours when the
--     employee marked it a half day (timesheet_half_days) or has an approved
--     half-day leave that date. Checked when the owner submits (draft/queried
--     -> pending/approved) for entry dates from 2026-11-01. Approver actions
--     (approve, query, undo) are never blocked.
--
-- Re-runnable. Apply with: supabase db query --linked -f <this file>
-- ==============================================================================

-- 1. Rule start date and the day classifier ----------------------------------
CREATE OR REPLACE FUNCTION optional_days_rule_from()
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$ SELECT DATE '2026-11-01' $$;

-- 'holiday_worked' / 'saturday_worked' when working p_date earns EL, else NULL.
CREATE OR REPLACE FUNCTION extra_work_day_reason(p_org UUID, p_date DATE)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN p_date IS NULL OR p_date < optional_days_rule_from() THEN NULL
    WHEN EXTRACT(ISODOW FROM p_date) = 7 THEN NULL                       -- Sunday: weekly off, never credited
    WHEN EXISTS (SELECT 1 FROM holidays h
                 WHERE h.organization_id = p_org AND h.holiday_date = p_date) THEN 'holiday_worked'
    WHEN EXTRACT(ISODOW FROM p_date) = 6 THEN 'saturday_worked'
    ELSE NULL
  END;
$$;

-- Complete attendance day: a punch-in and a punch-out on that date.
CREATE OR REPLACE FUNCTION attendance_day_complete(p_org UUID, p_profile UUID, p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM attendance_punches a
                 WHERE a.organization_id = p_org AND a.profile_id = p_profile
                   AND a.punch_date = p_date AND a.punch_type = 'in')
     AND EXISTS (SELECT 1 FROM attendance_punches a
                 WHERE a.organization_id = p_org AND a.profile_id = p_profile
                   AND a.punch_date = p_date AND a.punch_type = 'out');
$$;

-- 2. Ledger: a reason on every credit -----------------------------------------
ALTER TABLE earned_leave_transactions ADD COLUMN IF NOT EXISTS reason TEXT;
UPDATE earned_leave_transactions e
SET reason = CASE
  WHEN e.holiday_id IS NOT NULL
    OR EXISTS (SELECT 1 FROM holidays h WHERE h.organization_id = e.organization_id AND h.holiday_date = e.worked_date)
  THEN 'holiday_worked' ELSE 'saturday_worked' END
WHERE e.reason IS NULL;
ALTER TABLE earned_leave_transactions ALTER COLUMN reason SET NOT NULL;
ALTER TABLE earned_leave_transactions DROP CONSTRAINT IF EXISTS chk_earned_leave_reason;
ALTER TABLE earned_leave_transactions ADD CONSTRAINT chk_earned_leave_reason
  CHECK (reason IN ('saturday_worked', 'holiday_worked'));
COMMENT ON COLUMN earned_leave_transactions.reason IS
  'Why 1 EL day was credited: saturday_worked or holiday_worked (045).';

-- 3. Posting a credit ----------------------------------------------------------
-- Returns true when a new credit row was written (false: not qualifying, or
-- already credited for that date — the UNIQUE key makes this idempotent).
CREATE OR REPLACE FUNCTION credit_extra_work_day(
  p_org UUID, p_profile UUID, p_date DATE, p_source_type TEXT, p_source_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reason TEXT := extra_work_day_reason(p_org, p_date);
  v_holiday UUID;
  v_id UUID;
BEGIN
  IF v_reason IS NULL OR NOT attendance_day_complete(p_org, p_profile, p_date) THEN
    RETURN false;
  END IF;
  SELECT h.id INTO v_holiday FROM holidays h
  WHERE h.organization_id = p_org AND h.holiday_date = p_date;

  INSERT INTO earned_leave_transactions
    (organization_id, profile_id, worked_date, holiday_id, source_type, source_id, reason)
  VALUES (p_org, p_profile, p_date, v_holiday, p_source_type, p_source_id, v_reason)
  ON CONFLICT (organization_id, profile_id, worked_date) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN false; END IF;

  INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, new_values)
  VALUES (p_org, p_profile, 'earned_leave_credited', 'earned_leave_transactions', v_id::text,
          jsonb_build_object('profile_id', p_profile, 'worked_date', p_date, 'reason', v_reason,
                             'earned_days', 1, 'source_type', p_source_type, 'source_id', p_source_id));
  RETURN true;
END;
$$;

-- 4. Triggers: credit on punch-out; timesheets no longer credit ----------------
-- punch_date comes from the client; only a live punch (org's today, ±1 day for
-- time zones) earns a credit, so a back-dated insert cannot farm EL.
CREATE OR REPLACE FUNCTION record_attendance_holiday_worked()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_today DATE := org_today(NEW.organization_id);
BEGIN
  IF NEW.punch_type = 'out' AND NEW.punch_date BETWEEN v_today - 1 AND v_today + 1 THEN
    PERFORM credit_extra_work_day(NEW.organization_id, NEW.profile_id, NEW.punch_date, 'attendance', NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_attendance_holiday_worked ON attendance_punches;
CREATE TRIGGER trg_attendance_holiday_worked
  AFTER INSERT ON attendance_punches
  FOR EACH ROW EXECUTE FUNCTION record_attendance_holiday_worked();

DROP TRIGGER IF EXISTS trg_timesheet_holiday_worked ON timesheet_entries;
DROP FUNCTION IF EXISTS record_timesheet_holiday_worked();
DROP FUNCTION IF EXISTS record_holiday_worked(UUID, UUID, DATE, TEXT, UUID);

-- 5. Bring the ledger in line with the new rule from 2026-11-01 ---------------
-- (a) remove credits on/after the start date that the new rule does not
--     support (e.g. posted by 017 on a punch-in alone), with an audit row;
WITH removed AS (
  DELETE FROM earned_leave_transactions e
  WHERE e.worked_date >= optional_days_rule_from()
    AND (extra_work_day_reason(e.organization_id, e.worked_date) IS NULL
         OR NOT attendance_day_complete(e.organization_id, e.profile_id, e.worked_date))
  RETURNING e.*
)
INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, old_values)
SELECT r.organization_id, NULL, 'earned_leave_removed', 'earned_leave_transactions', r.id::text,
       to_jsonb(r) || jsonb_build_object('note', '045: does not qualify under the optional-day rule')
FROM removed r;

-- (b) credit qualifying days already worked since the start date.
WITH qualifying AS (
  SELECT DISTINCT a.organization_id, a.profile_id, a.punch_date AS worked_date
  FROM attendance_punches a
  WHERE a.punch_type = 'out'
    AND a.punch_date >= optional_days_rule_from()
    AND a.punch_date <= org_today(a.organization_id)
    AND extra_work_day_reason(a.organization_id, a.punch_date) IS NOT NULL
    AND attendance_day_complete(a.organization_id, a.profile_id, a.punch_date)
), added AS (
  INSERT INTO earned_leave_transactions
    (organization_id, profile_id, worked_date, holiday_id, source_type, source_id, reason)
  SELECT q.organization_id, q.profile_id, q.worked_date,
         (SELECT h.id FROM holidays h WHERE h.organization_id = q.organization_id AND h.holiday_date = q.worked_date),
         'backfill', NULL, extra_work_day_reason(q.organization_id, q.worked_date)
  FROM qualifying q
  ON CONFLICT (organization_id, profile_id, worked_date) DO NOTHING
  RETURNING *
)
INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, new_values)
SELECT a.organization_id, a.profile_id, 'earned_leave_credited', 'earned_leave_transactions', a.id::text,
       jsonb_build_object('profile_id', a.profile_id, 'worked_date', a.worked_date, 'reason', a.reason,
                          'earned_days', 1, 'source_type', 'backfill')
FROM added a;

-- 6. What the app reads (adds reason + when credited; same first two columns) -
DROP FUNCTION IF EXISTS holiday_worked_days();
CREATE FUNCTION holiday_worked_days()
RETURNS TABLE (profile_id UUID, holiday_date DATE, reason TEXT, credited_at TIMESTAMPTZ)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT elt.profile_id, elt.worked_date AS holiday_date, elt.reason, elt.created_at
  FROM earned_leave_transactions elt
  WHERE elt.organization_id = auth_org_id()
  ORDER BY elt.worked_date;
$$;

-- 7. Timesheet half days -------------------------------------------------------
CREATE TABLE IF NOT EXISTS timesheet_half_days (
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL,
  work_date DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, profile_id, work_date),
  CONSTRAINT fk_timesheet_half_days_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE CASCADE
);
COMMENT ON TABLE timesheet_half_days IS
  'Days an employee marked as a half day: the timesheet minimum for that date is 4 hours instead of 8 (045).';

ALTER TABLE timesheet_half_days ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS timesheet_half_days_select ON timesheet_half_days;
DROP POLICY IF EXISTS timesheet_half_days_insert ON timesheet_half_days;
DROP POLICY IF EXISTS timesheet_half_days_delete ON timesheet_half_days;
-- Same readers as timesheet_entries' owners/approvers; only the owner writes.
CREATE POLICY timesheet_half_days_select ON timesheet_half_days FOR SELECT TO authenticated
  USING (organization_id = auth_org_id()
         AND (profile_id = auth_profile_id() OR auth_profile_visible(profile_id)));
CREATE POLICY timesheet_half_days_insert ON timesheet_half_days FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id());
CREATE POLICY timesheet_half_days_delete ON timesheet_half_days FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND profile_id = auth_profile_id());
GRANT SELECT, INSERT, DELETE ON timesheet_half_days TO authenticated;

-- A day's half/full choice is fixed once time for it is submitted or approved.
CREATE OR REPLACE FUNCTION guard_timesheet_half_day()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r timesheet_half_days%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  IF EXISTS (SELECT 1 FROM timesheet_entries te
             WHERE te.organization_id = r.organization_id AND te.profile_id = r.profile_id
               AND te.entry_date = r.work_date AND te.status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'Time for % is already submitted — its half-day setting can no longer change.', r.work_date
      USING ERRCODE = '42501';
  END IF;
  RETURN r;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_timesheet_half_day ON timesheet_half_days;
CREATE TRIGGER trg_guard_timesheet_half_day
  BEFORE INSERT OR DELETE ON timesheet_half_days
  FOR EACH ROW EXECUTE FUNCTION guard_timesheet_half_day();

-- 8. Timesheet minimum hours on submission ------------------------------------
CREATE OR REPLACE FUNCTION enforce_timesheet_day_minimum()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_total NUMERIC;
  v_half BOOLEAN;
  v_min NUMERIC;
BEGIN
  -- Only the owner's own submission: draft/queried -> pending/approved.
  IF NEW.status NOT IN ('pending', 'approved') OR OLD.status IN ('pending', 'approved') THEN RETURN NULL; END IF;
  IF NEW.profile_id IS DISTINCT FROM auth_profile_id() THEN RETURN NULL; END IF;
  IF NEW.entry_date < optional_days_rule_from() THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(te.hours), 0) INTO v_total FROM timesheet_entries te
  WHERE te.organization_id = NEW.organization_id AND te.profile_id = NEW.profile_id
    AND te.entry_date = NEW.entry_date;
  v_half := EXISTS (SELECT 1 FROM timesheet_half_days hd
                    WHERE hd.organization_id = NEW.organization_id AND hd.profile_id = NEW.profile_id
                      AND hd.work_date = NEW.entry_date)
         OR EXISTS (SELECT 1 FROM leaves l
                    WHERE l.organization_id = NEW.organization_id AND l.profile_id = NEW.profile_id
                      AND l.leave_date = NEW.entry_date AND l.status = 'approved' AND l.duration_part = 'half');
  v_min := CASE WHEN v_half THEN 4 ELSE 8 END;
  IF v_total < v_min THEN
    RAISE EXCEPTION '%', CASE WHEN v_half
      THEN format('%s has %s hours — a half day needs at least 4 hours.', to_char(NEW.entry_date, 'Dy DD Mon YYYY'), trim_scale(v_total))
      ELSE format('%s has %s hours — a full day needs at least 8 hours. Mark it as a half day if you worked half a day (minimum 4 hours).',
                  to_char(NEW.entry_date, 'Dy DD Mon YYYY'), trim_scale(v_total)) END
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_timesheet_day_minimum ON timesheet_entries;
CREATE TRIGGER trg_timesheet_day_minimum
  AFTER UPDATE OF status ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_timesheet_day_minimum();

-- 9. Privileges ------------------------------------------------------------------
REVOKE ALL ON FUNCTION optional_days_rule_from() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION optional_days_rule_from() TO authenticated;
REVOKE ALL ON FUNCTION extra_work_day_reason(UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION attendance_day_complete(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION credit_extra_work_day(UUID, UUID, DATE, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_attendance_holiday_worked() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_timesheet_half_day() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enforce_timesheet_day_minimum() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION holiday_worked_days() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION holiday_worked_days() TO authenticated;
