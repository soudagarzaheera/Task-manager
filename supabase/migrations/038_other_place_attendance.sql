-- 038_other_place_attendance.sql
--
-- "Other Place" attendance: an employee may punch from their current GPS
-- position (client visit, department visit, bank, ...) without that position
-- being a registered office site. Only the registered-site geofence is
-- bypassed; nothing else is.
--
-- Inspected first (repo + live DB, 2026-10-31): attendance_punches has
-- location_id (nullable FK to locations), place_label NOT NULL, latitude,
-- longitude, distance_meters, is_within_geofence, needs_review,
-- accuracy_meters (006). No company column — the employee's company came
-- from profiles. trg_validate_attendance_site_punch (012, 037) requires a
-- site for every API insert.
--
-- Schema changes (all additive; no row is deleted, no existing value changed
-- except the new columns being filled):
--   location_type     TEXT NOT NULL DEFAULT 'site', CHECK IN ('site','other').
--                     Every existing row becomes 'site' (what it was).
--   location_note     TEXT NULL (<= 200 chars) — optional description, Other Place only.
--   resolved_address  TEXT NULL (<= 500 chars) — reverse-geocoded address, Other Place only.
--   company_id        UUID NOT NULL, FK (organization_id, company_id) -> companies.
--                     The employee's company AT PUNCH TIME, set by the server from
--                     profiles.company_id (any client value is overwritten).
--                     Existing rows are backfilled from the employee's current
--                     profiles.company_id — the same value reports already use today.
--   CHECK: an 'other' punch never references a site (location_id IS NULL).
--   No permanent locations row is ever created for an Other Place.
--
-- Server-side validation (validate_attendance_site_punch, replaces 037's):
--   both types : own punch only; active employee of the punch's organization;
--                latitude/longitude present and in range; company_id from profile;
--                one punch-in and one punch-out per employee per day, out only
--                after in (the app's existing in -> out -> done rule, now also
--                enforced by the server so the API cannot add a second record).
--   'site'     : unchanged from 037 — active site of the same organization, inside
--                its radius; distance/label/geofence flag set by the server;
--                note/address cleared.
--   'other'    : GPS accuracy required (>= 0); location_id forced NULL;
--                place_label 'Other Place'; distance NULL; is_within_geofence false
--                (it was not checked against a fence); needs_review false;
--                note/address trimmed, blank -> NULL.
--
-- Read access (attendance_punches_select, replaces 036 B6's): own punches, or
-- Senior Executive and above (rank >= 50, the app's CAN.seeTeamAtt) for people
-- they can already see (auth_profile_visible — company scope unchanged).
-- Before this, any employee could read colleagues' punch rows including
-- coordinates; no screen below rank 50 uses them.
-- Insert policy (own punches) unchanged; no update/delete policy (036 B6).
--
-- Depends on 036 and 037. Re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/038_other_place_attendance.sql

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                   AND tablename = 'attendance_punches' AND policyname = 'attendance_punches_insert')
     OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND table_name = 'locations' AND column_name = 'company_id' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION '038 requires 036_rbac_parity_and_hardening.sql and 037_org_wide_sites.sql to be applied first.';
  END IF;
END $$;

-- 1. Columns ------------------------------------------------------------------
ALTER TABLE attendance_punches ADD COLUMN IF NOT EXISTS location_type TEXT NOT NULL DEFAULT 'site';
ALTER TABLE attendance_punches ADD COLUMN IF NOT EXISTS location_note TEXT;
ALTER TABLE attendance_punches ADD COLUMN IF NOT EXISTS resolved_address TEXT;
ALTER TABLE attendance_punches ADD COLUMN IF NOT EXISTS company_id UUID;

UPDATE attendance_punches a
SET company_id = p.company_id
FROM profiles p
WHERE a.company_id IS NULL AND p.id = a.profile_id AND p.organization_id = a.organization_id;

ALTER TABLE attendance_punches ALTER COLUMN company_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_punches_location_type') THEN
    ALTER TABLE attendance_punches ADD CONSTRAINT chk_punches_location_type
      CHECK (location_type IN ('site', 'other'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_punches_other_no_site') THEN
    ALTER TABLE attendance_punches ADD CONSTRAINT chk_punches_other_no_site
      CHECK (location_type <> 'other' OR location_id IS NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_punches_note_len') THEN
    ALTER TABLE attendance_punches ADD CONSTRAINT chk_punches_note_len
      CHECK (location_note IS NULL OR char_length(location_note) <= 200);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_punches_address_len') THEN
    ALTER TABLE attendance_punches ADD CONSTRAINT chk_punches_address_len
      CHECK (resolved_address IS NULL OR char_length(resolved_address) <= 500);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_punches_company') THEN
    ALTER TABLE attendance_punches ADD CONSTRAINT fk_punches_company
      FOREIGN KEY (organization_id, company_id) REFERENCES companies(organization_id, id) ON DELETE RESTRICT;
  END IF;
END $$;

COMMENT ON COLUMN attendance_punches.location_type IS 'site = registered office site (geofenced); other = Other Place (GPS recorded, no geofence).';
COMMENT ON COLUMN attendance_punches.company_id IS 'Employee''s company at punch time, set by trg_validate_attendance_site_punch. Pre-038 rows: backfilled from profiles.company_id.';

CREATE INDEX IF NOT EXISTS idx_attendance_profile_date ON attendance_punches (profile_id, punch_date);
CREATE INDEX IF NOT EXISTS idx_attendance_company_date ON attendance_punches (organization_id, company_id, punch_date);

-- 2. Server-side validation ---------------------------------------------------------
CREATE OR REPLACE FUNCTION validate_attendance_site_punch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  site locations%ROWTYPE;
  employee_company UUID;
  measured_distance NUMERIC;
BEGIN
  IF NEW.profile_id IS DISTINCT FROM auth_profile_id() THEN
    RAISE EXCEPTION 'You can only record your own attendance.' USING ERRCODE = '42501';
  END IF;

  NEW.location_type := COALESCE(NEW.location_type, 'site');
  IF NEW.location_type NOT IN ('site', 'other') THEN
    RAISE EXCEPTION 'Unknown attendance location type.' USING ERRCODE = '22023';
  END IF;

  IF NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
    RAISE EXCEPTION 'Your current GPS coordinates are required.' USING ERRCODE = '22023';
  END IF;
  IF NEW.latitude NOT BETWEEN -90 AND 90 OR NEW.longitude NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'The GPS coordinates are not valid.' USING ERRCODE = '22023';
  END IF;

  -- Active employee of this organization; record their company (never the client's value).
  SELECT p.company_id INTO employee_company
  FROM profiles p
  WHERE p.id = NEW.profile_id
    AND p.organization_id = NEW.organization_id
    AND p.is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only active employees of this organization can record attendance.' USING ERRCODE = '42501';
  END IF;
  NEW.company_id := employee_company;

  -- One punch-in and one punch-out per day, out only after in (the app's rule).
  -- Only on INSERT: the trigger also fires on UPDATE, which the API cannot do (036 B6).
  IF TG_OP = 'INSERT' THEN
    PERFORM pg_advisory_xact_lock(hashtext('attendance:' || NEW.profile_id::text || ':' || NEW.punch_date::text));
    IF NEW.punch_type = 'in' AND EXISTS (
         SELECT 1 FROM attendance_punches a
         WHERE a.profile_id = NEW.profile_id AND a.punch_date = NEW.punch_date) THEN
      RAISE EXCEPTION 'You have already punched in for %.', NEW.punch_date USING ERRCODE = '23505';
    END IF;
    IF NEW.punch_type = 'out' THEN
      IF NOT EXISTS (SELECT 1 FROM attendance_punches a
                     WHERE a.profile_id = NEW.profile_id AND a.punch_date = NEW.punch_date
                       AND a.punch_type = 'in') THEN
        RAISE EXCEPTION 'Punch in before punching out.' USING ERRCODE = '22023';
      END IF;
      IF EXISTS (SELECT 1 FROM attendance_punches a
                 WHERE a.profile_id = NEW.profile_id AND a.punch_date = NEW.punch_date
                   AND a.punch_type = 'out') THEN
        RAISE EXCEPTION 'You have already punched out for %.', NEW.punch_date USING ERRCODE = '23505';
      END IF;
    END IF;
  END IF;

  IF NEW.location_type = 'other' THEN
    -- Other Place: the GPS fix is recorded as-is; no registered-site geofence.
    IF NEW.accuracy_meters IS NULL OR NEW.accuracy_meters < 0 THEN
      RAISE EXCEPTION 'GPS accuracy is required for an Other Place punch.' USING ERRCODE = '22023';
    END IF;
    NEW.location_id := NULL;
    NEW.place_label := 'Other Place';
    NEW.distance_meters := NULL;
    NEW.is_within_geofence := false;
    NEW.needs_review := false;
    NEW.location_note := NULLIF(btrim(NEW.location_note), '');
    NEW.resolved_address := NULLIF(btrim(NEW.resolved_address), '');
    RETURN NEW;
  END IF;

  -- Registered site (unchanged from 037).
  IF NEW.location_id IS NULL THEN
    RAISE EXCEPTION 'A selected site and current GPS coordinates are required.' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO site
  FROM locations l
  WHERE l.id = NEW.location_id
    AND l.organization_id = NEW.organization_id
    AND l.is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The selected site is not active or does not exist.' USING ERRCODE = '22023';
  END IF;

  measured_distance := 6371000 * 2 * asin(sqrt(
    power(sin(radians(site.latitude - NEW.latitude) / 2), 2) +
    cos(radians(NEW.latitude)) * cos(radians(site.latitude)) *
    power(sin(radians(site.longitude - NEW.longitude) / 2), 2)
  ));
  IF measured_distance > site.radius_meters THEN
    RAISE EXCEPTION 'Outside the allowed radius for site %: distance % m, radius % m.',
      site.label, round(measured_distance), site.radius_meters USING ERRCODE = '22023';
  END IF;

  NEW.distance_meters := measured_distance;
  NEW.location_id := site.id;
  NEW.place_label := site.label;
  NEW.is_within_geofence := true;
  NEW.needs_review := false;
  NEW.location_note := NULL;
  NEW.resolved_address := NULL;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION validate_attendance_site_punch() FROM PUBLIC, anon, authenticated;

-- Fire on every column the validation reads or sets (012's list + the new ones).
DROP TRIGGER IF EXISTS trg_validate_attendance_site_punch ON attendance_punches;
CREATE TRIGGER trg_validate_attendance_site_punch
  BEFORE INSERT OR UPDATE OF profile_id, location_id, latitude, longitude, organization_id,
    location_type, accuracy_meters, company_id, location_note, resolved_address, punch_type, punch_date
  ON attendance_punches
  FOR EACH ROW EXECUTE FUNCTION validate_attendance_site_punch();

-- 3. Read access: own punches, or rank >= 50 for people already visible -------------
DROP POLICY IF EXISTS attendance_punches_select ON attendance_punches;
CREATE POLICY attendance_punches_select ON attendance_punches FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR (auth_rank() >= 50 AND auth_profile_visible(profile_id))));

COMMIT;
