-- ==============================================================================
-- 032: JOB CODE EDITING — SAME PERMISSION AS CREATING
-- ==============================================================================
-- The app now lets a job code's details be edited (Job codes -> Edit). Editing
-- follows the create rule from 030: Assistant Manager and above
-- (auth_rank() >= 60). Until now jobs_update (028) let anyone who could see a
-- job update it through the API; this adds the rank check so the database
-- matches the app. Visibility and organization scoping are unchanged.
--
-- Who updates jobs today, all still allowed: create/edit (AM+), close and
-- reopen (Manager+, rank 70). No database function updates jobs as the
-- signed-in user. Company moves stay partner-only (set_record_company, 028).
-- Safe to re-run.
-- ==============================================================================

DROP POLICY IF EXISTS jobs_update ON jobs;
CREATE POLICY jobs_update ON jobs FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_job_visible(id) AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);
