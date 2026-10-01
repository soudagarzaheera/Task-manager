-- ==============================================================================
-- APPROVAL HISTORY: timesheet decision tracking + partner-only RLS scoping
-- ==============================================================================
-- Context: the Approvals screen only ever showed *pending* items (a submitted
-- timesheet, a "pending" budget_requests row, a "submitted" expense_claims
-- row). Once decideLine()/decideBudget()/decideClaim() moved a record out of
-- that pending state, it vanished from the screen — the decision was saved
-- (status did change in the database, nothing was deleted), but there was
-- nowhere left in the UI that read decided records back out. Separately,
-- 003_auth_integration.sql's `authenticated_org_access` policy gave every
-- signed-in member of an organization full read (and write) access to every
-- other member's budget_requests and expense_claims rows, decided or not —
-- so even once a history view existed, an ordinary employee could read
-- another employee's — or another partner's — accepted/rejected requests,
-- and who decided them, directly through the anon/publishable client.
--
-- This migration:
--   1. Adds decided_by/decided_at to timesheet_entries, mirroring the
--      decided_by/decided_at that budget_requests already had and the
--      approved_by/approved_at that expense_claims already had, so a
--      timesheet decision records who made it and when, the same as the
--      other two request types already did.
--   2. Replaces the blanket authenticated_org_access policy on
--      budget_requests, expense_claims and expense_claim_lines with policies
--      scoped to: the requester's own rows, plus the roles actually
--      authorized to decide them — mirroring CAN.approveBudget(),
--      CAN.approveClaim() and CAN.payClaim() in index.html exactly, so the
--      client-side capability matrix and the database policy agree.
--      *Pending* budget_requests stay organization-wide readable (unchanged)
--      because the "increase requested" flag on the Job codes screen — shown
--      to every role, not just approvers — already depends on seeing that a
--      request exists; it carries no decision, so there is nothing to
--      protect there. Only decided (approved/rejected) rows are locked down.
--   3. timesheet_entries' RLS is intentionally left as-is: the Job codes
--      screen (visible to every role) and the Time-on-jobs/Reports screens
--      (visible to seniors and up) already total hours from every employee's
--      entries by design, for job-cost visibility — tightening that table's
--      RLS would break those existing, unrelated features. The Approvals UI
--      scopes timesheet decision history in the client with the same
--      CAN.approveSheet() check it already used for the pending list, which
--      is the same trust boundary this table has had since
--      003_auth_integration.sql.
-- ==============================================================================

-- ---- 1. timesheet decision tracking -----------------------------------------
ALTER TABLE timesheet_entries
  ADD COLUMN IF NOT EXISTS decided_by UUID,
  ADD COLUMN IF NOT EXISTS decided_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'timesheet_entries_decided_by_fkey'
  ) THEN
    ALTER TABLE timesheet_entries
      ADD CONSTRAINT timesheet_entries_decided_by_fkey
      FOREIGN KEY (organization_id, decided_by) REFERENCES profiles(organization_id, id) ON DELETE SET NULL;
  END IF;
END $$;

-- ---- helper functions ---------------------------------------------------------
-- auth_rank() mirrors the RANK map in index.html exactly — keep both in sync
-- if a role is ever added or its rank changes.
CREATE OR REPLACE FUNCTION auth_rank()
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE (SELECT role FROM profiles WHERE auth_user_id = auth.uid() AND is_active LIMIT 1)
    WHEN 'partner' THEN 90 WHEN 'manager' THEN 70 WHEN 'senior' THEN 50
    WHEN 'accounts' THEN 40 WHEN 'associate' THEN 20 WHEN 'article' THEN 10
    ELSE 0 END;
$$;

CREATE OR REPLACE FUNCTION auth_role()
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT role FROM profiles WHERE auth_user_id = auth.uid() AND is_active LIMIT 1;
$$;

REVOKE ALL ON FUNCTION auth_rank() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION auth_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_rank() TO authenticated;
GRANT EXECUTE ON FUNCTION auth_role() TO authenticated;

-- ---- 2. budget_requests: decision-aware scope ----------------------------------
DROP POLICY IF EXISTS authenticated_org_access ON budget_requests;

-- Read: the requester's own request at any status, any pending request
-- org-wide (unchanged visibility — see note above), or any request at all
-- once you are ranked to decide budget requests (manager/partner).
CREATE POLICY budget_requests_select ON budget_requests FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      status = 'pending' OR requested_by = auth_profile_id() OR auth_rank() >= 70
    )
  );

CREATE POLICY budget_requests_insert ON budget_requests FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND requested_by = auth_profile_id());

-- Decide: manager/partner only, and — matching CAN.approveBudget() — never
-- your own request unless you are a partner.
CREATE POLICY budget_requests_update ON budget_requests FOR UPDATE TO authenticated
  USING (
    organization_id = auth_org_id() AND auth_rank() >= 70
    AND (requested_by <> auth_profile_id() OR auth_rank() >= 90)
  )
  WITH CHECK (organization_id = auth_org_id());

-- ---- 2. expense_claims: owner + decision-authorized roles only -----------------
DROP POLICY IF EXISTS authenticated_org_access ON expense_claims;

-- Read: your own claim at any status; anyone ranked to decide claims
-- (manager/partner) sees every claim; accounts sees approved/paid claims
-- only — matching CAN.payClaim(), which never decides, only pays.
CREATE POLICY expense_claims_select ON expense_claims FOR SELECT TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR auth_rank() >= 70
      OR (auth_role() = 'accounts' AND status IN ('approved', 'paid'))
    )
  );

CREATE POLICY expense_claims_insert ON expense_claims FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND profile_id = auth_profile_id());

-- Write: the owner submitting their own draft, a manager/partner deciding
-- someone else's claim, or accounts marking an approved claim paid.
CREATE POLICY expense_claims_update ON expense_claims FOR UPDATE TO authenticated
  USING (
    organization_id = auth_org_id() AND (
      profile_id = auth_profile_id()
      OR (auth_rank() >= 70 AND profile_id <> auth_profile_id())
      OR auth_role() = 'accounts'
    )
  )
  WITH CHECK (organization_id = auth_org_id());

-- ---- 2. expense_claim_lines: mirrors its parent claim's scope ------------------
DROP POLICY IF EXISTS authenticated_org_access ON expense_claim_lines;

CREATE POLICY expense_claim_lines_select ON expense_claim_lines FOR SELECT TO authenticated
  USING (
    claim_id IN (
      SELECT id FROM expense_claims WHERE organization_id = auth_org_id() AND (
        profile_id = auth_profile_id()
        OR auth_rank() >= 70
        OR (auth_role() = 'accounts' AND status IN ('approved', 'paid'))
      )
    )
  );

-- Lines are only ever added by the claim's own owner, while it is still theirs.
CREATE POLICY expense_claim_lines_insert ON expense_claim_lines FOR INSERT TO authenticated
  WITH CHECK (
    claim_id IN (SELECT id FROM expense_claims WHERE organization_id = auth_org_id() AND profile_id = auth_profile_id())
  );
