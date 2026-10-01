-- ==============================================================================
-- 019: COMBINE CASUAL + SICK LEAVE INTO ONE "Casual/Sick Leave" (CSL) TYPE
-- ==============================================================================
-- Scope: ONE organization only (target_org below). Other organizations'
-- leave types, leaves and overrides are not touched.
--
-- Inspected first:
--   * leaves.leave_type is a plain code (no FK), CHECK-limited to
--     CL/EL/SL/ML/PL/LWP. leave_types.code has the same CHECK.
--   * employee_leave_balances.(organization_id, leave_type_code) is the only
--     FK into leave_types (ON DELETE CASCADE, no ON UPDATE) — so renaming or
--     deleting the CL/SL rows would either fail or cascade-delete overrides.
--
-- Therefore:
--   1. Both CHECK constraints are extended with 'CSL' (the only schema change;
--      the existing codes stay valid).
--   2. A new CSL row is added (12 days, paid, active) unless one already
--      exists — never duplicated.
--   3. CL and SL are deactivated, not deleted or renamed: their rows keep
--      existing overrides valid and keep history resolvable.
--   4. Per-employee CL/SL overrides are copied to CSL for the same
--      profile/year (CL's value preferred, else SL's) where no CSL override
--      exists yet. The originals are left in place.
--   5. No `leaves` row is modified. Historical CL/SL days keep their original
--      code; index.html reads them as CSL whenever the organization has an
--      active CSL type, so they display as Casual/Sick Leave and count toward
--      the single 12-day balance.
-- Idempotent: safe to run more than once.
-- ==============================================================================

-- ---- 1. allow the new code ------------------------------------------------------
ALTER TABLE leave_types DROP CONSTRAINT IF EXISTS leave_types_code_check;
ALTER TABLE leave_types ADD CONSTRAINT leave_types_code_check
  CHECK (code IN ('CL', 'EL', 'SL', 'ML', 'PL', 'LWP', 'CSL'));

ALTER TABLE leaves DROP CONSTRAINT IF EXISTS leaves_leave_type_check;
ALTER TABLE leaves ADD CONSTRAINT leaves_leave_type_check
  CHECK (leave_type IN ('CL', 'EL', 'SL', 'ML', 'PL', 'LWP', 'CSL'));

-- ---- 2-4. organization-specific data change ---------------------------------------
DO $$
DECLARE
  target_org CONSTANT UUID := '1686f5d6-abe4-43d9-8a5b-4204a4a71d71';  -- Fynalliance Advisors
BEGIN
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = target_org) THEN
    RAISE NOTICE '019: organization % not found — no leave types changed', target_org;
    RETURN;
  END IF;

  INSERT INTO leave_types (organization_id, code, label, annual_days, is_paid, is_active)
  VALUES (target_org, 'CSL', 'Casual/Sick Leave', 12, true, true)
  ON CONFLICT (organization_id, code) DO NOTHING;

  UPDATE leave_types
     SET is_active = false
   WHERE organization_id = target_org
     AND code IN ('CL', 'SL')
     AND is_active;

  INSERT INTO employee_leave_balances (organization_id, profile_id, leave_type_code, leave_year, allocated_days)
  SELECT DISTINCT ON (b.profile_id, b.leave_year)
         b.organization_id, b.profile_id, 'CSL', b.leave_year, b.allocated_days
    FROM employee_leave_balances b
   WHERE b.organization_id = target_org
     AND b.leave_type_code IN ('CL', 'SL')
   ORDER BY b.profile_id, b.leave_year, (b.leave_type_code = 'CL') DESC
  ON CONFLICT (profile_id, leave_type_code, leave_year) DO NOTHING;
END $$;


INSERT INTO leave_types (organization_id, code, label, annual_days, is_paid, is_active)
SELECT o.id, t.code, t.label, t.annual_days, t.is_paid, true
FROM organizations o
CROSS JOIN (VALUES
    ('CSL', 'Casual/Sick Leave',  12,  true),
    ('EL',  'Earned Leave',        0,  true),
    ('ML',  'Maternity Leave',   182,  true),
    ('PL',  'Paternity Leave',    15,  true),
    ('LWP', 'Leave Without Pay',   0,  false)
) AS t(code, label, annual_days, is_paid)
WHERE o.id = '9b7f8895-4f40-4f81-8af6-a0f4641bcaba'
ON CONFLICT (organization_id, code) DO NOTHING;


ALTER TABLE leave_types DROP CONSTRAINT IF EXISTS leave_types_code_check;
ALTER TABLE leave_types ADD CONSTRAINT leave_types_code_check
  CHECK (code ~ '^[A-Z][A-Z0-9]{1,9}$');

ALTER TABLE leaves DROP CONSTRAINT IF EXISTS leaves_leave_type_check;
ALTER TABLE leaves DROP CONSTRAINT IF EXISTS fk_leaves_leave_type;
ALTER TABLE leaves ADD CONSTRAINT fk_leaves_leave_type
  FOREIGN KEY (organization_id, leave_type) REFERENCES leave_types(organization_id, code) ON DELETE RESTRICT;

ALTER TABLE leaves ALTER COLUMN leave_type DROP DEFAULT;


CREATE OR REPLACE FUNCTION job_approved_extra_hours()
RETURNS TABLE (job_id UUID, extra_hours NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT b.job_id, SUM(b.to_hours - b.from_hours)
  FROM budget_requests b
  WHERE b.organization_id = auth_org_id()
    AND b.status = 'approved'
  GROUP BY b.job_id;
$$;

REVOKE ALL ON FUNCTION job_approved_extra_hours() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_approved_extra_hours() TO authenticated;
