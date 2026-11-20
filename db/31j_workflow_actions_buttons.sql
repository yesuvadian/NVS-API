-- =============================================================================
-- CFMS / NVS  -  31j  Workflow action interface, action sequences, buttons
-- -----------------------------------------------------------------------------
-- Run as nvs after 31i. Safe to re-run.
--
-- * Action registry synchronised from code: every WorkflowAction subclass
--   (app/workflow/actions) is written to platform.action_definition at
--   start-up by platform.sync_action_definitions: names (en/ta), entities,
--   events, params JSON Schema, deferrable. Core actions shipped with the
--   platform are approved; other new ones wait for Super Admin approval;
--   actions no longer in code are RETIRED (never deleted).
-- * Transition actions are an ordered list [{seq, code, params, onError}]
--   (the older {"action": code} form is still read). onError: ROLLBACK
--   (default), CONTINUE, DEFER (only for deferrable actions). Params are
--   validated against the action's params schema.
-- * Buttons: a transition with a "label" is a button: code, label {en, ta},
--   style, confirm, actor {privilege, roles, approvers}, fromStatuses,
--   input (JSON Schema object whose properties carry x-field, one of the v1
--   field types). Validated on publish.
-- * Outbox: deferred actions are wf.action_execution rows (PENDING) with
--   their params.
-- =============================================================================

ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS name_translations jsonb;
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS supported_entities text[] NOT NULL DEFAULT '{}';
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS supported_events text[] NOT NULL DEFAULT '{}';
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS is_deferrable boolean NOT NULL DEFAULT false;
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS composite_step boolean NOT NULL DEFAULT false;
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS selectable boolean NOT NULL DEFAULT true;
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS implementation text;
ALTER TABLE platform.action_definition ADD COLUMN IF NOT EXISTS synced_at timestamptz;

ALTER TABLE wf.action_execution ADD COLUMN IF NOT EXISTS params jsonb;
ALTER TABLE wf.action_execution ADD COLUMN IF NOT EXISTS on_error text;
ALTER TABLE wf.action_execution ADD COLUMN IF NOT EXISTS entity_type text;
ALTER TABLE wf.action_execution ADD COLUMN IF NOT EXISTS entity_id uuid;

-- Registry sync (called by the API at start-up with the discovered actions).
CREATE OR REPLACE FUNCTION platform.sync_action_definitions(p_actions jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS
$$
DECLARE
    a        jsonb;
    v_retired integer := 0;
    v_codes  text[] := ARRAY(SELECT x ->> 'code' FROM jsonb_array_elements(p_actions) x);
BEGIN
    IF jsonb_typeof(p_actions) <> 'array' OR jsonb_array_length(p_actions) = 0 THEN
        RAISE EXCEPTION 'sync_action_definitions needs the discovered actions';
    END IF;
    FOR a IN SELECT * FROM jsonb_array_elements(p_actions) LOOP
        INSERT INTO platform.action_definition AS d (
            action_code, name, name_translations, description, category, action_kind, default_execution_type,
            config_schema, implementation_version, status, approved_at, approval_reason, supported_entities,
            supported_events, is_deferrable, composite_step, selectable, implementation, synced_at)
        VALUES (a ->> 'code', a -> 'name' ->> 'en', a -> 'name', a ->> 'description', a ->> 'category',
                a ->> 'kind', CASE WHEN (a ->> 'deferrable')::boolean THEN 'ASYNCHRONOUS' ELSE 'SYNCHRONOUS' END,
                a -> 'params_schema', a ->> 'version',
                CASE WHEN (a ->> 'core')::boolean THEN 'APPROVED' ELSE 'PENDING_APPROVAL' END,
                CASE WHEN (a ->> 'core')::boolean THEN now() END,
                CASE WHEN (a ->> 'core')::boolean THEN 'Shipped with the platform' END,
                ARRAY(SELECT jsonb_array_elements_text(a -> 'supported_entities')),
                ARRAY(SELECT jsonb_array_elements_text(a -> 'supported_events')),
                (a ->> 'deferrable')::boolean, (a ->> 'composite_step')::boolean,
                coalesce((a ->> 'selectable')::boolean, true), a ->> 'implementation', now())
        ON CONFLICT (action_code) DO UPDATE SET
            name = EXCLUDED.name, name_translations = EXCLUDED.name_translations,
            description = EXCLUDED.description, category = EXCLUDED.category, action_kind = EXCLUDED.action_kind,
            config_schema = EXCLUDED.config_schema, implementation_version = EXCLUDED.implementation_version,
            supported_entities = EXCLUDED.supported_entities, supported_events = EXCLUDED.supported_events,
            is_deferrable = EXCLUDED.is_deferrable, composite_step = EXCLUDED.composite_step,
            selectable = EXCLUDED.selectable, implementation = EXCLUDED.implementation, synced_at = now(),
            -- back in code after retirement: core actions are approved again,
            -- others wait for approval; approved/pending/rejected keep theirs
            status = CASE WHEN d.status = 'RETIRED'
                          THEN CASE WHEN (a ->> 'core')::boolean THEN 'APPROVED' ELSE 'PENDING_APPROVAL' END
                          ELSE d.status END,
            updated_at = now();
    END LOOP;
    UPDATE platform.action_definition
       SET status = 'RETIRED', updated_at = now()
     WHERE status <> 'RETIRED' AND NOT action_code = ANY (v_codes);
    GET DIAGNOSTICS v_retired = ROW_COUNT;
    RETURN jsonb_build_object('actions', jsonb_array_length(p_actions), 'retired', v_retired);
END
$$;
REVOKE ALL ON FUNCTION platform.sync_action_definitions(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.sync_action_definitions(jsonb) TO nvs_app;

-- Dropdown items: approved, selectable actions for an entity and event.
CREATE OR REPLACE FUNCTION platform.list_workflow_actions(p_entity text DEFAULT NULL, p_event text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS
$$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'code', d.action_code, 'name', coalesce(d.name_translations, jsonb_build_object('en', d.name)),
               'description', d.description, 'category', d.category, 'kind', d.action_kind,
               'entities', to_jsonb(d.supported_entities), 'events', to_jsonb(d.supported_events),
               'params_schema', coalesce(d.config_schema, '{"type":"object"}'::jsonb),
               'deferrable', d.is_deferrable, 'composite_step', d.composite_step, 'status', d.status)
             ORDER BY d.category, d.action_code), '[]'::jsonb)
      FROM platform.action_definition d
     WHERE d.status = 'APPROVED' AND d.selectable
       AND (p_entity IS NULL OR upper(p_entity) = ANY (d.supported_entities))
       AND (p_event IS NULL OR p_event = ANY (d.supported_events))
$$;
REVOKE ALL ON FUNCTION platform.list_workflow_actions(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.list_workflow_actions(text, text) TO nvs_app;

-- Params against a (subset of) JSON Schema: object, required, properties
-- with type / enum / minLength / maxLength / minimum / maximum, and
-- additionalProperties false.
CREATE OR REPLACE FUNCTION cfg.validate_params(p_schema jsonb, p_params jsonb, p_where text)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_errors text[] := '{}';
    k        text;
    v        jsonb;
    p        jsonb;
    t        text;
BEGIN
    IF p_schema IS NULL THEN
        RETURN v_errors;
    END IF;
    IF jsonb_typeof(coalesce(p_params, '{}'::jsonb)) <> 'object' THEN
        RETURN ARRAY[format('%s: params must be an object', p_where)];
    END IF;
    FOR k IN SELECT jsonb_array_elements_text(coalesce(p_schema -> 'required', '[]'::jsonb)) LOOP
        IF NOT coalesce(p_params, '{}'::jsonb) ? k THEN
            v_errors := v_errors || format('%s: param %s is required', p_where, k);
        END IF;
    END LOOP;
    FOR k, v IN SELECT * FROM jsonb_each(coalesce(p_params, '{}'::jsonb)) LOOP
        p := p_schema -> 'properties' -> k;
        IF p IS NULL THEN
            IF (p_schema ->> 'additionalProperties') = 'false' THEN
                v_errors := v_errors || format('%s: param %s is not allowed', p_where, k);
            END IF;
            CONTINUE;
        END IF;
        t := p ->> 'type';
        IF t IS NOT NULL AND NOT (
               (t = 'string' AND jsonb_typeof(v) = 'string')
            OR (t IN ('number', 'integer') AND jsonb_typeof(v) = 'number'
                AND (t = 'number' OR (v #>> '{}') ~ '^-?[0-9]+$'))
            OR (t = 'boolean' AND jsonb_typeof(v) = 'boolean')
            OR (t = 'array' AND jsonb_typeof(v) = 'array')
            OR (t = 'object' AND jsonb_typeof(v) = 'object')) THEN
            v_errors := v_errors || format('%s: param %s must be %s', p_where, k, t);
            CONTINUE;
        END IF;
        IF p ? 'enum' AND NOT (p -> 'enum') @> jsonb_build_array(v) THEN
            v_errors := v_errors || format('%s: param %s must be one of %s', p_where, k, p ->> 'enum');
        END IF;
        IF jsonb_typeof(v) = 'string' AND p ? 'minLength' AND length(v #>> '{}') < (p ->> 'minLength')::int THEN
            v_errors := v_errors || format('%s: param %s is too short', p_where, k);
        END IF;
        IF jsonb_typeof(v) = 'number' AND p ? 'minimum' AND (v #>> '{}')::numeric < (p ->> 'minimum')::numeric THEN
            v_errors := v_errors || format('%s: param %s is below %s', p_where, k, p ->> 'minimum');
        END IF;
    END LOOP;
    RETURN v_errors;
END
$$;

-- Transition actions: [{seq, code, params, onError}] in seq order.
CREATE OR REPLACE FUNCTION cfg.validate_workflow_actions(p_definition jsonb, p_tenant_id uuid)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_errors text[] := '{}';
    r        record;
    d        platform.action_definition%ROWTYPE;
    v_code   text;
    v_event  text;
    a        jsonb;
BEGIN
    FOR r IN SELECT t ->> 'on' AS ev, coalesce(t ->> 'code', t ->> 'on') AS tc, t -> 'actions' AS actions
               FROM jsonb_array_elements(p_definition -> 'transitions') t WHERE t ? 'actions' LOOP
        IF jsonb_typeof(r.actions) <> 'array' THEN
            v_errors := v_errors || format('transition %s: actions must be an array', r.tc);
            CONTINUE;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.actions) q WHERE q ? 'seq'
                    GROUP BY q ->> 'seq' HAVING count(*) > 1) THEN
            v_errors := v_errors || format('transition %s: action seq numbers must be unique', r.tc);
        END IF;
        IF jsonb_array_length(r.actions) > 1 AND EXISTS (
               SELECT 1 FROM jsonb_array_elements(r.actions) q WHERE NOT q ? 'seq') THEN
            v_errors := v_errors || format('transition %s: every action in a sequence needs an explicit seq', r.tc);
        END IF;
        FOR a IN SELECT x FROM jsonb_array_elements(r.actions) x LOOP
            v_code := coalesce(a ->> 'code', a ->> 'action');
            IF jsonb_typeof(a) <> 'object' OR v_code IS NULL THEN
                v_errors := v_errors || format('transition %s: each action needs a "code"', r.tc);
                CONTINUE;
            END IF;
            IF a ? 'seq' AND (jsonb_typeof(a -> 'seq') <> 'number'
                OR (a ->> 'seq')::numeric < 1 OR trunc((a ->> 'seq')::numeric) <> (a ->> 'seq')::numeric) THEN
                v_errors := v_errors || format('transition %s: seq of %s must be a positive integer', r.tc, v_code);
            END IF;
            SELECT * INTO d FROM platform.action_definition WHERE action_code = v_code;
            IF NOT FOUND OR d.status <> 'APPROVED' THEN
                v_errors := v_errors || format('transition %s: action %s is not a registered, approved action',
                                               r.tc, v_code);
                CONTINUE;
            END IF;
            IF NOT d.selectable THEN
                v_errors := v_errors || format('transition %s: %s is an engine step, not an action', r.tc, v_code);
            END IF;
            -- an organisation can switch an action off (cfg.tenant_action);
            -- without a row the approved action is available
            IF p_tenant_id IS NOT NULL AND EXISTS (
                   SELECT 1 FROM cfg.tenant_action ta
                    WHERE ta.tenant_id = p_tenant_id AND ta.action_code = v_code AND NOT ta.is_enabled) THEN
                v_errors := v_errors || format('transition %s: action %s is not enabled for this organisation',
                                               r.tc, v_code);
            END IF;
            IF coalesce(a ->> 'onError', 'ROLLBACK') NOT IN ('ROLLBACK', 'CONTINUE', 'DEFER') THEN
                v_errors := v_errors || format('transition %s: onError of %s must be ROLLBACK, CONTINUE or DEFER',
                                               r.tc, v_code);
            ELSIF a ->> 'onError' = 'DEFER' AND NOT d.is_deferrable THEN
                v_errors := v_errors || format('transition %s: action %s cannot be deferred', r.tc, v_code);
            END IF;
            v_errors := v_errors || cfg.validate_params(d.config_schema, coalesce(a -> 'params', '{}'::jsonb),
                                                        format('transition %s: action %s', r.tc, v_code));
        END LOOP;
    END LOOP;
    -- Stage hooks run when entering or leaving that named stage. They use the
    -- same ordered action registry and parameter validation as transitions.
    FOR r IN SELECT s ->> 'code' AS stage_code, s -> 'actions' AS actions
               FROM jsonb_array_elements(p_definition -> 'stages') s WHERE s ? 'actions' LOOP
        IF jsonb_typeof(r.actions) <> 'array' THEN
            v_errors := v_errors || format('stage %s: actions must be an array',r.stage_code);
            CONTINUE;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.actions) q
                    GROUP BY q ->> 'seq' HAVING count(*) > 1) THEN
            v_errors := v_errors || format('stage %s: action seq numbers must be unique',r.stage_code);
        END IF;
        -- Existing templates contain legacy composite stage actions with
        -- {action,type,config}; those are handled inside business SQL
        -- functions. New IStageAction hooks use `code`.
        FOR a IN SELECT x FROM jsonb_array_elements(r.actions) x WHERE x ? 'code' LOOP
            v_code:=coalesce(a ->> 'code',a ->> 'action');
            v_event:=coalesce(a ->> 'event',a ->> 'on','onEnter');
            IF jsonb_typeof(a)<>'object' OR v_code IS NULL THEN
                v_errors:=v_errors || format('stage %s: each action needs a code',r.stage_code);
                CONTINUE;
            END IF;
            IF v_event NOT IN ('onEnter','onExit') THEN
                v_errors:=v_errors || format('stage %s: action event must be onEnter or onExit',r.stage_code);
            END IF;
            IF jsonb_typeof(a -> 'seq')<>'number' OR (a ->> 'seq')::numeric<1
               OR trunc((a ->> 'seq')::numeric)<>(a ->> 'seq')::numeric THEN
                v_errors:=v_errors || format('stage %s: action %s seq must be a positive integer',r.stage_code,v_code);
            END IF;
            SELECT * INTO d FROM platform.action_definition WHERE action_code=v_code;
            IF NOT FOUND OR d.status<>'APPROVED' THEN
                v_errors:=v_errors || format('stage %s: action %s is not registered and approved',r.stage_code,v_code);
                CONTINUE;
            END IF;
            IF NOT d.selectable THEN
                v_errors:=v_errors || format('stage %s: %s is an engine step, not an action',r.stage_code,v_code);
            END IF;
            IF NOT v_event=ANY(d.supported_events) THEN
                v_errors:=v_errors || format('stage %s: action %s does not support %s',r.stage_code,v_code,v_event);
            END IF;
            IF p_tenant_id IS NOT NULL AND EXISTS (SELECT 1 FROM cfg.tenant_action ta
                    WHERE ta.tenant_id=p_tenant_id AND ta.action_code=v_code AND NOT ta.is_enabled) THEN
                v_errors:=v_errors || format('stage %s: action %s is not enabled for this organisation',r.stage_code,v_code);
            END IF;
            IF coalesce(a ->> 'onError','ROLLBACK') NOT IN ('ROLLBACK','CONTINUE','DEFER') THEN
                v_errors:=v_errors || format('stage %s: onError of %s must be ROLLBACK, CONTINUE or DEFER',r.stage_code,v_code);
            ELSIF a ->> 'onError'='DEFER' AND NOT d.is_deferrable THEN
                v_errors:=v_errors || format('stage %s: action %s cannot be deferred',r.stage_code,v_code);
            END IF;
            v_errors:=v_errors || cfg.validate_params(d.config_schema,coalesce(a -> 'params','{}'::jsonb),
                                                       format('stage %s: action %s',r.stage_code,v_code));
        END LOOP;
    END LOOP;
    RETURN v_errors;
END
$$;

-- Buttons: transitions with a label.
CREATE OR REPLACE FUNCTION cfg.validate_workflow_buttons(p_definition jsonb, p_tenant_id uuid)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_errors text[] := '{}';
    r        record;
    f        record;
    v_section jsonb;
    v_section_field text;
    v_seen_fields text[];
    v_role   text;
    v_status text;
BEGIN
    -- button codes unique per source stage (several transitions may share one
    -- code when their "when" conditions differ, e.g. SUBMIT to fee or approval)
    FOR r IN SELECT t ->> 'from' AS f, t ->> 'code' AS c, count(DISTINCT t -> 'label') AS n
               FROM jsonb_array_elements(p_definition -> 'transitions') t
              WHERE t ? 'code' GROUP BY 1, 2 HAVING count(DISTINCT t -> 'label') > 1 LOOP
        v_errors := v_errors || format('stage %s: transitions with code %s must share one label', r.f, r.c);
    END LOOP;
    FOR r IN SELECT t, t ->> 'from' AS f, coalesce(t ->> 'code', t ->> 'on') AS c
               FROM jsonb_array_elements(p_definition -> 'transitions') t WHERE t ? 'label' LOOP
        IF (r.t ? 'code') AND (r.t ->> 'code') !~ '^[A-Z][A-Z0-9_]*$' THEN
            v_errors := v_errors || format('button %s: code must be UPPER_SNAKE_CASE', r.c);
        END IF;
        IF jsonb_typeof(r.t -> 'label') <> 'object' OR coalesce(r.t -> 'label' ->> 'en', '') = ''
           OR coalesce(r.t -> 'label' ->> 'ta', '') = '' THEN
            v_errors := v_errors || format('button %s: label needs English and Tamil text', r.c);
        END IF;
        IF r.t ? 'style' AND (r.t ->> 'style') NOT IN ('primary', 'secondary', 'danger') THEN
            v_errors := v_errors || format('button %s: style must be primary, secondary or danger', r.c);
        END IF;
        IF r.t ? 'confirm' AND (jsonb_typeof(r.t -> 'confirm') <> 'object'
            OR coalesce(r.t -> 'confirm' ->> 'en', '') = '' OR coalesce(r.t -> 'confirm' ->> 'ta', '') = '') THEN
            v_errors := v_errors || format('button %s: confirm needs English and Tamil text', r.c);
        END IF;
        IF jsonb_typeof(coalesce(r.t -> 'actor', '{}'::jsonb)) <> 'object'
           OR NOT (coalesce(r.t -> 'actor' ->> 'privilege', '') <> ''
                   OR jsonb_typeof(r.t -> 'actor' -> 'roles') = 'array'
                   OR r.t -> 'actor' ->> 'approvers' = 'true') THEN
            v_errors := v_errors || format('button %s: actor needs a privilege, role list or approvers flag', r.c);
        END IF;
        IF r.t -> 'actor' ? 'privilege' AND NOT EXISTS (
               SELECT 1 FROM platform.privilege p WHERE p.privilege_code = r.t -> 'actor' ->> 'privilege' AND p.is_active) THEN
            v_errors := v_errors || format('button %s: actor privilege %s is not a known privilege',
                                           r.c, r.t -> 'actor' ->> 'privilege');
        END IF;
        IF r.t -> 'actor' ? 'roles' AND jsonb_typeof(r.t -> 'actor' -> 'roles') <> 'array' THEN
            v_errors := v_errors || format('button %s: actor roles must be an array', r.c);
        END IF;
        FOR v_role IN SELECT jsonb_array_elements_text(CASE
                    WHEN jsonb_typeof(r.t -> 'actor' -> 'roles') = 'array' THEN r.t -> 'actor' -> 'roles'
                    ELSE '[]'::jsonb END) LOOP
            IF p_tenant_id IS NOT NULL AND NOT EXISTS (
                   SELECT 1 FROM iam.role ro WHERE ro.tenant_id = p_tenant_id AND ro.role_code = v_role AND ro.status = 'ACTIVE') THEN
                v_errors := v_errors || format('button %s: actor role %s is not an active role', r.c, v_role);
            END IF;
        END LOOP;
        FOR v_status IN SELECT jsonb_array_elements_text(coalesce(r.t -> 'fromStatuses', '[]'::jsonb)) LOOP
            IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_definition -> 'stages') s,
                                         jsonb_array_elements(coalesce(s -> 'statuses' -> 'stageStatuses', '[]'::jsonb)) x
                            WHERE s ->> 'code' = r.f AND x ->> 'code' = v_status) THEN
                v_errors := v_errors || format('button %s: fromStatuses %s is not a status of stage %s', r.c, v_status, r.f);
            END IF;
        END LOOP;
        IF r.t ? 'input' THEN
            IF jsonb_typeof(r.t -> 'input') <> 'object' OR r.t -> 'input' ->> 'type' <> 'object'
               OR jsonb_typeof(coalesce(r.t -> 'input' -> 'properties', '{}'::jsonb)) <> 'object' THEN
                v_errors := v_errors || format('button %s: input must be a JSON Schema object with properties', r.c);
                CONTINUE;
            END IF;
            FOR f IN SELECT key, value FROM jsonb_each(coalesce(r.t -> 'input' -> 'properties', '{}'::jsonb)) LOOP
                IF coalesce(f.value ->> 'x-field', '') NOT IN
                   ('text', 'multiline', 'number', 'amount', 'date', 'enum', 'boolean', 'member', 'nominee') THEN
                    v_errors := v_errors || format('button %s: field %s has an unsupported type %s',
                                                   r.c, f.key, coalesce(f.value ->> 'x-field', '(none)'));
                END IF;
                IF f.value ->> 'x-field' = 'enum' AND coalesce(jsonb_typeof(f.value -> 'enum') <> 'array', true) THEN
                    v_errors := v_errors || format('button %s: enum field %s needs an array of values', r.c, f.key);
                ELSIF f.value ->> 'x-field' = 'enum' AND jsonb_array_length(f.value -> 'enum') = 0 THEN
                    v_errors := v_errors || format('button %s: enum field %s needs its values', r.c, f.key);
                END IF;
                IF f.value ? 'title' THEN
                    IF jsonb_typeof(f.value -> 'title') <> 'object'
                       OR coalesce(f.value -> 'title' ->> 'en', '') = ''
                       OR coalesce(f.value -> 'title' ->> 'ta', '') = '' THEN
                        v_errors := v_errors || format('button %s: title for field %s needs English and Tamil translations', r.c, f.key);
                    ELSIF EXISTS (SELECT 1 FROM jsonb_each(f.value -> 'title') l
                                   WHERE l.key !~ '^[a-z]{2,3}(-[A-Z]{2})?$'
                                      OR jsonb_typeof(l.value) <> 'string' OR l.value #>> '{}' = '') THEN
                        v_errors := v_errors || format('button %s: title for field %s has an invalid locale translation', r.c, f.key);
                    END IF;
                END IF;
            END LOOP;
            FOR v_status IN SELECT jsonb_array_elements_text(coalesce(r.t -> 'input' -> 'required', '[]'::jsonb)) LOOP
                IF NOT (r.t -> 'input' -> 'properties') ? v_status THEN
                    v_errors := v_errors || format('button %s: required field %s is not defined', r.c, v_status);
                END IF;
            END LOOP;
            IF r.t -> 'input' ? 'x-sections' THEN
                IF jsonb_typeof(r.t -> 'input' -> 'x-sections') <> 'array' THEN
                    v_errors := v_errors || format('button %s: x-sections must be an array', r.c);
                ELSE
                    v_seen_fields := '{}';
                    IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.t -> 'input' -> 'x-sections') s
                                GROUP BY s ->> 'code' HAVING count(*) > 1) THEN
                        v_errors := v_errors || format('button %s: form section codes must be unique', r.c);
                    END IF;
                    FOR v_section IN SELECT value FROM jsonb_array_elements(r.t -> 'input' -> 'x-sections') LOOP
                        IF jsonb_typeof(v_section) <> 'object'
                           OR coalesce(v_section ->> 'code', '') !~ '^[A-Z][A-Z0-9_]*$'
                           OR jsonb_typeof(v_section -> 'title') <> 'object'
                           OR coalesce(v_section -> 'title' ->> 'en', '') = ''
                           OR coalesce(v_section -> 'title' ->> 'ta', '') = ''
                           OR jsonb_typeof(v_section -> 'fields') <> 'array'
                           OR jsonb_array_length(coalesce(v_section -> 'fields', '[]'::jsonb)) = 0 THEN
                            v_errors := v_errors || format('button %s: each form section needs code, bilingual title and fields', r.c);
                            CONTINUE;
                        END IF;
                        IF EXISTS (SELECT 1 FROM jsonb_each(v_section -> 'title') l
                                    WHERE l.key !~ '^[a-z]{2,3}(-[A-Z]{2})?$'
                                       OR jsonb_typeof(l.value) <> 'string' OR l.value #>> '{}' = '') THEN
                            v_errors := v_errors || format('button %s: section %s has an invalid locale translation',
                                                           r.c, v_section ->> 'code');
                        END IF;
                        FOR v_section_field IN SELECT jsonb_array_elements_text(v_section -> 'fields') LOOP
                            IF NOT (r.t -> 'input' -> 'properties') ? v_section_field THEN
                                v_errors := v_errors || format('button %s: section %s references undefined field %s',
                                                               r.c, v_section ->> 'code', v_section_field);
                            END IF;
                            IF v_section_field = ANY(v_seen_fields) THEN
                                v_errors := v_errors || format('button %s: field %s belongs to multiple form sections', r.c, v_section_field);
                            ELSE
                                v_seen_fields := array_append(v_seen_fields, v_section_field);
                            END IF;
                        END LOOP;
                    END LOOP;
                END IF;
            END IF;
        END IF;
    END LOOP;
    RETURN v_errors;
END
$$;

-- LOAN_APPLICATION buttons (v4): today's actions as buttons, actions as
-- ordered sequences, member notifications deferred.
CREATE OR REPLACE FUNCTION platform.loan_workflow_buttons(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{transitions}', (
        SELECT jsonb_agg((t - 'actions') || CASE t ->> 'on'
            WHEN 'SUBMIT' THEN '{"code":"SUBMIT","label":{"en":"Submit","ta":"சமர்ப்பி"},"style":"primary",
                "confirm":{"en":"Submit this application for approval?","ta":"இந்த விண்ணப்பத்தை ஒப்புதலுக்குச் சமர்ப்பிக்கவா?"},
                "actor":{"privilege":"loan.create"},
                "actions":[{"seq":1,"code":"CREATE_APPROVAL_REQUEST","onError":"ROLLBACK"}]}'::jsonb
            WHEN 'WITHDRAW' THEN '{"code":"WITHDRAW","label":{"en":"Withdraw","ta":"திரும்பப் பெறு"},"style":"danger",
                "confirm":{"en":"Withdraw this application?","ta":"இந்த விண்ணப்பத்தைத் திரும்பப் பெறவா?"},
                "actor":{"privilege":"loan.edit"},
                "input":{"type":"object","required":["reason"],"properties":{"reason":{"type":"string","x-field":"multiline",
                    "title":{"en":"Reason","ta":"காரணம்"},"minLength":3,"maxLength":500}},
                    "x-sections":[{"code":"WITHDRAWAL_DETAILS","title":{"en":"Withdrawal details","ta":"திரும்பப் பெறும் விவரங்கள்"},"fields":["reason"]}]},
                "actions":[{"seq":1,"code":"WITHDRAW_APPLICATION","onError":"ROLLBACK"}]}'::jsonb
            WHEN 'APPROVE' THEN '{"code":"APPROVE","label":{"en":"Approve","ta":"ஒப்புதல் அளி"},"style":"primary",
                "actor":{"privilege":"loan.approve","approvers":true},
                "input":{"type":"object","properties":{
                    "approved_amount":{"type":"number","x-field":"amount","title":{"en":"Approved amount","ta":"ஒப்புதல் தொகை"},
                        "exclusiveMinimum":0,"x-maxFrom":"requested_amount"},
                    "tenure_months":{"type":"integer","x-field":"number","title":{"en":"Tenure (months)","ta":"காலம் (மாதங்கள்)"},
                        "minimum":1,"x-maxFrom":"requested_tenure_months"},
                    "nominee_override_reason":{"type":"string","x-field":"multiline",
                        "title":{"en":"Reason to approve without a nominee","ta":"நியமனதாரர் இல்லாமல் ஒப்புதல் அளிப்பதற்கான காரணம்"},
                        "minLength":3,"maxLength":500,"x-showWhen":"needs_override"}},
                    "x-sections":[{"code":"DECISION_DETAILS","title":{"en":"Decision details","ta":"முடிவு விவரங்கள்"},"fields":["approved_amount","tenure_months","nominee_override_reason"]}]},
                "actions":[{"seq":1,"code":"RECORD_APPROVAL_DECISION","onError":"ROLLBACK"}]}'::jsonb
            WHEN 'REJECT' THEN '{"code":"REJECT","label":{"en":"Reject","ta":"நிராகரி"},"style":"danger",
                "confirm":{"en":"Reject this application?","ta":"இந்த விண்ணப்பத்தை நிராகரிக்கவா?"},
                "actor":{"privilege":"loan.approve","approvers":true},
                "input":{"type":"object","required":["reason"],"properties":{"reason":{"type":"string","x-field":"multiline",
                    "title":{"en":"Reason","ta":"காரணம்"},"minLength":3,"maxLength":500}},
                    "x-sections":[{"code":"REJECTION_DETAILS","title":{"en":"Rejection details","ta":"நிராகரிப்பு விவரங்கள்"},"fields":["reason"]}]},
                "actions":[{"seq":1,"code":"RECORD_APPROVAL_DECISION","onError":"ROLLBACK"}]}'::jsonb
            WHEN 'RETURN' THEN '{"code":"RETURN","label":{"en":"Return for changes","ta":"மாற்றங்களுக்குத் திருப்பி அனுப்பு"},
                "style":"secondary","actor":{"privilege":"loan.approve","approvers":true},
                "input":{"type":"object","required":["reason"],"properties":{"reason":{"type":"string","x-field":"multiline",
                    "title":{"en":"What should change","ta":"என்ன மாற்ற வேண்டும்"},"minLength":3,"maxLength":500}},
                    "x-sections":[{"code":"RETURN_DETAILS","title":{"en":"Requested changes","ta":"கோரப்பட்ட மாற்றங்கள்"},"fields":["reason"]}]},
                "actions":[{"seq":1,"code":"RECORD_APPROVAL_DECISION","onError":"ROLLBACK"}]}'::jsonb
            WHEN 'DISBURSE' THEN '{"code":"DISBURSE","label":{"en":"Release disbursement","ta":"கடன் தொகையை வழங்கு"},
                "style":"primary","confirm":{"en":"Release this disbursement?","ta":"இந்தக் கடன் தொகையை வழங்கவா?"},
                "actor":{"privilege":"loan.edit"},
                "input":{"type":"object","required":["disbursement_id","ack_type"],"properties":{
                    "disbursement_id":{"type":"string","format":"uuid","x-field":"text",
                        "title":{"en":"Disbursement ID","ta":"வழங்கல் எண்"}},
                    "ack_type":{"type":"string","x-field":"enum","enum":["SIGNATURE","THUMB_IMPRESSION"],
                        "title":{"en":"Payee acknowledgement","ta":"பெறுநர் ஒப்புதல்"}}},
                    "x-sections":[{"code":"DISBURSEMENT_ACKNOWLEDGEMENT","title":{"en":"Disbursement acknowledgement","ta":"கடன் வழங்கல் ஒப்புதல்"},"fields":["disbursement_id","ack_type"]}]},
                "actions":[{"seq":1,"code":"RELEASE_DISBURSEMENT","onError":"ROLLBACK"}]}'::jsonb
            ELSE CASE WHEN t ? 'actions' THEN jsonb_build_object('actions', t -> 'actions') ELSE '{}'::jsonb END
            END ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'transitions') WITH ORDINALITY x(t, ord)))
$$;

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-WF-1010','WORKFLOW_INPUT_INVALID','WF','VALIDATION','ERROR',400,false,false,'Some of the details are missing or not valid.','Correct the highlighted fields and try again.'),
 ('CFMS-WF-5010','WORKFLOW_ACTION_NOT_AVAILABLE','WF','CONFLICT','WARNING',409,false,false,'This action is not available for the record now.','Refresh the record to see the actions available.'),
 ('CFMS-WF-4010','WORKFLOW_ENTITY_NOT_SUPPORTED','WF','NOT_FOUND','ERROR',404,false,false,'Workflow actions are not available for this kind of record.','Use the record''s own screen.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('WORKFLOW_INPUT_INVALID','சில விவரங்கள் இல்லை அல்லது சரியாக இல்லை.'),
 ('WORKFLOW_ACTION_NOT_AVAILABLE','இந்தச் செயல் இப்போது இந்தப் பதிவுக்குக் கிடைக்கவில்லை.'),
 ('WORKFLOW_ENTITY_NOT_SUPPORTED','இந்த வகைப் பதிவுக்குப் பணிப்பாய்வுச் செயல்கள் இல்லை.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;
