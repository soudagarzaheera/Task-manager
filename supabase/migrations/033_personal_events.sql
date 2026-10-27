-- ==============================================================================
-- 033: PERSONAL EVENTS (My calendar)
-- ==============================================================================
-- A personal event belongs to the Supabase Auth login that created it and is
-- visible to nobody else — not a supervisor, not a partner, not another
-- company. Privacy is enforced here by RLS, not by the app:
--   * user_id defaults to auth.uid(); the app never sends it, and the INSERT
--     check rejects any other value sent through the API directly.
--   * Every policy is user_id = auth.uid() alone — no organization, company,
--     role or auth_rank() exception — so elevated roles get no extra access.
--   * UPDATE checks ownership on the existing row (USING) and on the resulting
--     row (WITH CHECK), so ownership can never be transferred.
--   * anon has no privileges. No shared helper, report, notification trigger
--     or Edge Function reads this table.
-- Deleting the login deletes its events. Safe to re-run.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS personal_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  title       TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 200),
  description TEXT CHECK (description IS NULL OR char_length(description) <= 2000),
  event_date  DATE NOT NULL,
  start_time  TIME,
  end_time    TIME,
  is_all_day  BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT personal_events_all_day_no_times CHECK (NOT is_all_day OR (start_time IS NULL AND end_time IS NULL)),
  CONSTRAINT personal_events_end_needs_start  CHECK (end_time IS NULL OR start_time IS NOT NULL),
  CONSTRAINT personal_events_end_after_start  CHECK (end_time IS NULL OR end_time >= start_time)
);

CREATE INDEX IF NOT EXISTS idx_personal_events_user_date ON personal_events (user_id, event_date);

DROP TRIGGER IF EXISTS trg_personal_events_updated_at ON personal_events;
CREATE TRIGGER trg_personal_events_updated_at BEFORE UPDATE ON personal_events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE personal_events ENABLE ROW LEVEL SECURITY;

-- Supabase's default privileges grant ALL (incl. TRUNCATE, which ignores RLS)
-- on new tables; reset authenticated to exactly the four row operations.
REVOKE ALL ON personal_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON personal_events TO authenticated;

DROP POLICY IF EXISTS personal_events_select ON personal_events;
CREATE POLICY personal_events_select ON personal_events FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS personal_events_insert ON personal_events;
CREATE POLICY personal_events_insert ON personal_events FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS personal_events_update ON personal_events;
CREATE POLICY personal_events_update ON personal_events FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS personal_events_delete ON personal_events;
CREATE POLICY personal_events_delete ON personal_events FOR DELETE TO authenticated
  USING (user_id = auth.uid());
