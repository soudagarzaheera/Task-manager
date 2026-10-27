-- ==============================================================================
-- 031: ORGANIZATION INITIAL-SETUP STATE
-- ==============================================================================
-- The app used to send every partner to Sites & Clients on every load. That
-- page is meant as the first-run step for the person who just created the
-- organization, so whether setup is still pending now lives in the database:
--
--   organizations.setup_completed_at  NULL = initial setup still pending
--
-- * New organizations: provision_signup_company() (016) and the legacy
--   bootstrap_first_admin() (014/015) insert organizations with only a name,
--   so the column starts NULL — no change to signup.
-- * Existing organizations that already have a client or a site are marked
--   complete now (they are configured).
-- * Setup completes automatically when the organization's first client or
--   first site (locations) is added — trigger, so it holds however the row
--   is created. A partner can also finish it explicitly via
--   complete_organization_setup() (the "Skip setup" link).
-- * Once set it is never cleared: deleting clients/sites later does not put
--   the organization back into setup.
--
-- organizations has no client UPDATE policy; both writers below are
-- SECURITY DEFINER and only ever touch the caller's / row's own organization.
-- Safe to re-run.
-- ==============================================================================

ALTER TABLE organizations ADD COLUMN IF NOT EXISTS setup_completed_at TIMESTAMPTZ;

UPDATE organizations o SET setup_completed_at = now()
WHERE o.setup_completed_at IS NULL
  AND (EXISTS (SELECT 1 FROM clients c WHERE c.organization_id = o.id)
    OR EXISTS (SELECT 1 FROM locations l WHERE l.organization_id = o.id));

-- ---- first client / site completes setup ------------------------------------
CREATE OR REPLACE FUNCTION mark_organization_setup_complete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE organizations SET setup_completed_at = now()
  WHERE id = NEW.organization_id AND setup_completed_at IS NULL;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION mark_organization_setup_complete() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_clients_setup_complete ON clients;
CREATE TRIGGER trg_clients_setup_complete
  AFTER INSERT ON clients
  FOR EACH ROW EXECUTE FUNCTION mark_organization_setup_complete();

DROP TRIGGER IF EXISTS trg_locations_setup_complete ON locations;
CREATE TRIGGER trg_locations_setup_complete
  AFTER INSERT ON locations
  FOR EACH ROW EXECUTE FUNCTION mark_organization_setup_complete();

-- ---- explicit finish ("Skip setup"): partners of the caller's organization ----
CREATE OR REPLACE FUNCTION complete_organization_setup()
RETURNS TIMESTAMPTZ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  done TIMESTAMPTZ;
BEGIN
  IF auth_rank() < 90 THEN
    RAISE EXCEPTION 'Only a partner can complete the organization setup.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  UPDATE organizations SET setup_completed_at = COALESCE(setup_completed_at, now())
  WHERE id = auth_org_id()
  RETURNING setup_completed_at INTO done;
  RETURN done;
END;
$$;
REVOKE ALL ON FUNCTION complete_organization_setup() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION complete_organization_setup() TO authenticated;
