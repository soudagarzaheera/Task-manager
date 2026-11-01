-- 039_employee_soft_delete.sql
--
-- Deleted employees: hidden from reactivation, employee code and email free
-- for a new employee, history kept.
--
-- Inspected first (live DB, 2026-10-31):
--   * "Delete" in the app was a hard DELETE on profiles. timesheet_entries,
--     nil_timesheets, attendance_punches, budget_requests, expense_claims,
--     leaves and employee_salary_history reference profiles ON DELETE RESTRICT,
--     so the delete failed for anyone with history — including everyone added
--     with a Monthly CTC (create-employee writes their first salary row). The
--     only way out was Deactivate, which keeps the row (is_active = false), so
--     the person stays in the Reactivate list and keeps their code and email.
--   * uq_org_employee_code UNIQUE (organization_id, employee_code) covers every
--     row, active or not — a deactivated person's code is never free.
--   * create-employee rejects an email used by ANY profile of the organization,
--     and Supabase Auth keeps the old account (profiles.auth_user_id references
--     auth.users ON DELETE SET NULL; deleting a profile never removes the Auth
--     user), so the email stayed blocked even after a successful hard delete.
--   * No orphaned Auth accounts exist today. One organization already has two
--     profiles with the same contact email, so email uniqueness stays an
--     application check (create-employee, app) rather than a unique index.
--
-- Model:
--   Active   : is_active = true,  deleted_at IS NULL
--   Inactive : is_active = false, deleted_at IS NULL  -> can be reactivated
--   Deleted  : is_active = false, deleted_at NOT NULL -> never reactivated
--
-- Changes:
--   1. profiles.deleted_at / deleted_by. CHECK: deleted => not active.
--   2. Employee code unique only among non-deleted profiles (partial index
--      replaces uq_org_employee_code). Deleted rows keep their code and email
--      so history still shows who did the work.
--   3. delete_employee(profile): Partner only, same organization, one
--      transaction — marks the profile deleted (inactive, exit date, who/when),
--      unlinks it from its Auth account, then deletes that Auth account only if
--      no profile at all still links to it. History rows are untouched (they
--      reference the profile, which stays).
--   4. guard_profile_delete_state (API users only): a deleted profile cannot be
--      changed or reactivated; deleted_at/deleted_by can only be set by
--      delete_employee.
--   5. redirect_profile_delete (API users only): a direct DELETE on profiles
--      (older app builds) becomes delete_employee — same checks, history kept,
--      Auth account removed — instead of a hard delete that failed or left the
--      sign-in account behind.
--   Edge Functions (service role) keep their behaviour: create-employee's
--   rollback still hard-deletes a profile it just created.
--
-- Nothing is deleted from history tables. Re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/039_employee_soft_delete.sql

BEGIN;

-- 1. Deletion state ---------------------------------------------------------------
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS deleted_by UUID;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_profiles_deleted_inactive') THEN
    ALTER TABLE profiles ADD CONSTRAINT chk_profiles_deleted_inactive
      CHECK (deleted_at IS NULL OR NOT is_active);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_profiles_deleted_by') THEN
    ALTER TABLE profiles ADD CONSTRAINT fk_profiles_deleted_by
      FOREIGN KEY (deleted_by) REFERENCES profiles(id) ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON COLUMN profiles.deleted_at IS
  'Set by delete_employee(). Deleted employees are inactive, cannot be reactivated, and free their employee code and email. History rows keep referencing the profile.';

-- 2. Employee code: unique among non-deleted profiles only -------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_profiles_org_employee_code_live
  ON profiles (organization_id, employee_code) WHERE deleted_at IS NULL;
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS uq_org_employee_code;

CREATE INDEX IF NOT EXISTS idx_profiles_org_email_live
  ON profiles (organization_id, lower(contact_email)) WHERE deleted_at IS NULL;

-- 3. delete_employee ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_employee(p_profile UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me UUID := auth_profile_id();
  v_org UUID := auth_org_id();
  t profiles%ROWTYPE;
  v_auth UUID;
  n INT;
BEGIN
  IF v_me IS NULL OR v_org IS NULL OR NOT auth_is_partner() THEN
    RAISE EXCEPTION 'Only a partner can delete an employee.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO t FROM profiles WHERE id = p_profile AND organization_id = v_org FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee not found.' USING ERRCODE = 'P0002';
  END IF;
  IF t.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION '% has already been deleted.', t.full_name USING ERRCODE = '22023';
  END IF;
  IF t.id = v_me THEN
    RAISE EXCEPTION 'You cannot delete yourself.' USING ERRCODE = '22023';
  END IF;
  IF t.role = 'partner' AND t.is_active AND NOT EXISTS (
       SELECT 1 FROM profiles p WHERE p.organization_id = v_org AND p.role = 'partner'
         AND p.is_active AND p.id <> t.id) THEN
    RAISE EXCEPTION 'The firm would be left without a partner.' USING ERRCODE = '22023';
  END IF;

  -- Same blockers the app shows in the Remove dialog.
  SELECT count(*) INTO n FROM profiles p
  WHERE p.organization_id = v_org AND p.reports_to = t.id AND p.is_active;
  IF n > 0 THEN
    RAISE EXCEPTION '% people report to %. Reassign them first.', n, t.full_name USING ERRCODE = '22023';
  END IF;
  SELECT count(*) INTO n FROM tasks k
  WHERE k.organization_id = v_org AND k.assigned_to = t.id AND k.status <> 'completed';
  IF n > 0 THEN
    RAISE EXCEPTION '% has % open task(s). Reassign or complete them first.', t.full_name, n USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM timesheet_entries e
             WHERE e.organization_id = v_org AND e.profile_id = t.id AND e.status = 'pending') THEN
    RAISE EXCEPTION '% has a submitted timesheet waiting for approval.', t.full_name USING ERRCODE = '22023';
  END IF;

  -- Inactive people who still report to them: clear the line, so a later
  -- reactivation never routes approvals to a deleted employee.
  UPDATE profiles SET reports_to = NULL
  WHERE organization_id = v_org AND reports_to = t.id AND NOT is_active;

  v_auth := t.auth_user_id;
  UPDATE profiles
  SET is_active = false,
      exit_date = COALESCE(exit_date, current_date),
      deleted_at = now(),
      deleted_by = v_me,
      auth_user_id = NULL
  WHERE id = t.id;

  -- Remove the old sign-in account so the email can be used again — but never
  -- one that any profile (any organization) still links to.
  IF v_auth IS NOT NULL AND NOT EXISTS (SELECT 1 FROM profiles WHERE auth_user_id = v_auth) THEN
    DELETE FROM auth.users WHERE id = v_auth;
  END IF;

  INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, old_values, new_values)
  VALUES (v_org, v_me, 'employee_deleted', 'profiles', t.id::text,
          jsonb_build_object('employee_code', t.employee_code, 'full_name', t.full_name,
                             'contact_email', t.contact_email, 'is_active', t.is_active,
                             'had_sign_in_account', v_auth IS NOT NULL),
          jsonb_build_object('deleted_at', now()));
END;
$$;

REVOKE ALL ON FUNCTION delete_employee(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION delete_employee(UUID) TO authenticated;

-- 4. Deleted profiles are final (API users) ------------------------------------------
CREATE OR REPLACE FUNCTION guard_profile_delete_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;
  IF OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'This employee has been deleted and cannot be changed or reactivated.' USING ERRCODE = '42501';
  END IF;
  IF NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.deleted_by IS DISTINCT FROM OLD.deleted_by THEN
    RAISE EXCEPTION 'Use Delete employee to delete someone.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION guard_profile_delete_state() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_profile_delete_state ON profiles;
CREATE TRIGGER trg_guard_profile_delete_state
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION guard_profile_delete_state();

-- 5. A direct DELETE from the API becomes delete_employee ------------------------------
CREATE OR REPLACE FUNCTION redirect_profile_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN OLD;                      -- service role / migrations: real delete
  END IF;
  IF OLD.deleted_at IS NULL THEN
    PERFORM delete_employee(OLD.id); -- partner check and blockers inside
  END IF;
  RETURN NULL;                       -- keep the row (and its history)
END;
$$;
REVOKE ALL ON FUNCTION redirect_profile_delete() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_redirect_profile_delete ON profiles;
CREATE TRIGGER trg_redirect_profile_delete
  BEFORE DELETE ON profiles
  FOR EACH ROW EXECUTE FUNCTION redirect_profile_delete();

COMMIT;
