-- ==============================================================================
-- 034: STATUTORY DATES + CUSTOMISABLE CATEGORIES (Statutory calendar)
-- ==============================================================================
-- Inspected first (live DB, 2026-10-27): statutory_compliances is empty in
-- every organization, requires a client and is shaped for auto-raising job
-- codes (nothing raises them — no function or cron uses it). It is left
-- untouched; firm-entered statutory deadlines get their own table.
--
--   statutory_categories  one list per organization, shared by its companies
--                         (like leave types). Customisable; starter list seeded.
--   statutory_dates       each date belongs to one company (GST/TDS etc. are
--                         filed per company), optionally to one of its
--                         clients — a client's date always takes the
--                         client's company (trigger, section 2b).
-- The app lists these dates beside statutory_compliances rows in the
-- Statutory calendar's "Next 60 days" table.
--
-- Access (existing helpers, 028/030):
--   * Read: everyone in a company they can access — auth_company_ok():
--     partners every company of their organization, everyone else their own.
--     Categories are readable organization-wide.
--   * Write: Partner, Manager and Assistant Manager (auth_rank() >= 60), only
--     within companies they can access. Same bar as raising job codes.
--   * A category in use cannot be deleted (FK RESTRICT) — deactivate it.
--   * anon has no privileges.
-- reminder_days_before is not used by the app (reminders were dropped); no
-- notification trigger reads this table.
-- Safe to re-run (re-running on a database that already has 034 adds only
-- what is missing, e.g. client_id).
-- ==============================================================================

-- ---- 1. categories ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS statutory_categories (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name            TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  is_active       BOOLEAN NOT NULL DEFAULT true,
  sort_order      INTEGER NOT NULL DEFAULT 100,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_statutory_categories_org_id UNIQUE (organization_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_statutory_categories_org_name
  ON statutory_categories (organization_id, lower(btrim(name)));

DROP TRIGGER IF EXISTS trg_statutory_categories_updated_at ON statutory_categories;
CREATE TRIGGER trg_statutory_categories_updated_at BEFORE UPDATE ON statutory_categories
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ---- 2. dates --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS statutory_dates (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  company_id           UUID NOT NULL,
  client_id            UUID,
  category_id          UUID NOT NULL,
  title                TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 200),
  due_date             DATE NOT NULL,
  description          TEXT CHECK (description IS NULL OR char_length(description) <= 2000),
  reminder_days_before INTEGER CHECK (reminder_days_before IS NULL OR reminder_days_before BETWEEN 0 AND 60),
  created_by           UUID DEFAULT auth_profile_id(),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_statutory_dates_company  FOREIGN KEY (organization_id, company_id)
    REFERENCES companies(organization_id, id),
  CONSTRAINT fk_statutory_dates_category FOREIGN KEY (organization_id, category_id)
    REFERENCES statutory_categories(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT fk_statutory_dates_creator  FOREIGN KEY (organization_id, created_by)
    REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_statutory_dates_company_due
  ON statutory_dates (organization_id, company_id, due_date);

DROP TRIGGER IF EXISTS trg_statutory_dates_updated_at ON statutory_dates;
CREATE TRIGGER trg_statutory_dates_updated_at BEFORE UPDATE ON statutory_dates
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ---- 2b. optional client -----------------------------------------------------------
-- ADD COLUMN covers a database where the table was created before client_id
-- existed. Deleting a client clears only client_id (the date stays, company-wide).
ALTER TABLE statutory_dates ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE statutory_dates DROP CONSTRAINT IF EXISTS fk_statutory_dates_client;
ALTER TABLE statutory_dates ADD CONSTRAINT fk_statutory_dates_client
  FOREIGN KEY (organization_id, client_id) REFERENCES clients(organization_id, id)
  ON DELETE SET NULL (client_id);

-- A client's date always belongs to the client's company, so the company-based
-- RLS below also governs which clients a writer can attach.
CREATE OR REPLACE FUNCTION statutory_dates_client_company()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.client_id IS NOT NULL THEN
    SELECT company_id INTO NEW.company_id FROM clients
     WHERE id = NEW.client_id AND organization_id = NEW.organization_id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION statutory_dates_client_company() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_statutory_dates_client_company ON statutory_dates;
CREATE TRIGGER trg_statutory_dates_client_company
  BEFORE INSERT OR UPDATE OF client_id, company_id ON statutory_dates
  FOR EACH ROW EXECUTE FUNCTION statutory_dates_client_company();

-- ---- 3. RLS + grants ---------------------------------------------------------------
-- Supabase's default privileges grant ALL (incl. TRUNCATE, which ignores RLS)
-- on new tables; reset authenticated to exactly the four row operations.
ALTER TABLE statutory_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE statutory_dates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON statutory_categories, statutory_dates FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON statutory_categories, statutory_dates TO authenticated;

DROP POLICY IF EXISTS statutory_categories_select ON statutory_categories;
CREATE POLICY statutory_categories_select ON statutory_categories FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
DROP POLICY IF EXISTS statutory_categories_insert ON statutory_categories;
CREATE POLICY statutory_categories_insert ON statutory_categories FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);
DROP POLICY IF EXISTS statutory_categories_update ON statutory_categories;
CREATE POLICY statutory_categories_update ON statutory_categories FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);
DROP POLICY IF EXISTS statutory_categories_delete ON statutory_categories;
CREATE POLICY statutory_categories_delete ON statutory_categories FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60);

DROP POLICY IF EXISTS statutory_dates_select ON statutory_dates;
CREATE POLICY statutory_dates_select ON statutory_dates FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id));
DROP POLICY IF EXISTS statutory_dates_insert ON statutory_dates;
CREATE POLICY statutory_dates_insert ON statutory_dates FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60);
DROP POLICY IF EXISTS statutory_dates_update ON statutory_dates;
CREATE POLICY statutory_dates_update ON statutory_dates FOR UPDATE TO authenticated
  USING      (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60);
DROP POLICY IF EXISTS statutory_dates_delete ON statutory_dates;
CREATE POLICY statutory_dates_delete ON statutory_dates FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60);

-- ---- 4. starter categories -----------------------------------------------------------
-- New organizations: seeded on creation, like 2026 holidays (017).
CREATE OR REPLACE FUNCTION seed_statutory_categories_for_org()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO statutory_categories (organization_id, name, sort_order)
  VALUES
    (NEW.id, 'GST', 10), (NEW.id, 'Income Tax', 20), (NEW.id, 'TDS', 30), (NEW.id, 'ROC', 40),
    (NEW.id, 'PF/ESI', 50), (NEW.id, 'Professional Tax', 60), (NEW.id, 'Other', 1000)
  ON CONFLICT (organization_id, lower(btrim(name))) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION seed_statutory_categories_for_org() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_seed_statutory_categories ON organizations;
CREATE TRIGGER trg_seed_statutory_categories
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION seed_statutory_categories_for_org();

-- Existing organizations: once (a name that already exists is skipped).
INSERT INTO statutory_categories (organization_id, name, sort_order)
SELECT o.id, c.name, c.sort_order
FROM organizations o
CROSS JOIN (VALUES
  ('GST', 10), ('Income Tax', 20), ('TDS', 30), ('ROC', 40),
  ('PF/ESI', 50), ('Professional Tax', 60), ('Other', 1000)
) AS c(name, sort_order)
ON CONFLICT (organization_id, lower(btrim(name))) DO NOTHING;

