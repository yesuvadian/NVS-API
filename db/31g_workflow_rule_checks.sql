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
    v_entity  text;
    v_allowed text[];
    v_key     text;
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

    -- The initialization stage is the first stage in every workflow document.
    -- startStage names it; all later transitions leave it through workflow JSON.
    IF v_start IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s
                                       WHERE s ->> 'code' = v_start) THEN
        v_errors := v_errors || format('startStage %s does not exist', coalesce(v_start, '(null)'));
    ELSE
        -- The workflow document is ordered intentionally: the initialization
        -- stage is always the first stage and startStage must name it.
        IF (p_definition -> 'stages' -> 0 ->> 'code') IS DISTINCT FROM v_start THEN
            v_errors := v_errors || ARRAY['startStage must be the first workflow stage (initialization stage)'];
        END IF;
        IF p_definition->>'workflow' = 'LOAN_APPLICATION'
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s
                        WHERE s ->> 'code'=v_start AND s ? 'statuses'
                          AND s -> 'statuses' ? 'initial'
                          AND s -> 'statuses' ? 'entityStatus') THEN
            v_errors := v_errors || format('startStage %s must define initial stage and entity statuses',v_start);
        END IF;
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
    FOR r IN SELECT DISTINCT coalesce(a ->> 'code',a ->> 'action') AS action_code
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

    -- stage statuses: entityStatus is one of the entity's statuses (the fixed
    -- domain set in its status CHECK); stage status codes unique; initial,
    -- onPartialApproval and onRouted name one of them
    v_entity := (SELECT d.entity_type FROM cfg.workflow_definition d
                  WHERE d.tenant_id = p_tenant_id AND d.code = p_definition ->> 'workflow' LIMIT 1);
    v_allowed := cfg.entity_statuses(coalesce(v_entity, 'loan.loan'));
    FOR r IN SELECT s ->> 'code' AS code, s -> 'statuses' AS st
               FROM jsonb_array_elements(p_definition -> 'stages') s WHERE s ? 'statuses' LOOP
        IF jsonb_typeof(r.st) <> 'object' THEN
            v_errors := v_errors || format('stage %s: statuses must be an object', r.code);
            CONTINUE;
        END IF;
        IF r.st ? 'entityStatus' AND NOT (r.st ->> 'entityStatus') = ANY (coalesce(v_allowed, '{}')) THEN
            v_errors := v_errors || format('stage %s: entityStatus %s is not a status of %s',
                                           r.code, r.st ->> 'entityStatus', coalesce(v_entity, 'loan.loan'));
        END IF;
        IF jsonb_typeof(r.st -> 'stageStatuses') IS DISTINCT FROM 'array' OR jsonb_array_length(r.st -> 'stageStatuses') = 0 THEN
            v_errors := v_errors || format('stage %s: stageStatuses must be a non-empty array', r.code);
            CONTINUE;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.st -> 'stageStatuses') x
                    GROUP BY x ->> 'code' HAVING count(*) > 1 OR x ->> 'code' IS NULL) THEN
            v_errors := v_errors || format('stage %s: stage status codes must be present and unique', r.code);
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.st -> 'stageStatuses') x
                    WHERE (x ->> 'code') !~ '^[A-Z][A-Z0-9_]*$') THEN
            v_errors := v_errors || format('stage %s: stage status codes must be UPPER_SNAKE_CASE', r.code);
        END IF;
        FOR v_key IN SELECT k FROM unnest(ARRAY['initial', 'onPartialApproval', 'onRouted']) k LOOP
            IF r.st ? v_key AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r.st -> 'stageStatuses') x
                                             WHERE x ->> 'code' = r.st ->> v_key) THEN
                v_errors := v_errors || format('stage %s: %s %s is not one of its stage statuses',
                                               r.code, v_key, r.st ->> v_key);
            END IF;
        END LOOP;
    END LOOP;
    -- transitions: stageStatus is a status of the source stage; entityStatus allowed
    FOR r IN SELECT t ->> 'on' AS ev, t ->> 'from' AS f, t ->> 'stageStatus' AS ss, t ->> 'entityStatus' AS es
               FROM jsonb_array_elements(p_definition -> 'transitions') t
              WHERE t ? 'stageStatus' OR t ? 'entityStatus' LOOP
        IF r.ss IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s,
                             jsonb_array_elements(coalesce(s -> 'statuses' -> 'stageStatuses', '[]'::jsonb)) x
                WHERE s ->> 'code' = r.f AND x ->> 'code' = r.ss) THEN
            v_errors := v_errors || format('transition %s from %s: stageStatus %s is not a status of stage %s',
                                           r.ev, r.f, r.ss, r.f);
        END IF;
        IF r.es IS NOT NULL AND NOT r.es = ANY (coalesce(v_allowed, '{}')) THEN
            v_errors := v_errors || format('transition %s from %s: entityStatus %s is not a status of %s',
                                           r.ev, r.f, r.es, coalesce(v_entity, 'loan.loan'));
        END IF;
    END LOOP;

    -- engine: maker stages name an existing privilege
    FOR r IN SELECT s ->> 'code' AS code, s ->> 'actorPrivilege' AS priv
               FROM jsonb_array_elements(p_definition -> 'stages') s
              WHERE s ? 'actorPrivilege' LOOP
        IF NOT EXISTS (SELECT 1 FROM platform.privilege p WHERE p.privilege_code = r.priv AND p.is_active) THEN
            v_errors := v_errors || format('stage %s: actorPrivilege %s is not a known privilege', r.code, r.priv);
        END IF;
    END LOOP;

    -- engine: transition actions (registry codes, seq, onError, params) and
    -- button metadata (db/31j)
    v_errors := v_errors || cfg.validate_workflow_actions(p_definition, p_tenant_id)
                         || cfg.validate_workflow_buttons(p_definition, p_tenant_id);

    -- engine: role lists (approval roles, offline recorders, amount bands,
    -- ROUTE_TO_ROLE) name active roles of the organisation
    FOR r IN
        SELECT DISTINCT x.where_, x.role_code
          FROM (
            SELECT 'stage ' || (s ->> 'code') || ' approval' AS where_, rc AS role_code
              FROM jsonb_array_elements(p_definition -> 'stages') s,
                   jsonb_array_elements_text(coalesce(s -> 'approval' -> 'roles', '[]'::jsonb)
                                             || coalesce(s -> 'approval' -> 'offlineRecorderRoles', '[]'::jsonb)) rc
            UNION ALL
            SELECT 'stage ' || (s ->> 'code') || ' amount band', rc
              FROM jsonb_array_elements(p_definition -> 'stages') s,
                   jsonb_array_elements(coalesce(s -> 'approval' -> 'amountBands', '[]'::jsonb)) b,
                   jsonb_array_elements_text(coalesce(b -> 'roles', '[]'::jsonb)) rc
            UNION ALL
            SELECT 'transition ' || (t ->> 'on') || ' ROUTE_TO_ROLE', rc
              FROM jsonb_array_elements(p_definition -> 'transitions') t,
                   jsonb_array_elements(CASE jsonb_typeof(t -> 'ruleChecks') WHEN 'array' THEN t -> 'ruleChecks'
                                             ELSE '[]'::jsonb END) c,
                   jsonb_array_elements_text(CASE WHEN jsonb_typeof(c) = 'object' THEN coalesce(c -> 'roles', '[]'::jsonb)
                                                  ELSE '[]'::jsonb END) rc
          ) x
    LOOP
        IF p_tenant_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM iam.role ro
                 WHERE ro.tenant_id = p_tenant_id AND ro.role_code = r.role_code AND ro.status = 'ACTIVE') THEN
            v_errors := v_errors || format('%s: role %s does not exist or is inactive', r.where_, r.role_code);
        END IF;
    END LOOP;

    -- engine: approval settings are well formed
    FOR r IN SELECT s ->> 'code' AS code, s -> 'approval' AS ap
               FROM jsonb_array_elements(p_definition -> 'stages') s
              WHERE jsonb_typeof(s -> 'approval') = 'object' AND (s -> 'approval') ? 'roles' LOOP
        IF jsonb_typeof(r.ap -> 'roles') <> 'array' OR jsonb_array_length(r.ap -> 'roles') = 0 THEN
            v_errors := v_errors || format('stage %s: approval roles must be a non-empty array', r.code);
        END IF;
        IF r.ap ? 'minApprovals' AND (jsonb_typeof(r.ap -> 'minApprovals') <> 'number'
                                      OR (r.ap ->> 'minApprovals')::numeric < 1) THEN
            v_errors := v_errors || format('stage %s: minApprovals must be a number of at least 1', r.code);
        END IF;
        IF r.ap ? 'amountBands' AND (jsonb_typeof(r.ap -> 'amountBands') <> 'array' OR EXISTS (
                SELECT 1 FROM jsonb_array_elements(r.ap -> 'amountBands') b
                 WHERE jsonb_typeof(b -> 'minAmount') <> 'number' OR (b ->> 'minAmount')::numeric < 0
                    OR jsonb_typeof(b -> 'roles') <> 'array' OR jsonb_array_length(b -> 'roles') = 0)) THEN
            v_errors := v_errors || format('stage %s: each amount band needs minAmount (>= 0) and roles', r.code);
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'transitions') t,
                             jsonb_array_elements(CASE jsonb_typeof(t -> 'ruleChecks') WHEN 'array'
                                                  THEN t -> 'ruleChecks' ELSE '[]'::jsonb END) c
                WHERE jsonb_typeof(c) = 'object' AND c ->> 'onFail' = 'ROUTE_TO_ROLE'
                  AND (jsonb_typeof(c -> 'roles') IS DISTINCT FROM 'array' OR jsonb_array_length(c -> 'roles') = 0)) THEN
        v_errors := v_errors || 'ROUTE_TO_ROLE needs a non-empty "roles" list'::text;
    END IF;

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
    IF v_loan.is_first_loan AND coalesce((v_cond ->> 'firstLoan')::boolean, false) THEN
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
        'override_allowed', coalesce((v_rule ->> 'allowOverride')::boolean, false),
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

-- Checks and links nominees of a loan without touching the loan row (the
-- caller updates it once): stage, privilege by stage, count limit, active
-- nominees of the member, audit reason.
CREATE OR REPLACE FUNCTION loan.link_application_nominees(p_loan_id uuid, p_nominee_ids uuid[])
RETURNS uuid[] LANGUAGE plpgsql AS
$$
DECLARE
    v_loan loan.loan%ROWTYPE;
    v_ids  uuid[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_nominee_ids, '{}')));
BEGIN
    SELECT * INTO v_loan FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application not found');
    END IF;
    PERFORM loan.assert_nominee_changeable(v_loan);
    -- Draft/returned: the maker (loan.create) or loan.edit; after submission
    -- until the first disbursement: loan.edit.
    IF app.user_id() IS NOT NULL AND NOT iam.has_privilege(app.user_id(), 'loan.edit')
       AND NOT (v_loan.status IN ('DRAFT', 'RETURNED') AND iam.has_privilege(app.user_id(), 'loan.create')) THEN
        PERFORM app.fail('NO_PRIVILEGE', CASE WHEN v_loan.status IN ('DRAFT', 'RETURNED')
            THEN 'Linking loan nominees needs loan.edit or loan.create'
            ELSE 'Linking nominees after submission needs loan.edit' END);
    END IF;
    IF cardinality(v_ids) > cfg.require_setting_int('loans.max_nominees_per_loan') THEN
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
    RETURN v_ids;
END
$$;

CREATE OR REPLACE FUNCTION loan.set_application_nominees(
    p_loan_id uuid, p_nominee_ids uuid[], p_expected_version integer)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_loan loan.loan%ROWTYPE;
    v_ids  uuid[];
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
    v_ids := loan.link_application_nominees(p_loan_id, p_nominee_ids);
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
    loan.set_application_nominees(uuid, uuid[], integer), loan.link_application_nominees(uuid, uuid[]), loan.record_nominee_override(uuid, text),
    loan.loan_for_approval_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cfg.rule_check_codes(), loan.nominee_status(uuid), loan.member_past_default(uuid, integer, uuid), loan.assert_nominee_changeable(loan.loan),
    loan.set_application_nominees(uuid, uuid[], integer), loan.link_application_nominees(uuid, uuid[]), loan.record_nominee_override(uuid, text),
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

-- Template and organisation seeding: db/49c_seed_workflow_engine.sql (runs after
-- the platform templates exist, so a fresh build gets it too).
