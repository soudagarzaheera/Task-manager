-- ==============================================================================
-- 018: LINK TIMESHEET ENTRIES TO WORK TASKS + COMPLETE TASK ON APPROVAL
-- ==============================================================================
-- Context: timesheet_entries.task_id (with a composite FK to tasks) has existed
-- since 001_initial_schema.sql but the app never wrote it. The Timesheet screen
-- now lets a user optionally pick one of the selected job code's tasks, and
-- stores that task's id here — no new table, no copy of the task name.
--
-- This migration:
--   1. Makes deleting a task null only task_id on referencing timesheet rows.
--      The original composite FK's plain ON DELETE SET NULL would also try to
--      null organization_id (NOT NULL), so the delete would fail instead.
--   2. Rejects a task_id that does not belong to the entry's own job_id (the
--      composite FK only guarantees the same organization). Only checked when
--      task_id/job_id is set or changed, so historical rows are untouched.
--   3. When an entry with a task_id becomes 'approved', marks that one task
--      'completed' (shown as "Done" in the Work module). This is an AFTER
--      trigger on the same UPDATE the approver issues, so the approval and the
--      task update commit or roll back together. It runs as the caller
--      (SECURITY INVOKER), so the tasks table's existing RLS still applies,
--      and only fires for a manager/partner (auth_rank() >= 70, the same rank
--      map as CAN in index.html) — or a trusted backend session with no
--      auth.uid(). Draft/pending/queried entries never touch the task.
-- ==============================================================================

-- ---- 1. FK: null only task_id when a task is deleted ---------------------------
ALTER TABLE timesheet_entries DROP CONSTRAINT IF EXISTS fk_timesheet_task;
ALTER TABLE timesheet_entries
  ADD CONSTRAINT fk_timesheet_task FOREIGN KEY (organization_id, task_id)
  REFERENCES tasks(organization_id, id) ON DELETE SET NULL (task_id);

CREATE INDEX IF NOT EXISTS idx_timesheet_entries_task
  ON timesheet_entries (organization_id, task_id) WHERE task_id IS NOT NULL;

-- ---- 2. task must belong to the entry's job ------------------------------------
CREATE OR REPLACE FUNCTION check_timesheet_task_job()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.task_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.task_id IS NOT DISTINCT FROM OLD.task_id
     AND NEW.job_id IS NOT DISTINCT FROM OLD.job_id THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.organization_id = NEW.organization_id
      AND t.id = NEW.task_id
      AND t.job_id = NEW.job_id
  ) THEN
    RAISE EXCEPTION 'Task does not belong to the selected job code'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_timesheet_task_job ON timesheet_entries;
CREATE TRIGGER trg_timesheet_task_job
  BEFORE INSERT OR UPDATE OF task_id, job_id ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION check_timesheet_task_job();

-- ---- 3. approved entry -> its task is Done -------------------------------------
CREATE OR REPLACE FUNCTION complete_task_on_timesheet_approval()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.task_id IS NULL OR NEW.status <> 'approved' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;
  IF auth.uid() IS NOT NULL AND auth_rank() < 70 THEN
    RETURN NEW;
  END IF;

  -- Several approved entries can point at the same task; the first completes
  -- it and the rest are no-ops, so completed_at keeps the first approval time.
  UPDATE tasks
     SET status = 'completed',
         completed_at = COALESCE(completed_at, now())
   WHERE organization_id = NEW.organization_id
     AND id = NEW.task_id
     AND job_id = NEW.job_id
     AND status <> 'completed';

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_timesheet_task_approved ON timesheet_entries;
CREATE TRIGGER trg_timesheet_task_approved
  AFTER INSERT OR UPDATE OF status ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION complete_task_on_timesheet_approval();

REVOKE ALL ON FUNCTION check_timesheet_task_job() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION complete_task_on_timesheet_approval() FROM PUBLIC, anon, authenticated;
