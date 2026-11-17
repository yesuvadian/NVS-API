-- =============================================================================
-- CFMS 13 - Functional review (second pass) additions, 15 Nov 2026
--   1  Loan repayments from salary deduction, deposit set-off or journal
--   2  Matching totals checked at commit (receipts, vouchers, journals,
--      repayment allocations, tranches, payslips)
--   3  Business rules on status changes (fee before submission, member exit,
--      hall confirmation, disbursement window and member status)
--   4  Period close, period reopen and year-end close
--   5  Member unapplied receipts (account 2120)
--   8  Loan balance, loan control reconciliation and member financial profile views
--   9  Deposit death claims, premature closure requests, nominee shares = 100%
--  10  Chit dividend payouts, refunds, foreman security and group reconciliation
--  11  Hall booking approvals (family declaration, cancellation refund)
-- Items 6 and 7 (workflow and rule-set templates) are in 42_seed_templates.sql.
-- Runs before 20, so RLS, touch and audit triggers are applied there. Idempotent.
-- =============================================================================

-- =============================================================================
-- 1. Loan repayments that are not cash receipts
-- =============================================================================
ALTER TABLE loan.loan_repayment ALTER COLUMN cash_receipt_id DROP NOT NULL;
ALTER TABLE loan.loan_repayment
    ADD COLUMN IF NOT EXISTS payslip_line_id        uuid,
    ADD COLUMN IF NOT EXISTS deposit_transaction_id uuid,
    ADD COLUMN IF NOT EXISTS journal_id             uuid;
DO $$
BEGIN
    PERFORM app.add_constraint_if_missing('loan.loan_repayment', 'loan_repayment_payslip_line_fk',
        'FOREIGN KEY (tenant_id, payslip_line_id) REFERENCES ops.payslip_line (tenant_id, id)');
    PERFORM app.add_constraint_if_missing('loan.loan_repayment', 'loan_repayment_deposit_txn_fk',
        'FOREIGN KEY (tenant_id, deposit_transaction_id) REFERENCES dep.deposit_transaction (tenant_id, id)');
    PERFORM app.add_constraint_if_missing('loan.loan_repayment', 'loan_repayment_journal_fk',
        'FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id)');
    -- exactly one source of money (migrated history may carry none)
    PERFORM app.add_constraint_if_missing('loan.loan_repayment', 'loan_repayment_one_source',
        'CHECK (num_nonnulls(cash_receipt_id, payslip_line_id, deposit_transaction_id, journal_id) = 1
                OR (import_batch_id IS NOT NULL AND num_nonnulls(cash_receipt_id, payslip_line_id, deposit_transaction_id, journal_id) <= 1))');
    -- salary deduction is a repayment type of its own
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'loan.loan_repayment'::regclass
                     AND conname = 'loan_repayment_repayment_type_check'
                     AND pg_get_constraintdef(oid) LIKE '%SALARY_DEDUCTION%') THEN
        ALTER TABLE loan.loan_repayment DROP CONSTRAINT IF EXISTS loan_repayment_repayment_type_check;
        ALTER TABLE loan.loan_repayment ADD CONSTRAINT loan_repayment_repayment_type_check
            CHECK (repayment_type IN ('REGULAR','PARTIAL','LUMP_SUM','EARLY_SETTLEMENT','DEFAULT_SETTLEMENT',
                                      'RECOVERY','GUARANTOR','SET_OFF','SALARY_DEDUCTION','UNAPPLIED_TRANSFER'));
    END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS loan_repayment_payslip_line_uq
    ON loan.loan_repayment (tenant_id, payslip_line_id) WHERE payslip_line_id IS NOT NULL AND status = 'POSTED';

-- =============================================================================
-- 2. Matching totals, checked at commit (like journal balancing)
-- =============================================================================
-- 2a. Receipt / voucher: lines (when present) add up to the amount; the linked
--     journal moves exactly that amount through cash accounts.
CREATE OR REPLACE FUNCTION acct.trg_cash_document_totals()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_is_receipt boolean := TG_TABLE_NAME IN ('cash_receipt','cash_receipt_line');
    v_tenant uuid;
    v_id     uuid;
    v_amount numeric;
    v_status text;
    v_journal uuid;
    v_lines  numeric;
    v_nlines integer;
    v_cash   numeric;
    j        jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
BEGIN
    v_tenant := (j->>'tenant_id')::uuid;
    v_id := (j->>CASE TG_TABLE_NAME
              WHEN 'cash_receipt_line'    THEN 'cash_receipt_id'
              WHEN 'payment_voucher_line' THEN 'payment_voucher_id'
              ELSE 'id' END)::uuid;
    IF v_is_receipt THEN
        SELECT amount, status, journal_id INTO v_amount, v_status, v_journal
          FROM acct.cash_receipt WHERE tenant_id = v_tenant AND id = v_id;
        SELECT coalesce(sum(amount), 0), count(*) INTO v_lines, v_nlines
          FROM acct.cash_receipt_line WHERE tenant_id = v_tenant AND cash_receipt_id = v_id;
    ELSE
        SELECT amount, status, journal_id INTO v_amount, v_status, v_journal
          FROM acct.payment_voucher WHERE tenant_id = v_tenant AND id = v_id;
        SELECT coalesce(sum(amount), 0), count(*) INTO v_lines, v_nlines
          FROM acct.payment_voucher_line WHERE tenant_id = v_tenant AND payment_voucher_id = v_id;
    END IF;
    IF v_amount IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_nlines > 0 AND v_lines <> v_amount THEN
        PERFORM app.fail('DOCUMENT_TOTAL_MISMATCH',
            format('%s lines total %s but the amount is %s', CASE WHEN v_is_receipt THEN 'Receipt' ELSE 'Voucher' END, v_lines, v_amount));
    END IF;
    IF v_journal IS NOT NULL THEN
        SELECT coalesce(sum(CASE WHEN v_is_receipt THEN l.debit - l.credit ELSE l.credit - l.debit END), 0)
          INTO v_cash
          FROM acct.journal_line l
          JOIN acct.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id AND a.is_cash
         WHERE l.tenant_id = v_tenant AND l.journal_id = v_journal;
        IF v_cash <> v_amount THEN
            PERFORM app.fail('DOCUMENT_JOURNAL_MISMATCH',
                format('%s amount %s does not match the cash movement %s in its journal',
                       CASE WHEN v_is_receipt THEN 'Receipt' ELSE 'Voucher' END, v_amount, v_cash));
        END IF;
    END IF;
    RETURN NULL;
END
$$;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['acct.cash_receipt','acct.payment_voucher','acct.cash_receipt_line','acct.payment_voucher_line'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS document_totals ON %s', t);
        EXECUTE format('CREATE CONSTRAINT TRIGGER document_totals AFTER INSERT OR UPDATE OR DELETE ON %s
                        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION acct.trg_cash_document_totals()', t);
    END LOOP;
END $$;

-- 2b. Repayment allocations add up to the repayment (migrated history excepted).
CREATE OR REPLACE FUNCTION loan.trg_repayment_allocation_total()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    j        jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
    v_tenant uuid := (j->>'tenant_id')::uuid;
    v_id     uuid := (j->>CASE TG_TABLE_NAME WHEN 'loan_repayment' THEN 'id' ELSE 'loan_repayment_id' END)::uuid;
    r        record;
    v_alloc  numeric;
BEGIN
    SELECT amount, status, import_batch_id INTO r FROM loan.loan_repayment WHERE tenant_id = v_tenant AND id = v_id;
    IF NOT FOUND OR r.status <> 'POSTED' OR r.import_batch_id IS NOT NULL THEN
        RETURN NULL;
    END IF;
    SELECT coalesce(sum(amount), 0) INTO v_alloc FROM loan.loan_repayment_allocation
     WHERE tenant_id = v_tenant AND loan_repayment_id = v_id;
    IF v_alloc <> r.amount THEN
        PERFORM app.fail('ALLOCATION_MISMATCH', format('Repayment of %s is allocated %s', r.amount, v_alloc));
    END IF;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS repayment_allocation_total ON loan.loan_repayment;
CREATE CONSTRAINT TRIGGER repayment_allocation_total AFTER INSERT OR UPDATE ON loan.loan_repayment
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION loan.trg_repayment_allocation_total();
DROP TRIGGER IF EXISTS repayment_allocation_total ON loan.loan_repayment_allocation;
CREATE CONSTRAINT TRIGGER repayment_allocation_total AFTER INSERT OR UPDATE OR DELETE ON loan.loan_repayment_allocation
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION loan.trg_repayment_allocation_total();

-- 2c. Payslip: earnings = gross, deductions = deduction total, gross - deductions = net.
CREATE OR REPLACE FUNCTION ops.trg_payslip_totals()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    j        jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
    v_tenant uuid := (j->>'tenant_id')::uuid;
    v_id     uuid := (j->>CASE TG_TABLE_NAME WHEN 'payslip' THEN 'id' ELSE 'payslip_id' END)::uuid;
    p        record;
    v_earn   numeric;
    v_ded    numeric;
BEGIN
    SELECT gross_amount, deduction_amount, net_amount, status INTO p FROM ops.payslip WHERE tenant_id = v_tenant AND id = v_id;
    IF NOT FOUND OR p.status NOT IN ('FINAL','PAID') THEN
        RETURN NULL;
    END IF;
    SELECT coalesce(sum(amount) FILTER (WHERE line_type = 'EARNING'), 0),
           coalesce(sum(amount) FILTER (WHERE line_type = 'DEDUCTION'), 0)
      INTO v_earn, v_ded
      FROM ops.payslip_line WHERE tenant_id = v_tenant AND payslip_id = v_id;
    IF v_earn <> p.gross_amount OR v_ded <> p.deduction_amount OR p.gross_amount - p.deduction_amount <> p.net_amount THEN
        PERFORM app.fail('PAYSLIP_TOTAL_MISMATCH',
            format('Payslip lines (earnings %s, deductions %s) do not match gross %s, deductions %s, net %s',
                   v_earn, v_ded, p.gross_amount, p.deduction_amount, p.net_amount));
    END IF;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS payslip_totals ON ops.payslip;
CREATE CONSTRAINT TRIGGER payslip_totals AFTER INSERT OR UPDATE ON ops.payslip
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.trg_payslip_totals();
DROP TRIGGER IF EXISTS payslip_totals ON ops.payslip_line;
CREATE CONSTRAINT TRIGGER payslip_totals AFTER INSERT OR UPDATE OR DELETE ON ops.payslip_line
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.trg_payslip_totals();

-- =============================================================================
-- 3. Business rules on status changes
-- =============================================================================
-- 3a. Loan: no submission while a before-submission fee is unpaid; no approval
--     while any fee (other than one deducted from disbursement) is unpaid (6.2).
CREATE OR REPLACE FUNCTION loan.trg_loan_fee_gate()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.is_migrated OR NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;
    IF NEW.status IN ('SUBMITTED','UNDER_APPROVAL') AND EXISTS (
           SELECT 1 FROM loan.loan_application_fee f
            WHERE f.tenant_id = NEW.tenant_id AND f.loan_id = NEW.id
              AND f.collect_timing = 'BEFORE_SUBMISSION' AND f.status = 'PENDING') THEN
        PERFORM app.fail('FEE_UNPAID', 'The application fee must be paid or waived before the application is submitted');
    END IF;
    IF NEW.status = 'APPROVED' AND EXISTS (
           SELECT 1 FROM loan.loan_application_fee f
            WHERE f.tenant_id = NEW.tenant_id AND f.loan_id = NEW.id
              AND f.collect_timing <> 'DEDUCT_FROM_DISBURSEMENT' AND f.status = 'PENDING') THEN
        PERFORM app.fail('FEE_UNPAID', 'The application fee must be paid or waived before the loan is approved');
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS loan_fee_gate ON loan.loan;
CREATE TRIGGER loan_fee_gate BEFORE UPDATE OF status ON loan.loan
    FOR EACH ROW EXECUTE FUNCTION loan.trg_loan_fee_gate();

-- 3b. Member exit: nothing may remain open (5.4, 6.9).
CREATE OR REPLACE FUNCTION mbr.trg_member_exit_gate()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE v_open text[];
BEGIN
    IF NEW.status = 'EXITED' AND OLD.status <> 'EXITED' THEN
        v_open := mbr.open_obligations(NEW.id, NEW.tenant_id);
        IF array_length(v_open, 1) > 0 THEN
            PERFORM app.fail('MEMBER_HAS_OPEN_ITEMS',
                'The member cannot exit while these are open: ' || array_to_string(v_open, ', '));
        END IF;
    END IF;
    RETURN NEW;
END
$$;

-- 3c. Hall booking is confirmed only when rent and security deposit are paid in full (18.4).
CREATE OR REPLACE FUNCTION ops.trg_hall_confirm_gate()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE v_rent numeric; v_dep numeric;
BEGIN
    IF NEW.status = 'CONFIRMED' AND (TG_OP = 'INSERT' OR OLD.status <> 'CONFIRMED') AND NEW.import_batch_id IS NULL THEN
        SELECT coalesce(sum(p.amount) FILTER (WHERE p.component = 'RENT'), 0),
               coalesce(sum(p.amount) FILTER (WHERE p.component = 'SECURITY_DEPOSIT'), 0)
          INTO v_rent, v_dep
          FROM ops.hall_booking_payment p
          JOIN acct.cash_receipt r ON r.tenant_id = p.tenant_id AND r.id = p.cash_receipt_id AND r.status = 'ACTIVE'
         WHERE p.tenant_id = NEW.tenant_id AND p.hall_booking_id = NEW.id;
        IF v_rent < coalesce(NEW.rent_amount, 0) OR v_dep < coalesce(NEW.deposit_amount, 0) THEN
            PERFORM app.fail('HALL_NOT_PAID',
                format('A booking is confirmed only when rent (%s of %s) and security deposit (%s of %s) are paid in full',
                       v_rent, coalesce(NEW.rent_amount, 0), v_dep, coalesce(NEW.deposit_amount, 0)));
        END IF;
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS hall_confirm_gate ON ops.hall_booking;
CREATE TRIGGER hall_confirm_gate BEFORE INSERT OR UPDATE OF status ON ops.hall_booking
    FOR EACH ROW EXECUTE FUNCTION ops.trg_hall_confirm_gate();

-- 3d. Disbursement: only an approved (or already active, for later tranches) loan,
--     within the approval window for the first tranche, to an Active member, and
--     never more than the approved amount in total (6.6).
CREATE OR REPLACE FUNCTION loan.trg_disbursement_gate()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    l        record;
    v_member text;
    v_total  numeric;
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;
    SELECT * INTO l FROM loan.loan WHERE tenant_id = NEW.tenant_id AND id = NEW.loan_id;
    IF NOT l.is_migrated AND (TG_OP = 'INSERT' OR OLD.status = 'CANCELLED') THEN
        IF l.status NOT IN ('APPROVED','ACTIVE','OVERDUE','RESTRUCTURED') THEN
            PERFORM app.fail('LOAN_NOT_APPROVED', format('Loan status %s cannot be disbursed', l.status));
        END IF;
        IF l.status = 'APPROVED' AND l.approval_expires_on IS NOT NULL AND NEW.value_date > l.approval_expires_on THEN
            PERFORM app.fail('APPROVAL_EXPIRED', format('The approval expired on %s; the loan must be re-approved', l.approval_expires_on));
        END IF;
        SELECT status INTO v_member FROM mbr.member WHERE tenant_id = NEW.tenant_id AND id = l.member_id;
        IF v_member <> 'ACTIVE' THEN
            PERFORM app.fail('MEMBER_NOT_ACTIVE', format('Loans are disbursed only to Active members (member is %s)', v_member));
        END IF;
    END IF;
    SELECT coalesce(sum(gross_amount), 0) INTO v_total FROM loan.loan_disbursement
     WHERE tenant_id = NEW.tenant_id AND loan_id = NEW.loan_id AND status <> 'CANCELLED' AND id <> NEW.id;
    IF v_total + NEW.gross_amount > coalesce(l.approved_amount, 0) THEN
        PERFORM app.fail('OVER_DISBURSEMENT',
            format('Disbursements (%s) would exceed the approved amount %s', v_total + NEW.gross_amount, l.approved_amount));
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS disbursement_gate ON loan.loan_disbursement;
CREATE TRIGGER disbursement_gate BEFORE INSERT OR UPDATE ON loan.loan_disbursement
    FOR EACH ROW EXECUTE FUNCTION loan.trg_disbursement_gate();

-- =============================================================================
-- 4. Period close, reopen and year-end close (Sections 21.5, 22)
-- =============================================================================
-- Year-end closing journals do not move cash, so they may be dated on a closed
-- cash day; acct.close_financial_year sets app.year_end_close for that.
CREATE OR REPLACE FUNCTION acct.assert_open_date(p_tenant_id uuid, p_date date)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_limit    integer;
    v_year_end boolean := coalesce(app.setting('app.year_end_close'), '') = 'on';
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
    IF v_year_end THEN
        RETURN;
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

-- Checks before a period can close. Returns the problems found (empty = ready).
CREATE OR REPLACE FUNCTION acct.period_close_problems(p_period_id uuid)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    p      acct.financial_period;
    v_out  text[] := '{}';
    v_n    integer;
BEGIN
    SELECT * INTO p FROM acct.financial_period WHERE id = p_period_id;
    IF EXISTS (SELECT 1 FROM acct.financial_period e
                WHERE e.tenant_id = p.tenant_id AND e.financial_year_id = p.financial_year_id
                  AND e.period_no < p.period_no AND e.status = 'OPEN') THEN
        v_out := v_out || 'an earlier period of the year is still open'::text;
    END IF;
    SELECT count(*) INTO v_n FROM acct.journal j
     WHERE j.tenant_id = p.tenant_id AND j.value_date BETWEEN p.start_date AND p.end_date
       AND j.status IN ('DRAFT','PENDING_APPROVAL');
    IF v_n > 0 THEN
        v_out := v_out || format('%s draft or pending journal(s)', v_n);
    END IF;
    SELECT count(*) INTO v_n FROM acct.cash_day d
     WHERE d.tenant_id = p.tenant_id AND d.business_date BETWEEN p.start_date AND p.end_date AND d.status <> 'CLOSED';
    IF v_n > 0 THEN
        v_out := v_out || format('%s cash day(s) not closed', v_n);
    END IF;
    SELECT count(DISTINCT x.d) INTO v_n
      FROM (SELECT r.value_date AS d FROM acct.cash_receipt r
             WHERE r.tenant_id = p.tenant_id AND r.value_date BETWEEN p.start_date AND p.end_date
            UNION
            SELECT v.value_date FROM acct.payment_voucher v
             WHERE v.tenant_id = p.tenant_id AND v.value_date BETWEEN p.start_date AND p.end_date) x
     WHERE NOT EXISTS (SELECT 1 FROM acct.cash_day d WHERE d.tenant_id = p.tenant_id AND d.business_date = x.d AND d.status = 'CLOSED');
    IF v_n > 0 THEN
        v_out := v_out || format('%s day(s) with cash transactions have no closed cash day', v_n);
    END IF;
    SELECT count(*) INTO v_n FROM acct.payment_voucher v
     WHERE v.tenant_id = p.tenant_id AND v.value_date BETWEEN p.start_date AND p.end_date AND v.status = 'PREPARED';
    IF v_n > 0 THEN
        v_out := v_out || format('%s payment voucher(s) prepared but not paid or cancelled', v_n);
    END IF;
    RETURN v_out;
END
$$;

-- Status changes on periods are checked here, whoever makes them.
CREATE OR REPLACE FUNCTION acct.trg_financial_period_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_problems text[];
    v_year_status text;
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;
    IF NEW.status = 'CLOSED' THEN
        v_problems := acct.period_close_problems(NEW.id);
        IF array_length(v_problems, 1) > 0 THEN
            PERFORM app.fail('PERIOD_NOT_READY', format('Period %s cannot close: %s', NEW.name, array_to_string(v_problems, '; ')));
        END IF;
        NEW.closed_at := coalesce(NEW.closed_at, now());
        NEW.closed_by := coalesce(NEW.closed_by, app.user_id());
    ELSE  -- reopening
        SELECT status INTO v_year_status FROM acct.financial_year WHERE tenant_id = NEW.tenant_id AND id = NEW.financial_year_id;
        IF v_year_status = 'CLOSED' THEN
            PERFORM app.fail('YEAR_CLOSED', 'Periods of a closed financial year cannot be reopened');
        END IF;
        IF NEW.last_reopen_approval_request_id IS NULL
           OR NEW.last_reopen_approval_request_id IS NOT DISTINCT FROM OLD.last_reopen_approval_request_id
           OR NOT EXISTS (SELECT 1 FROM wf.approval_request a
                           WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.last_reopen_approval_request_id AND a.status = 'APPROVED')
           OR coalesce(NEW.last_reopen_reason, '') = '' THEN
            PERFORM app.fail('REOPEN_NEEDS_APPROVAL', 'Reopening a period needs a new approved request and a reason');
        END IF;
        NEW.reopened_count := OLD.reopened_count + 1;
        NEW.closed_at := NULL;
        NEW.closed_by := NULL;
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS financial_period_guard ON acct.financial_period;
CREATE TRIGGER financial_period_guard BEFORE UPDATE OF status ON acct.financial_period
    FOR EACH ROW EXECUTE FUNCTION acct.trg_financial_period_guard();

CREATE OR REPLACE FUNCTION acct.close_period(p_period_id uuid)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE acct.financial_period SET status = 'CLOSED'
     WHERE tenant_id = app.tenant_id() AND id = p_period_id AND status = 'OPEN';
    IF NOT FOUND THEN
        PERFORM app.fail('NOT_FOUND', 'Open period not found');
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION acct.reopen_period(p_period_id uuid, p_approval_request_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM app.set_audit_reason(p_reason, 'APPROVAL_REQUEST', p_approval_request_id::text);
    UPDATE acct.financial_period
       SET status = 'OPEN', last_reopen_approval_request_id = p_approval_request_id, last_reopen_reason = p_reason
     WHERE tenant_id = app.tenant_id() AND id = p_period_id AND status = 'CLOSED';
    IF NOT FOUND THEN
        PERFORM app.fail('NOT_FOUND', 'Closed period not found');
    END IF;
END
$$;

-- Year-end: every period but the last must be closed. Posts the YEAR_END journal
-- that moves each income and expense balance (per fund) to the fund's own account
-- (General Community Fund 3100 for unrestricted money), closes the last period and
-- the year, and opens the next year. Returns the closing journal id.
CREATE OR REPLACE FUNCTION acct.close_financial_year(p_year_id uuid, p_reason text DEFAULT 'Year-end close')
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    y        acct.financial_year;
    v_last   acct.financial_period;
    v_tenant uuid := app.tenant_id();
    v_gf     uuid;
    v_j      uuid;
    v_line   integer := 0;
    r        record;
BEGIN
    SELECT * INTO y FROM acct.financial_year WHERE tenant_id = v_tenant AND id = p_year_id FOR UPDATE;
    IF NOT FOUND OR y.status = 'CLOSED' THEN
        PERFORM app.fail('NOT_FOUND', 'Open financial year not found');
    END IF;
    SELECT * INTO v_last FROM acct.financial_period
     WHERE tenant_id = v_tenant AND financial_year_id = y.id ORDER BY period_no DESC LIMIT 1;
    IF EXISTS (SELECT 1 FROM acct.financial_period WHERE tenant_id = v_tenant AND financial_year_id = y.id
                AND id <> v_last.id AND status = 'OPEN') THEN
        PERFORM app.fail('YEAR_NOT_READY', 'Close every period except the last before closing the year');
    END IF;
    IF array_length(acct.period_close_problems(v_last.id), 1) > 0 THEN
        PERFORM app.fail('YEAR_NOT_READY', 'Last period: ' || array_to_string(acct.period_close_problems(v_last.id), '; '));
    END IF;
    IF v_last.status <> 'OPEN' THEN
        PERFORM app.fail('YEAR_NOT_READY', 'The last period must still be open to post the year-end journal');
    END IF;
    SELECT account_id INTO v_gf FROM acct.account_mapping
     WHERE tenant_id = v_tenant AND mapping_key = 'GENERAL_FUND' ORDER BY effective_from DESC LIMIT 1;

    PERFORM app.set_audit_reason(p_reason, 'FINANCIAL_YEAR', y.id::text);
    PERFORM set_config('app.year_end_close', 'on', true);
    SET CONSTRAINTS ALL DEFERRED;   -- lines are added after the journal row; balance is checked below

    IF EXISTS (SELECT l.account_id, l.fund_id, sum(l.credit - l.debit) AS bal
          FROM acct.journal_line l
          JOIN acct.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
          JOIN acct.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
         WHERE l.tenant_id = v_tenant AND j.status IN ('POSTED','REVERSED') AND j.voucher_type <> 'YEAR_END'
           AND j.value_date BETWEEN y.start_date AND y.end_date AND a.account_type IN ('INCOME','EXPENSE')
         GROUP BY l.account_id, l.fund_id
        HAVING sum(l.credit - l.debit) <> 0) THEN
    INSERT INTO acct.journal (tenant_id, voucher_type, value_date, status, narration, source_module,
                              source_entity_type, source_entity_id, idempotency_key)
    VALUES (v_tenant, 'YEAR_END', y.end_date, 'POSTED', 'Year-end close ' || y.code, 'FIN_PERIOD',
            'acct.financial_year', y.id, 'YEAR_END-' || y.id)
    RETURNING id INTO v_j;

    -- reverse each income / expense balance, keeping its fund
    FOR r IN
        SELECT l.account_id, l.fund_id, sum(l.credit - l.debit) AS bal
          FROM acct.journal_line l
          JOIN acct.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
          JOIN acct.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
         WHERE l.tenant_id = v_tenant AND j.status IN ('POSTED','REVERSED') AND j.voucher_type <> 'YEAR_END'
           AND j.value_date BETWEEN y.start_date AND y.end_date AND a.account_type IN ('INCOME','EXPENSE')
         GROUP BY l.account_id, l.fund_id
        HAVING sum(l.credit - l.debit) <> 0
    LOOP
        v_line := v_line + 1;
        INSERT INTO acct.journal_line (tenant_id, journal_id, line_no, account_id, fund_id, debit, credit, narration)
        VALUES (v_tenant, v_j, v_line, r.account_id, r.fund_id,
                CASE WHEN r.bal > 0 THEN r.bal ELSE 0 END, CASE WHEN r.bal < 0 THEN -r.bal ELSE 0 END, 'Year-end close');
    END LOOP;

    -- surplus or deficit of each fund goes to that fund's account
    FOR r IN
        SELECT l.fund_id, sum(l.debit - l.credit) AS surplus,
               coalesce(f.account_id, v_gf) AS target
          FROM acct.journal_line l
          LEFT JOIN acct.fund f ON f.tenant_id = l.tenant_id AND f.id = l.fund_id
         WHERE l.tenant_id = v_tenant AND l.journal_id = v_j
         GROUP BY l.fund_id, f.account_id
        HAVING sum(l.debit - l.credit) <> 0
    LOOP
        IF r.target IS NULL THEN
            PERFORM app.fail('NO_GENERAL_FUND', 'No General Fund account mapping (GENERAL_FUND) for the year-end transfer');
        END IF;
        v_line := v_line + 1;
        INSERT INTO acct.journal_line (tenant_id, journal_id, line_no, account_id, fund_id, debit, credit, narration)
        VALUES (v_tenant, v_j, v_line, r.target, r.fund_id,
                CASE WHEN r.surplus < 0 THEN -r.surplus ELSE 0 END, CASE WHEN r.surplus > 0 THEN r.surplus ELSE 0 END,
                CASE WHEN r.surplus > 0 THEN 'Surplus for the year' ELSE 'Deficit for the year' END);
    END LOOP;

    END IF;  -- no income or expenditure in the year: no closing journal

    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM set_config('app.year_end_close', '', true);
    UPDATE acct.financial_period SET status = 'CLOSED' WHERE tenant_id = v_tenant AND id = v_last.id;
    UPDATE acct.financial_year
       SET status = 'CLOSED', closed_by = app.user_id(), closed_at = now(), closing_journal_id = v_j
     WHERE tenant_id = v_tenant AND id = y.id;
    PERFORM acct.create_financial_year(v_tenant, y.end_date + 1);
    RETURN v_j;
END
$$;

-- =============================================================================
-- 5. Member unapplied receipts (account 2120)
-- =============================================================================
CREATE TABLE IF NOT EXISTS acct.member_unapplied (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id        uuid NOT NULL,
    movement_type    text NOT NULL CHECK (movement_type IN ('RECEIVED','APPLIED','REFUNDED','REVERSED')),
    value_date       date NOT NULL DEFAULT app.working_date(),
    amount           numeric(18,2) NOT NULL CHECK (amount > 0),
    cash_receipt_id  uuid,
    payment_voucher_id uuid,
    loan_repayment_id uuid,
    applied_to_type  text,              -- loan.loan, ops.contribution_due ...
    applied_to_id    uuid,
    journal_id       uuid,
    reason           text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_repayment_id) REFERENCES loan.loan_repayment (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    CHECK (movement_type <> 'RECEIVED' OR cash_receipt_id IS NOT NULL),
    CHECK (movement_type <> 'REFUNDED' OR payment_voucher_id IS NOT NULL),
    CHECK (movement_type <> 'APPLIED'  OR applied_to_id IS NOT NULL),
    CHECK (movement_type <> 'REVERSED' OR reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS member_unapplied_member_idx ON acct.member_unapplied (tenant_id, member_id);

CREATE OR REPLACE VIEW acct.v_member_unapplied_balance AS
SELECT tenant_id, member_id,
       sum(CASE WHEN movement_type = 'RECEIVED' THEN amount ELSE -amount END) AS balance,
       max(value_date) AS last_movement_on
  FROM acct.member_unapplied
 GROUP BY tenant_id, member_id;

-- Movements are never edited or deleted (correct with a REVERSED movement), and a
-- member's unapplied balance can never go negative.
CREATE OR REPLACE FUNCTION acct.trg_member_unapplied_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM app.fail('UNAPPLIED_IMMUTABLE', 'Unapplied money movements are never changed; record a reversal');
    END IF;
    IF NEW.movement_type <> 'RECEIVED'
       AND coalesce((SELECT b.balance FROM acct.v_member_unapplied_balance b
                      WHERE b.tenant_id = NEW.tenant_id AND b.member_id = NEW.member_id), 0) < NEW.amount THEN
        PERFORM app.fail('UNAPPLIED_INSUFFICIENT', 'The member does not have that much unapplied money');
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS member_unapplied_guard ON acct.member_unapplied;
CREATE TRIGGER member_unapplied_guard BEFORE INSERT OR UPDATE OR DELETE ON acct.member_unapplied
    FOR EACH ROW EXECUTE FUNCTION acct.trg_member_unapplied_guard();

-- open obligations (used by the exit gate, 3b) read the unapplied balance, so they are defined here
CREATE OR REPLACE FUNCTION mbr.open_obligations(p_member_id uuid, p_tenant_id uuid DEFAULT NULL)
RETURNS text[] LANGUAGE sql STABLE AS
$$
    SELECT array_remove(ARRAY[
        CASE WHEN EXISTS (SELECT 1 FROM loan.loan l WHERE l.tenant_id = t.id AND l.member_id = p_member_id
                            AND l.status IN ('SUBMITTED','UNDER_APPROVAL','APPROVED','ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED'))
             THEN 'open loan or pending application' END,
        CASE WHEN EXISTS (SELECT 1 FROM loan.loan_guarantor g JOIN loan.loan l ON l.tenant_id = g.tenant_id AND l.id = g.loan_id
                           WHERE g.tenant_id = t.id AND g.guarantor_member_id = p_member_id AND g.status IN ('ACTIVE','INVOKED')
                             AND l.status IN ('APPROVED','ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED'))
             THEN 'open guarantee' END,
        CASE WHEN EXISTS (SELECT 1 FROM dep.deposit_account d WHERE d.tenant_id = t.id AND d.member_id = p_member_id
                            AND d.status IN ('APPLIED','ACTIVE','MATURED','FROZEN'))
             THEN 'open deposit account' END,
        CASE WHEN EXISTS (SELECT 1 FROM chit.chit_ticket c JOIN chit.chit_group g ON g.tenant_id = c.tenant_id AND g.id = c.chit_group_id
                           WHERE c.tenant_id = t.id AND c.member_id = p_member_id
                             AND c.status IN ('NON_PRIZED','PRIZED','DEFAULTED','FROZEN')
                             AND g.status IN ('DRAFT','REGISTERED','ACTIVE'))
             THEN 'open chit ticket' END,
        CASE WHEN EXISTS (SELECT 1 FROM ops.contribution_due cd WHERE cd.tenant_id = t.id AND cd.member_id = p_member_id
                            AND cd.status IN ('DUE','PARTLY_PAID') AND cd.due_date <= app.tenant_today(t.id))
             THEN 'unpaid contribution dues' END,
        CASE WHEN coalesce((SELECT b.balance FROM acct.v_member_unapplied_balance b
                             WHERE b.tenant_id = t.id AND b.member_id = p_member_id), 0) <> 0
             THEN 'unapplied money held for the member' END
    ], NULL)
    FROM (SELECT coalesce(p_tenant_id, app.tenant_id()) AS id) t
$$;

-- the exit gate (3b) reads the unapplied balance, so its trigger is created here
DROP TRIGGER IF EXISTS member_exit_gate ON mbr.member;
CREATE TRIGGER member_exit_gate BEFORE UPDATE OF status ON mbr.member
    FOR EACH ROW EXECUTE FUNCTION mbr.trg_member_exit_gate();

-- =============================================================================
-- 8. Loan balances, loan control reconciliation, member financial profile
-- =============================================================================
CREATE OR REPLACE VIEW loan.v_loan_balance AS
WITH d AS (
    SELECT tenant_id, loan_id, sum(gross_amount) AS disbursed
      FROM loan.loan_disbursement WHERE status = 'PAID' GROUP BY 1, 2),
rp AS (
    SELECT tenant_id, loan_id, sum(principal_amount) AS principal_repaid, sum(interest_amount) AS interest_repaid,
           sum(late_fee_amount + penalty_amount + charge_amount) AS charges_repaid, max(value_date) AS last_payment_on
      FROM loan.loan_repayment WHERE status = 'POSTED' GROUP BY 1, 2),
wo AS (
    SELECT tenant_id, loan_id, sum(principal_amount) AS written_off
      FROM loan.loan_write_off WHERE status IN ('APPROVED','POSTED') GROUP BY 1, 2),
i AS (
    SELECT i.tenant_id, i.loan_id,
           sum(i.interest_due) FILTER (WHERE i.due_date <= app.working_date())                          AS interest_due_to_date,
           sum(i.interest_paid)                                                                       AS interest_paid_sched,
           sum(i.principal_due - i.principal_paid) FILTER (WHERE i.due_date < app.working_date() AND i.status IN ('DUE','PARTLY_PAID')) AS overdue_principal,
           sum(i.interest_due - i.interest_paid)  FILTER (WHERE i.due_date < app.working_date() AND i.status IN ('DUE','PARTLY_PAID')) AS overdue_interest,
           sum(i.interest_due - i.interest_paid)  FILTER (WHERE i.status IN ('DUE','PARTLY_PAID'))         AS interest_outstanding_sched,
           min(i.due_date) FILTER (WHERE i.status IN ('DUE','PARTLY_PAID'))                           AS oldest_unpaid_due_date,
           min(i.due_date) FILTER (WHERE i.status IN ('DUE','PARTLY_PAID') AND i.due_date >= app.working_date()) AS next_due_date
      FROM loan.loan_instalment i
      JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
     GROUP BY 1, 2),
c AS (
    SELECT tenant_id, loan_id, sum(amount - paid_amount - waived_amount) AS charges_open
      FROM loan.loan_charge WHERE status = 'OPEN' GROUP BY 1, 2)
SELECT l.tenant_id, l.id AS loan_id, l.loan_no, l.member_id, l.loan_type_id, l.status, l.is_restructured, l.is_migrated,
       coalesce(d.disbursed, 0)                                                    AS principal_disbursed,
       coalesce(rp.principal_repaid, 0)                                            AS principal_repaid,
       coalesce(wo.written_off, 0)                                                 AS principal_written_off,
       CASE WHEN l.is_migrated THEN l.outstanding_principal
            ELSE coalesce(d.disbursed, 0) - coalesce(rp.principal_repaid, 0) - coalesce(wo.written_off, 0) END AS outstanding_principal,
       l.outstanding_principal                                                     AS outstanding_principal_stored,
       coalesce(i.interest_due_to_date, 0)                                         AS interest_due_to_date,
       coalesce(rp.interest_repaid, 0)                                             AS interest_collected,
       coalesce(i.interest_outstanding_sched, 0)                                   AS interest_outstanding_scheduled,
       coalesce(i.overdue_principal, 0)                                            AS overdue_principal,
       coalesce(i.overdue_interest, 0)                                             AS overdue_interest,
       coalesce(c.charges_open, 0)                                                 AS charges_open,
       i.oldest_unpaid_due_date,
       i.next_due_date,
       CASE WHEN i.oldest_unpaid_due_date < app.working_date()
            THEN app.working_date() - i.oldest_unpaid_due_date ELSE 0 END          AS days_overdue,
       rp.last_payment_on
  FROM loan.loan l
  LEFT JOIN d  ON d.tenant_id = l.tenant_id AND d.loan_id = l.id
  LEFT JOIN rp ON rp.tenant_id = l.tenant_id AND rp.loan_id = l.id
  LEFT JOIN wo ON wo.tenant_id = l.tenant_id AND wo.loan_id = l.id
  LEFT JOIN i  ON i.tenant_id = l.tenant_id AND i.loan_id = l.id
  LEFT JOIN c  ON c.tenant_id = l.tenant_id AND c.loan_id = l.id
 WHERE NOT l.is_deleted;

-- Loan Principal Receivable in the ledger vs the loan sub-ledger, per loan type.
CREATE OR REPLACE VIEW acct.v_loan_control_reconciliation AS
SELECT lt.tenant_id, lt.id AS loan_type_id, lt.code AS loan_type, a.code AS account_code,
       coalesce((SELECT sum(jl.debit - jl.credit) FROM acct.journal_line jl
                   JOIN acct.journal j ON j.tenant_id = jl.tenant_id AND j.id = jl.journal_id AND j.status IN ('POSTED','REVERSED')
                  WHERE jl.tenant_id = lt.tenant_id AND jl.account_id = lt.principal_account_id), 0) AS gl_balance,
       coalesce((SELECT sum(b.outstanding_principal) FROM loan.v_loan_balance b
                  WHERE b.tenant_id = lt.tenant_id AND b.loan_type_id = lt.id
                    AND b.status NOT IN ('DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED','APPROVED',
                                         'REJECTED','WITHDRAWN','CANCELLED')), 0) AS subledger_balance
  FROM loan.loan_type lt
  LEFT JOIN acct.account a ON a.tenant_id = lt.tenant_id AND a.id = lt.principal_account_id;

CREATE OR REPLACE VIEW mbr.v_member_financial_profile AS
SELECT m.tenant_id, m.id AS member_id, m.member_no, m.full_name, m.status, m.loan_eligibility, m.cooling_off_until,
       (SELECT count(*) FROM loan.loan l WHERE l.tenant_id = m.tenant_id AND l.member_id = m.id AND NOT l.is_deleted) AS loan_applications,
       (SELECT count(*) FROM loan.loan l WHERE l.tenant_id = m.tenant_id AND l.member_id = m.id
           AND l.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED'))                                AS active_loans,
       (SELECT coalesce(sum(b.outstanding_principal), 0) FROM loan.v_loan_balance b
         WHERE b.tenant_id = m.tenant_id AND b.member_id = m.id AND b.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')) AS outstanding_principal,
       (SELECT coalesce(sum(b.overdue_principal + b.overdue_interest), 0) FROM loan.v_loan_balance b
         WHERE b.tenant_id = m.tenant_id AND b.member_id = m.id)                                           AS overdue_amount,
       (SELECT count(*) FROM loan.loan_default d JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.loan_id
         WHERE d.tenant_id = m.tenant_id AND l.member_id = m.id)                                           AS defaults,
       (SELECT coalesce(sum(f.fee_amount), 0) FROM loan.loan_application_fee f JOIN loan.loan l ON l.tenant_id = f.tenant_id AND l.id = f.loan_id
         WHERE f.tenant_id = m.tenant_id AND l.member_id = m.id AND f.status IN ('PAID','DEDUCTED'))        AS application_fees_paid,
       (SELECT coalesce(sum(r.amount), 0) FROM loan.loan_repayment r JOIN loan.loan l ON l.tenant_id = r.tenant_id AND l.id = r.loan_id
         WHERE r.tenant_id = m.tenant_id AND l.member_id = m.id AND r.status = 'POSTED')                   AS total_repaid,
       (SELECT coalesce(sum(a.amount_approved), 0) FROM ops.assistance_application a
         WHERE a.tenant_id = m.tenant_id AND a.member_id = m.id AND a.status = 'PAID')                     AS assistance_received,
       (SELECT count(*) FROM ops.hall_booking h WHERE h.tenant_id = m.tenant_id AND h.member_id = m.id)    AS hall_bookings,
       (SELECT coalesce(sum(d.balance), 0) FROM dep.deposit_account d
         WHERE d.tenant_id = m.tenant_id AND d.member_id = m.id AND d.status IN ('ACTIVE','MATURED','FROZEN')) AS deposit_balance,
       (SELECT count(*) FROM chit.chit_ticket c WHERE c.tenant_id = m.tenant_id AND c.member_id = m.id
           AND c.status IN ('NON_PRIZED','PRIZED','DEFAULTED','FROZEN'))                                   AS open_chit_tickets,
       (SELECT coalesce(sum(p.amount), 0) FROM ops.contribution_payment p
          JOIN ops.contribution_due cd ON cd.tenant_id = p.tenant_id AND cd.id = p.contribution_due_id
         WHERE p.tenant_id = m.tenant_id AND cd.member_id = m.id AND p.status = 'POSTED')              AS contributions_paid,
       (SELECT coalesce(sum(cd.amount - cd.paid_amount - cd.waived_amount), 0) FROM ops.contribution_due cd
         WHERE cd.tenant_id = m.tenant_id AND cd.member_id = m.id AND cd.status IN ('DUE','PARTLY_PAID')
           AND cd.due_date < app.working_date())                                                          AS contributions_overdue,
       (SELECT coalesce(sum(dn.amount), 0) FROM ops.donation dn JOIN ops.donor o ON o.tenant_id = dn.tenant_id AND o.id = dn.donor_id
         WHERE dn.tenant_id = m.tenant_id AND o.member_id = m.id AND dn.status = 'RECEIVED')            AS donations,
       coalesce((SELECT b.balance FROM acct.v_member_unapplied_balance b
                  WHERE b.tenant_id = m.tenant_id AND b.member_id = m.id), 0)                             AS unapplied_balance
  FROM mbr.member m
 WHERE NOT m.is_deleted;

-- =============================================================================
-- 9. Deposits: death claims, premature closure requests, nominee shares
-- =============================================================================
CREATE TABLE IF NOT EXISTS dep.deposit_claim (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    claim_no          text,
    deposit_account_id uuid NOT NULL,
    death_record_id   uuid,
    claimant_type     text NOT NULL CHECK (claimant_type IN ('NOMINEE','LEGAL_SUCCESSOR')),
    nominee_id        uuid,
    legal_successor_id uuid,
    share_percent     numeric(5,2) NOT NULL DEFAULT 100 CHECK (share_percent > 0 AND share_percent <= 100),
    balance_at_death  numeric(18,2),
    interest_to_death numeric(18,2) NOT NULL DEFAULT 0,
    claim_amount      numeric(18,2) NOT NULL CHECK (claim_amount > 0),
    calculation       jsonb,
    status            text NOT NULL DEFAULT 'SUBMITTED'
                      CHECK (status IN ('SUBMITTED','VERIFIED','APPROVED','PAID','REJECTED','CANCELLED')),
    verified_by       uuid,
    verified_at       timestamptz,
    rejection_reason  text,
    approval_request_id uuid,
    payment_voucher_id uuid,
    deposit_transaction_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, death_record_id) REFERENCES mbr.death_record (tenant_id, id),
    FOREIGN KEY (tenant_id, nominee_id) REFERENCES mbr.nominee (tenant_id, id),
    FOREIGN KEY (tenant_id, legal_successor_id) REFERENCES mbr.legal_successor (tenant_id, id),
    FOREIGN KEY (tenant_id, verified_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_transaction_id) REFERENCES dep.deposit_transaction (tenant_id, id),
    CHECK ((claimant_type = 'NOMINEE' AND nominee_id IS NOT NULL) OR (claimant_type = 'LEGAL_SUCCESSOR' AND legal_successor_id IS NOT NULL)),
    CHECK (status NOT IN ('VERIFIED','APPROVED','PAID') OR verified_by IS NOT NULL),
    CHECK (status <> 'PAID' OR payment_voucher_id IS NOT NULL),
    CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS dep.deposit_closure_request (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    request_no        text,
    deposit_account_id uuid NOT NULL,
    request_date      date NOT NULL DEFAULT app.working_date(),
    reason            text NOT NULL,
    within_lock_in    boolean NOT NULL DEFAULT false,
    contract_rate     numeric(9,4) NOT NULL,
    applied_rate      numeric(9,4) NOT NULL,
    balance           numeric(18,2) NOT NULL,
    interest_payable  numeric(18,2) NOT NULL DEFAULT 0,
    interest_forgone  numeric(18,2) NOT NULL DEFAULT 0,        -- the penalty: lower interest, no separate entry
    lien_amount       numeric(18,2) NOT NULL DEFAULT 0,
    payout_amount     numeric(18,2) NOT NULL CHECK (payout_amount >= 0),
    calculation       jsonb,
    shown_to_member_at timestamptz,
    status            text NOT NULL DEFAULT 'REQUESTED'
                      CHECK (status IN ('REQUESTED','APPROVED','PAID','REJECTED','WITHDRAWN')),
    approval_request_id uuid,
    payment_voucher_id uuid,
    deposit_transaction_id uuid,
    rule_set_version_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_transaction_id) REFERENCES dep.deposit_transaction (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK (applied_rate <= contract_rate),
    CHECK (status <> 'PAID' OR payment_voucher_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS deposit_closure_one_open
    ON dep.deposit_closure_request (tenant_id, deposit_account_id) WHERE status IN ('REQUESTED','APPROVED');

-- Nominee shares of a deposit account add up to 100% (9.5).
CREATE OR REPLACE FUNCTION dep.trg_deposit_nominee_shares()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    j        jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
    v_tenant uuid := (j->>'tenant_id')::uuid;
    v_acct   uuid := (j->>'deposit_account_id')::uuid;
    v_sum    numeric;
BEGIN
    SELECT sum(share_percent) INTO v_sum FROM dep.deposit_nominee WHERE tenant_id = v_tenant AND deposit_account_id = v_acct;
    IF v_sum IS NOT NULL AND v_sum <> 100 THEN
        PERFORM app.fail('NOMINEE_SHARES', format('Nominee shares of a deposit account must total 100%% (now %s%%)', v_sum));
    END IF;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS deposit_nominee_shares ON dep.deposit_nominee;
CREATE CONSTRAINT TRIGGER deposit_nominee_shares AFTER INSERT OR UPDATE OR DELETE ON dep.deposit_nominee
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION dep.trg_deposit_nominee_shares();

-- =============================================================================
-- 10. Chit funds: dividend payouts, refunds, foreman security, reconciliation
-- =============================================================================
ALTER TABLE chit.chit_group
    ADD COLUMN IF NOT EXISTS foreman_security_amount      numeric(18,2),
    ADD COLUMN IF NOT EXISTS foreman_security_details     text,
    ADD COLUMN IF NOT EXISTS foreman_security_document_id uuid,
    ADD COLUMN IF NOT EXISTS agreement_document_id        uuid;
DO $$ BEGIN
    PERFORM app.add_constraint_if_missing('chit.chit_group', 'chit_group_security_doc_fk',
        'FOREIGN KEY (tenant_id, foreman_security_document_id) REFERENCES core.document (tenant_id, id)');
    PERFORM app.add_constraint_if_missing('chit.chit_group', 'chit_group_agreement_doc_fk',
        'FOREIGN KEY (tenant_id, agreement_document_id) REFERENCES core.document (tenant_id, id)');
END $$;

CREATE TABLE IF NOT EXISTS chit.chit_dividend_payout (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_dividend_id  uuid NOT NULL,
    chit_ticket_id    uuid NOT NULL,
    amount            numeric(18,2) NOT NULL CHECK (amount >= 0),
    treatment         text NOT NULL CHECK (treatment IN ('ADJUSTED','PAID')),
    chit_instalment_id uuid,                     -- next month's instalment it reduced
    payment_voucher_id uuid,                     -- when paid out in cash
    status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','DONE','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, chit_dividend_id, chit_ticket_id),
    FOREIGN KEY (tenant_id, chit_dividend_id) REFERENCES chit.chit_dividend (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_instalment_id) REFERENCES chit.chit_instalment (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    CHECK (status <> 'DONE' OR (treatment = 'ADJUSTED' AND chit_instalment_id IS NOT NULL)
                            OR (treatment = 'PAID' AND payment_voucher_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS chit.chit_refund (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_ticket_id    uuid NOT NULL,
    reason            text NOT NULL CHECK (reason IN ('WITHDRAWN','SUBSTITUTED','TERMINATED','DEATH')),
    amount_paid_in    numeric(18,2) NOT NULL CHECK (amount_paid_in >= 0),
    deductions        numeric(18,2) NOT NULL DEFAULT 0 CHECK (deductions >= 0),
    deduction_details jsonb,
    refund_amount     numeric(18,2) NOT NULL CHECK (refund_amount >= 0),
    due_on            date,                      -- e.g. end of the group, per the chit agreement
    status            text NOT NULL DEFAULT 'CALCULATED' CHECK (status IN ('CALCULATED','APPROVED','PAID','CANCELLED')),
    payee_type        text NOT NULL DEFAULT 'MEMBER' CHECK (payee_type IN ('MEMBER','NOMINEE','SUCCESSOR')),
    approval_request_id uuid,
    payment_voucher_id uuid,
    journal_id        uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    CHECK (refund_amount = amount_paid_in - deductions),
    CHECK (status <> 'PAID' OR payment_voucher_id IS NOT NULL)
);

-- Group balances must reconcile every month (10.7): collected = prizes paid +
-- commission + dividends + refunds + balance held.
CREATE OR REPLACE VIEW chit.v_group_reconciliation AS
SELECT g.tenant_id, g.id AS chit_group_id, g.group_code, g.status,
       coalesce((SELECT sum(p.amount) FROM chit.chit_instalment_payment p
                   JOIN chit.chit_instalment i ON i.tenant_id = p.tenant_id AND i.id = p.chit_instalment_id
                   JOIN chit.chit_ticket t ON t.tenant_id = i.tenant_id AND t.id = i.chit_ticket_id
                  WHERE t.tenant_id = g.tenant_id AND t.chit_group_id = g.id AND p.status = 'POSTED'), 0) AS subscriptions_collected,
       coalesce((SELECT sum(z.prize_amount) FROM chit.chit_prize z
                   JOIN chit.chit_auction a ON a.tenant_id = z.tenant_id AND a.id = z.chit_auction_id
                  WHERE a.tenant_id = g.tenant_id AND a.chit_group_id = g.id AND z.status = 'PAID'), 0)       AS prizes_paid,
       coalesce((SELECT sum(z.commission) FROM chit.chit_prize z
                   JOIN chit.chit_auction a ON a.tenant_id = z.tenant_id AND a.id = z.chit_auction_id
                  WHERE a.tenant_id = g.tenant_id AND a.chit_group_id = g.id AND z.status <> 'CANCELLED'), 0) AS commission,
       coalesce((SELECT sum(dp.amount) FROM chit.chit_dividend_payout dp
                   JOIN chit.chit_ticket t ON t.tenant_id = dp.tenant_id AND t.id = dp.chit_ticket_id
                  WHERE t.tenant_id = g.tenant_id AND t.chit_group_id = g.id AND dp.treatment = 'PAID' AND dp.status = 'DONE'), 0) AS dividends_paid_out,
       coalesce((SELECT sum(r.refund_amount) FROM chit.chit_refund r
                   JOIN chit.chit_ticket t ON t.tenant_id = r.tenant_id AND t.id = r.chit_ticket_id
                  WHERE t.tenant_id = g.tenant_id AND t.chit_group_id = g.id AND r.status = 'PAID'), 0)    AS refunds_paid,
       coalesce((SELECT sum(jl.credit - jl.debit) FROM acct.journal_line jl
                   JOIN acct.journal j ON j.tenant_id = jl.tenant_id AND j.id = jl.journal_id AND j.status IN ('POSTED','REVERSED')
                  WHERE jl.tenant_id = g.tenant_id
                    AND jl.account_id IN (g.subscriptions_account_id, g.prize_payable_account_id, g.dividend_payable_account_id)), 0) AS ledger_balance_held
  FROM chit.chit_group g;

-- =============================================================================
-- 11. Hall booking approvals
-- =============================================================================
ALTER TABLE ops.hall_booking
    ADD COLUMN IF NOT EXISTS family_event_approval_request_id uuid,
    ADD COLUMN IF NOT EXISTS family_event_approved_by uuid,
    ADD COLUMN IF NOT EXISTS cancel_approval_request_id uuid,
    ADD COLUMN IF NOT EXISTS refund_amount numeric(18,2);
DO $$ BEGIN
    PERFORM app.add_constraint_if_missing('ops.hall_booking', 'hall_booking_family_approval_fk',
        'FOREIGN KEY (tenant_id, family_event_approval_request_id) REFERENCES wf.approval_request (tenant_id, id)');
    PERFORM app.add_constraint_if_missing('ops.hall_booking', 'hall_booking_family_approver_fk',
        'FOREIGN KEY (tenant_id, family_event_approved_by) REFERENCES iam.app_user (tenant_id, id)');
    PERFORM app.add_constraint_if_missing('ops.hall_booking', 'hall_booking_cancel_approval_fk',
        'FOREIGN KEY (tenant_id, cancel_approval_request_id) REFERENCES wf.approval_request (tenant_id, id)');
    -- member rate for a non-member's event only with an approved family declaration (18.5)
    PERFORM app.add_constraint_if_missing('ops.hall_booking', 'hall_booking_family_rate_approved',
        'CHECK (NOT (customer_type = ''MEMBER'' AND rate_category = ''MEMBER'' AND family_event_declared)
                OR status IN (''ENQUIRY'',''TENTATIVE'',''CANCELLED'') OR family_event_approved_by IS NOT NULL
                OR import_batch_id IS NOT NULL)');
END $$;
