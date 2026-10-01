-- Provision one isolated tenant for every direct signup. Unlike the original
-- first-install bootstrap, this does not depend on the database being globally
-- empty, so the SaaS can onboard multiple independent companies.
--
-- Invited employees already have a profile linked to auth.uid() and this RPC
-- returns that row without changing their role or organization. A caller with
-- no linked profile can create only their own new organization, company, and
-- Partner profile in one transaction.
CREATE OR REPLACE FUNCTION provision_signup_company()
RETURNS profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  caller_id uuid := auth.uid();
  caller_email text;
  signup_metadata jsonb;
  tenant_name text;
  person_name text;
  company_code text;
  employee_code text;
  new_org_id uuid;
  new_company_id uuid;
  existing_profile profiles;
  new_profile profiles;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  -- Share the bootstrap lock with migration 015. This prevents a simultaneous
  -- legacy first-install request from racing tenant creation.
  PERFORM pg_advisory_xact_lock(hashtext('public.bootstrap_first_admin'));

  SELECT * INTO existing_profile
  FROM profiles
  WHERE auth_user_id = caller_id
  LIMIT 1;
  IF FOUND THEN
    RETURN existing_profile;
  END IF;

  SELECT email, raw_user_meta_data
    INTO caller_email, signup_metadata
  FROM auth.users
  WHERE id = caller_id;

  tenant_name := trim(coalesce(signup_metadata->>'company_name', ''));
  person_name := trim(coalesce(signup_metadata->>'full_name', ''));
  IF tenant_name = '' THEN
    RAISE EXCEPTION 'Company name is required for direct signup.';
  END IF;
  IF person_name = '' THEN
    RAISE EXCEPTION 'Full name is required for direct signup.';
  END IF;

  company_code := 'C-' || upper(substr(replace(caller_id::text, '-', ''), 1, 12));
  employee_code := 'P-' || upper(substr(replace(caller_id::text, '-', ''), 1, 12));

  INSERT INTO organizations (name)
  VALUES (tenant_name)
  RETURNING id INTO new_org_id;

  INSERT INTO companies (organization_id, code, name)
  VALUES (new_org_id, company_code, tenant_name)
  RETURNING id INTO new_company_id;

  INSERT INTO profiles (
    organization_id, auth_user_id, employee_code, full_name, contact_email,
    role, joining_date, is_active, company, company_id
  ) VALUES (
    new_org_id, caller_id, employee_code, person_name, caller_email,
    'partner', CURRENT_DATE, true, company_code, new_company_id
  ) RETURNING * INTO new_profile;

  RETURN new_profile;
END;
$$;

REVOKE ALL ON FUNCTION provision_signup_company() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION provision_signup_company() TO authenticated;
