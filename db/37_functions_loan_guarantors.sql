-- =============================================================================
-- CFMS / NVS  -  37  Guarantors and eligibility exposure (functional gap review)
-- -----------------------------------------------------------------------------
-- Eligibility inputs the API combines with the loan type rules (scope 6.2, 6.9):
--   loan.get_member_exposure(member, loan_type) -> jsonb
--     date_of_birth, open loans of this type, member and household outstanding,
--     overdue chit and contribution dues, and the organisation settings
--     loans.age_limits, loans.exposure_limits, loans.guarantors_required,
--     loans.guarantor_limits (a loan type rule with the same meaning wins in the API).
-- Guarantors
--   loan.list_guarantors(loan)
--   loan.add_guarantor(loan, details jsonb)       DRAFT / RETURNED / FEE_PENDING
--       details: guarantor_member_id | non_member_name + non_member_mobile (+ address),
--                guaranteed_amount (default the requested amount), consent_type
--                (SIGNATURE / THUMB_IMPRESSION), consent_document_id
--   loan.remove_guarantor(guarantor)              before submission only
--   loan.request_guarantor_replacement(guarantor, new jsonb, reason)  running loan
--   loan.decide_guarantor_replacement(id, approve, remarks)           Manager / Leadership
--   Guarantees are released when the loan closes, is settled, or ends before
--   disbursement (trigger loan_guarantor_release). A member cannot exit while
--   a guarantee is open (mbr.open_obligations, script 13).
-- Run as nvs. Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION loan.household_member_ids(p_member_id uuid)
RETURNS uuid[] LANGUAGE sql STABLE AS
$$
    SELECT array_agg(DISTINCT x) FROM (
        SELECT p_member_id AS x
        UNION SELECT f.linked_member_id FROM mbr.member_family f
         WHERE f.tenant_id = app.tenant_id() AND f.member_id = p_member_id AND f.linked_member_id IS NOT NULL AND NOT f.is_deleted
        UNION SELECT f.member_id FROM mbr.member_family f
         WHERE f.tenant_id = app.tenant_id() AND f.linked_member_id = p_member_id AND NOT f.is_deleted
    ) h
$$;

CREATE OR REPLACE FUNCTION loan.get_member_exposure(p_member_id uuid, p_loan_type_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object(
        'date_of_birth', m.date_of_birth,
        'type_loan_count', (SELECT count(*) FROM loan.loan l
                             WHERE l.tenant_id = m.tenant_id AND l.member_id = m.id AND NOT l.is_deleted
                               AND l.loan_type_id = p_loan_type_id
                               AND l.status IN ('APPROVED','ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')),
        'member_outstanding', (SELECT coalesce(sum(l.outstanding_principal), 0) FROM loan.loan l
                                WHERE l.tenant_id = m.tenant_id AND l.member_id = m.id AND NOT l.is_deleted
                                  AND l.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')),
        'household_outstanding', (SELECT coalesce(sum(l.outstanding_principal), 0) FROM loan.loan l
                                   WHERE l.tenant_id = m.tenant_id AND l.member_id = ANY (loan.household_member_ids(m.id))
                                     AND NOT l.is_deleted AND l.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')),
        'overdue_chit_dues', EXISTS (SELECT 1 FROM chit.chit_instalment i
                                       JOIN chit.chit_ticket k ON k.tenant_id = i.tenant_id AND k.id = i.chit_ticket_id
                                      WHERE i.tenant_id = m.tenant_id AND k.member_id = m.id
                                        AND i.status IN ('DUE','PARTLY_PAID','DEFAULTED') AND i.due_date < app.working_date()),
        'overdue_contribution_dues', EXISTS (SELECT 1 FROM ops.contribution_due d
                                              WHERE d.tenant_id = m.tenant_id AND d.member_id = m.id
                                                AND d.status IN ('DUE','PARTLY_PAID') AND d.due_date < app.working_date()),
        'age_limits', coalesce(cfg.get_setting('loans.age_limits'), '{"minAtApplication":18}'::jsonb),
        'exposure_limits', coalesce(cfg.get_setting('loans.exposure_limits'), '{}'::jsonb),
        'guarantors_required', coalesce(cfg.get_setting('loans.guarantors_required'), '{"count":0}'::jsonb),
        'guarantor_limits', coalesce(cfg.get_setting('loans.guarantor_limits'), '{"maxActiveGuarantees":2}'::jsonb))
      FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_member_id AND NOT m.is_deleted
$$;

CREATE OR REPLACE FUNCTION loan.list_guarantors(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg((to_jsonb(g) - 'tenant_id') || jsonb_build_object('guarantor_name', coalesce(m.full_name, g.non_member_name),
                                                                               'guarantor_member_no', m.member_no)
                              ORDER BY g.created_at), '[]'::jsonb)
      FROM loan.loan_guarantor g
      LEFT JOIN mbr.member m ON m.tenant_id = g.tenant_id AND m.id = g.guarantor_member_id
     WHERE g.tenant_id = app.tenant_id() AND g.loan_id = p_loan_id
$$;

-- Limits on the person standing as guarantor (rule GUARANTOR_LIMITS of the
-- loan, else setting loans.guarantor_limits {"maxActiveGuarantees":2,
-- "maxGuaranteedTotal":null}): an Active member in good standing, not the
-- borrower, within the number and amount of open guarantees.
CREATE OR REPLACE FUNCTION loan.assert_guarantor_allowed(p_loan_id uuid, p_member_id uuid, p_amount numeric)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_member record;
    v_limits jsonb;
    v_count integer;
    v_total numeric;
BEGIN
    SELECT l.member_id, l.rule_snapshot INTO v_loan FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id;
    IF p_member_id IS NULL THEN RETURN; END IF;
    IF p_member_id = v_loan.member_id THEN
        PERFORM app.fail('GUARANTOR_IS_BORROWER', 'The borrower cannot be their own guarantor.');
    END IF;
    SELECT status, loan_eligibility INTO v_member FROM mbr.member
     WHERE tenant_id = app.tenant_id() AND id = p_member_id AND NOT is_deleted;
    IF NOT FOUND OR v_member.status <> 'ACTIVE' OR v_member.loan_eligibility NOT IN ('ELIGIBLE','REINSTATED') THEN
        PERFORM app.fail('GUARANTOR_NOT_ELIGIBLE', 'The guarantor must be an active member in good standing.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.loan_guarantor WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id
                  AND guarantor_member_id = p_member_id AND status IN ('ACTIVE','INVOKED')) THEN
        PERFORM app.fail('GUARANTOR_ALREADY_ADDED', 'This member is already a guarantor for the loan.');
    END IF;
    v_limits := coalesce(loan.rule(v_loan.rule_snapshot, 'GUARANTOR_LIMITS')->'value',
                         cfg.get_setting('loans.guarantor_limits'), '{"maxActiveGuarantees":2}'::jsonb);
    SELECT count(*), coalesce(sum(g.guaranteed_amount), 0) INTO v_count, v_total
      FROM loan.loan_guarantor g JOIN loan.loan l ON l.tenant_id = g.tenant_id AND l.id = g.loan_id
     WHERE g.tenant_id = app.tenant_id() AND g.guarantor_member_id = p_member_id AND g.status IN ('ACTIVE','INVOKED')
       AND l.status NOT IN ('REJECTED','WITHDRAWN','CANCELLED','CLOSED','SETTLED');
    IF (v_limits->>'maxActiveGuarantees') IS NOT NULL AND v_count >= (v_limits->>'maxActiveGuarantees')::integer THEN
        PERFORM app.fail('GUARANTOR_LIMIT_REACHED', 'The member already stands guarantor for the maximum number of loans.');
    END IF;
    IF (v_limits->>'maxGuaranteedTotal') IS NOT NULL AND v_total + p_amount > (v_limits->>'maxGuaranteedTotal')::numeric THEN
        PERFORM app.fail('GUARANTOR_LIMIT_REACHED', 'The guarantee would take the member above the maximum guaranteed amount.');
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION loan.insert_guarantor(p_loan_id uuid, p_details jsonb)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_member uuid := nullif(p_details->>'guarantor_member_id', '')::uuid;
    v_amount numeric := coalesce(nullif(p_details->>'guaranteed_amount', '')::numeric,
                                 (SELECT coalesce(approved_amount, requested_amount) FROM loan.loan
                                   WHERE tenant_id = app.tenant_id() AND id = p_loan_id));
    v_consent text := upper(coalesce(p_details->>'consent_type', ''));
    v_id uuid;
BEGIN
    IF v_member IS NULL AND (coalesce(btrim(p_details->>'non_member_name'), '') = '' OR coalesce(btrim(p_details->>'non_member_mobile'), '') = '') THEN
        PERFORM app.fail('GUARANTOR_DETAILS_REQUIRED', 'Choose a member, or enter the name and mobile of the guarantor.');
    END IF;
    IF v_consent NOT IN ('SIGNATURE','THUMB_IMPRESSION') THEN
        PERFORM app.fail('GUARANTOR_CONSENT_REQUIRED', 'Record the guarantor''s signature or thumb impression.');
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
        PERFORM app.fail('INVALID_GUARANTEED_AMOUNT', 'The guaranteed amount must be positive.');
    END IF;
    PERFORM loan.assert_guarantor_allowed(p_loan_id, v_member, v_amount);
    INSERT INTO loan.loan_guarantor (loan_id, guarantor_member_id, non_member_name, non_member_mobile, non_member_address,
                                     guaranteed_amount, consent_type, consent_document_id, status)
    VALUES (p_loan_id, v_member, CASE WHEN v_member IS NULL THEN p_details->>'non_member_name' END,
            CASE WHEN v_member IS NULL THEN p_details->>'non_member_mobile' END,
            CASE WHEN v_member IS NULL THEN p_details->>'non_member_address' END,
            v_amount, v_consent, nullif(p_details->>'consent_document_id', '')::uuid, 'ACTIVE')
    RETURNING id INTO v_id;
    RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION loan.add_guarantor(p_loan_id uuid, p_details jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_status text;
BEGIN
    SELECT status INTO v_status FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application was not found'); END IF;
    IF v_status NOT IN ('DRAFT','RETURNED','FEE_PENDING') THEN
        PERFORM app.fail('APPLICATION_NOT_EDITABLE', 'Guarantors of a submitted loan are changed by a replacement request.');
    END IF;
    PERFORM loan.insert_guarantor(p_loan_id, p_details);
    RETURN loan.list_guarantors(p_loan_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.remove_guarantor(p_guarantor_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_g record;
BEGIN
    SELECT g.id, g.loan_id, l.status INTO v_g FROM loan.loan_guarantor g
      JOIN loan.loan l ON l.tenant_id = g.tenant_id AND l.id = g.loan_id
     WHERE g.tenant_id = app.tenant_id() AND g.id = p_guarantor_id FOR UPDATE OF g;
    IF NOT FOUND THEN PERFORM app.fail('GUARANTOR_NOT_FOUND', 'The guarantor was not found.'); END IF;
    IF v_g.status NOT IN ('DRAFT','RETURNED','FEE_PENDING') THEN
        PERFORM app.fail('APPLICATION_NOT_EDITABLE', 'Guarantors of a submitted loan are changed by a replacement request.');
    END IF;
    DELETE FROM loan.loan_guarantor WHERE tenant_id = app.tenant_id() AND id = p_guarantor_id;
    RETURN loan.list_guarantors(v_g.loan_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.get_guarantor_replacement(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT to_jsonb(r) - 'tenant_id' FROM loan.guarantor_replacement r WHERE r.tenant_id = app.tenant_id() AND r.id = p_id
$$;

CREATE OR REPLACE FUNCTION loan.request_guarantor_replacement(p_guarantor_id uuid, p_new jsonb, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_g record;
    v_id uuid;
BEGIN
    IF coalesce(btrim(p_reason), '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'Enter the reason for replacing the guarantor.');
    END IF;
    SELECT g.id, g.loan_id, g.status, l.status AS loan_status INTO v_g FROM loan.loan_guarantor g
      JOIN loan.loan l ON l.tenant_id = g.tenant_id AND l.id = g.loan_id
     WHERE g.tenant_id = app.tenant_id() AND g.id = p_guarantor_id;
    IF NOT FOUND THEN PERFORM app.fail('GUARANTOR_NOT_FOUND', 'The guarantor was not found.'); END IF;
    IF v_g.status NOT IN ('ACTIVE','INVOKED')
       OR v_g.loan_status NOT IN ('SUBMITTED','UNDER_APPROVAL','APPROVED','ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED') THEN
        PERFORM app.fail('GUARANTOR_NOT_REPLACEABLE', 'Only an open guarantee on a submitted or running loan can be replaced.');
    END IF;
    IF EXISTS (SELECT 1 FROM loan.guarantor_replacement WHERE tenant_id = app.tenant_id()
                  AND loan_guarantor_id = p_guarantor_id AND status = 'PENDING') THEN
        PERFORM app.fail('REPLACEMENT_ALREADY_PENDING', 'A replacement for this guarantor is already waiting for a decision.');
    END IF;
    -- Validate the new guarantor now so the approver sees a request that can be applied.
    PERFORM loan.assert_guarantor_allowed(v_g.loan_id, nullif(p_new->>'guarantor_member_id', '')::uuid,
        coalesce(nullif(p_new->>'guaranteed_amount', '')::numeric,
                 (SELECT guaranteed_amount FROM loan.loan_guarantor WHERE tenant_id = app.tenant_id() AND id = p_guarantor_id)));
    IF upper(coalesce(p_new->>'consent_type', '')) NOT IN ('SIGNATURE','THUMB_IMPRESSION') THEN
        PERFORM app.fail('GUARANTOR_CONSENT_REQUIRED', 'Record the new guarantor''s signature or thumb impression.');
    END IF;
    INSERT INTO loan.guarantor_replacement (loan_id, loan_guarantor_id, new_guarantor, reason)
    VALUES (v_g.loan_id, p_guarantor_id, p_new, p_reason) RETURNING id INTO v_id;
    RETURN loan.get_guarantor_replacement(v_id);
END
$$;

CREATE OR REPLACE FUNCTION loan.decide_guarantor_replacement(p_id uuid, p_approve boolean, p_remarks text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_r loan.guarantor_replacement%ROWTYPE;
    v_old loan.loan_guarantor%ROWTYPE;
    v_new uuid;
BEGIN
    SELECT * INTO v_r FROM loan.guarantor_replacement WHERE tenant_id = app.tenant_id() AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('REPLACEMENT_NOT_FOUND', 'The replacement request was not found.'); END IF;
    IF v_r.status <> 'PENDING' THEN PERFORM app.fail('REQUEST_CLOSED', 'The request is no longer pending'); END IF;
    PERFORM loan.assert_approver('MGR,LDR', v_r.requested_by);
    IF NOT p_approve AND coalesce(btrim(p_remarks), '') = '' THEN
        PERFORM app.fail('APPROVAL_REASON_REQUIRED', 'A reason is required to reject the request.');
    END IF;
    IF p_approve THEN
        SELECT * INTO v_old FROM loan.loan_guarantor WHERE tenant_id = app.tenant_id() AND id = v_r.loan_guarantor_id FOR UPDATE;
        v_new := loan.insert_guarantor(v_r.loan_id,
            jsonb_build_object('guaranteed_amount', v_old.guaranteed_amount) || v_r.new_guarantor);
        UPDATE loan.loan_guarantor SET status = 'REPLACED', replaced_by_id = v_new, released_on = app.working_date(),
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = app.tenant_id() AND id = v_old.id;
    END IF;
    UPDATE loan.guarantor_replacement
       SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, decided_by = app.user_id(),
           decided_on = app.working_date(), decision_remarks = p_remarks, new_loan_guarantor_id = v_new,
           updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_id;
    RETURN loan.get_guarantor_replacement(p_id);
END
$$;

-- Guarantees end with the loan.
CREATE OR REPLACE FUNCTION loan.trg_loan_guarantor_release()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.status IN ('CLOSED','SETTLED','REJECTED','WITHDRAWN','CANCELLED') AND NEW.status IS DISTINCT FROM OLD.status THEN
        UPDATE loan.loan_guarantor SET status = 'RELEASED', released_on = app.working_date(),
               updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
         WHERE tenant_id = NEW.tenant_id AND loan_id = NEW.id AND status IN ('ACTIVE','INVOKED');
    END IF;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS loan_guarantor_release ON loan.loan;
CREATE TRIGGER loan_guarantor_release AFTER UPDATE OF status ON loan.loan
    FOR EACH ROW EXECUTE FUNCTION loan.trg_loan_guarantor_release();
