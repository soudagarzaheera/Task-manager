-- Close the race between duplicate auth callbacks/session restoration and the
-- one-time first-user gate. The same authenticated caller may safely receive
-- their already-created profile; all other callers remain blocked once any
-- organization/profile exists.
CREATE OR REPLACE FUNCTION bootstrap_first_admin(
  org_name text, admin_full_name text, admin_employee_code text
)
RETURNS profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  new_org_id uuid;
  new_company_id uuid;
  new_profile profiles;
  caller_email text;
  clean_org_name text := trim(coalesce(org_name, ''));
  clean_admin_name text := trim(coalesce(admin_full_name, ''));
  clean_employee_code text := trim(coalesce(admin_employee_code, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  -- Serialize first-user requests. The database state, not a client supplied
  -- email or user ID, decides who may create the primary Partner profile.
  PERFORM pg_advisory_xact_lock(hashtext('public.bootstrap_first_admin'));

  -- Repeated calls from this same account return its existing row without
  -- creating another organization, company, or profile.
  SELECT * INTO new_profile FROM profiles WHERE auth_user_id = auth.uid() LIMIT 1;
  IF FOUND THEN
    RETURN new_profile;
  END IF;

  IF EXISTS (SELECT 1 FROM organizations) OR EXISTS (SELECT 1 FROM profiles) THEN
    RAISE EXCEPTION 'This system has already been set up.';
  END IF;
  IF clean_org_name = '' THEN
    RAISE EXCEPTION 'Organization name is required.';
  END IF;
  IF clean_admin_name = '' THEN
    RAISE EXCEPTION 'Your name is required.';
  END IF;
  IF clean_employee_code = '' THEN
    RAISE EXCEPTION 'An employee code is required.';
  END IF;

  SELECT email INTO caller_email FROM auth.users WHERE id = auth.uid();

  INSERT INTO organizations (name)
  VALUES (clean_org_name)
  RETURNING id INTO new_org_id;

  INSERT INTO companies (organization_id, code, name)
  VALUES (new_org_id, clean_org_name, clean_org_name)
  RETURNING id INTO new_company_id;

  INSERT INTO profiles (
    organization_id, auth_user_id, employee_code, full_name, contact_email,
    role, joining_date, is_active, company, company_id
  ) VALUES (
    new_org_id, auth.uid(), clean_employee_code, clean_admin_name, caller_email,
    'partner', CURRENT_DATE, true, clean_org_name, new_company_id
  ) RETURNING * INTO new_profile;

  RETURN new_profile;
END;
$$;

REVOKE ALL ON FUNCTION bootstrap_first_admin(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION bootstrap_first_admin(text, text, text) TO authenticated;
