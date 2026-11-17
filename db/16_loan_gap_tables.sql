-- =============================================================================
-- CFMS / NVS  -  16  Loan module additions (functional gap review, Nov 2026)
-- -----------------------------------------------------------------------------
-- Run as nvs, before 20_security_rls_audit.sql (which secures and audits every
-- tenant table). Safe to re-run.
-- =============================================================================

-- Migrated loans whose default would apply retroactively are listed for
-- review instead of being defaulted by the daily job (scope 39.3).
CREATE TABLE IF NOT EXISTS loan.migration_default_review (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    listed_on         date NOT NULL DEFAULT app.working_date(),
    oldest_unpaid_due_date date NOT NULL,
    go_live_date      date,
    status            text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','DEFAULT_APPLIED','DISMISSED')),
    decided_by        uuid,
    decided_at        timestamptz,
    remarks           text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, decided_by) REFERENCES iam.app_user (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS migration_default_review_open_uq
    ON loan.migration_default_review (tenant_id, loan_id) WHERE status = 'OPEN';

-- Cooling-off override request and decision details (scope 8.5).
ALTER TABLE loan.cooling_off_override
    ADD COLUMN IF NOT EXISTS evidence_document_id uuid,
    ADD COLUMN IF NOT EXISTS requested_by uuid DEFAULT app.user_id(),
    ADD COLUMN IF NOT EXISTS decided_by uuid,
    ADD COLUMN IF NOT EXISTS decided_on date,
    ADD COLUMN IF NOT EXISTS decision_remarks text,
    ADD COLUMN IF NOT EXISTS previous_eligibility text;

DO $$ BEGIN
    PERFORM app.add_constraint_if_missing('loan.cooling_off_override', 'cooling_off_override_evidence_fk',
        'FOREIGN KEY (tenant_id, evidence_document_id) REFERENCES core.document (tenant_id, id)');
    PERFORM app.add_constraint_if_missing('loan.cooling_off_override', 'cooling_off_override_decided_by_fk',
        'FOREIGN KEY (tenant_id, decided_by) REFERENCES iam.app_user (tenant_id, id)');
END $$;

-- Repayment receipt reversal (scope 7.7). Before day-end one approver
-- (setting cash.receipt_cancel_same_day_approver, Manager); after day-end all of
-- cash.receipt_cancel_after_close_approvers (Manager and Accountant).
CREATE TABLE IF NOT EXISTS loan.repayment_reversal (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    loan_repayment_id uuid NOT NULL,
    cash_receipt_id   uuid NOT NULL,
    reason            text NOT NULL,
    after_day_close   boolean NOT NULL,
    required_roles    text[] NOT NULL,
    approvals         jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{role, user_id, at, remarks}]
    status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    requested_by      uuid DEFAULT app.user_id(),
    requested_on      date NOT NULL DEFAULT app.working_date(),
    decided_by        uuid,
    decided_at        timestamptz,
    decision_remarks  text,
    reversal_journal_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_repayment_id) REFERENCES loan.loan_repayment (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, reversal_journal_id) REFERENCES acct.journal (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS repayment_reversal_pending_uq
    ON loan.repayment_reversal (tenant_id, loan_repayment_id) WHERE status = 'PENDING';

-- Cancellation of an approved, not yet disbursed loan (scope 6.6).
CREATE TABLE IF NOT EXISTS loan.loan_cancellation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id           uuid NOT NULL,
    reason            text NOT NULL,
    status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    requested_by      uuid DEFAULT app.user_id(),
    requested_on      date NOT NULL DEFAULT app.working_date(),
    decided_by        uuid,
    decided_on        date,
    decision_remarks  text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, decided_by) REFERENCES iam.app_user (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS loan_cancellation_pending_uq
    ON loan.loan_cancellation (tenant_id, loan_id) WHERE status = 'PENDING';

-- Replacement of a guarantor on a running loan (scope 6.9): Manager approval.
CREATE TABLE IF NOT EXISTS loan.guarantor_replacement (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    loan_id              uuid NOT NULL,
    loan_guarantor_id    uuid NOT NULL,
    new_guarantor        jsonb NOT NULL,      -- guarantor_member_id or non_member_*, guaranteed_amount, consent_type, consent_document_id
    reason               text NOT NULL,
    status               text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    requested_by         uuid DEFAULT app.user_id(),
    requested_on         date NOT NULL DEFAULT app.working_date(),
    decided_by           uuid,
    decided_on           date,
    decision_remarks     text,
    new_loan_guarantor_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_guarantor_id) REFERENCES loan.loan_guarantor (tenant_id, id),
    FOREIGN KEY (tenant_id, new_loan_guarantor_id) REFERENCES loan.loan_guarantor (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS guarantor_replacement_pending_uq
    ON loan.guarantor_replacement (tenant_id, loan_guarantor_id) WHERE status = 'PENDING';

-- Cash disbursement above the limit (setting cash.disbursement_limit, scope 21.6)
-- needs an extra approval before release.
ALTER TABLE loan.loan_disbursement
    ADD COLUMN IF NOT EXISTS cash_limit_approved_by uuid,
    ADD COLUMN IF NOT EXISTS cash_limit_approved_at timestamptz,
    ADD COLUMN IF NOT EXISTS cash_limit_remarks text;

-- Interest stopped on a deceased member's loan creates a new schedule version.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'loan.loan_schedule'::regclass
                  AND conname = 'loan_schedule_reason_check'
                  AND pg_get_constraintdef(oid) NOT LIKE '%DECEASED%') THEN
        ALTER TABLE loan.loan_schedule DROP CONSTRAINT loan_schedule_reason_check;
    END IF;
    PERFORM app.add_constraint_if_missing('loan.loan_schedule', 'loan_schedule_reason_check',
        'CHECK (reason IN (''ORIGINAL'',''RESTRUCTURE'',''PREPAYMENT'',''TRANSFER'',''TRANCHE'',''DECEASED''))');
    PERFORM app.add_constraint_if_missing('loan.loan_disbursement', 'loan_disbursement_cash_limit_approver_fk',
        'FOREIGN KEY (tenant_id, cash_limit_approved_by) REFERENCES iam.app_user (tenant_id, id)');
END $$;

-- Who asked for a restructure or transfer (maker-checker).
ALTER TABLE loan.loan_restructure
    ADD COLUMN IF NOT EXISTS requested_by uuid DEFAULT app.user_id(),
    ADD COLUMN IF NOT EXISTS decided_by uuid,
    ADD COLUMN IF NOT EXISTS decided_on date,
    ADD COLUMN IF NOT EXISTS decision_remarks text,
    ADD COLUMN IF NOT EXISTS capitalised_amount numeric(18,2) NOT NULL DEFAULT 0;
ALTER TABLE loan.loan_transfer
    ADD COLUMN IF NOT EXISTS requested_by uuid DEFAULT app.user_id(),
    ADD COLUMN IF NOT EXISTS decided_by uuid,
    ADD COLUMN IF NOT EXISTS decided_on date;
ALTER TABLE loan.deceased_loan_decision
    ADD COLUMN IF NOT EXISTS decided_by uuid DEFAULT app.user_id();

-- Documents a loan type needs before an application is submitted (gap L8)
ALTER TABLE loan.loan_type ADD COLUMN IF NOT EXISTS required_documents jsonb NOT NULL DEFAULT '[]'::jsonb;
