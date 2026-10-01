-- ==============================================================================
-- 025: NO TASK ASSIGNMENT ON A CLOSED JOB
-- ==============================================================================
-- Once jobs.status = 'closed', a task can no longer be created on that job,
-- moved onto it, or (re)assigned to someone. Reopening the job (status back
-- to open/in_progress — the existing reopenJob() path) restores all of it.
--
-- Nothing is deleted or changed: closing a job still only updates the jobs
-- row, and existing tasks, their responsibility history, timesheets,
-- approvals and costs stay exactly as they are. Only INSERT, and UPDATEs
-- that change job_id or assigned_to, are checked — status/cost edits and
-- every existing row are unaffected.
-- ==============================================================================

CREATE OR REPLACE FUNCTION block_task_assignment_on_closed_job()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  j_code TEXT;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.job_id IS NOT DISTINCT FROM OLD.job_id
     AND NEW.assigned_to IS NOT DISTINCT FROM OLD.assigned_to THEN
    RETURN NEW;
  END IF;

  SELECT job_code INTO j_code
  FROM jobs
  WHERE organization_id = NEW.organization_id AND id = NEW.job_id AND status = 'closed';

  IF FOUND THEN
    RAISE EXCEPTION 'Job % is closed — tasks can no longer be assigned. Reopen the job first.', j_code
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION block_task_assignment_on_closed_job() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_tasks_closed_job ON tasks;
CREATE TRIGGER trg_tasks_closed_job
  BEFORE INSERT OR UPDATE OF job_id, assigned_to ON tasks
  FOR EACH ROW EXECUTE FUNCTION block_task_assignment_on_closed_job();
