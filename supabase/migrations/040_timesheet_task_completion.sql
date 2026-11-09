-- ==============================================================================
-- 040: COMPLETE A TASK FROM APPROVED TIME — SAFELY (replaces 018, which never ran)
-- ==============================================================================
-- Inspected first (live DB, 2026-11-05): nothing from 018 exists — no functions,
-- no triggers, the old foreign key — yet index.html expects the behaviour.
-- 018's rule must not be applied: any one approved entry completed the task, and
-- 4 of the 6 linked entries live were logged by someone other than the assignee.
--
-- A task now becomes Done only when an entry moves to 'approved' and ALL hold:
--   1. the entry names that exact task, on the same organization and job;
--   2. the entry was logged by the task's current assignee;
--   3. the task is 'todo' or 'in_progress' — "Waiting on client", "For review"
--      and "Changes asked" are someone's explicit decision and are left alone;
--   4. the job is not closed;
--   5. none of the assignee's other entries on the task is still unapproved;
--   6. the assignee's approved hours on the task reach its estimated hours.
-- Otherwise nothing changes and the status stays manual, as it is today.
--
-- Undoing an approval reopens the task (as 'in_progress') only if this trigger
-- completed it and nobody has changed it since: tasks.auto_completed_at must
-- still equal completed_at. A task someone marked Done by hand is never touched.
--
-- Who may approve is already decided by guard_timesheet_entry() (036), so 018's
-- rank check is dropped: it left Assistant Managers' approvals with no effect.
-- SECURITY DEFINER because the approver may not be able to update the task under
-- RLS / guard_task_update(). Only the one task named by the entry is ever updated.
-- A failure here logs a warning and never blocks the approval.
-- Existing rows are not back-filled: past approvals change nothing.
-- Safe to re-run.
-- ==============================================================================

DO $$
BEGIN
  IF to_regprocedure('guard_timesheet_entry()') IS NULL THEN
    RAISE EXCEPTION '040 needs 036_rbac_parity_and_hardening.sql first';
  END IF;
END $$;

-- ---- 1. marker: this task was completed by the trigger -----------------------------
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS auto_completed_at TIMESTAMPTZ;

-- ---- 2. FK: deleting a task nulls only task_id (from 018) ---------------------------
-- The plain ON DELETE SET NULL would also try to null organization_id (NOT NULL).
ALTER TABLE timesheet_entries DROP CONSTRAINT IF EXISTS fk_timesheet_task;
ALTER TABLE timesheet_entries
  ADD CONSTRAINT fk_timesheet_task FOREIGN KEY (organization_id, task_id)
  REFERENCES tasks(organization_id, id) ON DELETE SET NULL (task_id);

CREATE INDEX IF NOT EXISTS idx_timesheet_entries_task
  ON timesheet_entries (organization_id, task_id) WHERE task_id IS NOT NULL;

-- ---- 3. a task must belong to the entry's job (from 018) ----------------------------
-- Checked only when task_id / job_id is set or changed, so old rows are untouched.
CREATE OR REPLACE FUNCTION check_timesheet_task_job()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

-- ---- 4. approved time -> task Done; undone approval -> reopened ---------------------
-- An AFTER ROW trigger sees the whole statement's changes, so approving a week's
-- entries in one UPDATE counts all of them, whichever row fires first.
CREATE OR REPLACE FUNCTION complete_task_on_timesheet_approval()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_task tasks%ROWTYPE;
  v_stamp TIMESTAMPTZ := now();
BEGIN
  IF NEW.task_id IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status
     OR NOT (NEW.status = 'approved' OR OLD.status = 'approved') THEN
    RETURN NULL;
  END IF;

  BEGIN
    -- Rules 1, 2 and 4.
    SELECT t.* INTO v_task
      FROM tasks t
      JOIN jobs j ON j.organization_id = t.organization_id AND j.id = t.job_id
     WHERE t.organization_id = NEW.organization_id
       AND t.id = NEW.task_id
       AND t.job_id = NEW.job_id
       AND t.assigned_to = NEW.profile_id
       AND j.status <> 'closed'
     FOR UPDATE OF t;
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    IF NEW.status = 'approved' THEN
      IF v_task.status IN ('todo', 'in_progress')                     -- rule 3
         AND NOT EXISTS (                                             -- rule 5
           SELECT 1 FROM timesheet_entries e
            WHERE e.organization_id = NEW.organization_id
              AND e.task_id = NEW.task_id
              AND e.profile_id = NEW.profile_id
              AND e.status <> 'approved')
         AND (SELECT COALESCE(SUM(e.hours), 0) FROM timesheet_entries e -- rule 6
               WHERE e.organization_id = NEW.organization_id
                 AND e.task_id = NEW.task_id
                 AND e.profile_id = NEW.profile_id
                 AND e.status = 'approved') >= v_task.estimated_hours
      THEN
        UPDATE tasks
           SET status = 'completed', completed_at = v_stamp, auto_completed_at = v_stamp
         WHERE organization_id = v_task.organization_id AND id = v_task.id;
      END IF;
    ELSIF v_task.status = 'completed' AND v_task.completed_at = v_task.auto_completed_at THEN
      UPDATE tasks
         SET status = 'in_progress', completed_at = NULL, auto_completed_at = NULL
       WHERE organization_id = v_task.organization_id AND id = v_task.id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'task % not updated from time entry %: %', NEW.task_id, NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_timesheet_task_approved ON timesheet_entries;
CREATE TRIGGER trg_timesheet_task_approved
  AFTER UPDATE OF status ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION complete_task_on_timesheet_approval();

REVOKE ALL ON FUNCTION check_timesheet_task_job() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION complete_task_on_timesheet_approval() FROM PUBLIC, anon, authenticated;
