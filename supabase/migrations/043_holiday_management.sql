-- ==============================================================================
-- 043: HOLIDAY MANAGEMENT
-- ==============================================================================
-- Holidays are organization-wide (one list for every company of the
-- organization) and already shown in every employee's calendar. Until now they
-- could only be added by a migration (017). The app now lets Partners add,
-- edit and delete them.
--
--   * New columns: description (optional, <= 500), created_by, updated_by,
--     updated_at. name must be 1–100 characters after trimming.
--   * Duplicates: one holiday per date per organization — the existing
--     UNIQUE (organization_id, holiday_date) from 001, unchanged.
--   * Access (RLS) unchanged from 036: every member of the organization reads;
--     only Partners (auth_rank() >= 90) write, within their own organization.
--   * Past dates are locked for API users (trg_guard_holiday_change): a
--     holiday dated today or earlier cannot be added, moved or deleted, and a
--     holiday cannot be moved onto such a date. Its name and description stay
--     editable. Attendance status and earned leave for those days are already
--     settled (record_holiday_worked, 017, credits earned leave only when time
--     or a punch is saved). "Today" is the organization's notification
--     timezone (default Asia/Kolkata). Service-role / migration writes are
--     exempt, so the yearly seed keeps working.
--
-- Additive: existing rows and the installed app are unaffected.
-- Safe to re-run.
-- ==============================================================================

ALTER TABLE holidays ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE holidays ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE holidays ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE holidays ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE holidays DROP CONSTRAINT IF EXISTS chk_holidays_name;
ALTER TABLE holidays ADD CONSTRAINT chk_holidays_name CHECK (length(btrim(name)) BETWEEN 1 AND 100);
ALTER TABLE holidays DROP CONSTRAINT IF EXISTS chk_holidays_description;
ALTER TABLE holidays ADD CONSTRAINT chk_holidays_description CHECK (description IS NULL OR length(description) <= 500);

ALTER TABLE holidays DROP CONSTRAINT IF EXISTS fk_holidays_created_by;
ALTER TABLE holidays ADD CONSTRAINT fk_holidays_created_by
  FOREIGN KEY (organization_id, created_by) REFERENCES profiles(organization_id, id) ON DELETE SET NULL (created_by);
ALTER TABLE holidays DROP CONSTRAINT IF EXISTS fk_holidays_updated_by;
ALTER TABLE holidays ADD CONSTRAINT fk_holidays_updated_by
  FOREIGN KEY (organization_id, updated_by) REFERENCES profiles(organization_id, id) ON DELETE SET NULL (updated_by);

DROP TRIGGER IF EXISTS trg_holidays_updated_at ON holidays;
CREATE TRIGGER trg_holidays_updated_at BEFORE UPDATE ON holidays
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- "Today" for an organization, in its notification timezone.
CREATE OR REPLACE FUNCTION org_today(p_org UUID)
RETURNS DATE
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (now() AT TIME ZONE COALESCE(
            (SELECT s.timezone FROM notification_settings s WHERE s.organization_id = p_org),
            'Asia/Kolkata'))::date;
$$;

CREATE OR REPLACE FUNCTION guard_holiday_change()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today DATE;
BEGIN
  IF auth.uid() IS NULL THEN            -- service role / migrations / seeds
    RETURN COALESCE(NEW, OLD);
  END IF;
  v_today := org_today(COALESCE(NEW.organization_id, OLD.organization_id));

  IF TG_OP = 'DELETE' THEN
    IF OLD.holiday_date <= v_today THEN
      RAISE EXCEPTION 'A holiday dated today or earlier cannot be deleted — attendance and earned leave for it are already recorded.'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.holiday_date <= v_today THEN
      RAISE EXCEPTION 'Holidays can only be added for future dates.' USING ERRCODE = '22023';
    END IF;
    NEW.created_by := auth_profile_id();
    NEW.updated_by := NEW.created_by;
  ELSE
    IF NEW.holiday_date IS DISTINCT FROM OLD.holiday_date
       AND (OLD.holiday_date <= v_today OR NEW.holiday_date <= v_today) THEN
      RAISE EXCEPTION 'A holiday can only be moved from one future date to another — edit just its name or description.'
        USING ERRCODE = '22023';
    END IF;
    NEW.created_by := OLD.created_by;
    NEW.updated_by := auth_profile_id();
  END IF;
  NEW.name := btrim(NEW.name);
  NEW.description := NULLIF(btrim(COALESCE(NEW.description, '')), '');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_holiday_change ON holidays;
CREATE TRIGGER trg_guard_holiday_change
  BEFORE INSERT OR UPDATE OR DELETE ON holidays
  FOR EACH ROW EXECUTE FUNCTION guard_holiday_change();

REVOKE ALL ON FUNCTION guard_holiday_change() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION org_today(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION org_today(uuid) TO authenticated;
