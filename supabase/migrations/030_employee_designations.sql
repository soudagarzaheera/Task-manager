-- ==============================================================================
-- 030: EMPLOYEE DESIGNATIONS + JOB CODE / TASK ASSIGNMENT ACCESS
-- ==============================================================================
-- profiles.role IS the employee's designation — no separate role system. The
-- designation list becomes (lowest to highest):
--
--   trainee 10 · associate 20 · senior_associate 30 · senior_executive 50 ·
--   assistant_manager 60 · manager 70 · partner 90
--
-- 'accounts' (40) and 'admin' stay valid as legacy values so nothing that
-- still carries them breaks, but the app no longer offers them.
--
-- 1. Existing employees keep their access:
--      senior  -> assistant_manager  (seniors could raise job codes; AM keeps that)
--      article -> trainee            (same rank, 10)
--    partner / manager / associate are unchanged.
-- 2. auth_rank() / profile_rank() learn the new designations. They mirror the
--    RANK map in index.html — keep both in sync. Every existing threshold
--    (>= 50 / >= 70 / >= 90) keeps the same meaning: a former senior is now
--    60, still >= 50 and still < 70.
-- 3. Creating a job code requires rank >= 60 (Assistant Manager and above):
--    jobs_insert gains auth_rank() >= 60. Editing a job is unchanged.
-- 4. Assigning work requires rank >= 60: trigger trg_tasks_assignment_rank
--    blocks, for a signed-in user below Assistant Manager, inserting a task,
--    deleting one, or changing its assignee / assigner / job. Status and
--    other fields stay editable under the existing tasks_access policy.
--    Service-role calls (auth.uid() IS NULL) are not affected.
-- 5. partner_task_assignments() (Work screen "Assigned by" filter) now also
--    counts tasks assigned by a manager or assistant manager, since they can
--    assign work too. Same signature and columns.
--
-- Safe to re-run.
-- ==============================================================================

-- ---- 1. designation values -------------------------------------------------
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;

UPDATE profiles SET role = 'assistant_manager' WHERE role = 'senior';
UPDATE profiles SET role = 'trainee'           WHERE role = 'article';

ALTER TABLE profiles ADD CONSTRAINT profiles_role_check CHECK (role IN (
  'trainee', 'associate', 'senior_associate', 'senior_executive',
  'assistant_manager', 'manager', 'partner',
  'accounts', 'admin'   -- legacy, no longer assignable from the app
));

-- ---- 2. rank helpers ---------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_rank()
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE (SELECT role FROM profiles WHERE auth_user_id = auth.uid() AND is_active LIMIT 1)
    WHEN 'partner' THEN 90 WHEN 'manager' THEN 70 WHEN 'assistant_manager' THEN 60
    WHEN 'senior_executive' THEN 50 WHEN 'accounts' THEN 40 WHEN 'senior_associate' THEN 30
    WHEN 'associate' THEN 20 WHEN 'trainee' THEN 10
    ELSE 0 END;
$$;

CREATE OR REPLACE FUNCTION profile_rank(pid UUID)
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE (SELECT role FROM profiles WHERE id = pid)
    WHEN 'partner' THEN 90 WHEN 'manager' THEN 70 WHEN 'assistant_manager' THEN 60
    WHEN 'senior_executive' THEN 50 WHEN 'accounts' THEN 40 WHEN 'senior_associate' THEN 30
    WHEN 'associate' THEN 20 WHEN 'trainee' THEN 10
    ELSE 0 END;
$$;

-- ---- 3. job code creation: Assistant Manager and above -----------------------
DROP POLICY IF EXISTS jobs_insert ON jobs;
CREATE POLICY jobs_insert ON jobs FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_company_ok(company_id) AND auth_rank() >= 60);

-- ---- 4. task assignment: Assistant Manager and above -------------------------
CREATE OR REPLACE FUNCTION enforce_task_assignment_rank()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR auth_rank() >= 60 THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.assigned_to IS NOT DISTINCT FROM OLD.assigned_to
     AND NEW.assigned_by IS NOT DISTINCT FROM OLD.assigned_by
     AND NEW.job_id      IS NOT DISTINCT FROM OLD.job_id THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Only Assistant Managers, Managers and Partners can assign work under a job code.'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS trg_tasks_assignment_rank ON tasks;
CREATE TRIGGER trg_tasks_assignment_rank
  BEFORE INSERT OR UPDATE OR DELETE ON tasks
  FOR EACH ROW EXECUTE FUNCTION enforce_task_assignment_rank();

-- ---- 5. "Assigned by" filter covers every designation that can assign --------
CREATE OR REPLACE FUNCTION partner_task_assignments()
RETURNS TABLE(task_id uuid, partner_id uuid)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT t.id, p.id
  FROM tasks t
  JOIN profiles p
    ON p.id = t.assigned_by
   AND p.organization_id = t.organization_id
   AND p.role IN ('partner', 'manager', 'assistant_manager')
  WHERE t.organization_id = auth_org_id()

  UNION

  SELECT t.id, p.id
  FROM tasks t
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(t.responsibility_history) = 'array' THEN t.responsibility_history
      ELSE '[]'::jsonb
    END
  ) AS history(entry)
  JOIN profiles p
    ON p.id::text = history.entry->>'assignedBy'
   AND p.organization_id = t.organization_id
   AND p.role IN ('partner', 'manager', 'assistant_manager')
  WHERE t.organization_id = auth_org_id()

  UNION

  SELECT t.id, p.id
  FROM tasks t
  JOIN jobs j
    ON j.id = t.job_id
   AND j.organization_id = t.organization_id
  JOIN profiles p
    ON p.id = j.opened_by
   AND p.organization_id = t.organization_id
   AND p.role IN ('partner', 'manager', 'assistant_manager')
  WHERE t.organization_id = auth_org_id();
$$;
