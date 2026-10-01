-- ==============================================================================
-- 024: PARTNERS MAY BOOK BEYOND A JOB'S BUDGET
-- ==============================================================================
-- Refines 023. The hard limit (booked + new hours <= budgeted + approved
-- additional) now applies to every role EXCEPT an active partner booking
-- their own time — the entry's profile, not whoever runs the statement, is
-- what counts, so nobody else can book "as" a partner to get around it.
-- Partner hours still count toward the job's booked total, so they use up
-- the budget for everyone else. Budgets and existing entries are unchanged.
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

  -- Partners are not held to the budget for their own entries.
  IF EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.organization_id = NEW.organization_id AND p.id = NEW.profile_id
      AND p.role = 'partner' AND p.is_active
  ) THEN
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
