-- =============================================================================
-- CFMS / NVS  -  32  Loan servicing functions used by the API and jobs
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run. Every function runs as the caller (nvs_app), so
-- row-level security and the signed tenant context still apply.
--
-- Views
--   loan.get_schedule(loan_id)                 -> current schedule with paid/open amounts
--   loan.get_repayments(loan_id)               -> receipts with component allocations
--   loan.get_member_loan_statement(member_id)  -> per-loan balances and totals
-- Daily job (platform.job_definition LOAN_STATUS_DAILY and APPROVAL_EXPIRY)
--   loan.run_daily_status(on_date, triggered_by)
--        approvals not disbursed in time -> CANCELLED (prepared vouchers cancelled)
--        unpaid instalment past grace    -> OVERDUE, cleared -> ACTIVE/RESTRUCTURED
--        oldest unpaid due + N months    -> DEFAULTED, loan_default row, penalty
--                                           charge, member loan eligibility RESTRICTED
--   loan.record_job_failure(job_code, on_date, triggered_by, error)
-- Early settlement (rule EARLY_SETTLEMENT in the loan's rule snapshot)
--   loan.calculate_early_settlement(loan_id, on_date)
--   loan.quote_early_settlement(loan_id)       -> QUOTED statement
--   loan.approve_early_settlement(id, remarks) -> APPROVED (approver <> creator)
--   loan.collect_early_settlement(id, mode, reference) -> receipt, loan SETTLED
--   loan.get_settlement(id), loan.list_settlements(loan_id)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Views
-- -----------------------------------------------------------------------------
-- Current repayment schedule of a loan. NULL when the loan does not exist.
CREATE OR REPLACE FUNCTION loan.get_schedule(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH inst AS (
        SELECT i.*,
               CASE WHEN i.status IN ('DUE','PARTLY_PAID')
                    THEN i.principal_due - i.principal_paid + i.interest_due - i.interest_paid
                         + i.late_fee_assessed - i.late_fee_paid ELSE 0 END AS amount_open,
               i.status IN ('DUE','PARTLY_PAID') AND i.due_date < app.working_date() AS is_overdue
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id
    )
    SELECT jsonb_build_object(
        'loan_id', l.id, 'loan_no', l.loan_no, 'status', l.status, 'as_of', app.working_date(),
        'outstanding_principal', l.outstanding_principal,
        'schedule', CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object(
            'schedule_id', s.id, 'schedule_version', s.schedule_version, 'reason', s.reason,
            'effective_from', s.effective_from, 'principal_basis', s.principal_basis,
            'interest_rate_annual', s.interest_rate_annual, 'total_interest', s.total_interest,
            'total_repayable', s.total_repayable) END,
        'instalments', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'instalment_id', x.id, 'instalment_no', x.instalment_no, 'due_date', x.due_date,
                       'principal_due', x.principal_due, 'interest_due', x.interest_due, 'total_due', x.total_due,
                       'principal_paid', x.principal_paid, 'interest_paid', x.interest_paid,
                       'late_fee_assessed', x.late_fee_assessed, 'late_fee_paid', x.late_fee_paid,
                       'amount_open', x.amount_open, 'status', x.status, 'paid_on', x.paid_on,
                       'is_overdue', x.is_overdue,
                       'days_overdue', CASE WHEN x.is_overdue THEN app.working_date() - x.due_date ELSE 0 END)
                     ORDER BY x.instalment_no)
              FROM inst x), '[]'::jsonb),
        'totals', (SELECT jsonb_build_object(
                       'principal_due', coalesce(sum(x.principal_due), 0),
                       'interest_due', coalesce(sum(x.interest_due), 0),
                       'principal_paid', coalesce(sum(x.principal_paid), 0),
                       'interest_paid', coalesce(sum(x.interest_paid), 0),
                       'amount_open', coalesce(sum(x.amount_open), 0),
                       'overdue_amount', coalesce(sum(x.amount_open) FILTER (WHERE x.is_overdue), 0),
                       'overdue_instalments', count(*) FILTER (WHERE x.is_overdue))
                     FROM inst x))
      FROM loan.loan l
      LEFT JOIN loan.loan_schedule s ON s.tenant_id = l.tenant_id AND s.loan_id = l.id AND s.is_current
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND NOT l.is_deleted
$$;

-- Repayments of a loan, newest first, with receipt and allocation detail.
-- NULL when the loan does not exist.
CREATE OR REPLACE FUNCTION loan.get_repayments(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                   'repayment_id', r.id, 'value_date', r.value_date, 'repayment_type', r.repayment_type,
                   'amount', r.amount, 'principal_amount', r.principal_amount,
                   'interest_amount', r.interest_amount, 'late_fee_amount', r.late_fee_amount,
                   'penalty_amount', r.penalty_amount, 'charge_amount', r.charge_amount,
                   'status', r.status, 'reversal_reason', r.reversal_reason,
                   'cash_receipt_id', r.cash_receipt_id, 'receipt_no', cr.receipt_no,
                   'payment_mode', cr.payment_mode, 'payment_reference', cr.payment_reference,
                   'created_at', r.created_at,
                   'allocations', coalesce((
                       SELECT jsonb_agg(jsonb_build_object(
                                  'seq', a.seq, 'component', a.component, 'amount', a.amount,
                                  'instalment_no', i.instalment_no, 'due_date', i.due_date,
                                  'loan_charge_id', a.loan_charge_id) ORDER BY a.seq)
                         FROM loan.loan_repayment_allocation a
                         LEFT JOIN loan.loan_instalment i ON i.tenant_id = a.tenant_id AND i.id = a.loan_instalment_id
                        WHERE a.tenant_id = r.tenant_id AND a.loan_repayment_id = r.id), '[]'::jsonb))
                 ORDER BY r.value_date DESC, r.created_at DESC)
          FROM loan.loan_repayment r
          LEFT JOIN acct.cash_receipt cr ON cr.tenant_id = r.tenant_id AND cr.id = r.cash_receipt_id
         WHERE r.tenant_id = l.tenant_id AND r.loan_id = l.id), '[]'::jsonb)
      FROM loan.loan l
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND NOT l.is_deleted
$$;

-- Member loan statement: every disbursed loan with balances, plus totals over
-- open loans. NULL when the member does not exist.
CREATE OR REPLACE FUNCTION loan.get_member_loan_statement(p_member_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH loans AS (
        SELECT l.id, l.loan_no, l.status, l.application_date, l.approved_amount, l.disbursed_amount,
               l.first_disbursement_date, l.maturity_date, l.closed_on, l.outstanding_principal,
               lt.code AS loan_type_code, lt.name AS loan_type_name,
               b.interest_outstanding_scheduled, b.overdue_principal, b.overdue_interest, b.charges_open,
               b.days_overdue, b.oldest_unpaid_due_date, b.next_due_date, b.principal_repaid,
               b.interest_collected, b.last_payment_on,
               (SELECT coalesce(sum(i.principal_due - i.principal_paid + i.interest_due - i.interest_paid), 0)
                  FROM loan.loan_instalment i
                  JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
                 WHERE i.tenant_id = l.tenant_id AND i.loan_id = l.id AND i.due_date = b.next_due_date
                   AND i.status IN ('DUE','PARTLY_PAID')) AS next_due_amount,
               l.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED') AS is_open
          FROM loan.loan l
          JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
          JOIN loan.v_loan_balance b ON b.tenant_id = l.tenant_id AND b.loan_id = l.id
         WHERE l.tenant_id = app.tenant_id() AND l.member_id = p_member_id
           AND NOT l.is_deleted AND l.disbursed_amount > 0
    )
    SELECT jsonb_build_object(
        'member_id', m.id, 'member_no', m.member_no, 'member_name', m.full_name,
        'loan_eligibility', m.loan_eligibility, 'cooling_off_until', m.cooling_off_until,
        'as_of', app.working_date(),
        'loans', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'loan_id', x.id, 'loan_no', x.loan_no, 'loan_type_code', x.loan_type_code,
                       'loan_type_name', x.loan_type_name, 'status', x.status,
                       'approved_amount', x.approved_amount, 'disbursed_amount', x.disbursed_amount,
                       'first_disbursement_date', x.first_disbursement_date, 'maturity_date', x.maturity_date,
                       'outstanding_principal', x.outstanding_principal,
                       'interest_outstanding_scheduled', x.interest_outstanding_scheduled,
                       'overdue_principal', x.overdue_principal, 'overdue_interest', x.overdue_interest,
                       'overdue_amount', x.overdue_principal + x.overdue_interest,
                       'charges_open', x.charges_open, 'days_overdue', x.days_overdue,
                       'oldest_unpaid_due_date', x.oldest_unpaid_due_date,
                       'next_due_date', x.next_due_date, 'next_due_amount', x.next_due_amount,
                       'principal_repaid', x.principal_repaid, 'interest_collected', x.interest_collected,
                       'last_payment_on', x.last_payment_on, 'closed_on', x.closed_on)
                     ORDER BY x.is_open DESC, x.application_date DESC, x.loan_no DESC)
              FROM loans x), '[]'::jsonb),
        'totals', (SELECT jsonb_build_object(
                       'open_loans', count(*),
                       'outstanding_principal', coalesce(sum(x.outstanding_principal), 0),
                       'interest_outstanding_scheduled', coalesce(sum(x.interest_outstanding_scheduled), 0),
                       'overdue_amount', coalesce(sum(x.overdue_principal + x.overdue_interest), 0),
                       'charges_open', coalesce(sum(x.charges_open), 0),
                       'next_due_date', min(x.next_due_date))
                     FROM loans x WHERE x.is_open))
      FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_member_id AND NOT m.is_deleted
$$;

-- -----------------------------------------------------------------------------
-- Daily job
-- -----------------------------------------------------------------------------
-- One successful run per tenant, job and working date (job_run_one_per_day_uq):
-- a re-run on the same day updates that row instead of adding another.
CREATE OR REPLACE FUNCTION loan.record_job_run(
    p_job_code text, p_on date, p_triggered_by text, p_started timestamptz,
    p_processed integer, p_details jsonb)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE v_id uuid;
BEGIN
    UPDATE platform.job_run SET status = 'SUCCEEDED', started_at = p_started, completed_at = clock_timestamp(),
           triggered_by = p_triggered_by, records_processed = p_processed, records_failed = 0,
           error_message = NULL, details = p_details,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND job_code = p_job_code AND working_date = p_on
       AND status IN ('QUEUED','RUNNING','SUCCEEDED')
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        INSERT INTO platform.job_run (job_code, working_date, scheduled_for, started_at, completed_at, status,
                                      triggered_by, records_processed, details)
        VALUES (p_job_code, p_on, p_started, p_started, clock_timestamp(), 'SUCCEEDED',
                p_triggered_by, p_processed, p_details)
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END
$$;

-- Called by the job runner in a fresh transaction after a tenant's run failed.
CREATE OR REPLACE FUNCTION loan.record_job_failure(
    p_job_code text, p_on date, p_triggered_by text, p_error text)
RETURNS uuid LANGUAGE sql AS
$$
    INSERT INTO platform.job_run (job_code, working_date, scheduled_for, started_at, completed_at, status,
                                  triggered_by, records_failed, error_message)
    VALUES (p_job_code, p_on, now(), now(), now(), 'FAILED', p_triggered_by, 1, left(p_error, 2000))
    RETURNING id
$$;

CREATE OR REPLACE FUNCTION loan.run_daily_status(
    p_on date DEFAULT NULL, p_triggered_by text DEFAULT 'SCHEDULE')
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_tenant uuid := app.tenant_id();
    v_on date := coalesce(p_on, app.working_date());
    v_started timestamptz := clock_timestamp();
    v_loan record;
    v_disb record;
    v_expired integer := 0;
    v_vouchers integer := 0;
    v_overdue integer := 0;
    v_cured integer := 0;
    v_defaulted integer := 0;
    v_checked integer := 0;
    v_skipped integer := 0;
    v_review integer := 0;
    v_late integer := 0;
    v_cool integer := 0;
    v_reminders integer := 0;
    v_escalated integer := 0;
    v_oldest date;
    v_months integer;
    v_interest numeric(18,2);
    v_rule jsonb;
    v_penalty numeric(18,2);
    v_default_id uuid;
    v_go_live date;
    v_expiry jsonb;
    v_status jsonb;
    v_other jsonb;
BEGIN
    IF v_tenant IS NULL THEN
        PERFORM app.fail('TENANT_CONTEXT_REQUIRED', 'The daily loan job needs a valid signed tenant context (check CFMS_DB_CONTEXT_SIGNING_KEY)');
    END IF;
    v_go_live := nullif(cfg.get_setting('migration.go_live_date') #>> '{}', '')::date;

    -- 1. Approvals not disbursed within the window (approval_expires_on).
    FOR v_loan IN
        SELECT id, approval_expires_on FROM loan.loan
         WHERE tenant_id = v_tenant AND status = 'APPROVED' AND approval_expires_on < v_on
           AND disbursed_amount = 0 AND NOT is_deleted
         ORDER BY id FOR UPDATE
    LOOP
        FOR v_disb IN
            SELECT id, payment_voucher_id FROM loan.loan_disbursement
             WHERE tenant_id = v_tenant AND loan_id = v_loan.id AND status = 'PREPARED' FOR UPDATE
        LOOP
            UPDATE acct.payment_voucher SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = app.user_id(),
                   cancel_reason = 'Loan approval expired before release',
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = v_tenant AND id = v_disb.payment_voucher_id AND status = 'PREPARED';
            UPDATE loan.loan_disbursement SET status = 'CANCELLED',
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = v_tenant AND id = v_disb.id;
            v_vouchers := v_vouchers + 1;
        END LOOP;
        UPDATE loan.loan SET status = 'CANCELLED', status_date = v_on,
               status_reason = format('Approval expired on %s without disbursement', v_loan.approval_expires_on),
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = v_tenant AND id = v_loan.id;
        v_expired := v_expired + 1;
    END LOOP;
    v_expiry := jsonb_build_object('working_date', v_on, 'approvals_expired', v_expired,
                                   'disbursements_cancelled', v_vouchers);
    PERFORM loan.record_job_run('APPROVAL_EXPIRY', v_on, p_triggered_by, v_started, v_expired, v_expiry);

    -- 2. Late fees, then overdue, back to current and default. Loans of a
    --    deceased member (or whose interest stopped) wait for the Manager's
    --    decision (scope 12.2, 12.3). A migrated loan whose default would date
    --    from before go-live is listed for review instead (scope 39.3).
    v_late := loan.assess_late_fees(v_on);
    FOR v_loan IN
        SELECT l.id, l.member_id, l.status, l.is_restructured, l.outstanding_principal, l.rule_snapshot,
               l.rule_set_version_id, l.is_migrated, l.interest_stopped_from, l.created_at, m.status AS member_status
          FROM loan.loan l JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
         WHERE l.tenant_id = v_tenant AND l.status IN ('ACTIVE','OVERDUE','RESTRUCTURED') AND NOT l.is_deleted
         ORDER BY l.id FOR UPDATE OF l
    LOOP
        v_checked := v_checked + 1;
        IF v_loan.member_status = 'DECEASED' OR v_loan.interest_stopped_from IS NOT NULL THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;
        SELECT min(i.due_date) INTO v_oldest
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = v_tenant AND i.loan_id = v_loan.id
           AND i.status IN ('DUE','PARTLY_PAID') AND i.due_date < v_on;
        v_months := loan.default_after_months(v_loan.rule_snapshot);

        IF v_oldest IS NOT NULL AND (v_oldest + make_interval(months => v_months))::date < v_on
           AND v_loan.is_migrated AND v_oldest < coalesce(v_go_live, v_loan.created_at::date)
           -- A Manager can decide that the default applies (loan.decide_migration_review).
           AND NOT EXISTS (SELECT 1 FROM loan.migration_default_review r
                            WHERE r.tenant_id = v_tenant AND r.loan_id = v_loan.id AND r.status = 'DEFAULT_APPLIED') THEN
            INSERT INTO loan.migration_default_review (loan_id, listed_on, oldest_unpaid_due_date, go_live_date)
            SELECT v_loan.id, v_on, v_oldest, coalesce(v_go_live, v_loan.created_at::date)
             WHERE NOT EXISTS (SELECT 1 FROM loan.migration_default_review r
                                WHERE r.tenant_id = v_tenant AND r.loan_id = v_loan.id AND r.status IN ('OPEN','DISMISSED'));
            IF FOUND THEN v_review := v_review + 1; END IF;
            IF v_loan.status <> 'OVERDUE' THEN
                UPDATE loan.loan SET status = 'OVERDUE', status_date = v_on,
                       status_reason = format('Instalment due on %s is unpaid (migrated, default under review)', v_oldest),
                       updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
                 WHERE tenant_id = v_tenant AND id = v_loan.id;
                v_overdue := v_overdue + 1;
            END IF;
        ELSIF v_oldest IS NOT NULL AND (v_oldest + make_interval(months => v_months))::date < v_on THEN
            SELECT coalesce(sum(i.interest_due - i.interest_paid), 0) INTO v_interest
              FROM loan.loan_instalment i
              JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
             WHERE i.tenant_id = v_tenant AND i.loan_id = v_loan.id AND i.status IN ('DUE','PARTLY_PAID');
            v_rule := loan.rule(v_loan.rule_snapshot, 'DEFAULT_PENALTY');
            v_rule := coalesce(v_rule->'then', v_rule->'value', '{}'::jsonb);
            v_penalty := CASE lower(coalesce(v_rule->>'type', ''))
                WHEN 'percent' THEN round(v_loan.outstanding_principal * coalesce((v_rule->>'value')::numeric, 0) / 100, 2)
                WHEN 'fixed'   THEN round(coalesce((v_rule->>'value')::numeric, (v_rule->>'amount')::numeric, 0), 2)
                ELSE 0 END;
            INSERT INTO loan.loan_default (loan_id, defaulted_on, oldest_unpaid_due_date, unpaid_months_rule,
                                           outstanding_principal, outstanding_interest, penalty_amount, rule_set_version_id)
            VALUES (v_loan.id, v_on, v_oldest, v_months, v_loan.outstanding_principal, v_interest,
                    v_penalty, v_loan.rule_set_version_id)
            RETURNING id INTO v_default_id;
            IF v_penalty > 0 THEN
                INSERT INTO loan.loan_charge (loan_id, charge_type, assessed_on, amount, rule_set_version_id)
                VALUES (v_loan.id, 'DEFAULT_PENALTY', v_on, v_penalty, v_loan.rule_set_version_id);
            END IF;
            UPDATE loan.loan SET status = 'DEFAULTED', status_date = v_on,
                   status_reason = format('Unpaid since %s, more than %s month(s)', v_oldest, v_months),
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = v_tenant AND id = v_loan.id;
            UPDATE mbr.member SET loan_eligibility = 'RESTRICTED',
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = v_tenant AND id = v_loan.member_id AND loan_eligibility <> 'RESTRICTED';
            PERFORM loan.open_recovery_case(v_loan.id, v_default_id);
            PERFORM loan.notify_member('LOAN_DEFAULTED', v_loan.id, jsonb_build_object('amount',
                v_loan.outstanding_principal + v_interest + v_penalty
                + coalesce((SELECT sum(amount - paid_amount - waived_amount) FROM loan.loan_charge
                             WHERE tenant_id = v_tenant AND loan_id = v_loan.id AND status = 'OPEN' AND charge_type = 'LATE_FEE'), 0)));
            PERFORM loan.notify_guarantors('GUARANTOR_DEFAULT_NOTICE', v_loan.id, '{}'::jsonb);
            PERFORM loan.notify_nominees('NOMINEE_DEFAULT_NOTICE', v_loan.id, '{}'::jsonb);
            v_defaulted := v_defaulted + 1;
        ELSIF v_oldest IS NOT NULL AND v_oldest + loan.grace_days(v_loan.rule_snapshot) < v_on THEN
            IF v_loan.status <> 'OVERDUE' THEN
                UPDATE loan.loan SET status = 'OVERDUE', status_date = v_on,
                       status_reason = format('Instalment due on %s is unpaid', v_oldest),
                       updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
                 WHERE tenant_id = v_tenant AND id = v_loan.id;
                PERFORM loan.notify_guarantors('GUARANTOR_NOTICE', v_loan.id, '{}'::jsonb);
                v_overdue := v_overdue + 1;
            END IF;
        ELSIF v_loan.status = 'OVERDUE' THEN
            UPDATE loan.loan SET status = CASE WHEN is_restructured THEN 'RESTRUCTURED' ELSE 'ACTIVE' END,
                   status_date = v_on, status_reason = 'Overdue instalments cleared',
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = v_tenant AND id = v_loan.id;
            v_cured := v_cured + 1;
        END IF;
    END LOOP;
    v_status := jsonb_build_object('working_date', v_on, 'loans_checked', v_checked,
                                   'late_fees_assessed', v_late, 'marked_overdue', v_overdue,
                                   'back_to_current', v_cured, 'defaulted', v_defaulted,
                                   'skipped_deceased', v_skipped, 'migrated_listed_for_review', v_review);
    PERFORM loan.record_job_run('LOAN_STATUS_DAILY', v_on, p_triggered_by, v_started,
                                v_late + v_overdue + v_cured + v_defaulted + v_review, v_status);

    -- 3. Cooling-off completion, reminders and recovery escalation.
    v_started := clock_timestamp();
    v_cool := loan.end_cooling_off(v_on);
    PERFORM loan.record_job_run('COOLING_OFF_END', v_on, p_triggered_by, v_started, v_cool,
                                jsonb_build_object('working_date', v_on, 'cooling_off_ended', v_cool));
    v_started := clock_timestamp();
    IF NOT EXISTS (SELECT 1 FROM platform.job_run WHERE tenant_id = v_tenant AND job_code = 'LOAN_REMINDERS'
                    AND working_date = v_on AND status = 'SUCCEEDED') THEN
        v_reminders := loan.send_due_reminders(v_on);
    END IF;
    PERFORM loan.record_job_run('LOAN_REMINDERS', v_on, p_triggered_by, v_started, v_reminders,
                                jsonb_build_object('working_date', v_on, 'reminders_queued', v_reminders));
    v_started := clock_timestamp();
    v_escalated := loan.escalate_recovery_cases(v_on);
    PERFORM loan.record_job_run('RECOVERY_ESCALATION', v_on, p_triggered_by, v_started, v_escalated,
                                jsonb_build_object('working_date', v_on, 'cases_escalated', v_escalated));
    v_other := jsonb_build_object('cooling_off_ended', v_cool, 'reminders_queued', v_reminders,
                                  'recovery_cases_escalated', v_escalated);
    RETURN v_expiry || v_status || v_other;
END
$$;

-- -----------------------------------------------------------------------------
-- Early settlement
-- -----------------------------------------------------------------------------
-- Settlement amount of a loan on a date, from the loan's EARLY_SETTLEMENT rule:
--   {"enabled":true,"interestPolicy":"A_ALL_SCHEDULED_INTEREST"|"B_INTEREST_TO_DATE",
--    "charge":{"type":"none"|"fixed"|"percent","value":n},"approvalRequired":true,
--    "quoteValidDays":0}
-- Policy A charges all unpaid scheduled interest. Policy B charges interest due
-- up to the date plus interest accrued by days on the current instalment.
-- Open late fees and default penalties are added, then the rounding.settlement
-- setting is applied. A downward rounding is taken off interest, then the
-- charge; when they cannot absorb it the amount is left unrounded.
CREATE OR REPLACE FUNCTION loan.calculate_early_settlement(p_loan_id uuid, p_on date)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_loan record;
    v_rule jsonb;
    v_policy text;
    v_inst record;
    v_prev_due date;
    v_current_seen boolean := false;
    v_part numeric(18,2);
    v_period integer;
    v_days integer;
    v_principal numeric(18,2) := 0;
    v_interest numeric(18,2) := 0;
    v_sched_interest numeric(18,2) := 0;
    v_plan jsonb := '[]'::jsonb;
    v_charges jsonb;
    v_late numeric(18,2);
    v_penalty numeric(18,2);
    v_charge_rule jsonb;
    v_charge numeric(18,2) := 0;
    v_subtotal numeric(18,2);
    v_total numeric(18,2);
    v_rounding numeric(18,2);
    v_type text := 'EARLY';
BEGIN
    SELECT l.id, l.status, l.loan_type_id, l.member_id, l.rule_snapshot, l.rule_set_version_id,
           l.early_settlement_policy, l.outstanding_principal, s.id AS schedule_id, s.effective_from
      INTO v_loan
      FROM loan.loan l
      LEFT JOIN loan.loan_schedule s ON s.tenant_id = l.tenant_id AND s.loan_id = l.id AND s.is_current
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND NOT l.is_deleted;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_NOT_FOUND', 'The loan was not found.');
    END IF;
    IF v_loan.status NOT IN ('ACTIVE','OVERDUE','RESTRUCTURED','DEFAULTED') OR v_loan.schedule_id IS NULL THEN
        PERFORM app.fail('EARLY_SETTLEMENT_NOT_ALLOWED',
            format('Early settlement is not available for a loan in status %s.', v_loan.status));
    END IF;
    IF v_loan.status = 'DEFAULTED' THEN
        -- Default settlement (scope 8.1): the full outstanding plus the default
        -- penalty. Always available; rule DEFAULT_SETTLEMENT may set the
        -- interest policy (default A, all remaining interest) and approval.
        v_type := 'DEFAULT';
        v_rule := coalesce(loan.rule(v_loan.rule_snapshot, 'DEFAULT_SETTLEMENT')->'value', '{}'::jsonb);
        v_policy := coalesce(v_rule->>'interestPolicy', 'A_ALL_SCHEDULED_INTEREST');
        v_rule := v_rule - 'charge';
    ELSE
        v_rule := coalesce(loan.rule(v_loan.rule_snapshot, 'EARLY_SETTLEMENT')->'value', '{}'::jsonb);
        IF NOT coalesce((v_rule->>'enabled')::boolean, true) THEN
            PERFORM app.fail('EARLY_SETTLEMENT_DISABLED', 'Early settlement is not enabled for this loan type.');
        END IF;
        v_policy := coalesce(v_loan.early_settlement_policy, v_rule->>'interestPolicy', 'B_INTEREST_TO_DATE');
    END IF;
    IF v_policy NOT IN ('A_ALL_SCHEDULED_INTEREST','B_INTEREST_TO_DATE') THEN
        v_policy := 'B_INTEREST_TO_DATE';
    END IF;

    v_prev_due := v_loan.effective_from;
    FOR v_inst IN
        SELECT id, instalment_no, due_date, status, interest_due, interest_paid,
               principal_due - principal_paid AS principal_open, interest_due - interest_paid AS interest_open
          FROM loan.loan_instalment
         WHERE tenant_id = app.tenant_id() AND loan_schedule_id = v_loan.schedule_id
         ORDER BY instalment_no
    LOOP
        IF v_inst.status IN ('DUE','PARTLY_PAID') THEN
            IF v_policy = 'A_ALL_SCHEDULED_INTEREST' OR v_inst.due_date <= p_on THEN
                v_part := v_inst.interest_open;
            ELSIF NOT v_current_seen THEN
                v_current_seen := true;
                v_period := greatest(v_inst.due_date - v_prev_due, 1);
                v_days := least(greatest(p_on - v_prev_due, 0), v_period);
                v_part := least(v_inst.interest_open,
                                greatest(round(v_inst.interest_due * v_days / v_period, 2) - v_inst.interest_paid, 0));
            ELSE
                v_part := 0;
            END IF;
            v_principal := v_principal + v_inst.principal_open;
            v_interest := v_interest + v_part;
            v_sched_interest := v_sched_interest + v_inst.interest_open;
            v_plan := v_plan || jsonb_build_array(jsonb_build_object(
                'instalment_id', v_inst.id, 'instalment_no', v_inst.instalment_no, 'due_date', v_inst.due_date,
                'principal', v_inst.principal_open, 'interest', v_part,
                'interest_rebated', v_inst.interest_open - v_part));
        END IF;
        v_prev_due := v_inst.due_date;
    END LOOP;

    SELECT coalesce(jsonb_agg(jsonb_build_object('loan_charge_id', c.id, 'charge_type', c.charge_type,
                                                 'amount', c.amount - c.paid_amount - c.waived_amount)
                              ORDER BY c.assessed_on, c.id), '[]'::jsonb),
           coalesce(sum(c.amount - c.paid_amount - c.waived_amount) FILTER (WHERE c.charge_type = 'LATE_FEE'), 0),
           coalesce(sum(c.amount - c.paid_amount - c.waived_amount) FILTER (WHERE c.charge_type = 'DEFAULT_PENALTY'), 0)
      INTO v_charges, v_late, v_penalty
      FROM loan.loan_charge c
     WHERE c.tenant_id = app.tenant_id() AND c.loan_id = p_loan_id AND c.status = 'OPEN'
       AND c.charge_type IN ('LATE_FEE','DEFAULT_PENALTY') AND c.amount - c.paid_amount - c.waived_amount > 0;

    v_charge_rule := coalesce(v_rule->'charge', '{}'::jsonb);
    v_charge := CASE lower(coalesce(v_charge_rule->>'type', 'none'))
        WHEN 'fixed'   THEN round(coalesce((v_charge_rule->>'value')::numeric, (v_charge_rule->>'amount')::numeric, 0), 2)
        WHEN 'percent' THEN round(v_principal * coalesce((v_charge_rule->>'value')::numeric,
                                                         (v_charge_rule->>'percent')::numeric, 0) / 100, 2)
        ELSE 0 END;

    v_subtotal := v_principal + v_interest + v_late + v_penalty + v_charge;
    v_total := loan.round_amount(v_subtotal, cfg.get_setting('rounding.settlement'));
    v_rounding := v_total - v_subtotal;
    IF v_rounding < 0 AND -v_rounding > v_interest + v_charge THEN
        v_rounding := 0;
        v_total := v_subtotal;
    END IF;

    RETURN jsonb_build_object(
        'loan_id', p_loan_id, 'settlement_type', v_type, 'statement_date', p_on, 'interest_policy', v_policy,
        'principal_outstanding', v_principal, 'interest_component', v_interest,
        'scheduled_interest_outstanding', v_sched_interest, 'rebate', v_sched_interest - v_interest,
        'late_fees', v_late, 'penalty', v_penalty, 'settlement_charge', v_charge,
        'rounding_adjustment', v_rounding, 'total_payable', v_total,
        'approval_required', coalesce((v_rule->>'approvalRequired')::boolean, true),
        'quote_valid_days', greatest(coalesce((v_rule->>'quoteValidDays')::integer, 0), 0),
        'instalments', v_plan, 'charges', v_charges,
        'rule_set_version_id', v_loan.rule_set_version_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.get_settlement(p_settlement_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object(
        'id', s.id, 'loan_id', s.loan_id, 'loan_no', l.loan_no, 'member_id', l.member_id,
        'member_no', m.member_no, 'member_name', m.full_name, 'loan_status', l.status,
        'settlement_type', s.settlement_type, 'statement_date', s.statement_date,
        'valid_until', s.valid_until, 'interest_policy', s.interest_policy,
        'principal_outstanding', s.principal_outstanding, 'interest_component', s.interest_component,
        'late_fees', s.late_fees, 'penalty', s.penalty, 'settlement_charge', s.settlement_charge,
        'rebate', s.rebate, 'waiver', s.waiver, 'rounding_adjustment', s.rounding_adjustment,
        'total_payable', s.total_payable, 'status', s.status,
        'approval_required', coalesce((s.components->>'approval_required')::boolean, true),
        'approval', s.components->'approval', 'collection', s.components->'collection',
        'instalments', coalesce(s.components->'instalments', '[]'::jsonb),
        'charges', coalesce(s.components->'charges', '[]'::jsonb),
        'cash_receipt_id', s.cash_receipt_id, 'receipt_no', cr.receipt_no,
        'created_at', s.created_at, 'created_by', s.created_by,
        'updated_at', s.updated_at, 'row_version', s.row_version)
      FROM loan.loan_settlement s
      JOIN loan.loan l ON l.tenant_id = s.tenant_id AND l.id = s.loan_id
      JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
      LEFT JOIN acct.cash_receipt cr ON cr.tenant_id = s.tenant_id AND cr.id = s.cash_receipt_id
     WHERE s.tenant_id = app.tenant_id() AND s.id = p_settlement_id
$$;

-- Settlement statements of a loan, newest first. NULL when the loan does not exist.
CREATE OR REPLACE FUNCTION loan.list_settlements(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce((
        SELECT jsonb_agg(loan.get_settlement(s.id) ORDER BY s.created_at DESC)
          FROM loan.loan_settlement s
         WHERE s.tenant_id = l.tenant_id AND s.loan_id = l.id), '[]'::jsonb)
      FROM loan.loan l
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND NOT l.is_deleted
$$;

-- New quote on the working date; earlier open quotes of the loan expire.
-- An interest waiver (negotiated settlement, scope 7.3 and 8.6) needs a reason
-- and always needs approval; late fees and penalties are waived separately
-- (loan.request_waiver) and principal relief goes through write-off.
DROP FUNCTION IF EXISTS loan.quote_early_settlement(uuid);
CREATE OR REPLACE FUNCTION loan.quote_early_settlement(
    p_loan_id uuid, p_interest_waiver numeric DEFAULT 0, p_waiver_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_on date := app.working_date();
    v_calc jsonb;
    v_id uuid;
    v_waiver numeric(18,2) := coalesce(p_interest_waiver, 0);
BEGIN
    PERFORM 1 FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id FOR UPDATE;
    v_calc := loan.calculate_early_settlement(p_loan_id, v_on);
    IF v_waiver < 0 OR v_waiver > (v_calc->>'interest_component')::numeric THEN
        PERFORM app.fail('INVALID_WAIVER_AMOUNT',
            format('The interest waiver cannot exceed the interest of %s.', v_calc->>'interest_component'));
    END IF;
    IF v_waiver > 0 AND coalesce(p_waiver_reason, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required for this change.');
    END IF;
    UPDATE loan.loan_settlement SET status = 'EXPIRED',
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status IN ('QUOTED','APPROVED');
    INSERT INTO loan.loan_settlement (
        loan_id, settlement_type, statement_date, interest_policy, principal_outstanding,
        interest_component, late_fees, penalty, settlement_charge, rebate, rounding_adjustment,
        waiver, total_payable, components, status, valid_until, rule_set_version_id)
    VALUES (
        p_loan_id, v_calc->>'settlement_type', v_on, v_calc->>'interest_policy', (v_calc->>'principal_outstanding')::numeric,
        (v_calc->>'interest_component')::numeric, (v_calc->>'late_fees')::numeric,
        (v_calc->>'penalty')::numeric, (v_calc->>'settlement_charge')::numeric,
        (v_calc->>'rebate')::numeric, (v_calc->>'rounding_adjustment')::numeric,
        v_waiver, (v_calc->>'total_payable')::numeric - v_waiver,
        jsonb_build_object('approval_required', (v_calc->>'approval_required')::boolean OR v_waiver > 0,
                           'waiver_reason', p_waiver_reason,
                           'scheduled_interest_outstanding', v_calc->'scheduled_interest_outstanding',
                           'instalments', v_calc->'instalments', 'charges', v_calc->'charges'),
        'QUOTED', v_on + (v_calc->>'quote_valid_days')::integer,
        nullif(v_calc->>'rule_set_version_id', '')::uuid)
    RETURNING id INTO v_id;
    PERFORM loan.notify_member('SETTLEMENT_QUOTE', p_loan_id,
        jsonb_build_object('amount', (v_calc->>'total_payable')::numeric - v_waiver,
                           'valid_until', to_char(v_on + (v_calc->>'quote_valid_days')::integer, 'DD-Mon-YYYY')));
    RETURN loan.get_settlement(v_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.approve_early_settlement(p_settlement_id uuid, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_s record;
BEGIN
    SELECT id, status, valid_until, created_by INTO v_s FROM loan.loan_settlement
     WHERE tenant_id = app.tenant_id() AND id = p_settlement_id AND settlement_type IN ('EARLY','DEFAULT') FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('SETTLEMENT_NOT_FOUND', 'The settlement quote was not found.');
    END IF;
    IF v_s.status <> 'QUOTED' THEN
        PERFORM app.fail('SETTLEMENT_NOT_PENDING', format('The settlement quote is %s.', v_s.status));
    END IF;
    IF v_s.valid_until < app.working_date() THEN
        PERFORM app.fail('SETTLEMENT_QUOTE_EXPIRED', format('The settlement quote expired on %s.', v_s.valid_until));
    END IF;
    IF v_s.created_by IS NOT DISTINCT FROM app.user_id() THEN
        PERFORM app.fail('SETTLEMENT_APPROVER_IS_CREATOR', 'The employee who prepared the quote cannot approve it.');
    END IF;
    UPDATE loan.loan_settlement SET status = 'APPROVED',
           components = coalesce(components, '{}'::jsonb) || jsonb_build_object('approval', jsonb_build_object(
               'approved_by', app.user_id(), 'approver_role', app.role_code(),
               'approved_on', app.working_date(), 'approved_at', now(), 'remarks', p_remarks)),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_settlement_id;
    RETURN loan.get_settlement(p_settlement_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.collect_early_settlement(
    p_settlement_id uuid, p_payment_mode text, p_payment_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_on date := app.working_date();
    v_s record;
    v_loan record;
    v_calc jsonb;
    v_absorb numeric(18,2);
    v_interest numeric(18,2);
    v_charge numeric(18,2);
    v_round_up numeric(18,2);
    v_budget numeric(18,2);
    v_part numeric(18,2);
    v_lines jsonb := '[]'::jsonb;
    v_receipt uuid;
    v_journal uuid;
    v_repayment uuid;
    v_item jsonb;
    v_seq integer := 0;
    v_charge_id uuid;
    v_cool jsonb;
    v_cool_until date;
BEGIN
    SELECT * INTO v_s FROM loan.loan_settlement
     WHERE tenant_id = app.tenant_id() AND id = p_settlement_id AND settlement_type IN ('EARLY','DEFAULT') FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('SETTLEMENT_NOT_FOUND', 'The settlement quote was not found.');
    END IF;
    SELECT id, member_id, loan_type_id, status, rule_snapshot, rule_set_version_id INTO v_loan
      FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = v_s.loan_id FOR UPDATE;
    IF v_s.status = 'QUOTED' AND coalesce((v_s.components->>'approval_required')::boolean, true) THEN
        PERFORM app.fail('SETTLEMENT_NOT_APPROVED', 'The settlement quote must be approved before collection.');
    END IF;
    IF v_s.status NOT IN ('QUOTED','APPROVED') THEN
        PERFORM app.fail('SETTLEMENT_NOT_PENDING', format('The settlement quote is %s.', v_s.status));
    END IF;
    IF v_s.valid_until < v_on THEN
        PERFORM app.fail('SETTLEMENT_QUOTE_EXPIRED', format('The settlement quote expired on %s.', v_s.valid_until));
    END IF;
    -- The quote must still describe the loan: same dues and open charges.
    v_calc := loan.calculate_early_settlement(v_s.loan_id, v_s.statement_date);
    IF (v_calc->>'total_payable')::numeric <> v_s.total_payable + v_s.waiver
       OR (v_calc->>'principal_outstanding')::numeric <> v_s.principal_outstanding
       OR v_calc->'instalments' IS DISTINCT FROM v_s.components->'instalments'
       OR v_calc->'charges' IS DISTINCT FROM v_s.components->'charges' THEN
        PERFORM app.fail('SETTLEMENT_QUOTE_STALE', 'The loan changed after the quote was prepared; prepare a new quote.');
    END IF;

    v_absorb := greatest(-v_s.rounding_adjustment, 0);
    v_interest := v_s.interest_component - v_s.waiver;
    v_interest := v_interest - least(v_absorb, v_interest);
    v_charge := v_s.settlement_charge - (v_absorb - (v_s.interest_component - v_s.waiver - v_interest));
    v_round_up := greatest(v_s.rounding_adjustment, 0);

    IF v_s.principal_outstanding > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'PRINCIPAL',
            'mapping_key', 'LOAN_PRINCIPAL', 'scope_type', 'LOAN_TYPE', 'scope_id', v_loan.loan_type_id,
            'amount', v_s.principal_outstanding));
    END IF;
    IF v_interest > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'INTEREST',
            'mapping_key', 'LOAN_INTEREST', 'amount', v_interest));
    END IF;
    IF v_s.late_fees > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'LATE_FEE',
            'mapping_key', 'LATE_FEE', 'amount', v_s.late_fees));
    END IF;
    IF v_s.penalty > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'PENALTY',
            'mapping_key', 'DEFAULT_PENALTY', 'amount', v_s.penalty));
    END IF;
    IF v_charge > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'SETTLEMENT_CHARGE',
            'mapping_key', 'OTHER_INCOME', 'amount', v_charge));
    END IF;
    IF v_round_up > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'ROUNDING',
            'mapping_key', 'ROUNDING_OFF', 'amount', v_round_up));
    END IF;

    SELECT r.cash_receipt_id, r.journal_id INTO v_receipt, v_journal
      FROM acct.post_cash_receipt(v_loan.member_id, v_s.total_payable, p_payment_mode, p_payment_reference,
                                  CASE v_s.settlement_type WHEN 'DEFAULT' THEN 'LOAN_DEFAULT_SETTLEMENT' ELSE 'LOAN_EARLY_SETTLEMENT' END,
                                  'loan.loan', v_s.loan_id, v_lines) r;

    INSERT INTO loan.loan_repayment (loan_id, cash_receipt_id, value_date, repayment_type, amount,
        principal_amount, interest_amount, late_fee_amount, penalty_amount, charge_amount, rule_set_version_id)
    VALUES (v_s.loan_id, v_receipt, v_on,
            CASE v_s.settlement_type WHEN 'DEFAULT' THEN 'DEFAULT_SETTLEMENT' ELSE 'EARLY_SETTLEMENT' END, v_s.total_payable, v_s.principal_outstanding,
            v_interest, v_s.late_fees, v_s.penalty, v_charge + v_round_up, v_loan.rule_set_version_id)
    RETURNING id INTO v_repayment;

    -- Instalments: all principal is cleared; interest as quoted (less any
    -- downward rounding). Fully paid -> PAID, otherwise CANCELLED.
    v_budget := v_interest;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_s.components->'instalments') LOOP
        v_part := least((v_item->>'interest')::numeric, v_budget);
        v_budget := v_budget - v_part;
        IF v_part > 0 THEN
            v_seq := v_seq + 1;
            INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, loan_instalment_id, component, amount)
            VALUES (v_repayment, v_seq, (v_item->>'instalment_id')::uuid, 'INTEREST', v_part);
        END IF;
        IF (v_item->>'principal')::numeric > 0 THEN
            v_seq := v_seq + 1;
            INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, loan_instalment_id, component, amount)
            VALUES (v_repayment, v_seq, (v_item->>'instalment_id')::uuid, 'PRINCIPAL', (v_item->>'principal')::numeric);
        END IF;
        UPDATE loan.loan_instalment
           SET principal_paid = principal_due, interest_paid = interest_paid + v_part,
               status = CASE WHEN interest_paid + v_part >= interest_due THEN 'PAID' ELSE 'CANCELLED' END,
               paid_on = v_on, updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = (v_item->>'instalment_id')::uuid;
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_s.components->'charges', '[]'::jsonb)) LOOP
        v_seq := v_seq + 1;
        INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, loan_charge_id, component, amount)
        VALUES (v_repayment, v_seq, (v_item->>'loan_charge_id')::uuid,
                CASE WHEN v_item->>'charge_type' = 'LATE_FEE' THEN 'LATE_FEE' ELSE 'PENALTY' END,
                (v_item->>'amount')::numeric);
        UPDATE loan.loan_charge SET paid_amount = amount - waived_amount, status = 'PAID',
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = (v_item->>'loan_charge_id')::uuid;
    END LOOP;

    IF v_charge > 0 THEN
        INSERT INTO loan.loan_charge (loan_id, charge_type, assessed_on, amount, paid_amount, status, rule_set_version_id)
        VALUES (v_s.loan_id, 'SETTLEMENT_CHARGE', v_on, v_charge, v_charge, 'PAID', v_loan.rule_set_version_id)
        RETURNING id INTO v_charge_id;
        v_seq := v_seq + 1;
        INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, loan_charge_id, component, amount)
        VALUES (v_repayment, v_seq, v_charge_id, 'CHARGE', v_charge);
    END IF;
    IF v_round_up > 0 THEN
        v_seq := v_seq + 1;
        INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, component, amount)
        VALUES (v_repayment, v_seq, 'CHARGE', v_round_up);
    END IF;

    UPDATE loan.loan SET status = 'SETTLED', status_date = v_on,
           status_reason = CASE v_s.settlement_type WHEN 'DEFAULT' THEN 'Default settlement' ELSE 'Early settlement' END,
           outstanding_principal = 0, closed_on = v_on,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_s.loan_id;

    v_cool := coalesce(loan.rule(v_loan.rule_snapshot, 'COOLING_OFF_AFTER_EARLY_SETTLEMENT')->'value', '{}'::jsonb);
    IF v_s.settlement_type = 'DEFAULT' THEN
        -- default settled: default record closed, cooling-off from loans.cooling_off
        v_cool_until := loan.close_default(v_s.loan_id, p_settlement_id);
    ELSIF coalesce((v_cool->>'enabled')::boolean, false) AND coalesce((v_cool->>'months')::integer, 0) > 0 THEN
        v_cool_until := (v_on + make_interval(months => (v_cool->>'months')::integer))::date;
        UPDATE mbr.member SET loan_eligibility = 'COOLING_OFF',
               cooling_off_until = greatest(coalesce(cooling_off_until, v_cool_until), v_cool_until),
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_loan.member_id AND loan_eligibility IN ('ELIGIBLE','REINSTATED','COOLING_OFF');
        PERFORM loan.notify_member('LOAN_SETTLED', v_s.loan_id, '{}'::jsonb);
    ELSE
        PERFORM loan.notify_member('LOAN_SETTLED', v_s.loan_id, '{}'::jsonb);
    END IF;

    UPDATE loan.loan_settlement SET status = 'PAID', cash_receipt_id = v_receipt,
           components = components || jsonb_build_object('collection', jsonb_build_object(
               'repayment_id', v_repayment, 'journal_id', v_journal, 'collected_by', app.user_id(),
               'collected_on', v_on, 'collected_at', now(), 'interest_collected', v_interest,
               'charge_collected', v_charge, 'cooling_off_until', v_cool_until)),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_settlement_id;

    RETURN jsonb_build_object('settlement_id', p_settlement_id, 'loan_id', v_s.loan_id,
        'repayment_id', v_repayment, 'cash_receipt_id', v_receipt, 'journal_id', v_journal,
        'amount', v_s.total_payable, 'loan_status', 'SETTLED', 'cooling_off_until', v_cool_until,
        'status', 'PAID');
END
$$;

-- The runtime role gets EXECUTE through the default privileges set in script
-- 20; grant explicitly as well so a re-run of this file alone is enough.
GRANT EXECUTE ON FUNCTION
    loan.rule(jsonb, text),
    loan.grace_days(jsonb),
    loan.default_after_months(jsonb),
    loan.round_amount(numeric, jsonb),
    loan.get_schedule(uuid),
    loan.get_repayments(uuid),
    loan.get_member_loan_statement(uuid),
    loan.record_job_run(text, date, text, timestamptz, integer, jsonb),
    loan.record_job_failure(text, date, text, text),
    loan.run_daily_status(date, text),
    loan.calculate_early_settlement(uuid, date),
    loan.get_settlement(uuid),
    loan.list_settlements(uuid),
    loan.quote_early_settlement(uuid, numeric, text),
    loan.approve_early_settlement(uuid, text),
    loan.collect_early_settlement(uuid, text, text)
TO nvs_app;
