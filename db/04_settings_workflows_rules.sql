-- =============================================================================
-- CFMS / NVS  -  04  Tenant settings, workflow and rule definitions (JSON)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- * Settings are effective-dated rows copied from the platform default
--   template at onboarding (Section 4.10).
-- * Workflows and rule sets are versioned jsonb documents per tenant
--   (Sections 24.2, 29.1, 35.4). Published versions are immutable; a change is
--   a new version with a mandatory reason and an effective date. Every action
--   on a version is written to cfg.config_change_log.
-- * Structural validation is done in the database on publish
--   (cfg.validate_workflow / cfg.validate_rule_set). Full JSON Schema
--   validation against platform.json_schema is done by the API (or the
--   pg_jsonschema extension if available) before saving and publishing.
-- =============================================================================

-- Tenant settings -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cfg.tenant_setting (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    setting_key       text NOT NULL REFERENCES platform.setting_definition (setting_key),
    value             jsonb NOT NULL,
    effective_from    date NOT NULL DEFAULT current_date,
    status            text NOT NULL DEFAULT 'ACTIVE'
                      CHECK (status IN ('PENDING_APPROVAL','ACTIVE','REJECTED','CANCELLED')),
    source            text NOT NULL DEFAULT 'ORG_ADMIN'
                      CHECK (source IN ('TEMPLATE','ORG_ADMIN','ACCOUNTANT','SUPER_ADMIN','RESET','MIGRATION')),
    template_version  integer,
    is_locked         boolean NOT NULL DEFAULT false,   -- locked by the Super Admin
    reason            text,
    approved_by       uuid,                              -- LDR approval where required
    approved_at       timestamptz,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS tenant_setting_active_uq
    ON cfg.tenant_setting (tenant_id, setting_key, effective_from) WHERE status = 'ACTIVE';

-- Value of a setting in force on a date (default: session working date).
CREATE OR REPLACE FUNCTION cfg.get_setting(p_key text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT s.value
      FROM cfg.tenant_setting s
     WHERE s.tenant_id = coalesce(p_tenant_id, app.tenant_id())
       AND s.setting_key = p_key
       AND s.status = 'ACTIVE'
       AND s.effective_from <= coalesce(p_on, app.working_date())
     ORDER BY s.effective_from DESC, s.created_at DESC
     LIMIT 1
$$;

-- =============================================================================
-- Actions enabled per tenant (Section 25.4)
-- =============================================================================
CREATE TABLE IF NOT EXISTS cfg.tenant_action (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    action_code   text NOT NULL REFERENCES platform.action_definition (action_code),
    is_enabled    boolean NOT NULL DEFAULT true,
    reason        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, action_code)
);

-- Named, reusable action configurations (e.g. journal templates)
CREATE TABLE IF NOT EXISTS cfg.action_configuration (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    action_code   text NOT NULL REFERENCES platform.action_definition (action_code),
    config_code   text NOT NULL,
    name          text NOT NULL,
    config        jsonb NOT NULL,
    version_no    integer NOT NULL DEFAULT 1,
    status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    effective_from date NOT NULL DEFAULT current_date,
    reason        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, config_code, version_no)
);

-- =============================================================================
-- Workflow definitions and versions
-- =============================================================================
CREATE TABLE IF NOT EXISTS cfg.workflow_definition (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code               text NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    name               text NOT NULL,
    module_code        text NOT NULL REFERENCES platform.module (module_code),
    entity_type        text,                       -- e.g. loan.loan
    description        text,
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    is_locked          boolean NOT NULL DEFAULT true,  -- never editable by the tenant
    template_id        uuid REFERENCES platform.config_template (id),
    template_version   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code)
);

CREATE TABLE IF NOT EXISTS cfg.workflow_version (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_definition_id uuid NOT NULL,
    version_no         integer NOT NULL CHECK (version_no > 0),
    status             text NOT NULL DEFAULT 'DRAFT'
                       CHECK (status IN ('DRAFT','PUBLISHED','RETIRED','DISCARDED')),
    definition         jsonb NOT NULL,
    schema_version     text NOT NULL DEFAULT '1.0',
    json_schema_id     uuid REFERENCES platform.json_schema (id),
    checksum           text GENERATED ALWAYS AS (md5(definition::text)) STORED,
    effective_from     date,
    effective_to       date,
    reason             text NOT NULL CHECK (length(trim(reason)) > 0),
    source             text NOT NULL DEFAULT 'DESIGNER'
                       CHECK (source IN ('DESIGNER','IMPORT','TEMPLATE','TEMPLATE_UPGRADE','RESTORE','MIGRATION')),
    source_template_version_id uuid REFERENCES platform.config_template_version (id),
    restored_from_version_id   uuid,
    validation_status  text NOT NULL DEFAULT 'NOT_VALIDATED'
                       CHECK (validation_status IN ('NOT_VALIDATED','VALID','INVALID')),
    validation_result  jsonb,
    test_run_result    jsonb,
    published_by       uuid REFERENCES platform.platform_user (id),
    published_at       timestamptz,
    retired_by         uuid REFERENCES platform.platform_user (id),
    retired_at         timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, workflow_definition_id, version_no),
    FOREIGN KEY (tenant_id, workflow_definition_id) REFERENCES cfg.workflow_definition (tenant_id, id),
    FOREIGN KEY (tenant_id, restored_from_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    CONSTRAINT workflow_version_shape CHECK (
        jsonb_typeof(definition) = 'object'
        AND definition ? 'startStage'
        AND jsonb_typeof(definition -> 'stages') = 'array'
        AND jsonb_typeof(definition -> 'transitions') = 'array'),
    CONSTRAINT workflow_version_publish_fields CHECK (
        status NOT IN ('PUBLISHED','RETIRED') OR (effective_from IS NOT NULL AND published_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS workflow_version_published_uq
    ON cfg.workflow_version (tenant_id, workflow_definition_id, effective_from) WHERE status = 'PUBLISHED';

-- Normalised projection of a published version (written on publish; read by the engine)
CREATE TABLE IF NOT EXISTS cfg.workflow_stage (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_version_id uuid NOT NULL,
    stage_code      text NOT NULL,
    stage_name      text,
    role_code       text,                 -- dynamic role, never a named person
    is_start        boolean NOT NULL DEFAULT false,
    is_end          boolean NOT NULL DEFAULT false,
    approval_config jsonb,                -- {"methods":["online","offline"]}
    sort_order      integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, workflow_version_id, stage_code),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS cfg.workflow_transition (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_version_id uuid NOT NULL,
    from_stage_code text NOT NULL,
    to_stage_code   text NOT NULL,
    trigger_event   text NOT NULL,        -- SUBMIT, APPROVE, REJECT, RETURN, WITHDRAW, CANCEL ...
    priority        integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS cfg.workflow_condition (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_transition_id uuid NOT NULL,
    condition       jsonb NOT NULL,        -- same operator set as rules
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_transition_id) REFERENCES cfg.workflow_transition (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS cfg.workflow_stage_action (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_stage_id uuid NOT NULL,
    seq             integer NOT NULL,
    action_code     text NOT NULL REFERENCES platform.action_definition (action_code),
    execution_type  text NOT NULL DEFAULT 'SYNCHRONOUS'
                    CHECK (execution_type IN ('SYNCHRONOUS','ASYNCHRONOUS','CONDITIONAL','PARALLEL','MANUAL','SCHEDULED')),
    is_validation   boolean NOT NULL DEFAULT false,
    is_mandatory    boolean NOT NULL DEFAULT true,
    is_enabled      boolean NOT NULL DEFAULT true,
    retry_count     integer NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    config          jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, workflow_stage_id, seq),
    FOREIGN KEY (tenant_id, workflow_stage_id) REFERENCES cfg.workflow_stage (tenant_id, id)
);

-- =============================================================================
-- Rule sets and versions (Section 29)
-- =============================================================================
CREATE TABLE IF NOT EXISTS cfg.rule_set (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code            text NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    name            text NOT NULL,
    module_code     text NOT NULL REFERENCES platform.module (module_code),
    scope_type      text,                  -- LOAN_TYPE, DEPOSIT_PRODUCT, HALL, GENERAL ...
    description     text,
    status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    is_locked       boolean NOT NULL DEFAULT true,
    template_id     uuid REFERENCES platform.config_template (id),
    template_version integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code)
);

CREATE TABLE IF NOT EXISTS cfg.rule_set_version (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    rule_set_id        uuid NOT NULL,
    version_no         integer NOT NULL CHECK (version_no > 0),
    status             text NOT NULL DEFAULT 'DRAFT'
                       CHECK (status IN ('DRAFT','PUBLISHED','RETIRED','DISCARDED')),
    definition         jsonb NOT NULL,
    schema_version     text NOT NULL DEFAULT '1.0',
    json_schema_id     uuid REFERENCES platform.json_schema (id),
    checksum           text GENERATED ALWAYS AS (md5(definition::text)) STORED,
    effective_from     date,
    effective_to       date,
    reason             text NOT NULL CHECK (length(trim(reason)) > 0),
    source             text NOT NULL DEFAULT 'DESIGNER'
                       CHECK (source IN ('DESIGNER','IMPORT','TEMPLATE','TEMPLATE_UPGRADE','RESTORE','MIGRATION')),
    source_template_version_id uuid REFERENCES platform.config_template_version (id),
    restored_from_version_id   uuid,
    validation_status  text NOT NULL DEFAULT 'NOT_VALIDATED'
                       CHECK (validation_status IN ('NOT_VALIDATED','VALID','INVALID')),
    validation_result  jsonb,
    test_run_result    jsonb,
    published_by       uuid REFERENCES platform.platform_user (id),
    published_at       timestamptz,
    retired_by         uuid REFERENCES platform.platform_user (id),
    retired_at         timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, rule_set_id, version_no),
    FOREIGN KEY (tenant_id, rule_set_id) REFERENCES cfg.rule_set (tenant_id, id),
    FOREIGN KEY (tenant_id, restored_from_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CONSTRAINT rule_set_version_shape CHECK (
        jsonb_typeof(definition) = 'object' AND jsonb_typeof(definition -> 'rules') = 'array'),
    CONSTRAINT rule_set_version_publish_fields CHECK (
        status NOT IN ('PUBLISHED','RETIRED') OR (effective_from IS NOT NULL AND published_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS rule_set_version_published_uq
    ON cfg.rule_set_version (tenant_id, rule_set_id, effective_from) WHERE status = 'PUBLISHED';

-- Every action on workflow / rule versions and other governed configuration
CREATE TABLE IF NOT EXISTS cfg.config_change_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    object_type     text NOT NULL CHECK (object_type IN ('WORKFLOW','RULESET','SETTING','MODULE','ACTION','PRIVILEGE_CEILING','COMPLIANCE')),
    object_id       uuid,
    version_id      uuid,
    version_no      integer,
    action          text NOT NULL CHECK (action IN ('CREATE_DRAFT','EDIT','VALIDATE','TEST_RUN','PUBLISH','RETIRE',
                                                    'DISCARD','IMPORT','EXPORT','RESTORE','ENABLE','DISABLE','LOCK','UNLOCK','CHANGE')),
    result          jsonb,
    reason          text,
    platform_user_id uuid,
    user_id         uuid,
    logged_at       timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS config_change_log_obj_idx ON cfg.config_change_log (tenant_id, object_type, object_id, logged_at DESC);

-- =============================================================================
-- Validation of workflow / rule documents
-- =============================================================================
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

CREATE OR REPLACE FUNCTION cfg.validate_rule_set(p_definition jsonb, p_tenant_id uuid)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_errors text[] := '{}';
    r record;
BEGIN
    IF jsonb_typeof(p_definition -> 'rules') IS DISTINCT FROM 'array' THEN
        RETURN ARRAY['rules must be an array'];
    END IF;
    FOR r IN SELECT x ->> 'code' AS code, count(*) n
               FROM jsonb_array_elements(p_definition -> 'rules') x
              GROUP BY 1 HAVING count(*) > 1 OR x ->> 'code' IS NULL LOOP
        v_errors := v_errors || format('rule code %s is missing or duplicated', coalesce(r.code, '(null)'));
    END LOOP;
    FOR r IN SELECT x ->> 'code' AS code
               FROM jsonb_array_elements(p_definition -> 'rules') x
              WHERE NOT (x ? 'value' OR x ? 'then') LOOP
        v_errors := v_errors || format('rule %s needs "value" or "then"', r.code);
    END LOOP;
    -- only the published operator set is allowed (no arbitrary code)
    FOR r IN SELECT DISTINCT o #>> '{}' AS op
               FROM jsonb_path_query(p_definition, 'strict $.**.op') o LOOP
        IF r.op NOT IN ('eq','ne','gt','gte','lt','lte','between','in','notIn') THEN
            v_errors := v_errors || format('operator %s is not allowed', r.op);
        END IF;
    END LOOP;
    RETURN v_errors;
END
$$;

-- Version protection: published/retired versions are immutable and never deleted;
-- publishing validates the document and logs every action.
CREATE OR REPLACE FUNCTION cfg.trg_config_version_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_kind   text := CASE TG_TABLE_NAME WHEN 'workflow_version' THEN 'WORKFLOW' ELSE 'RULESET' END;
    v_obj    uuid;
    v_errors text[];
    v_action text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM app.fail('VERSION_IMMUTABLE', 'Workflow and rule versions are never deleted (discard a draft instead)');
    END IF;

    v_obj := CASE v_kind WHEN 'WORKFLOW' THEN to_jsonb(NEW) ->> 'workflow_definition_id'
                         ELSE to_jsonb(NEW) ->> 'rule_set_id' END;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.status IN ('PUBLISHED','RETIRED','DISCARDED') THEN
            IF NEW.definition IS DISTINCT FROM OLD.definition
               OR NEW.version_no <> OLD.version_no
               OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
               OR NEW.reason <> OLD.reason
               OR NOT (NEW.status = OLD.status OR (OLD.status = 'PUBLISHED' AND NEW.status = 'RETIRED')) THEN
                PERFORM app.fail('VERSION_IMMUTABLE',
                    'A published, retired or discarded version cannot be changed; create a new version');
            END IF;
        END IF;
    END IF;

    IF NEW.status = 'PUBLISHED' AND (TG_OP = 'INSERT' OR OLD.status <> 'PUBLISHED') THEN
        v_errors := CASE v_kind WHEN 'WORKFLOW' THEN cfg.validate_workflow(NEW.definition, NEW.tenant_id)
                                ELSE cfg.validate_rule_set(NEW.definition, NEW.tenant_id) END;
        IF array_length(v_errors, 1) > 0 THEN
            PERFORM app.fail('INVALID_DOCUMENT', 'Cannot publish: ' || array_to_string(v_errors, '; '));
        END IF;
        NEW.validation_status := 'VALID';
        NEW.validation_result := jsonb_build_object('errors', '[]'::jsonb, 'validated_at', now());
        NEW.published_at      := coalesce(NEW.published_at, now());
        NEW.published_by      := coalesce(NEW.published_by, app.platform_user_id());
        NEW.effective_from    := coalesce(NEW.effective_from, app.tenant_today(NEW.tenant_id));
    END IF;
    IF NEW.status = 'RETIRED' AND TG_OP = 'UPDATE' AND OLD.status <> 'RETIRED' THEN
        NEW.retired_at := coalesce(NEW.retired_at, now());
        NEW.retired_by := coalesce(NEW.retired_by, app.platform_user_id());
    END IF;

    v_action := CASE
        WHEN TG_OP = 'INSERT' AND NEW.source = 'IMPORT'  THEN 'IMPORT'
        WHEN TG_OP = 'INSERT' AND NEW.source = 'RESTORE' THEN 'RESTORE'
        WHEN TG_OP = 'INSERT' AND NEW.status = 'PUBLISHED' THEN 'PUBLISH'
        WHEN TG_OP = 'INSERT' THEN 'CREATE_DRAFT'
        WHEN NEW.status <> OLD.status AND NEW.status = 'PUBLISHED' THEN 'PUBLISH'
        WHEN NEW.status <> OLD.status AND NEW.status = 'RETIRED'   THEN 'RETIRE'
        WHEN NEW.status <> OLD.status AND NEW.status = 'DISCARDED' THEN 'DISCARD'
        WHEN NEW.definition IS DISTINCT FROM OLD.definition THEN 'EDIT'
        ELSE NULL END;

    IF v_action IS NOT NULL THEN
        INSERT INTO cfg.config_change_log (tenant_id, object_type, object_id, version_id, version_no,
                                           action, reason, platform_user_id, user_id)
        VALUES (NEW.tenant_id, v_kind, v_obj, NEW.id, NEW.version_no, v_action,
                coalesce(app.setting('app.reason'), NEW.reason), app.platform_user_id(),
                app.setting('app.user_id')::uuid);
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS workflow_version_guard ON cfg.workflow_version;
CREATE TRIGGER workflow_version_guard BEFORE INSERT OR UPDATE OR DELETE ON cfg.workflow_version
    FOR EACH ROW EXECUTE FUNCTION cfg.trg_config_version_guard();
DROP TRIGGER IF EXISTS rule_set_version_guard ON cfg.rule_set_version;
CREATE TRIGGER rule_set_version_guard BEFORE INSERT OR UPDATE OR DELETE ON cfg.rule_set_version
    FOR EACH ROW EXECUTE FUNCTION cfg.trg_config_version_guard();

-- Version in force on a date (the engine stamps it on every transaction).
CREATE OR REPLACE FUNCTION cfg.workflow_version_at(p_workflow_code text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE sql STABLE AS
$$
    SELECT v.id
      FROM cfg.workflow_version v
      JOIN cfg.workflow_definition d ON d.tenant_id = v.tenant_id AND d.id = v.workflow_definition_id
     WHERE v.tenant_id = coalesce(p_tenant_id, app.tenant_id())
       AND d.code = p_workflow_code AND d.status = 'ACTIVE'
       AND v.status = 'PUBLISHED'
       AND v.effective_from <= coalesce(p_on, app.working_date())
       AND (v.effective_to IS NULL OR v.effective_to >= coalesce(p_on, app.working_date()))
     ORDER BY v.effective_from DESC, v.version_no DESC
     LIMIT 1
$$;

CREATE OR REPLACE FUNCTION cfg.rule_set_version_at(p_rule_set_id uuid, p_on date DEFAULT NULL)
RETURNS uuid LANGUAGE sql STABLE AS
$$
    SELECT v.id
      FROM cfg.rule_set_version v
     WHERE v.rule_set_id = p_rule_set_id
       AND v.status = 'PUBLISHED'
       AND v.effective_from <= coalesce(p_on, app.working_date())
       AND (v.effective_to IS NULL OR v.effective_to >= coalesce(p_on, app.working_date()))
     ORDER BY v.effective_from DESC, v.version_no DESC
     LIMIT 1
$$;
