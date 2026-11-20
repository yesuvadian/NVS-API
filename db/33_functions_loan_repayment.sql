-- =============================================================================
-- CFMS / NVS  -  33  Loan repayment: allocation order, late fees, overpayment,
--                   default settlement and cooling-off (scope 7.4-7.6, 8.1-8.4)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run. Every function runs as the caller (nvs_app).
--
--   loan.allocation_order(snapshot)          -> bucket order: rule PAYMENT_ALLOCATION, else setting loans.payment_allocation_order
--   loan.rebuild_schedule(loan, reason, principal, interest, due_dates[])
--                                            -> new schedule version; settled rows copied
--   loan.collect_repayment(loan, amount, mode, ref)
--        allocates in the configured order (late fee, penalty, overdue interest,
--        overdue principal, current interest, current principal). The excess
--        reduces principal and regenerates the schedule (rule OVERPAYMENT).
--        On a DEFAULTED loan every open instalment is payable; paying it all
--        off settles the loan (SETTLED) and closes the default.
--   loan.close_default(loan, settlement)     -> default SETTLED, cooling-off starts
--   loan.assess_late_fees(on)                -> LATE_FEE charges (rule LATE_FEE)
--   loan.end_cooling_off(on)                 -> COOLING_OFF members back to ELIGIBLE/REINSTATED
-- =============================================================================

-- Allocation buckets in the order the loan's rule gives; buckets the rule
-- leaves out keep their default position after the listed ones.
CREATE OR REPLACE FUNCTION loan.allocation_order(p_snapshot jsonb)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_default text[] := ARRAY['LATE_FEE','PENALTY','OVERDUE_INTEREST','OVERDUE_PRINCIPAL',
                              'CURRENT_INTEREST','CURRENT_PRINCIPAL'];
    v_list jsonb := loan.rule(p_snapshot, 'PAYMENT_ALLOCATION')->'value'->'order';
    v_order text[] := '{}';
    v_item text;
BEGIN
    -- The loan's rule wins; otherwise the organisation setting.
    IF jsonb_typeof(v_list) IS DISTINCT FROM 'array' THEN
        v_list := cfg.get_setting('loans.payment_allocation_order');
    END IF;
    IF jsonb_typeof(v_list) = 'array' THEN
        FOR v_item IN SELECT upper(value) FROM jsonb_array_elements_text(v_list) LOOP
            IF v_item = ANY (v_default) AND NOT v_item = ANY (v_order) THEN
                v_order := v_order || v_item;
            END IF;
        END LOOP;
    END IF;
    -- A list that names late fees but not the default penalty keeps the penalty with the fees.
    IF 'LATE_FEE' = ANY (v_order) AND NOT 'PENALTY' = ANY (v_order) THEN
        v_order := v_order[1:array_position(v_order, 'LATE_FEE')] || 'PENALTY'::text
                   || v_order[array_position(v_order, 'LATE_FEE') + 1:];
    END IF;
    FOREACH v_item IN ARRAY v_default LOOP
        IF NOT v_item = ANY (v_order) THEN
            v_order := v_order || v_item;
        END IF;
    END LOOP;
    RETURN v_order;
END
$$;

-- New schedule version for a loan. Instalments that are paid, partly paid,
-- already due, cancelled or waived are copied as they are; the open future
-- instalments are replaced by p_principal and p_interest spread over the
-- given due dates (the last instalment absorbs the rounding).
CREATE OR REPLACE FUNCTION loan.rebuild_schedule(
    p_loan_id uuid, p_reason text, p_principal numeric, p_interest numeric, p_due_dates date[])
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_on date := app.working_date();
    v_old record;
    v_new uuid;
    v_count integer := coalesce(array_length(p_due_dates, 1), 0);
    v_next integer;
    v_kept_total numeric(18,2);
    v_kept_interest numeric(18,2);
    v_p_each numeric(18,2);
    v_i_each numeric(18,2);
    i integer;
BEGIN
    IF v_count = 0 AND coalesce(p_principal, 0) > 0 THEN
        PERFORM app.fail('SCHEDULE_NEEDS_INSTALMENTS', 'A new schedule needs at least one instalment.');
    END IF;
    SELECT s.* INTO v_old FROM loan.loan_schedule s
     WHERE s.tenant_id = app.tenant_id() AND s.loan_id = p_loan_id AND s.is_current FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_NOT_OPEN', 'The loan has no repayment schedule.');
    END IF;
    UPDATE loan.loan_schedule SET is_current = false,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_old.id;

    SELECT coalesce(sum(principal_due + interest_due), 0), coalesce(sum(interest_due), 0), coalesce(max(instalment_no), 0)
      INTO v_kept_total, v_kept_interest, v_next
      FROM loan.loan_instalment
     WHERE tenant_id = app.tenant_id() AND loan_schedule_id = v_old.id
       AND NOT (status = 'DUE' AND principal_paid = 0 AND interest_paid = 0 AND due_date > v_on);

    INSERT INTO loan.loan_schedule (loan_id, schedule_version, reason, is_current, effective_from, principal_basis,
                                    interest_rate_annual, total_interest, total_repayable, rounding_rule,
                                    rule_set_version_id, previous_schedule_id)
    SELECT p_loan_id, (SELECT max(schedule_version) + 1 FROM loan.loan_schedule
                        WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id),
           p_reason, true, v_on, p_principal, v_old.interest_rate_annual,
           v_kept_interest + coalesce(p_interest, 0), v_kept_total + p_principal + coalesce(p_interest, 0),
           v_old.rounding_rule, v_old.rule_set_version_id, v_old.id
    RETURNING id INTO v_new;

    INSERT INTO loan.loan_instalment (loan_schedule_id, loan_id, instalment_no, due_date, principal_due, interest_due,
                                      rounding_adjustment, principal_paid, interest_paid, late_fee_assessed,
                                      late_fee_paid, status, paid_on)
    SELECT v_new, loan_id, instalment_no, due_date, principal_due, interest_due, rounding_adjustment,
           principal_paid, interest_paid, late_fee_assessed, late_fee_paid, status, paid_on
      FROM loan.loan_instalment
     WHERE tenant_id = app.tenant_id() AND loan_schedule_id = v_old.id
       AND NOT (status = 'DUE' AND principal_paid = 0 AND interest_paid = 0 AND due_date > v_on)
     ORDER BY instalment_no;

    IF v_count > 0 THEN
        v_p_each := round(p_principal / v_count, 2);
        v_i_each := round(coalesce(p_interest, 0) / v_count, 2);
        FOR i IN 1..v_count LOOP
            INSERT INTO loan.loan_instalment (loan_schedule_id, loan_id, instalment_no, due_date, principal_due, interest_due)
            VALUES (v_new, p_loan_id, v_next + i, p_due_dates[i],
                    CASE WHEN i = v_count THEN p_principal - v_p_each * (v_count - 1) ELSE v_p_each END,
                    CASE WHEN i = v_count THEN coalesce(p_interest, 0) - v_i_each * (v_count - 1) ELSE v_i_each END);
        END LOOP;
        UPDATE loan.loan SET maturity_date = p_due_dates[v_count], instalment_amount = v_p_each + v_i_each,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    END IF;
    RETURN v_new;
END
$$;

-- Settles a loan's open default: SETTLED, cooling-off from the tenant setting
-- loans.cooling_off {"months":6}; the member moves from RESTRICTED to
-- COOLING_OFF (or REINSTATED without a cooling-off period) unless another
-- default of the member is still open. Open recovery cases are closed.
CREATE OR REPLACE FUNCTION loan.close_default(p_loan_id uuid, p_settlement_id uuid DEFAULT NULL)
RETURNS date LANGUAGE plpgsql AS
$$
DECLARE
    v_on date := app.working_date();
    v_member uuid;
    v_months integer;
    v_until date;
BEGIN
    SELECT member_id INTO v_member FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    v_months := (cfg.require_setting('loans.cooling_off')->>'months')::integer;
    IF v_months IS NULL THEN
        PERFORM app.fail('SETTING_MISSING', 'Setting loans.cooling_off has no months.');
    END IF;
    v_months := greatest(v_months, 0);
    v_until := CASE WHEN v_months > 0 THEN (v_on + make_interval(months => v_months))::date END;
    UPDATE loan.loan_default SET status = 'SETTLED', settled_on = v_on, cooling_off_until = v_until,
           loan_settlement_id = coalesce(p_settlement_id, loan_settlement_id),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'OPEN';
    UPDATE loan.recovery_case SET status = 'SETTLEMENT_RECEIVED', closed_on = v_on, next_follow_up = NULL,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND closed_on IS NULL;
    IF NOT EXISTS (SELECT 1 FROM loan.loan_default d JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.loan_id
                    WHERE d.tenant_id = app.tenant_id() AND l.member_id = v_member AND d.status = 'OPEN') THEN
        UPDATE mbr.member
           SET loan_eligibility = CASE WHEN v_until IS NULL THEN 'REINSTATED' ELSE 'COOLING_OFF' END,
               cooling_off_until = CASE WHEN v_until IS NULL THEN cooling_off_until
                                        ELSE greatest(coalesce(cooling_off_until, v_until), v_until) END,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_member AND loan_eligibility IN ('RESTRICTED','COOLING_OFF');
    END IF;
    PERFORM loan.notify_member('LOAN_SETTLED', p_loan_id, '{}'::jsonb);
    RETURN v_until;
END
$$;

-- Repayment in the configured allocation order. See the header.
CREATE OR REPLACE FUNCTION loan.collect_repayment(
    p_loan_id uuid, p_amount numeric(18,2), p_payment_mode text, p_payment_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_on date := app.working_date();
    v_loan record;
    v_row record;
    v_bucket text;
    v_remaining numeric(18,2) := p_amount;
    v_part numeric(18,2);
    v_plan jsonb := '[]'::jsonb;
    v_principal numeric(18,2) := 0;
    v_interest numeric(18,2) := 0;
    v_late numeric(18,2) := 0;
    v_penalty numeric(18,2) := 0;
    v_excess numeric(18,2) := 0;
    v_due_now numeric(18,2) := 0;
    v_current_id uuid;
    v_future_principal numeric(18,2);
    v_rule jsonb;
    v_lines jsonb := '[]'::jsonb;
    v_receipt uuid;
    v_journal uuid;
    v_receipt_no text;
    v_repayment uuid;
    v_item jsonb;
    v_seq integer := 0;
    v_balance numeric(18,2);
    v_open boolean;
    v_still_overdue boolean;
    v_status text;
    v_type text;
    v_schedule uuid;
    v_dates date[];
    v_n integer;
    v_per numeric(18,2);
    v_new_interest numeric(18,2);
    v_cool date;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        PERFORM app.fail('INVALID_REPAYMENT_AMOUNT', 'Repayment amount must be positive');
    END IF;
    SELECT l.id, l.member_id, l.loan_type_id, l.status, l.outstanding_principal, l.rule_set_version_id,
           l.rule_snapshot, l.is_restructured, l.interest_rate_annual, l.loan_no
      INTO v_loan FROM loan.loan l
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND NOT l.is_deleted FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found');
    END IF;
    IF v_loan.status NOT IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED') THEN
        PERFORM app.fail('LOAN_NOT_OPEN', 'Loan is not open for repayments');
    END IF;

    -- The "current" instalment: the one due today, else the next one due. On a
    -- defaulted loan the whole outstanding is payable, so every open instalment
    -- counts as overdue.
    IF v_loan.status <> 'DEFAULTED' THEN
        SELECT i.id INTO v_current_id
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id
           AND i.status IN ('DUE','PARTLY_PAID') AND i.due_date >= v_on
         ORDER BY i.due_date, i.instalment_no LIMIT 1;
    END IF;

    FOREACH v_bucket IN ARRAY loan.allocation_order(v_loan.rule_snapshot) LOOP
        EXIT WHEN v_remaining = 0;
        IF v_bucket IN ('LATE_FEE','PENALTY') THEN
            FOR v_row IN
                SELECT c.id, c.amount - c.paid_amount - c.waived_amount AS open_amount
                  FROM loan.loan_charge c
                 WHERE c.tenant_id = app.tenant_id() AND c.loan_id = p_loan_id AND c.status = 'OPEN'
                   AND c.charge_type = CASE v_bucket WHEN 'LATE_FEE' THEN 'LATE_FEE' ELSE 'DEFAULT_PENALTY' END
                   AND c.amount - c.paid_amount - c.waived_amount > 0
                 ORDER BY c.assessed_on, c.created_at, c.id FOR UPDATE
            LOOP
                v_part := least(v_remaining, v_row.open_amount);
                v_plan := v_plan || jsonb_build_array(jsonb_build_object('charge_id', v_row.id, 'component', v_bucket, 'amount', v_part));
                IF v_bucket = 'LATE_FEE' THEN v_late := v_late + v_part; ELSE v_penalty := v_penalty + v_part; END IF;
                v_remaining := v_remaining - v_part;
                EXIT WHEN v_remaining = 0;
            END LOOP;
        ELSE
            FOR v_row IN
                SELECT i.id, i.principal_due - i.principal_paid AS principal_open, i.interest_due - i.interest_paid AS interest_open
                  FROM loan.loan_instalment i
                  JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
                 WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID')
                   AND CASE WHEN v_bucket LIKE 'OVERDUE%'
                            THEN v_loan.status = 'DEFAULTED' OR i.due_date < v_on
                            ELSE i.id = v_current_id END
                 ORDER BY i.due_date, i.instalment_no FOR UPDATE
            LOOP
                IF v_bucket LIKE '%INTEREST' THEN
                    v_part := least(v_remaining, v_row.interest_open
                                    - coalesce((SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(v_plan) x
                                                 WHERE x->>'instalment_id' = v_row.id::text AND x->>'component' = 'INTEREST'), 0));
                    IF v_part > 0 THEN
                        v_plan := v_plan || jsonb_build_array(jsonb_build_object('instalment_id', v_row.id, 'component', 'INTEREST', 'amount', v_part));
                        v_interest := v_interest + v_part;
                    END IF;
                ELSE
                    v_part := least(v_remaining, v_row.principal_open
                                    - coalesce((SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(v_plan) x
                                                 WHERE x->>'instalment_id' = v_row.id::text AND x->>'component' = 'PRINCIPAL'), 0));
                    IF v_part > 0 THEN
                        v_plan := v_plan || jsonb_build_array(jsonb_build_object('instalment_id', v_row.id, 'component', 'PRINCIPAL', 'amount', v_part));
                        v_principal := v_principal + v_part;
                    END IF;
                END IF;
                v_remaining := v_remaining - greatest(v_part, 0);
                EXIT WHEN v_remaining = 0;
            END LOOP;
        END IF;
    END LOOP;

    -- What was due today: open charges and instalments due on or before today.
    SELECT coalesce(sum(c.amount - c.paid_amount - c.waived_amount), 0) INTO v_due_now
      FROM loan.loan_charge c
     WHERE c.tenant_id = app.tenant_id() AND c.loan_id = p_loan_id AND c.status = 'OPEN'
       AND c.charge_type IN ('LATE_FEE','DEFAULT_PENALTY');
    v_due_now := v_due_now + coalesce((
        SELECT sum(i.principal_due - i.principal_paid + i.interest_due - i.interest_paid)
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID')
           AND (v_loan.status = 'DEFAULTED' OR i.due_date <= v_on)), 0);

    -- Excess over the amount due reduces principal (rule OVERPAYMENT).
    IF v_remaining > 0 THEN
        v_rule := coalesce(loan.rule(v_loan.rule_snapshot, 'OVERPAYMENT')->'value', '{}'::jsonb);
        SELECT coalesce(sum(i.principal_due - i.principal_paid), 0) INTO v_future_principal
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id
           AND i.status = 'DUE' AND i.principal_paid = 0 AND i.interest_paid = 0 AND i.due_date > v_on
           AND i.id IS DISTINCT FROM v_current_id;
        IF v_loan.status = 'DEFAULTED' OR NOT coalesce((v_rule->>'excessReducesPrincipal')::boolean, true)
           OR v_future_principal = 0 THEN
            PERFORM app.fail('REPAYMENT_EXCEEDS_DUES', 'Repayment cannot exceed the amount currently due');
        END IF;
        IF v_remaining >= v_future_principal THEN
            PERFORM app.fail('REPAYMENT_CLEARS_LOAN',
                'The amount clears the whole loan; use early settlement instead.');
        END IF;
        v_excess := v_remaining;
        v_principal := v_principal + v_excess;
        v_remaining := 0;
    END IF;

    IF v_principal > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'PRINCIPAL', 'mapping_key', 'LOAN_PRINCIPAL',
            'scope_type', 'LOAN_TYPE', 'scope_id', v_loan.loan_type_id, 'amount', v_principal));
    END IF;
    IF v_interest > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'INTEREST', 'mapping_key', 'LOAN_INTEREST', 'amount', v_interest));
    END IF;
    IF v_late > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'LATE_FEE', 'mapping_key', 'LATE_FEE', 'amount', v_late));
    END IF;
    IF v_penalty > 0 THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('component', 'PENALTY', 'mapping_key', 'DEFAULT_PENALTY', 'amount', v_penalty));
    END IF;
    SELECT r.cash_receipt_id, r.journal_id INTO v_receipt, v_journal
      FROM acct.post_cash_receipt(v_loan.member_id, p_amount, p_payment_mode, p_payment_reference,
                                  'LOAN_REPAYMENT', 'loan.loan', p_loan_id, v_lines) r;
    SELECT receipt_no INTO v_receipt_no FROM acct.cash_receipt WHERE tenant_id = app.tenant_id() AND id = v_receipt;

    v_type := CASE WHEN v_excess > 0 THEN 'LUMP_SUM' WHEN p_amount < v_due_now THEN 'PARTIAL' ELSE 'REGULAR' END;
    INSERT INTO loan.loan_repayment (loan_id, cash_receipt_id, value_date, repayment_type, amount, principal_amount,
                                     interest_amount, late_fee_amount, penalty_amount, excess_to_principal, rule_set_version_id)
    VALUES (p_loan_id, v_receipt, v_on, v_type, p_amount, v_principal, v_interest, v_late, v_penalty, v_excess,
            v_loan.rule_set_version_id)
    RETURNING id INTO v_repayment;

    FOR v_item IN SELECT value FROM jsonb_array_elements(v_plan) LOOP
        v_seq := v_seq + 1;
        IF v_item ? 'charge_id' THEN
            INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, loan_charge_id, component, amount)
            VALUES (v_repayment, v_seq, (v_item->>'charge_id')::uuid, v_item->>'component', (v_item->>'amount')::numeric);
            UPDATE loan.loan_charge SET paid_amount = paid_amount + (v_item->>'amount')::numeric,
                   status = CASE WHEN paid_amount + waived_amount + (v_item->>'amount')::numeric >= amount THEN 'PAID' ELSE status END,
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND id = (v_item->>'charge_id')::uuid;
            IF v_item->>'component' = 'LATE_FEE' THEN
                UPDATE loan.loan_instalment SET late_fee_paid = late_fee_paid + (v_item->>'amount')::numeric,
                       updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
                 WHERE tenant_id = app.tenant_id()
                   AND id = (SELECT loan_instalment_id FROM loan.loan_charge
                              WHERE tenant_id = app.tenant_id() AND id = (v_item->>'charge_id')::uuid);
            END IF;
        ELSE
            INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, loan_instalment_id, component, amount)
            VALUES (v_repayment, v_seq, (v_item->>'instalment_id')::uuid, v_item->>'component', (v_item->>'amount')::numeric);
            UPDATE loan.loan_instalment
               SET interest_paid = interest_paid + CASE WHEN v_item->>'component' = 'INTEREST' THEN (v_item->>'amount')::numeric ELSE 0 END,
                   principal_paid = principal_paid + CASE WHEN v_item->>'component' = 'PRINCIPAL' THEN (v_item->>'amount')::numeric ELSE 0 END,
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND id = (v_item->>'instalment_id')::uuid;
            UPDATE loan.loan_instalment
               SET status = CASE WHEN principal_paid >= principal_due AND interest_paid >= interest_due THEN 'PAID' ELSE 'PARTLY_PAID' END,
                   paid_on = CASE WHEN principal_paid >= principal_due AND interest_paid >= interest_due THEN v_on ELSE paid_on END
             WHERE tenant_id = app.tenant_id() AND id = (v_item->>'instalment_id')::uuid;
        END IF;
    END LOOP;
    IF v_excess > 0 THEN
        v_seq := v_seq + 1;
        INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, component, amount)
        VALUES (v_repayment, v_seq, 'EXCESS_PRINCIPAL', v_excess);
    END IF;

    v_balance := greatest(0, v_loan.outstanding_principal - v_principal);
    UPDATE loan.loan SET outstanding_principal = v_balance,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id;

    -- Regenerate the open future instalments after a principal reduction.
    IF v_excess > 0 THEN
        SELECT array_agg(i.due_date ORDER BY i.due_date, i.instalment_no), coalesce(sum(i.interest_due), 0),
               (array_agg(i.principal_due ORDER BY i.due_date, i.instalment_no))[1]
          INTO v_dates, v_new_interest, v_per
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
         WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id
           AND i.status = 'DUE' AND i.principal_paid = 0 AND i.interest_paid = 0 AND i.due_date > v_on;
        v_n := array_length(v_dates, 1);
        IF upper(coalesce(v_rule->>'regenerate', 'REDUCE_INSTALMENT')) = 'REDUCE_TENURE' AND v_per > 0 THEN
            v_n := least(v_n, ceil((v_future_principal - v_excess) / v_per)::integer);
            v_new_interest := round(v_new_interest * v_n / array_length(v_dates, 1), 2);
        END IF;
        IF coalesce((v_rule->>'interestOnReducedPrincipal')::boolean, true) THEN
            v_new_interest := round((v_future_principal - v_excess) * coalesce(v_loan.interest_rate_annual, 0) / 100 * v_n / 12, 2);
        END IF;
        v_schedule := loan.rebuild_schedule(p_loan_id, 'PREPAYMENT', v_future_principal - v_excess,
                                            v_new_interest, v_dates[1:v_n]);
    END IF;

    SELECT EXISTS (SELECT 1 FROM loan.loan_instalment i
                     JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
                    WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID'))
        OR EXISTS (SELECT 1 FROM loan.loan_charge c
                    WHERE c.tenant_id = app.tenant_id() AND c.loan_id = p_loan_id AND c.status = 'OPEN'
                      AND c.charge_type IN ('LATE_FEE','DEFAULT_PENALTY'))
      INTO v_open;
    SELECT EXISTS (SELECT 1 FROM loan.loan_instalment i
                     JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
                    WHERE i.tenant_id = app.tenant_id() AND i.loan_id = p_loan_id AND i.status IN ('DUE','PARTLY_PAID')
                      AND i.due_date + loan.grace_days(v_loan.rule_snapshot) < v_on)
      INTO v_still_overdue;
    v_status := CASE WHEN NOT v_open AND v_loan.status = 'DEFAULTED' THEN 'SETTLED'
                     WHEN NOT v_open THEN 'CLOSED'
                     WHEN v_loan.status = 'OVERDUE' AND NOT v_still_overdue
                          THEN CASE WHEN v_loan.is_restructured THEN 'RESTRUCTURED' ELSE 'ACTIVE' END
                     ELSE v_loan.status END;
    IF v_status <> v_loan.status THEN
        UPDATE loan.loan SET status = v_status, status_date = v_on,
               status_reason = CASE v_status WHEN 'CLOSED' THEN 'Repaid in full'
                                             WHEN 'SETTLED' THEN 'Defaulted loan paid in full'
                                             ELSE 'Overdue instalments cleared' END,
               closed_on = CASE WHEN v_status IN ('CLOSED','SETTLED') THEN v_on ELSE closed_on END,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    END IF;
    IF v_status = 'SETTLED' THEN
        v_cool := loan.close_default(p_loan_id, NULL);
    END IF;
    PERFORM loan.notify_member('REPAYMENT_RECEIPT', p_loan_id,
        jsonb_build_object('amount', p_amount, 'receipt_no', v_receipt_no, 'outstanding', v_balance));

    RETURN jsonb_build_object('loan_id', p_loan_id, 'repayment_id', v_repayment, 'repayment_type', v_type,
        'cash_receipt_id', v_receipt, 'receipt_no', v_receipt_no, 'journal_id', v_journal, 'amount', p_amount,
        'principal_amount', v_principal, 'interest_amount', v_interest, 'late_fee_amount', v_late,
        'penalty_amount', v_penalty, 'excess_to_principal', v_excess, 'new_schedule_id', v_schedule,
        'allocations', v_plan, 'outstanding_principal', v_balance, 'loan_status', v_status,
        'cooling_off_until', v_cool, 'status', 'POSTED');
END
$$;

-- Late fees for unpaid instalments past the grace period (rule LATE_FEE):
--   {"enabled":true,"graceDays":5,"type":"fixed"|"percent","amount":100,
--    "value":2,"frequency":"ONCE_PER_INSTALMENT"|"MONTHLY","cap":500}
-- percent is of the instalment's open amount; cap limits the late fees of one
-- instalment. Safe to run more than once a day.
CREATE OR REPLACE FUNCTION loan.assess_late_fees(p_on date)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_row record;
    v_rule jsonb;
    v_amount numeric(18,2);
    v_last date;
    v_count integer := 0;
BEGIN
    FOR v_row IN
        SELECT l.id AS loan_id, l.rule_snapshot, l.rule_set_version_id, i.id AS instalment_id, i.due_date,
               i.principal_due - i.principal_paid + i.interest_due - i.interest_paid AS open_amount
          FROM loan.loan l
          JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
          JOIN loan.loan_schedule s ON s.tenant_id = l.tenant_id AND s.loan_id = l.id AND s.is_current
          JOIN loan.loan_instalment i ON i.tenant_id = s.tenant_id AND i.loan_schedule_id = s.id
         WHERE l.tenant_id = app.tenant_id() AND l.status IN ('ACTIVE','OVERDUE','RESTRUCTURED') AND NOT l.is_deleted
           AND l.interest_stopped_from IS NULL AND m.status <> 'DECEASED'
           AND i.status IN ('DUE','PARTLY_PAID')
           AND coalesce((loan.rule(l.rule_snapshot, 'LATE_FEE')->'value'->>'enabled')::boolean, false)
           AND i.due_date + loan.grace_days(l.rule_snapshot) < p_on
         ORDER BY l.id, i.due_date
    LOOP
        v_rule := loan.rule(v_row.rule_snapshot, 'LATE_FEE')->'value';
        SELECT max(assessed_on) INTO v_last FROM loan.loan_charge
         WHERE tenant_id = app.tenant_id() AND loan_instalment_id = v_row.instalment_id
           AND charge_type = 'LATE_FEE' AND status <> 'CANCELLED';
        CONTINUE WHEN v_last IS NOT NULL AND (upper(coalesce(v_rule->>'frequency', 'ONCE_PER_INSTALMENT')) <> 'MONTHLY'
                                              OR (v_last + interval '1 month')::date > p_on);
        v_amount := CASE lower(coalesce(v_rule->>'type', 'fixed'))
            WHEN 'percent' THEN round(v_row.open_amount * coalesce((v_rule->>'value')::numeric, (v_rule->>'percent')::numeric, 0) / 100, 2)
            ELSE round(coalesce((v_rule->>'amount')::numeric, (v_rule->>'value')::numeric, 0), 2) END;
        IF nullif(v_rule->>'cap', '') IS NOT NULL THEN
            v_amount := least(v_amount, (v_rule->>'cap')::numeric - coalesce((
                SELECT sum(amount) FROM loan.loan_charge
                 WHERE tenant_id = app.tenant_id() AND loan_instalment_id = v_row.instalment_id
                   AND charge_type = 'LATE_FEE' AND status <> 'CANCELLED'), 0));
        END IF;
        CONTINUE WHEN v_amount IS NULL OR v_amount <= 0;
        INSERT INTO loan.loan_charge (loan_id, loan_instalment_id, charge_type, assessed_on, amount, rule_set_version_id)
        VALUES (v_row.loan_id, v_row.instalment_id, 'LATE_FEE', p_on, v_amount, v_row.rule_set_version_id);
        UPDATE loan.loan_instalment SET late_fee_assessed = late_fee_assessed + v_amount,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_row.instalment_id;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END
$$;

-- Members whose cooling-off has ended become eligible again: REINSTATED when
-- they have a default history, otherwise ELIGIBLE. Members with an open
-- default stay as they are.
CREATE OR REPLACE FUNCTION loan.end_cooling_off(p_on date)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_member record;
    v_count integer := 0;
BEGIN
    FOR v_member IN
        SELECT m.id FROM mbr.member m
         WHERE m.tenant_id = app.tenant_id() AND m.loan_eligibility = 'COOLING_OFF'
           AND (m.cooling_off_until IS NULL OR m.cooling_off_until < p_on)
           AND NOT EXISTS (SELECT 1 FROM loan.loan_default d JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.loan_id
                            WHERE d.tenant_id = m.tenant_id AND l.member_id = m.id AND d.status = 'OPEN')
         ORDER BY m.id FOR UPDATE
    LOOP
        UPDATE mbr.member m
           SET loan_eligibility = CASE WHEN EXISTS (SELECT 1 FROM loan.loan_default d
                                                      JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.loan_id
                                                     WHERE d.tenant_id = m.tenant_id AND l.member_id = m.id)
                                       THEN 'REINSTATED' ELSE 'ELIGIBLE' END,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE m.tenant_id = app.tenant_id() AND m.id = v_member.id;
        PERFORM loan.notify('COOLING_OFF_COMPLETED', 'MEMBER', v_member.id, NULL, 'mbr.member', v_member.id, '{}'::jsonb);
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END
$$;

GRANT EXECUTE ON FUNCTION
    loan.allocation_order(jsonb),
    loan.rebuild_schedule(uuid, text, numeric, numeric, date[]),
    loan.close_default(uuid, uuid),
    loan.collect_repayment(uuid, numeric, text, text),
    loan.assess_late_fees(date),
    loan.end_cooling_off(date)
TO nvs_app;
