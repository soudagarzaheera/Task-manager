-- ==============================================================================
-- 035: JOB SERVICES (New job code → Service list)
-- ==============================================================================
-- Inspected first (live DB, 2026-10-27): there is no services table. The
-- service list was hardcoded in index.html (SERVICES) and jobs store only the
-- short code as free text in jobs.service_category (001) — e.g. 'STATAUD'.
-- That column is left untouched: it keeps storing the code, and the code is
-- still what the suggested job code is built from (CLIENT/STATAUD/2026-27).
--
--   job_services  one list per organization, shared by its companies (like
--                 leave types and statutory categories). The 14 services the
--                 app shipped with are seeded with the same codes, so every
--                 existing job keeps matching its service.
--
-- Access (existing helpers, 030):
--   * Read: everyone in the organization.
--   * Add: Partner, Manager and Assistant Manager (auth_rank() >= 60) — the
--     same people who can raise a job code.
--   * No UPDATE / DELETE privilege: there is no management screen yet.
--   * anon has no privileges.
-- Duplicates: a name or a code may appear once per organization, ignoring
-- case and surrounding spaces.
-- Safe to re-run.
-- ==============================================================================

-- ---- 1. table ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS job_services (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code            TEXT NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9]{1,9}$'),
  name            TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  is_active       BOOLEAN NOT NULL DEFAULT true,
  sort_order      INTEGER NOT NULL DEFAULT 100,
  created_by      UUID DEFAULT auth_profile_id(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_job_services_creator FOREIGN KEY (organization_id, created_by)
    REFERENCES profiles(organization_id, id) ON DELETE SET NULL (created_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_job_services_org_code
  ON job_services (organization_id, code);
CREATE UNIQUE INDEX IF NOT EXISTS uq_job_services_org_name
  ON job_services (organization_id, lower(btrim(name)));

DROP TRIGGER IF EXISTS trg_job_services_updated_at ON job_services;
CREATE TRIGGER trg_job_services_updated_at BEFORE UPDATE ON job_services
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ---- 2. RLS + grants -------------------------------------------------------------
-- Supabase's default privileges grant ALL (incl. TRUNCATE, which ignores RLS)
-- on new tables; reset authenticated to exactly read + add.
ALTER TABLE job_services ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON job_services FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON job_services TO authenticated;

DROP POLICY IF EXISTS job_services_select ON job_services;
CREATE POLICY job_services_select ON job_services FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
DROP POLICY IF EXISTS job_services_insert ON job_services;
CREATE POLICY job_services_insert ON job_services FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);

-- ---- 3. starter services -----------------------------------------------------------
-- The list index.html shipped with, codes unchanged (existing jobs use them).
-- New organizations: seeded on creation, like statutory categories (034).
CREATE OR REPLACE FUNCTION seed_job_services_for_org()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO job_services (organization_id, code, name, sort_order, created_by)
  VALUES
    (NEW.id, 'STATAUD', 'Statutory Audit',     10, NULL), (NEW.id, 'TAXAUD', 'Tax Audit',         20, NULL),
    (NEW.id, 'INTAUD',  'Internal Audit',      30, NULL), (NEW.id, 'GSTR1',  'GSTR-1',            40, NULL),
    (NEW.id, 'GSTR3B',  'GSTR-3B',             50, NULL), (NEW.id, 'GSTR9',  'GST Annual Return', 60, NULL),
    (NEW.id, 'ITRNA',   'ITR — non-audit',     70, NULL), (NEW.id, 'ITRAUD', 'ITR — audit case',  80, NULL),
    (NEW.id, 'TDSRET',  'TDS Return',          90, NULL), (NEW.id, 'AOC4',   'ROC — AOC-4',      100, NULL),
    (NEW.id, 'MGT7',    'ROC — MGT-7',        110, NULL), (NEW.id, 'ACCTG',  'Bookkeeping',      120, NULL),
    (NEW.id, 'CERT',    'Certification',      130, NULL), (NEW.id, 'ADV',    'Advisory',         140, NULL)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION seed_job_services_for_org() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_seed_job_services ON organizations;
CREATE TRIGGER trg_seed_job_services
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION seed_job_services_for_org();

-- Existing organizations: once (a code or name that already exists is skipped).
INSERT INTO job_services (organization_id, code, name, sort_order, created_by)
SELECT o.id, s.code, s.name, s.sort_order, NULL
FROM organizations o
CROSS JOIN (VALUES
  ('STATAUD', 'Statutory Audit',     10), ('TAXAUD', 'Tax Audit',         20),
  ('INTAUD',  'Internal Audit',      30), ('GSTR1',  'GSTR-1',            40),
  ('GSTR3B',  'GSTR-3B',             50), ('GSTR9',  'GST Annual Return', 60),
  ('ITRNA',   'ITR — non-audit',     70), ('ITRAUD', 'ITR — audit case',  80),
  ('TDSRET',  'TDS Return',          90), ('AOC4',   'ROC — AOC-4',      100),
  ('MGT7',    'ROC — MGT-7',        110), ('ACCTG',  'Bookkeeping',      120),
  ('CERT',    'Certification',      130), ('ADV',    'Advisory',         140)
) AS s(code, name, sort_order)
ON CONFLICT DO NOTHING;
