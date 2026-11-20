-- =============================================================================
-- CFMS / NVS  -  31g  Rules linked to workflow transitions
-- -----------------------------------------------------------------------------
-- Run as nvs after 31f. Safe to re-run.
--
-- A workflow transition can list "ruleChecks": rule checks the API evaluates
-- when the transition happens (app/services/loan_rules.py), instead of fixed
-- check points in code. The loan keeps the workflow version it was created
-- with, so changing a later version never changes loans already in progress.
--
--   cfg.rule_check_codes()                 -> codes a transition may list
--   cfg.validate_workflow(...)             -> also validates ruleChecks
--   loan.nominee_status(loan)              -> NOMINEE rule state for a loan
--   loan.set_application_nominees(loan, ids, row_version)
--   loan.record_nominee_override(loan, reason)   (replaces the 3-argument one)
--   LOAN_APPLICATION workflow v2 (template + existing organisations):
--     SUBMIT   -> eligibility, limits, guarantors (no nominee needed)
--     APPROVE  -> NOMINEE, GUARANTORS
--     DISBURSE -> NOMINEE (re-check: a nominee may have become inactive)
-- =============================================================================

CREATE OR REPLACE FUNCTION cfg.rule_check_codes()
RETURNS text[] LANGUAGE sql IMMUTABLE AS
$$
    SELECT ARRAY['MEMBER_STATUS','MEMBERSHIP_PERIOD','CONCURRENT_LOANS','OVERDUE_DUES','AGE_LIMITS',
                 'EXPOSURE_LIMITS','AMOUNT_LIMITS','TENURE_LIMITS','GUARANTORS','NOMINEE']
$$;

CREATE OR REPLACE FUNCTION cfg.validate_workflow(p_definition jsonb, p_tenant_id uuid)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_errors text[] := '{}';
    v_start  text := p_definition ->> 'startStage';
    r        record;
BEGIN
    IF jsonb_typeof(p_definition -> 'stages') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_definition -> 'stages') = 0 THEN
        RETURN ARRAY['stages must be a non-empty array'];
    END IF;
    IF jsonb_typeof(p_definition -> 'transitions') IS DISTINCT FROM 'array' THEN
        RETURN ARRAY['transitions must be an array'];
    END IF;

    -- stage codes present and unique
    FOR r IN SELECT s ->> 'code' AS code, count(*) AS n
               FROM jsonb_array_elements(p_definition -> 'stages') s
              GROUP BY 1 HAVING count(*) > 1 OR s ->> 'code' IS NULL LOOP
        v_errors := v_errors || format('stage code %s is missing or duplicated', coalesce(r.code, '(null)'));
    END LOOP;

    -- exactly one start stage that exists
    IF v_start IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s
                                       WHERE s ->> 'code' = v_start) THEN
        v_errors := v_errors || format('startStage %s does not exist', coalesce(v_start, '(null)'));
    END IF;

    -- transitions reference existing stages
    FOR r IN SELECT t ->> 'from' AS f, t ->> 'to' AS tt, t ->> 'on' AS ev
               FROM jsonb_array_elements(p_definition -> 'transitions') t LOOP
        IF r.ev IS NULL THEN
            v_errors := v_errors || format('transition %s -> %s has no "on" event', r.f, r.tt);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s WHERE s ->> 'code' = r.f) THEN
            v_errors := v_errors || format('transition from unknown stage %s', r.f);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s WHERE s ->> 'code' = r.tt) THEN
            v_errors := v_errors || format('transition to unknown stage %s', r.tt);
        END IF;
    END LOOP;

    -- rule checks: an array of codes or {"code", "onFail"}; known codes and
    -- outcomes; no duplicates per transition
    FOR r IN SELECT t ->> 'on' AS ev, t -> 'ruleChecks' AS checks
               FROM jsonb_array_elements(p_definition -> 'transitions') t
              WHERE t ? 'ruleChecks' LOOP
        IF jsonb_typeof(r.checks) IS DISTINCT FROM 'array' THEN
            v_errors := v_errors || format('transition %s: ruleChecks must be an array', r.ev);
            CONTINUE;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.checks) c
                    WHERE coalesce(CASE jsonb_typeof(c) WHEN 'string' THEN c #>> '{}' ELSE c ->> 'code' END, '')
                          <> ALL (cfg.rule_check_codes())) THEN
            v_errors := v_errors || format('transition %s: unknown rule check %s', r.ev,
                (SELECT string_agg(coalesce(CASE jsonb_typeof(c) WHEN 'string' THEN c #>> '{}' ELSE c ->> 'code' END,
                                            '(missing)'), ', ')
                   FROM jsonb_array_elements(r.checks) c
                  WHERE coalesce(CASE jsonb_typeof(c) WHEN 'string' THEN c #>> '{}' ELSE c ->> 'code' END, '')
                        <> ALL (cfg.rule_check_codes())));
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.checks) c
                    WHERE jsonb_typeof(c) = 'object' AND c ? 'onFail'
                      AND c ->> 'onFail' NOT IN ('BLOCK','REQUIRE_OVERRIDE','ROUTE_TO_ROLE','WARN')) THEN
            v_errors := v_errors || format('transition %s: onFail must be BLOCK, REQUIRE_OVERRIDE, ROUTE_TO_ROLE or WARN', r.ev);
        END IF;
        IF (SELECT count(*) FROM jsonb_array_elements(r.checks))
           <> (SELECT count(DISTINCT CASE jsonb_typeof(c) WHEN 'string' THEN c #>> '{}' ELSE c ->> 'code' END)
                 FROM jsonb_array_elements(r.checks) c) THEN
            v_errors := v_errors || format('transition %s: a rule check is listed twice', r.ev);
        END IF;
    END LOOP;

    -- no dead ends except end stages
    FOR r IN SELECT s ->> 'code' AS code
               FROM jsonb_array_elements(p_definition -> 'stages') s
              WHERE NOT coalesce((s ->> 'end')::boolean, false)
                AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'transitions') t
                                 WHERE t ->> 'from' = s ->> 'code') LOOP
        v_errors := v_errors || format('stage %s is a dead end (no outgoing transition and not an end stage)', r.code);
    END LOOP;

    -- every stage reachable from the start stage
    FOR r IN
        WITH RECURSIVE reach(code) AS (
            SELECT v_start
            UNION
            SELECT t ->> 'to'
              FROM reach
              JOIN jsonb_array_elements(p_definition -> 'transitions') t ON t ->> 'from' = reach.code)
        SELECT s ->> 'code' AS code
          FROM jsonb_array_elements(p_definition -> 'stages') s
         WHERE s ->> 'code' NOT IN (SELECT code FROM reach WHERE code IS NOT NULL)
    LOOP
        v_errors := v_errors || format('stage %s is not reachable from the start stage', r.code);
    END LOOP;

    -- actions registered, approved and enabled for the tenant
    FOR r IN SELECT DISTINCT a ->> 'action' AS action_code
               FROM jsonb_array_elements(p_definition -> 'stages') s,
                    jsonb_array_elements(coalesce(s -> 'actions', '[]'::jsonb)) a LOOP
        IF NOT EXISTS (SELECT 1 FROM platform.action_definition d
                        WHERE d.action_code = r.action_code AND d.status = 'APPROVED') THEN
            v_errors := v_errors || format('action %s is not a registered, approved action', r.action_code);
        ELSIF NOT EXISTS (SELECT 1 FROM cfg.tenant_action ta
                           WHERE ta.tenant_id = p_tenant_id AND ta.action_code = r.action_code AND ta.is_enabled) THEN
            v_errors := v_errors || format('action %s is not enabled for this organisation', r.action_code);
        END IF;
    END LOOP;

    -- roles exist in the tenant
    FOR r IN SELECT DISTINCT s ->> 'role' AS role_code
               FROM jsonb_array_elements(p_definition -> 'stages') s
              WHERE s ? 'role' LOOP
        IF NOT EXISTS (SELECT 1 FROM iam.role ro
                        WHERE ro.tenant_id = p_tenant_id AND ro.role_code = r.role_code AND ro.status = 'ACTIVE') THEN
            v_errors := v_errors || format('role %s does not exist or is inactive', r.role_code);
        END IF;
    END LOOP;

    RETURN v_errors;
END
$$;

-- The member's most recent loan (other than p_exclude_loan) that is DEFAULTED
-- or WRITTEN_OFF now, or that defaulted within p_lookback_months (null = ever).
CREATE OR REPLACE FUNCTION loan.member_past_default(
    p_member_id uuid, p_lookback_months integer, p_exclude_loan uuid DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS
$$
    SELECT l.loan_no
      FROM loan.loan l
      LEFT JOIN LATERAL (
          SELECT max(d.defaulted_on) AS last_default
            FROM loan.loan_default d
           WHERE d.tenant_id = l.tenant_id AND d.loan_id = l.id) d ON true
     WHERE l.tenant_id = app.tenant_id() AND l.member_id = p_member_id
       AND l.id IS DISTINCT FROM p_exclude_loan
       AND (l.status IN ('DEFAULTED', 'WRITTEN_OFF')
            OR (d.last_default IS NOT NULL
                AND (p_lookback_months IS NULL
                     OR d.last_default >= (app.working_date() - make_interval(months => p_lookback_months))::date)))
     ORDER BY coalesce(d.last_default, l.status_date) DESC NULLS LAST, l.loan_no
     LIMIT 1
$$;

-- NOMINEE rule state of a loan, from the loan's own rule snapshot.
-- Rule value (current): {"conditions": {"firstLoan": true, "thresholdAmount": 100000,
--   "defaulter": {"enabled": true, "lookbackMonths": 24}}, "allowOverride": true}
-- A nominee is required if ANY enabled condition is met. Older snapshots
-- ({"everyLoan", "firstLoan", "thresholdAmount"} at the top) keep working.
CREATE OR REPLACE FUNCTION loan.nominee_status(p_loan_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_loan      loan.loan%ROWTYPE;
    v_rule      jsonb;
    v_cond      jsonb;
    v_amount    numeric;
    v_threshold numeric;
    v_why       text[] := '{}';
    v_default   text;
    v_active    integer;
    v_setting   boolean := coalesce((cfg.get_setting('loans.nominee_mandatory_first_loan') #>> '{}')::boolean, true);
BEGIN
    SELECT * INTO v_loan FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application not found');
    END IF;
    SELECT r -> 'value' INTO v_rule
      FROM jsonb_array_elements(coalesce(v_loan.rule_snapshot -> 'rules', '[]'::jsonb)) r
     WHERE r ->> 'code' = 'NOMINEE' LIMIT 1;
    v_rule := coalesce(v_rule, '{}'::jsonb);
    v_cond := coalesce(v_rule -> 'conditions', v_rule);          -- older snapshots: conditions at the top
    v_amount := coalesce(v_loan.approved_amount, v_loan.requested_amount);
    v_threshold := nullif(v_cond ->> 'thresholdAmount', '')::numeric;

    IF coalesce((v_rule ->> 'everyLoan')::boolean, false) THEN
        v_why := array_append(v_why, 'EVERY_LOAN');
    END IF;
    IF v_loan.is_first_loan AND v_setting AND coalesce((v_cond ->> 'firstLoan')::boolean, true) THEN
        v_why := array_append(v_why, 'FIRST_LOAN');
    END IF;
    IF v_threshold IS NOT NULL AND v_amount >= v_threshold THEN
        v_why := array_append(v_why, 'THRESHOLD');
    END IF;
    IF coalesce((v_cond -> 'defaulter' ->> 'enabled')::boolean, false) THEN
        v_default := loan.member_past_default(v_loan.member_id,
                                              nullif(v_cond -> 'defaulter' ->> 'lookbackMonths', '')::integer,
                                              v_loan.id);
        IF v_default IS NOT NULL THEN
            v_why := array_append(v_why, 'PAST_DEFAULT');
        END IF;
    END IF;
    v_active := loan.count_active_application_nominees(p_loan_id);
    RETURN jsonb_build_object(
        'required', cardinality(v_why) > 0,
        'required_because', to_jsonb(v_why),
        'threshold_amount', v_threshold,
        'default_loan_no', v_default,
        'active_nominees', v_active,
        'linked', v_active > 0,
        'override_allowed', coalesce((v_rule ->> 'allowOverride')::boolean, true),
        'overridden', v_loan.nominee_override_reason IS NOT NULL,
        'override_reason', v_loan.nominee_override_reason,
        'satisfied', cardinality(v_why) = 0 OR v_active > 0 OR v_loan.nominee_override_reason IS NOT NULL);
END
$$;

-- Statuses in which nominees can still be linked or overridden: before
-- approval, and after approval until the first disbursement.
CREATE OR REPLACE FUNCTION loan.assert_nominee_changeable(v_loan loan.loan)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF v_loan.status NOT IN ('DRAFT','RETURNED','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','APPROVED')
       OR (v_loan.status = 'APPROVED' AND v_loan.disbursed_amount > 0) THEN
        PERFORM app.fail('APPLICATION_NOT_EDITABLE',
            format('Nominees cannot be changed for a loan in status %s', v_loan.status));
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION loan.set_application_nominees(
    p_loan_id uuid, p_nominee_ids uuid[], p_expected_version integer)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan loan.loan%ROWTYPE;
    v_ids  uuid[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_nominee_ids, '{}')));
BEGIN
    SELECT * INTO v_loan FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application not found');
    END IF;
    IF p_expected_version IS NULL THEN
        PERFORM app.fail('ROW_VERSION_REQUIRED', 'Send the row version of the loan you opened');
    END IF;
    IF v_loan.row_version <> p_expected_version THEN
        PERFORM app.fail('STALE_RECORD', 'The loan was changed after it was opened');
    END IF;
    PERFORM loan.assert_nominee_changeable(v_loan);
    IF cardinality(v_ids) > 10 THEN
        PERFORM app.fail('INVALID_DATA', 'nominee_ids');
    END IF;
    IF cardinality(v_ids) > 0 AND NOT loan.validate_nominees(v_loan.member_id, v_ids) THEN
        PERFORM app.fail('NOMINEE_NOT_ACTIVE', 'A selected nominee is not active for this member');
    END IF;
    PERFORM app.set_audit_reason('Loan nominees changed', 'LOAN_NOMINEES', p_loan_id::text);
    DELETE FROM loan.loan_nominee ln
     WHERE ln.tenant_id = app.tenant_id() AND ln.loan_id = p_loan_id AND ln.nominee_id <> ALL (v_ids);
    INSERT INTO loan.loan_nominee (loan_id, nominee_id)
    SELECT p_loan_id, n FROM unnest(v_ids) n
    ON CONFLICT (tenant_id, loan_id, nominee_id) DO NOTHING;
    UPDATE loan.loan SET updated_at = now() WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    RETURN loan.nominee_status(p_loan_id) || jsonb_build_object(
        'row_version', (SELECT row_version FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id),
        'nominee_ids', to_jsonb(v_ids));
END
$$;

-- Record a nominee override (privilege loan.nominee_override, reason 3-500,
-- NOMINEE.allowOverride from the loan's rule snapshot).
DROP FUNCTION IF EXISTS loan.record_nominee_override(uuid, text, boolean);
CREATE OR REPLACE FUNCTION loan.record_nominee_override(p_loan_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan   loan.loan%ROWTYPE;
    v_status jsonb;
BEGIN
    SELECT * INTO v_loan FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application not found');
    END IF;
    PERFORM loan.assert_nominee_changeable(v_loan);
    v_status := loan.nominee_status(p_loan_id);
    PERFORM mbr.assert_nominee_override((v_status ->> 'override_allowed')::boolean, p_reason, 'NOMINEE_REQUIRED');
    PERFORM app.set_audit_reason('Nominee rule overridden: ' || btrim(p_reason), 'NOMINEE_OVERRIDE', p_loan_id::text);
    UPDATE loan.loan
       SET nominee_override_reason = btrim(p_reason), nominee_override_by = app.user_id(),
           nominee_override_at = now()
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    RETURN loan.nominee_status(p_loan_id);
END
$$;

-- Approval request -> loan (the APPROVE transition needs the loan).
CREATE OR REPLACE FUNCTION loan.loan_for_approval_request(p_request_id uuid)
RETURNS uuid LANGUAGE sql STABLE AS
$$
    SELECT ar.entity_id FROM wf.approval_request ar
     WHERE ar.tenant_id = app.tenant_id() AND ar.id = p_request_id AND ar.entity_type = 'loan.loan'
$$;

REVOKE ALL ON FUNCTION cfg.rule_check_codes(), loan.nominee_status(uuid), loan.member_past_default(uuid, integer, uuid), loan.assert_nominee_changeable(loan.loan),
    loan.set_application_nominees(uuid, uuid[], integer), loan.record_nominee_override(uuid, text),
    loan.loan_for_approval_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cfg.rule_check_codes(), loan.nominee_status(uuid), loan.member_past_default(uuid, integer, uuid), loan.assert_nominee_changeable(loan.loan),
    loan.set_application_nominees(uuid, uuid[], integer), loan.record_nominee_override(uuid, text),
    loan.loan_for_approval_request(uuid) TO nvs_app;

-- LOAN_APPLICATION workflow v2 with rule checks -------------------------------
CREATE OR REPLACE FUNCTION platform.loan_workflow_with_rule_checks(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{transitions}', (
        SELECT jsonb_agg(CASE t ->> 'on'
            WHEN 'SUBMIT'  THEN t || '{"ruleChecks": ["MEMBER_STATUS","MEMBERSHIP_PERIOD","CONCURRENT_LOANS",
                                    "OVERDUE_DUES","AGE_LIMITS","EXPOSURE_LIMITS","AMOUNT_LIMITS","TENURE_LIMITS",
                                    "GUARANTORS"]}'::jsonb
            WHEN 'APPROVE' THEN t || '{"ruleChecks": ["NOMINEE","GUARANTORS"]}'::jsonb
            WHEN 'DISBURSE' THEN t || '{"ruleChecks": ["NOMINEE"]}'::jsonb
            ELSE t END ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'transitions') WITH ORDINALITY x(t, ord)))
$$;

SET app.channel TO 'MIGRATION';
SET app.reason TO 'Loan workflow v2: rules linked to transitions; nominee checked at approval';

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 2, 'PUBLISHED',
       jsonb_set(platform.loan_workflow_with_rule_checks(v.definition), '{version}', '2'),
       v.json_schema_id, 'Rules linked to transitions; nominee checked at approval and disbursement', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id AND v.version_no = 1
 WHERE t.template_kind = 'WORKFLOW' AND t.code = 'LOAN_APPLICATION'
ON CONFLICT (template_id, version_no) DO NOTHING;

DO $$
DECLARE
    t      record;
    w      record;
    v_next integer;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        SELECT d.id AS definition_id, v.definition, v.json_schema_id INTO w
          FROM cfg.workflow_definition d
          JOIN cfg.workflow_version v ON v.id = cfg.workflow_version_at('LOAN_APPLICATION', app.tenant_today(t.id), t.id)
         WHERE d.tenant_id = t.id AND d.code = 'LOAN_APPLICATION';
        IF w.definition_id IS NULL
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(w.definition -> 'transitions') x WHERE x ? 'ruleChecks') THEN
            CONTINUE;
        END IF;
        SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.workflow_version WHERE workflow_definition_id = w.definition_id;
        INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                          json_schema_id, effective_from, reason, source)
        VALUES (t.id, w.definition_id, v_next, 'PUBLISHED',
                jsonb_set(platform.loan_workflow_with_rule_checks(w.definition), '{version}', to_jsonb(v_next)),
                w.json_schema_id, app.tenant_today(t.id),
                'Rules linked to transitions; nominee checked at approval and disbursement', 'TEMPLATE');
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;
