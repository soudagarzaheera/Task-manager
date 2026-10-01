-- ==============================================================================
-- ACCESS POLICIES FOR THE FRONTEND (anon / publishable key)
-- ==============================================================================
-- 001_initial_schema.sql enables Row Level Security on every table but defines
-- no policies. With RLS on and no policies, Postgres denies ALL access by
-- default — so the app cannot read or write anything, regardless of the
-- frontend code, until policies exist.
--
-- The app currently has no real sign-in flow (the "Signed in as" control is a
-- local view-switcher, not Supabase Auth), so it only ever connects with the
-- anon/publishable key. These policies grant that key the same broad access
-- the prototype already assumed. This is intentionally permissive to match
-- the app's current (no-login) trust model.
--
-- SECURITY NOTE: once real Supabase Auth is wired up, replace these with
-- policies scoped to auth.uid() / the caller's organization_id.
-- ==============================================================================

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
    EXECUTE format(
      'DROP POLICY IF EXISTS anon_full_access ON %I;', t
    );
    EXECUTE format(
      'CREATE POLICY anon_full_access ON %I FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);', t
    );
  END LOOP;
END $$;
