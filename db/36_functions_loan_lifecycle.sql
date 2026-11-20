-- =============================================================================
-- CFMS / NVS  -  36  Loan application lifecycle and receipt reversal
--                   (functional gap review, Nov 2026)
-- -----------------------------------------------------------------------------
-- Approval decisions (scope 28.1)
--   loan.apply_approval_decision(request, decision, reason, amount, tenure, offline jsonb)
--   loan.record_approval_decision(request, decision, reason, amount, tenure)   online
--   loan.record_offline_approval(request, details jsonb)                       offline
--       details: decision, reason, approved_amount, tenure_months, approved_by,
--                evidence_type (code), decision_date, document_id, remarks
--       Requested By, Approved By and Recorded By are three different people
--       (policy require_distinct_identities); the approver must hold the
--       approval role; the evidence type must be active and, unless its upload
--       is optional, a document is required.
--   loan.verify_offline_approval(request, result, remarks)  the approver confirms
-- Application changes (scope 6.6)
--   loan.update_application(loan, values jsonb, expected_version)  DRAFT / RETURNED
--   loan.withdraw_application(loan, reason)                        before approval
--   loan.request_loan_cancellation(loan, reason)                   APPROVED, not disbursed
--   loan.decide_loan_cancellation(id, approve, remarks)            Manager / Leadership
-- Receipt reversal (scope 7.7)
--   loan.request_repayment_reversal(repayment, reason)   latest posted repayment only
--   loan.decide_repayment_reversal(id, approve, remarks) approver roles from settings
--   loan.get_repayment_reversal(id), loan.list_repayment_reversals(loan)
-- Run as nvs. Safe to re-run.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Approval decisions
-- -----------------------------------------------------------------------------
-- Maximum concurrent loans per member (setting loans.max_concurrent_loans),
-- checked when a loan is approved and again before its first disbursement.
-- Approved but not yet disbursed loans count, so two applications made at the
-- same time cannot both go through. The member row lock serialises approvals
-- and disbursements for the same member.
CREATE OR REPLACE FUNCTION loan.assert_concurrent_loan_limit(p_loan_id uuid)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE
    v_member uuid;
    v_max integer;
    v_count integer;
BEGIN
    SELECT member_id INTO v_member FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    IF v_member IS NULL THEN RETURN; END IF;
    PERFORM 1 FROM mbr.member WHERE tenant_id = app.tenant_id() AND id = v_member FOR NO KEY UPDATE;
    SELECT max_concurrent_loans INTO v_max FROM loan.get_loan_settings();
    IF v_max IS NULL THEN RETURN; END IF;
    SELECT count(*) INTO v_count FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND member_id = v_member AND id <> p_loan_id AND NOT is_deleted
       AND status IN ('APPROVED','ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED');
    IF v_count >= v_max THEN
        PERFORM app.fail('MAX_CONCURRENT_LOANS_REACHED',
            format('The member already has %s approved or running loan(s); the limit is %s.', v_count, v_max));
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION loan.apply_approval_decision(
    p_request_id uuid, p_decision text, p_reason text, p_approved_amount numeric(18,2),
    p_tenure_months integer, p_offline jsonb DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_req record;
    v_role_id uuid;
    v_approver uuid := app.user_id();
    v_amount numeric(18,2);
    v_tenure integer;
    v_rate numeric(7,4);
    v_method text;
    v_interest numeric(18,2);
    v_old_stage text;
    v_new_stage text;
    v_instance_status text;
    v_decision_id uuid;
    v_channel text := CASE WHEN p_offline IS NULL THEN 'ONLINE' ELSE 'OFFLINE' END;
    v_approval_method text := 'ONLINE';
    v_decision_date date := app.working_date();
    v_terms jsonb;
    v_approvals jsonb;
BEGIN
    IF p_decision NOT IN ('APPROVED','REJECTED','RETURNED') THEN
        PERFORM app.fail('INVALID_APPROVAL_DECISION','Decision must be APPROVED, REJECTED, or RETURNED');
    END IF;
    IF p_decision <> 'APPROVED' AND coalesce(btrim(p_reason),'') = '' THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED','A reason is required to reject or return an application');
    END IF;
    SELECT ar.id,ar.status,ar.round_no,ar.workflow_instance_id,ar.required_role_id,ar.requested_at,
           ar.approver_roles,ar.min_approvals,ar.requested_by,
           l.id loan_id,l.requested_amount,l.requested_tenure_months,l.rule_snapshot
      INTO v_req
      FROM wf.approval_request ar
      JOIN loan.loan l ON l.tenant_id=ar.tenant_id AND l.id=ar.entity_id
     WHERE ar.tenant_id=app.tenant_id() AND ar.id=p_request_id AND ar.entity_type='loan.loan'
     FOR UPDATE OF ar,l;
    IF NOT FOUND THEN PERFORM app.fail('APPROVAL_REQUEST_NOT_FOUND','Loan approval request was not found'); END IF;
    IF v_req.status <> 'PENDING' THEN PERFORM app.fail('REQUEST_CLOSED','The approval request is no longer pending'); END IF;

    IF p_offline IS NULL THEN
        SELECT id INTO v_role_id FROM iam.role
         WHERE tenant_id=app.tenant_id() AND role_code=app.role_code() AND status='ACTIVE' LIMIT 1;
        IF v_role_id IS NULL THEN PERFORM app.fail('APPROVER_ROLE_REQUIRED','An active approver role is required'); END IF;
        -- Maker-checker before the role check (the requester never decides).
        IF v_req.requested_by = app.user_id() THEN
            PERFORM app.fail('SOD_SELF_APPROVAL', 'The approver must be a different person from the requester');
        END IF;
        -- Roles from the workflow stage (configured on the request).
        IF v_req.approver_roles IS NOT NULL AND NOT app.role_code() = ANY (v_req.approver_roles) THEN
            PERFORM app.fail('APPROVER_ROLE_REQUIRED',
                format('Only %s can decide this approval.', array_to_string(v_req.approver_roles, ', ')));
        END IF;
    ELSE
        v_approver := (p_offline->>'approved_by')::uuid;
        v_role_id := (p_offline->>'approver_role_id')::uuid;
        v_approval_method := p_offline->>'method';
        v_decision_date := (p_offline->>'decision_date')::date;
    END IF;

    v_amount := coalesce(p_approved_amount,v_req.requested_amount);
    v_tenure := coalesce(p_tenure_months,v_req.requested_tenure_months);
    IF p_decision='APPROVED' AND (v_amount <= 0 OR v_amount > v_req.requested_amount
       OR v_tenure <= 0 OR v_tenure > v_req.requested_tenure_months) THEN
        PERFORM app.fail('APPROVED_TERMS_OUT_OF_RANGE','Approved amount and term must not exceed the request');
    END IF;

    -- minApprovals: each approval is a distinct person (never the requester);
    -- the request is decided when the minimum is reached.
    IF p_decision = 'APPROVED' AND v_req.approver_roles IS NOT NULL THEN
        v_approvals := wf.add_approval(p_request_id,
            CASE WHEN p_offline IS NULL THEN app.role_code() ELSE p_offline->>'approver_role_code' END, v_approver);
        IF jsonb_array_length(v_approvals) < v_req.min_approvals THEN
            PERFORM app.set_audit_reason(format('Approval %s of %s recorded', jsonb_array_length(v_approvals),
                                                v_req.min_approvals), 'APPROVAL', p_request_id::text);
            RETURN jsonb_build_object('approval_request_id', p_request_id, 'loan_id', v_req.loan_id,
                'decision', 'APPROVAL_RECORDED', 'approval_channel', v_channel, 'approved_by', v_approver,
                'approvals', v_approvals, 'min_approvals', v_req.min_approvals,
                'approvals_needed', v_req.min_approvals - jsonb_array_length(v_approvals));
        END IF;
    END IF;

    INSERT INTO wf.approval_decision (
        approval_request_id,round_no,decision,approval_channel,approval_method,
        approved_by,approver_role_id,decision_date,recorded_by,evidence_type_id,reason,remarks
    ) VALUES (p_request_id,v_req.round_no,p_decision,v_channel,v_approval_method,v_approver,
              v_role_id,v_decision_date,app.user_id(),(p_offline->>'evidence_type_id')::uuid,p_reason,
              p_offline->>'remarks')
    RETURNING id INTO v_decision_id;
    IF p_offline ? 'document_id' AND p_offline->>'document_id' IS NOT NULL THEN
        INSERT INTO wf.approval_evidence (approval_decision_id, document_id, description)
        VALUES (v_decision_id, (p_offline->>'document_id')::uuid, 'Offline approval evidence');
    END IF;

    IF p_decision='APPROVED' THEN
        PERFORM loan.assert_concurrent_loan_limit(v_req.loan_id);
        -- Interest by the INTEREST rule's method (refuses if the rule is missing).
        v_terms := loan.interest_terms(v_req.rule_snapshot, v_amount, v_tenure);
        v_method := v_terms->>'method';
        v_rate := (v_terms->>'rate')::numeric;
        v_interest := (v_terms->>'total')::numeric;
        UPDATE loan.loan SET status='APPROVED',status_date=app.working_date(),
            approved_amount=v_amount,tenure_months=v_tenure,interest_rate_annual=v_rate,
            interest_method=v_method,total_interest=v_interest,
            instalment_amount=round((v_amount+v_interest)/v_tenure,2),
            approved_at=now(),approved_by=v_approver,approval_expires_on=app.working_date()+cfg.require_setting_int('loans.disbursement_window_days'),
            updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
         WHERE tenant_id=app.tenant_id() AND id=v_req.loan_id;
        -- Percentage application fees for AFTER_APPROVAL are based on the
        -- final approved loan amount, which can differ from the request.
        UPDATE loan.loan_application_fee f
           SET fee_amount=round(v_amount*f.fee_rate/100,2),updated_at=now(),
               updated_by=app.user_id(),row_version=f.row_version+1
         WHERE f.tenant_id=app.tenant_id() AND f.loan_id=v_req.loan_id
           AND f.fee_basis='PERCENT' AND f.collect_timing='AFTER_APPROVAL'
           AND f.status='PENDING' AND f.fee_rate IS NOT NULL;
        v_new_stage := 'APPROVED';
        v_instance_status := 'COMPLETED';
    ELSE
        v_new_stage := CASE WHEN p_decision='REJECTED' THEN 'REJECTED' ELSE 'DRAFT' END;
        v_instance_status := CASE WHEN p_decision='REJECTED' THEN 'COMPLETED' ELSE 'RUNNING' END;
        UPDATE loan.loan SET status=p_decision,status_date=app.working_date(),status_reason=p_reason,
            updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
         WHERE tenant_id=app.tenant_id() AND id=v_req.loan_id;
    END IF;
    UPDATE wf.task SET status='DONE',completed_by=app.user_id(),completed_at=now(),
        updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
     WHERE tenant_id=app.tenant_id() AND approval_request_id=p_request_id AND status IN ('OPEN','IN_PROGRESS');
    SELECT current_stage_code INTO v_old_stage FROM wf.workflow_instance
     WHERE tenant_id=app.tenant_id() AND id=v_req.workflow_instance_id FOR UPDATE;
    UPDATE wf.workflow_instance SET current_stage_code=v_new_stage,status=v_instance_status,
        completed_at=CASE WHEN v_instance_status='COMPLETED' THEN now() ELSE NULL END,
        updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
     WHERE tenant_id=app.tenant_id() AND id=v_req.workflow_instance_id;
    INSERT INTO wf.workflow_history (workflow_instance_id,from_stage_code,to_stage_code,
        trigger_event,acted_by,acted_role_code,working_date,round_no,remarks)
    VALUES (v_req.workflow_instance_id,v_old_stage,v_new_stage,p_decision,v_approver,
        CASE WHEN p_offline IS NULL THEN app.role_code() ELSE p_offline->>'approver_role_code' END,
        app.working_date(),v_req.round_no,
        CASE WHEN p_offline IS NULL THEN p_reason
             ELSE concat_ws(' ', 'Offline decision recorded by', app.user_id()::text, '-', p_reason) END);
    IF p_decision IN ('APPROVED','REJECTED') THEN
        PERFORM loan.notify_member(CASE p_decision WHEN 'APPROVED' THEN 'LOAN_APPROVED' ELSE 'LOAN_REJECTED' END,
            v_req.loan_id, jsonb_build_object('amount', v_amount, 'reason', p_reason));
    END IF;
    RETURN jsonb_build_object('approval_request_id',p_request_id,'loan_id',v_req.loan_id,
        'decision',p_decision,'approval_channel',v_channel,'approved_by',v_approver,
        'approved_amount',CASE WHEN p_decision='APPROVED' THEN v_amount END,
        'tenure_months',CASE WHEN p_decision='APPROVED' THEN v_tenure END);
END
$$;

CREATE OR REPLACE FUNCTION loan.record_approval_decision(
    p_request_id uuid, p_decision text, p_reason text DEFAULT NULL,
    p_approved_amount numeric(18,2) DEFAULT NULL, p_tenure_months integer DEFAULT NULL
)
RETURNS jsonb LANGUAGE sql AS
$$
    SELECT loan.apply_approval_decision(p_request_id, p_decision, p_reason, p_approved_amount, p_tenure_months, NULL)
$$;

-- The policy for a request: its own, else the organisation's DEFAULT policy.
CREATE OR REPLACE FUNCTION loan.request_policy(p_request_id uuid)
RETURNS wf.approval_policy LANGUAGE sql STABLE AS
$$
    SELECT p.* FROM wf.approval_policy p
     WHERE p.tenant_id = app.tenant_id() AND p.status = 'ACTIVE'
       AND (p.id = (SELECT approval_policy_id FROM wf.approval_request
                     WHERE tenant_id = app.tenant_id() AND id = p_request_id)
            OR p.code = 'DEFAULT')
     ORDER BY (p.code = 'DEFAULT'), p.effective_from DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION loan.record_offline_approval(p_request_id uuid, p_details jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_req wf.approval_request%ROWTYPE;
    v_policy wf.approval_policy;
    v_approver uuid := nullif(p_details->>'approved_by', '')::uuid;
    v_role record;
    v_evidence wf.offline_evidence_type%ROWTYPE;
    v_date date := coalesce(nullif(p_details->>'decision_date', '')::date, app.working_date());
    v_document uuid := nullif(p_details->>'document_id', '')::uuid;
BEGIN
    SELECT * INTO v_req FROM wf.approval_request
     WHERE tenant_id = app.tenant_id() AND id = p_request_id AND entity_type = 'loan.loan';
    IF NOT FOUND THEN PERFORM app.fail('APPROVAL_REQUEST_NOT_FOUND','Loan approval request was not found'); END IF;
    v_policy := loan.request_policy(p_request_id);
    -- Engine-configured requests follow the workflow stage (allowOfflineRecording);
    -- older requests follow the approval policy.
    IF v_req.approver_roles IS NOT NULL THEN
        IF v_req.allow_offline IS NOT TRUE THEN
            PERFORM app.fail('OFFLINE_NOT_ALLOWED', 'Offline decisions are not allowed for this approval.');
        END IF;
    ELSIF v_policy.id IS NOT NULL AND NOT v_policy.allow_offline THEN
        PERFORM app.fail('OFFLINE_NOT_ALLOWED', 'Offline decisions are not allowed for this approval.');
    END IF;
    IF v_approver IS NULL THEN
        PERFORM app.fail('OFFLINE_APPROVER_REQUIRED', 'Choose who gave the offline decision.');
    END IF;
    SELECT r.id, r.role_code INTO v_role
      FROM iam.app_user u
      JOIN iam.user_role ur ON ur.tenant_id = u.tenant_id AND ur.user_id = u.id
           AND ur.effective_from <= app.working_date()
           AND (ur.effective_to IS NULL OR ur.effective_to >= app.working_date())
      JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id AND r.status = 'ACTIVE'
     WHERE u.tenant_id = app.tenant_id() AND u.id = v_approver AND u.status = 'ACTIVE'
       AND CASE WHEN v_req.approver_roles IS NOT NULL THEN r.role_code = ANY (v_req.approver_roles)
                ELSE r.id = coalesce(v_req.required_role_id, v_policy.approver_role_id) END
     ORDER BY (r.id = v_req.required_role_id) DESC
     LIMIT 1;
    IF NOT FOUND THEN
        PERFORM app.fail('APPROVER_ROLE_REQUIRED', 'The person who decided does not hold the approval role.');
    END IF;
    SELECT * INTO v_evidence FROM wf.offline_evidence_type
     WHERE tenant_id = app.tenant_id() AND code = upper(p_details->>'evidence_type') AND is_active;
    IF NOT FOUND THEN
        PERFORM app.fail('EVIDENCE_TYPE_INVALID', 'Choose a valid evidence type for the offline decision.');
    END IF;
    IF NOT v_evidence.upload_optional AND v_document IS NULL THEN
        PERFORM app.fail('EVIDENCE_REQUIRED', 'Upload the evidence for this offline decision.');
    END IF;
    IF v_date > app.working_date()
       OR v_date < coalesce((SELECT working_date FROM wf.workflow_instance
                              WHERE tenant_id = app.tenant_id() AND id = v_req.workflow_instance_id),
                            v_req.requested_at::date) THEN
        PERFORM app.fail('OFFLINE_DATE_INVALID', 'The decision date must be between the request date and today.');
    END IF;
    RETURN loan.apply_approval_decision(p_request_id, upper(p_details->>'decision'), p_details->>'reason',
        nullif(p_details->>'approved_amount', '')::numeric, nullif(p_details->>'tenure_months', '')::integer,
        jsonb_build_object('approved_by', v_approver, 'approver_role_id', v_role.id,
                           'approver_role_code', v_role.role_code, 'evidence_type_id', v_evidence.id,
                           'method', CASE v_evidence.code WHEN 'VERBAL' THEN 'VERBAL' WHEN 'MEETING' THEN 'MEETING'
                                                          WHEN 'PHONE' THEN 'PHONE' WHEN 'SIGNED_PAPER' THEN 'DOCUMENT'
                                                          ELSE 'OTHER' END,
                           'decision_date', v_date, 'document_id', v_document, 'remarks', p_details->>'remarks'));
END
$$;

-- The approver confirms (or disputes) an offline decision recorded in their name.
CREATE OR REPLACE FUNCTION loan.verify_offline_approval(p_request_id uuid, p_result text, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_decision record;
BEGIN
    SELECT d.approved_by, d.approval_channel INTO v_decision FROM wf.approval_decision d
     WHERE d.tenant_id = app.tenant_id() AND d.approval_request_id = p_request_id
     ORDER BY d.created_at DESC LIMIT 1;
    IF NOT FOUND OR v_decision.approval_channel <> 'OFFLINE' THEN
        PERFORM app.fail('APPROVAL_REQUEST_NOT_FOUND', 'No offline decision was found for this request.');
    END IF;
    IF v_decision.approved_by <> app.user_id() THEN
        PERFORM app.fail('APPROVER_ROLE_REQUIRED', 'Only the person who gave the decision can verify it.');
    END IF;
    IF upper(p_result) NOT IN ('VERIFIED','DISCREPANCY') OR (upper(p_result) = 'DISCREPANCY' AND coalesce(btrim(p_remarks), '') = '') THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'Verify the decision, or describe the discrepancy.');
    END IF;
    INSERT INTO wf.approval_verification (approval_request_id, verified_by, verified_at, result, remarks)
    VALUES (p_request_id, app.user_id(), now(), upper(p_result), p_remarks);
    RETURN jsonb_build_object('approval_request_id', p_request_id, 'result', upper(p_result));
END
$$;

-- -----------------------------------------------------------------------------
-- Application changes
-- -----------------------------------------------------------------------------
-- Terms of a draft or returned application. The API re-runs the eligibility
-- checks before calling this and passes the recalculated fee_amount; without
-- it a percentage application fee that is still pending is recalculated here.
CREATE OR REPLACE FUNCTION loan.update_application(p_loan_id uuid, p_values jsonb, p_expected_version integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan loan.loan%ROWTYPE;
    v_nominee uuid;
BEGIN
    SELECT * INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application was not found'); END IF;
    IF v_loan.status NOT IN ('DRAFT','RETURNED') THEN
        PERFORM app.fail('APPLICATION_NOT_EDITABLE', 'Only a draft or returned application can be changed.');
    END IF;
    -- Draft and returned applications: loan.edit or loan.create (the maker).
    IF app.user_id() IS NOT NULL AND NOT iam.has_privilege(app.user_id(), 'loan.edit')
       AND NOT iam.has_privilege(app.user_id(), 'loan.create') THEN
        PERFORM app.fail('NO_PRIVILEGE', 'Changing a loan application needs loan.edit or loan.create');
    END IF;
    IF p_expected_version IS NOT NULL AND p_expected_version <> v_loan.row_version THEN
        PERFORM app.fail('STALE_RECORD', 'The application was changed by someone else. Refresh and try again.');
    END IF;
    UPDATE loan.loan
       SET requested_amount = coalesce(nullif(p_values->>'requested_amount', '')::numeric, requested_amount),
           requested_tenure_months = coalesce(nullif(p_values->>'requested_tenure_months', '')::integer, requested_tenure_months),
           purpose = coalesce(nullif(p_values->>'purpose', ''), purpose),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    UPDATE loan.loan_application_fee f
       SET fee_amount = coalesce(nullif(p_values->>'fee_amount', '')::numeric, round(l.requested_amount * f.fee_rate / 100, 2)),
           updated_at = now(), updated_by = app.user_id(), row_version = f.row_version + 1
      FROM loan.loan l
     WHERE f.tenant_id = app.tenant_id() AND f.loan_id = p_loan_id AND l.tenant_id = f.tenant_id AND l.id = f.loan_id
       AND f.fee_basis = 'PERCENT' AND f.status = 'PENDING' AND f.fee_rate IS NOT NULL;
    -- Nominees go through the one nominee function (loan.edit, count limit,
    -- active-nominee and stage checks, audit) like PUT /loans/{id}/nominees.
    IF jsonb_typeof(p_values->'nominee_ids') = 'array' THEN
        PERFORM loan.link_application_nominees(p_loan_id,
            ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(p_values->'nominee_ids')));
    END IF;
    RETURN (SELECT to_jsonb(a) FROM loan.get_application(p_loan_id, false) a);
END
$$;

-- Withdraw before approval: the open approval request, its task and the
-- workflow are closed. An application fee already paid is reported so the
-- office can decide on a refund.
CREATE OR REPLACE FUNCTION loan.withdraw_application(p_loan_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan loan.loan%ROWTYPE;
    v_fee text;
BEGIN
    IF coalesce(btrim(p_reason), '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'Enter the reason for withdrawing the application.');
    END IF;
    SELECT * INTO v_loan FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application was not found'); END IF;
    IF v_loan.status NOT IN ('DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED') THEN
        PERFORM app.fail('APPLICATION_NOT_WITHDRAWABLE', 'Only an application that is not yet approved can be withdrawn.');
    END IF;
    UPDATE wf.approval_request SET status = 'WITHDRAWN', closed_at = now(),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND entity_type = 'loan.loan' AND entity_id = p_loan_id AND status = 'PENDING';
    UPDATE wf.task SET status = 'CANCELLED', cancel_reason = 'Application withdrawn',
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND entity_type = 'loan.loan' AND entity_id = p_loan_id
       AND status IN ('OPEN','IN_PROGRESS');
    UPDATE wf.workflow_instance SET status = 'WITHDRAWN', current_stage_code = 'WITHDRAWN', completed_at = now(),
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND entity_type = 'loan.loan' AND entity_id = p_loan_id AND status = 'RUNNING';
    UPDATE loan.loan SET status = 'WITHDRAWN', status_date = app.working_date(), status_reason = p_reason,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    SELECT status INTO v_fee FROM loan.loan_application_fee WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id;
    RETURN jsonb_build_object('loan_id', p_loan_id, 'status', 'WITHDRAWN', 'previous_status', v_loan.status,
                              'fee_paid', coalesce(v_fee = 'PAID', false));
END
$$;

CREATE OR REPLACE FUNCTION loan.get_loan_cancellation(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT (to_jsonb(c) - 'tenant_id') || jsonb_build_object('loan_no', l.loan_no, 'loan_status', l.status)
      FROM loan.loan_cancellation c JOIN loan.loan l ON l.tenant_id = c.tenant_id AND l.id = c.loan_id
     WHERE c.tenant_id = app.tenant_id() AND c.id = p_id
$$;

CREATE OR REPLACE FUNCTION loan.request_loan_cancellation(p_loan_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_status text;
    v_id uuid;
BEGIN
    IF coalesce(btrim(p_reason), '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'Enter the reason for cancelling the loan.');
    END IF;
    SELECT status INTO v_status FROM loan.loan
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    IF v_status <> 'APPROVED' OR EXISTS (SELECT 1 FROM loan.loan_disbursement
                                          WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'PAID') THEN
        PERFORM app.fail('LOAN_NOT_CANCELLABLE', 'Only an approved loan that is not disbursed can be cancelled.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_cancellation WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id AND status = 'PENDING') THEN
        PERFORM app.fail('CANCELLATION_ALREADY_PENDING', 'A cancellation for this loan is already waiting for a decision.');
    END IF;
    INSERT INTO loan.loan_cancellation (loan_id, reason) VALUES (p_loan_id, p_reason) RETURNING id INTO v_id;
    RETURN loan.get_loan_cancellation(v_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.decide_loan_cancellation(p_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_c loan.loan_cancellation%ROWTYPE;
BEGIN
    SELECT * INTO v_c FROM loan.loan_cancellation WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('CANCELLATION_NOT_FOUND', 'The cancellation request was not found.'); END IF;
    IF v_c.status <> 'PENDING' THEN PERFORM app.fail('REQUEST_CLOSED', 'The request is no longer pending'); END IF;
    PERFORM loan.assert_approver_setting('loans.cancellation_approver_roles', v_c.requested_by);
    IF NOT p_approve AND coalesce(btrim(p_remarks), '') = '' THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject the request.');
    END IF;
    UPDATE loan.loan_cancellation
       SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, decided_by = app.user_id(),
           decided_on = app.working_date(), decision_remarks = p_remarks,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    IF p_approve THEN
        IF (SELECT status FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = v_c.loan_id FOR UPDATE) <> 'APPROVED'
           OR EXISTS (SELECT 1 FROM loan.loan_disbursement
                       WHERE tenant_id = app.tenant_id() AND loan_id = v_c.loan_id AND status = 'PAID') THEN
            PERFORM app.fail('LOAN_NOT_CANCELLABLE', 'Only an approved loan that is not disbursed can be cancelled.');
        END IF;
        UPDATE loan.loan_disbursement SET status = 'CANCELLED',
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND loan_id = v_c.loan_id AND status = 'PREPARED';
        UPDATE loan.loan SET status = 'CANCELLED', status_date = app.working_date(), status_reason = v_c.reason,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_c.loan_id;
    END IF;
    RETURN loan.get_loan_cancellation(p_id);
END
$$;

-- -----------------------------------------------------------------------------
-- Receipt reversal
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.get_repayment_reversal(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT (to_jsonb(r) - 'tenant_id') || jsonb_build_object('receipt_no', c.receipt_no, 'amount', p.amount,
                                                              'repayment_status', p.status)
      FROM loan.repayment_reversal r
      JOIN loan.loan_repayment p ON p.tenant_id = r.tenant_id AND p.id = r.loan_repayment_id
      JOIN acct.cash_receipt c ON c.tenant_id = r.tenant_id AND c.id = r.cash_receipt_id
     WHERE r.tenant_id = app.tenant_id() AND r.id = p_id
$$;

CREATE OR REPLACE FUNCTION loan.list_repayment_reversals(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg(loan.get_repayment_reversal(r.id) ORDER BY r.created_at DESC), '[]'::jsonb)
      FROM loan.repayment_reversal r WHERE r.tenant_id = app.tenant_id() AND r.loan_id = p_loan_id
$$;

-- Checks shared by the request and the final approval.
CREATE OR REPLACE FUNCTION loan.assert_repayment_reversible(p_repayment_id uuid)
RETURNS loan.loan_repayment LANGUAGE plpgsql AS
$$
DECLARE
    v_rep loan.loan_repayment%ROWTYPE;
    v_loan_status text;
BEGIN
    SELECT * INTO v_rep FROM loan.loan_repayment WHERE tenant_id = app.tenant_id() AND id = p_repayment_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('REPAYMENT_NOT_FOUND', 'The repayment was not found.'); END IF;
    SELECT status INTO v_loan_status FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = v_rep.loan_id FOR UPDATE;
    IF v_rep.status <> 'POSTED' OR v_rep.cash_receipt_id IS NULL
       OR v_rep.repayment_type NOT IN ('REGULAR','PARTIAL','LUMP_SUM')
       OR v_loan_status NOT IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED','CLOSED') THEN
        PERFORM app.fail('REVERSAL_NOT_ALLOWED', 'This receipt cannot be reversed.');
    END IF;
    -- Receipt numbers break ties between repayments posted in one transaction.
    IF EXISTS (SELECT 1 FROM loan.loan_repayment x
                 JOIN acct.cash_receipt xc ON xc.tenant_id = x.tenant_id AND xc.id = x.cash_receipt_id
                 JOIN acct.cash_receipt vc ON vc.tenant_id = x.tenant_id AND vc.id = v_rep.cash_receipt_id
                WHERE x.tenant_id = app.tenant_id() AND x.loan_id = v_rep.loan_id AND x.status = 'POSTED'
                  AND x.id <> v_rep.id
                  AND (x.created_at, length(xc.receipt_no), xc.receipt_no) > (v_rep.created_at, length(vc.receipt_no), vc.receipt_no)) THEN
        PERFORM app.fail('REVERSAL_NOT_LATEST', 'Only the latest receipt of a loan can be reversed. Reverse the later receipts first.');
    END IF;
    RETURN v_rep;
END
$$;

CREATE OR REPLACE FUNCTION loan.request_repayment_reversal(p_repayment_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_rep loan.loan_repayment%ROWTYPE;
    v_receipt acct.cash_receipt%ROWTYPE;
    v_after boolean;
    v_roles text[];
    v_id uuid;
BEGIN
    IF coalesce(btrim(p_reason), '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'Enter the reason for reversing the receipt.');
    END IF;
    v_rep := loan.assert_repayment_reversible(p_repayment_id);
    IF EXISTS (SELECT 1 FROM loan.repayment_reversal
                WHERE tenant_id = app.tenant_id() AND loan_repayment_id = p_repayment_id AND status = 'PENDING') THEN
        PERFORM app.fail('REVERSAL_ALREADY_PENDING', 'A reversal of this receipt is already waiting for approval.');
    END IF;
    SELECT * INTO v_receipt FROM acct.cash_receipt WHERE tenant_id = app.tenant_id() AND id = v_rep.cash_receipt_id;
    v_after := app.working_date() > v_receipt.value_date
               OR EXISTS (SELECT 1 FROM acct.cash_day d
                           WHERE d.tenant_id = app.tenant_id() AND d.cash_account_id = v_receipt.cash_account_id
                             AND d.business_date = v_receipt.value_date AND d.status = 'CLOSED');
    IF v_after THEN
        v_roles := cfg.setting_roles('cash.receipt_cancel_after_close_approvers');
    ELSE
        v_roles := cfg.setting_roles('cash.receipt_cancel_same_day_approver');
    END IF;
    INSERT INTO loan.repayment_reversal (loan_id, loan_repayment_id, cash_receipt_id, reason, after_day_close, required_roles)
    VALUES (v_rep.loan_id, v_rep.id, v_rep.cash_receipt_id, p_reason, v_after, v_roles)
    RETURNING id INTO v_id;
    RETURN loan.get_repayment_reversal(v_id);
END
$$;

-- Undo the repayment: allocations, charges, schedule (after a prepayment),
-- balances and status; post the reversal journal and cancel the receipt.
CREATE OR REPLACE FUNCTION loan.execute_repayment_reversal(p_id uuid)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_r loan.repayment_reversal%ROWTYPE;
    v_rep loan.loan_repayment%ROWTYPE;
    v_loan record;
    v_receipt acct.cash_receipt%ROWTYPE;
    v_alloc record;
    v_current record;
    v_journal uuid;
    v_status text;
    v_overdue boolean;
    v_open boolean;
BEGIN
    SELECT * INTO v_r FROM loan.repayment_reversal WHERE tenant_id = app.tenant_id() AND id = p_id;
    v_rep := loan.assert_repayment_reversible(v_r.loan_repayment_id);
    SELECT id, status, is_restructured, rule_snapshot, outstanding_principal, member_id, loan_no
      INTO v_loan FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = v_rep.loan_id FOR UPDATE;
    SELECT * INTO v_receipt FROM acct.cash_receipt WHERE tenant_id = app.tenant_id() AND id = v_rep.cash_receipt_id FOR UPDATE;

    -- A prepayment created a new schedule version: go back to the previous one.
    IF v_rep.excess_to_principal > 0 THEN
        SELECT s.id, s.previous_schedule_id, s.reason, s.created_at INTO v_current
          FROM loan.loan_schedule s WHERE s.tenant_id = app.tenant_id() AND s.loan_id = v_loan.id AND s.is_current;
        IF v_current.reason <> 'PREPAYMENT' OR v_current.previous_schedule_id IS NULL
           OR v_current.created_at < v_rep.created_at THEN
            PERFORM app.fail('REVERSAL_NOT_ALLOWED', 'The schedule changed after this receipt; it cannot be reversed.');
        END IF;
        UPDATE loan.loan_schedule SET is_current = false,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_current.id;
        UPDATE loan.loan_schedule SET is_current = true,
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_current.previous_schedule_id;
        UPDATE loan.loan l
           SET maturity_date = x.maturity, instalment_amount = x.instalment,
               updated_at = now(), updated_by = app.user_id(), row_version = l.row_version + 1
          FROM (SELECT max(due_date) AS maturity,
                       (array_agg(principal_due + interest_due ORDER BY instalment_no))[1] AS instalment
                  FROM loan.loan_instalment
                 WHERE tenant_id = app.tenant_id() AND loan_schedule_id = v_current.previous_schedule_id
                   AND status NOT IN ('CANCELLED','WAIVED')) x
         WHERE l.tenant_id = app.tenant_id() AND l.id = v_loan.id;
    END IF;

    FOR v_alloc IN
        SELECT * FROM loan.loan_repayment_allocation
         WHERE tenant_id = app.tenant_id() AND loan_repayment_id = v_rep.id ORDER BY seq DESC
    LOOP
        IF v_alloc.loan_charge_id IS NOT NULL THEN
            UPDATE loan.loan_charge SET paid_amount = paid_amount - v_alloc.amount,
                   status = CASE WHEN status = 'PAID' THEN 'OPEN' ELSE status END,
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND id = v_alloc.loan_charge_id;
            IF v_alloc.component = 'LATE_FEE' THEN
                UPDATE loan.loan_instalment SET late_fee_paid = greatest(late_fee_paid - v_alloc.amount, 0),
                       updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
                 WHERE tenant_id = app.tenant_id()
                   AND id = (SELECT loan_instalment_id FROM loan.loan_charge
                              WHERE tenant_id = app.tenant_id() AND id = v_alloc.loan_charge_id);
            END IF;
        ELSIF v_alloc.loan_instalment_id IS NOT NULL THEN
            UPDATE loan.loan_instalment
               SET interest_paid = interest_paid - CASE WHEN v_alloc.component = 'INTEREST' THEN v_alloc.amount ELSE 0 END,
                   principal_paid = principal_paid - CASE WHEN v_alloc.component = 'PRINCIPAL' THEN v_alloc.amount ELSE 0 END,
                   updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
             WHERE tenant_id = app.tenant_id() AND id = v_alloc.loan_instalment_id;
            UPDATE loan.loan_instalment
               SET status = CASE WHEN principal_paid = 0 AND interest_paid = 0 THEN 'DUE' ELSE 'PARTLY_PAID' END,
                   paid_on = NULL
             WHERE tenant_id = app.tenant_id() AND id = v_alloc.loan_instalment_id;
        END IF;
    END LOOP;

    -- Balance and status
    SELECT EXISTS (SELECT 1 FROM loan.loan_instalment i
                     JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
                    WHERE i.tenant_id = app.tenant_id() AND i.loan_id = v_loan.id AND i.status IN ('DUE','PARTLY_PAID')
                      AND i.due_date + loan.grace_days(v_loan.rule_snapshot) < app.working_date())
      INTO v_overdue;
    v_status := CASE WHEN v_loan.status = 'DEFAULTED' THEN 'DEFAULTED'
                     WHEN v_overdue THEN 'OVERDUE'
                     WHEN v_loan.status IN ('CLOSED','OVERDUE') THEN CASE WHEN v_loan.is_restructured THEN 'RESTRUCTURED' ELSE 'ACTIVE' END
                     ELSE v_loan.status END;
    UPDATE loan.loan
       SET outstanding_principal = outstanding_principal + v_rep.principal_amount,
           status = v_status,
           status_date = CASE WHEN v_status <> v_loan.status THEN app.working_date() ELSE status_date END,
           status_reason = CASE WHEN v_status <> v_loan.status THEN 'Receipt ' || v_receipt.receipt_no || ' reversed' ELSE status_reason END,
           closed_on = CASE WHEN v_status <> 'CLOSED' THEN NULL ELSE closed_on END,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_loan.id;

    -- Reversal journal (lines mirrored) and receipt cancellation
    INSERT INTO acct.journal (voucher_type, value_date, status, narration, total_amount, source_module,
                              source_entity_type, source_entity_id, source_ref, reversal_of_journal_id, reversal_reason)
    VALUES ('REVERSAL', app.working_date(), 'POSTED', 'Reversal of receipt ' || v_receipt.receipt_no, v_receipt.amount,
            'LOAN', 'acct.cash_receipt', v_receipt.id, v_receipt.id::text, v_receipt.journal_id, v_r.reason)
    RETURNING id INTO v_journal;
    INSERT INTO acct.journal_line (journal_id, line_no, account_id, fund_id, debit, credit, narration, member_id,
                                   sub_entity_type, sub_entity_id)
    SELECT v_journal, line_no, account_id, fund_id, credit, debit, 'Reversal: ' || coalesce(narration, ''), member_id,
           sub_entity_type, sub_entity_id
      FROM acct.journal_line WHERE tenant_id = app.tenant_id() AND journal_id = v_receipt.journal_id;
    UPDATE acct.journal SET status = 'REVERSED', reversed_by_journal_id = v_journal, reversal_reason = v_r.reason,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_receipt.journal_id;
    UPDATE acct.cash_receipt SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = app.user_id(),
           cancel_reason = v_r.reason, reversal_journal_id = v_journal,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_receipt.id;
    UPDATE loan.loan_repayment SET status = 'REVERSED', reversal_reason = v_r.reason,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = v_rep.id;
    PERFORM loan.notify_member('RECEIPT_CANCELLED', v_loan.id,
        jsonb_build_object('receipt_no', v_receipt.receipt_no, 'amount', v_receipt.amount, 'reason', v_r.reason));
    RETURN v_journal;
END
$$;

CREATE OR REPLACE FUNCTION loan.decide_repayment_reversal(p_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_r loan.repayment_reversal%ROWTYPE;
    v_role text := app.role_code();
    v_approvals jsonb;
    v_journal uuid;
BEGIN
    SELECT * INTO v_r FROM loan.repayment_reversal WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('REVERSAL_NOT_FOUND', 'The reversal request was not found.'); END IF;
    IF v_r.status <> 'PENDING' THEN PERFORM app.fail('REQUEST_CLOSED', 'The request is no longer pending'); END IF;
    IF v_r.requested_by = app.user_id() THEN
        PERFORM app.fail('SOD_SELF_APPROVAL', 'The approver must be a different person from the requester');
    END IF;
    IF NOT v_role = ANY (v_r.required_roles)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_r.approvals) a
                   WHERE a->>'role' = v_role OR a->>'user_id' = app.user_id()::text) THEN
        PERFORM app.fail('APPROVER_ROLE_REQUIRED', 'Your role is not an outstanding approver for this reversal.');
    END IF;
    IF NOT p_approve THEN
        IF coalesce(btrim(p_remarks), '') = '' THEN
            PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject the request.');
        END IF;
        UPDATE loan.repayment_reversal SET status = 'REJECTED', decided_by = app.user_id(), decided_at = now(),
               decision_remarks = p_remarks, updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = p_id;
        RETURN loan.get_repayment_reversal(p_id);
    END IF;
    v_approvals := v_r.approvals || jsonb_build_array(jsonb_build_object('role', v_role, 'user_id', app.user_id(),
                                                                         'at', now(), 'remarks', p_remarks));
    UPDATE loan.repayment_reversal SET approvals = v_approvals,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    IF NOT EXISTS (SELECT 1 FROM unnest(v_r.required_roles) rr
                    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_approvals) a WHERE a->>'role' = rr)) THEN
        v_journal := loan.execute_repayment_reversal(p_id);
        UPDATE loan.repayment_reversal SET status = 'APPROVED', decided_by = app.user_id(), decided_at = now(),
               decision_remarks = p_remarks, reversal_journal_id = v_journal
         WHERE tenant_id = app.tenant_id() AND id = p_id;
    END IF;
    RETURN loan.get_repayment_reversal(p_id);
END
$$;
