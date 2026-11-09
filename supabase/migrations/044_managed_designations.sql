-- ==============================================================================
-- 044: MANAGED DESIGNATIONS
-- ==============================================================================
-- Until now a designation WAS profiles.role: a fixed list of 7 that is also
-- the permission level (auth_rank(), profile_rank(), every RLS policy and
-- every role = 'partner' check). Firms want their own titles ("Audit
-- Executive", "Senior Manager — Tax", …) without touching permissions.
--
-- designations (one list per organization)
--   name         — the title shown for the employee (unique per organization)
--   access_role  — one of the 7 permission levels; what the employee can do.
--                  Fixed once created (create a new designation instead).
--   is_builtin   — the 7 existing designations, seeded for every organization
--                  under their current names; read-only.
--   is_active / sort_order
--
-- profiles.designation_id → designations. profiles.role stays the permission
-- level and is kept equal to the designation's access_role by
-- trg_profiles_designation_sync:
--   * designation_id set/changed  → role := its access_role (must be active,
--     same organization)
--   * only role set/changed (create-employee, an older app) → designation_id
--     := the built-in designation of that role (NULL for legacy accounts/admin)
-- So no permission check changes, and EXISTING EMPLOYEES KEEP THEIR ROLE AND
-- PERMISSIONS: they are linked to the built-in designation matching their
-- current role, with the same name they show today.
--
-- Who manages the list (RLS + guard, mirrored by CAN.manageDesignations /
-- CAN.editDesignation in index.html):
--   read                    — every member of the organization
--   add / rename / reorder / (de)activate / delete
--                           — Partner, Manager, Assistant Manager
--                             (auth_rank() >= 60); a non-partner only for
--                             access levels BELOW their own; never a built-in
--   delete                  — only while no employee (including deleted ones,
--                             whose history is kept) has it
-- Assigning a designation to an employee is unchanged: Partners only
-- (profiles_update, 003/028).
--
-- Safe to re-run.
-- ==============================================================================

-- ---- 1. rank of an access role (same numbers as auth_rank(), 030) -------------
CREATE OR REPLACE FUNCTION role_rank(p_role TEXT)
RETURNS INT
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_role
    WHEN 'partner' THEN 90 WHEN 'manager' THEN 70 WHEN 'assistant_manager' THEN 60
    WHEN 'senior_executive' THEN 50 WHEN 'accounts' THEN 40 WHEN 'senior_associate' THEN 30
    WHEN 'associate' THEN 20 WHEN 'trainee' THEN 10
    ELSE 0 END;
$$;

-- ---- 2. table ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS designations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  access_role TEXT NOT NULL,
  is_builtin BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_by UUID,
  updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_designations_org_id UNIQUE (organization_id, id),
  CONSTRAINT chk_designations_name CHECK (length(btrim(name)) BETWEEN 2 AND 60),
  CONSTRAINT chk_designations_access_role CHECK (access_role IN (
    'trainee', 'associate', 'senior_associate', 'senior_executive',
    'assistant_manager', 'manager', 'partner')),
  CONSTRAINT fk_designations_created_by FOREIGN KEY (organization_id, created_by)
    REFERENCES profiles(organization_id, id) ON DELETE SET NULL (created_by),
  CONSTRAINT fk_designations_updated_by FOREIGN KEY (organization_id, updated_by)
    REFERENCES profiles(organization_id, id) ON DELETE SET NULL (updated_by)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_designations_org_name ON designations (organization_id, lower(btrim(name)));
CREATE UNIQUE INDEX IF NOT EXISTS uq_designations_builtin ON designations (organization_id, access_role) WHERE is_builtin;

DROP TRIGGER IF EXISTS trg_designations_updated_at ON designations;
CREATE TRIGGER trg_designations_updated_at BEFORE UPDATE ON designations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ---- 3. built-in designations: existing organizations now, new ones by trigger ----
-- The 7 designations the app has always offered, under their current names
-- (ROLE_LABEL in index.html). Nothing new is invented here.
CREATE OR REPLACE FUNCTION seed_builtin_designations(p_org UUID)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO designations (organization_id, name, access_role, is_builtin, sort_order)
  SELECT p_org, d.name, d.role, true, role_rank(d.role)
  FROM (VALUES
    ('Trainee', 'trainee'), ('Associate', 'associate'), ('Senior Associate', 'senior_associate'),
    ('Senior Executive', 'senior_executive'), ('Assistant Manager', 'assistant_manager'),
    ('Manager', 'manager'), ('Partner', 'partner')
  ) AS d(name, role)
  WHERE NOT EXISTS (SELECT 1 FROM designations x
                    WHERE x.organization_id = p_org AND x.is_builtin AND x.access_role = d.role)
  ON CONFLICT DO NOTHING;
$$;

CREATE OR REPLACE FUNCTION seed_designations_for_org()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM seed_builtin_designations(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_designations ON organizations;
CREATE TRIGGER trg_seed_designations
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION seed_designations_for_org();

SELECT seed_builtin_designations(o.id) FROM organizations o;

-- ---- 4. profiles.designation_id + backfill (before the sync trigger exists) -------
DROP TRIGGER IF EXISTS trg_profiles_designation_sync ON profiles;

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS designation_id UUID;
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS fk_profiles_designation;
ALTER TABLE profiles ADD CONSTRAINT fk_profiles_designation
  FOREIGN KEY (organization_id, designation_id) REFERENCES designations(organization_id, id);
  -- NO ACTION (checked at the end of the statement): a used designation cannot
  -- be deleted, but deleting a whole organization still cascades cleanly.
CREATE INDEX IF NOT EXISTS idx_profiles_designation ON profiles (organization_id, designation_id);

-- role is not touched: each employee gets the built-in designation of the role
-- they already have. Legacy accounts/admin profiles stay without one.
UPDATE profiles p
   SET designation_id = d.id
  FROM designations d
 WHERE p.designation_id IS NULL
   AND d.organization_id = p.organization_id AND d.is_builtin AND d.access_role = p.role;

-- ---- 5. keep profiles.role and designation_id in step ------------------------------
CREATE OR REPLACE FUNCTION sync_profile_designation()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_d designations%ROWTYPE;
BEGIN
  IF NEW.designation_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.designation_id IS DISTINCT FROM OLD.designation_id) THEN
    SELECT * INTO v_d FROM designations
     WHERE id = NEW.designation_id AND organization_id = NEW.organization_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That designation does not belong to this organization.' USING ERRCODE = '23503';
    END IF;
    IF NOT v_d.is_active THEN
      RAISE EXCEPTION 'The designation "%" is inactive — choose an active designation.', v_d.name USING ERRCODE = '22023';
    END IF;
    NEW.role := v_d.access_role;                 -- the designation decides the permission level
  ELSIF TG_OP = 'INSERT' OR NEW.role IS DISTINCT FROM OLD.role THEN
    -- Only the role was given (create-employee, an older app): follow it with
    -- the built-in designation of that role (none for legacy roles).
    SELECT id INTO NEW.designation_id FROM designations
     WHERE organization_id = NEW.organization_id AND is_builtin AND access_role = NEW.role;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_designation_sync
  BEFORE INSERT OR UPDATE OF role, designation_id ON profiles
  FOR EACH ROW EXECUTE FUNCTION sync_profile_designation();

-- ---- 6. who may change the list ------------------------------------------------------
-- May the signed-in user manage a designation with this access level?
CREATE OR REPLACE FUNCTION auth_can_manage_designation(p_access_role TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth_rank() >= 90 OR (auth_rank() >= 60 AND role_rank(p_access_role) < auth_rank());
$$;

ALTER TABLE designations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS designations_select ON designations;
DROP POLICY IF EXISTS designations_insert ON designations;
DROP POLICY IF EXISTS designations_update ON designations;
DROP POLICY IF EXISTS designations_delete ON designations;
CREATE POLICY designations_select ON designations FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
CREATE POLICY designations_insert ON designations FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND NOT is_builtin AND auth_can_manage_designation(access_role));
CREATE POLICY designations_update ON designations FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND NOT is_builtin AND auth_can_manage_designation(access_role))
  WITH CHECK (organization_id = auth_org_id() AND NOT is_builtin AND auth_can_manage_designation(access_role));
CREATE POLICY designations_delete ON designations FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND NOT is_builtin AND auth_can_manage_designation(access_role));

GRANT SELECT, INSERT, UPDATE, DELETE ON designations TO authenticated;
REVOKE ALL ON designations FROM anon;

-- Fixed fields, audit columns, and a clear message instead of a bare FK error.
CREATE OR REPLACE FUNCTION guard_designation_change()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n INT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF auth.uid() IS NULL THEN RETURN OLD; END IF;   -- e.g. an organization being deleted
    SELECT count(*) INTO n FROM profiles
     WHERE organization_id = OLD.organization_id AND designation_id = OLD.id;
    IF n > 0 THEN
      RAISE EXCEPTION '"%" is used by % employee(s) — deactivate it instead.', OLD.name, n USING ERRCODE = '23503';
    END IF;
    RETURN OLD;
  END IF;
  NEW.name := btrim(NEW.name);
  IF TG_OP = 'INSERT' THEN
    IF auth.uid() IS NOT NULL THEN
      NEW.created_by := auth_profile_id();
      NEW.updated_by := NEW.created_by;
    END IF;
    RETURN NEW;
  END IF;
  IF auth.uid() IS NOT NULL THEN
    IF NEW.access_role IS DISTINCT FROM OLD.access_role THEN
      RAISE EXCEPTION 'A designation''s access level cannot be changed — create a new designation instead.'
        USING ERRCODE = '42501';
    END IF;
    IF NEW.is_builtin IS DISTINCT FROM OLD.is_builtin OR NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
      RAISE EXCEPTION 'This field of a designation cannot be changed.' USING ERRCODE = '42501';
    END IF;
    NEW.created_by := OLD.created_by;
    NEW.updated_by := auth_profile_id();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_designation_change ON designations;
CREATE TRIGGER trg_guard_designation_change
  BEFORE INSERT OR UPDATE OR DELETE ON designations
  FOR EACH ROW EXECUTE FUNCTION guard_designation_change();

-- ---- 7. privileges -------------------------------------------------------------------
REVOKE ALL ON FUNCTION role_rank(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION role_rank(text) TO authenticated;
REVOKE ALL ON FUNCTION auth_can_manage_designation(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_can_manage_designation(text) TO authenticated;
REVOKE ALL ON FUNCTION seed_builtin_designations(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION seed_designations_for_org() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION sync_profile_designation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_designation_change() FROM PUBLIC, anon, authenticated;
