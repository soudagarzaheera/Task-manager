-- ==============================================================================
-- 008: ADD COMPANY AND MONTHLY CTC TO PROFILES
-- ==============================================================================

ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS company TEXT DEFAULT 'Fyn',
ADD COLUMN IF NOT EXISTS monthly_ctc NUMERIC(12,2) DEFAULT 0.00;

COMMENT ON COLUMN profiles.company IS 'Short company code (e.g. Fyn, MRCO)';
COMMENT ON COLUMN profiles.monthly_ctc IS 'Monthly Cost-to-Company (CTC) amount';

-- ==============================================================================
-- 009: TASK RESPONSIBILITY HISTORY AND RECURRING MONTHLY COSTS
-- ==============================================================================

ALTER TABLE tasks
ADD COLUMN IF NOT EXISTS assigned_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS monthly_cost NUMERIC(12,2) DEFAULT 0.00,
ADD COLUMN IF NOT EXISTS cost_history JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS responsibility_history JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN tasks.assigned_by IS 'Profile ID of user who assigned the task';
COMMENT ON COLUMN tasks.monthly_cost IS 'Current recurring monthly cost';
COMMENT ON COLUMN tasks.cost_history IS 'Historical monthly cost schedule [{effectiveMonth, monthlyCost, updatedBy, updatedAt}]';
COMMENT ON COLUMN tasks.responsibility_history IS 'Task assignment history [{assignedTo, assignedBy, fromDate, toDate, createdAt}]';
