-- ==============================================================================
-- 046: COMPANY HOLIDAYS — MANAGERS & ASSISTANT MANAGERS, LIVE UPDATES
-- ==============================================================================
-- Builds on 043 (holiday management). Holidays stay ONE organization-wide list,
-- shown in every employee's calendar whatever their company, designation or
-- role.
--
--   * Write access widens from Partners only (auth_rank() >= 90, 036) to
--     Partners, Managers and Assistant Managers (auth_rank() >= 60), within
--     their own organization. Not limited to the writer's company: a holiday
--     is organization-wide by design. Everyone else keeps read-only access
--     (holidays_select, 036, unchanged).
--   * The past-date lock from 043 (trg_guard_holiday_change) is unchanged and
--     applies to every writer: a holiday dated today or earlier cannot be
--     added, moved or deleted, so attendance and earned leave already
--     recorded for it are never rewritten.
--   * holidays joins the supabase_realtime publication, so open apps refresh
--     their holiday list as soon as anyone adds, edits or deletes one.
--     Realtime applies holidays_select (RLS) to each subscriber.
--
-- Additive: no data changes. Safe to re-run. Independent of 044 / 045.
-- ==============================================================================

DROP POLICY IF EXISTS holidays_write ON holidays;
CREATE POLICY holidays_write ON holidays FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);

-- Realtime: add the table once (the publication exists on every Supabase
-- project; skip quietly where it does not, e.g. a plain Postgres test DB).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
                     WHERE pubname = 'supabase_realtime'
                       AND schemaname = 'public' AND tablename = 'holidays') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.holidays;
  END IF;
END;
$$;
