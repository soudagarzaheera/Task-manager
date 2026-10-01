-- ==============================================================================
-- AUTH INTEGRATION: SCOPE ACCESS TO SIGNED-IN, LINKED USERS
-- ==============================================================================
-- 002_open_access_policies.sql intentionally granted the anon key full access
-- because the app had no real sign-in flow yet ("Signed in as" was a local
-- view-switcher, not Supabase Auth). That note said to replace these once
-- Supabase Auth was wired up — this migration is that replacement.
--
-- Model:
--   * Every table's rows belong to one organization. A signed-in user's own
--     organization is looked up from their `profiles` row via auth.uid().
--   * `anon` loses all access — every table now requires a real session.
--   * `authenticated` keeps the same broad, organization-scoped access the
--     app already assumed (the app's finer-grained checks — who can approve
--     a sheet, close a job, etc. — remain enforced in the client's CAN.*
--     logic, same as before this migration; only the login gate and the
--     employee-creation path change trust boundaries here).
--   * `profiles` is the exception: INSERT is removed for authenticated/anon
--     entirely (new employees can only be created by the create-employee
--     Edge Function, which uses the service-role key and bypasses RLS), and
--     UPDATE/DELETE require the caller to be a partner — mirroring the
--     existing CAN.manageTeam() rule (rank()>=90, i.e. role='partner').
-- ==============================================================================

-- ---- helper functions -------------------------------------------------------
-- SECURITY DEFINER so these can read `profiles` for the lookup without
-- recursing into the RLS policies defined below (which call these functions).

CREATE OR REPLACE FUNCTION auth_profile_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM profiles WHERE auth_user_id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION auth_org_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT organization_id FROM profiles WHERE auth_user_id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION auth_is_partner()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT role = 'partner' AND is_active FROM profiles WHERE auth_user_id = auth.uid() LIMIT 1),
    false
  );
$$;

REVOKE ALL ON FUNCTION auth_profile_id() FROM anon;
REVOKE ALL ON FUNCTION auth_org_id() FROM anon;
REVOKE ALL ON FUNCTION auth_is_partner() FROM anon;

-- ---- drop the prototype's open-access policies -------------------------------

DO $$
DECLARE
  t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'organizations','profiles','clients','locations','jobs','job_assignments',
    'tasks','timesheet_entries','nil_timesheets','attendance_punches',
    'budget_requests','expense_claims','expense_claim_lines','leaves','holidays',
    'statutory_compliances','review_notes','audit_logs'
  ])
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS anon_full_access ON %I;', t);
  END LOOP;
END $$;

-- ---- organizations: read-only, own org row only ------------------------------
CREATE POLICY org_select ON organizations FOR SELECT TO authenticated
  USING (id = auth_org_id());

-- ---- straightforward org-scoped tables ---------------------------------------
-- Same broad authenticated access the app already assumed, just no longer
-- available to anon and never crossing an organization boundary.
DO $$
DECLARE
  t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'clients','locations','jobs','job_assignments','tasks','timesheet_entries',
    'nil_timesheets','attendance_punches','budget_requests','expense_claims',
    'leaves','holidays','statutory_compliances','review_notes','audit_logs'
  ])
  LOOP
    EXECUTE format(
      'CREATE POLICY authenticated_org_access ON %I FOR ALL TO authenticated USING (organization_id = auth_org_id()) WITH CHECK (organization_id = auth_org_id());',
      t
    );
  END LOOP;
END $$;

-- ---- expense_claim_lines: scoped via its parent claim -------------------------
CREATE POLICY authenticated_org_access ON expense_claim_lines FOR ALL TO authenticated
  USING (claim_id IN (SELECT id FROM expense_claims WHERE organization_id = auth_org_id()))
  WITH CHECK (claim_id IN (SELECT id FROM expense_claims WHERE organization_id = auth_org_id()));

-- ---- profiles: read broadly, but writes are locked down ----------------------
-- Everyone signed in can see their firm's people (team list, reporting tree,
-- assignment pickers, etc. — unchanged from today's behaviour).
CREATE POLICY profiles_select ON profiles FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());

-- No INSERT policy for anon/authenticated at all: creating a profile is only
-- possible through the service-role client inside the create-employee Edge
-- Function, which bypasses RLS. This is what stops any signed-in employee
-- from calling supabase.from('profiles').insert(...) themselves.

-- Editing/deactivating/reactivating an employee (existing "Add Employee"
-- screen's edit path) stays a direct client call, but only a partner can do
-- it — mirrors CAN.manageTeam().
CREATE POLICY profiles_update ON profiles FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_is_partner())
  WITH CHECK (organization_id = auth_org_id());

-- Hard-delete only ever happens for a profile with no history (doOffboard()
-- checks this client-side; ON DELETE RESTRICT foreign keys back it up).
CREATE POLICY profiles_delete ON profiles FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_is_partner());
