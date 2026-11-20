-- =============================================================================
-- CFMS / NVS  -  09  Loans: types, applications, fees, disbursement,
--                   schedules, repayments, settlement, default, recovery,
--                   restructuring, write-off, transfer (Sections 6, 7, 8, 12)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Loan types are rule-driven: each type points at a rule set; every loan keeps
-- the rule set version (and workflow version) it was processed under.
-- No top-up loans: additional borrowing is always a new loan row.
-- =============================================================================

CREATE TABLE IF NOT EXISTS loan.loan_type (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code              text NOT NULL,
    name              text NOT NULL,
    description       text,
    interest_method   text NOT NULL DEFAULT 'FLAT' CHECK (interest_method IN ('FLAT','NONE')),
    is_interest_free  boolean NOT NULL DEFAULT false,
    rule_set_id       uuid NOT NULL,                  -- interest, fees, limits, late fee, penalty, settlement
    allows_tranches   boolean NOT NULL DEFAULT false,
    principal_account_id uuid,                        -- Loan Principal Receivable - [type]
    interest_account_id  uuid,
    status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    sort_order        integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, rule_set_id) REFERENCES cfg.rule_set (tenant_id, id),
    FOREIGN KEY (tenant_id, principal_account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, interest_account_id) REFERENCES acct.account (tenant_id, id),
    CHECK (NOT is_interest_free OR interest_method = 'NONE')
);

-- One row per loan, from application (Draft) to closure (Section 6.7 statuses).
CREATE TABLE IF NOT EXISTS loan.loan (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_no              text NOT NULL,              -- LN-2027-0045
    branch_id            uuid,
    member_id            uuid NOT NULL,
    loan_type_id         uuid NOT NULL,
    purpose              text,
    requested_amount     numeric(18,2) NOT NULL CHECK (requested_amount > 0),
    requested_tenure_months integer NOT NULL CHECK (requested_tenure_months > 0),
    application_date     date NOT NULL DEFAULT app.working_date(),
    status               text NOT NULL DEFAULT 'DRAFT' CHECK (status IN (
                           'DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED','APPROVED','REJECTED',
                           'WITHDRAWN','CANCELLED','ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED','TRANSFERRED',
                           'SETTLED','CLOSED','WRITTEN_OFF')),
    status_date          date,
    status_reason        text,
    is_first_loan        boolean NOT NULL DEFAULT false,   -- nominee mandatory
    -- terms fixed at approval (copied from the rule set version in force)
    approved_amount      numeric(18,2) CHECK (approved_amount > 0),
    tenure_months        integer CHECK (tenure_months > 0),
    interest_rate_annual numeric(7,4) CHECK (interest_rate_annual >= 0),
    interest_method      text CHECK (interest_method IN ('FLAT','NONE')),
    total_interest       numeric(18,2),
    instalment_amount    numeric(18,2),
    early_settlement_policy text CHECK (early_settlement_policy IN ('A_ALL_SCHEDULED_INTEREST','B_INTEREST_TO_DATE')),
    approved_at          timestamptz,
    approved_by          uuid,
    approval_request_id  uuid,
    approval_expires_on  date,                        -- disbursement window (default 30 days)
    -- disbursement and balances (denormalised, maintained by the API)
    disbursed_amount     numeric(18,2) NOT NULL DEFAULT 0,
    first_disbursement_date date,
    first_due_date       date,
    maturity_date        date,
    outstanding_principal numeric(18,2) NOT NULL DEFAULT 0,
    is_restructured      boolean NOT NULL DEFAULT false,
    restructure_count    integer NOT NULL DEFAULT 0,
    parent_loan_id       uuid,                        -- successor loan created by transfer
    interest_stopped_from date,                       -- deceased member
    closed_on            date,
    -- version stamping
    workflow_instance_id uuid,
    workflow_version_id  uuid,
    rule_set_version_id  uuid,
    rule_snapshot        jsonb,                       -- rule values evaluated at approval
    created_by_employee  uuid DEFAULT app.user_id(),
    is_deleted           boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_no),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_type_id) REFERENCES loan.loan_type (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, parent_loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    FOREIGN KEY (tenant_id, created_by_employee) REFERENCES iam.app_user (tenant_id, id),
    CONSTRAINT loan_approver_not_creator CHECK (approved_by IS NULL OR approved_by <> created_by_employee),
    CONSTRAINT loan_terms_on_approval CHECK (
        status IN ('DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED','REJECTED','WITHDRAWN')
        OR (approved_amount IS NOT NULL AND tenure_months IS NOT NULL AND rule_set_version_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS loan_member_idx ON loan.loan (tenant_id, member_id);
CREATE INDEX IF NOT EXISTS loan_status_idx ON loan.loan (tenant_id, status);

CREATE TABLE IF NOT EXISTS loan.loan_status_history (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id        uuid NOT NULL,
    from_status    text,
    to_status      text NOT NULL,
    changed_on     date NOT NULL DEFAULT app.working_date(),
    changed_at     timestamptz NOT NULL DEFAULT now(),
    changed_by     uuid DEFAULT app.user_id(),
    reason         text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id)
);

CREATE OR REPLACE FUNCTION loan.trg_loan_status_history()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO loan.loan_status_history (tenant_id, loan_id, from_status, to_status, reason)
        VALUES (NEW.tenant_id, NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
                coalesce(NEW.status_reason, app.setting('app.reason')));
    END IF;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS loan_status_history ON loan.loan;
CREATE TRIGGER loan_status_history AFTER INSERT OR UPDATE OF status ON loan.loan
    FOR EACH ROW EXECUTE FUNCTION loan.trg_loan_status_history();

-- Application fee (non-refundable, optional per loan type) ---------------------------
CREATE TABLE IF NOT EXISTS loan.loan_application_fee (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id          uuid NOT NULL,
    fee_basis        text NOT NULL CHECK (fee_basis IN ('FIXED','PERCENT')),
    fee_rate         numeric(9,4),
    fee_amount       numeric(18,2) NOT NULL CHECK (fee_amount >= 0),
    collect_timing   text NOT NULL DEFAULT 'BEFORE_SUBMISSION' CHECK (collect_timing IN ('BEFORE_SUBMISSION','AFTER_SUBMISSION','AFTER_APPROVAL','DEDUCT_FROM_DISBURSEMENT')),
    status           text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PAID','WAIVED','DEDUCTED')),
    cash_receipt_id  uuid,
    waiver_reason    text,
    waiver_approval_request_id uuid,
    rule_set_version_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, waiver_approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK (status <> 'WAIVED' OR waiver_reason IS NOT NULL)
);

-- Nominees and guarantors --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS loan.loan_nominee (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id      uuid NOT NULL,
    nominee_id   uuid NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_id, nominee_id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, nominee_id) REFERENCES mbr.nominee (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS loan.loan_guarantor (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id            uuid NOT NULL,
    guarantor_member_id uuid,                        -- member guarantor
    non_member_name    text,                         -- approved non-member, if configured
    non_member_mobile  text,
    non_member_address text,
    guaranteed_amount  numeric(18,2) NOT NULL CHECK (guaranteed_amount > 0),
    consent_type       text CHECK (consent_type IN ('SIGNATURE','THUMB_IMPRESSION')),
    consent_document_id uuid,
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RELEASED','REPLACED','INVOKED')),
    replaced_by_id     uuid,
    replacement_approval_request_id uuid,
    released_on        date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, guarantor_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, consent_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, replaced_by_id) REFERENCES loan.loan_guarantor (tenant_id, id),
    FOREIGN KEY (tenant_id, replacement_approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    CHECK (guarantor_member_id IS NOT NULL OR non_member_name IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS loan_guarantor_member_idx ON loan.loan_guarantor (tenant_id, guarantor_member_id) WHERE status = 'ACTIVE';

-- Disbursement (tranches; maker-checker through the payment voucher) --------------------
CREATE TABLE IF NOT EXISTS loan.loan_disbursement (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    tranche_no        integer NOT NULL DEFAULT 1 CHECK (tranche_no > 0),
    value_date        date NOT NULL DEFAULT app.working_date(),
    gross_amount      numeric(18,2) NOT NULL CHECK (gross_amount > 0),
    deductions        numeric(18,2) NOT NULL DEFAULT 0 CHECK (deductions >= 0),  -- fee deducted (if policy allows)
    net_amount        numeric(18,2) GENERATED ALWAYS AS (gross_amount - deductions) STORED,
    payment_voucher_id uuid,
    prepared_by       uuid NOT NULL DEFAULT app.user_id(),
    released_by       uuid,
    status            text NOT NULL DEFAULT 'PREPARED' CHECK (status IN ('PREPARED','PAID','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_id, tranche_no),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, prepared_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, released_by) REFERENCES iam.app_user (tenant_id, id),
    CHECK (released_by IS NULL OR released_by <> prepared_by)
);

-- Repayment schedules: versioned (original, restructure, prepayment, transfer) ---------
CREATE TABLE IF NOT EXISTS loan.loan_schedule (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    schedule_version  integer NOT NULL CHECK (schedule_version > 0),
    reason            text NOT NULL CHECK (reason IN ('ORIGINAL','RESTRUCTURE','PREPAYMENT','TRANSFER','TRANCHE')),
    is_current        boolean NOT NULL DEFAULT true,
    effective_from    date NOT NULL,
    principal_basis   numeric(18,2) NOT NULL,
    interest_rate_annual numeric(7,4) NOT NULL,
    total_interest    numeric(18,2) NOT NULL,
    total_repayable   numeric(18,2) NOT NULL,
    rounding_rule     jsonb,                       -- rounding settings applied
    rule_set_version_id uuid,
    previous_schedule_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_id, schedule_version),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    FOREIGN KEY (tenant_id, previous_schedule_id) REFERENCES loan.loan_schedule (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS loan_schedule_current_uq ON loan.loan_schedule (tenant_id, loan_id) WHERE is_current;

CREATE TABLE IF NOT EXISTS loan.loan_instalment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_schedule_id  uuid NOT NULL,
    loan_id           uuid NOT NULL,
    instalment_no     integer NOT NULL CHECK (instalment_no > 0),
    due_date          date NOT NULL,
    principal_due     numeric(18,2) NOT NULL CHECK (principal_due >= 0),
    interest_due      numeric(18,2) NOT NULL CHECK (interest_due >= 0),
    total_due         numeric(18,2) GENERATED ALWAYS AS (principal_due + interest_due) STORED,
    rounding_adjustment numeric(18,2) NOT NULL DEFAULT 0,   -- final instalment absorbs rounding
    principal_paid    numeric(18,2) NOT NULL DEFAULT 0,
    interest_paid     numeric(18,2) NOT NULL DEFAULT 0,
    late_fee_assessed numeric(18,2) NOT NULL DEFAULT 0,
    late_fee_paid     numeric(18,2) NOT NULL DEFAULT 0,
    status            text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DUE','PARTLY_PAID','PAID','CANCELLED','WAIVED')),
    paid_on           date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_schedule_id, instalment_no),
    FOREIGN KEY (tenant_id, loan_schedule_id) REFERENCES loan.loan_schedule (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    CHECK (principal_paid >= 0 AND interest_paid >= 0 AND principal_paid <= principal_due AND interest_paid <= interest_due)
);
CREATE INDEX IF NOT EXISTS loan_instalment_due_idx ON loan.loan_instalment (tenant_id, due_date) WHERE status IN ('DUE','PARTLY_PAID');

-- Charges assessed (late fee, default penalty, settlement charge) -----------------------
CREATE TABLE IF NOT EXISTS loan.loan_charge (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    loan_instalment_id uuid,
    charge_type       text NOT NULL CHECK (charge_type IN ('LATE_FEE','DEFAULT_PENALTY','SETTLEMENT_CHARGE','OTHER')),
    assessed_on       date NOT NULL DEFAULT app.working_date(),
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    paid_amount       numeric(18,2) NOT NULL DEFAULT 0,
    waived_amount     numeric(18,2) NOT NULL DEFAULT 0,
    status            text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','PAID','WAIVED','CANCELLED')),
    rule_set_version_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_instalment_id) REFERENCES loan.loan_instalment (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK (paid_amount + waived_amount <= amount)
);

-- Repayments and allocation (Section 7.4 order) ----------------------------------------
CREATE TABLE IF NOT EXISTS loan.loan_repayment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    cash_receipt_id   uuid NOT NULL,
    value_date        date NOT NULL DEFAULT app.working_date(),
    repayment_type    text NOT NULL CHECK (repayment_type IN ('REGULAR','PARTIAL','LUMP_SUM','EARLY_SETTLEMENT',
                                                              'DEFAULT_SETTLEMENT','RECOVERY','GUARANTOR','SET_OFF')),
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    principal_amount  numeric(18,2) NOT NULL DEFAULT 0,
    interest_amount   numeric(18,2) NOT NULL DEFAULT 0,
    late_fee_amount   numeric(18,2) NOT NULL DEFAULT 0,
    penalty_amount    numeric(18,2) NOT NULL DEFAULT 0,
    charge_amount     numeric(18,2) NOT NULL DEFAULT 0,
    excess_to_principal numeric(18,2) NOT NULL DEFAULT 0,   -- lump sum reduces principal
    status            text NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','REVERSED')),
    reversal_reason   text,
    rule_set_version_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK (principal_amount + interest_amount + late_fee_amount + penalty_amount + charge_amount = amount)
);
CREATE INDEX IF NOT EXISTS loan_repayment_loan_idx ON loan.loan_repayment (tenant_id, loan_id, value_date);

CREATE TABLE IF NOT EXISTS loan.loan_repayment_allocation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_repayment_id uuid NOT NULL,
    seq               integer NOT NULL,
    loan_instalment_id uuid,
    loan_charge_id    uuid,
    component         text NOT NULL CHECK (component IN ('LATE_FEE','INTEREST','PRINCIPAL','PENALTY','CHARGE','EXCESS_PRINCIPAL')),
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_repayment_id, seq),
    FOREIGN KEY (tenant_id, loan_repayment_id) REFERENCES loan.loan_repayment (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_instalment_id) REFERENCES loan.loan_instalment (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_charge_id) REFERENCES loan.loan_charge (tenant_id, id)
);

-- Waivers (interest, late fee, penalty, settlement charge) -----------------------------
CREATE TABLE IF NOT EXISTS loan.loan_waiver (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    loan_charge_id    uuid,
    component         text NOT NULL CHECK (component IN ('INTEREST','LATE_FEE','PENALTY','SETTLEMENT_CHARGE','PRINCIPAL','APPLICATION_FEE')),
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    reason            text NOT NULL,
    status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_charge_id) REFERENCES loan.loan_charge (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

-- Early / default / negotiated settlement statements ---------------------------------
CREATE TABLE IF NOT EXISTS loan.loan_settlement (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id              uuid NOT NULL,
    settlement_type      text NOT NULL CHECK (settlement_type IN ('EARLY','DEFAULT','NEGOTIATED')),
    statement_date       date NOT NULL DEFAULT app.working_date(),
    interest_policy      text CHECK (interest_policy IN ('A_ALL_SCHEDULED_INTEREST','B_INTEREST_TO_DATE')),
    principal_outstanding numeric(18,2) NOT NULL,
    interest_component   numeric(18,2) NOT NULL DEFAULT 0,
    late_fees            numeric(18,2) NOT NULL DEFAULT 0,
    penalty              numeric(18,2) NOT NULL DEFAULT 0,
    settlement_charge    numeric(18,2) NOT NULL DEFAULT 0,
    rebate               numeric(18,2) NOT NULL DEFAULT 0,
    waiver               numeric(18,2) NOT NULL DEFAULT 0,
    rounding_adjustment  numeric(18,2) NOT NULL DEFAULT 0,
    total_payable        numeric(18,2) NOT NULL,
    components           jsonb,                      -- detailed calculation shown on the statement
    status               text NOT NULL DEFAULT 'QUOTED' CHECK (status IN ('QUOTED','APPROVED','PAID','EXPIRED','CANCELLED')),
    valid_until          date,
    approval_request_id  uuid,
    cash_receipt_id      uuid,
    statement_document_id uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, statement_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id)
);

-- Default events (Section 8) ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS loan.loan_default (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id              uuid NOT NULL,
    defaulted_on         date NOT NULL,
    oldest_unpaid_due_date date NOT NULL,
    unpaid_months_rule   integer NOT NULL,           -- rule value applied (default 2)
    outstanding_principal numeric(18,2) NOT NULL,
    outstanding_interest numeric(18,2) NOT NULL DEFAULT 0,
    penalty_amount       numeric(18,2) NOT NULL DEFAULT 0,
    status               text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','SETTLED','WRITTEN_OFF','TRANSFERRED')),
    settled_on           date,
    cooling_off_until    date,
    loan_settlement_id   uuid,
    rule_set_version_id  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_settlement_id) REFERENCES loan.loan_settlement (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS loan_default_open_uq ON loan.loan_default (tenant_id, loan_id) WHERE status = 'OPEN';

CREATE TABLE IF NOT EXISTS loan.cooling_off_override (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id         uuid NOT NULL,
    loan_default_id   uuid,
    reason            text NOT NULL,
    status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    approval_request_id uuid,
    valid_until       date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_default_id) REFERENCES loan.loan_default (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

-- Recovery (Section 8.6) -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS loan.recovery_case (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    case_no           text NOT NULL,
    loan_id           uuid NOT NULL,
    member_id         uuid NOT NULL,
    loan_default_id   uuid,
    status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                        'PENDING','CONTACTED','PROMISE_TO_PAY','LEGAL_NOTICE','SETTLEMENT_AGREED',
                        'SETTLEMENT_RECEIVED','EXCEPTION_APPROVED','WRITTEN_OFF')),
    assigned_to       uuid,
    escalation_level  text NOT NULL DEFAULT 'EMPLOYEE' CHECK (escalation_level IN ('EMPLOYEE','MANAGER','LEADERSHIP')),
    escalated_at      timestamptz,
    opened_on         date NOT NULL DEFAULT app.working_date(),
    next_follow_up    date,
    closed_on         date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, case_no),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_default_id) REFERENCES loan.loan_default (tenant_id, id),
    FOREIGN KEY (tenant_id, assigned_to) REFERENCES iam.app_user (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS loan.recovery_contact (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    recovery_case_id  uuid NOT NULL,
    contact_date      date NOT NULL DEFAULT app.working_date(),
    method            text NOT NULL CHECK (method IN ('CALL','VISIT','LETTER','SMS','WHATSAPP','LEGAL_NOTICE','OTHER')),
    person_type       text NOT NULL CHECK (person_type IN ('MEMBER','GUARANTOR','NOMINEE','SUCCESSOR','OTHER')),
    person_name       text,
    outcome           text NOT NULL,
    promise_date      date,
    promise_amount    numeric(18,2),
    next_follow_up    date,
    contacted_by      uuid NOT NULL DEFAULT app.user_id(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, recovery_case_id) REFERENCES loan.recovery_case (tenant_id, id),
    FOREIGN KEY (tenant_id, contacted_by) REFERENCES iam.app_user (tenant_id, id)
);

-- Restructuring (Section 6.10) -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS loan.loan_restructure (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    request_date      date NOT NULL DEFAULT app.working_date(),
    reason            text NOT NULL,
    restructure_option text NOT NULL CHECK (restructure_option IN ('EXTEND_TENURE','REDUCE_INSTALMENT','MORATORIUM',
                                                                   'CAPITALISE_OVERDUE','COMBINATION')),
    moratorium_months integer CHECK (moratorium_months >= 0),
    new_tenure_months integer CHECK (new_tenure_months > 0),
    new_interest_rate numeric(7,4),
    status            text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','REJECTED','APPLIED','CANCELLED')),
    approval_request_id uuid,
    old_schedule_id   uuid,
    new_schedule_id   uuid,
    rule_set_version_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, old_schedule_id) REFERENCES loan.loan_schedule (tenant_id, id),
    FOREIGN KEY (tenant_id, new_schedule_id) REFERENCES loan.loan_schedule (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id)
);

-- Write-off (Section 8.7) ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS loan.loan_write_off (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    proposed_on       date NOT NULL DEFAULT app.working_date(),
    principal_amount  numeric(18,2) NOT NULL CHECK (principal_amount > 0),
    reason            text NOT NULL,
    status            text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','APPROVED','REJECTED','POSTED')),
    approval_request_id uuid,
    journal_id        uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id)
);

-- Loans of a deceased member (Section 12) ----------------------------------------------
CREATE TABLE IF NOT EXISTS loan.deceased_loan_decision (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    death_record_id   uuid NOT NULL,
    decision          text NOT NULL CHECK (decision IN ('RECOVER_FROM_SUCCESSOR','RECOVER_FROM_GUARANTOR',
                                                        'SET_OFF_DEPOSITS_CHIT','WAIVE_WRITE_OFF','TRANSFER')),
    interest_stops_from date,
    remarks           text,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, loan_id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, death_record_id) REFERENCES mbr.death_record (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS loan.loan_transfer (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    original_loan_id  uuid NOT NULL,
    successor_loan_id uuid,
    legal_successor_id uuid,
    successor_member_id uuid,
    share_percent     numeric(5,2) CHECK (share_percent > 0 AND share_percent <= 100),
    transferred_principal numeric(18,2) NOT NULL CHECK (transferred_principal > 0),
    consent_document_id uuid,
    legal_verification_document_id uuid,
    status            text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','APPROVED','REJECTED','COMPLETED')),
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, original_loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, successor_loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, legal_successor_id) REFERENCES mbr.legal_successor (tenant_id, id),
    FOREIGN KEY (tenant_id, successor_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, consent_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, legal_verification_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);
