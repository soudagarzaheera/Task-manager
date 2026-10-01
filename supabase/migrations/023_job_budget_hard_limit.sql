-- ==============================================================================
-- 023: BUDGETED HOURS ARE A HARD LIMIT ON TIME ENTRY
-- ==============================================================================
-- A timesheet entry may only be recorded against a job while
--   hours already booked on the job (every entry, any status, anyone)
--   + this entry's hours
--   <= budgeted hours + approved additional hours (budget_requests, 022).
-- Additional hours count only once a request is APPROVED, so a pending
-- request does not unlock anything. jobs.budget_hours is never changed here.
--
-- Checked on INSERT, and on UPDATE only when hours or job_id change — so
-- submitting, approving, querying or undoing existing entries (status-only
-- updates) never trips it, and historical entries are left as they are
-- even where a job is already over its budget; such a job simply has no
-- room for more hours until additional hours are approved.
--
-- Overhead codes (jobs.is_overhead, e.g. FIRM/IDLE, FIRM/ADMIN) are internal
-- non-chargeable time sinks without a client budget and are not limited.
--
-- The job row is locked (FOR UPDATE) for the check, so two people booking
-- the same job at the same moment cannot both squeeze past the limit.
-- SECURITY DEFINER because decided budget_requests are not readable by most
-- employees (005); the function only reads rows of NEW's own organization.
-- ==============================================================================

CREATE OR REPLACE FUNCTION enforce_job_budget_limit()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  j_budget NUMERIC;
  j_overhead BOOLEAN;
  j_code TEXT;
  extra NUMERIC;
  booked NUMERIC;
  available NUMERIC;
  remaining NUMERIC;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.hours IS NOT DISTINCT FROM OLD.hours
     AND NEW.job_id IS NOT DISTINCT FROM OLD.job_id THEN
    RETURN NEW;
  END IF;

  SELECT budget_hours, is_overhead, job_code INTO j_budget, j_overhead, j_code
  FROM jobs
  WHERE organization_id = NEW.organization_id AND id = NEW.job_id
  FOR UPDATE;

  IF NOT FOUND OR j_overhead THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(to_hours - from_hours), 0) INTO extra
  FROM budget_requests
  WHERE organization_id = NEW.organization_id AND job_id = NEW.job_id AND status = 'approved';

  SELECT COALESCE(SUM(hours), 0) INTO booked
  FROM timesheet_entries
  WHERE organization_id = NEW.organization_id AND job_id = NEW.job_id
    AND (TG_OP = 'INSERT' OR id <> NEW.id);

  available := j_budget + extra;
  remaining := GREATEST(available - booked, 0);

  IF booked + NEW.hours > available THEN
    RAISE EXCEPTION 'Only % hour(s) remain for job %. Please request additional hours before recording more time.',
      trim(to_char(remaining, 'FM999990.##')), j_code
      USING ERRCODE = 'check_violation',
            DETAIL = format('Budgeted %s h + approved additional %s h = %s h available; %s h already booked; %s h requested.',
                            j_budget, extra, available, booked, NEW.hours);
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION enforce_job_budget_limit() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_timesheet_job_budget_limit ON timesheet_entries;
CREATE TRIGGER trg_timesheet_job_budget_limit
  BEFORE INSERT OR UPDATE OF hours, job_id ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_job_budget_limit();
