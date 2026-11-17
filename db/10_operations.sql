-- =============================================================================
-- CFMS / NVS  -  10  Operations: expenses, petty cash, vendors, payroll,
--                   assistance and grants, marriage halls, assets,
--                   contributions and donations (Sections 13-20)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- =============================================================================

-- ===== Vendors and bills (Section 16.2) =====================================
CREATE TABLE IF NOT EXISTS ops.vendor (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    vendor_code     text NOT NULL,
    name            text NOT NULL,
    category        text,
    contact_person  text,
    mobile          text,
    email           text,
    address         text,
    registration_no text,
    pan             text,
    gstin           text,
    status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    is_deleted      boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, vendor_code)
);

-- ===== Daily expenses (Section 16) ==========================================
CREATE TABLE IF NOT EXISTS ops.expense_category (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code              text NOT NULL,
    name              text NOT NULL,
    account_id        uuid NOT NULL,
    approver_role_id  uuid,
    status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    sort_order        integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, approver_role_id) REFERENCES iam.role (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.vendor_bill (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    vendor_id        uuid NOT NULL,
    bill_no          text NOT NULL,
    bill_date        date NOT NULL,
    received_on      date NOT NULL DEFAULT app.working_date(),
    description      text,
    expense_category_id uuid,
    asset_purchase_request_id uuid,               -- FK added below
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    paid_amount      numeric(18,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
    status           text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','APPROVED','PARTLY_PAID','PAID','CANCELLED')),
    document_id      uuid,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, vendor_id, bill_no),
    FOREIGN KEY (tenant_id, vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, expense_category_id) REFERENCES ops.expense_category (tenant_id, id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    CHECK (paid_amount <= amount)
);

CREATE TABLE IF NOT EXISTS ops.vendor_payment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    vendor_id        uuid NOT NULL,
    vendor_bill_id   uuid,                         -- null = advance to vendor
    is_advance       boolean NOT NULL DEFAULT false,
    value_date       date NOT NULL DEFAULT app.working_date(),
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    payment_voucher_id uuid,
    status           text NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','REVERSED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_bill_id) REFERENCES ops.vendor_bill (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    CHECK (is_advance OR vendor_bill_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS ops.vendor_advance_adjustment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    vendor_payment_id uuid NOT NULL,               -- the advance
    vendor_bill_id    uuid NOT NULL,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    adjusted_on       date NOT NULL DEFAULT app.working_date(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_payment_id) REFERENCES ops.vendor_payment (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_bill_id) REFERENCES ops.vendor_bill (tenant_id, id)
);

-- ===== Employees and payroll (Section 17) ===================================
CREATE TABLE IF NOT EXISTS ops.employee (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    employee_code    text NOT NULL,
    full_name        text NOT NULL,
    joining_date     date NOT NULL,
    designation      text,
    department       text,
    employment_status text NOT NULL DEFAULT 'ACTIVE' CHECK (employment_status IN ('ACTIVE','ON_LEAVE','RESIGNED','TERMINATED','RETIRED')),
    exit_date        date,
    mobile           text,
    email            text,
    pan              text,
    address          text,
    user_id          uuid,                          -- linked login user (optional)
    is_deleted       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, employee_code),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id)
);

DO $$ BEGIN
    PERFORM app.add_constraint_if_missing('iam.app_user', 'app_user_employee_fk',
        'FOREIGN KEY (tenant_id, employee_id) REFERENCES ops.employee (tenant_id, id)');
END $$;

CREATE TABLE IF NOT EXISTS ops.salary_component (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code             text NOT NULL,
    name             text NOT NULL,
    component_type   text NOT NULL CHECK (component_type IN ('EARNING','DEDUCTION')),
    calc_type        text NOT NULL DEFAULT 'FIXED' CHECK (calc_type IN ('FIXED','PERCENT_OF_BASIC','VARIABLE')),
    account_id       uuid,
    is_statutory     boolean NOT NULL DEFAULT false,
    feature_code     text REFERENCES platform.compliance_feature (feature_code),
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    sort_order       integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.employee_salary_structure (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    employee_id         uuid NOT NULL,
    salary_component_id uuid NOT NULL,
    amount              numeric(18,2),
    percent             numeric(7,4),
    effective_from      date NOT NULL,
    effective_to        date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, employee_id, salary_component_id, effective_from),
    FOREIGN KEY (tenant_id, employee_id) REFERENCES ops.employee (tenant_id, id),
    FOREIGN KEY (tenant_id, salary_component_id) REFERENCES ops.salary_component (tenant_id, id),
    CHECK (amount IS NOT NULL OR percent IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS ops.salary_advance (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    employee_id      uuid NOT NULL,
    advance_no       text NOT NULL,
    issued_on        date NOT NULL DEFAULT app.working_date(),
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    recovery_per_month numeric(18,2),
    recovered_amount numeric(18,2) NOT NULL DEFAULT 0,
    status           text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','ISSUED','RECOVERED','CANCELLED')),
    payment_voucher_id uuid,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, advance_no),
    FOREIGN KEY (tenant_id, employee_id) REFERENCES ops.employee (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.payroll_run (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    run_no           text NOT NULL,
    period_month     date NOT NULL CHECK (extract(day FROM period_month) = 1),
    status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PREPARED','VERIFIED','APPROVED','PAID','CANCELLED')),
    total_gross      numeric(18,2) NOT NULL DEFAULT 0,
    total_deductions numeric(18,2) NOT NULL DEFAULT 0,
    total_net        numeric(18,2) NOT NULL DEFAULT 0,
    prepared_by      uuid,                          -- ACC
    prepared_at      timestamptz,
    verified_by      uuid,                          -- MGR
    verified_at      timestamptz,
    approved_by      uuid,                          -- LDR
    approved_at      timestamptz,
    workflow_instance_id uuid,
    workflow_version_id  uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, run_no),
    FOREIGN KEY (tenant_id, prepared_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, verified_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CONSTRAINT payroll_preparer_not_approver CHECK (approved_by IS NULL OR approved_by <> prepared_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS payroll_run_month_uq ON ops.payroll_run (tenant_id, period_month) WHERE status <> 'CANCELLED';

CREATE TABLE IF NOT EXISTS ops.payslip (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    payroll_run_id   uuid NOT NULL,
    employee_id      uuid NOT NULL,
    lop_days         numeric(5,2) NOT NULL DEFAULT 0,
    lop_source_note  text,
    gross_amount     numeric(18,2) NOT NULL DEFAULT 0,
    deduction_amount numeric(18,2) NOT NULL DEFAULT 0,
    net_amount       numeric(18,2) NOT NULL DEFAULT 0,
    rounded_net      numeric(18,2) NOT NULL DEFAULT 0,
    rounding_diff    numeric(18,2) GENERATED ALWAYS AS (rounded_net - net_amount) STORED,
    status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','FINAL','PAID','CANCELLED')),
    payment_voucher_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, payroll_run_id, employee_id),
    FOREIGN KEY (tenant_id, payroll_run_id) REFERENCES ops.payroll_run (tenant_id, id),
    FOREIGN KEY (tenant_id, employee_id) REFERENCES ops.employee (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.payslip_line (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    payslip_id          uuid NOT NULL,
    salary_component_id uuid,
    salary_advance_id   uuid,
    loan_id             uuid,                       -- authorised loan deduction
    description         text NOT NULL,
    line_type           text NOT NULL CHECK (line_type IN ('EARNING','DEDUCTION')),
    amount              numeric(18,2) NOT NULL CHECK (amount >= 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, payslip_id) REFERENCES ops.payslip (tenant_id, id),
    FOREIGN KEY (tenant_id, salary_component_id) REFERENCES ops.salary_component (tenant_id, id),
    FOREIGN KEY (tenant_id, salary_advance_id) REFERENCES ops.salary_advance (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id)
);

-- ===== Petty cash / imprest (Section 16.1) ==================================
CREATE TABLE IF NOT EXISTS ops.petty_cash_advance (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    advance_no       text NOT NULL,
    holder_user_id   uuid NOT NULL,
    employee_id      uuid,
    limit_amount     numeric(18,2) NOT NULL CHECK (limit_amount > 0),
    issued_amount    numeric(18,2) NOT NULL DEFAULT 0,
    settled_amount   numeric(18,2) NOT NULL DEFAULT 0,
    returned_amount  numeric(18,2) NOT NULL DEFAULT 0,
    balance          numeric(18,2) GENERATED ALWAYS AS (issued_amount - settled_amount - returned_amount) STORED,
    issued_on        date,
    status           text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','ISSUED','SETTLED','CLOSED','CANCELLED')),
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, advance_no),
    FOREIGN KEY (tenant_id, holder_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, employee_id) REFERENCES ops.employee (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    CHECK (issued_amount <= limit_amount)
);

CREATE TABLE IF NOT EXISTS ops.expense (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    expense_no       text NOT NULL,
    value_date       date NOT NULL DEFAULT app.working_date(),
    expense_category_id uuid NOT NULL,
    description      text NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    payment_mode     text NOT NULL DEFAULT 'CASH' REFERENCES platform.payment_mode (mode_code),
    fund_id          uuid,
    vendor_id        uuid,
    vendor_bill_id   uuid,
    petty_cash_advance_id uuid,                    -- paid from imprest
    bill_document_id uuid,
    submitted_by     uuid NOT NULL DEFAULT app.user_id(),
    status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','SUBMITTED','RETURNED','APPROVED','REJECTED','PAID','CANCELLED')),
    payment_voucher_id uuid,
    approval_request_id uuid,
    workflow_instance_id uuid,
    workflow_version_id  uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, expense_no),
    FOREIGN KEY (tenant_id, expense_category_id) REFERENCES ops.expense_category (tenant_id, id),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_bill_id) REFERENCES ops.vendor_bill (tenant_id, id),
    FOREIGN KEY (tenant_id, petty_cash_advance_id) REFERENCES ops.petty_cash_advance (tenant_id, id),
    FOREIGN KEY (tenant_id, bill_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, submitted_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.petty_cash_movement (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    petty_cash_advance_id uuid NOT NULL,
    movement_type    text NOT NULL CHECK (movement_type IN ('ISSUE','TOP_UP','EXPENSE','RETURN')),
    value_date       date NOT NULL DEFAULT app.working_date(),
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    expense_id       uuid,
    payment_voucher_id uuid,
    cash_receipt_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, petty_cash_advance_id) REFERENCES ops.petty_cash_advance (tenant_id, id),
    FOREIGN KEY (tenant_id, expense_id) REFERENCES ops.expense (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id)
);

-- ===== Assistance: education, cremation, other; birthday grants (13-15) =======
CREATE TABLE IF NOT EXISTS ops.assistance_scheme (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code             text NOT NULL,
    name             text NOT NULL,
    assistance_type  text NOT NULL CHECK (assistance_type IN ('EDUCATION','CREMATION','BIRTHDAY_GRANT','OTHER')),
    module_code      text NOT NULL REFERENCES platform.module (module_code),
    default_amount   numeric(18,2) CHECK (default_amount >= 0),
    is_repayable     boolean NOT NULL DEFAULT false,      -- policy to confirm for education
    fund_id          uuid,
    account_id       uuid,
    rule_set_id      uuid,                                -- eligibility / limits
    required_documents jsonb NOT NULL DEFAULT '[]'::jsonb,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_id) REFERENCES cfg.rule_set (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.assistance_cycle (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    assistance_scheme_id uuid NOT NULL,
    cycle_name       text NOT NULL,                       -- e.g. 2027
    opens_on         date NOT NULL,
    closes_on        date NOT NULL,
    amount_per_beneficiary numeric(18,2) NOT NULL CHECK (amount_per_beneficiary >= 0),
    cycle_limit      numeric(18,2),
    over_limit_rule  text NOT NULL DEFAULT 'ASK_MANAGER' CHECK (over_limit_rule IN ('REDUCE_EQUALLY','FIRST_COME','ASK_MANAGER')),
    max_per_family   integer,
    allow_consecutive_years boolean NOT NULL DEFAULT true,
    status           text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','OPEN','CLOSED','PAID_OUT','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, assistance_scheme_id, cycle_name),
    FOREIGN KEY (tenant_id, assistance_scheme_id) REFERENCES ops.assistance_scheme (tenant_id, id),
    CHECK (closes_on >= opens_on)
);

CREATE TABLE IF NOT EXISTS ops.assistance_application (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    application_no   text NOT NULL,
    assistance_scheme_id uuid NOT NULL,
    assistance_cycle_id  uuid,
    member_id        uuid NOT NULL,
    family_member_id uuid,                                -- the student, where applicable
    beneficiary_name text NOT NULL,
    beneficiary_relation text,
    death_record_id  uuid,                                -- cremation assistance
    institution      text,
    course           text,
    academic_year    text,
    application_date date NOT NULL DEFAULT app.working_date(),
    amount_requested numeric(18,2),
    amount_approved  numeric(18,2),
    status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','SUBMITTED','VERIFIED','RETURNED','APPROVED',
                                                                     'REJECTED','PAID','CANCELLED','WITHDRAWN')),
    rejection_reason text,
    paid_to          text,                                -- member / parent / institution
    payment_voucher_id uuid,
    approval_request_id uuid,
    workflow_instance_id uuid,
    workflow_version_id  uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, application_no),
    FOREIGN KEY (tenant_id, assistance_scheme_id) REFERENCES ops.assistance_scheme (tenant_id, id),
    FOREIGN KEY (tenant_id, assistance_cycle_id) REFERENCES ops.assistance_cycle (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, family_member_id) REFERENCES mbr.member_family (tenant_id, id),
    FOREIGN KEY (tenant_id, death_record_id) REFERENCES mbr.death_record (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS ops.birthday_grant_leader (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id          uuid,                                -- leadership user (may be record-only)
    full_name        text NOT NULL,
    birth_date       date NOT NULL,
    grant_amount     numeric(18,2) NOT NULL CHECK (grant_amount > 0),
    beneficiary_name text,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.birthday_grant (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    birthday_grant_leader_id uuid NOT NULL,
    grant_year       integer NOT NULL,
    scheduled_date   date NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    beneficiary_name text,
    status           text NOT NULL DEFAULT 'SCHEDULED' CHECK (status IN ('SCHEDULED','APPROVED','PAID','CANCELLED')),
    beneficiary_user_id uuid,                             -- leader cannot approve own grant
    payment_voucher_id uuid,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, birthday_grant_leader_id, grant_year),
    FOREIGN KEY (tenant_id, birthday_grant_leader_id) REFERENCES ops.birthday_grant_leader (tenant_id, id),
    FOREIGN KEY (tenant_id, beneficiary_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

-- ===== Marriage halls (Section 18) ==========================================
CREATE TABLE IF NOT EXISTS ops.hall (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code             text NOT NULL,
    name             text NOT NULL,
    capacity         integer CHECK (capacity > 0),
    facilities       jsonb NOT NULL DEFAULT '[]'::jsonb,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','UNDER_MAINTENANCE','INACTIVE')),
    income_account_id uuid,
    sort_order       integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, income_account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.hall_rate (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    hall_id          uuid NOT NULL,
    customer_category text NOT NULL CHECK (customer_category IN ('MEMBER','NON_MEMBER')),
    day_type         text NOT NULL CHECK (day_type IN ('WEEKDAY','WEEKEND','PUBLIC_HOLIDAY','HALF_DAY','ADDITIONAL_DAY')),
    amount           numeric(18,2) NOT NULL CHECK (amount >= 0),
    effective_from   date NOT NULL DEFAULT current_date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, hall_id, customer_category, day_type, effective_from),
    FOREIGN KEY (tenant_id, hall_id) REFERENCES ops.hall (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.hall_charge_type (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code             text NOT NULL,
    name             text NOT NULL,                 -- Security deposit, Cleaning, Electricity, Decoration, Extra hours
    default_amount   numeric(18,2),
    is_security_deposit boolean NOT NULL DEFAULT false,
    account_id       uuid,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.hall_customer (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    full_name        text NOT NULL,
    mobile           text NOT NULL,
    address          text,
    id_type          text,
    id_number_masked text,
    id_number_enc    text,
    is_deleted       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS hall_customer_mobile_uq ON ops.hall_customer (tenant_id, mobile) WHERE NOT is_deleted;

CREATE TABLE IF NOT EXISTS ops.hall_booking (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    booking_no       text NOT NULL,
    branch_id        uuid,
    customer_type    text NOT NULL CHECK (customer_type IN ('MEMBER','NON_MEMBER')),
    member_id        uuid,
    hall_customer_id uuid,
    rate_category    text NOT NULL CHECK (rate_category IN ('MEMBER','NON_MEMBER')),
    family_event_declared boolean NOT NULL DEFAULT false,
    event_type       text,
    event_description text,
    status           text NOT NULL DEFAULT 'ENQUIRY' CHECK (status IN ('ENQUIRY','TENTATIVE','CONFIRMED','RESCHEDULED',
                                                                      'CANCELLED','COMPLETED','SETTLED')),
    tentative_expires_at timestamptz,
    confirmed_at     timestamptz,
    price_locked     boolean NOT NULL DEFAULT false,
    rent_amount      numeric(18,2) NOT NULL DEFAULT 0,
    deposit_amount   numeric(18,2) NOT NULL DEFAULT 0,
    charges_amount   numeric(18,2) NOT NULL DEFAULT 0,
    total_amount     numeric(18,2) GENERATED ALWAYS AS (rent_amount + deposit_amount + charges_amount) STORED,
    rescheduled_from_id uuid,
    cancel_reason    text,
    refund_decision  text,
    workflow_instance_id uuid,
    workflow_version_id  uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, booking_no),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, hall_customer_id) REFERENCES ops.hall_customer (tenant_id, id),
    FOREIGN KEY (tenant_id, rescheduled_from_id) REFERENCES ops.hall_booking (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK ((customer_type = 'MEMBER' AND member_id IS NOT NULL) OR (customer_type = 'NON_MEMBER' AND hall_customer_id IS NOT NULL)),
    CHECK (status <> 'CONFIRMED' OR price_locked)
);

-- One confirmed / tentative booking per hall per calendar day (Section 18.4).
CREATE TABLE IF NOT EXISTS ops.hall_booking_day (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    hall_booking_id  uuid NOT NULL,
    hall_id          uuid NOT NULL,
    booking_date     date NOT NULL,
    day_type         text NOT NULL CHECK (day_type IN ('WEEKDAY','WEEKEND','PUBLIC_HOLIDAY','HALF_DAY','ADDITIONAL_DAY')),
    rate_amount      numeric(18,2) NOT NULL DEFAULT 0,
    blocks_calendar  boolean NOT NULL DEFAULT false,      -- true while booking is TENTATIVE or CONFIRMED
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, hall_booking_id, hall_id, booking_date),
    FOREIGN KEY (tenant_id, hall_booking_id) REFERENCES ops.hall_booking (tenant_id, id),
    FOREIGN KEY (tenant_id, hall_id) REFERENCES ops.hall (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS hall_booking_day_block_uq
    ON ops.hall_booking_day (tenant_id, hall_id, booking_date) WHERE blocks_calendar;

CREATE OR REPLACE FUNCTION ops.trg_hall_booking_calendar()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_TABLE_NAME = 'hall_booking' THEN
        UPDATE ops.hall_booking_day
           SET blocks_calendar = (NEW.status IN ('TENTATIVE','CONFIRMED'))
         WHERE tenant_id = NEW.tenant_id AND hall_booking_id = NEW.id
           AND blocks_calendar IS DISTINCT FROM (NEW.status IN ('TENTATIVE','CONFIRMED'));
        RETURN NULL;
    END IF;
    -- hall_booking_day insert / update
    SELECT b.status IN ('TENTATIVE','CONFIRMED') INTO NEW.blocks_calendar
      FROM ops.hall_booking b WHERE b.tenant_id = NEW.tenant_id AND b.id = NEW.hall_booking_id;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS hall_booking_calendar ON ops.hall_booking;
CREATE TRIGGER hall_booking_calendar AFTER INSERT OR UPDATE OF status ON ops.hall_booking
    FOR EACH ROW EXECUTE FUNCTION ops.trg_hall_booking_calendar();
DROP TRIGGER IF EXISTS hall_booking_day_calendar ON ops.hall_booking_day;
CREATE TRIGGER hall_booking_day_calendar BEFORE INSERT OR UPDATE OF hall_booking_id, booking_date, hall_id ON ops.hall_booking_day
    FOR EACH ROW EXECUTE FUNCTION ops.trg_hall_booking_calendar();

CREATE TABLE IF NOT EXISTS ops.hall_booking_charge (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    hall_booking_id  uuid NOT NULL,
    hall_charge_type_id uuid NOT NULL,
    description      text,
    amount           numeric(18,2) NOT NULL CHECK (amount >= 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, hall_booking_id) REFERENCES ops.hall_booking (tenant_id, id),
    FOREIGN KEY (tenant_id, hall_charge_type_id) REFERENCES ops.hall_charge_type (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.hall_booking_payment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    hall_booking_id  uuid NOT NULL,
    component        text NOT NULL CHECK (component IN ('RENT','SECURITY_DEPOSIT','CHARGES','DEPOSIT_REFUND','REFUND','SHORTFALL')),
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    cash_receipt_id  uuid,
    payment_voucher_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, hall_booking_id) REFERENCES ops.hall_booking (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    CHECK ((cash_receipt_id IS NULL) <> (payment_voucher_id IS NULL))
);

CREATE TABLE IF NOT EXISTS ops.hall_settlement (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    hall_booking_id  uuid NOT NULL,
    inspected_by     uuid,
    inspected_at     timestamptz,
    extra_hours      numeric(6,2) NOT NULL DEFAULT 0,
    electricity_units numeric(10,2),
    damages_amount   numeric(18,2) NOT NULL DEFAULT 0,
    extra_charges    numeric(18,2) NOT NULL DEFAULT 0,
    deposit_held     numeric(18,2) NOT NULL DEFAULT 0,
    deduction_amount numeric(18,2) NOT NULL DEFAULT 0,
    refund_amount    numeric(18,2) NOT NULL DEFAULT 0,
    shortfall_amount numeric(18,2) NOT NULL DEFAULT 0,
    deduction_reason text,
    status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','SETTLED','CANCELLED')),
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, hall_booking_id),
    FOREIGN KEY (tenant_id, hall_booking_id) REFERENCES ops.hall_booking (tenant_id, id),
    FOREIGN KEY (tenant_id, inspected_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    CHECK (deduction_amount = 0 OR deduction_reason IS NOT NULL)
);

-- ===== Community assets (Section 19) ========================================
CREATE TABLE IF NOT EXISTS ops.asset_category (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code              text NOT NULL,
    name              text NOT NULL,
    account_id        uuid,
    depreciation_method text NOT NULL DEFAULT 'NONE' CHECK (depreciation_method IN ('NONE','STRAIGHT_LINE','WRITTEN_DOWN_VALUE')),
    useful_life_months integer CHECK (useful_life_months > 0),
    depreciation_rate numeric(7,4),
    approver_role_id  uuid,
    status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, approver_role_id) REFERENCES iam.role (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.asset_purchase_request (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    request_no        text NOT NULL,
    asset_category_id uuid NOT NULL,
    asset_name        text NOT NULL,
    description       text,
    quantity          integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    estimated_cost    numeric(18,2) NOT NULL CHECK (estimated_cost > 0),
    purpose           text,
    required_by       date,
    department        text,
    location          text,
    preferred_vendor_id uuid,
    requested_by      uuid NOT NULL DEFAULT app.user_id(),
    status            text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','SUBMITTED','VERIFIED','RETURNED','APPROVED',
                                                                      'REJECTED','AUTHORISED','PURCHASED','CANCELLED')),
    approval_request_id uuid,
    workflow_instance_id uuid,
    workflow_version_id  uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, request_no),
    FOREIGN KEY (tenant_id, asset_category_id) REFERENCES ops.asset_category (tenant_id, id),
    FOREIGN KEY (tenant_id, preferred_vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, requested_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id)
);

DO $$ BEGIN
    PERFORM app.add_constraint_if_missing('ops.vendor_bill', 'vendor_bill_asset_purchase_fk',
        'FOREIGN KEY (tenant_id, asset_purchase_request_id) REFERENCES ops.asset_purchase_request (tenant_id, id)');
END $$;

CREATE TABLE IF NOT EXISTS ops.asset_quotation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    asset_purchase_request_id uuid NOT NULL,
    vendor_id         uuid,
    supplier_name     text,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    document_id       uuid,
    is_preferred      boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, asset_purchase_request_id) REFERENCES ops.asset_purchase_request (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES core.document (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.asset (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    asset_no          text NOT NULL,
    branch_id         uuid,
    name              text NOT NULL,
    asset_category_id uuid NOT NULL,
    description       text,
    asset_purchase_request_id uuid,
    purchase_date     date,
    purchase_value    numeric(18,2) CHECK (purchase_value >= 0),
    vendor_id         uuid,
    invoice_no        text,
    invoice_document_id uuid,
    payment_voucher_id uuid,
    location          text,
    department        text,
    assigned_employee_id uuid,
    warranty_expiry   date,
    useful_life_months integer,
    depreciation_method text CHECK (depreciation_method IN ('NONE','STRAIGHT_LINE','WRITTEN_DOWN_VALUE')),
    depreciation_rate numeric(7,4),
    accumulated_depreciation numeric(18,2) NOT NULL DEFAULT 0,
    book_value        numeric(18,2),
    condition         text,
    status            text NOT NULL DEFAULT 'IN_USE' CHECK (status IN ('REQUESTED','APPROVED','PURCHASED','IN_USE',
                                                                      'UNDER_MAINTENANCE','TRANSFERRED','DISPOSED','WRITTEN_OFF')),
    is_opening_balance boolean NOT NULL DEFAULT false,   -- migrated asset
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, asset_no),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, asset_category_id) REFERENCES ops.asset_category (tenant_id, id),
    FOREIGN KEY (tenant_id, asset_purchase_request_id) REFERENCES ops.asset_purchase_request (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, invoice_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, assigned_employee_id) REFERENCES ops.employee (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.asset_assignment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    asset_id          uuid NOT NULL,
    assignment_type   text NOT NULL CHECK (assignment_type IN ('ASSIGN','TRANSFER','RETURN')),
    employee_id       uuid,
    department        text,
    location          text,
    from_date         date NOT NULL DEFAULT app.working_date(),
    to_date           date,
    handover_ack_document_id uuid,
    approval_request_id uuid,
    remarks           text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, asset_id) REFERENCES ops.asset (tenant_id, id),
    FOREIGN KEY (tenant_id, employee_id) REFERENCES ops.employee (tenant_id, id),
    FOREIGN KEY (tenant_id, handover_ack_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.asset_maintenance (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    asset_id          uuid NOT NULL,
    maintenance_date  date NOT NULL DEFAULT app.working_date(),
    maintenance_type  text NOT NULL,
    description       text,
    vendor_id         uuid,
    cost              numeric(18,2) NOT NULL DEFAULT 0 CHECK (cost >= 0),
    invoice_document_id uuid,
    next_due_date     date,
    is_warranty_claim boolean NOT NULL DEFAULT false,
    status            text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','DONE','PAID','CANCELLED')),
    payment_voucher_id uuid,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, asset_id) REFERENCES ops.asset (tenant_id, id),
    FOREIGN KEY (tenant_id, vendor_id) REFERENCES ops.vendor (tenant_id, id),
    FOREIGN KEY (tenant_id, invoice_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.asset_depreciation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    asset_id          uuid NOT NULL,
    financial_period_id uuid,
    period_from       date NOT NULL,
    period_to         date NOT NULL,
    entry_type        text NOT NULL DEFAULT 'DEPRECIATION' CHECK (entry_type IN ('DEPRECIATION','REVALUATION')),
    amount            numeric(18,2) NOT NULL,
    accumulated_after numeric(18,2) NOT NULL,
    book_value_after  numeric(18,2) NOT NULL,
    journal_id        uuid,                               -- only if ledger posting is enabled
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, asset_id, period_from, entry_type),
    FOREIGN KEY (tenant_id, asset_id) REFERENCES ops.asset (tenant_id, id),
    FOREIGN KEY (tenant_id, financial_period_id) REFERENCES acct.financial_period (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.asset_disposal (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    asset_id          uuid NOT NULL,
    disposal_date     date NOT NULL DEFAULT app.working_date(),
    disposal_method   text NOT NULL CHECK (disposal_method IN ('SALE','SCRAP','DONATION','WRITE_OFF','LOSS')),
    reason            text NOT NULL,
    sale_value        numeric(18,2) NOT NULL DEFAULT 0,
    book_value_at_disposal numeric(18,2) NOT NULL,
    gain_loss         numeric(18,2) GENERATED ALWAYS AS (sale_value - book_value_at_disposal) STORED,
    buyer_name        text,
    buyer_details     text,
    status            text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','APPROVED','REJECTED','COMPLETED')),
    cash_receipt_id   uuid,
    journal_id        uuid,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, asset_id),
    FOREIGN KEY (tenant_id, asset_id) REFERENCES ops.asset (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

-- ===== Contributions and donations (Section 20.4) ===========================
CREATE TABLE IF NOT EXISTS ops.contribution_scheme (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code             text NOT NULL,
    name             text NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    frequency        text NOT NULL CHECK (frequency IN ('MONTHLY','QUARTERLY','HALF_YEARLY','ANNUAL','ONE_TIME')),
    due_day          integer CHECK (due_day BETWEEN 1 AND 31),
    fund_id          uuid,
    account_id       uuid,
    restricts_loans_when_overdue boolean NOT NULL DEFAULT false,
    starts_on        date NOT NULL,
    ends_on          date,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE','CLOSED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.contribution_due (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    contribution_scheme_id uuid NOT NULL,
    member_id        uuid NOT NULL,
    period_start     date NOT NULL,
    due_date         date NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    paid_amount      numeric(18,2) NOT NULL DEFAULT 0,
    waived_amount    numeric(18,2) NOT NULL DEFAULT 0,
    status           text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DUE','PARTLY_PAID','PAID','WAIVED','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, contribution_scheme_id, member_id, period_start),
    FOREIGN KEY (tenant_id, contribution_scheme_id) REFERENCES ops.contribution_scheme (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    CHECK (paid_amount + waived_amount <= amount)
);
CREATE INDEX IF NOT EXISTS contribution_due_open_idx ON ops.contribution_due (tenant_id, member_id) WHERE status IN ('DUE','PARTLY_PAID');

CREATE TABLE IF NOT EXISTS ops.contribution_payment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    contribution_due_id uuid NOT NULL,
    cash_receipt_id  uuid NOT NULL,
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    status           text NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','REVERSED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, contribution_due_id) REFERENCES ops.contribution_due (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.donor (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    full_name        text NOT NULL,
    member_id        uuid,
    mobile           text,
    email            text,
    address          text,
    pan              text,                          -- 80G receipts
    is_deleted       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS ops.donation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    donation_no      text NOT NULL,
    donor_id         uuid NOT NULL,
    value_date       date NOT NULL DEFAULT app.working_date(),
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    purpose          text,
    fund_id          uuid NOT NULL,
    is_restricted    boolean NOT NULL DEFAULT false,
    is_80g           boolean NOT NULL DEFAULT false,
    receipt_80g_no   text,
    cash_receipt_id  uuid,
    status           text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, donation_no),
    FOREIGN KEY (tenant_id, donor_id) REFERENCES ops.donor (tenant_id, id),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id)
);
