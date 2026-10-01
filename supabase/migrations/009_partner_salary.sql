-- Partner-only salary history. Existing profile CTC is copied at joining_date,
-- the earliest effective date available in the current schema.
CREATE TABLE IF NOT EXISTS employee_salary_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL,
  monthly_ctc NUMERIC(12,2) NOT NULL CHECK (monthly_ctc >= 0),
  effective_from DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  CONSTRAINT fk_salary_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT uq_salary_effective UNIQUE (profile_id, effective_from)
);
CREATE INDEX IF NOT EXISTS idx_salary_history_lookup
  ON employee_salary_history (organization_id, profile_id, effective_from DESC);
ALTER TABLE employee_salary_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS salary_partner_only ON employee_salary_history;
CREATE POLICY salary_partner_only ON employee_salary_history FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_is_partner())
  WITH CHECK (organization_id = auth_org_id() AND auth_is_partner());

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='profiles' AND column_name='monthly_ctc') THEN
    EXECUTE $q$
      INSERT INTO employee_salary_history (organization_id, profile_id, monthly_ctc, effective_from)
      SELECT organization_id, id, monthly_ctc, joining_date FROM profiles
      WHERE monthly_ctc IS NOT NULL AND monthly_ctc > 0
      ON CONFLICT (profile_id, effective_from) DO NOTHING
    $q$;
  END IF;
END $$;

-- CTC on profiles was included in SELECT * for every employee. Remove that
-- leak; the history table is now the sole authorized salary source.
ALTER TABLE profiles DROP COLUMN IF EXISTS monthly_ctc;

-- Leave classifications are also exposed as a tiny function for the salary
-- calculation to use without inventing leave policy defaults.
