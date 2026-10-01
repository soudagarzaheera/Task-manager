-- Keep first-user signup compatible with company/site support (migration 012).
-- The original bootstrap function inserted a Partner profile without the now
-- required company_id, so the whole transaction failed and signup fell through
-- to the "Account not assigned" path.
--
-- This remains a one-time self-service path: it is available only while there
-- are no organizations or profiles, and the check and inserts run atomically.
-- Employee profiles continue to be created through the Partner-only Edge
-- Function and are not affected by this bootstrap.

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

  -- profiles.company_id is NOT NULL and references a company within the same
  -- organization. Create the initial company before inserting the Partner.
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
