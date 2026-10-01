-- Count each worked 2nd/4th Saturday once, whether the work was recorded by
-- attendance punches or by a timesheet entry. No existing attendance or
-- timesheet rows are changed.
CREATE OR REPLACE FUNCTION holiday_worked_days()
RETURNS TABLE (profile_id UUID, holiday_date DATE)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH worked_dates AS (
    SELECT ap.profile_id, ap.punch_date AS worked_on
    FROM attendance_punches ap
    WHERE ap.organization_id = auth_org_id()

    UNION

    SELECT te.profile_id, te.entry_date AS worked_on
    FROM timesheet_entries te
    WHERE te.organization_id = auth_org_id()
  )
  SELECT DISTINCT worked_dates.profile_id, worked_dates.worked_on AS holiday_date
  FROM worked_dates
  WHERE worked_on <= CURRENT_DATE
    AND EXTRACT(ISODOW FROM worked_on) = 6
    AND ((EXTRACT(DAY FROM worked_on)::INTEGER - 1) / 7 + 1) IN (2, 4);
$$;

REVOKE ALL ON FUNCTION holiday_worked_days() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION holiday_worked_days() TO authenticated;

-- The seeded 18-day EL default is not a starting balance. Preserve explicit
-- policy edits and per-employee balance overrides; Saturday work earns EL.
UPDATE leave_types
SET annual_days = 0
WHERE code = 'EL';
