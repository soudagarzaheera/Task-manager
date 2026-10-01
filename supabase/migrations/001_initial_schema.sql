-- ==============================================================================
-- FYNALLIANCE ADVISORS / PRACTICE MANAGER — SUPABASE INITIAL DATABASE SCHEMA
-- ==============================================================================

-- Enable pgcrypto for gen_random_uuid() if required
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ==============================================================================
-- 1. HELPER FUNCTIONS & TRIGGERS
-- ==============================================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ==============================================================================
-- 2. MULTI-TENANCY FOUNDATION: ORGANIZATIONS
-- ==============================================================================

CREATE TABLE IF NOT EXISTS organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    code TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_organizations_updated_at
    BEFORE UPDATE ON organizations
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 3. EMPLOYEES & PROFILES (PEOPLE)
-- Note: auth_user_id references auth.users(id) in Supabase.
--       contact_email is for contact/Outlook info, NOT login identifier.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    employee_code TEXT NOT NULL,
    full_name TEXT NOT NULL,
    contact_email TEXT,
    phone TEXT,
    role TEXT NOT NULL CHECK (role IN ('partner', 'manager', 'senior', 'associate', 'article', 'accounts', 'admin')),
    reports_to UUID,
    joining_date DATE NOT NULL DEFAULT CURRENT_DATE,
    exit_date DATE,
    cost_per_hour NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (cost_per_hour >= 0),
    bill_rate_per_hour NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (bill_rate_per_hour >= 0),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_org_employee_code UNIQUE (organization_id, employee_code),
    CONSTRAINT uq_profiles_org_id UNIQUE (organization_id, id),
    CONSTRAINT fk_profiles_reports_to FOREIGN KEY (organization_id, reports_to)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 4. CLIENTS MASTER
-- ==============================================================================

CREATE TABLE IF NOT EXISTS clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    client_code TEXT NOT NULL,
    name TEXT NOT NULL,
    entity_type TEXT NOT NULL DEFAULT 'Private Ltd' CHECK (
        entity_type IN ('Individual','Proprietor','Partnership','LLP','Private Ltd','Public Ltd','Trust','HUF','Society')
    ),
    pan TEXT,
    gstin TEXT,
    email TEXT,
    phone TEXT,
    relationship_partner_id UUID,
    onboarded_date DATE NOT NULL DEFAULT CURRENT_DATE,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_org_client_code UNIQUE (organization_id, client_code),
    CONSTRAINT uq_clients_org_id UNIQUE (organization_id, id),
    CONSTRAINT fk_clients_partner FOREIGN KEY (organization_id, relationship_partner_id)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_clients_updated_at
    BEFORE UPDATE ON clients
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 5. LOCATIONS & GEOFENCES
-- ==============================================================================

CREATE TABLE IF NOT EXISTS locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    client_id UUID, -- NULL indicates firm's own office
    label TEXT NOT NULL,
    latitude NUMERIC(9,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    radius_meters INTEGER NOT NULL DEFAULT 250 CHECK (radius_meters BETWEEN 25 AND 5000),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_locations_org_id UNIQUE (organization_id, id),
    CONSTRAINT fk_locations_client FOREIGN KEY (organization_id, client_id)
        REFERENCES clients(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_locations_updated_at
    BEFORE UPDATE ON locations
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 6. JOBS (JOB CODES & ENGAGEMENTS)
-- Note: fee_amount is confidential financial data; budget_hours is operational.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    client_id UUID, -- Nullable only for internal non-chargeable overhead codes
    job_code TEXT NOT NULL,
    title TEXT NOT NULL,
    service_category TEXT,
    period_fy TEXT,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'under_review', 'closed')),
    budget_hours NUMERIC(8,2) NOT NULL DEFAULT 0.00 CHECK (budget_hours >= 0),
    fee_amount NUMERIC(12,2) CHECK (fee_amount IS NULL OR fee_amount >= 0),
    is_overhead BOOLEAN NOT NULL DEFAULT false,
    internal_due_date DATE,
    statutory_due_date DATE,
    closing_note TEXT,
    closed_at TIMESTAMPTZ,
    opened_by UUID,
    opened_on DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_org_job_code UNIQUE (organization_id, job_code),
    CONSTRAINT uq_jobs_org_id UNIQUE (organization_id, id),
    CONSTRAINT fk_jobs_client FOREIGN KEY (organization_id, client_id)
        REFERENCES clients(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_jobs_opened_by FOREIGN KEY (organization_id, opened_by)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_jobs_updated_at
    BEFORE UPDATE ON jobs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 7. JOB ASSIGNMENTS (JUNCTION: JOBS <-> PROFILES)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS job_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    job_id UUID NOT NULL,
    profile_id UUID NOT NULL,
    role_in_job TEXT,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_job_profile UNIQUE (job_id, profile_id),
    CONSTRAINT fk_job_assignments_job FOREIGN KEY (organization_id, job_id)
        REFERENCES jobs(organization_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_job_assignments_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE CASCADE
);

-- ==============================================================================
-- 8. TASKS
-- ==============================================================================

CREATE TABLE IF NOT EXISTS tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    job_id UUID NOT NULL,
    title TEXT NOT NULL,
    assigned_to UUID,
    status TEXT NOT NULL DEFAULT 'todo' CHECK (
        status IN ('todo', 'in_progress', 'blocked_on_client', 'submitted_for_review', 'changes_requested', 'completed')
    ),
    due_date DATE NOT NULL,
    estimated_hours NUMERIC(6,2) NOT NULL DEFAULT 1.00 CHECK (estimated_hours >= 0),
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_tasks_org_id UNIQUE (organization_id, id),
    CONSTRAINT fk_tasks_job FOREIGN KEY (organization_id, job_id)
        REFERENCES jobs(organization_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_tasks_assigned_to FOREIGN KEY (organization_id, assigned_to)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 9. TIME ENTRIES (TIMESHEET RECORDS)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS timesheet_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    job_id UUID NOT NULL,
    task_id UUID,
    week_start_date DATE NOT NULL, -- Monday date of the week
    entry_date DATE NOT NULL,
    day_index INTEGER NOT NULL CHECK (day_index BETWEEN 0 AND 6), -- 0=Mon .. 5=Sat, 6=Sun
    hours NUMERIC(5,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
    narration TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending', 'approved', 'queried')),
    query_reason TEXT DEFAULT '',
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_timesheet_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_timesheet_job FOREIGN KEY (organization_id, job_id)
        REFERENCES jobs(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_timesheet_task FOREIGN KEY (organization_id, task_id)
        REFERENCES tasks(organization_id, id) ON DELETE SET NULL,
    CONSTRAINT fk_timesheet_approver FOREIGN KEY (organization_id, approved_by)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_timesheet_entries_updated_at
    BEFORE UPDATE ON timesheet_entries
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 10. NIL TIMESHEETS (WHOLE-WEEK OFF RECORDS)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS nil_timesheets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    week_start_date DATE NOT NULL,
    filed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_profile_nil_week UNIQUE (profile_id, week_start_date),
    CONSTRAINT fk_nil_timesheet_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE RESTRICT
);

-- ==============================================================================
-- 11. ATTENDANCE PUNCHES & GEOLOCATION LOGS
-- Note: Raw punch log preserved for complete historical audit.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS attendance_punches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    punch_type TEXT NOT NULL CHECK (punch_type IN ('in', 'out')),
    punch_timestamp TIMESTAMPTZ NOT NULL DEFAULT now(),
    punch_date DATE NOT NULL DEFAULT CURRENT_DATE,
    location_id UUID,
    place_label TEXT NOT NULL,
    latitude NUMERIC(9,6),
    longitude NUMERIC(9,6),
    distance_meters NUMERIC(10,2),
    is_within_geofence BOOLEAN NOT NULL DEFAULT false,
    needs_review BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_punches_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_punches_location FOREIGN KEY (organization_id, location_id)
        REFERENCES locations(organization_id, id) ON DELETE SET NULL
);

-- ==============================================================================
-- 12. BUDGET REQUESTS
-- ==============================================================================

CREATE TABLE IF NOT EXISTS budget_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    job_id UUID NOT NULL,
    from_hours NUMERIC(8,2) NOT NULL CHECK (from_hours >= 0),
    to_hours NUMERIC(8,2) NOT NULL CHECK (to_hours > from_hours),
    requested_by UUID NOT NULL,
    requested_date DATE NOT NULL DEFAULT CURRENT_DATE,
    reason TEXT NOT NULL CHECK (length(trim(reason)) >= 10),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    decided_by UUID,
    decided_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_budget_requests_job FOREIGN KEY (organization_id, job_id)
        REFERENCES jobs(organization_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_budget_requests_requester FOREIGN KEY (organization_id, requested_by)
        REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_budget_requests_decider FOREIGN KEY (organization_id, decided_by)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_budget_requests_updated_at
    BEFORE UPDATE ON budget_requests
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 13. EXPENSE CLAIMS & EXPENSE CLAIM LINES
-- ==============================================================================

CREATE TABLE IF NOT EXISTS expense_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    claim_month TEXT NOT NULL CHECK (claim_month ~ '^\d{4}-\d{2}$'), -- Format: YYYY-MM
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'paid')),
    submitted_at TIMESTAMPTZ,
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    paid_by UUID,
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_profile_month_claim UNIQUE (profile_id, claim_month),
    CONSTRAINT uq_expense_claims_org_id UNIQUE (organization_id, id),
    CONSTRAINT fk_claims_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_claims_approver FOREIGN KEY (organization_id, approved_by)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL,
    CONSTRAINT fk_claims_payer FOREIGN KEY (organization_id, paid_by)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_expense_claims_updated_at
    BEFORE UPDATE ON expense_claims
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS expense_claim_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
    job_id UUID NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
    expense_date DATE NOT NULL,
    category TEXT NOT NULL CHECK (
        category IN ('conveyance', 'travel', 'lodging', 'meals', 'printing', 'courier', 'govt_fee', 'other')
    ),
    description TEXT NOT NULL,
    amount NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    is_recoverable_from_client BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_expense_claim_lines_updated_at
    BEFORE UPDATE ON expense_claim_lines
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 14. LEAVES & HOLIDAYS
-- ==============================================================================

CREATE TABLE IF NOT EXISTS leaves (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    leave_date DATE NOT NULL,
    duration_part TEXT NOT NULL DEFAULT 'full' CHECK (duration_part IN ('full', 'half')),
    leave_type TEXT NOT NULL DEFAULT 'CL' CHECK (leave_type IN ('CL', 'EL', 'SL', 'ML', 'PL', 'LWP')),
    status TEXT NOT NULL DEFAULT 'approved' CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
    reason TEXT,
    approved_by UUID,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_profile_leave_date UNIQUE (profile_id, leave_date),
    CONSTRAINT fk_leaves_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_leaves_approver FOREIGN KEY (organization_id, approved_by)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_leaves_updated_at
    BEFORE UPDATE ON leaves
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS holidays (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    holiday_date DATE NOT NULL,
    name TEXT NOT NULL,
    is_mandatory BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_org_holiday_date UNIQUE (organization_id, holiday_date)
);

-- ==============================================================================
-- 15. STATUTORY COMPLIANCES (CALENDAR)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS statutory_compliances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    compliance_code TEXT NOT NULL,
    title TEXT NOT NULL,
    client_id UUID NOT NULL,
    statutory_due_date DATE NOT NULL,
    period TEXT,
    is_job_raised BOOLEAN NOT NULL DEFAULT false,
    job_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_compliances_client FOREIGN KEY (organization_id, client_id)
        REFERENCES clients(organization_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_compliances_job FOREIGN KEY (organization_id, job_id)
        REFERENCES jobs(organization_id, id) ON DELETE SET NULL
);

CREATE TRIGGER trg_statutory_compliances_updated_at
    BEFORE UPDATE ON statutory_compliances
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ==============================================================================
-- 16. REVIEW NOTES (FEEDBACK DRAWER)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS review_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL,
    screen_view TEXT NOT NULL,
    note_text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_review_notes_profile FOREIGN KEY (organization_id, profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE CASCADE
);

-- ==============================================================================
-- 17. AUDIT LOGS (IMMUTABLE AUDIT TRAIL)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    actor_profile_id UUID,
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    old_values JSONB,
    new_values JSONB,
    ip_address TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_audit_logs_actor FOREIGN KEY (organization_id, actor_profile_id)
        REFERENCES profiles(organization_id, id) ON DELETE SET NULL
);

-- ==============================================================================
-- 18. PERFORMANCE INDEXES
-- ==============================================================================

-- Profiles
CREATE INDEX IF NOT EXISTS idx_profiles_org_id ON profiles(organization_id);
CREATE INDEX IF NOT EXISTS idx_profiles_role ON profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_reports_to ON profiles(reports_to);
CREATE INDEX IF NOT EXISTS idx_profiles_is_active ON profiles(is_active);

-- Clients
CREATE INDEX IF NOT EXISTS idx_clients_org_id ON clients(organization_id);
CREATE INDEX IF NOT EXISTS idx_clients_partner ON clients(relationship_partner_id);
CREATE INDEX IF NOT EXISTS idx_clients_is_active ON clients(is_active);

-- Locations
CREATE INDEX IF NOT EXISTS idx_locations_org_id ON locations(organization_id);
CREATE INDEX IF NOT EXISTS idx_locations_client ON locations(client_id);
CREATE INDEX IF NOT EXISTS idx_locations_active ON locations(is_active);

-- Jobs
CREATE INDEX IF NOT EXISTS idx_jobs_org_id ON jobs(organization_id);
CREATE INDEX IF NOT EXISTS idx_jobs_client_id ON jobs(client_id);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_internal_due ON jobs(internal_due_date);

-- Tasks
CREATE INDEX IF NOT EXISTS idx_tasks_org_id ON tasks(organization_id);
CREATE INDEX IF NOT EXISTS idx_tasks_job_id ON tasks(job_id);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON tasks(assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON tasks(due_date);

-- Time Entries
CREATE INDEX IF NOT EXISTS idx_time_entries_org_id ON timesheet_entries(organization_id);
CREATE INDEX IF NOT EXISTS idx_time_entries_profile_id ON timesheet_entries(profile_id);
CREATE INDEX IF NOT EXISTS idx_time_entries_job_id ON timesheet_entries(job_id);
CREATE INDEX IF NOT EXISTS idx_time_entries_week ON timesheet_entries(week_start_date);
CREATE INDEX IF NOT EXISTS idx_time_entries_date ON timesheet_entries(entry_date);
CREATE INDEX IF NOT EXISTS idx_time_entries_status ON timesheet_entries(status);

-- Attendance
CREATE INDEX IF NOT EXISTS idx_attendance_org_id ON attendance_punches(organization_id);
CREATE INDEX IF NOT EXISTS idx_attendance_profile_id ON attendance_punches(profile_id);
CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance_punches(punch_date);
CREATE INDEX IF NOT EXISTS idx_attendance_timestamp ON attendance_punches(punch_timestamp);

-- Budget Requests
CREATE INDEX IF NOT EXISTS idx_budget_requests_org_id ON budget_requests(organization_id);
CREATE INDEX IF NOT EXISTS idx_budget_requests_job ON budget_requests(job_id);
CREATE INDEX IF NOT EXISTS idx_budget_requests_status ON budget_requests(status);

-- Claims
CREATE INDEX IF NOT EXISTS idx_claims_org_id ON expense_claims(organization_id);
CREATE INDEX IF NOT EXISTS idx_claims_profile_month ON expense_claims(profile_id, claim_month);
CREATE INDEX IF NOT EXISTS idx_claims_status ON expense_claims(status);
CREATE INDEX IF NOT EXISTS idx_claim_lines_claim ON expense_claim_lines(claim_id);
CREATE INDEX IF NOT EXISTS idx_claim_lines_job ON expense_claim_lines(job_id);

-- Leaves & Holidays
CREATE INDEX IF NOT EXISTS idx_leaves_profile_date ON leaves(profile_id, leave_date);
CREATE INDEX IF NOT EXISTS idx_holidays_date ON holidays(organization_id, holiday_date);

-- Compliances
CREATE INDEX IF NOT EXISTS idx_compliances_client ON statutory_compliances(client_id);
CREATE INDEX IF NOT EXISTS idx_compliances_due ON statutory_compliances(statutory_due_date);

-- Audit Logs
CREATE INDEX IF NOT EXISTS idx_audit_org_id ON audit_logs(organization_id);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs(created_at);

-- ==============================================================================
-- 19. ROW-LEVEL SECURITY (RLS) ACTIVATION
-- Note: Foundational RLS is enabled on all tables. Specific fine-grained policies
--       will be applied in the authentication and authorization phase.
-- ==============================================================================

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE job_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE timesheet_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE nil_timesheets ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_punches ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_claim_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE leaves ENABLE ROW LEVEL SECURITY;
ALTER TABLE holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE statutory_compliances ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
