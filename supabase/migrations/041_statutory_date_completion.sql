-- ==============================================================================
-- 041: MARK A MANUALLY ADDED STATUTORY DATE AS DONE
-- ==============================================================================
-- statutory_dates has no status, so an overdue date could only be hidden or
-- deleted. These two columns let the calendar keep an overdue date visible until
-- someone marks it done, and undo that. completed_at IS NULL means not done.
--
-- Access is unchanged: statutory_dates_update (034) already limits writes to
-- Partner, Manager and Assistant Manager, within companies they can access.
-- Additive: existing rows and the app already installed are unaffected.
-- Safe to re-run.
-- ==============================================================================

ALTER TABLE statutory_dates ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;
ALTER TABLE statutory_dates ADD COLUMN IF NOT EXISTS completed_by UUID;

ALTER TABLE statutory_dates DROP CONSTRAINT IF EXISTS fk_statutory_dates_completed_by;
ALTER TABLE statutory_dates ADD CONSTRAINT fk_statutory_dates_completed_by
  FOREIGN KEY (organization_id, completed_by) REFERENCES profiles(organization_id, id)
  ON DELETE SET NULL (completed_by);
