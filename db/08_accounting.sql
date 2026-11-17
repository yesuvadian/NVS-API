-- =============================================================================
-- CFMS / NVS  -  08  Accounting: chart of accounts, periods, funds, journals,
--                   cash receipts / payment vouchers, cash day-end
--                   (Sections 4.6, 20, 21, 22)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Cash basis only. One common cash account per tenant; no banks (table kept
-- for future use). Every posted journal balances; posted entries are never
-- edited or deleted, only reversed. Value date = working date and must not be
-- in the future, in a closed period or on a closed cash day.
-- =============================================================================

-- Chart of accounts -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.account (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code             text NOT NULL,
    name             text NOT NULL,
    account_type     text NOT NULL CHECK (account_type IN ('ASSET','CONTRA_ASSET','LIABILITY','FUND','INCOME','EXPENSE')),
    normal_balance   char(1) NOT NULL CHECK (normal_balance IN ('D','C')),
    parent_id        uuid,
    is_group         boolean NOT NULL DEFAULT false,   -- header accounts cannot be posted to
    is_system        boolean NOT NULL DEFAULT false,   -- cloned from the platform template
    template_code    text,
    module_code      text REFERENCES platform.module (module_code),
    feature_code     text REFERENCES platform.compliance_feature (feature_code),
    is_cash          boolean NOT NULL DEFAULT false,
    allow_manual     boolean NOT NULL DEFAULT true,
    sub_ledger_type  text,                              -- LOAN_TYPE, FUND, HALL, CHIT_GROUP, EMPLOYEE ...
    sub_ledger_id    uuid,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    description      text,
    sort_order       integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, parent_id) REFERENCES acct.account (tenant_id, id)
);

-- Account types never change (Section 21.1)
CREATE OR REPLACE FUNCTION acct.trg_account_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM app.fail('ACCOUNT_DELETE', 'Accounts are never deleted; make the account inactive');
    END IF;
    IF NEW.account_type <> OLD.account_type THEN
        PERFORM app.fail('ACCOUNT_TYPE_FIXED', 'The type of an account cannot be changed');
    END IF;
    IF OLD.is_system AND NEW.code <> OLD.code THEN
        PERFORM app.fail('ACCOUNT_CODE_FIXED', 'The code of a standard account cannot be changed');
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS account_guard ON acct.account;
CREATE TRIGGER account_guard BEFORE UPDATE OR DELETE ON acct.account
    FOR EACH ROW EXECUTE FUNCTION acct.trg_account_guard();

-- Financial years and monthly periods ------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.financial_year (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code          text NOT NULL,                   -- 2026-27
    start_date    date NOT NULL,
    end_date      date NOT NULL,
    status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSING','CLOSED')),
    closed_by     uuid,
    closed_at     timestamptz,
    closing_journal_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    UNIQUE (tenant_id, start_date),
    CHECK (end_date > start_date)
);

CREATE TABLE IF NOT EXISTS acct.financial_period (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    financial_year_id uuid NOT NULL,
    period_no     integer NOT NULL CHECK (period_no BETWEEN 1 AND 13),
    name          text NOT NULL,                   -- Apr-2026
    start_date    date NOT NULL,
    end_date      date NOT NULL,
    status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
    closed_by     uuid,
    closed_at     timestamptz,
    reopened_count integer NOT NULL DEFAULT 0,
    last_reopen_reason text,
    last_reopen_approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, financial_year_id, period_no),
    UNIQUE (tenant_id, start_date),
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES acct.financial_year (tenant_id, id),
    CHECK (end_date >= start_date)
);

-- Cash and (future) bank accounts --------------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.cash_account (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code          text NOT NULL,
    name          text NOT NULL,
    account_id    uuid NOT NULL,
    branch_id     uuid,
    is_default    boolean NOT NULL DEFAULT true,
    custodian_user_id uuid,
    status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, custodian_user_id) REFERENCES iam.app_user (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS cash_account_one_default ON acct.cash_account (tenant_id) WHERE is_default;

CREATE TABLE IF NOT EXISTS acct.bank_account (           -- future use only
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code          text NOT NULL,
    bank_name     text NOT NULL,
    account_number_masked text,
    ifsc          text,
    account_id    uuid NOT NULL,
    status        text NOT NULL DEFAULT 'INACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

-- Funds (Section 20.3) -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.fund (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code          text NOT NULL,
    name          text NOT NULL,
    fund_type     text NOT NULL CHECK (fund_type IN ('UNRESTRICTED','DESIGNATED','RESTRICTED','CORPUS')),
    account_id    uuid NOT NULL,
    purpose       text,                             -- mandatory for restricted funds
    is_default    boolean NOT NULL DEFAULT false,   -- General Community Fund
    status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE','CLOSED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id),
    CHECK (fund_type <> 'RESTRICTED' OR purpose IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS fund_one_default ON acct.fund (tenant_id) WHERE is_default;

-- Account mapping: transaction type (+ scope) -> account; users never pick accounts
CREATE TABLE IF NOT EXISTS acct.account_mapping (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    mapping_key     text NOT NULL,                  -- LOAN_PRINCIPAL, LOAN_INTEREST, APPLICATION_FEE, LATE_FEE ...
    scope_type      text NOT NULL DEFAULT 'NONE',   -- NONE, LOAN_TYPE, EXPENSE_CATEGORY, HALL, FUND, DEPOSIT_PRODUCT, CHIT_GROUP
    scope_id        uuid,
    account_id      uuid NOT NULL,
    effective_from  date NOT NULL DEFAULT '2000-01-01',
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS account_mapping_uq ON acct.account_mapping
    (tenant_id, mapping_key, scope_type, coalesce(scope_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_from);

-- Voucher numbering: continuous per tenant, series and financial year ----------------
CREATE TABLE IF NOT EXISTS acct.voucher_series (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    series_code      text NOT NULL,                 -- RECEIPT, PAYMENT, JOURNAL, CONTRA, LOAN, MEMBER, BOOKING ...
    financial_year_id uuid,                         -- null = not reset yearly (e.g. member numbers)
    prefix           text NOT NULL DEFAULT '',
    next_no          bigint NOT NULL DEFAULT 1 CHECK (next_no > 0),
    pad_length       integer NOT NULL DEFAULT 5,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES acct.financial_year (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS voucher_series_uq ON acct.voucher_series
    (tenant_id, series_code, coalesce(financial_year_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Next number in a series; gapless because the row is locked until commit.
CREATE OR REPLACE FUNCTION acct.next_number(p_series_code text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS
$$
DECLARE
    v_tenant uuid := coalesce(p_tenant_id, app.tenant_id());
    v_fy     acct.financial_year%ROWTYPE;
    v_no     bigint;
    v_prefix text;
    v_pad    integer;
    v_yearly boolean := p_series_code IN ('RECEIPT','PAYMENT','JOURNAL','CONTRA','ADJUSTMENT');
BEGIN
    IF v_yearly THEN
        SELECT * INTO v_fy FROM acct.financial_year
         WHERE tenant_id = v_tenant AND coalesce(p_on, app.working_date()) BETWEEN start_date AND end_date;
        IF NOT FOUND THEN
            PERFORM app.fail('NO_FINANCIAL_YEAR', 'No financial year covers the date');
        END IF;
        INSERT INTO acct.voucher_series (tenant_id, series_code, financial_year_id, prefix)
        VALUES (v_tenant, p_series_code, v_fy.id, left(p_series_code, 3) || '/' || v_fy.code || '/')
        ON CONFLICT DO NOTHING;
    ELSE
        INSERT INTO acct.voucher_series (tenant_id, series_code, financial_year_id, prefix)
        VALUES (v_tenant, p_series_code, NULL, left(p_series_code, 3) || '-')
        ON CONFLICT DO NOTHING;
    END IF;

    UPDATE acct.voucher_series s
       SET next_no = s.next_no + 1
     WHERE s.tenant_id = v_tenant AND s.series_code = p_series_code
       AND s.financial_year_id IS NOT DISTINCT FROM (CASE WHEN v_yearly THEN v_fy.id END)
    RETURNING s.next_no - 1, s.prefix, s.pad_length INTO v_no, v_prefix, v_pad;

    RETURN v_prefix || lpad(v_no::text, v_pad, '0');
END
$$;

-- Cash day (day-end closing and denomination count, Section 21.6) ----------------------
CREATE TABLE IF NOT EXISTS acct.cash_day (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    cash_account_id  uuid NOT NULL,
    business_date    date NOT NULL,
    opening_balance  numeric(18,2) NOT NULL DEFAULT 0,
    total_receipts   numeric(18,2) NOT NULL DEFAULT 0,
    total_payments   numeric(18,2) NOT NULL DEFAULT 0,
    book_balance     numeric(18,2) GENERATED ALWAYS AS (opening_balance + total_receipts - total_payments) STORED,
    counted_balance  numeric(18,2),
    variance         numeric(18,2) GENERATED ALWAYS AS (counted_balance - (opening_balance + total_receipts - total_payments)) STORED,
    variance_reason  text,
    variance_journal_id uuid,
    status           text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','COUNTED','CLOSED')),
    custodian_user_id uuid,
    counted_by       uuid,
    counted_at       timestamptz,
    approved_by      uuid,                          -- Manager approval of variance
    closed_by        uuid,
    closed_at        timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, cash_account_id, business_date),
    FOREIGN KEY (tenant_id, cash_account_id) REFERENCES acct.cash_account (tenant_id, id),
    FOREIGN KEY (tenant_id, custodian_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, counted_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, closed_by) REFERENCES iam.app_user (tenant_id, id),
    CHECK (status <> 'CLOSED' OR counted_balance IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS acct.cash_denomination_count (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    cash_day_id     uuid NOT NULL,
    denomination    numeric(10,2) NOT NULL CHECK (denomination > 0),
    note_count      integer NOT NULL CHECK (note_count >= 0),
    amount          numeric(18,2) GENERATED ALWAYS AS (denomination * note_count) STORED,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, cash_day_id, denomination),
    FOREIGN KEY (tenant_id, cash_day_id) REFERENCES acct.cash_day (tenant_id, id)
);

-- Working-date guard: not future, not in a closed period, not on a closed day.
CREATE OR REPLACE FUNCTION acct.assert_open_date(p_tenant_id uuid, p_date date)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
DECLARE v_limit integer;
BEGIN
    IF p_date IS NULL THEN
        PERFORM app.fail('NO_VALUE_DATE', 'A value (working) date is required');
    END IF;
    IF p_date > app.tenant_today(p_tenant_id) THEN
        PERFORM app.fail('FUTURE_DATE', format('Working date %s is in the future', p_date));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM acct.financial_period p
                    WHERE p.tenant_id = p_tenant_id AND p_date BETWEEN p.start_date AND p.end_date
                      AND p.status = 'OPEN') THEN
        PERFORM app.fail('PERIOD_CLOSED', format('No open accounting period for %s', p_date));
    END IF;
    IF EXISTS (SELECT 1 FROM acct.cash_day d
                WHERE d.tenant_id = p_tenant_id AND d.business_date = p_date AND d.status = 'CLOSED') THEN
        PERFORM app.fail('DAY_CLOSED', format('Cash day %s is closed', p_date));
    END IF;
    v_limit := (cfg.get_setting('accounting.backdating_limit_days', NULL, p_tenant_id) #>> '{}')::integer;
    IF v_limit IS NOT NULL AND p_date < app.tenant_today(p_tenant_id) - v_limit THEN
        PERFORM app.fail('BACKDATE_LIMIT', format('Working date %s is beyond the backdating limit of %s days', p_date, v_limit));
    END IF;
END
$$;

-- Journals ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.journal (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    journal_no        text,                         -- assigned on posting
    voucher_type      text NOT NULL CHECK (voucher_type IN ('JOURNAL','RECEIPT','PAYMENT','CONTRA','ADJUSTMENT',
                                                            'REVERSAL','OPENING','YEAR_END')),
    value_date        date NOT NULL DEFAULT app.working_date(),
    entry_at          timestamptz NOT NULL DEFAULT now(),
    financial_period_id uuid,
    status            text NOT NULL DEFAULT 'DRAFT'
                      CHECK (status IN ('DRAFT','PENDING_APPROVAL','POSTED','REVERSED','CANCELLED')),
    is_manual         boolean NOT NULL DEFAULT false,
    narration         text,
    total_amount      numeric(18,2),
    source_module     text REFERENCES platform.module (module_code),
    source_entity_type text,
    source_entity_id  uuid,
    source_ref        text,
    idempotency_key   text,                         -- prevents duplicate postings
    reversal_of_journal_id uuid,
    reversed_by_journal_id uuid,
    reversal_reason   text,
    approval_request_id uuid,
    approved_by       uuid,
    posted_by         uuid,
    posted_at         timestamptz,
    workflow_version_id uuid,
    rule_set_version_id uuid,                       -- journal template version used
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, financial_period_id) REFERENCES acct.financial_period (tenant_id, id),
    FOREIGN KEY (tenant_id, reversal_of_journal_id) REFERENCES acct.journal (tenant_id, id),
    FOREIGN KEY (tenant_id, reversed_by_journal_id) REFERENCES acct.journal (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, posted_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CONSTRAINT journal_manual_maker_checker CHECK (NOT is_manual OR approved_by IS NULL OR approved_by <> created_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS journal_no_uq ON acct.journal (tenant_id, journal_no) WHERE journal_no IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS journal_idempotency_uq ON acct.journal (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS journal_one_reversal_uq ON acct.journal (tenant_id, reversal_of_journal_id) WHERE reversal_of_journal_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_date_idx ON acct.journal (tenant_id, value_date) WHERE status IN ('POSTED','REVERSED');
CREATE INDEX IF NOT EXISTS journal_source_idx ON acct.journal (tenant_id, source_entity_type, source_entity_id);

CREATE TABLE IF NOT EXISTS acct.journal_line (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    journal_id      uuid NOT NULL,
    line_no         integer NOT NULL,
    account_id      uuid NOT NULL,
    fund_id         uuid,
    debit           numeric(18,2) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
    credit          numeric(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    narration       text,
    member_id       uuid,
    sub_entity_type text,                           -- loan.loan, ops.hall ...
    sub_entity_id   uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, journal_id, line_no),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    CONSTRAINT journal_line_one_side CHECK ((debit = 0) <> (credit = 0))
);
CREATE INDEX IF NOT EXISTS journal_line_account_idx ON acct.journal_line (tenant_id, account_id);

CREATE OR REPLACE FUNCTION acct.trg_journal_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'DRAFT' THEN
            PERFORM app.fail('JOURNAL_IMMUTABLE', 'Only draft journals can be deleted; posted journals are reversed');
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.status IN ('POSTED','REVERSED','CANCELLED') THEN
        IF OLD.status = 'POSTED' AND NEW.status = 'REVERSED' AND NEW.reversed_by_journal_id IS NOT NULL
           AND (to_jsonb(NEW) - ARRAY['status','reversed_by_journal_id','reversal_reason','updated_at','updated_by','row_version'])
             = (to_jsonb(OLD) - ARRAY['status','reversed_by_journal_id','reversal_reason','updated_at','updated_by','row_version']) THEN
            RETURN NEW;
        END IF;
        PERFORM app.fail('JOURNAL_IMMUTABLE', 'A posted journal cannot be changed; post a reversal instead');
    END IF;

    IF NEW.status = 'POSTED' AND (TG_OP = 'INSERT' OR OLD.status <> 'POSTED') THEN
        PERFORM acct.assert_open_date(NEW.tenant_id, NEW.value_date);
        IF NEW.is_manual AND NEW.approved_by IS NULL THEN
            PERFORM app.fail('MANUAL_JOURNAL_APPROVAL', 'Manual journals require approval before posting');
        END IF;
        SELECT p.id INTO NEW.financial_period_id FROM acct.financial_period p
         WHERE p.tenant_id = NEW.tenant_id AND NEW.value_date BETWEEN p.start_date AND p.end_date;
        NEW.posted_at := now();          -- transaction start time; also marks "posted in this transaction"
        NEW.posted_by := coalesce(NEW.posted_by, app.setting('app.user_id')::uuid);
        NEW.journal_no := coalesce(NEW.journal_no,
            acct.next_number(CASE NEW.voucher_type WHEN 'CONTRA' THEN 'CONTRA' WHEN 'ADJUSTMENT' THEN 'ADJUSTMENT' ELSE 'JOURNAL' END,
                             NEW.value_date, NEW.tenant_id));
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS journal_guard ON acct.journal;
CREATE TRIGGER journal_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.journal
    FOR EACH ROW EXECUTE FUNCTION acct.trg_journal_guard();

-- Lines of a posted journal are frozen. Lines may still be added in the same
-- transaction that posted the journal, so a journal can be inserted as POSTED
-- together with its lines; the deferred balance check runs at commit.
CREATE OR REPLACE FUNCTION acct.trg_journal_line_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_row   acct.journal_line%ROWTYPE := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    v_status text;
    v_same_tx boolean;
BEGIN
    SELECT j.status, (j.posted_at = now())          -- now() = start of the current transaction
      INTO v_status, v_same_tx
      FROM acct.journal j WHERE j.tenant_id = v_row.tenant_id AND j.id = v_row.journal_id;

    IF v_status IN ('POSTED','REVERSED','CANCELLED') AND NOT (TG_OP = 'INSERT' AND v_same_tx) THEN
        PERFORM app.fail('JOURNAL_IMMUTABLE', 'Lines of a posted journal cannot be changed');
    END IF;
    IF TG_OP <> 'DELETE' AND EXISTS (SELECT 1 FROM acct.account a
                                      WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.account_id
                                        AND (a.is_group OR a.status <> 'ACTIVE')) THEN
        PERFORM app.fail('ACCOUNT_NOT_POSTABLE', 'Cannot post to a group or inactive account');
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;
DROP TRIGGER IF EXISTS journal_line_guard ON acct.journal_line;
CREATE TRIGGER journal_line_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.journal_line
    FOR EACH ROW EXECUTE FUNCTION acct.trg_journal_line_guard();

-- Every posted journal must balance (checked at commit).
CREATE OR REPLACE FUNCTION acct.trg_journal_balanced()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_journal_id uuid;
    v_tenant     uuid;
    v_status     text;
    v_dr numeric; v_cr numeric; v_n integer;
BEGIN
    IF TG_TABLE_NAME = 'journal' THEN
        v_journal_id := NEW.id; v_tenant := NEW.tenant_id;
    ELSE
        v_journal_id := coalesce(NEW.journal_id, OLD.journal_id);
        v_tenant := coalesce(NEW.tenant_id, OLD.tenant_id);
    END IF;
    SELECT status INTO v_status FROM acct.journal WHERE tenant_id = v_tenant AND id = v_journal_id;
    IF v_status IN ('POSTED','REVERSED') THEN
        SELECT coalesce(sum(debit),0), coalesce(sum(credit),0), count(*)
          INTO v_dr, v_cr, v_n
          FROM acct.journal_line WHERE tenant_id = v_tenant AND journal_id = v_journal_id;
        IF v_n < 2 OR v_dr <> v_cr OR v_dr = 0 THEN
            PERFORM app.fail('JOURNAL_UNBALANCED',
                format('Journal %s does not balance (debit %s, credit %s, lines %s)', v_journal_id, v_dr, v_cr, v_n));
        END IF;
    END IF;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS journal_balanced ON acct.journal;
CREATE CONSTRAINT TRIGGER journal_balanced AFTER INSERT OR UPDATE ON acct.journal
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION acct.trg_journal_balanced();
DROP TRIGGER IF EXISTS journal_line_balanced ON acct.journal_line;
CREATE CONSTRAINT TRIGGER journal_line_balanced AFTER INSERT OR UPDATE OR DELETE ON acct.journal_line
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION acct.trg_journal_balanced();

-- Cash receipts (all modules) ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.cash_receipt (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    receipt_no        text NOT NULL,
    branch_id         uuid,
    cash_account_id   uuid NOT NULL,
    value_date        date NOT NULL DEFAULT app.working_date(),
    entry_at          timestamptz NOT NULL DEFAULT now(),
    payer_type        text NOT NULL CHECK (payer_type IN ('MEMBER','HALL_CUSTOMER','DONOR','VENDOR','EMPLOYEE','OTHER')),
    member_id         uuid,
    payer_name        text NOT NULL,
    payer_mobile      text,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    payment_mode      text NOT NULL DEFAULT 'CASH' REFERENCES platform.payment_mode (mode_code),
    payment_reference text,
    purpose           text NOT NULL,                -- LOAN_REPAYMENT, APPLICATION_FEE, HALL_RENT, CONTRIBUTION ...
    source_module     text REFERENCES platform.module (module_code),
    source_entity_type text,
    source_entity_id  uuid,
    fund_id           uuid,
    status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CANCELLED')),
    journal_id        uuid,
    collected_by      uuid NOT NULL DEFAULT app.user_id(),
    cancelled_at      timestamptz,
    cancelled_by      uuid,
    cancel_reason     text,
    cancel_approval_request_id uuid,
    reversal_journal_id uuid,
    print_count       integer NOT NULL DEFAULT 0,
    last_printed_at   timestamptz,
    last_printed_by   uuid,
    idempotency_key   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, receipt_no),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_account_id) REFERENCES acct.cash_account (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    FOREIGN KEY (tenant_id, collected_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, cancelled_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, cancel_approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, reversal_journal_id) REFERENCES acct.journal (tenant_id, id),
    CHECK (status <> 'CANCELLED' OR (cancel_reason IS NOT NULL AND cancelled_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS cash_receipt_idem_uq ON acct.cash_receipt (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS cash_receipt_date_idx ON acct.cash_receipt (tenant_id, value_date);
CREATE INDEX IF NOT EXISTS cash_receipt_member_idx ON acct.cash_receipt (tenant_id, member_id);

CREATE TABLE IF NOT EXISTS acct.cash_receipt_line (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    cash_receipt_id uuid NOT NULL,
    line_no         integer NOT NULL,
    component       text NOT NULL,                  -- PRINCIPAL, INTEREST, LATE_FEE, PENALTY, FEE, RENT, DEPOSIT ...
    amount          numeric(18,2) NOT NULL CHECK (amount > 0),
    account_id      uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, cash_receipt_id, line_no),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

-- Payment vouchers (all cash payments; maker-checker; payee acknowledgement) -----------
CREATE TABLE IF NOT EXISTS acct.payment_voucher (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    voucher_no        text NOT NULL,
    branch_id         uuid,
    cash_account_id   uuid NOT NULL,
    value_date        date NOT NULL DEFAULT app.working_date(),
    entry_at          timestamptz NOT NULL DEFAULT now(),
    payee_type        text NOT NULL CHECK (payee_type IN ('MEMBER','EMPLOYEE','VENDOR','HALL_CUSTOMER','NOMINEE','SUCCESSOR','OTHER')),
    member_id         uuid,
    payee_name        text NOT NULL,
    payee_mobile      text,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    payment_mode      text NOT NULL DEFAULT 'CASH' REFERENCES platform.payment_mode (mode_code),
    payment_reference text,
    purpose           text NOT NULL,                -- LOAN_DISBURSEMENT, ASSISTANCE, SALARY, EXPENSE, REFUND, PRIZE ...
    source_module     text REFERENCES platform.module (module_code),
    source_entity_type text,
    source_entity_id  uuid,
    fund_id           uuid,
    status            text NOT NULL DEFAULT 'PREPARED' CHECK (status IN ('PREPARED','PAID','CANCELLED')),
    prepared_by       uuid NOT NULL DEFAULT app.user_id(),
    released_by       uuid,                         -- different user releases the cash
    released_at       timestamptz,
    payee_ack_type    text CHECK (payee_ack_type IN ('SIGNATURE','THUMB_IMPRESSION')),
    payee_ack_document_id uuid,
    journal_id        uuid,
    cancelled_at      timestamptz,
    cancelled_by      uuid,
    cancel_reason     text,
    reversal_journal_id uuid,
    print_count       integer NOT NULL DEFAULT 0,
    idempotency_key   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, voucher_no),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_account_id) REFERENCES acct.cash_account (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, prepared_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, released_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, payee_ack_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    FOREIGN KEY (tenant_id, cancelled_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, reversal_journal_id) REFERENCES acct.journal (tenant_id, id),
    CONSTRAINT payment_voucher_maker_checker CHECK (released_by IS NULL OR released_by <> prepared_by),
    CONSTRAINT payment_voucher_paid_fields CHECK (status <> 'PAID' OR (released_by IS NOT NULL AND payee_ack_type IS NOT NULL)),
    CHECK (status <> 'CANCELLED' OR cancel_reason IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS payment_voucher_idem_uq ON acct.payment_voucher (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS payment_voucher_date_idx ON acct.payment_voucher (tenant_id, value_date);

CREATE TABLE IF NOT EXISTS acct.payment_voucher_line (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    payment_voucher_id uuid NOT NULL,
    line_no         integer NOT NULL,
    component       text NOT NULL,
    amount          numeric(18,2) NOT NULL CHECK (amount <> 0),   -- negative = deduction shown on voucher
    account_id      uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, payment_voucher_id, line_no),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

-- Receipts / vouchers: date guard on entry; amounts and dates frozen afterwards.
CREATE OR REPLACE FUNCTION acct.trg_cash_document_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_mutable text[] := ARRAY['status','journal_id','cancelled_at','cancelled_by','cancel_reason',
                              'cancel_approval_request_id','reversal_journal_id','print_count',
                              'last_printed_at','last_printed_by','released_by','released_at',
                              'payee_ack_type','payee_ack_document_id','updated_at','updated_by','row_version'];
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM app.fail('CASH_DOC_IMMUTABLE', 'Receipts and vouchers are never deleted; cancel by reversal');
    END IF;
    IF TG_OP = 'INSERT' THEN
        PERFORM acct.assert_open_date(NEW.tenant_id, NEW.value_date);
        RETURN NEW;
    END IF;
    IF (to_jsonb(NEW) - v_mutable) <> (to_jsonb(OLD) - v_mutable) THEN
        PERFORM app.fail('CASH_DOC_IMMUTABLE', 'Amounts, dates and parties of a receipt or voucher cannot be edited');
    END IF;
    IF OLD.status = 'CANCELLED' AND NEW.status <> 'CANCELLED' THEN
        PERFORM app.fail('CASH_DOC_IMMUTABLE', 'A cancelled receipt or voucher cannot be reinstated');
    END IF;
    IF OLD.journal_id IS NOT NULL AND NEW.journal_id IS DISTINCT FROM OLD.journal_id THEN
        PERFORM app.fail('CASH_DOC_IMMUTABLE', 'The posting of a receipt or voucher cannot be replaced');
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS cash_receipt_guard ON acct.cash_receipt;
CREATE TRIGGER cash_receipt_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.cash_receipt
    FOR EACH ROW EXECUTE FUNCTION acct.trg_cash_document_guard();
DROP TRIGGER IF EXISTS payment_voucher_guard ON acct.payment_voucher;
CREATE TRIGGER payment_voucher_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.payment_voucher
    FOR EACH ROW EXECUTE FUNCTION acct.trg_cash_document_guard();

-- Fund transfers (Leadership approval) ----------------------------------------------------
CREATE TABLE IF NOT EXISTS acct.fund_transfer (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    transfer_no     text NOT NULL,
    from_fund_id    uuid NOT NULL,
    to_fund_id      uuid NOT NULL,
    amount          numeric(18,2) NOT NULL CHECK (amount > 0),
    value_date      date NOT NULL DEFAULT app.working_date(),
    reason          text NOT NULL,
    status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','POSTED','CANCELLED')),
    approval_request_id uuid,
    journal_id      uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, transfer_no),
    FOREIGN KEY (tenant_id, from_fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, to_fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    CHECK (from_fund_id <> to_fund_id)
);

-- Reporting helpers --------------------------------------------------------------------------

-- Ledger of posted entries (reversed journals and their reversals both count).
CREATE OR REPLACE VIEW acct.v_ledger AS
SELECT j.tenant_id, j.id AS journal_id, j.journal_no, j.voucher_type, j.value_date, j.entry_at,
       j.status, j.narration, j.source_module, j.source_ref,
       l.line_no, l.account_id, a.code AS account_code, a.name AS account_name, a.account_type,
       l.fund_id, l.member_id, l.debit, l.credit, l.narration AS line_narration
  FROM acct.journal j
  JOIN acct.journal_line l ON l.tenant_id = j.tenant_id AND l.journal_id = j.id
  JOIN acct.account a      ON a.tenant_id = l.tenant_id AND a.id = l.account_id
 WHERE j.status IN ('POSTED','REVERSED');

-- Cash position for a date (top bar): opening, receipts, payments, current balance.
CREATE OR REPLACE FUNCTION acct.cash_position(p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS TABLE (cash_account_id uuid, opening_balance numeric, receipts numeric, payments numeric, closing_balance numeric)
LANGUAGE sql STABLE AS
$$
    SELECT ca.id,
           coalesce(sum(l.debit - l.credit) FILTER (WHERE l.value_date <  d.on_date), 0),
           coalesce(sum(l.debit)            FILTER (WHERE l.value_date =  d.on_date), 0),
           coalesce(sum(l.credit)           FILTER (WHERE l.value_date =  d.on_date), 0),
           coalesce(sum(l.debit - l.credit) FILTER (WHERE l.value_date <= d.on_date), 0)
      FROM (SELECT coalesce(p_on, app.working_date()) AS on_date, coalesce(p_tenant_id, app.tenant_id()) AS tid) d
      JOIN acct.cash_account ca ON ca.tenant_id = d.tid
      LEFT JOIN acct.v_ledger l ON l.tenant_id = ca.tenant_id AND l.account_id = ca.account_id
     GROUP BY ca.id
$$;

CREATE OR REPLACE VIEW acct.v_trial_balance AS
SELECT l.tenant_id, p.financial_year_id, p.id AS financial_period_id, p.name AS period_name,
       l.account_id, l.account_code, l.account_name, l.account_type,
       sum(l.debit) AS total_debit, sum(l.credit) AS total_credit,
       sum(l.debit - l.credit) AS net_debit
  FROM acct.v_ledger l
  JOIN acct.financial_period p ON p.tenant_id = l.tenant_id AND l.value_date BETWEEN p.start_date AND p.end_date
 GROUP BY l.tenant_id, p.financial_year_id, p.id, p.name, l.account_id, l.account_code, l.account_name, l.account_type;

-- Backdated entries report (working date differs from entry date).
CREATE OR REPLACE VIEW acct.v_backdated_entries AS
SELECT 'RECEIPT' AS doc_type, r.tenant_id, r.id, r.receipt_no AS doc_no, r.value_date, r.entry_at, r.amount, r.collected_by AS user_id
  FROM acct.cash_receipt r
  JOIN platform.tenant t ON t.id = r.tenant_id
 WHERE r.value_date <> (r.entry_at AT TIME ZONE t.time_zone)::date
UNION ALL
SELECT 'PAYMENT', v.tenant_id, v.id, v.voucher_no, v.value_date, v.entry_at, v.amount, v.prepared_by
  FROM acct.payment_voucher v
  JOIN platform.tenant t ON t.id = v.tenant_id
 WHERE v.value_date <> (v.entry_at AT TIME ZONE t.time_zone)::date
UNION ALL
SELECT 'JOURNAL', j.tenant_id, j.id, j.journal_no, j.value_date, j.entry_at, j.total_amount, j.created_by
  FROM acct.journal j
  JOIN platform.tenant t ON t.id = j.tenant_id
 WHERE j.status IN ('POSTED','REVERSED') AND j.value_date <> (j.entry_at AT TIME ZONE t.time_zone)::date;
