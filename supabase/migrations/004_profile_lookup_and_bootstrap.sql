-- ==============================================================================
-- FIX: POST-LOGIN PROFILE LOOKUP + FIRST-ADMIN BOOTSTRAP
-- ==============================================================================
-- Root cause this migration fixes:
--
-- 003_auth_integration.sql scoped every table (including `organizations`) to
-- the caller's own org via auth_org_id(), which resolves by looking up
-- profiles.organization_id WHERE auth_user_id = auth.uid(). That is correct
-- for an already-linked user, but for a Supabase Auth session that has no
-- matching `profiles` row yet (auth_user_id never set — e.g. an existing
-- employee profile created before this auth integration, or literally the
-- first person ever to sign in for real), auth_org_id() returns NULL. Every
-- RLS policy built on it then hides everything, including the organization
-- row that may perfectly well exist. The client's loadAppData() queried
-- `organizations` FIRST, saw zero rows because of that RLS gap, and reported
-- the misleading "No organization is set up in Supabase yet." — a message
-- that is only true for a genuinely empty database, not an unlinked session.
--
-- Fix: give the client a reliable, narrowly-scoped way to answer "is MY
-- session linked to a profile?" *before* it ever asks "what's in the
-- organizations table" — so it can tell an unlinked account (Case C — needs
-- an administrator to add them as an employee) apart from a truly fresh,
-- empty install (Case B — offer one-time organization setup).
-- ==============================================================================

-- ---- my_profile(): the caller's own profile row, independent of org RLS ------
-- Safe to expose broadly: the WHERE clause hard-codes auth.uid(), so it can
-- only ever return the caller's own row (or nothing).
CREATE OR REPLACE FUNCTION my_profile()
RETURNS SETOF profiles
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM profiles WHERE auth_user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION my_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION my_profile() TO authenticated;

-- ---- system_needs_bootstrap(): true only for a genuinely empty install -------
-- Existence-only check (no row contents leak), used purely to decide whether
-- to offer the one-time "set up your organization" screen. Once a single
-- organization or profile exists anywhere, this is permanently false — after
-- that, new people can only join through an administrator's Add Employee.
CREATE OR REPLACE FUNCTION system_needs_bootstrap()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT EXISTS (SELECT 1 FROM organizations) AND NOT EXISTS (SELECT 1 FROM profiles);
$$;

REVOKE ALL ON FUNCTION system_needs_bootstrap() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION system_needs_bootstrap() TO authenticated;

-- ---- bootstrap_first_admin(): the one-time self-service escape hatch ---------
-- Creates the organization and the caller's own partner profile together, but
-- only when the system is still empty (re-checked here, not just trusted from
-- a prior system_needs_bootstrap() call, to close the race). This is the only
-- path that ever lets an authenticated-but-unlinked user create a profile for
-- themselves — every other employee is created by an existing partner via the
-- create-employee Edge Function, never by this function.
CREATE OR REPLACE FUNCTION bootstrap_first_admin(
  org_name text, admin_full_name text, admin_employee_code text
)
RETURNS profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  new_org_id uuid;
  new_profile profiles;
  caller_email text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF EXISTS (SELECT 1 FROM organizations) OR EXISTS (SELECT 1 FROM profiles) THEN
    RAISE EXCEPTION 'This system has already been set up.';
  END IF;
  IF coalesce(trim(org_name), '') = '' THEN
    RAISE EXCEPTION 'Organization name is required.';
  END IF;
  IF coalesce(trim(admin_full_name), '') = '' THEN
    RAISE EXCEPTION 'Your name is required.';
  END IF;
  IF coalesce(trim(admin_employee_code), '') = '' THEN
    RAISE EXCEPTION 'An employee code is required.';
  END IF;

  SELECT email INTO caller_email FROM auth.users WHERE id = auth.uid();

  INSERT INTO organizations (name) VALUES (trim(org_name))
    RETURNING id INTO new_org_id;

  INSERT INTO profiles (
    organization_id, auth_user_id, employee_code, full_name, contact_email,
    role, joining_date, is_active
  ) VALUES (
    new_org_id, auth.uid(), trim(admin_employee_code), trim(admin_full_name), caller_email,
    'partner', CURRENT_DATE, true
  ) RETURNING * INTO new_profile;

  RETURN new_profile;
END;
$$;

REVOKE ALL ON FUNCTION bootstrap_first_admin(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bootstrap_first_admin(text, text, text) TO authenticated;
