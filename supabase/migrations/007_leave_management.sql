-- ==============================================================================
-- LEAVE MANAGEMENT MODULE  (idempotent — safe to run multiple times)
-- ==============================================================================
-- Inspected first: `leaves` (001_initial_schema.sql) already exists as a
-- PER-DAY record — one row per calendar date — and already has exactly the
-- status vocabulary this module needs: status IN ('pending','approved',
-- 'rejected','cancelled'), plus approved_by/approved_at/reason/duration_part
-- /leave_type. It was populated directly (no application UI ever called
-- into it) and read by index.html's leaveOn()/dayInfo() for the timesheet
-- and "Team today" attendance board. None of that changes here.
--
-- What was missing was purely the "apply for N days at once, decide the
-- whole span in one action" grouping, and a rejection reason distinct from
-- the request's own reason. Rather than add a parallel `leave_requests`
-- header table (a second place to keep a request's status/approver in sync
-- with its day rows), this migration adds one grouping column to `leaves`
-- itself: `request_id`. A multi-day application becomes N day-rows sharing
-- one request_id; "the request" is queried as `WHERE request_id = X` and
-- decided with one bulk UPDATE — exactly the pattern index.html already
-- uses for timesheet approval (a job code's rows for a week are approved
-- together; see decideLine()). This keeps one source of truth for "is this
-- day on leave" (still just `leaves`, still what leaveOn() reads) while
-- adding the request-level grouping the UI needs.
--
-- Two new tables:
--   * leave_types: the organization's configurable leave type catalogue
--     (label + default annual allocation + paid/unpaid), so the frontend
--     never hardcodes leave types or their day counts.
--   * employee_leave_balances: optional PER-EMPLOYEE allocation override for
--     a given leave type and year (e.g. a mid-year joiner's pro-rated
--     allowance, or a carried-forward balance). Sparse by design — an
--     employee with no override row simply uses leave_types' default.
-- "Used"/"Pending" are never stored — they are always summed live from
-- `leaves`, so there is nothing to keep in sync or go stale.
--
-- The existing `leaves.leave_type` CHECK constraint (CL/EL/SL/ML/PL/LWP) is
-- left in place rather than opened up to arbitrary codes: it is a small,
-- already-used, compliance-relevant enum, and loosening it is a bigger,
-- separate decision than this module needs to make. leave_types is seeded
-- with exactly those six codes, so "configurable" today means label/annual
-- allocation/active — adding a genuinely new leave code later needs both a
-- migration (extend the CHECK) and a leave_types row, same as adding a new
-- role would.
--
-- IDEMPOTENCY: this file was previously pasted into the SQL Editor and ran
-- to completion (every table/column/index/trigger/function/policy/seed row
-- it creates already exists in this database), but a second paste failed on
-- `CREATE POLICY leaves_select ... already exists` — plain CREATE POLICY
-- and CREATE TRIGGER have no IF NOT EXISTS clause in Postgres. Every
-- statement below is now guarded so the whole file can be re-run safely:
-- columns/tables/indexes already used IF NOT EXISTS; triggers and policies
-- now DROP ... IF EXISTS immediately before recreating (identical
-- definition — not a behaviour change, purely a syntax fix); the function
-- already used CREATE OR REPLACE; the seed insert already used ON CONFLICT
-- DO NOTHING. Nothing is dropped except a trigger/policy immediately
-- recreated in the same statement group, no table is touched, and no
-- `leaves` row is ever deleted or modified by this file.
-- ==============================================================================

-- ---- 1. leaves: request grouping + rejection reason --------------------------
ALTER TABLE leaves
  ADD COLUMN IF NOT EXISTS request_id UUID NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS rejection_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_leaves_request_id ON leaves (request_id);
CREATE INDEX IF NOT EXISTS idx_leaves_profile_status ON leaves (profile_id, status);

-- ---- 2. leave_types: organization-configurable catalogue ----------------------
CREATE TABLE IF NOT EXISTS leave_types (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code TEXT NOT NULL CHECK (code IN ('CL', 'EL', 'SL', 'ML', 'PL', 'LWP')),
    label TEXT NOT NULL,
    annual_days NUMERIC(5,1) NOT NULL DEFAULT 0 CHECK (annual_days >= 0),
    is_paid BOOLEAN NOT NULL DEFAULT true,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_leave_types_org_code UNIQUE (organization_id, code)
);

DROP TRIGGER IF EXISTS trg_leave_types_updated_at ON leave_types;
CREATE TRIGGER trg_leave_types_updated_at
    BEFORE UPDATE ON leave_types
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Seed the existing six leave codes for every organization that already
-- exists, with standard defaults a partner can edit immediately from the
-- Leave screen. Not mock/demo data — every real org needs at least this
-- much configuration for the Apply-for-leave form to have anything to list.
-- ON CONFLICT DO NOTHING already makes this safe to re-run — it will never
-- overwrite a type a partner has since edited.
INSERT INTO leave_types (organization_id, code, label, annual_days, is_paid)
SELECT o.id, t.code, t.label, t.annual_days, t.is_paid
FROM organizations o
CROSS JOIN (VALUES
    ('CL',  'Casual Leave',        12,  true),
    ('SL',  'Sick Leave',          12,  true),
    ('EL',  'Earned Leave',         0,  true),
    ('ML',  'Maternity Leave',     182, true),
    ('PL',  'Paternity Leave',     15,  true),
    ('LWP', 'Leave Without Pay',   0,   false)
) AS t(code, label, annual_days, is_paid)
ON CONFLICT (organization_id, code) DO NOTHING;

-- ---- 3. employee_leave_balances: optional per-employee override --------------
CREATE TABLE IF NOT EXISTS employee_leave_balances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    leave_type_code TEXT NOT NULL,
    leave_year INTEGER NOT NULL CHECK (leave_year BETWEEN 2000 AND 2100),
    allocated_days NUMERIC(5,1) NOT NULL CHECK (allocated_days >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_employee_leave_balance UNIQUE (profile_id, leave_type_code, leave_year),
    CONSTRAINT fk_elb_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_elb_leave_type FOREIGN KEY (organization_id, leave_type_code)
        REFERENCES leave_types(organization_id, code) ON DELETE CASCADE
);

DROP TRIGGER IF EXISTS trg_employee_leave_balances_updated_at ON employee_leave_balances;
CREATE TRIGGER trg_employee_leave_balances_updated_at
    BEFORE UPDATE ON employee_leave_balances
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ---- helper: rank of an arbitrary profile (auth_rank() is the caller's own) ---
-- CREATE OR REPLACE is already idempotent.
CREATE OR REPLACE FUNCTION profile_rank(pid UUID)
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE (SELECT role FROM profiles WHERE id = pid)
    WHEN 'partner' THEN 90 WHEN 'manager' THEN 70 WHEN 'senior' THEN 50
    WHEN 'accounts' THEN 40 WHEN 'associate' THEN 20 WHEN 'article' THEN 10
    ELSE 0 END;
$$;
REVOKE ALL ON FUNCTION profile_rank(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION profile_rank(UUID) TO authenticated;

-- ---- 4. RLS: leaves — replace the blanket policy ------------------------------
-- Mirrors CAN.approveSheet() in index.html exactly (same rule this app
-- already uses to decide who approves whose timesheet): a direct manager
-- sees everything for their own reports; a partner sees everything for any
-- non-partner. Two additions beyond that: every profile always sees its own
-- row (to apply/cancel/view history), and any senior-and-up (auth_rank()>=50,
-- matching CAN.seeTeamAtt()) sees APPROVED rows org-wide — this was already
-- fully open under the old blanket policy and is needed by the existing
-- "Team today" attendance board, which has shown who is on approved leave
-- since before this migration.
DROP POLICY IF EXISTS authenticated_org_access ON leaves;

DROP POLICY IF EXISTS leaves_select ON leaves;
CREATE POLICY leaves_select ON leaves FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR (status = 'approved' AND auth_rank() >= 50)
      OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = leaves.profile_id AND p.reports_to = auth_profile_id())
      OR (auth_rank() >= 90 AND profile_rank(leaves.profile_id) < 90)
    )
  );

-- A fresh application must start 'pending' — EXCEPT a partner applying for
-- their own leave, which index.html self-certifies client-side the same
-- way it already self-certifies a partner's own timesheet (CAN.selfCertify():
-- there is nobody above a partner to send it to). auth_rank() = 90 is
-- exactly "is a partner" on the RANK map this project already uses. Without
-- this, WITH CHECK would only confirm "inserting your own row" and nothing
-- would stop any employee from inserting a pre-approved row for themselves.
DROP POLICY IF EXISTS leaves_insert ON leaves;
CREATE POLICY leaves_insert ON leaves FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = auth_org_id() AND profile_id = auth_profile_id() AND (
      status = 'pending' OR (status = 'approved' AND auth_rank() = 90)
    )
  );

-- Write: the owner may only move their OWN row to 'cancelled' (WITH CHECK
-- pins that — it is what stops a plain UPDATE call from the browser console
-- self-approving a pending request; the owner clause in USING only grants
-- reaching the row, not what it may become). Whoever is authorized to
-- decide it (same reports-to/partner rule as SELECT above) may set any
-- status on someone else's row — same trust level this project already
-- gives an approver elsewhere (e.g. budget_requests_update), with exact
-- status-transition correctness left to the client, as there too.
DROP POLICY IF EXISTS leaves_update ON leaves;
CREATE POLICY leaves_update ON leaves FOR UPDATE TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = leaves.profile_id AND p.reports_to = auth_profile_id())
      OR (auth_rank() >= 90 AND profile_rank(leaves.profile_id) < 90)
    )
  )
  WITH CHECK (
    organization_id = auth_org_id() AND (
      (profile_id = auth_profile_id() AND status = 'cancelled')
      OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = leaves.profile_id AND p.reports_to = auth_profile_id())
      OR (auth_rank() >= 90 AND profile_rank(leaves.profile_id) < 90)
    )
  );

-- No DELETE policy: approved/rejected/cancelled leave is never deleted,
-- only its status changes — same rule this project already applies to
-- budget_requests and expense_claims.

-- ---- 5. RLS: leave_types ------------------------------------------------------
-- Every signed-in member needs to read the catalogue (to apply for leave and
-- see their balance); only a partner configures it — same boundary as
-- CAN.manageTeam()/"Add an employee, change a role".
DROP POLICY IF EXISTS leave_types_select ON leave_types;
CREATE POLICY leave_types_select ON leave_types FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());

DROP POLICY IF EXISTS leave_types_write ON leave_types;
CREATE POLICY leave_types_write ON leave_types FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 90)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 90);

-- ---- 6. RLS: employee_leave_balances ------------------------------------------
-- Same visibility boundary as leaves itself (it's the allocation half of the
-- same sensitive per-employee record); only a partner sets an override.
DROP POLICY IF EXISTS employee_leave_balances_select ON employee_leave_balances;
CREATE POLICY employee_leave_balances_select ON employee_leave_balances FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = employee_leave_balances.profile_id AND p.reports_to = auth_profile_id())
      OR (auth_rank() >= 90 AND profile_rank(employee_leave_balances.profile_id) < 90)
    )
  );

DROP POLICY IF EXISTS employee_leave_balances_write ON employee_leave_balances;
CREATE POLICY employee_leave_balances_write ON employee_leave_balances FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 90)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 90);
