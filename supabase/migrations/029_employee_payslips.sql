-- ==============================================================================
-- 029: EMPLOYEE SALARY / PAYSLIPS
-- ==============================================================================
-- Inspected first: CTC lives only in employee_salary_history (009 removed it
-- from profiles), one row per effective date with company_id (028). Its only
-- policy, salary_partner_only, gives partners full access and everyone else
-- nothing. The monthly salary itself is not stored — the app calculates it
-- from that history plus attendance, leave and holidays, which employees can
-- already read for themselves.
--
-- 1. Employees may READ their own salary history rows — never anyone else's.
--    Writes stay partner-only (salary_partner_only, unchanged). Nobody can
--    query another employee's CTC: the only rows a non-partner can see are
--    WHERE profile_id = their own profile.
-- 2. companies.logo_data_url: an optional small PNG/JPEG logo (data URL) that
--    partners set on the Companies screen, printed on payslips. Readable by
--    whoever can already read the company row (companies_select, 028);
--    writable by partners only (companies_update, 028).
--
-- No other table, row or policy is changed. Safe to re-run.
-- ==============================================================================

DROP POLICY IF EXISTS salary_own_select ON employee_salary_history;
CREATE POLICY salary_own_select ON employee_salary_history FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND profile_id = auth_profile_id());

ALTER TABLE companies ADD COLUMN IF NOT EXISTS logo_data_url TEXT;
ALTER TABLE companies DROP CONSTRAINT IF EXISTS chk_companies_logo;
ALTER TABLE companies ADD CONSTRAINT chk_companies_logo CHECK (
  logo_data_url IS NULL OR (
    length(logo_data_url) <= 400000
    AND logo_data_url ~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$'
  )
);

-- 3. A payslip for a past month names the company that paid that month. An
--    employee who has since moved company may read (only) the companies that
--    appear in their OWN salary history. Otherwise identical to 028.
DROP POLICY IF EXISTS companies_select ON companies;
CREATE POLICY companies_select ON companies FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      auth_all_companies()
      OR id = auth_company_id()
      OR id IN (SELECT s.company_id FROM employee_salary_history s WHERE s.profile_id = auth_profile_id())
    )
  );
