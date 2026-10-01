CREATE OR REPLACE FUNCTION partner_task_assignments()
RETURNS TABLE (task_id UUID, partner_id UUID)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT t.id, p.id
  FROM tasks t
  JOIN profiles p
    ON p.id = t.assigned_by
   AND p.organization_id = t.organization_id
   AND p.role = 'partner'
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
   AND p.role = 'partner'
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
   AND p.role = 'partner'
  WHERE t.organization_id = auth_org_id();
$$;

REVOKE ALL ON FUNCTION partner_task_assignments() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION partner_task_assignments() TO authenticated;
