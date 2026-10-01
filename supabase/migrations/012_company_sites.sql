-- Promote the existing company codes to org-scoped records, then attach
-- profiles and geofenced locations without replacing either table.
CREATE TABLE IF NOT EXISTS companies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_companies_org_code UNIQUE (organization_id, code),
  CONSTRAINT uq_companies_org_id UNIQUE (organization_id, id)
);

ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS companies_select ON companies;
CREATE POLICY companies_select ON companies FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());

-- Derive company records from the codes already assigned to profiles.
INSERT INTO companies (organization_id, code, name)
SELECT DISTINCT p.organization_id, trim(p.company), trim(p.company)
FROM profiles p
WHERE NULLIF(trim(p.company), '') IS NOT NULL
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO companies (organization_id, code, name)
SELECT o.id, o.name, o.name
FROM organizations o
WHERE NOT EXISTS (SELECT 1 FROM companies c WHERE c.organization_id = o.id)
ON CONFLICT (organization_id, code) DO NOTHING;

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS company_id UUID;
UPDATE profiles p
SET company_id = COALESCE(
  (SELECT c.id FROM companies c
   WHERE c.organization_id = p.organization_id
     AND c.code = NULLIF(trim(p.company), '') LIMIT 1),
  (SELECT c.id FROM companies c
   WHERE c.organization_id = p.organization_id
   ORDER BY c.created_at, c.id LIMIT 1)
)
WHERE p.company_id IS NULL;
ALTER TABLE profiles ALTER COLUMN company_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_profiles_company') THEN
    ALTER TABLE profiles ADD CONSTRAINT fk_profiles_company
      FOREIGN KEY (organization_id, company_id)
      REFERENCES companies(organization_id, id) ON DELETE RESTRICT;
  END IF;
END $$;

ALTER TABLE locations ADD COLUMN IF NOT EXISTS company_id UUID;
UPDATE locations l
SET company_id = COALESCE(
  (SELECT p.company_id
   FROM clients c
   JOIN profiles p ON p.id = c.relationship_partner_id
                  AND p.organization_id = c.organization_id
   WHERE c.id = l.client_id AND c.organization_id = l.organization_id),
  (SELECT c.id FROM companies c
   WHERE c.organization_id = l.organization_id
   ORDER BY c.created_at, c.id
   LIMIT 1)
)
WHERE l.company_id IS NULL;
ALTER TABLE locations ALTER COLUMN company_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_locations_company') THEN
    ALTER TABLE locations ADD CONSTRAINT fk_locations_company
      FOREIGN KEY (organization_id, company_id)
      REFERENCES companies(organization_id, id) ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_locations_company_active
  ON locations (organization_id, company_id, is_active);

-- Employees see only their own company's sites. Existing manager-and-above
-- site management remains available across the organization.
DROP POLICY IF EXISTS authenticated_org_access ON locations;
DROP POLICY IF EXISTS locations_select ON locations;
CREATE POLICY locations_select ON locations FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      auth_rank() >= 70
      OR (is_active AND company_id = (SELECT p.company_id FROM profiles p WHERE p.id = auth_profile_id()))
    )
  );

DROP POLICY IF EXISTS locations_insert ON locations;
CREATE POLICY locations_insert ON locations FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 70);

DROP POLICY IF EXISTS locations_update ON locations;
CREATE POLICY locations_update ON locations FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 70)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 70);

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
  IF NEW.location_id IS NULL OR NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
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

  SELECT p.company_id INTO employee_company
  FROM profiles p
  WHERE p.id = NEW.profile_id
    AND p.organization_id = NEW.organization_id
    AND p.is_active;
  IF employee_company IS NULL OR employee_company <> site.company_id THEN
    RAISE EXCEPTION 'The selected site does not belong to your company.' USING ERRCODE = '42501';
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

DROP TRIGGER IF EXISTS trg_validate_attendance_site_punch ON attendance_punches;
CREATE TRIGGER trg_validate_attendance_site_punch
  BEFORE INSERT OR UPDATE OF profile_id, location_id, latitude, longitude, organization_id
  ON attendance_punches
  FOR EACH ROW EXECUTE FUNCTION validate_attendance_site_punch();
