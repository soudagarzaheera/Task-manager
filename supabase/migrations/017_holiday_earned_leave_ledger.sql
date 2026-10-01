-- Seed the 2026 public holidays for current and future organizations.
CREATE OR REPLACE FUNCTION seed_2026_holidays_for_org()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO holidays (organization_id, holiday_date, name, is_mandatory)
  VALUES
    (NEW.id, DATE '2026-10-02', 'Mahatma Gandhi Jayanti', true),
    (NEW.id, DATE '2026-11-09', 'Saal Mubarak', true),
    (NEW.id, DATE '2026-11-11', 'Bhai Dooj', true)
  ON CONFLICT (organization_id, holiday_date) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_2026_holidays ON organizations;
CREATE TRIGGER trg_seed_2026_holidays
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION seed_2026_holidays_for_org();

INSERT INTO holidays (organization_id, holiday_date, name, is_mandatory)
SELECT o.id, h.holiday_date, h.name, true
FROM organizations o
CROSS JOIN (VALUES
  (DATE '2026-10-02', 'Mahatma Gandhi Jayanti'),
  (DATE '2026-11-09', 'Saal Mubarak'),
  (DATE '2026-11-11', 'Bhai Dooj')
) AS h(holiday_date, name)
ON CONFLICT (organization_id, holiday_date) DO NOTHING;

CREATE TABLE IF NOT EXISTS earned_leave_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL,
  worked_date DATE NOT NULL,
  holiday_id UUID REFERENCES holidays(id) ON DELETE SET NULL,
  source_type TEXT NOT NULL CHECK (source_type IN ('timesheet', 'attendance', 'backfill')),
  source_id UUID,
  earned_days NUMERIC(5,1) NOT NULL DEFAULT 1 CHECK (earned_days = 1),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_earned_leave_profile_date UNIQUE (organization_id, profile_id, worked_date),
  CONSTRAINT fk_earned_leave_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_earned_leave_profile_date
  ON earned_leave_transactions (organization_id, profile_id, worked_date);

ALTER TABLE earned_leave_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS earned_leave_transactions_select ON earned_leave_transactions;
CREATE POLICY earned_leave_transactions_select ON earned_leave_transactions FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());

CREATE OR REPLACE FUNCTION record_holiday_worked(
  p_organization_id UUID,
  p_profile_id UUID,
  p_worked_date DATE,
  p_source_type TEXT,
  p_source_id UUID
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  matched_holiday_id UUID;
BEGIN
  IF p_worked_date IS NULL OR p_worked_date > CURRENT_DATE THEN
    RETURN;
  END IF;

  SELECT h.id INTO matched_holiday_id
  FROM holidays h
  WHERE h.organization_id = p_organization_id
    AND h.holiday_date = p_worked_date;

  IF matched_holiday_id IS NULL AND NOT (
    EXTRACT(ISODOW FROM p_worked_date) = 6
    AND ((EXTRACT(DAY FROM p_worked_date)::INTEGER - 1) / 7 + 1) IN (2, 4)
  ) THEN
    RETURN;
  END IF;

  INSERT INTO earned_leave_transactions (
    organization_id, profile_id, worked_date, holiday_id, source_type, source_id
  ) VALUES (
    p_organization_id, p_profile_id, p_worked_date, matched_holiday_id, p_source_type, p_source_id
  )
  ON CONFLICT (organization_id, profile_id, worked_date) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION record_timesheet_holiday_worked()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM record_holiday_worked(NEW.organization_id, NEW.profile_id, NEW.entry_date, 'timesheet', NEW.id);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION record_attendance_holiday_worked()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM record_holiday_worked(NEW.organization_id, NEW.profile_id, NEW.punch_date, 'attendance', NEW.id);
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION seed_2026_holidays_for_org() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_holiday_worked(UUID, UUID, DATE, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_timesheet_holiday_worked() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_attendance_holiday_worked() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_timesheet_holiday_worked ON timesheet_entries;
CREATE TRIGGER trg_timesheet_holiday_worked
  AFTER INSERT OR UPDATE OF organization_id, profile_id, entry_date, hours ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION record_timesheet_holiday_worked();

DROP TRIGGER IF EXISTS trg_attendance_holiday_worked ON attendance_punches;
CREATE TRIGGER trg_attendance_holiday_worked
  AFTER INSERT OR UPDATE OF organization_id, profile_id, punch_date ON attendance_punches
  FOR EACH ROW EXECUTE FUNCTION record_attendance_holiday_worked();

-- Preserve earned credits already represented by holiday or Saturday work.
WITH worked_dates AS (
  SELECT ap.organization_id, ap.profile_id, ap.punch_date AS worked_date,
         'attendance'::TEXT AS source_type, ap.id AS source_id
  FROM attendance_punches ap
  WHERE ap.punch_date <= CURRENT_DATE
  UNION ALL
  SELECT te.organization_id, te.profile_id, te.entry_date,
         'timesheet'::TEXT, te.id
  FROM timesheet_entries te
  WHERE te.entry_date <= CURRENT_DATE AND te.hours > 0
), qualifying_dates AS (
  SELECT DISTINCT ON (wd.organization_id, wd.profile_id, wd.worked_date)
    wd.organization_id, wd.profile_id, wd.worked_date, wd.source_type, wd.source_id,
    h.id AS holiday_id
  FROM worked_dates wd
  LEFT JOIN holidays h
    ON h.organization_id = wd.organization_id AND h.holiday_date = wd.worked_date
  WHERE h.id IS NOT NULL OR (
    EXTRACT(ISODOW FROM wd.worked_date) = 6
    AND ((EXTRACT(DAY FROM wd.worked_date)::INTEGER - 1) / 7 + 1) IN (2, 4)
  )
  ORDER BY wd.organization_id, wd.profile_id, wd.worked_date, wd.source_type
)
INSERT INTO earned_leave_transactions (
  organization_id, profile_id, worked_date, holiday_id, source_type, source_id
)
SELECT organization_id, profile_id, worked_date, holiday_id, source_type, source_id
FROM qualifying_dates
ON CONFLICT (organization_id, profile_id, worked_date) DO NOTHING;

-- The client reads this list to derive balances and show earned-date history.
CREATE OR REPLACE FUNCTION holiday_worked_days()
RETURNS TABLE (profile_id UUID, holiday_date DATE)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT elt.profile_id, elt.worked_date AS holiday_date
  FROM earned_leave_transactions elt
  WHERE elt.organization_id = auth_org_id()
  ORDER BY elt.worked_date;
$$;

REVOKE ALL ON FUNCTION holiday_worked_days() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION holiday_worked_days() TO authenticated;