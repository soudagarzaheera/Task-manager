-- 037_org_wide_sites.sql
--
-- Office sites belong to the ORGANIZATION, not to one company.
--
-- Before (012 / 028 / 036):
--   * locations.company_id NOT NULL — every site had to name a company.
--   * locations RLS: auth_company_ok(company_id) — managers saw/managed only
--     their own company's sites; employees saw only their company's active sites.
--   * trg_validate_attendance_site_punch rejected a punch when the employee's
--     company <> site's company ("The selected site does not belong to your company.").
--
-- After:
--   * locations.company_id is nullable. New sites are saved without it.
--     Existing values are KEPT, unchanged — they are no longer used for access
--     or validation. Keeping them means installed older app builds (which still
--     filter punch sites by company on the client) keep working exactly as today
--     until they update. Nothing is deleted; no attendance row is touched.
--   * locations RLS: organization-wide. Any signed-in member sees the active
--     sites of their own organization; Assistant Manager and above (rank >= 60,
--     036 parity) see inactive sites too and add/edit/turn sites on or off.
--   * Punch validation: the employee must be an ACTIVE member of the punch's
--     organization, the site must be ACTIVE and in that SAME organization, and
--     the GPS fix must be inside the site's radius. The company comparison is
--     the only rule removed. Own-punch-only, GPS-required, the haversine radius
--     check, and the server-set distance/label/geofence flags are unchanged.
--
-- Unchanged on purpose:
--   * attendance_punches: no column or row changes. The employee's company is
--     identified as before, through profile_id -> profiles.company_id.
--     attendance_punches RLS (who can READ punches) still follows the
--     employee's company via auth_profile_visible(profile_id), so a manager of
--     Company B does not see Company A employees' punches just because they
--     punched at a shared site.
--   * fk_locations_company stays: a legacy company_id, when present, must still
--     be a company of the same organization.
--   * Organization isolation: RLS (organization_id = auth_org_id()), the
--     composite FKs (organization_id, location_id) / (organization_id,
--     profile_id), and the trigger's same-organization site lookup together
--     make a cross-organization punch impossible.
--
-- Depends on 036 (rank >= 60 for site management). Apply 036 first; this file
-- refuses to run otherwise. If 036 is ever re-run after this file, re-run this
-- file too (036 A3 re-creates the company-scoped site policies).
--
-- Re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/037_org_wide_sites.sql

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public' AND tablename = 'attendance_punches'
                   AND policyname = 'attendance_punches_insert') THEN
    RAISE EXCEPTION '037 requires 036_rbac_parity_and_hardening.sql to be applied first.';
  END IF;
END $$;

-- 1. Company is optional on a site (existing values preserved).
ALTER TABLE locations ALTER COLUMN company_id DROP NOT NULL;
COMMENT ON COLUMN locations.company_id IS
  'Legacy (pre-037). Sites are organization-wide; not used for access or punch validation. NULL for sites added after 037.';

CREATE INDEX IF NOT EXISTS idx_locations_org_active ON locations (organization_id, is_active);

-- 2. RLS: organization-wide sites.
DROP POLICY IF EXISTS locations_select ON locations;
CREATE POLICY locations_select ON locations FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (auth_rank() >= 60 OR is_active));

DROP POLICY IF EXISTS locations_insert ON locations;
CREATE POLICY locations_insert ON locations FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);

DROP POLICY IF EXISTS locations_update ON locations;
CREATE POLICY locations_update ON locations FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);

-- 3. Punch validation without the company comparison.
CREATE OR REPLACE FUNCTION validate_attendance_site_punch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  site locations%ROWTYPE;
  measured_distance NUMERIC;
BEGIN
  IF NEW.profile_id IS DISTINCT FROM auth_profile_id() THEN
    RAISE EXCEPTION 'You can only record your own attendance.' USING ERRCODE = '42501';
  END IF;
  IF NEW.location_id IS NULL OR NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
    RAISE EXCEPTION 'A selected site and current GPS coordinates are required.' USING ERRCODE = '22023';
  END IF;

  -- The employee must be an active member of the punch's organization.
  IF NOT EXISTS (SELECT 1 FROM profiles p
                 WHERE p.id = NEW.profile_id
                   AND p.organization_id = NEW.organization_id
                   AND p.is_active) THEN
    RAISE EXCEPTION 'Only active employees of this organization can record attendance.' USING ERRCODE = '42501';
  END IF;

  -- Any active site of that same organization, whatever company the employee is in.
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
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION validate_attendance_site_punch() FROM PUBLIC, anon, authenticated;
-- trg_validate_attendance_site_punch (012) already calls this function; not re-created.

COMMIT;
