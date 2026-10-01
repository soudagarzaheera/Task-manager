-- ==============================================================================
-- 028: MULTIPLE COMPANIES UNDER ONE ORGANIZATION
-- ==============================================================================
-- Inspected first (live DB, 2026-10-01):
--   * `companies` already exists (012): id, organization_id, code, name,
--     is_active, created_at — reused, not recreated. It was read-only.
--   * `company_id` already exists on profiles (NOT NULL, 012) and locations
--     (NOT NULL, 012). No other business table had one.
--   * Every other table's RLS was organization-wide.
--
-- Model (existing roles only — no new role system):
--   Organization ─┬─ Company A ─ employees (profiles.company_id)
--                 └─ Company B
--   * Partners (auth_rank() = 90) manage and see every company of their
--     organization — they get the company switcher in the app.
--   * Everyone else sees their OWN company, plus the explicit relationships
--     the app already relies on: themselves, their supervisor, their direct
--     reports, and any job they personally work on (task / time / assignment
--     / opened it). This keeps today's cross-company work (e.g. an MRCO
--     senior on a Fyn job) working.
--
-- Changes:
--   1. companies: partners may create/rename/(de)activate; unique name per org.
--   2. company_id added to clients, jobs, employee_salary_history — backfilled
--      from existing relationships, NOT NULL, composite FK to companies.
--      Tasks, timesheets, budget requests and compliances follow their job /
--      client; leave, attendance, claims follow the employee's profile.
--   3. A BEFORE trigger fills company_id when an older app build omits it, and
--      stops non-partners moving a record to another company.
--   4. RLS on every company-specific table is narrowed as described above.
--
-- Nothing is deleted. No existing row loses data. Safe to re-run.
-- ==============================================================================

-- New columns first: the helper functions below reference them.
ALTER TABLE clients ADD COLUMN IF NOT EXISTS company_id UUID;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS company_id UUID;
ALTER TABLE employee_salary_history ADD COLUMN IF NOT EXISTS company_id UUID;

-- ---- 0. helpers ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_company_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT company_id FROM profiles WHERE auth_user_id = auth.uid() AND is_active LIMIT 1;
$$;

-- Partners work across every company of their organization.
CREATE OR REPLACE FUNCTION auth_all_companies()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth_rank() >= 90;
$$;

CREATE OR REPLACE FUNCTION auth_company_ok(p_company UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_company IS NOT NULL
     AND EXISTS (SELECT 1 FROM companies c WHERE c.id = p_company AND c.organization_id = auth_org_id())
     AND (auth_all_companies() OR p_company = auth_company_id());
$$;

-- A profile the caller may see: same organization and (partner | same company
-- | self | own supervisor | own direct report | someone booked or tasked on a
-- job of the caller's company, so job cost / task lists keep their names).
CREATE OR REPLACE FUNCTION auth_profile_visible(p_profile UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = p_profile AND p.organization_id = auth_org_id()
      AND (
        auth_all_companies()
        OR p.company_id = auth_company_id()
        OR p.id = auth_profile_id()
        OR p.reports_to = auth_profile_id()
        OR p.id = (SELECT me.reports_to FROM profiles me WHERE me.id = auth_profile_id())
        OR EXISTS (SELECT 1 FROM tasks t JOIN jobs j ON j.id = t.job_id
                   WHERE t.assigned_to = p.id AND j.organization_id = p.organization_id
                     AND j.company_id = auth_company_id())
        OR EXISTS (SELECT 1 FROM timesheet_entries te JOIN jobs j ON j.id = te.job_id
                   WHERE te.profile_id = p.id AND j.organization_id = p.organization_id
                     AND j.company_id = auth_company_id())
      )
  );
$$;

-- A job the caller may see: partner | job of own company | a job they opened,
-- are tasked on, booked time on, or are assigned to | a job one of their
-- direct reports is tasked on or booked time on (the supervisor approves that
-- time, so it must be able to see the job).
CREATE OR REPLACE FUNCTION auth_job_visible(p_job UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM jobs j
    WHERE j.id = p_job AND j.organization_id = auth_org_id()
      AND (
        auth_all_companies()
        OR j.company_id = auth_company_id()
        OR j.opened_by = auth_profile_id()
        OR EXISTS (SELECT 1 FROM tasks t WHERE t.job_id = j.id AND t.assigned_to = auth_profile_id())
        OR EXISTS (SELECT 1 FROM timesheet_entries te WHERE te.job_id = j.id AND te.profile_id = auth_profile_id())
        OR EXISTS (SELECT 1 FROM job_assignments a WHERE a.job_id = j.id AND a.profile_id = auth_profile_id())
        OR EXISTS (SELECT 1 FROM tasks t JOIN profiles r ON r.id = t.assigned_to
                   WHERE t.job_id = j.id AND r.reports_to = auth_profile_id())
        OR EXISTS (SELECT 1 FROM timesheet_entries te JOIN profiles r ON r.id = te.profile_id
                   WHERE te.job_id = j.id AND r.reports_to = auth_profile_id())
      )
  );
$$;

CREATE OR REPLACE FUNCTION auth_client_visible(p_client UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM clients c
    WHERE c.id = p_client AND c.organization_id = auth_org_id()
      AND (auth_company_ok(c.company_id)
           OR EXISTS (SELECT 1 FROM jobs j WHERE j.client_id = c.id AND auth_job_visible(j.id)))
  );
$$;

-- ---- 1. companies: partner-managed ---------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_companies_org_name') THEN
    CREATE UNIQUE INDEX uq_companies_org_name ON companies (organization_id, lower(trim(name)));
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_companies_updated_at ON companies;
CREATE TRIGGER trg_companies_updated_at
  BEFORE UPDATE ON companies FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- A company that still has active employees cannot be deactivated (every
-- active employee must belong to an active company).
CREATE OR REPLACE FUNCTION guard_company_deactivation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF OLD.is_active AND NOT NEW.is_active AND EXISTS (
    SELECT 1 FROM profiles p WHERE p.company_id = NEW.id AND p.organization_id = NEW.organization_id AND p.is_active
  ) THEN
    RAISE EXCEPTION 'Company % still has active employees. Move or deactivate them first.', NEW.name
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_company_deactivation ON companies;
CREATE TRIGGER trg_guard_company_deactivation
  BEFORE UPDATE OF is_active ON companies FOR EACH ROW EXECUTE FUNCTION guard_company_deactivation();

DROP POLICY IF EXISTS companies_select ON companies;
CREATE POLICY companies_select ON companies FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (auth_all_companies() OR id = auth_company_id()));
DROP POLICY IF EXISTS companies_insert ON companies;
CREATE POLICY companies_insert ON companies FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 90);
DROP POLICY IF EXISTS companies_update ON companies;
CREATE POLICY companies_update ON companies FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 90)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 90);
-- No DELETE policy: companies are deactivated, never deleted (FKs RESTRICT).

-- ---- 2. company_id on clients, jobs, employee_salary_history (backfill) -------------

-- clients: relationship partner's company -> company of whoever opened its
-- first job -> the organization's first company.
UPDATE clients c SET company_id = COALESCE(
  (SELECT p.company_id FROM profiles p WHERE p.id = c.relationship_partner_id AND p.organization_id = c.organization_id),
  (SELECT p.company_id FROM jobs j JOIN profiles p ON p.id = j.opened_by
    WHERE j.client_id = c.id AND j.organization_id = c.organization_id ORDER BY j.created_at LIMIT 1),
  (SELECT co.id FROM companies co WHERE co.organization_id = c.organization_id ORDER BY co.created_at, co.id LIMIT 1))
WHERE c.company_id IS NULL;

-- jobs: the client's company -> opener's company -> first company.
UPDATE jobs j SET company_id = COALESCE(
  (SELECT c.company_id FROM clients c WHERE c.id = j.client_id AND c.organization_id = j.organization_id),
  (SELECT p.company_id FROM profiles p WHERE p.id = j.opened_by AND p.organization_id = j.organization_id),
  (SELECT co.id FROM companies co WHERE co.organization_id = j.organization_id ORDER BY co.created_at, co.id LIMIT 1))
WHERE j.company_id IS NULL;

-- salary: the employee's company at the time of migration (the only company
-- information that existed).
UPDATE employee_salary_history s SET company_id = p.company_id
FROM profiles p WHERE p.id = s.profile_id AND s.company_id IS NULL;

ALTER TABLE clients ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE jobs ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE employee_salary_history ALTER COLUMN company_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_clients_company') THEN
    ALTER TABLE clients ADD CONSTRAINT fk_clients_company
      FOREIGN KEY (organization_id, company_id) REFERENCES companies(organization_id, id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_jobs_company') THEN
    ALTER TABLE jobs ADD CONSTRAINT fk_jobs_company
      FOREIGN KEY (organization_id, company_id) REFERENCES companies(organization_id, id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_salary_company') THEN
    ALTER TABLE employee_salary_history ADD CONSTRAINT fk_salary_company
      FOREIGN KEY (organization_id, company_id) REFERENCES companies(organization_id, id) ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_clients_company ON clients (organization_id, company_id);
CREATE INDEX IF NOT EXISTS idx_jobs_company ON jobs (organization_id, company_id);
CREATE INDEX IF NOT EXISTS idx_salary_company ON employee_salary_history (organization_id, company_id, profile_id);
CREATE INDEX IF NOT EXISTS idx_profiles_company ON profiles (organization_id, company_id);

-- ---- 3. default + guard company_id --------------------------------------------------
CREATE OR REPLACE FUNCTION set_record_company()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.company_id IS NULL THEN
    IF TG_TABLE_NAME = 'jobs' THEN
      SELECT company_id INTO NEW.company_id FROM clients
       WHERE id = NEW.client_id AND organization_id = NEW.organization_id;
    ELSIF TG_TABLE_NAME = 'employee_salary_history' THEN
      SELECT company_id INTO NEW.company_id FROM profiles
       WHERE id = NEW.profile_id AND organization_id = NEW.organization_id;
    END IF;
    IF NEW.company_id IS NULL THEN
      NEW.company_id := auth_company_id();
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.company_id IS DISTINCT FROM OLD.company_id
     AND auth.uid() IS NOT NULL AND NOT auth_all_companies() THEN
    RAISE EXCEPTION 'Only a partner can move a record to another company.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clients_company ON clients;
CREATE TRIGGER trg_clients_company BEFORE INSERT OR UPDATE OF company_id ON clients
  FOR EACH ROW EXECUTE FUNCTION set_record_company();
DROP TRIGGER IF EXISTS trg_jobs_company ON jobs;
CREATE TRIGGER trg_jobs_company BEFORE INSERT OR UPDATE OF company_id ON jobs
  FOR EACH ROW EXECUTE FUNCTION set_record_company();
DROP TRIGGER IF EXISTS trg_salary_company ON employee_salary_history;
CREATE TRIGGER trg_salary_company BEFORE INSERT OR UPDATE OF company_id ON employee_salary_history
  FOR EACH ROW EXECUTE FUNCTION set_record_company();

-- ---- 4. RLS ------------------------------------------------------------------------

-- profiles (writes unchanged: partner only, 003)
DROP POLICY IF EXISTS profiles_select ON profiles;
CREATE POLICY profiles_select ON profiles FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_profile_visible(id));

-- clients
DROP POLICY IF EXISTS authenticated_org_access ON clients;
DROP POLICY IF EXISTS clients_select ON clients;
DROP POLICY IF EXISTS clients_insert ON clients;
DROP POLICY IF EXISTS clients_update ON clients;
DROP POLICY IF EXISTS clients_delete ON clients;
-- Checks the row's own company_id first: a function that looks the row up by
-- id cannot see a row being inserted, which would break INSERT ... RETURNING.
CREATE POLICY clients_select ON clients FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (auth_company_ok(company_id) OR auth_client_visible(id)));
CREATE POLICY clients_insert ON clients FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id));
CREATE POLICY clients_update ON clients FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id));
CREATE POLICY clients_delete ON clients FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id));

-- jobs
DROP POLICY IF EXISTS authenticated_org_access ON jobs;
DROP POLICY IF EXISTS jobs_select ON jobs;
DROP POLICY IF EXISTS jobs_insert ON jobs;
DROP POLICY IF EXISTS jobs_update ON jobs;
DROP POLICY IF EXISTS jobs_delete ON jobs;
CREATE POLICY jobs_select ON jobs FOR SELECT TO authenticated
  USING (organization_id = auth_org_id()
         AND (auth_company_ok(company_id) OR opened_by = auth_profile_id() OR auth_job_visible(id)));
CREATE POLICY jobs_insert ON jobs FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id));
CREATE POLICY jobs_update ON jobs FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(id))
  WITH CHECK (organization_id = auth_org_id());      -- company moves guarded by trg_jobs_company
CREATE POLICY jobs_delete ON jobs FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id));

-- tasks (follow their job)
DROP POLICY IF EXISTS authenticated_org_access ON tasks;
DROP POLICY IF EXISTS tasks_access ON tasks;
CREATE POLICY tasks_access ON tasks FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND (assigned_to = auth_profile_id() OR auth_job_visible(job_id)))
  WITH CHECK (organization_id = auth_org_id() AND (assigned_to = auth_profile_id() OR auth_job_visible(job_id)));

-- job_assignments (follow their job)
DROP POLICY IF EXISTS authenticated_org_access ON job_assignments;
DROP POLICY IF EXISTS job_assignments_access ON job_assignments;
CREATE POLICY job_assignments_access ON job_assignments FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(job_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_job_visible(job_id));

-- statutory_compliances (follow their client)
DROP POLICY IF EXISTS authenticated_org_access ON statutory_compliances;
DROP POLICY IF EXISTS statutory_compliances_access ON statutory_compliances;
CREATE POLICY statutory_compliances_access ON statutory_compliances FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_client_visible(client_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_client_visible(client_id));

-- timesheet_entries: own, people you can see, or any entry on a job of your
-- company (keeps job-cost totals complete for that company's jobs).
DROP POLICY IF EXISTS authenticated_org_access ON timesheet_entries;
DROP POLICY IF EXISTS timesheet_entries_access ON timesheet_entries;
CREATE POLICY timesheet_entries_access ON timesheet_entries FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id() OR auth_profile_visible(profile_id)
    OR EXISTS (SELECT 1 FROM jobs j WHERE j.id = timesheet_entries.job_id AND auth_company_ok(j.company_id))))
  WITH CHECK (organization_id = auth_org_id() AND (profile_id = auth_profile_id() OR auth_profile_visible(profile_id)));

-- attendance_punches, nil_timesheets (follow the employee)
DROP POLICY IF EXISTS authenticated_org_access ON attendance_punches;
DROP POLICY IF EXISTS attendance_punches_access ON attendance_punches;
CREATE POLICY attendance_punches_access ON attendance_punches FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_profile_visible(profile_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_profile_visible(profile_id));

DROP POLICY IF EXISTS authenticated_org_access ON nil_timesheets;
DROP POLICY IF EXISTS nil_timesheets_access ON nil_timesheets;
CREATE POLICY nil_timesheets_access ON nil_timesheets FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_profile_visible(profile_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_profile_visible(profile_id));

-- leaves: the org-wide "approved leave, senior and up" read (Team today board)
-- is narrowed to people you can see. Everything else as in 007.
DROP POLICY IF EXISTS leaves_select ON leaves;
CREATE POLICY leaves_select ON leaves FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR (status = 'approved' AND auth_rank() >= 50 AND auth_profile_visible(profile_id))
      OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = leaves.profile_id AND p.reports_to = auth_profile_id())
      OR (auth_rank() >= 90 AND profile_rank(leaves.profile_id) < 90)
    )
  );

-- budget_requests: as 005, and only on jobs you can see.
DROP POLICY IF EXISTS budget_requests_select ON budget_requests;
CREATE POLICY budget_requests_select ON budget_requests FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND auth_job_visible(job_id) AND (
      status = 'pending' OR requested_by = auth_profile_id() OR auth_rank() >= 70
    )
  );
DROP POLICY IF EXISTS budget_requests_insert ON budget_requests;
CREATE POLICY budget_requests_insert ON budget_requests FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND requested_by = auth_profile_id() AND auth_job_visible(job_id));
DROP POLICY IF EXISTS budget_requests_update ON budget_requests;
CREATE POLICY budget_requests_update ON budget_requests FOR UPDATE TO authenticated
  USING (
    organization_id = auth_org_id() AND auth_rank() >= 70 AND auth_job_visible(job_id)
    AND (requested_by <> auth_profile_id() OR auth_rank() >= 90)
  )
  WITH CHECK (organization_id = auth_org_id());

-- expense_claims: managers/accounts only for people they can see.
DROP POLICY IF EXISTS expense_claims_select ON expense_claims;
CREATE POLICY expense_claims_select ON expense_claims FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR (auth_rank() >= 70 AND auth_profile_visible(profile_id))
      OR (auth_role() = 'accounts' AND status IN ('approved', 'paid') AND auth_profile_visible(profile_id))
    )
  );
DROP POLICY IF EXISTS expense_claims_update ON expense_claims;
CREATE POLICY expense_claims_update ON expense_claims FOR UPDATE TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR (auth_rank() >= 70 AND profile_id <> auth_profile_id() AND auth_profile_visible(profile_id))
      OR (auth_role() = 'accounts' AND auth_profile_visible(profile_id))
    )
  )
  WITH CHECK (organization_id = auth_org_id());
DROP POLICY IF EXISTS expense_claim_lines_select ON expense_claim_lines;
CREATE POLICY expense_claim_lines_select ON expense_claim_lines FOR SELECT TO authenticated
  USING (claim_id IN (SELECT id FROM expense_claims));   -- inherits expense_claims RLS

-- locations: managers see/manage sites of companies they may access.
DROP POLICY IF EXISTS locations_select ON locations;
CREATE POLICY locations_select ON locations FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id) AND (auth_rank() >= 70 OR is_active));
DROP POLICY IF EXISTS locations_insert ON locations;
CREATE POLICY locations_insert ON locations FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 70 AND auth_company_ok(company_id));
DROP POLICY IF EXISTS locations_update ON locations;
CREATE POLICY locations_update ON locations FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 70 AND auth_company_ok(company_id))
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 70 AND auth_company_ok(company_id));

-- employee_salary_history: unchanged (partner only — partners cover every company).

-- ---- 5. privileges -------------------------------------------------------------------
REVOKE ALL ON FUNCTION auth_company_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION auth_all_companies() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION auth_company_ok(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION auth_profile_visible(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION auth_job_visible(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION auth_client_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_company_id(), auth_all_companies(), auth_company_ok(uuid),
  auth_profile_visible(uuid), auth_job_visible(uuid), auth_client_visible(uuid) TO authenticated;
REVOKE ALL ON FUNCTION set_record_company() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_company_deactivation() FROM PUBLIC, anon, authenticated;
