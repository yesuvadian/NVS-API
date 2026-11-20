-- =============================================================================
-- CFMS / NVS  -  30  Provisioning and administration functions
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
--   acct.create_financial_year(tenant, start_date)  -> FY + 12 monthly periods
--   platform.provision_tenant(...)                  -> creates an organisation:
--        tenant, default branch, modules, privilege ceiling, standard roles and
--        privileges, settings from the published default template, compliance
--        features, chart of accounts, cash account, General Fund, financial
--        year, lookups, actions, rule sets, loan types, workflows, approval
--        policy, notification templates, purge policies and the default
--        organisation administrator user (Web access, ADM role).
--   platform.set_module_enabled(...)                -> enable / disable a module
--   platform.apply_module_accounts(tenant, module)  -> template accounts of a module
--   loan.rule / grace_days / default_after_months / round_amount -> loan rule helpers
-- =============================================================================

-- Loan rule helpers. A loan keeps the rule-set definition it was created under in
-- loan.rule_snapshot ({"rules":[{"code":..,"value":..}]}); these read it.
CREATE OR REPLACE FUNCTION loan.rule(p_snapshot jsonb, p_code text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT r FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(p_snapshot->'rules') = 'array' THEN p_snapshot->'rules' ELSE '[]'::jsonb END) r
     WHERE r->>'code' = p_code
     LIMIT 1
$$;

-- Days after the due date before an unpaid instalment makes the loan overdue.
CREATE OR REPLACE FUNCTION loan.grace_days(p_snapshot jsonb)
RETURNS integer LANGUAGE sql IMMUTABLE AS
$$
    SELECT greatest(coalesce((loan.rule(p_snapshot, 'LATE_FEE')->'value'->>'graceDays')::integer, 0), 0)
$$;

-- Unpaid months before default: the loan's rule, else the tenant setting, else 2.
CREATE OR REPLACE FUNCTION loan.default_after_months(p_snapshot jsonb)
RETURNS integer LANGUAGE sql STABLE AS
$$
    SELECT greatest(coalesce((loan.rule(p_snapshot, 'DEFAULT_AFTER_MONTHS')->>'value')::integer,
                             cfg.require_setting_int('loans.default_after_months')), 1)
$$;

-- Rounds an amount with a rounding setting such as {"mode":"NEAREST","precision":1}.
CREATE OR REPLACE FUNCTION loan.round_amount(p_amount numeric, p_rule jsonb)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS
$$
DECLARE
    v_precision numeric := coalesce(nullif(p_rule->>'precision', '')::numeric, 0.01);
    v_mode text := upper(coalesce(p_rule->>'mode', 'NONE'));
BEGIN
    IF p_amount IS NULL THEN RETURN NULL; END IF;
    IF v_precision <= 0 THEN v_precision := 0.01; END IF;
    RETURN round(CASE v_mode
        WHEN 'NEAREST' THEN round(p_amount / v_precision) * v_precision
        WHEN 'FLOOR'   THEN floor(p_amount / v_precision) * v_precision
        WHEN 'CEIL'    THEN ceil(p_amount / v_precision) * v_precision
        WHEN 'CEILING' THEN ceil(p_amount / v_precision) * v_precision
        ELSE p_amount END, 2);
END
$$;

-- Accounting transaction API used by tenant services. Keep receipt numbering,
-- cash/account mapping resolution, and journal posting inside the database so
-- all callers share the same atomic controls.
CREATE OR REPLACE FUNCTION acct.post_cash_receipt(
    p_member_id uuid,
    p_amount numeric(18,2),
    p_payment_mode text,
    p_payment_reference text,
    p_purpose text,
    p_source_entity_type text,
    p_source_entity_id uuid,
    p_lines jsonb
)
RETURNS TABLE (cash_receipt_id uuid, journal_id uuid)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_tenant uuid := app.tenant_id();
    v_member mbr.member%ROWTYPE;
    v_cash acct.cash_account%ROWTYPE;
    v_receipt_id uuid;
    v_journal_id uuid;
    v_account_id uuid;
    v_line record;
    v_line_total numeric(18,2);
    v_line_no integer := 0;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 OR p_purpose IS NULL OR p_purpose = '' THEN
        PERFORM app.fail('INVALID_CASH_RECEIPT', 'Receipt amount and purpose are required');
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        PERFORM app.fail('INVALID_CASH_RECEIPT_LINES', 'At least one receipt line is required');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.payment_mode
                    WHERE mode_code = p_payment_mode AND is_enabled) THEN
        PERFORM app.fail('PAYMENT_MODE_DISABLED', 'The payment mode is not enabled');
    END IF;

    SELECT * INTO v_member FROM mbr.member
     WHERE tenant_id = v_tenant AND id = p_member_id AND is_deleted = false;
    IF NOT FOUND THEN
        PERFORM app.fail('MEMBER_NOT_FOUND', 'The receipt member was not found');
    END IF;
    SELECT * INTO v_cash FROM acct.cash_account
     WHERE tenant_id = v_tenant AND status = 'ACTIVE'
     ORDER BY is_default DESC LIMIT 1;
    IF NOT FOUND THEN
        PERFORM app.fail('CASH_ACCOUNT_NOT_CONFIGURED', 'No active cash account is configured');
    END IF;

    SELECT coalesce(sum((x->>'amount')::numeric), 0)::numeric(18,2)
      INTO v_line_total FROM jsonb_array_elements(p_lines) x;
    IF v_line_total <> p_amount THEN
        PERFORM app.fail('CASH_RECEIPT_TOTAL_MISMATCH', 'Receipt lines must equal the receipt amount');
    END IF;

    INSERT INTO acct.cash_receipt (
        receipt_no,cash_account_id,payer_type,member_id,payer_name,payer_mobile,
        amount,payment_mode,payment_reference,purpose,source_module,
        source_entity_type,source_entity_id,idempotency_key
    ) VALUES (
        acct.next_number('RECEIPT',app.working_date(),v_tenant),v_cash.id,'MEMBER',
        v_member.id,v_member.full_name,v_member.mobile,p_amount,p_payment_mode,
        p_payment_reference,p_purpose,'LOAN',p_source_entity_type,p_source_entity_id,
        core.current_idempotency_key()   -- the API request that posted it (double-save guard)
    ) RETURNING id INTO v_receipt_id;

    INSERT INTO acct.journal (
        voucher_type,value_date,status,narration,total_amount,source_module,
        source_entity_type,source_entity_id,source_ref,idempotency_key
    ) VALUES (
        'JOURNAL',app.working_date(),'POSTED',initcap(replace(p_purpose,'_',' ')),
        p_amount,'LOAN','acct.cash_receipt',v_receipt_id,v_receipt_id::text,
        core.current_idempotency_key()
    ) RETURNING id INTO v_journal_id;

    INSERT INTO acct.journal_line (
        journal_id,line_no,account_id,debit,credit,narration,member_id,
        sub_entity_type,sub_entity_id
    ) VALUES (
        v_journal_id,1,v_cash.account_id,p_amount,0,
        initcap(replace(p_purpose,'_',' ')),v_member.id,'loan.loan',p_source_entity_id
    );

    FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
        IF coalesce(v_line.value->>'component','') = ''
           OR coalesce(v_line.value->>'mapping_key','') = ''
           OR coalesce((v_line.value->>'amount')::numeric,0) <= 0 THEN
            PERFORM app.fail('INVALID_CASH_RECEIPT_LINE', 'Receipt line component, mapping, and positive amount are required');
        END IF;
        SELECT am.account_id INTO v_account_id
          FROM acct.account_mapping am
         WHERE am.tenant_id = v_tenant
           AND am.mapping_key = v_line.value->>'mapping_key'
           AND am.scope_type = coalesce(nullif(v_line.value->>'scope_type',''),'NONE')
           AND am.scope_id IS NOT DISTINCT FROM nullif(v_line.value->>'scope_id','')::uuid
           AND am.effective_from <= app.working_date()
         ORDER BY am.effective_from DESC LIMIT 1;
        IF v_account_id IS NULL AND coalesce(nullif(v_line.value->>'scope_type',''),'NONE') <> 'NONE' THEN
            SELECT am.account_id INTO v_account_id
              FROM acct.account_mapping am
             WHERE am.tenant_id = v_tenant AND am.mapping_key = v_line.value->>'mapping_key'
               AND am.scope_type = 'NONE' AND am.scope_id IS NULL
               AND am.effective_from <= app.working_date()
             ORDER BY am.effective_from DESC LIMIT 1;
        END IF;
        IF v_account_id IS NULL THEN
            PERFORM app.fail('ACCOUNT_MAPPING_MISSING', format('No account mapping for %s', v_line.value->>'mapping_key'));
        END IF;

        v_line_no := v_line_no + 1;
        INSERT INTO acct.cash_receipt_line (cash_receipt_id,line_no,component,amount,account_id)
        VALUES (v_receipt_id,v_line_no,v_line.value->>'component',
                (v_line.value->>'amount')::numeric,v_account_id);
        INSERT INTO acct.journal_line (
            journal_id,line_no,account_id,debit,credit,narration,member_id,
            sub_entity_type,sub_entity_id
        ) VALUES (
            v_journal_id,v_line_no+1,v_account_id,0,(v_line.value->>'amount')::numeric,
            initcap(replace(p_purpose,'_',' ')),v_member.id,'loan.loan',p_source_entity_id
        );
    END LOOP;

    UPDATE acct.cash_receipt SET journal_id = v_journal_id WHERE tenant_id = v_tenant AND id = v_receipt_id;
    RETURN QUERY SELECT v_receipt_id,v_journal_id;
END
$$;

CREATE OR REPLACE FUNCTION loan.collect_application_fee(
    p_loan_id uuid, p_payment_mode text, p_payment_reference text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record;
    v_fee record;
    v_receipt uuid;
    v_journal uuid;
BEGIN
    SELECT l.id,l.member_id,l.status,f.id fee_id,f.fee_amount,f.status fee_status,
           f.collect_timing
      INTO v_loan
      FROM loan.loan l
      JOIN loan.loan_application_fee f ON f.tenant_id=l.tenant_id AND f.loan_id=l.id
     WHERE l.tenant_id=app.tenant_id() AND l.id=p_loan_id
     FOR UPDATE OF l,f;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_FEE_NOT_FOUND','Loan application fee was not found'); END IF;
    IF v_loan.status NOT IN ('DRAFT','RETURNED') THEN
        PERFORM app.fail('LOAN_FEE_STATE','Fees can only be collected for draft or returned applications');
    END IF;
    IF v_loan.fee_status <> 'PENDING' OR v_loan.fee_amount <= 0 THEN
        PERFORM app.fail('LOAN_FEE_STATE','Fee is not pending collection');
    END IF;
    SELECT r.cash_receipt_id,r.journal_id INTO v_receipt,v_journal
      FROM acct.post_cash_receipt(
        v_loan.member_id,v_loan.fee_amount,p_payment_mode,p_payment_reference,
        'APPLICATION_FEE','loan.loan',p_loan_id,
        jsonb_build_array(jsonb_build_object('component','FEE','mapping_key','APPLICATION_FEE',
            'scope_type','NONE','scope_id',NULL,'amount',v_loan.fee_amount))
      ) r;
    UPDATE loan.loan_application_fee
       SET status='PAID',cash_receipt_id=v_receipt,updated_at=now(),
           updated_by=app.user_id(),row_version=row_version+1
     WHERE tenant_id=app.tenant_id() AND id=v_loan.fee_id;
    RETURN jsonb_build_object('loan_id',p_loan_id,'fee_amount',v_loan.fee_amount,
        'status','PAID','cash_receipt_id',v_receipt,'journal_id',v_journal);
END
$$;

-- loan.record_approval_decision moved to 36_functions_loan_lifecycle.sql (online and
-- offline decisions share loan.apply_approval_decision).

-- loan.prepare_disbursement and loan.release_disbursement moved to
-- 38_functions_loan_restructure.sql (tranches and the cash disbursement limit).

-- Possible duplicate of a member (scope 5.5): same mobile number (last ten
-- digits) or same name with the same date of birth. Exited and deceased
-- members are not counted, so a family member or a rejoining member can reuse
-- the details.
CREATE OR REPLACE FUNCTION mbr.find_duplicate_member(
    p_exclude_id uuid, p_mobile text, p_full_name text, p_date_of_birth date)
RETURNS TABLE (member_id uuid, member_no text, matched_on text)
LANGUAGE sql STABLE AS
$$
    SELECT m.id, m.member_no,
           CASE WHEN nullif(right(regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'), 10), '') IS NOT NULL
                     AND right(regexp_replace(coalesce(m.mobile, ''), '\D', '', 'g'), 10)
                       = right(regexp_replace(p_mobile, '\D', '', 'g'), 10)
                THEN 'mobile number' ELSE 'name and date of birth' END
      FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND NOT m.is_deleted AND m.status NOT IN ('EXITED','DECEASED')
       AND m.id IS DISTINCT FROM p_exclude_id
       AND ((nullif(right(regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'), 10), '') IS NOT NULL
             AND right(regexp_replace(coalesce(m.mobile, ''), '\D', '', 'g'), 10)
               = right(regexp_replace(p_mobile, '\D', '', 'g'), 10))
         OR (p_date_of_birth IS NOT NULL AND m.date_of_birth = p_date_of_birth
             AND lower(btrim(m.full_name)) = lower(btrim(p_full_name))))
     ORDER BY m.member_no
     LIMIT 1
$$;

-- Fails with DUPLICATE_MEMBER unless the employee confirmed the duplicate with
-- a reason. Member registrations and key-detail changes of one organisation
-- are serialised by an advisory lock, so two clerks (or a double-click)
-- cannot both register the same person at the same moment.
CREATE OR REPLACE FUNCTION mbr.assert_no_duplicate_member(
    p_exclude_id uuid, p_mobile text, p_full_name text, p_date_of_birth date, p_override_reason text)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE v_dup record;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('mbr.member.identity:' || app.tenant_id()::text, 0));
    SELECT * INTO v_dup FROM mbr.find_duplicate_member(p_exclude_id, p_mobile, p_full_name, p_date_of_birth);
    IF FOUND AND coalesce(btrim(p_override_reason), '') = '' THEN
        PERFORM app.fail('DUPLICATE_MEMBER',
            format('Member %s already has the same %s. Open that member, or confirm with a reason that this is a different person.',
                   v_dup.member_no, v_dup.matched_on));
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION mbr.create_member(p_values jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_member mbr.member%ROWTYPE;
    v_override text := nullif(btrim(p_values->>'duplicate_override_reason'), '');
BEGIN
    PERFORM mbr.assert_no_duplicate_member(NULL, p_values->>'mobile', p_values->>'full_name',
                                           (p_values->>'date_of_birth')::date, v_override);
    IF v_override IS NOT NULL THEN
        PERFORM app.set_audit_reason('Possible duplicate confirmed: ' || v_override, 'MEMBER', NULL);
    END IF;
    INSERT INTO mbr.member (member_no,full_name,date_of_birth,gender,mobile,alt_mobile,email,
        address_line1,address_line2,city,district,state,pincode,preferred_language,preferred_channel,notes)
    VALUES (acct.next_number('MEMBER',NULL,app.tenant_id()),p_values->>'full_name',
        (p_values->>'date_of_birth')::date,p_values->>'gender',p_values->>'mobile',p_values->>'alt_mobile',
        p_values->>'email',p_values->>'address_line1',p_values->>'address_line2',p_values->>'city',
        p_values->>'district',p_values->>'state',p_values->>'pincode',
        coalesce(p_values->>'preferred_language',(SELECT language_code FROM platform.language WHERE is_default),'en'),coalesce(p_values->>'preferred_channel','SMS'),p_values->>'notes')
    RETURNING * INTO v_member;
    RETURN to_jsonb(v_member);
END
$$;

CREATE OR REPLACE FUNCTION mbr.update_member(p_member_id uuid,p_values jsonb,p_expected_version integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_member mbr.member%ROWTYPE;
    v_current mbr.member%ROWTYPE;
BEGIN
    IF p_values ?| ARRAY['mobile','full_name','date_of_birth'] THEN
        SELECT * INTO v_current FROM mbr.member
         WHERE tenant_id=app.tenant_id() AND id=p_member_id AND is_deleted=false;
        IF FOUND THEN
            PERFORM mbr.assert_no_duplicate_member(p_member_id,
                CASE WHEN p_values?'mobile' THEN p_values->>'mobile' ELSE v_current.mobile END,
                CASE WHEN p_values?'full_name' THEN p_values->>'full_name' ELSE v_current.full_name END,
                CASE WHEN p_values?'date_of_birth' THEN (p_values->>'date_of_birth')::date ELSE v_current.date_of_birth END,
                p_values->>'duplicate_override_reason');
        END IF;
    END IF;
    UPDATE mbr.member SET
        full_name=CASE WHEN p_values?'full_name' THEN p_values->>'full_name' ELSE full_name END,
        date_of_birth=CASE WHEN p_values?'date_of_birth' THEN (p_values->>'date_of_birth')::date ELSE date_of_birth END,
        gender=CASE WHEN p_values?'gender' THEN p_values->>'gender' ELSE gender END,
        mobile=CASE WHEN p_values?'mobile' THEN p_values->>'mobile' ELSE mobile END,
        alt_mobile=CASE WHEN p_values?'alt_mobile' THEN p_values->>'alt_mobile' ELSE alt_mobile END,
        email=CASE WHEN p_values?'email' THEN p_values->>'email' ELSE email END,
        address_line1=CASE WHEN p_values?'address_line1' THEN p_values->>'address_line1' ELSE address_line1 END,
        address_line2=CASE WHEN p_values?'address_line2' THEN p_values->>'address_line2' ELSE address_line2 END,
        city=CASE WHEN p_values?'city' THEN p_values->>'city' ELSE city END,
        district=CASE WHEN p_values?'district' THEN p_values->>'district' ELSE district END,
        state=CASE WHEN p_values?'state' THEN p_values->>'state' ELSE state END,
        pincode=CASE WHEN p_values?'pincode' THEN p_values->>'pincode' ELSE pincode END,
        preferred_language=CASE WHEN p_values?'preferred_language' THEN p_values->>'preferred_language' ELSE preferred_language END,
        preferred_channel=CASE WHEN p_values?'preferred_channel' THEN p_values->>'preferred_channel' ELSE preferred_channel END,
        notes=CASE WHEN p_values?'notes' THEN p_values->>'notes' ELSE notes END
    WHERE tenant_id=app.tenant_id() AND id=p_member_id AND is_deleted=false
      AND (p_expected_version IS NULL OR row_version=p_expected_version)
    RETURNING * INTO v_member;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN to_jsonb(v_member);
END
$$;

-- Paginated member search used by the tenant API. Keeping the tenant scope and
-- filters here makes the repository a thin caller and prevents unscoped reads.
CREATE OR REPLACE FUNCTION mbr.search_members(
    p_query text DEFAULT NULL, p_status text DEFAULT NULL,
    p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS TABLE (
    id uuid, member_no text, full_name text, date_of_birth date, gender text,
    mobile text, alt_mobile text, email text, address_line1 text, address_line2 text,
    city text, district text, state text, pincode text, membership_date date,
    status text, loan_eligibility text, preferred_language text,
    preferred_channel text, previous_member_id uuid, created_at timestamptz,
    updated_at timestamptz, row_version integer)
LANGUAGE sql STABLE AS
$$
    SELECT m.id, m.member_no, m.full_name, m.date_of_birth, m.gender,
           m.mobile, m.alt_mobile, m.email, m.address_line1, m.address_line2,
           m.city, m.district, m.state, m.pincode, m.membership_date,
           m.status, m.loan_eligibility, m.preferred_language,
           m.preferred_channel, m.previous_member_id, m.created_at,
           m.updated_at, m.row_version
      FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.is_deleted = false
       AND (p_query IS NULL OR m.member_no ILIKE '%' || p_query || '%'
            OR m.full_name ILIKE '%' || p_query || '%'
            OR m.mobile ILIKE '%' || p_query || '%')
       AND (p_status IS NULL OR m.status = p_status)
     ORDER BY m.created_at DESC, m.member_no
     LIMIT greatest(1, least(p_limit, 500)) OFFSET greatest(p_offset, 0)
$$;

CREATE OR REPLACE FUNCTION loan.create_application(
    p_member_id uuid,p_loan_type_id uuid,p_purpose text,p_requested_amount numeric(18,2),
    p_tenure_months integer,p_is_first_loan boolean,p_rule_set_version_id uuid,
    p_rule_snapshot jsonb,p_workflow_version_id uuid,p_fee jsonb,p_nominee_ids uuid[]
)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE v_loan_id uuid; v_nominee_id uuid; v_open text;
BEGIN
    -- One open application per member and loan type. The member row lock
    -- serialises concurrent creates (a double-click) for the same member.
    PERFORM 1 FROM mbr.member WHERE tenant_id=app.tenant_id() AND id=p_member_id AND is_deleted=false FOR NO KEY UPDATE;
    SELECT loan_no INTO v_open FROM loan.loan
     WHERE tenant_id=app.tenant_id() AND member_id=p_member_id AND loan_type_id=p_loan_type_id
       AND NOT is_deleted AND status IN ('DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED')
     ORDER BY created_at LIMIT 1;
    IF v_open IS NOT NULL THEN
        PERFORM app.fail('LOAN_APPLICATION_ALREADY_OPEN',
            format('Application %s of this member for the same loan type is still open. Continue that application, or withdraw it first.', v_open));
    END IF;
    INSERT INTO loan.loan (loan_no,member_id,loan_type_id,purpose,requested_amount,
        requested_tenure_months,application_date,status,status_date,is_first_loan,
        rule_set_version_id,rule_snapshot,workflow_version_id,created_by_employee)
    VALUES (acct.next_number('LOAN',app.working_date(),app.tenant_id()),p_member_id,p_loan_type_id,
        p_purpose,p_requested_amount,p_tenure_months,app.working_date(),'DRAFT',app.working_date(),
        p_is_first_loan,p_rule_set_version_id,p_rule_snapshot,p_workflow_version_id,app.user_id())
    RETURNING id INTO v_loan_id;
    IF p_fee IS NOT NULL THEN
        INSERT INTO loan.loan_application_fee (loan_id,fee_basis,fee_rate,fee_amount,collect_timing,status,rule_set_version_id)
        VALUES (v_loan_id,p_fee->>'fee_basis',(p_fee->>'fee_rate')::numeric,
            (p_fee->>'fee_amount')::numeric,p_fee->>'collect_timing','PENDING',p_rule_set_version_id);
    END IF;
    FOREACH v_nominee_id IN ARRAY coalesce(p_nominee_ids,'{}'::uuid[]) LOOP
        INSERT INTO loan.loan_nominee (loan_id,nominee_id) VALUES (v_loan_id,v_nominee_id);
    END LOOP;
    RETURN v_loan_id;
END
$$;

CREATE OR REPLACE FUNCTION loan.submit_application(p_loan_id uuid)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_loan record; v_workflow record; v_role_id uuid; v_policy_id uuid;
    v_request_no text; v_instance_id uuid; v_approval_id uuid; v_config jsonb;
BEGIN
    SELECT l.id,l.loan_no,l.member_id,l.loan_type_id,l.requested_amount,l.rule_set_version_id,
           l.workflow_version_id,l.status,m.full_name,rs.code rule_code
      INTO v_loan FROM loan.loan l
      JOIN mbr.member m ON m.tenant_id=l.tenant_id AND m.id=l.member_id
      JOIN loan.loan_type lt ON lt.tenant_id=l.tenant_id AND lt.id=l.loan_type_id
      JOIN cfg.rule_set rs ON rs.tenant_id=lt.tenant_id AND rs.id=lt.rule_set_id
     WHERE l.tenant_id=app.tenant_id() AND l.id=p_loan_id AND l.is_deleted=false FOR UPDATE OF l;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF v_loan.status NOT IN ('DRAFT','RETURNED') THEN PERFORM app.fail('CHECK_FAILED','Only draft or returned loans can be submitted'); END IF;
    SELECT d.id workflow_definition_id,v.id workflow_version_id INTO v_workflow
      FROM cfg.workflow_version v JOIN cfg.workflow_definition d
        ON d.tenant_id=v.tenant_id AND d.id=v.workflow_definition_id
     WHERE v.tenant_id=app.tenant_id() AND v.id=v_loan.workflow_version_id
       AND v.status IN ('PUBLISHED','RETIRED') AND d.code='LOAN_APPLICATION';
    IF NOT FOUND THEN RETURN NULL; END IF;
    -- Approver roles come from the workflow's approval stage (no role in code).
    v_config := wf.stage_approval_config(v_loan.workflow_version_id, 'MANAGER_APPROVAL', v_loan.requested_amount);
    SELECT id INTO v_role_id FROM iam.role WHERE tenant_id=app.tenant_id()
       AND role_code=v_config->'roles'->>0 AND status='ACTIVE' LIMIT 1;
    IF v_role_id IS NULL THEN RETURN NULL; END IF;
    SELECT id INTO v_policy_id FROM wf.approval_policy
     WHERE tenant_id=app.tenant_id() AND workflow_code='LOAN_APPLICATION'
       AND stage_code='MANAGER_APPROVAL' AND status='ACTIVE' AND effective_from<=app.working_date()
     ORDER BY effective_from DESC LIMIT 1;
    v_request_no := acct.next_number('APPROVAL',app.working_date(),app.tenant_id());
    INSERT INTO wf.workflow_instance (workflow_definition_id,workflow_version_id,entity_type,entity_id,
        business_ref,current_stage_code,status,rule_set_versions,working_date,started_by)
    VALUES (v_workflow.workflow_definition_id,v_workflow.workflow_version_id,'loan.loan',v_loan.id,
        v_loan.loan_no,'MANAGER_APPROVAL','RUNNING',jsonb_build_object(v_loan.rule_code,v_loan.rule_set_version_id::text),
        app.working_date(),app.user_id()) RETURNING id INTO v_instance_id;
    INSERT INTO wf.approval_request (request_no,approval_policy_id,workflow_instance_id,stage_code,
        entity_type,entity_id,business_ref,summary,amount,requested_by,required_role_id)
    VALUES (v_request_no,v_policy_id,v_instance_id,'MANAGER_APPROVAL','loan.loan',v_loan.id,
        v_loan.loan_no,'Loan application '||v_loan.loan_no||' for '||v_loan.full_name,
        v_loan.requested_amount,app.user_id(),v_role_id) RETURNING id INTO v_approval_id;
    PERFORM wf.configure_approval_request(v_approval_id,
        ARRAY(SELECT jsonb_array_elements_text(v_config->'roles')), (v_config->>'minApprovals')::integer,
        (v_config->>'allowOffline')::boolean,
        ARRAY(SELECT jsonb_array_elements_text(coalesce(v_config->'offlineRecorderRoles', '[]'::jsonb))));
    INSERT INTO wf.task (task_type,title,entity_type,entity_id,business_ref,workflow_instance_id,
        approval_request_id,assigned_role_id,priority)
    VALUES ('APPROVAL','Review loan application '||v_loan.loan_no,'loan.loan',v_loan.id,
        v_loan.loan_no,v_instance_id,v_approval_id,v_role_id,'NORMAL');
    INSERT INTO wf.workflow_history (workflow_instance_id,from_stage_code,to_stage_code,trigger_event,
        acted_by,acted_role_code,working_date,remarks)
    VALUES (v_instance_id,'DRAFT','MANAGER_APPROVAL','SUBMIT',app.user_id(),app.role_code(),
        app.working_date(),'Submitted for Manager approval');
    UPDATE loan.loan SET status='UNDER_APPROVAL',status_date=app.working_date(),
        workflow_instance_id=v_instance_id,approval_request_id=v_approval_id,
        updated_at=now(),updated_by=app.user_id(),row_version=row_version+1
     WHERE tenant_id=app.tenant_id() AND id=v_loan.id;
    RETURN v_approval_id;
END
$$;

-- A rule of an organisation-level (GENERAL) rule set, from its version in
-- force; NULL when the set or the rule is absent.
CREATE OR REPLACE FUNCTION cfg.general_rule(p_rule_set_code text, p_rule_code text, p_on date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE v_rule jsonb;
BEGIN
    SELECT r INTO v_rule
      FROM cfg.rule_set s
      JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(s.id, coalesce(p_on, app.working_date()))
      CROSS JOIN LATERAL jsonb_array_elements(v.definition -> 'rules') r
     WHERE s.tenant_id = app.tenant_id() AND s.code = p_rule_set_code AND s.status = 'ACTIVE'
       AND r ->> 'code' = p_rule_code
     LIMIT 1;
    RETURN v_rule;
END
$$;

-- The rules a loan type works with: its own rule set, with the NOMINEE rule
-- taken from the organisation's MEMBER_RULES set (nominees depend on the
-- organisation's rule, not on the loan type). New loans snapshot this.
CREATE OR REPLACE FUNCTION loan.effective_type_rules(p_definition jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE v_nominee jsonb := cfg.general_rule('MEMBER_RULES', 'NOMINEE');
BEGIN
    RETURN jsonb_set(p_definition, '{rules}',
        coalesce((SELECT jsonb_agg(r) FROM jsonb_array_elements(p_definition -> 'rules') r
                   WHERE r ->> 'code' <> 'NOMINEE'), '[]'::jsonb)
        || CASE WHEN v_nominee IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_nominee) END);
END
$$;

CREATE OR REPLACE FUNCTION loan.get_active_loan_types(p_loan_type_id uuid DEFAULT NULL)
RETURNS TABLE (
    id uuid,code text,name text,description text,interest_method text,
    is_interest_free boolean,allows_tranches boolean,rule_set_code text,
    rule_set_version_id uuid,rule_set_version_no integer,effective_from date,definition jsonb
)
LANGUAGE sql STABLE AS
$$
    SELECT lt.id,lt.code,lt.name,lt.description,lt.interest_method,
           lt.is_interest_free,lt.allows_tranches,rs.code,
           rv.id,rv.version_no,rv.effective_from,loan.effective_type_rules(rv.definition)
      FROM loan.loan_type lt
      JOIN cfg.rule_set rs ON rs.tenant_id=lt.tenant_id AND rs.id=lt.rule_set_id
      JOIN LATERAL (
          SELECT v.id,v.version_no,v.effective_from,v.definition
            FROM cfg.rule_set_version v
           WHERE v.tenant_id=rs.tenant_id AND v.rule_set_id=rs.id
             AND v.status='PUBLISHED'
             AND v.effective_from<=app.working_date()
             AND (v.effective_to IS NULL OR v.effective_to>=app.working_date())
           ORDER BY v.effective_from DESC,v.version_no DESC
           LIMIT 1
      ) rv ON true
     WHERE lt.tenant_id=app.tenant_id() AND lt.status='ACTIVE' AND rs.status='ACTIVE'
       AND (p_loan_type_id IS NULL OR lt.id=p_loan_type_id)
     ORDER BY lt.sort_order,lt.name
$$;

-- Filtered, paginated loan application list for the tenant API.
CREATE OR REPLACE FUNCTION loan.search_applications(
    p_query text DEFAULT NULL, p_status text DEFAULT NULL,
    p_member_id uuid DEFAULT NULL, p_limit integer DEFAULT 50,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id uuid, loan_no text, member_id uuid, member_no text, member_name text,
    loan_type_id uuid, loan_type_code text, loan_type_name text, purpose text,
    requested_amount numeric, requested_tenure_months integer, application_date date,
    status text, status_date date, is_first_loan boolean, approved_amount numeric,
    tenure_months integer, interest_rate_annual numeric, interest_method text,
    total_interest numeric, instalment_amount numeric, rule_set_version_id uuid,
    workflow_version_id uuid, created_at timestamptz, updated_at timestamptz,
    row_version integer)
LANGUAGE sql STABLE AS
$$
    SELECT l.id, l.loan_no, l.member_id, m.member_no, m.full_name,
           l.loan_type_id, lt.code, lt.name, l.purpose, l.requested_amount,
           l.requested_tenure_months, l.application_date, l.status, l.status_date,
           l.is_first_loan, l.approved_amount, l.tenure_months,
           l.interest_rate_annual, l.interest_method, l.total_interest,
           l.instalment_amount, l.rule_set_version_id, l.workflow_version_id,
           l.created_at, l.updated_at, l.row_version
      FROM loan.loan l
      JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
      JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
     WHERE l.tenant_id = app.tenant_id() AND l.is_deleted = false
       AND (p_query IS NULL OR l.loan_no ILIKE '%' || p_query || '%'
            OR m.member_no ILIKE '%' || p_query || '%'
            OR m.full_name ILIKE '%' || p_query || '%')
       AND (p_status IS NULL OR l.status = p_status)
       AND (p_member_id IS NULL OR l.member_id = p_member_id)
     ORDER BY l.created_at DESC, l.loan_no
     LIMIT greatest(1, least(p_limit, 500)) OFFSET greatest(p_offset, 0)
$$;

-- Tenant detail lookup for platform administration.
CREATE OR REPLACE FUNCTION platform.get_tenant(p_tenant_id uuid)
RETURNS TABLE (
    id uuid, code text, name text, legal_name text, registration_no text,
    status text, is_sandbox boolean, time_zone text, currency_code character(3),
    address jsonb, contact_email text, contact_mobile text, logo_url text,
    data_region text, settings_template_version integer, created_at timestamptz,
    activated_at timestamptz, suspended_at timestamptz, closed_at timestamptz,
    status_reason text)
LANGUAGE sql STABLE AS
$$
    SELECT t.id, t.code, t.name, t.legal_name, t.registration_no, t.status,
           t.is_sandbox, t.time_zone, t.currency_code, t.address,
           t.contact_email, t.contact_mobile, t.logo_url, t.data_region,
           t.settings_template_version, t.created_at, t.activated_at,
           t.suspended_at, t.closed_at, t.status_reason
      FROM platform.tenant t
     WHERE t.id = p_tenant_id
$$;

CREATE OR REPLACE FUNCTION platform.create_translation_draft(p_language_code text,p_user_id uuid)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE v_version integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('translation:'||p_language_code,0));
    SELECT coalesce(max(version_no),0)+1 INTO v_version FROM platform.language_pack WHERE language_code=p_language_code;
    INSERT INTO platform.language_pack(language_code,version_no,status,created_by)
    VALUES (p_language_code,v_version,'DRAFT',p_user_id);
    INSERT INTO platform.translation_entry(language_code,version_no,text_id,translated_text,status,updated_by)
    SELECT e.language_code,v_version,e.text_id,e.translated_text,e.status,p_user_id
      FROM platform.translation_entry e
      JOIN platform.language_pack p ON p.language_code=e.language_code AND p.version_no=e.version_no
     WHERE e.language_code=p_language_code AND p.status='PUBLISHED'
       AND p.version_no=(SELECT max(version_no) FROM platform.language_pack
                          WHERE language_code=p_language_code AND status='PUBLISHED');
    RETURN v_version;
END
$$;

CREATE OR REPLACE FUNCTION platform.save_translation_entry(
    p_language_code text,p_version_no integer,p_text_id text,p_translated_text text,
    p_status text,p_user_id uuid
)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_entry platform.translation_entry%ROWTYPE;
BEGIN
    INSERT INTO platform.translation_entry(language_code,version_no,text_id,translated_text,status,updated_by)
    SELECT p_language_code,p_version_no,t.text_id,p_translated_text,p_status,p_user_id
      FROM platform.translation_text t
      JOIN platform.language_pack p ON p.language_code=p_language_code AND p.version_no=p_version_no AND p.status='DRAFT'
     WHERE t.text_id=p_text_id AND t.status='ACTIVE'
    ON CONFLICT(language_code,version_no,text_id) DO UPDATE
       SET translated_text=EXCLUDED.translated_text,status=EXCLUDED.status,
           updated_at=now(),updated_by=EXCLUDED.updated_by
    RETURNING * INTO v_entry;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('language_code',v_entry.language_code,'version_no',v_entry.version_no,
        'text_id',v_entry.text_id,'translated_text',v_entry.translated_text,'status',v_entry.status,
        'updated_at',v_entry.updated_at,'updated_by',v_entry.updated_by);
END
$$;

CREATE OR REPLACE FUNCTION platform.publish_translation_pack(p_language_code text,p_version_no integer,p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_pack platform.language_pack%ROWTYPE; v_missing bigint;
BEGIN
    SELECT * INTO v_pack FROM platform.language_pack
     WHERE language_code=p_language_code AND version_no=p_version_no AND status='DRAFT' FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT count(*) INTO v_missing FROM platform.translation_text t
      LEFT JOIN platform.translation_entry e ON e.text_id=t.text_id
          AND e.language_code=p_language_code AND e.version_no=p_version_no
     WHERE t.status='ACTIVE' AND coalesce(e.status,'MISSING')<>'APPROVED';
    UPDATE platform.language_pack SET status='PUBLISHED',published_at=now(),published_by=p_user_id
     WHERE language_code=p_language_code AND version_no=p_version_no RETURNING * INTO v_pack;
    RETURN jsonb_build_object('language_code',v_pack.language_code,'version_no',v_pack.version_no,
        'status',v_pack.status,'published_at',v_pack.published_at,'published_by',v_pack.published_by,
        'missing_count',v_missing);
END
$$;

CREATE OR REPLACE FUNCTION acct.create_financial_year(p_tenant_id uuid, p_start date)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_fy_id uuid;
    v_end   date := (p_start + interval '1 year' - interval '1 day')::date;
    v_code  text := to_char(p_start, 'YYYY') || '-' || to_char(v_end, 'YY');
    i       integer;
    v_from  date;
BEGIN
    SELECT id INTO v_fy_id FROM acct.financial_year WHERE tenant_id = p_tenant_id AND start_date = p_start;
    IF v_fy_id IS NOT NULL THEN
        RETURN v_fy_id;
    END IF;
    INSERT INTO acct.financial_year (tenant_id, code, start_date, end_date)
    VALUES (p_tenant_id, v_code, p_start, v_end)
    RETURNING id INTO v_fy_id;

    FOR i IN 1..12 LOOP
        v_from := (p_start + make_interval(months => i - 1))::date;
        INSERT INTO acct.financial_period (tenant_id, financial_year_id, period_no, name, start_date, end_date)
        VALUES (p_tenant_id, v_fy_id, i, to_char(v_from, 'Mon-YYYY'), v_from,
                (v_from + interval '1 month' - interval '1 day')::date);
    END LOOP;
    RETURN v_fy_id;
END
$$;

CREATE OR REPLACE FUNCTION platform.provision_tenant(
    p_code              text,
    p_name              text,
    p_admin_name        text,
    p_admin_mobile      text,
    p_admin_email       text,
    p_optional_modules  text[]  DEFAULT '{}',      -- e.g. {LOAN,LOAN_FEE,HALL,PAYROLL}
    p_features          text[]  DEFAULT '{}',      -- e.g. {GST}
    p_platform_user_id  uuid    DEFAULT NULL,
    p_is_sandbox        boolean DEFAULT false,
    p_time_zone         text    DEFAULT 'Asia/Kolkata')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app, platform, core, iam, cfg, wf, audit, mbr,
                  acct, loan, ops, dep, chit, notif AS
$$
DECLARE
    v_tenant    uuid;
    v_tpl_ver   integer;
    v_today     date;
    v_fy_month  integer;
    v_fy_start  date;
    v_admin_id  uuid;
    v_adm_role  uuid;
    v_mgr_role  uuid;
    v_rs_id     uuid;
    v_wf_id     uuid;
    v_acct_id   uuid;
    v_seq       integer;
    r           record;
    -- caller context, restored at the end
    c_tenant text := current_setting('app.tenant_id', true);
    c_scope  text := current_setting('app.scope', true);
    c_chan   text := current_setting('app.channel', true);
    c_puser  text := current_setting('app.platform_user_id', true);
    c_reason text := current_setting('app.reason', true);
    c_signature text := current_setting('app.context_signature', true);
BEGIN
    IF session_user <> 'nvs' AND
       (app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE OR
        app.platform_user_id() IS DISTINCT FROM p_platform_user_id OR
        app.role_code() <> 'SUPER_ADMIN') THEN
        PERFORM app.fail('PLATFORM_CONTEXT_REQUIRED', 'Tenant provisioning requires an authenticated Super Administrator context');
    END IF;
    SELECT version_no INTO v_tpl_ver FROM platform.settings_template WHERE status = 'PUBLISHED';
    IF v_tpl_ver IS NULL THEN
        PERFORM app.fail('NO_SETTINGS_TEMPLATE', 'No published default settings template (run 40_seed_platform.sql)');
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_optional_modules) m
                WHERE NOT EXISTS (SELECT 1 FROM platform.module pm
                                   WHERE pm.module_code = m AND pm.module_type <> 'PLATFORM' AND pm.is_active)) THEN
        PERFORM app.fail('UNKNOWN_MODULE', 'One or more module codes are unknown');
    END IF;

    -- 1. tenant
    INSERT INTO platform.tenant (code, name, status, is_sandbox, time_zone, contact_email, contact_mobile,
                                 settings_template_version, created_by)
    VALUES (lower(p_code), p_name, 'PROVISIONING', p_is_sandbox, p_time_zone, p_admin_email, p_admin_mobile,
            v_tpl_ver, p_platform_user_id)
    RETURNING id INTO v_tenant;

    PERFORM set_config('app.tenant_id', v_tenant::text, true);
    PERFORM set_config('app.scope', 'platform', true);
    PERFORM set_config('app.channel', 'SUPER_ADMIN', true);
    PERFORM set_config('app.platform_user_id', coalesce(p_platform_user_id::text, ''), true);
    PERFORM set_config('app.reason', 'Organisation provisioning', true);
    -- This function is SECURITY DEFINER: sign the internal tenant context so
    -- FORCE RLS remains active while provisioning rows across tenant schemas.
    PERFORM set_config('app.context_signature', encode(app.hmac(
        convert_to(app.context_payload(), 'UTF8'),
        (SELECT secret FROM app.context_signing_key WHERE key_id = 1), 'sha256'), 'hex'), true);
    v_today := app.tenant_today(v_tenant);

    -- 2. default branch
    INSERT INTO core.branch (tenant_id, code, name, is_default) VALUES (v_tenant, 'MAIN', 'Main Office', true);

    -- 3. modules: core always, plus the optional modules chosen by the Super Admin
    INSERT INTO platform.tenant_module (tenant_id, module_code, is_enabled, enabled_at, enabled_by, reason,
                                        legal_warning_ack_at, legal_warning_ack_by)
    SELECT v_tenant, m.module_code, true, now(), p_platform_user_id,
           CASE WHEN m.is_core THEN 'Core module' ELSE 'Enabled at onboarding' END,
           CASE WHEN m.is_optional_legal THEN now() END,
           CASE WHEN m.is_optional_legal THEN p_platform_user_id END
      FROM platform.module m
     WHERE m.module_type <> 'PLATFORM' AND m.is_active
       AND (m.is_core
            OR m.module_code = ANY (p_optional_modules)
            OR (NOT m.is_menu AND (m.parent_module_code = ANY (p_optional_modules)
                                   OR EXISTS (SELECT 1 FROM platform.module pm
                                               WHERE pm.module_code = m.parent_module_code AND pm.is_core))));

    -- 4. privilege ceiling = all privileges provided through the standard role templates
    INSERT INTO platform.tenant_privilege_ceiling (tenant_id, privilege_code, granted_by, reason)
    SELECT DISTINCT v_tenant, rtp.privilege_code, p_platform_user_id, 'Default set at onboarding'
      FROM platform.role_template_privilege rtp;

    -- 5. standard roles and their privileges (enabled modules only)
    INSERT INTO iam.role (tenant_id, role_code, role_name, description, role_type, default_home_module,
                          requires_mfa, is_read_only, sort_order)
    SELECT v_tenant, rt.role_code, rt.role_name, rt.description, 'STANDARD', rt.default_home_module,
           rt.requires_mfa, rt.is_read_only, rt.sort_order
      FROM platform.role_template rt;

    INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
    SELECT v_tenant, ro.id, rtp.privilege_code
      FROM platform.role_template_privilege rtp
      JOIN iam.role ro ON ro.tenant_id = v_tenant AND ro.role_code = rtp.role_code
      JOIN platform.privilege p ON p.privilege_code = rtp.privilege_code
      JOIN platform.tenant_module tm ON tm.tenant_id = v_tenant AND tm.module_code = p.module_code AND tm.is_enabled;

    SELECT id INTO v_adm_role FROM iam.role WHERE tenant_id = v_tenant AND role_code = 'ADM';
    SELECT id INTO v_mgr_role FROM iam.role WHERE tenant_id = v_tenant AND role_code = 'MGR';

    -- 6. settings copied from the published default template
    INSERT INTO cfg.tenant_setting (tenant_id, setting_key, value, effective_from, status, source, template_version, reason)
    SELECT v_tenant, i.setting_key, i.value, DATE '2000-01-01', 'ACTIVE', 'TEMPLATE', v_tpl_ver,
           'Default from settings template v' || v_tpl_ver
      FROM platform.settings_template_item i
     WHERE i.version_no = v_tpl_ver;

    -- 7. legal and tax features (all off unless chosen)
    INSERT INTO platform.tenant_compliance_setting (tenant_id, feature_code, is_enabled, effective_from, reason,
                                                    legal_warning_ack_at)
    SELECT v_tenant, f.feature_code, f.feature_code = ANY (p_features), v_today, 'Set at onboarding',
           CASE WHEN f.feature_code = ANY (p_features) AND f.legal_warning IS NOT NULL THEN now() END
      FROM platform.compliance_feature f;

    -- 8. chart of accounts (accounts of disabled modules / features are not created)
    INSERT INTO acct.account (tenant_id, code, name, account_type, normal_balance, is_group, is_system,
                              template_code, module_code, feature_code, is_cash, allow_manual, sub_ledger_type,
                              status, description, sort_order)
    SELECT v_tenant, t.account_code, t.account_name, t.account_type,
           CASE WHEN t.account_type IN ('ASSET','EXPENSE') THEN 'D' ELSE 'C' END,
           t.is_group, true, t.account_code, t.module_code, t.feature_code, t.is_cash, t.allow_manual,
           t.sub_ledger_type, CASE WHEN t.is_active_default THEN 'ACTIVE' ELSE 'INACTIVE' END, t.notes, t.sort_order
      FROM platform.coa_template t
     WHERE (t.module_code IS NULL OR EXISTS (SELECT 1 FROM platform.tenant_module tm
                                              WHERE tm.tenant_id = v_tenant AND tm.module_code = t.module_code AND tm.is_enabled))
       AND (t.feature_code IS NULL OR t.feature_code = ANY (p_features));

    UPDATE acct.account a
       SET parent_id = p.id
      FROM platform.coa_template t
      JOIN acct.account p ON p.tenant_id = v_tenant AND p.code = t.parent_code
     WHERE a.tenant_id = v_tenant AND a.code = t.account_code AND t.parent_code IS NOT NULL;

    -- 9. one common cash account and the General Community Fund
    INSERT INTO acct.cash_account (tenant_id, code, name, account_id, branch_id, is_default)
    SELECT v_tenant, 'CASH', 'Cash in Hand', a.id, b.id, true
      FROM acct.account a, core.branch b
     WHERE a.tenant_id = v_tenant AND a.code = '1110' AND b.tenant_id = v_tenant AND b.is_default;

    INSERT INTO acct.fund (tenant_id, code, name, fund_type, account_id, is_default)
    SELECT v_tenant, 'GENERAL', 'General Community Fund', 'UNRESTRICTED', a.id, true
      FROM acct.account a WHERE a.tenant_id = v_tenant AND a.code = '3100';

    -- 10. current financial year (start month from settings; default April)
    v_fy_month := coalesce(split_part(cfg.get_setting('accounting.financial_year_start', v_today, v_tenant) #>> '{}', '-', 1)::integer, 4);
    v_fy_start := make_date(extract(year FROM v_today)::integer - CASE WHEN extract(month FROM v_today) < v_fy_month THEN 1 ELSE 0 END,
                            v_fy_month, 1);
    PERFORM acct.create_financial_year(v_tenant, v_fy_start);

    -- 11. account mappings for routine postings (platform.account_mapping_template)
    INSERT INTO acct.account_mapping (tenant_id, mapping_key, account_id)
    SELECT v_tenant, m.mapping_key, a.id
      FROM platform.account_mapping_template m
      JOIN acct.account a ON a.tenant_id = v_tenant AND a.code = m.account_code
     WHERE m.is_active;

    -- 12. lookups cloned from platform templates
    INSERT INTO ops.expense_category (tenant_id, code, name, account_id, approver_role_id, sort_order)
    SELECT v_tenant, l.code, l.name, a.id, v_mgr_role, l.sort_order
      FROM platform.lookup_template l
      JOIN acct.account a ON a.tenant_id = v_tenant AND a.code = l.attributes ->> 'account_code'
     WHERE l.lookup_type = 'EXPENSE_CATEGORY' AND l.is_active;

    INSERT INTO ops.asset_category (tenant_id, code, name, account_id, depreciation_method, useful_life_months, approver_role_id)
    SELECT v_tenant, l.code, l.name, a.id, coalesce(l.attributes ->> 'method', 'NONE'),
           (l.attributes ->> 'life_months')::integer, v_mgr_role
      FROM platform.lookup_template l
      LEFT JOIN acct.account a ON a.tenant_id = v_tenant AND a.code = l.attributes ->> 'account_code'
     WHERE l.lookup_type = 'ASSET_CATEGORY' AND l.is_active;

    INSERT INTO ops.hall_charge_type (tenant_id, code, name, is_security_deposit, account_id)
    SELECT v_tenant, l.code, l.name, coalesce((l.attributes ->> 'security_deposit')::boolean, false), a.id
      FROM platform.lookup_template l
      LEFT JOIN acct.account a ON a.tenant_id = v_tenant AND a.code = l.attributes ->> 'account_code'
     WHERE l.lookup_type = 'HALL_CHARGE_TYPE' AND l.is_active;

    INSERT INTO ops.salary_component (tenant_id, code, name, component_type, calc_type, account_id, is_statutory, sort_order)
    SELECT v_tenant, l.code, l.name, l.attributes ->> 'type', coalesce(l.attributes ->> 'calc', 'FIXED'), a.id,
           coalesce((l.attributes ->> 'statutory')::boolean, false), l.sort_order
      FROM platform.lookup_template l
      LEFT JOIN acct.account a ON a.tenant_id = v_tenant AND a.code = l.attributes ->> 'account_code'
     WHERE l.lookup_type = 'SALARY_COMPONENT' AND l.is_active;

    -- (general reference lists and offline evidence types: step 19b)

    -- 13. registered, approved actions enabled for the tenant
    INSERT INTO cfg.tenant_action (tenant_id, action_code, is_enabled, reason)
    SELECT v_tenant, d.action_code, true, 'Enabled at onboarding'
      FROM platform.action_definition d WHERE d.status = 'APPROVED';

    -- 14. rule sets cloned from the template library (published versions)
    FOR r IN SELECT t.id AS template_id, t.code, t.name, t.module_code, v.id AS tv_id, v.version_no, v.definition, v.json_schema_id
               FROM platform.config_template t
               JOIN platform.config_template_version v ON v.template_id = t.id AND v.status = 'PUBLISHED'
              WHERE t.template_kind = 'RULESET' AND t.is_active
                AND v.version_no = (SELECT max(v2.version_no) FROM platform.config_template_version v2
                                     WHERE v2.template_id = t.id AND v2.status = 'PUBLISHED')
    LOOP
        INSERT INTO cfg.rule_set (tenant_id, code, name, module_code, scope_type, template_id, template_version)
        VALUES (v_tenant, r.code, r.name, r.module_code,
                CASE WHEN r.code LIKE 'LOAN_TYPE_%' THEN 'LOAN_TYPE' ELSE 'GENERAL' END, r.template_id, r.version_no)
        RETURNING id INTO v_rs_id;
        INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                          effective_from, reason, source, source_template_version_id, published_by, published_at)
        VALUES (v_tenant, v_rs_id, 1, 'PUBLISHED', r.definition, r.json_schema_id, DATE '2000-01-01',
                'Cloned from template ' || r.code || ' v' || r.version_no, 'TEMPLATE', r.tv_id, p_platform_user_id, now());
    END LOOP;

    -- 15. loan types (rule-driven) with one principal sub-account per type
    v_seq := 0;
    FOR r IN SELECT lt.* FROM platform.loan_type_template lt ORDER BY lt.sort_order LOOP
        v_seq := v_seq + 1;
        SELECT id INTO v_rs_id FROM cfg.rule_set WHERE tenant_id = v_tenant AND code = r.rule_template_code;
        v_acct_id := NULL;
        IF EXISTS (SELECT 1 FROM acct.account WHERE tenant_id = v_tenant AND code = '1210') THEN
            INSERT INTO acct.account (tenant_id, code, name, account_type, normal_balance, parent_id, is_system,
                                      module_code, allow_manual, sub_ledger_type, sort_order)
            SELECT v_tenant, '1210.' || lpad(v_seq::text, 2, '0'), 'Loan Principal Receivable - ' || r.name,
                   'ASSET', 'D', p.id, true, 'LOAN', false, 'LOAN_TYPE', p.sort_order + v_seq
              FROM acct.account p WHERE p.tenant_id = v_tenant AND p.code = '1210'
            RETURNING id INTO v_acct_id;
        END IF;
        IF v_rs_id IS NOT NULL THEN
            INSERT INTO loan.loan_type (tenant_id, code, name, description, interest_method, is_interest_free,
                                        rule_set_id, principal_account_id, interest_account_id, sort_order)
            SELECT v_tenant, r.code, r.name, r.description, r.interest_method, r.interest_method = 'NONE',
                   v_rs_id, v_acct_id, a.id, r.sort_order
              FROM (SELECT 1) x LEFT JOIN acct.account a ON a.tenant_id = v_tenant AND a.code = '4110';
        END IF;
    END LOOP;
    INSERT INTO acct.account_mapping (tenant_id, mapping_key, scope_type, scope_id, account_id)
    SELECT v_tenant, 'LOAN_PRINCIPAL', 'LOAN_TYPE', lt.id, lt.principal_account_id
      FROM loan.loan_type lt WHERE lt.tenant_id = v_tenant AND lt.principal_account_id IS NOT NULL;

    -- 16. workflows cloned from the template library (published versions, validated on insert)
    FOR r IN SELECT t.id AS template_id, t.code, t.name, t.module_code, t.entity_type,
                    v.id AS tv_id, v.version_no, v.definition, v.json_schema_id
               FROM platform.config_template t
               JOIN platform.config_template_version v ON v.template_id = t.id AND v.status = 'PUBLISHED'
              WHERE t.template_kind = 'WORKFLOW' AND t.is_active
                AND v.version_no = (SELECT max(v2.version_no) FROM platform.config_template_version v2
                                     WHERE v2.template_id = t.id AND v2.status = 'PUBLISHED')
    LOOP
        INSERT INTO cfg.workflow_definition (tenant_id, code, name, module_code, entity_type, template_id, template_version)
        VALUES (v_tenant, r.code, r.name, r.module_code, r.entity_type, r.template_id, r.version_no)
        RETURNING id INTO v_wf_id;
        INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                          json_schema_id, effective_from, reason, source, source_template_version_id,
                                          published_by, published_at)
        VALUES (v_tenant, v_wf_id, 1, 'PUBLISHED', r.definition, r.json_schema_id, DATE '2000-01-01',
                'Cloned from template ' || r.code || ' v' || r.version_no, 'TEMPLATE', r.tv_id, p_platform_user_id, now());
    END LOOP;

    -- 17-18. approval policy, offline recorders and notification templates: step 19b

    -- 19. purge policies (purge off by default)
    INSERT INTO platform.purge_policy (tenant_id, category_code, purge_enabled, retention_years, archive_retention_years)
    SELECT v_tenant, dc.category_code, false, dc.default_years, 2 FROM platform.data_category dc;

    -- 19b. everything else from the template library (43_seed_common_data.sql): reference lists,
    --      approval policy, offline recorders, notification templates, assistance schemes,
    --      deposit products and chit schemes for enabled modules, dashboards
    PERFORM platform.apply_platform_defaults(v_tenant);

    -- 20. default organisation administrator (Web access on, ADM role)
    INSERT INTO iam.app_user (tenant_id, full_name, mobile, email, web_access, mobile_access, username,
                              must_change_password, mfa_enabled, mfa_method, primary_role_id, is_default_org_admin)
    VALUES (v_tenant, p_admin_name, p_admin_mobile, p_admin_email, true, false,
            coalesce(lower(p_admin_email), p_admin_mobile), true, true, 'TOTP', v_adm_role, true)
    RETURNING id INTO v_admin_id;
    INSERT INTO iam.user_role (tenant_id, user_id, role_id, effective_from, reason)
    VALUES (v_tenant, v_admin_id, v_adm_role, v_today, 'Default organisation administrator');

    UPDATE platform.tenant SET status = 'ACTIVE', activated_at = now() WHERE id = v_tenant;

    -- restore caller context
    PERFORM set_config('app.tenant_id', coalesce(c_tenant, ''), true);
    PERFORM set_config('app.scope', coalesce(c_scope, ''), true);
    PERFORM set_config('app.channel', coalesce(c_chan, ''), true);
    PERFORM set_config('app.platform_user_id', coalesce(c_puser, ''), true);
    PERFORM set_config('app.reason', coalesce(c_reason, ''), true);
    PERFORM set_config('app.context_signature', coalesce(c_signature, ''), true);
    RETURN v_tenant;
END
$$;

-- Create the template accounts that belong to a module (used when a module is
-- enabled after onboarding) and, for loans, one principal sub-account per loan type.
CREATE OR REPLACE FUNCTION platform.apply_module_accounts(p_tenant_id uuid, p_module_code text)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_count integer;
    v_seq   integer;
    r       record;
    v_acct  uuid;
BEGIN
    INSERT INTO acct.account (tenant_id, code, name, account_type, normal_balance, is_group, is_system,
                              template_code, module_code, feature_code, is_cash, allow_manual, sub_ledger_type,
                              status, description, sort_order)
    SELECT p_tenant_id, t.account_code, t.account_name, t.account_type,
           CASE WHEN t.account_type IN ('ASSET','EXPENSE') THEN 'D' ELSE 'C' END,
           t.is_group, true, t.account_code, t.module_code, t.feature_code, t.is_cash, t.allow_manual,
           t.sub_ledger_type, CASE WHEN t.is_active_default THEN 'ACTIVE' ELSE 'INACTIVE' END, t.notes, t.sort_order
      FROM platform.coa_template t
     WHERE t.module_code = p_module_code
    ON CONFLICT (tenant_id, code) DO NOTHING;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE acct.account a
       SET parent_id = p.id
      FROM platform.coa_template t
      JOIN acct.account p ON p.tenant_id = p_tenant_id AND p.code = t.parent_code
     WHERE a.tenant_id = p_tenant_id AND a.code = t.account_code AND a.parent_id IS NULL AND t.parent_code IS NOT NULL;

    IF p_module_code = 'LOAN' THEN
        SELECT count(*) INTO v_seq FROM acct.account WHERE tenant_id = p_tenant_id AND code LIKE '1210.%';
        FOR r IN SELECT lt.* FROM loan.loan_type lt
                  WHERE lt.tenant_id = p_tenant_id AND lt.principal_account_id IS NULL ORDER BY lt.sort_order LOOP
            v_seq := v_seq + 1;
            INSERT INTO acct.account (tenant_id, code, name, account_type, normal_balance, parent_id, is_system,
                                      module_code, allow_manual, sub_ledger_type, sort_order)
            SELECT p_tenant_id, '1210.' || lpad(v_seq::text, 2, '0'), 'Loan Principal Receivable - ' || r.name,
                   'ASSET', 'D', p.id, true, 'LOAN', false, 'LOAN_TYPE', p.sort_order + v_seq
              FROM acct.account p WHERE p.tenant_id = p_tenant_id AND p.code = '1210'
            RETURNING id INTO v_acct;
            UPDATE loan.loan_type
               SET principal_account_id = v_acct,
                   interest_account_id = coalesce(interest_account_id,
                       (SELECT id FROM acct.account WHERE tenant_id = p_tenant_id AND code = '4110'))
             WHERE tenant_id = p_tenant_id AND id = r.id;
            INSERT INTO acct.account_mapping (tenant_id, mapping_key, scope_type, scope_id, account_id)
            VALUES (p_tenant_id, 'LOAN_PRINCIPAL', 'LOAN_TYPE', r.id, v_acct);
            v_count := v_count + 1;
        END LOOP;
    END IF;
    RETURN v_count;
END
$$;

-- Enable / disable a module for a tenant (Super Admin only, Section 3.9.1).
-- Owner/provisioning entry point: sets a Super Admin context for the tenant,
-- then applies the change. The API uses platform.set_tenant_module (31c),
-- which runs platform.apply_module_enabled under a signed context instead.
CREATE OR REPLACE FUNCTION platform.set_module_enabled(
    p_tenant_id uuid, p_module_code text, p_enabled boolean, p_reason text,
    p_platform_user_id uuid DEFAULT NULL, p_legal_warning_ack boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM set_config('app.scope', 'platform', true);
    PERFORM set_config('app.tenant_id', p_tenant_id::text, true);
    PERFORM set_config('app.channel', 'SUPER_ADMIN', true);
    PERFORM set_config('app.platform_user_id', coalesce(p_platform_user_id::text, ''), true);
    PERFORM set_config('app.reason', p_reason, true);

    PERFORM platform.apply_module_enabled(p_tenant_id, p_module_code, p_enabled, p_reason,
                                          p_platform_user_id, p_legal_warning_ack);
END
$$;

-- The module change itself, under whatever (valid) context the caller set.
CREATE OR REPLACE FUNCTION platform.apply_module_enabled(
    p_tenant_id uuid, p_module_code text, p_enabled boolean, p_reason text,
    p_platform_user_id uuid DEFAULT NULL, p_legal_warning_ack boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE
    v_mod platform.module%ROWTYPE;
    v_open boolean := false;
BEGIN
    SELECT * INTO v_mod FROM platform.module WHERE module_code = p_module_code;
    IF NOT FOUND THEN PERFORM app.fail('UNKNOWN_MODULE', 'Unknown module ' || p_module_code); END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required');
    END IF;
    IF NOT p_enabled AND v_mod.is_core THEN
        PERFORM app.fail('CORE_MODULE', 'Core modules cannot be disabled');
    END IF;
    IF p_enabled AND v_mod.is_optional_legal AND NOT p_legal_warning_ack THEN
        PERFORM app.fail('LEGAL_WARNING', 'The legal warning must be acknowledged before enabling ' || p_module_code);
    END IF;

    IF NOT p_enabled THEN
        v_open := CASE p_module_code
            WHEN 'LOAN'    THEN EXISTS (SELECT 1 FROM loan.loan WHERE tenant_id = p_tenant_id
                                         AND status NOT IN ('REJECTED','WITHDRAWN','CANCELLED','SETTLED','CLOSED','WRITTEN_OFF','TRANSFERRED'))
            WHEN 'DEPOSIT' THEN EXISTS (SELECT 1 FROM dep.deposit_account WHERE tenant_id = p_tenant_id
                                         AND status NOT IN ('CLOSED','PREMATURELY_CLOSED','RENEWED','REJECTED'))
            WHEN 'CHIT'    THEN EXISTS (SELECT 1 FROM chit.chit_group WHERE tenant_id = p_tenant_id
                                         AND status NOT IN ('CLOSED','TERMINATED'))
            ELSE false END;
        IF v_open THEN
            PERFORM app.fail('OPEN_ITEMS', 'Module ' || p_module_code || ' has open items and cannot be disabled');
        END IF;
    END IF;

    INSERT INTO platform.tenant_module AS tm (tenant_id, module_code, is_enabled, enabled_at, enabled_by, reason,
                                              legal_warning_ack_at, legal_warning_ack_by)
    VALUES (p_tenant_id, p_module_code, p_enabled, CASE WHEN p_enabled THEN now() END,
            CASE WHEN p_enabled THEN p_platform_user_id END, p_reason,
            CASE WHEN p_legal_warning_ack THEN now() END, CASE WHEN p_legal_warning_ack THEN p_platform_user_id END)
    ON CONFLICT (tenant_id, module_code) DO UPDATE
       SET is_enabled  = EXCLUDED.is_enabled,
           enabled_at  = CASE WHEN EXCLUDED.is_enabled THEN now() ELSE tm.enabled_at END,
           enabled_by  = CASE WHEN EXCLUDED.is_enabled THEN p_platform_user_id ELSE tm.enabled_by END,
           disabled_at = CASE WHEN NOT EXCLUDED.is_enabled THEN now() ELSE tm.disabled_at END,
           disabled_by = CASE WHEN NOT EXCLUDED.is_enabled THEN p_platform_user_id ELSE tm.disabled_by END,
           reason      = EXCLUDED.reason,
           legal_warning_ack_at = coalesce(EXCLUDED.legal_warning_ack_at, tm.legal_warning_ack_at),
           legal_warning_ack_by = coalesce(EXCLUDED.legal_warning_ack_by, tm.legal_warning_ack_by);

    -- hidden sub-functions (is_menu = false) follow their parent
    UPDATE platform.tenant_module tm
       SET is_enabled = p_enabled, reason = 'Follows parent ' || p_module_code
      FROM platform.module m
     WHERE tm.tenant_id = p_tenant_id AND tm.module_code = m.module_code
       AND m.parent_module_code = p_module_code AND NOT m.is_menu;
    INSERT INTO platform.tenant_module (tenant_id, module_code, is_enabled, enabled_at, reason)
    SELECT p_tenant_id, m.module_code, p_enabled, now(), 'Follows parent ' || p_module_code
      FROM platform.module m
     WHERE m.parent_module_code = p_module_code AND NOT m.is_menu
    ON CONFLICT (tenant_id, module_code) DO NOTHING;

    IF p_enabled THEN
        PERFORM platform.apply_module_accounts(p_tenant_id, p_module_code);
        PERFORM platform.apply_platform_defaults(p_tenant_id);
    END IF;

    INSERT INTO cfg.config_change_log (tenant_id, object_type, action, reason, platform_user_id, result)
    VALUES (p_tenant_id, 'MODULE', CASE WHEN p_enabled THEN 'ENABLE' ELSE 'DISABLE' END, p_reason, p_platform_user_id,
            jsonb_build_object('module_code', p_module_code));
END
$$;
