-- =============================================================================
-- CFMS / NVS  -  35  Loan default, recovery, waivers, cooling-off override and
--                   write-off (scope 6.2, 7.6, 8.2, 8.5-8.7, 28.5)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run. Every function runs as the caller (nvs_app).
-- Approvals follow the single-approver rule (scope 28.4): the approver has the
-- configured role and is never the person who raised the request.
--
-- Recovery
--   loan.open_recovery_case(loan, default)       (daily job, at default)
--   loan.assign_recovery_case(case, user)
--   loan.log_recovery_contact(case, details jsonb)
--   loan.set_recovery_status(case, status, remarks)
--   loan.escalate_recovery_cases(on)             (daily job; settings recovery.escalate_to_*_days)
--   loan.get_recovery_case(case), loan.list_recovery_cases(status, assigned_to, due_only)
-- Waivers (late fee, penalty, application fee)
--   loan.request_waiver(loan, component, charge, amount, reason)
--   loan.decide_waiver(waiver, approve, remarks)
-- Cooling-off override
--   loan.request_cooling_off_override(member, reason, evidence_document)
--   loan.decide_cooling_off_override(override, approve, valid_until, remarks)
-- Write-off (approver role: setting loans.write_off_approver_role, default LDR)
--   loan.propose_write_off(loan, reason), loan.decide_write_off(write_off, approve, remarks)
--   loan.collect_written_off_recovery(loan, amount, mode, reference)
-- =============================================================================

-- Account mapped to a key (optionally for a loan type) on the working date.
CREATE OR REPLACE FUNCTION loan.mapped_account(p_key text, p_loan_type_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql STABLE AS
$$
DECLARE v_account uuid;
BEGIN
    IF p_loan_type_id IS NOT NULL THEN
        SELECT account_id INTO v_account FROM acct.account_mapping
         WHERE tenant_id = app.tenant_id() AND mapping_key = p_key AND scope_type = 'LOAN_TYPE'
           AND scope_id = p_loan_type_id AND effective_from <= app.working_date()
         ORDER BY effective_from DESC LIMIT 1;
        IF v_account IS NULL AND p_key = 'LOAN_PRINCIPAL' THEN
            SELECT principal_account_id INTO v_account FROM loan.loan_type
             WHERE tenant_id = app.tenant_id() AND id = p_loan_type_id;
        END IF;
    END IF;
    IF v_account IS NULL THEN
        SELECT account_id INTO v_account FROM acct.account_mapping
         WHERE tenant_id = app.tenant_id() AND mapping_key = p_key AND scope_type = 'NONE' AND scope_id IS NULL
           AND effective_from <= app.working_date()
         ORDER BY effective_from DESC LIMIT 1;
    END IF;
    IF v_account IS NULL THEN
        PERFORM app.fail('ACCOUNT_MAPPING_MISSING', format('No account mapping for %s', p_key));
    END IF;
    RETURN v_account;
END
$$;

-- The caller must hold one of the roles (comma separated) and must not be the
-- person who raised the request.
CREATE OR REPLACE FUNCTION loan.assert_approver(p_roles text, p_requested_by uuid)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF app.user_id() IS NOT DISTINCT FROM p_requested_by THEN
        PERFORM app.fail('SOD_SELF_APPROVAL', 'The person who raised the request cannot approve it.');
    END IF;
    IF NOT coalesce(app.role_code(), '') = ANY (string_to_array(replace(p_roles, ' ', ''), ',')) THEN
        PERFORM app.fail('APPROVER_ROLE_REQUIRED', format('Only %s can approve this request.', p_roles));
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- Recovery cases
-- -----------------------------------------------------------------------------
-- Opened when a loan defaults and assigned to the employee who created the
-- loan (or left unassigned). One open case per loan.
CREATE OR REPLACE FUNCTION loan.open_recovery_case(p_loan_id uuid, p_default_id uuid)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_id uuid;
BEGIN
    SELECT id FROM loan.recovery_case INTO v_id
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND closed_on IS NULL;
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;
    SELECT l.id, l.member_id, l.created_by_employee INTO v_loan FROM loan.loan l
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id;
    INSERT INTO loan.recovery_case (case_no, loan_id, member_id, loan_default_id, status, assigned_to,
                                    escalation_level, opened_on, next_follow_up)
    VALUES (acct.next_number('RECOVERY_CASE', app.working_date()), p_loan_id, v_loan.member_id, p_default_id,
            'PENDING', (SELECT u.id FROM iam.app_user u WHERE u.tenant_id = app.tenant_id()
                         AND u.id = v_loan.created_by_employee AND u.status = 'ACTIVE'),
            'EMPLOYEE', app.working_date(), app.working_date() + cfg.require_setting_int('recovery.first_follow_up_days'))
    RETURNING id INTO v_id;
    RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION loan.get_recovery_case(p_case_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object(
        'id', c.id, 'case_no', c.case_no, 'loan_id', c.loan_id, 'loan_no', l.loan_no, 'loan_status', l.status,
        'member_id', c.member_id, 'member_no', m.member_no, 'member_name', m.full_name, 'member_mobile', m.mobile,
        'loan_default_id', c.loan_default_id, 'status', c.status, 'assigned_to', c.assigned_to,
        'assigned_to_name', u.full_name, 'escalation_level', c.escalation_level, 'escalated_at', c.escalated_at,
        'opened_on', c.opened_on, 'next_follow_up', c.next_follow_up, 'closed_on', c.closed_on,
        'outstanding_principal', l.outstanding_principal,
        'defaulted_on', d.defaulted_on, 'penalty_amount', d.penalty_amount,
        'guarantors', coalesce((SELECT jsonb_agg(jsonb_build_object('id', g.id, 'member_id', g.guarantor_member_id,
                                    'name', coalesce(gm.full_name, g.non_member_name),
                                    'mobile', coalesce(gm.mobile, g.non_member_mobile),
                                    'guaranteed_amount', g.guaranteed_amount, 'status', g.status))
                                  FROM loan.loan_guarantor g
                                  LEFT JOIN mbr.member gm ON gm.tenant_id = g.tenant_id AND gm.id = g.guarantor_member_id
                                 WHERE g.tenant_id = c.tenant_id AND g.loan_id = c.loan_id AND g.status IN ('ACTIVE','INVOKED')), '[]'::jsonb),
        'contacts', coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'contact_date', x.contact_date,
                                    'method', x.method, 'person_type', x.person_type, 'person_name', x.person_name,
                                    'outcome', x.outcome, 'promise_date', x.promise_date, 'promise_amount', x.promise_amount,
                                    'next_follow_up', x.next_follow_up, 'contacted_by', x.contacted_by,
                                    'created_at', x.created_at) ORDER BY x.contact_date DESC, x.created_at DESC)
                                FROM loan.recovery_contact x
                               WHERE x.tenant_id = c.tenant_id AND x.recovery_case_id = c.id), '[]'::jsonb),
        'row_version', c.row_version)
      FROM loan.recovery_case c
      JOIN loan.loan l ON l.tenant_id = c.tenant_id AND l.id = c.loan_id
      JOIN mbr.member m ON m.tenant_id = c.tenant_id AND m.id = c.member_id
      LEFT JOIN loan.loan_default d ON d.tenant_id = c.tenant_id AND d.id = c.loan_default_id
      LEFT JOIN iam.app_user u ON u.tenant_id = c.tenant_id AND u.id = c.assigned_to
     WHERE c.tenant_id = app.tenant_id() AND c.id = p_case_id
$$;

-- Open cases for the Manager dashboard and the employee's follow-up list.
CREATE OR REPLACE FUNCTION loan.list_recovery_cases(
    p_status text DEFAULT NULL, p_assigned_to uuid DEFAULT NULL, p_follow_up_due boolean DEFAULT false,
    p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg(r ORDER BY (r->>'next_follow_up') NULLS LAST, r->>'case_no'), '[]'::jsonb)
      FROM (SELECT jsonb_build_object('id', c.id, 'case_no', c.case_no, 'loan_id', c.loan_id, 'loan_no', l.loan_no,
                                      'member_id', c.member_id, 'member_name', m.full_name, 'status', c.status,
                                      'assigned_to', c.assigned_to, 'escalation_level', c.escalation_level,
                                      'opened_on', c.opened_on, 'next_follow_up', c.next_follow_up,
                                      'outstanding_principal', l.outstanding_principal) AS r
              FROM loan.recovery_case c
              JOIN loan.loan l ON l.tenant_id = c.tenant_id AND l.id = c.loan_id
              JOIN mbr.member m ON m.tenant_id = c.tenant_id AND m.id = c.member_id
             WHERE c.tenant_id = app.tenant_id()
               AND (p_status IS NULL AND c.closed_on IS NULL OR c.status = p_status)
               AND (p_assigned_to IS NULL OR c.assigned_to = p_assigned_to)
               AND (NOT p_follow_up_due OR c.next_follow_up <= app.working_date())
             ORDER BY c.next_follow_up NULLS LAST, c.case_no
             LIMIT greatest(least(p_limit, 200), 1) OFFSET greatest(p_offset, 0)) x
$$;

CREATE OR REPLACE FUNCTION loan.assign_recovery_case(p_case_id uuid, p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM iam.app_user WHERE tenant_id = app.tenant_id() AND id = p_user_id AND status = 'ACTIVE') THEN
        PERFORM app.fail('USER_NOT_FOUND', 'The user was not found or is not active.');
    END IF;
    UPDATE loan.recovery_case SET assigned_to = p_user_id,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_case_id AND closed_on IS NULL;
    IF NOT FOUND THEN
        PERFORM app.fail('RECOVERY_CASE_NOT_FOUND', 'The open recovery case was not found.');
    END IF;
    RETURN loan.get_recovery_case(p_case_id);
END
$$;

-- details: {"method","person_type","person_name","outcome","promise_date","promise_amount","next_follow_up","contact_date"}
-- A promise to pay moves the case to PROMISE_TO_PAY and follows up on the promised date.
CREATE OR REPLACE FUNCTION loan.log_recovery_contact(p_case_id uuid, p_details jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_case record;
    v_promise date := nullif(p_details->>'promise_date', '')::date;
    v_next date := nullif(p_details->>'next_follow_up', '')::date;
BEGIN
    SELECT * INTO v_case FROM loan.recovery_case
     WHERE tenant_id = app.tenant_id() AND id = p_case_id AND closed_on IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('RECOVERY_CASE_NOT_FOUND', 'The open recovery case was not found.');
    END IF;
    IF coalesce(p_details->>'outcome', '') = '' THEN
        PERFORM app.fail('RECOVERY_OUTCOME_REQUIRED', 'Record the outcome of the contact.');
    END IF;
    IF v_promise IS NOT NULL AND v_promise < app.working_date() THEN
        PERFORM app.fail('PROMISE_DATE_PAST', 'The promised payment date cannot be in the past.');
    END IF;
    INSERT INTO loan.recovery_contact (recovery_case_id, contact_date, method, person_type, person_name, outcome,
                                       promise_date, promise_amount, next_follow_up)
    VALUES (p_case_id, coalesce(nullif(p_details->>'contact_date', '')::date, app.working_date()),
            upper(p_details->>'method'), upper(coalesce(p_details->>'person_type', 'MEMBER')),
            p_details->>'person_name', p_details->>'outcome', v_promise,
            nullif(p_details->>'promise_amount', '')::numeric, coalesce(v_next, v_promise));
    UPDATE loan.recovery_case
       SET status = CASE WHEN v_promise IS NOT NULL THEN 'PROMISE_TO_PAY'
                         WHEN status = 'PENDING' THEN 'CONTACTED' ELSE status END,
           next_follow_up = coalesce(v_next, v_promise, app.working_date() + cfg.require_setting_int('recovery.follow_up_interval_days')),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_case_id;
    IF upper(coalesce(p_details->>'person_type', '')) = 'GUARANTOR' THEN
        UPDATE loan.loan_guarantor SET status = 'INVOKED',
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND loan_id = v_case.loan_id AND status = 'ACTIVE';
    END IF;
    RETURN loan.get_recovery_case(p_case_id);
END
$$;

-- LEGAL_NOTICE, SETTLEMENT_AGREED and EXCEPTION_APPROVED are set by hand;
-- SETTLEMENT_RECEIVED and WRITTEN_OFF come from the settlement and write-off.
CREATE OR REPLACE FUNCTION loan.set_recovery_status(p_case_id uuid, p_status text, p_remarks text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
BEGIN
    IF p_status NOT IN ('CONTACTED','PROMISE_TO_PAY','LEGAL_NOTICE','SETTLEMENT_AGREED','EXCEPTION_APPROVED') THEN
        PERFORM app.fail('INVALID_RECOVERY_STATUS', format('Recovery status %s cannot be set by hand.', p_status));
    END IF;
    IF p_status = 'EXCEPTION_APPROVED' THEN
        PERFORM loan.assert_approver_setting('recovery.exception_approver_roles', NULL);
    END IF;
    IF coalesce(p_remarks, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required for this change.');
    END IF;
    UPDATE loan.recovery_case SET status = p_status,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_case_id AND closed_on IS NULL;
    IF NOT FOUND THEN
        PERFORM app.fail('RECOVERY_CASE_NOT_FOUND', 'The open recovery case was not found.');
    END IF;
    INSERT INTO loan.recovery_contact (recovery_case_id, method, person_type, outcome)
    VALUES (p_case_id, CASE WHEN p_status = 'LEGAL_NOTICE' THEN 'LEGAL_NOTICE' ELSE 'OTHER' END, 'OTHER',
            format('Status set to %s: %s', p_status, p_remarks));
    RETURN loan.get_recovery_case(p_case_id);
END
$$;

-- Escalation (scope 28.5): unpaid N days after default -> MANAGER, then a
-- further M days (counted from the case opening plus N) -> LEADERSHIP. Settings
-- recovery.escalate_to_manager_days (N, 30) and recovery.escalate_to_leadership_days
-- (M, 30). Cases with a promise to pay
-- that is not yet due are left alone.
CREATE OR REPLACE FUNCTION loan.escalate_recovery_cases(p_on date)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_mgr integer := greatest(cfg.require_setting_int('recovery.escalate_to_manager_days'), 1);
    v_ldr integer := greatest(cfg.require_setting_int('recovery.escalate_to_leadership_days'), 1);
    v_mgr_role text := (cfg.setting_roles('recovery.escalate_to_manager_role'))[1];
    v_ldr_role text := (cfg.setting_roles('recovery.escalate_to_leadership_role'))[1];
    v_count integer;
    v_more integer;
BEGIN
    UPDATE loan.recovery_case c SET escalation_level = 'MANAGER', escalated_at = now(),
           assigned_to = coalesce((SELECT u.id FROM iam.app_user u JOIN iam.role r ON r.tenant_id = u.tenant_id AND r.id = u.primary_role_id
                                    WHERE u.tenant_id = c.tenant_id AND r.role_code = v_mgr_role AND u.status = 'ACTIVE'
                                    ORDER BY u.created_at LIMIT 1), c.assigned_to),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE c.tenant_id = app.tenant_id() AND c.closed_on IS NULL AND c.escalation_level = 'EMPLOYEE'
       AND c.opened_on + v_mgr <= p_on
       AND NOT (c.status = 'PROMISE_TO_PAY' AND coalesce(c.next_follow_up, p_on) >= p_on);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    UPDATE loan.recovery_case c SET escalation_level = 'LEADERSHIP', escalated_at = now(),
           assigned_to = coalesce((SELECT u.id FROM iam.app_user u JOIN iam.role r ON r.tenant_id = u.tenant_id AND r.id = u.primary_role_id
                                    WHERE u.tenant_id = c.tenant_id AND r.role_code = v_ldr_role AND u.status = 'ACTIVE'
                                    ORDER BY u.created_at LIMIT 1), c.assigned_to),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE c.tenant_id = app.tenant_id() AND c.closed_on IS NULL AND c.escalation_level = 'MANAGER'
       AND c.opened_on + v_mgr + v_ldr <= p_on
       AND NOT (c.status = 'PROMISE_TO_PAY' AND coalesce(c.next_follow_up, p_on) >= p_on);
    GET DIAGNOSTICS v_more = ROW_COUNT;
    RETURN v_count + v_more;
END
$$;

-- -----------------------------------------------------------------------------
-- Waivers: late fee and penalty charges, application fee (Manager approval;
-- rule APPLICATION_FEE.waiverAllowed). Waived amounts are never collected.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.get_waiver(p_waiver_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT to_jsonb(w) - 'tenant_id' FROM loan.loan_waiver w
     WHERE w.tenant_id = app.tenant_id() AND w.id = p_waiver_id
$$;

CREATE OR REPLACE FUNCTION loan.list_waivers(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg(to_jsonb(w) - 'tenant_id' ORDER BY w.created_at DESC), '[]'::jsonb)
      FROM loan.loan_waiver w WHERE w.tenant_id = app.tenant_id() AND w.loan_id = p_loan_id
$$;

CREATE OR REPLACE FUNCTION loan.request_waiver(
    p_loan_id uuid, p_component text, p_charge_id uuid, p_amount numeric, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_open numeric(18,2);
    v_loan record;
    v_id uuid;
BEGIN
    SELECT id, status, rule_snapshot, loan_type_id INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_NOT_FOUND', 'The loan was not found.');
    END IF;
    IF coalesce(p_reason, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required for this change.');
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        PERFORM app.fail('INVALID_WAIVER_AMOUNT', 'The waiver amount must be greater than zero.');
    END IF;
    IF p_component IN ('LATE_FEE','PENALTY') THEN
        SELECT amount - paid_amount - waived_amount INTO v_open FROM loan.loan_charge
         WHERE tenant_id = app.tenant_id() AND id = p_charge_id AND loan_id = p_loan_id AND status = 'OPEN'
           AND charge_type = CASE p_component WHEN 'LATE_FEE' THEN 'LATE_FEE' ELSE 'DEFAULT_PENALTY' END;
    ELSIF p_component = 'APPLICATION_FEE' THEN
        IF NOT coalesce((loan.rule(v_loan.rule_snapshot, 'APPLICATION_FEE')->'value'->>'waiverAllowed')::boolean,
                        (SELECT (r->'value'->>'waiverAllowed')::boolean
                           FROM loan.loan_type lt
                           JOIN cfg.rule_set_version v ON v.tenant_id = lt.tenant_id AND v.rule_set_id = lt.rule_set_id AND v.status = 'PUBLISHED'
                           CROSS JOIN LATERAL jsonb_array_elements(v.definition->'rules') r
                          WHERE lt.tenant_id = app.tenant_id() AND lt.id = v_loan.loan_type_id AND r->>'code' = 'APPLICATION_FEE'
                          ORDER BY v.version_no DESC LIMIT 1), false) THEN
            PERFORM app.fail('WAIVER_NOT_ALLOWED', 'Fee waivers are not allowed for this loan type.');
        END IF;
        SELECT fee_amount INTO v_open FROM loan.loan_application_fee
         WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'PENDING';
        p_charge_id := NULL;
    ELSE
        PERFORM app.fail('WAIVER_NOT_ALLOWED', format('A %s waiver is not available; use a settlement waiver or write-off.', p_component));
    END IF;
    IF v_open IS NULL THEN
        PERFORM app.fail('WAIVER_TARGET_NOT_OPEN', 'There is nothing open to waive.');
    END IF;
    IF p_amount > v_open OR (p_component = 'APPLICATION_FEE' AND p_amount <> v_open) THEN
        PERFORM app.fail('INVALID_WAIVER_AMOUNT', format('The waiver cannot exceed the open amount of %s.', v_open));
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_waiver WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id
                AND component = p_component AND loan_charge_id IS NOT DISTINCT FROM p_charge_id AND status = 'PENDING') THEN
        PERFORM app.fail('WAIVER_ALREADY_PENDING', 'A waiver for this item is already waiting for approval.');
    END IF;
    INSERT INTO loan.loan_waiver (loan_id, loan_charge_id, component, amount, reason)
    VALUES (p_loan_id, p_charge_id, p_component, p_amount, p_reason)
    RETURNING id INTO v_id;
    RETURN loan.get_waiver(v_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.decide_waiver(p_waiver_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_w record;
    v_charge record;
BEGIN
    SELECT * INTO v_w FROM loan.loan_waiver WHERE tenant_id = app.tenant_id() AND id = p_waiver_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('WAIVER_NOT_FOUND', 'The waiver request was not found.');
    END IF;
    IF v_w.status <> 'PENDING' THEN
        PERFORM app.fail('REQUEST_CLOSED', format('The request is already %s.', v_w.status));
    END IF;
    PERFORM loan.assert_approver_setting('loans.waiver_approver_roles', v_w.created_by);
    IF NOT p_approve AND coalesce(p_remarks, '') = '' THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject.');
    END IF;
    IF p_approve THEN
        IF v_w.component IN ('LATE_FEE','PENALTY') THEN
            SELECT * INTO v_charge FROM loan.loan_charge
             WHERE tenant_id = app.tenant_id() AND id = v_w.loan_charge_id FOR UPDATE;
            IF v_charge.status <> 'OPEN' OR v_charge.amount - v_charge.paid_amount - v_charge.waived_amount < v_w.amount THEN
                PERFORM app.fail('WAIVER_TARGET_NOT_OPEN', 'The charge changed after the waiver was requested.');
            END IF;
            UPDATE loan.loan_charge SET waived_amount = waived_amount + v_w.amount,
                   status = CASE WHEN paid_amount + waived_amount + v_w.amount >= amount
                                 THEN CASE WHEN paid_amount > 0 THEN 'PAID' ELSE 'WAIVED' END ELSE status END,
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND id = v_w.loan_charge_id;
        ELSE
            UPDATE loan.loan_application_fee SET status = 'WAIVED', waiver_reason = v_w.reason,
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND loan_id = v_w.loan_id AND status = 'PENDING';
            IF NOT FOUND THEN
                PERFORM app.fail('WAIVER_TARGET_NOT_OPEN', 'The fee changed after the waiver was requested.');
            END IF;
            UPDATE loan.loan SET status = 'DRAFT', status_reason = 'Application fee waived',
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND id = v_w.loan_id AND status = 'FEE_PENDING';
        END IF;
    END IF;
    UPDATE loan.loan_waiver SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
           reason = CASE WHEN p_remarks IS NULL THEN reason ELSE reason || E'\nDecision: ' || p_remarks END,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_waiver_id;
    RETURN loan.get_waiver(p_waiver_id);
END
$$;

-- -----------------------------------------------------------------------------
-- Cooling-off override (scope 8.5): Manager exception to a cooling-off or
-- restriction, with reason, evidence and decision. Default history is kept.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.get_cooling_off_override(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT to_jsonb(o) - 'tenant_id' FROM loan.cooling_off_override o WHERE o.tenant_id = app.tenant_id() AND o.id = p_id
$$;

CREATE OR REPLACE FUNCTION loan.request_cooling_off_override(p_member_id uuid, p_reason text, p_evidence_document_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_member record;
    v_id uuid;
BEGIN
    SELECT id, loan_eligibility, cooling_off_until INTO v_member FROM mbr.member
     WHERE tenant_id = app.tenant_id() AND id = p_member_id AND NOT is_deleted FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('MEMBER_NOT_FOUND', 'The member was not found.');
    END IF;
    IF v_member.loan_eligibility NOT IN ('COOLING_OFF','RESTRICTED') THEN
        PERFORM app.fail('OVERRIDE_NOT_NEEDED', 'The member is not in a cooling-off period or restricted.');
    END IF;
    IF coalesce(p_reason, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required for this change.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.cooling_off_override WHERE tenant_id = app.tenant_id() AND member_id = p_member_id AND status = 'PENDING') THEN
        PERFORM app.fail('OVERRIDE_ALREADY_PENDING', 'An override for this member is already waiting for a decision.');
    END IF;
    INSERT INTO loan.cooling_off_override (member_id, loan_default_id, reason, evidence_document_id, previous_eligibility)
    VALUES (p_member_id,
            (SELECT d.id FROM loan.loan_default d JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.loan_id
              WHERE d.tenant_id = app.tenant_id() AND l.member_id = p_member_id ORDER BY d.defaulted_on DESC LIMIT 1),
            p_reason, p_evidence_document_id, v_member.loan_eligibility)
    RETURNING id INTO v_id;
    RETURN loan.get_cooling_off_override(v_id);
END
$$;

-- An approved override lets the member apply until valid_until (default 30
-- days): the member is REINSTATED and the cooling-off end date is kept as history
-- in the override row.
CREATE OR REPLACE FUNCTION loan.decide_cooling_off_override(
    p_id uuid, p_approve boolean, p_valid_until date DEFAULT NULL, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_o record;
BEGIN
    SELECT * INTO v_o FROM loan.cooling_off_override WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('OVERRIDE_NOT_FOUND', 'The override request was not found.');
    END IF;
    IF v_o.status <> 'PENDING' THEN
        PERFORM app.fail('REQUEST_CLOSED', format('The request is already %s.', v_o.status));
    END IF;
    PERFORM loan.assert_approver_setting('loans.cooling_off_override_approver_roles', coalesce(v_o.requested_by, v_o.created_by));
    IF NOT p_approve AND coalesce(p_remarks, '') = '' THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject.');
    END IF;
    IF p_approve AND EXISTS (SELECT 1 FROM loan.loan_default d JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.loan_id
                               WHERE d.tenant_id = app.tenant_id() AND l.member_id = v_o.member_id AND d.status = 'OPEN') THEN
        PERFORM app.fail('OPEN_DEFAULT_EXISTS', 'The member still has an unsettled defaulted loan.');
    END IF;
    UPDATE loan.cooling_off_override SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
           valid_until = CASE WHEN p_approve THEN coalesce(p_valid_until, app.working_date() + cfg.require_setting_int('loans.cooling_off_override_valid_days')) END,
           decided_by = app.user_id(), decided_on = app.working_date(), decision_remarks = p_remarks,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    IF p_approve THEN
        UPDATE mbr.member SET loan_eligibility = 'REINSTATED', cooling_off_until = NULL,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_o.member_id;
    END IF;
    RETURN loan.get_cooling_off_override(p_id);
END
$$;

-- -----------------------------------------------------------------------------
-- Write-off (scope 8.7): proposed when recovery failed; one authorised
-- approver (default LDR). Dr Bad Debts Written Off / Cr Loan Principal.
-- The member stays RESTRICTED. Later recovery -> Bad Debts Recovered income.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.get_write_off(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT (to_jsonb(w) - 'tenant_id') || jsonb_build_object('loan_no', l.loan_no, 'loan_status', l.status)
      FROM loan.loan_write_off w JOIN loan.loan l ON l.tenant_id = w.tenant_id AND l.id = w.loan_id
     WHERE w.tenant_id = app.tenant_id() AND w.id = p_id
$$;

CREATE OR REPLACE FUNCTION loan.propose_write_off(p_loan_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_id uuid;
BEGIN
    SELECT id, status, outstanding_principal INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_NOT_FOUND', 'The loan was not found.');
    END IF;
    IF v_loan.status NOT IN ('DEFAULTED','OVERDUE','ACTIVE','RESTRUCTURED') OR v_loan.outstanding_principal <= 0 THEN
        PERFORM app.fail('WRITE_OFF_NOT_ALLOWED', format('A loan in status %s cannot be written off.', v_loan.status));
    END IF;
    IF coalesce(p_reason, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required for this change.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_write_off WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id
                AND status IN ('PROPOSED','APPROVED')) THEN
        PERFORM app.fail('WRITE_OFF_ALREADY_PROPOSED', 'A write-off for this loan is already waiting for a decision.');
    END IF;
    INSERT INTO loan.loan_write_off (loan_id, principal_amount, reason)
    VALUES (p_loan_id, v_loan.outstanding_principal, p_reason)
    RETURNING id INTO v_id;
    RETURN loan.get_write_off(v_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.decide_write_off(p_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_w record;
    v_loan record;
    v_journal uuid;
BEGIN
    SELECT * INTO v_w FROM loan.loan_write_off WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('WRITE_OFF_NOT_FOUND', 'The write-off proposal was not found.');
    END IF;
    IF v_w.status <> 'PROPOSED' THEN
        PERFORM app.fail('REQUEST_CLOSED', format('The request is already %s.', v_w.status));
    END IF;
    PERFORM loan.assert_approver_setting('loans.write_off_approver_role', v_w.created_by);
    IF NOT p_approve THEN
        IF coalesce(p_remarks, '') = '' THEN
            PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject.');
        END IF;
        UPDATE loan.loan_write_off SET status = 'REJECTED', reason = reason || E'\nDecision: ' || p_remarks,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = p_id;
        RETURN loan.get_write_off(p_id);
    END IF;
    SELECT l.id, l.loan_no, l.member_id, l.loan_type_id, l.status, l.outstanding_principal INTO v_loan
      FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = v_w.loan_id FOR UPDATE;
    IF v_loan.outstanding_principal <> v_w.principal_amount THEN
        PERFORM app.fail('WRITE_OFF_STALE', 'The loan balance changed after the proposal; propose the write-off again.');
    END IF;
    INSERT INTO acct.journal (voucher_type, value_date, status, narration, total_amount, source_module,
                              source_entity_type, source_entity_id, source_ref)
    VALUES ('JOURNAL', app.working_date(), 'POSTED', 'Loan written off ' || v_loan.loan_no, v_w.principal_amount,
            'LOAN', 'loan.loan_write_off', p_id, p_id::text)
    RETURNING id INTO v_journal;
    INSERT INTO acct.journal_line (journal_id, line_no, account_id, debit, credit, narration, member_id, sub_entity_type, sub_entity_id)
    VALUES (v_journal, 1, loan.mapped_account('BAD_DEBTS_WRITTEN_OFF'), v_w.principal_amount, 0, 'Bad debt written off',
            v_loan.member_id, 'loan.loan', v_loan.id),
           (v_journal, 2, loan.mapped_account('LOAN_PRINCIPAL', v_loan.loan_type_id), 0, v_w.principal_amount,
            'Loan principal written off', v_loan.member_id, 'loan.loan', v_loan.id);
    UPDATE loan.loan_instalment i SET status = 'WAIVED', updated_at = now(), updated_by = app.user_id(), row_version = i.row_version + 1
      FROM loan.loan_schedule s
     WHERE s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
       AND i.tenant_id = app.tenant_id() AND i.loan_id = v_loan.id AND i.status IN ('DUE','PARTLY_PAID');
    UPDATE loan.loan_charge SET status = 'CANCELLED', updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = v_loan.id AND status = 'OPEN';
    UPDATE loan.loan SET status = 'WRITTEN_OFF', status_date = app.working_date(), status_reason = v_w.reason,
           outstanding_principal = 0, closed_on = app.working_date(),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_loan.id;
    UPDATE loan.loan_default SET status = 'WRITTEN_OFF', updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = v_loan.id AND status = 'OPEN';
    UPDATE loan.recovery_case SET status = 'WRITTEN_OFF', closed_on = app.working_date(), next_follow_up = NULL,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND loan_id = v_loan.id AND closed_on IS NULL;
    UPDATE mbr.member SET loan_eligibility = 'RESTRICTED', updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_loan.member_id AND loan_eligibility <> 'RESTRICTED';
    UPDATE loan.loan_write_off SET status = 'POSTED', journal_id = v_journal,
           reason = CASE WHEN p_remarks IS NULL THEN reason ELSE reason || E'\nDecision: ' || p_remarks END,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    RETURN loan.get_write_off(p_id);
END
$$;

-- Money received on a written-off loan: Bad Debts Recovered income.
CREATE OR REPLACE FUNCTION loan.collect_written_off_recovery(
    p_loan_id uuid, p_amount numeric, p_payment_mode text, p_payment_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_written numeric(18,2);
    v_recovered numeric(18,2);
    v_receipt uuid;
    v_journal uuid;
BEGIN
    SELECT id, member_id, status INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_NOT_FOUND', 'The loan was not found.');
    END IF;
    IF v_loan.status <> 'WRITTEN_OFF' THEN
        PERFORM app.fail('LOAN_NOT_WRITTEN_OFF', 'Only a written-off loan takes a bad debt recovery.');
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        PERFORM app.fail('INVALID_REPAYMENT_AMOUNT', 'Repayment amount must be positive');
    END IF;
    SELECT coalesce(sum(principal_amount), 0) INTO v_written FROM loan.loan_write_off
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'POSTED';
    SELECT coalesce(sum(amount), 0) INTO v_recovered FROM loan.loan_repayment
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND repayment_type = 'RECOVERY' AND status = 'POSTED';
    IF v_recovered + p_amount > v_written THEN
        PERFORM app.fail('REPAYMENT_EXCEEDS_DUES', format('Only %s remains recoverable on this loan.', v_written - v_recovered));
    END IF;
    SELECT r.cash_receipt_id, r.journal_id INTO v_receipt, v_journal
      FROM acct.post_cash_receipt(v_loan.member_id, p_amount, p_payment_mode, p_payment_reference,
                                  'BAD_DEBT_RECOVERY', 'loan.loan', p_loan_id,
                                  jsonb_build_array(jsonb_build_object('component', 'RECOVERY',
                                      'mapping_key', 'BAD_DEBTS_RECOVERED', 'amount', p_amount))) r;
    INSERT INTO loan.loan_repayment (loan_id, cash_receipt_id, repayment_type, amount, charge_amount)
    VALUES (p_loan_id, v_receipt, 'RECOVERY', p_amount, p_amount);
    INSERT INTO loan.loan_repayment_allocation (loan_repayment_id, seq, component, amount)
    SELECT id, 1, 'CHARGE', p_amount FROM loan.loan_repayment
     WHERE tenant_id = app.tenant_id() AND cash_receipt_id = v_receipt;
    RETURN jsonb_build_object('loan_id', p_loan_id, 'cash_receipt_id', v_receipt, 'journal_id', v_journal,
        'amount', p_amount, 'recovered_total', v_recovered + p_amount, 'written_off', v_written, 'status', 'POSTED');
END
$$;

GRANT EXECUTE ON FUNCTION
    loan.mapped_account(text, uuid),
    loan.assert_approver(text, uuid),
    loan.open_recovery_case(uuid, uuid),
    loan.get_recovery_case(uuid),
    loan.list_recovery_cases(text, uuid, boolean, integer, integer),
    loan.assign_recovery_case(uuid, uuid),
    loan.log_recovery_contact(uuid, jsonb),
    loan.set_recovery_status(uuid, text, text),
    loan.escalate_recovery_cases(date),
    loan.get_waiver(uuid),
    loan.list_waivers(uuid),
    loan.request_waiver(uuid, text, uuid, numeric, text),
    loan.decide_waiver(uuid, boolean, text),
    loan.get_cooling_off_override(uuid),
    loan.request_cooling_off_override(uuid, text, uuid),
    loan.decide_cooling_off_override(uuid, boolean, date, text),
    loan.get_write_off(uuid),
    loan.propose_write_off(uuid, text),
    loan.decide_write_off(uuid, boolean, text),
    loan.collect_written_off_recovery(uuid, numeric, text, text)
TO nvs_app;
