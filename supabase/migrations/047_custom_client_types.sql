-- ==============================================================================
-- 047: CUSTOM CLIENT TYPES
-- ==============================================================================
-- clients.entity_type was limited by clients_entity_type_check (001) to nine
-- values (Individual … Society), so an OPC, Section 8 company, AOP, BOI,
-- government entity, cooperative society, foreign company, etc. could not be
-- saved from the Add Client form or the Excel import.
--
--   * clients_entity_type_check is replaced by chk_clients_entity_type: any
--     text with no leading/trailing spaces, 1–100 characters. The value is
--     stored exactly as entered (after trimming); no list of permitted types.
--   * Unchanged: NOT NULL, DEFAULT 'Private Ltd', every other clients column,
--     constraint and policy. No existing row is modified (all current values
--     already satisfy the new check).
--
-- Inspected first (live, read-only, 2026-11-11): the only CHECK on clients is
-- clients_entity_type_check; no function or view reads clients.entity_type.
--
-- Safe to re-run.
-- ==============================================================================

ALTER TABLE clients DROP CONSTRAINT IF EXISTS clients_entity_type_check;
ALTER TABLE clients DROP CONSTRAINT IF EXISTS chk_clients_entity_type;
ALTER TABLE clients ADD CONSTRAINT chk_clients_entity_type
  CHECK (entity_type = btrim(entity_type) AND length(entity_type) BETWEEN 1 AND 100);
