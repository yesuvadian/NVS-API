-- =============================================================================
-- CFMS / NVS  -  38  Disbursement (tranches, cash limit), restructuring,
--                   deceased members' loans and migrated-loan review
--                   (functional gap review, Nov 2026)
-- -----------------------------------------------------------------------------
-- Disbursement (scope 6.6, 21.6)
--   loan.prepare_disbursement(loan, gross, payment_mode 'CASH', reference)
--       A loan type with allows_tranches and rule TRANCHES {"allowed":true} can be
--       paid in several tranches; each later tranche is added to the open future
--       instalments (schedule reason TRANCHE).
--       Cash above setting cash.disbursement_limit {"amount":null,"approverRole":"LDR"}
--       needs loan.approve_cash_disbursement before release.
--   loan.release_disbursement(loan, disbursement, payee_ack_type)
--   loan.approve_cash_disbursement(disbursement, remarks)
-- Restructuring (scope 6.10; setting loans.restructuring {"allowed","maxPerLoan","maxMoratoriumMonths"})
--   loan.request_restructure(loan, details jsonb)   option, reason, new_tenure_months,
--                                                   moratorium_months, new_interest_rate
--   loan.decide_restructure(id, approve, remarks)   Manager / Leadership; applies it
--   loan.get_restructure(id), loan.list_restructures(loan)
-- Deceased member (scope 12.1, 12.2)
--   loan.record_deceased_loan_decision(loan, decision, remarks)   Manager / Leadership
--       interest stops from the verified death record; WAIVE_WRITE_OFF proposes a
--       write-off, RECOVER_FROM_GUARANTOR invokes the guarantees.
--   loan.propose_loan_transfer(loan, shares jsonb[{successor_member_id, legal_successor_id, share_percent}])
--   loan.decide_loan_transfer(loan, approve, remarks)              Manager / Leadership
-- Migrated loans (scope 39.3)
--   loan.list_migration_reviews(status), loan.decide_migration_review(id, apply_default, remarks)
-- Run as nvs. Safe to re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS loan.prepare_disbursement(uuid, numeric);

CREATE OR REPLACE FUNCTION loan.tranches_allowed(p_loan_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT lt.allows_tranches AND coalesce((loan.rule(l.rule_snapshot, 'TRANCHES')->'value'->>'allowed')::boolean, false)
      FROM loan.loan l JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id
$$;

CREATE OR REPLACE FUNCTION loan.cash_limit_needs_approval(p_payment_mode text, p_net numeric)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT p_payment_mode = 'CASH'
       AND (cfg.get_setting('cash.disbursement_limit')->>'amount') IS NOT NULL
       AND p_net > (cfg.get_setting('cash.disbursement_limit')->>'amount')::numeric
$$;

CREATE OR REPLACE FUNCTION loan.prepare_disbursement(
    p_loan_id uuid, p_gross_amount numeric(18,2), p_payment_mode text DEFAULT 'CASH', p_payment_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_fee record;
    v_cash record;
    v_voucher_id uuid;
    v_voucher_no text;
    v_disbursement_id uuid;
    v_principal_account uuid;
    v_fee_account uuid;
    v_deduction numeric(18,2) := 0;
    v_tranche integer;
    v_mode text := upper(coalesce(p_payment_mode, 'CASH'));
BEGIN
    SELECT l.id,l.loan_no,l.member_id,l.loan_type_id,l.approved_amount,l.disbursed_amount,
           l.status,m.full_name,m.mobile,lt.principal_account_id
      INTO v_loan FROM loan.loan l
      JOIN mbr.member m ON m.tenant_id=l.tenant_id AND m.id=l.member_id
      JOIN loan.loan_type lt ON lt.tenant_id=l.tenant_id AND lt.id=l.loan_type_id
     WHERE l.tenant_id=app.tenant_id() AND l.id=p_loan_id FOR UPDATE OF l;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND','Loan was not found'); END IF;
    IF v_loan.status NOT IN ('APPROVED','ACTIVE','OVERDUE','RESTRUCTURED') THEN
        PERFORM app.fail('LOAN_NOT_APPROVED','Only approved loans can be disbursed');
    END IF;
    -- the approved balance left after released and still-prepared disbursements
    IF p_gross_amount IS NULL OR p_gross_amount<=0 OR p_gross_amount>v_loan.approved_amount-v_loan.disbursed_amount
         - (SELECT coalesce(sum(gross_amount),0) FROM loan.loan_disbursement
             WHERE tenant_id=app.tenant_id() AND loan_id=p_loan_id AND status='PREPARED') THEN
        PERFORM app.fail('OVER_DISBURSEMENT','Disbursement amount exceeds the approved balance');
    END IF;
    IF (v_loan.disbursed_amount<>0 OR v_loan.status<>'APPROVED') AND NOT coalesce(loan.tranches_allowed(p_loan_id), false) THEN
        PERFORM app.fail('TRANCHE_NOT_SUPPORTED','Additional disbursement tranches are not enabled');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_disbursement WHERE tenant_id=app.tenant_id() AND loan_id=p_loan_id AND status='PREPARED') THEN
        PERFORM app.fail('DISBURSEMENT_STATE','A prepared disbursement is already waiting for release');
    END IF;
    IF v_loan.status='APPROVED' AND v_loan.disbursed_amount=0 THEN
        PERFORM loan.assert_concurrent_loan_limit(p_loan_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.payment_mode WHERE mode_code = v_mode AND is_enabled) THEN
        PERFORM app.fail('PAYMENT_MODE_DISABLED', 'The payment mode is not enabled');
    END IF;
    SELECT coalesce(max(tranche_no),0)+1 INTO v_tranche FROM loan.loan_disbursement
     WHERE tenant_id=app.tenant_id() AND loan_id=p_loan_id AND status<>'CANCELLED';
    SELECT id,fee_amount INTO v_fee FROM loan.loan_application_fee
     WHERE tenant_id=app.tenant_id() AND loan_id=p_loan_id AND status='PENDING'
       AND collect_timing='DEDUCT_FROM_DISBURSEMENT' FOR UPDATE;
    v_deduction := coalesce(v_fee.fee_amount,0);
    IF v_deduction>=p_gross_amount THEN PERFORM app.fail('FEE_EXCEEDS_DISBURSEMENT','Fee deduction must be less than gross proceeds'); END IF;
    SELECT id INTO v_cash FROM acct.cash_account
     WHERE tenant_id=app.tenant_id() AND status='ACTIVE' ORDER BY is_default DESC LIMIT 1;
    IF v_cash.id IS NULL THEN PERFORM app.fail('CASH_ACCOUNT_NOT_CONFIGURED','No active cash account is configured'); END IF;
    v_principal_account := v_loan.principal_account_id;
    IF v_principal_account IS NULL THEN
        SELECT account_id INTO v_principal_account FROM acct.account_mapping
         WHERE tenant_id=app.tenant_id() AND mapping_key='LOAN_PRINCIPAL'
           AND scope_type='LOAN_TYPE' AND scope_id=v_loan.loan_type_id
           AND effective_from<=app.working_date() ORDER BY effective_from DESC LIMIT 1;
    END IF;
    IF v_principal_account IS NULL THEN PERFORM app.fail('ACCOUNT_MAPPING_MISSING','Loan principal account is not configured'); END IF;
    v_voucher_no := acct.next_number('PAYMENT',app.working_date(),app.tenant_id());
    INSERT INTO acct.payment_voucher (voucher_no,cash_account_id,payee_type,member_id,payee_name,
        payee_mobile,amount,payment_mode,payment_reference,purpose,source_module,source_entity_type,source_entity_id,
        idempotency_key)
    VALUES (v_voucher_no,v_cash.id,'MEMBER',v_loan.member_id,v_loan.full_name,v_loan.mobile,
        p_gross_amount-v_deduction,v_mode,p_payment_reference,'LOAN_DISBURSEMENT','LOAN','loan.loan',p_loan_id,
        core.current_idempotency_key())
    RETURNING id INTO v_voucher_id;
    INSERT INTO acct.payment_voucher_line (payment_voucher_id,line_no,component,amount,account_id)
    VALUES (v_voucher_id,1,'LOAN_PRINCIPAL',p_gross_amount,v_principal_account);
    IF v_deduction>0 THEN
        SELECT account_id INTO v_fee_account FROM acct.account_mapping
         WHERE tenant_id=app.tenant_id() AND mapping_key='APPLICATION_FEE'
           AND scope_type='NONE' AND scope_id IS NULL AND effective_from<=app.working_date()
         ORDER BY effective_from DESC LIMIT 1;
        IF v_fee_account IS NULL THEN PERFORM app.fail('ACCOUNT_MAPPING_MISSING','Application fee account is not configured'); END IF;
        INSERT INTO acct.payment_voucher_line (payment_voucher_id,line_no,component,amount,account_id)
        VALUES (v_voucher_id,2,'APPLICATION_FEE',-v_deduction,v_fee_account);
    END IF;
    INSERT INTO loan.loan_disbursement (loan_id,tranche_no,value_date,gross_amount,deductions,payment_voucher_id)
    VALUES (p_loan_id,v_tranche,app.working_date(),p_gross_amount,v_deduction,v_voucher_id)
    RETURNING id INTO v_disbursement_id;
    RETURN jsonb_build_object('disbursement_id',v_disbursement_id,'voucher_id',v_voucher_id,
        'voucher_no',v_voucher_no,'tranche_no',v_tranche,'gross_amount',p_gross_amount,'deductions',v_deduction,
        'net_amount',p_gross_amount-v_deduction,'payment_mode',v_mode,'status','PREPARED',
        'cash_limit_approval_required',loan.cash_limit_needs_approval(v_mode,p_gross_amount-v_deduction));
END
$$;

CREATE OR REPLACE FUNCTION loan.approve_cash_disbursement(p_disbursement_id uuid, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_d record;
BEGIN
    SELECT d.id, d.status, d.prepared_by, d.created_by, v.payment_mode, v.amount INTO v_d
      FROM loan.loan_disbursement d JOIN acct.payment_voucher v ON v.tenant_id = d.tenant_id AND v.id = d.payment_voucher_id
     WHERE d.tenant_id = app.tenant_id() AND d.id = p_disbursement_id FOR UPDATE OF d;
    IF NOT FOUND THEN PERFORM app.fail('DISBURSEMENT_NOT_FOUND','Prepared disbursement was not found'); END IF;
    IF v_d.status <> 'PREPARED' THEN PERFORM app.fail('DISBURSEMENT_STATE','Disbursement is not awaiting release'); END IF;
    IF NOT loan.cash_limit_needs_approval(v_d.payment_mode, v_d.amount) THEN
        PERFORM app.fail('CASH_LIMIT_APPROVAL_NOT_NEEDED', 'This disbursement is within the cash limit.');
    END IF;
    PERFORM loan.assert_approver(coalesce(cfg.get_setting('cash.disbursement_limit')->>'approverRole', 'LDR'),
                                 coalesce(v_d.prepared_by, v_d.created_by));
    UPDATE loan.loan_disbursement SET cash_limit_approved_by = app.user_id(), cash_limit_approved_at = now(),
           cash_limit_remarks = p_remarks, updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_disbursement_id;
    RETURN jsonb_build_object('disbursement_id', p_disbursement_id, 'cash_limit_approved_by', app.user_id());
END
$$;

CREATE OR REPLACE FUNCTION loan.release_disbursement(
    p_loan_id uuid,p_disbursement_id uuid,p_payee_ack_type text
)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_data record;
    v_cash_account uuid;
    v_principal_account uuid;
    v_fee_account uuid;
    v_journal_id uuid;
    v_schedule_id uuid;
    v_interest numeric(18,2);
    v_interest_each numeric(18,2);
    v_principal_each numeric(18,2);
    v_principal_due numeric(18,2);
    v_interest_due numeric(18,2);
    v_dates date[];
    v_future_principal numeric(18,2);
    v_future_interest numeric(18,2);
    i integer;
BEGIN
    IF p_payee_ack_type NOT IN ('SIGNATURE','THUMB_IMPRESSION') THEN
        PERFORM app.fail('PAYEE_ACK_REQUIRED','A supported payee acknowledgement is required');
    END IF;
    SELECT d.id,d.status disbursement_status,d.gross_amount,d.deductions,d.value_date,d.tranche_no,d.cash_limit_approved_by,
           v.id voucher_id,v.amount net_amount,v.cash_account_id,v.prepared_by,v.member_id,v.payment_mode,
           l.loan_no,l.status loan_status,l.approved_amount,l.tenure_months,l.total_interest,l.interest_rate_annual,
           l.rule_set_version_id,l.loan_type_id,lt.principal_account_id
      INTO v_data FROM loan.loan_disbursement d
      JOIN acct.payment_voucher v ON v.tenant_id=d.tenant_id AND v.id=d.payment_voucher_id
      JOIN loan.loan l ON l.tenant_id=d.tenant_id AND l.id=d.loan_id
      JOIN loan.loan_type lt ON lt.tenant_id=l.tenant_id AND lt.id=l.loan_type_id
     WHERE d.tenant_id=app.tenant_id() AND d.loan_id=p_loan_id AND d.id=p_disbursement_id
     FOR UPDATE OF d,v,l;
    IF NOT FOUND THEN PERFORM app.fail('DISBURSEMENT_NOT_FOUND','Prepared disbursement was not found'); END IF;
    IF v_data.disbursement_status<>'PREPARED' THEN PERFORM app.fail('DISBURSEMENT_STATE','Disbursement is not awaiting release'); END IF;
    IF loan.cash_limit_needs_approval(v_data.payment_mode, v_data.net_amount) AND v_data.cash_limit_approved_by IS NULL THEN
        PERFORM app.fail('CASH_LIMIT_APPROVAL_REQUIRED', 'Cash above the limit needs approval before it is paid.');
    END IF;
    SELECT account_id INTO v_cash_account FROM acct.cash_account
     WHERE tenant_id=app.tenant_id() AND id=v_data.cash_account_id AND status='ACTIVE';
    v_principal_account := v_data.principal_account_id;
    IF v_principal_account IS NULL THEN
        SELECT account_id INTO v_principal_account FROM acct.account_mapping
         WHERE tenant_id=app.tenant_id() AND mapping_key='LOAN_PRINCIPAL'
           AND scope_type='LOAN_TYPE' AND scope_id=v_data.loan_type_id
           AND effective_from<=app.working_date() ORDER BY effective_from DESC LIMIT 1;
    END IF;
    INSERT INTO acct.journal (voucher_type,value_date,status,narration,total_amount,
        source_module,source_entity_type,source_entity_id,source_ref)
    VALUES ('JOURNAL',v_data.value_date,'POSTED','Loan disbursement '||v_data.loan_no,
        v_data.gross_amount,'LOAN','acct.payment_voucher',v_data.voucher_id,v_data.voucher_id::text)
    RETURNING id INTO v_journal_id;
    INSERT INTO acct.journal_line (journal_id,line_no,account_id,debit,credit,narration,member_id,sub_entity_type,sub_entity_id)
    VALUES (v_journal_id,1,v_principal_account,v_data.gross_amount,0,'Loan principal disbursed',v_data.member_id,'loan.loan',p_loan_id),
           (v_journal_id,2,v_cash_account,0,v_data.net_amount,'Loan cash paid',v_data.member_id,'loan.loan',p_loan_id);
    IF v_data.deductions>0 THEN
        SELECT account_id INTO v_fee_account FROM acct.account_mapping
         WHERE tenant_id=app.tenant_id() AND mapping_key='APPLICATION_FEE'
           AND scope_type='NONE' AND scope_id IS NULL AND effective_from<=app.working_date()
         ORDER BY effective_from DESC LIMIT 1;
        INSERT INTO acct.journal_line (journal_id,line_no,account_id,debit,credit,narration,member_id,sub_entity_type,sub_entity_id)
        VALUES (v_journal_id,3,v_fee_account,0,v_data.deductions,'Fee deducted at disbursement',v_data.member_id,'loan.loan',p_loan_id);
        UPDATE loan.loan_application_fee SET status='DEDUCTED',updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
         WHERE tenant_id=app.tenant_id() AND loan_id=p_loan_id AND status='PENDING' AND collect_timing='DEDUCT_FROM_DISBURSEMENT';
    END IF;
    UPDATE acct.payment_voucher SET status='PAID',released_by=app.user_id(),released_at=now(),
        payee_ack_type=p_payee_ack_type,journal_id=v_journal_id,updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
     WHERE tenant_id=app.tenant_id() AND id=v_data.voucher_id;
    UPDATE loan.loan_disbursement SET status='PAID',released_by=app.user_id(),updated_at=now(),
        updated_by=app.user_id(),row_version=row_version+1
     WHERE tenant_id=app.tenant_id() AND id=p_disbursement_id;

    IF v_data.loan_status = 'APPROVED' THEN
        -- First (or only) disbursement: the original schedule on the amount paid.
        v_interest := CASE WHEN v_data.gross_amount = v_data.approved_amount THEN coalesce(v_data.total_interest,0)
                           ELSE round(v_data.gross_amount*coalesce(v_data.interest_rate_annual,0)*v_data.tenure_months/1200,2) END;
        v_interest_each := round(v_interest/v_data.tenure_months,2);
        v_principal_each := round(v_data.gross_amount/v_data.tenure_months,2);
        INSERT INTO loan.loan_schedule (loan_id,schedule_version,reason,effective_from,principal_basis,
            interest_rate_annual,total_interest,total_repayable,rule_set_version_id)
        VALUES (p_loan_id,1,'ORIGINAL',app.working_date(),v_data.gross_amount,
            v_data.interest_rate_annual,v_interest,v_data.gross_amount+v_interest,v_data.rule_set_version_id)
        RETURNING id INTO v_schedule_id;
        FOR i IN 1..v_data.tenure_months LOOP
            v_principal_due := CASE WHEN i=v_data.tenure_months
                THEN v_data.gross_amount-v_principal_each*(v_data.tenure_months-1) ELSE v_principal_each END;
            v_interest_due := CASE WHEN i=v_data.tenure_months
                THEN v_interest-v_interest_each*(v_data.tenure_months-1) ELSE v_interest_each END;
            INSERT INTO loan.loan_instalment (loan_schedule_id,loan_id,instalment_no,due_date,principal_due,interest_due)
            VALUES (v_schedule_id,p_loan_id,i,(app.working_date()+make_interval(months=>i))::date,v_principal_due,v_interest_due);
        END LOOP;
        UPDATE loan.loan SET status='ACTIVE',status_date=app.working_date(),disbursed_amount=v_data.gross_amount,
            total_interest=v_interest,instalment_amount=v_principal_each+v_interest_each,
            first_disbursement_date=app.working_date(),first_due_date=(app.working_date()+interval '1 month')::date,
            maturity_date=(app.working_date()+make_interval(months=>v_data.tenure_months))::date,
            outstanding_principal=v_data.gross_amount,updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
         WHERE tenant_id=app.tenant_id() AND id=p_loan_id;
    ELSE
        -- Later tranche: spread over the open future instalments, interest for their months.
        SELECT array_agg(i.due_date ORDER BY i.due_date, i.instalment_no),
               coalesce(sum(i.principal_due), 0), coalesce(sum(i.interest_due), 0)
          INTO v_dates, v_future_principal, v_future_interest
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id
           AND i.status = 'DUE' AND i.principal_paid = 0 AND i.interest_paid = 0 AND i.due_date > app.working_date();
        IF v_dates IS NULL THEN
            PERFORM app.fail('TRANCHE_AFTER_LAST_INSTALMENT', 'No future instalment is left to add the tranche to.');
        END IF;
        v_interest := round(v_data.gross_amount*coalesce(v_data.interest_rate_annual,0)*array_length(v_dates,1)/1200,2);
        v_schedule_id := loan.rebuild_schedule(p_loan_id, 'TRANCHE', v_future_principal + v_data.gross_amount,
                                               v_future_interest + v_interest, v_dates);
        UPDATE loan.loan SET disbursed_amount=disbursed_amount+v_data.gross_amount,
            outstanding_principal=outstanding_principal+v_data.gross_amount,
            total_interest=coalesce(total_interest,0)+v_interest,
            updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
         WHERE tenant_id=app.tenant_id() AND id=p_loan_id;
    END IF;
    RETURN jsonb_build_object('loan_id',p_loan_id,'disbursement_id',p_disbursement_id,'tranche_no',v_data.tranche_no,
        'journal_id',v_journal_id,'schedule_id',v_schedule_id,'status','PAID');
END
$$;

-- -----------------------------------------------------------------------------
-- Restructuring
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.get_restructure(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT (to_jsonb(r) - 'tenant_id') || jsonb_build_object('loan_no', l.loan_no, 'loan_status', l.status)
      FROM loan.loan_restructure r JOIN loan.loan l ON l.tenant_id = r.tenant_id AND l.id = r.loan_id
     WHERE r.tenant_id = app.tenant_id() AND r.id = p_id
$$;

CREATE OR REPLACE FUNCTION loan.list_restructures(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg(loan.get_restructure(r.id) ORDER BY r.created_at DESC), '[]'::jsonb)
      FROM loan.loan_restructure r WHERE r.tenant_id = app.tenant_id() AND r.loan_id = p_loan_id
$$;

CREATE OR REPLACE FUNCTION loan.request_restructure(p_loan_id uuid, p_details jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_cfg jsonb := coalesce(cfg.get_setting('loans.restructuring'), '{"allowed":true,"maxPerLoan":1,"maxMoratoriumMonths":3}'::jsonb);
    v_option text := upper(coalesce(p_details->>'option', ''));
    v_moratorium integer := coalesce(nullif(p_details->>'moratorium_months', '')::integer, 0);
    v_open integer;
    v_tenure integer;
    v_id uuid;
BEGIN
    IF coalesce(btrim(p_details->>'reason'), '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'Enter the reason for restructuring the loan.');
    END IF;
    SELECT id, status, restructure_count, rule_set_version_id INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    IF NOT coalesce((v_cfg->>'allowed')::boolean, true) OR v_loan.status NOT IN ('ACTIVE','OVERDUE','RESTRUCTURED') THEN
        PERFORM app.fail('RESTRUCTURE_NOT_ALLOWED', 'This loan cannot be restructured.');
    END IF;
    IF v_loan.restructure_count >= coalesce((v_cfg->>'maxPerLoan')::integer, 1) THEN
        PERFORM app.fail('RESTRUCTURE_LIMIT_REACHED', 'The loan has been restructured the maximum number of times.');
    END IF;
    IF v_option NOT IN ('EXTEND_TENURE','REDUCE_INSTALMENT','MORATORIUM','CAPITALISE_OVERDUE','COMBINATION') THEN
        PERFORM app.fail('INVALID_RESTRUCTURE_TERMS', 'Choose a restructuring option.');
    END IF;
    IF v_moratorium < 0 OR v_moratorium > coalesce((v_cfg->>'maxMoratoriumMonths')::integer, 3)
       OR (v_option = 'MORATORIUM' AND v_moratorium = 0) THEN
        PERFORM app.fail('INVALID_RESTRUCTURE_TERMS', 'The moratorium is outside the allowed months.');
    END IF;
    SELECT count(*) INTO v_open FROM loan.loan_instalment i
      JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
     WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID');
    v_tenure := coalesce(nullif(p_details->>'new_tenure_months', '')::integer, v_open);
    IF v_tenure <= 0 OR (v_option IN ('EXTEND_TENURE','REDUCE_INSTALMENT') AND v_tenure <= v_open) THEN
        PERFORM app.fail('INVALID_RESTRUCTURE_TERMS', 'The new tenure must be longer than the instalments still open.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_restructure WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'REQUESTED') THEN
        PERFORM app.fail('RESTRUCTURE_ALREADY_PENDING', 'A restructure of this loan is already waiting for a decision.');
    END IF;
    INSERT INTO loan.loan_restructure (loan_id, request_date, reason, restructure_option, moratorium_months,
                                       new_tenure_months, new_interest_rate, status, rule_set_version_id)
    VALUES (p_loan_id, app.working_date(), p_details->>'reason', v_option, v_moratorium, v_tenure,
            nullif(p_details->>'new_interest_rate', '')::numeric, 'REQUESTED', v_loan.rule_set_version_id)
    RETURNING id INTO v_id;
    RETURN loan.get_restructure(v_id);
END
$$;

-- Apply: paid instalments stay; whatever is still open (principal, and the open
-- interest of instalments already due) goes into a new schedule of
-- new_tenure_months starting after the moratorium. CAPITALISE_OVERDUE (and
-- COMBINATION) turn the overdue interest into principal; otherwise it is spread
-- as interest. Interest on the principal runs at the new rate (or the loan's)
-- for the moratorium and the new tenure.
CREATE OR REPLACE FUNCTION loan.apply_restructure(p_id uuid)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_r loan.loan_restructure%ROWTYPE;
    v_loan record;
    v_old uuid;
    v_new uuid;
    v_on date := app.working_date();
    v_principal numeric(18,2);
    v_overdue_interest numeric(18,2);
    v_rate numeric(7,4);
    v_interest numeric(18,2);
    v_capital numeric(18,2) := 0;
    v_next integer;
    v_day date;
    v_p_each numeric(18,2);
    v_i_each numeric(18,2);
    v_kept_total numeric(18,2);
    v_kept_interest numeric(18,2);
    i integer;
BEGIN
    SELECT * INTO v_r FROM loan.loan_restructure WHERE tenant_id = app.tenant_id() AND id = p_id;
    SELECT id, outstanding_principal, interest_rate_annual, first_due_date INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = v_r.loan_id FOR UPDATE;
    SELECT id INTO v_old FROM loan.loan_schedule WHERE tenant_id = app.tenant_id() AND loan_id = v_loan.id AND is_current FOR UPDATE;
    SELECT coalesce(sum(i.interest_due - i.interest_paid), 0) INTO v_overdue_interest
      FROM loan.loan_instalment i
     WHERE i.tenant_id = app.tenant_id() AND i.loan_schedule_id = v_old AND i.status IN ('DUE','PARTLY_PAID') AND i.due_date <= v_on;
    v_principal := v_loan.outstanding_principal;
    IF v_r.restructure_option IN ('CAPITALISE_OVERDUE','COMBINATION') THEN
        v_capital := v_overdue_interest;
        v_principal := v_principal + v_capital;
        v_overdue_interest := 0;
    END IF;
    v_rate := coalesce(v_r.new_interest_rate, v_loan.interest_rate_annual, 0);
    v_interest := v_overdue_interest
                  + round(v_principal * v_rate / 100 * (v_r.new_tenure_months + v_r.moratorium_months) / 12, 2);

    UPDATE loan.loan_schedule SET is_current = false, updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_old;
    -- Kept rows: fully settled ones as they are; part-paid ones reduced to what was paid.
    SELECT coalesce(sum(CASE WHEN status IN ('DUE','PARTLY_PAID') THEN principal_paid + interest_paid ELSE principal_due + interest_due END), 0),
           coalesce(sum(CASE WHEN status IN ('DUE','PARTLY_PAID') THEN interest_paid ELSE interest_due END), 0),
           coalesce(max(instalment_no) FILTER (WHERE status NOT IN ('DUE') OR principal_paid + interest_paid > 0), 0)
      INTO v_kept_total, v_kept_interest, v_next
      FROM loan.loan_instalment
     WHERE tenant_id = app.tenant_id() AND loan_schedule_id = v_old AND (status <> 'DUE' OR principal_paid + interest_paid > 0);
    INSERT INTO loan.loan_schedule (loan_id, schedule_version, reason, is_current, effective_from, principal_basis,
                                    interest_rate_annual, total_interest, total_repayable, rounding_rule,
                                    rule_set_version_id, previous_schedule_id)
    SELECT v_loan.id, max(schedule_version) + 1, 'RESTRUCTURE', true, v_on, v_principal, v_rate,
           v_kept_interest + v_interest, v_kept_total + v_principal + v_interest, NULL, v_r.rule_set_version_id, v_old
      FROM loan.loan_schedule WHERE tenant_id = app.tenant_id() AND loan_id = v_loan.id
    RETURNING id INTO v_new;
    INSERT INTO loan.loan_instalment (loan_schedule_id, loan_id, instalment_no, due_date, principal_due, interest_due,
                                      rounding_adjustment, principal_paid, interest_paid, late_fee_assessed, late_fee_paid, status, paid_on)
    SELECT v_new, loan_id, instalment_no, due_date,
           CASE WHEN status IN ('DUE','PARTLY_PAID') THEN principal_paid ELSE principal_due END,
           CASE WHEN status IN ('DUE','PARTLY_PAID') THEN interest_paid ELSE interest_due END,
           rounding_adjustment, principal_paid, interest_paid, late_fee_assessed, late_fee_paid,
           CASE WHEN status IN ('DUE','PARTLY_PAID') THEN 'PAID' ELSE status END,
           CASE WHEN status IN ('DUE','PARTLY_PAID') THEN v_on ELSE paid_on END
      FROM loan.loan_instalment
     WHERE tenant_id = app.tenant_id() AND loan_schedule_id = v_old AND (status <> 'DUE' OR principal_paid + interest_paid > 0)
     ORDER BY instalment_no;
    v_day := (v_on + make_interval(months => v_r.moratorium_months))::date;
    v_p_each := round(v_principal / v_r.new_tenure_months, 2);
    v_i_each := round(v_interest / v_r.new_tenure_months, 2);
    FOR i IN 1..v_r.new_tenure_months LOOP
        INSERT INTO loan.loan_instalment (loan_schedule_id, loan_id, instalment_no, due_date, principal_due, interest_due)
        VALUES (v_new, v_loan.id, v_next + i, (v_day + make_interval(months => i))::date,
                CASE WHEN i = v_r.new_tenure_months THEN v_principal - v_p_each * (v_r.new_tenure_months - 1) ELSE v_p_each END,
                CASE WHEN i = v_r.new_tenure_months THEN v_interest - v_i_each * (v_r.new_tenure_months - 1) ELSE v_i_each END);
    END LOOP;
    UPDATE loan.loan SET status = 'RESTRUCTURED', status_date = v_on, status_reason = 'Restructured: ' || v_r.reason,
           is_restructured = true, restructure_count = restructure_count + 1, interest_rate_annual = v_rate,
           outstanding_principal = v_principal, instalment_amount = v_p_each + v_i_each,
           maturity_date = (v_day + make_interval(months => v_r.new_tenure_months))::date,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_loan.id;
    UPDATE loan.loan_restructure SET status = 'APPLIED', old_schedule_id = v_old, new_schedule_id = v_new,
           capitalised_amount = v_capital
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    RETURN v_new;
END
$$;

CREATE OR REPLACE FUNCTION loan.decide_restructure(p_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_r loan.loan_restructure%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM loan.loan_restructure WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('RESTRUCTURE_NOT_FOUND', 'The restructure request was not found.'); END IF;
    IF v_r.status <> 'REQUESTED' THEN PERFORM app.fail('REQUEST_CLOSED', 'The request is no longer pending'); END IF;
    PERFORM loan.assert_approver('MGR,LDR', coalesce(v_r.requested_by, v_r.created_by));
    IF NOT p_approve AND coalesce(btrim(p_remarks), '') = '' THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject the request.');
    END IF;
    UPDATE loan.loan_restructure SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
           decided_by = app.user_id(), decided_on = app.working_date(), decision_remarks = p_remarks,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    IF p_approve THEN
        PERFORM loan.apply_restructure(p_id);
    END IF;
    RETURN loan.get_restructure(p_id);
END
$$;

-- -----------------------------------------------------------------------------
-- Deceased member's loan
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.record_deceased_loan_decision(p_loan_id uuid, p_decision text, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_death record;
    v_stop date;
    v_id uuid;
    v_dates date[];
    v_principal numeric(18,2);
    v_write_off jsonb;
BEGIN
    PERFORM loan.assert_approver('MGR,LDR', NULL);
    SELECT l.id, l.status, l.member_id, l.interest_stopped_from INTO v_loan FROM loan.loan l
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND NOT l.is_deleted FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    IF v_loan.status NOT IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED') THEN
        PERFORM app.fail('LOAN_NOT_OPEN', 'Loan is not open');
    END IF;
    SELECT id, date_of_death, interest_stops_from INTO v_death FROM mbr.death_record
     WHERE tenant_id = app.tenant_id() AND member_id = v_loan.member_id AND status = 'VERIFIED'
     ORDER BY created_at DESC LIMIT 1;
    IF NOT FOUND THEN
        PERFORM app.fail('DEATH_NOT_VERIFIED', 'The member''s death must be verified before deciding on the loan.');
    END IF;
    IF upper(p_decision) NOT IN ('RECOVER_FROM_SUCCESSOR','RECOVER_FROM_GUARANTOR','SET_OFF_DEPOSITS_CHIT','WAIVE_WRITE_OFF','TRANSFER') THEN
        PERFORM app.fail('INVALID_DECEASED_DECISION', 'Choose how the loan will be handled.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.deceased_loan_decision WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id) THEN
        PERFORM app.fail('DECEASED_DECISION_EXISTS', 'A decision for this loan is already recorded.');
    END IF;
    v_stop := coalesce(v_death.interest_stops_from, v_death.date_of_death);
    INSERT INTO loan.deceased_loan_decision (loan_id, death_record_id, decision, interest_stops_from, remarks)
    VALUES (p_loan_id, v_death.id, upper(p_decision), v_stop, p_remarks) RETURNING id INTO v_id;

    -- Interest stops: the open future instalments keep their principal, interest 0.
    IF v_loan.interest_stopped_from IS NULL THEN
        SELECT array_agg(i.due_date ORDER BY i.due_date, i.instalment_no), coalesce(sum(i.principal_due), 0)
          INTO v_dates, v_principal
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id
           AND i.status = 'DUE' AND i.principal_paid = 0 AND i.interest_paid = 0 AND i.due_date > app.working_date();
        IF v_dates IS NOT NULL THEN
            PERFORM loan.rebuild_schedule(p_loan_id, 'DECEASED', v_principal, 0, v_dates);
        END IF;
        UPDATE loan.loan SET interest_stopped_from = v_stop,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    END IF;
    IF upper(p_decision) = 'RECOVER_FROM_GUARANTOR' THEN
        UPDATE loan.loan_guarantor SET status = 'INVOKED', updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'ACTIVE';
        PERFORM loan.notify_guarantors('GUARANTOR_DEFAULT_NOTICE', p_loan_id, '{}'::jsonb);
    ELSIF upper(p_decision) = 'WAIVE_WRITE_OFF' THEN
        v_write_off := loan.propose_write_off(p_loan_id, coalesce(p_remarks, 'Deceased member: waive and write off'));
    END IF;
    RETURN jsonb_build_object('id', v_id, 'loan_id', p_loan_id, 'decision', upper(p_decision),
                              'interest_stops_from', v_stop, 'write_off', v_write_off);
END
$$;

CREATE OR REPLACE FUNCTION loan.list_loan_transfers(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg((to_jsonb(t) - 'tenant_id') || jsonb_build_object('successor_name', m.full_name,
                                                                              'successor_loan_no', s.loan_no)
                              ORDER BY t.created_at), '[]'::jsonb)
      FROM loan.loan_transfer t
      JOIN mbr.member m ON m.tenant_id = t.tenant_id AND m.id = t.successor_member_id
      LEFT JOIN loan.loan s ON s.tenant_id = t.tenant_id AND s.id = t.successor_loan_id
     WHERE t.tenant_id = app.tenant_id() AND t.original_loan_id = p_loan_id
$$;

-- Shares of the outstanding principal to the children (successors who are
-- Active members). The shares add up to 100 %.
CREATE OR REPLACE FUNCTION loan.propose_loan_transfer(p_loan_id uuid, p_shares jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_share jsonb;
    v_total numeric := 0;
    v_amount numeric(18,2);
    v_left numeric(18,2);
    v_n integer;
    v_i integer := 0;
BEGIN
    SELECT l.id, l.member_id, l.outstanding_principal INTO v_loan FROM loan.loan l
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    IF NOT EXISTS (SELECT 1 FROM loan.deceased_loan_decision WHERE tenant_id = app.tenant_id()
                      AND loan_id = p_loan_id AND decision = 'TRANSFER') THEN
        PERFORM app.fail('TRANSFER_NOT_DECIDED', 'The Manager must first decide to transfer this loan.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_transfer WHERE tenant_id = app.tenant_id() AND original_loan_id = p_loan_id
                  AND status IN ('PROPOSED','APPROVED','COMPLETED')) THEN
        PERFORM app.fail('TRANSFER_ALREADY_PROPOSED', 'A transfer of this loan is already proposed.');
    END IF;
    IF jsonb_typeof(p_shares) <> 'array' OR jsonb_array_length(p_shares) = 0 THEN
        PERFORM app.fail('INVALID_TRANSFER_SHARES', 'Give at least one successor and share.');
    END IF;
    SELECT coalesce(sum((x->>'share_percent')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_shares) x;
    IF v_total <> 100 THEN
        PERFORM app.fail('INVALID_TRANSFER_SHARES', 'The shares must add up to 100 %.');
    END IF;
    v_n := jsonb_array_length(p_shares);
    v_left := v_loan.outstanding_principal;
    FOR v_share IN SELECT value FROM jsonb_array_elements(p_shares) LOOP
        v_i := v_i + 1;
        IF NOT EXISTS (SELECT 1 FROM mbr.member WHERE tenant_id = app.tenant_id() AND id = (v_share->>'successor_member_id')::uuid
                          AND status = 'ACTIVE' AND id <> v_loan.member_id) THEN
            PERFORM app.fail('SUCCESSOR_NOT_MEMBER', 'Each successor must be an active member.');
        END IF;
        v_amount := CASE WHEN v_i = v_n THEN v_left
                         ELSE round(v_loan.outstanding_principal * (v_share->>'share_percent')::numeric / 100, 2) END;
        v_left := v_left - v_amount;
        INSERT INTO loan.loan_transfer (original_loan_id, legal_successor_id, successor_member_id, share_percent,
                                        transferred_principal, consent_document_id, legal_verification_document_id, status)
        VALUES (p_loan_id, nullif(v_share->>'legal_successor_id', '')::uuid, (v_share->>'successor_member_id')::uuid,
                (v_share->>'share_percent')::numeric, v_amount, nullif(v_share->>'consent_document_id', '')::uuid,
                nullif(v_share->>'legal_verification_document_id', '')::uuid, 'PROPOSED');
    END LOOP;
    RETURN loan.list_loan_transfers(p_loan_id);
END
$$;

-- Approve: each successor gets a new ACTIVE loan (parent_loan_id = the original)
-- for their share, over the instalments still open, at the original rate from
-- the transfer date; the original loan becomes TRANSFERRED.
CREATE OR REPLACE FUNCTION loan.decide_loan_transfer(p_loan_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan loan.loan%ROWTYPE;
    v_t record;
    v_requested_by uuid;
    v_n integer;
    v_new uuid;
    v_schedule uuid;
    v_interest numeric(18,2);
    v_p_each numeric(18,2);
    v_i_each numeric(18,2);
    i integer;
BEGIN
    SELECT * INTO v_loan FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    SELECT max(requested_by::text)::uuid INTO v_requested_by FROM loan.loan_transfer
     WHERE tenant_id = app.tenant_id() AND original_loan_id = p_loan_id AND status = 'PROPOSED';
    IF NOT FOUND OR v_requested_by IS NULL THEN
        PERFORM app.fail('TRANSFER_NOT_FOUND', 'No proposed transfer was found for this loan.');
    END IF;
    PERFORM loan.assert_approver('MGR,LDR', v_requested_by);
    IF NOT p_approve THEN
        IF coalesce(btrim(p_remarks), '') = '' THEN
            PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject the request.');
        END IF;
        UPDATE loan.loan_transfer SET status = 'REJECTED', decided_by = app.user_id(), decided_on = app.working_date(),
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND original_loan_id = p_loan_id AND status = 'PROPOSED';
        RETURN loan.list_loan_transfers(p_loan_id);
    END IF;
    SELECT count(*) INTO v_n FROM loan.loan_instalment i
      JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
     WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID');
    v_n := greatest(v_n, 1);
    FOR v_t IN SELECT * FROM loan.loan_transfer WHERE tenant_id = app.tenant_id() AND original_loan_id = p_loan_id
                   AND status = 'PROPOSED' ORDER BY created_at, id FOR UPDATE
    LOOP
        v_interest := round(v_t.transferred_principal * coalesce(v_loan.interest_rate_annual, 0) * v_n / 1200, 2);
        v_p_each := round(v_t.transferred_principal / v_n, 2);
        v_i_each := round(v_interest / v_n, 2);
        INSERT INTO loan.loan (loan_no, member_id, loan_type_id, purpose, requested_amount, requested_tenure_months,
                               application_date, status, status_date, status_reason, is_first_loan, approved_amount,
                               tenure_months, interest_rate_annual, interest_method, total_interest, instalment_amount,
                               early_settlement_policy, approved_at, approved_by, disbursed_amount, first_disbursement_date,
                               first_due_date, maturity_date, outstanding_principal, parent_loan_id, rule_set_version_id,
                               rule_snapshot, workflow_version_id, created_by_employee)
        VALUES (acct.next_number('LOAN', app.working_date(), app.tenant_id()), v_t.successor_member_id, v_loan.loan_type_id,
                'Transferred from ' || v_loan.loan_no, v_t.transferred_principal, v_n, app.working_date(), 'ACTIVE',
                app.working_date(), 'Transferred from deceased member''s loan ' || v_loan.loan_no, false,
                v_t.transferred_principal, v_n, v_loan.interest_rate_annual, v_loan.interest_method, v_interest,
                v_p_each + v_i_each, v_loan.early_settlement_policy, now(), app.user_id(), v_t.transferred_principal,
                app.working_date(), (app.working_date() + interval '1 month')::date,
                (app.working_date() + make_interval(months => v_n))::date, v_t.transferred_principal, p_loan_id,
                v_loan.rule_set_version_id, v_loan.rule_snapshot, v_loan.workflow_version_id, v_requested_by)
        RETURNING id INTO v_new;
        INSERT INTO loan.loan_schedule (loan_id, schedule_version, reason, effective_from, principal_basis, interest_rate_annual,
                                        total_interest, total_repayable, rule_set_version_id)
        VALUES (v_new, 1, 'TRANSFER', app.working_date(), v_t.transferred_principal, v_loan.interest_rate_annual,
                v_interest, v_t.transferred_principal + v_interest, v_loan.rule_set_version_id)
        RETURNING id INTO v_schedule;
        FOR i IN 1..v_n LOOP
            INSERT INTO loan.loan_instalment (loan_schedule_id, loan_id, instalment_no, due_date, principal_due, interest_due)
            VALUES (v_schedule, v_new, i, (app.working_date() + make_interval(months => i))::date,
                    CASE WHEN i = v_n THEN v_t.transferred_principal - v_p_each * (v_n - 1) ELSE v_p_each END,
                    CASE WHEN i = v_n THEN v_interest - v_i_each * (v_n - 1) ELSE v_i_each END);
        END LOOP;
        UPDATE loan.loan_transfer SET status = 'COMPLETED', successor_loan_id = v_new, decided_by = app.user_id(),
               decided_on = app.working_date(), updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_t.id;
    END LOOP;
    -- Close the original: open instalments cancelled, balance moved to the successors.
    UPDATE loan.loan_instalment i SET status = 'CANCELLED', updated_at = now(), updated_by = app.user_id(), row_version = i.row_version + 1
      FROM loan.loan_schedule s
     WHERE s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
       AND i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID');
    UPDATE loan.loan SET status = 'TRANSFERRED', status_date = app.working_date(), status_reason = 'Transferred to successors',
           outstanding_principal = 0, closed_on = app.working_date(),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    UPDATE loan.loan_guarantor SET status = 'RELEASED', released_on = app.working_date(),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status IN ('ACTIVE','INVOKED');
    RETURN loan.list_loan_transfers(p_loan_id);
END
$$;

-- -----------------------------------------------------------------------------
-- Migrated loans listed for review by the daily job
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.list_migration_reviews(p_status text DEFAULT 'OPEN')
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg((to_jsonb(r) - 'tenant_id') || jsonb_build_object('loan_no', l.loan_no, 'legacy_ref', l.legacy_ref,
                                                                              'member_name', m.full_name, 'loan_status', l.status)
                              ORDER BY r.listed_on, l.loan_no), '[]'::jsonb)
      FROM loan.migration_default_review r
      JOIN loan.loan l ON l.tenant_id = r.tenant_id AND l.id = r.loan_id
      JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
     WHERE r.tenant_id = app.tenant_id() AND (p_status IS NULL OR r.status = p_status)
$$;

-- apply_default true: the next daily run defaults the loan as usual;
-- false: dues from before go-live never default it (they stay overdue).
CREATE OR REPLACE FUNCTION loan.decide_migration_review(p_id uuid, p_apply_default boolean, p_remarks text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_status text;
BEGIN
    PERFORM loan.assert_approver('MGR,LDR', NULL);
    IF coalesce(btrim(p_remarks), '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'Enter the reason for the decision.');
    END IF;
    SELECT status INTO v_status FROM loan.migration_default_review WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('MIGRATION_REVIEW_NOT_FOUND', 'The review item was not found.'); END IF;
    IF v_status <> 'OPEN' THEN PERFORM app.fail('REQUEST_CLOSED', 'The request is no longer pending'); END IF;
    UPDATE loan.migration_default_review
       SET status = CASE WHEN p_apply_default THEN 'DEFAULT_APPLIED' ELSE 'DISMISSED' END,
           decided_by = app.user_id(), decided_at = now(), remarks = p_remarks,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    RETURN (SELECT to_jsonb(r) - 'tenant_id' FROM loan.migration_default_review r WHERE r.tenant_id = app.tenant_id() AND r.id = p_id);
END
$$;
