-- =============================================================================
-- CFMS 14 - Exception management with error codes (idempotent)
--
-- How an error travels:
--   1. Every business rule in the database fails through app.fail(short_code, message).
--   2. app.fail looks the short code up in platform.error_code and raises with
--        SQLSTATE  = CF + the category digit + 00 (CF100 validation, CF200 business rule,
--                    CF300 authorisation, CF400 not found, CF500 conflict, CF600 integration, CF900 system)
--        MESSAGE   = the specific English message (with the actual values)
--        DETAIL    = JSON: {"code":"CFMS-FEE-2001","shortCode":"FEE_UNPAID","category":"BUSINESS_RULE",
--                           "http":422,"severity":"ERROR","retryable":false}
--        HINT      = the short code (unchanged, for older callers)
--   3. Errors PostgreSQL raises itself (unique, foreign key, check, not-null, row-level
--      security, deadlock ...) are translated with app.error_info(sqlstate, constraint,
--      hint): named constraints map through platform.constraint_error_map, everything
--      else through platform.sqlstate_error_map.
--   4. The API rolls back, then logs the error in a new transaction with
--      app.log_error(jsonb) (core.error_log inside an organisation, otherwise
--      platform.platform_error_log), and returns the code, message key and a
--      correlation id to the user. Internal details are never shown to members.
-- Matches scope Section 34.1: code CFMS-<MODULE>-<NNNN>, first digit = category.
-- The catalog itself is seeded in 44_seed_error_codes.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Catalog
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform.error_code (
    code            text PRIMARY KEY CHECK (code ~ '^CFMS-[A-Z]{2,6}-[1-69][0-9]{3}$'),
    short_code      text NOT NULL UNIQUE CHECK (short_code ~ '^[A-Z][A-Z0-9_]*$'),   -- name used in app.fail()
    module          text NOT NULL,          -- AUTH, USER, ORG, MEM, LOAN, FEE, REPAY, SETL, DEF, DEP, CHIT, ASST, EXP,
                                            -- PAY, HALL, ASSET, ACC, WF, RULE, ACT, APPR, NOTIF, RPT, AUDIT, PLAT, SYS
    category        text NOT NULL CHECK (category IN ('VALIDATION','BUSINESS_RULE','AUTHORISATION','NOT_FOUND',
                                                       'CONFLICT','INTEGRATION','SYSTEM')),
    severity        text NOT NULL DEFAULT 'ERROR' CHECK (severity IN ('INFO','WARNING','ERROR','CRITICAL')),
    http_status     integer NOT NULL CHECK (http_status BETWEEN 400 AND 599),
    message_template text NOT NULL,         -- default English user message, {placeholders} allowed
    translations    jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {"ta": "...", "hi": "..."}
    internal_description text,              -- for support; never shown to users
    resolution      text,                   -- suggested resolution for support / the user
    is_retryable    boolean NOT NULL DEFAULT false,
    raises_alert    boolean NOT NULL DEFAULT false,
    is_active       boolean NOT NULL DEFAULT true,  -- codes are never reused; retired codes stay inactive
    sqlstate        text GENERATED ALWAYS AS ('CF' || substr(code, length(code) - 3, 1) || '00') STORED,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (substr(code, 6, length(code) - 10) = module),
    CHECK (substr(code, length(code) - 3, 1) = CASE category WHEN 'VALIDATION' THEN '1' WHEN 'BUSINESS_RULE' THEN '2'
               WHEN 'AUTHORISATION' THEN '3' WHEN 'NOT_FOUND' THEN '4' WHEN 'CONFLICT' THEN '5'
               WHEN 'INTEGRATION' THEN '6' ELSE '9' END)
);

-- Error codes each action can return (shown to the Super Administrator when approving an action).
CREATE TABLE IF NOT EXISTS platform.action_error_code (
    action_code text NOT NULL REFERENCES platform.action_definition (action_code),
    error_code  text NOT NULL REFERENCES platform.error_code (code),
    PRIMARY KEY (action_code, error_code)
);

CREATE TABLE IF NOT EXISTS platform.sqlstate_error_map (
    sqlstate    text PRIMARY KEY CHECK (sqlstate ~ '^[0-9A-Z]{2}([0-9A-Z]{3})?$'),   -- 5 chars, or a 2-char class
    error_code  text NOT NULL REFERENCES platform.error_code (code)
);

CREATE TABLE IF NOT EXISTS platform.constraint_error_map (
    constraint_name text PRIMARY KEY,
    error_code      text NOT NULL REFERENCES platform.error_code (code),
    note            text
);

-- -----------------------------------------------------------------------------
-- Raising: app.fail now carries the catalog code
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.fail(p_code text, p_message text)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE
    e platform.error_code%ROWTYPE;
BEGIN
    SELECT * INTO e FROM platform.error_code WHERE short_code = p_code;
    IF NOT FOUND THEN      -- unknown short code: still a coded business error (90_verify lists these)
        RAISE EXCEPTION USING ERRCODE = 'CF200', MESSAGE = p_message, HINT = p_code,
            DETAIL = jsonb_build_object('code', 'CFMS-SYS-2999', 'shortCode', p_code, 'category', 'BUSINESS_RULE',
                                        'http', 422, 'severity', 'ERROR', 'retryable', false)::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = e.sqlstate, MESSAGE = coalesce(p_message, e.message_template), HINT = p_code,
        DETAIL = jsonb_build_object('code', e.code, 'shortCode', e.short_code, 'category', e.category,
                                    'http', e.http_status, 'severity', e.severity, 'retryable', e.is_retryable)::text;
END
$$;

-- -----------------------------------------------------------------------------
-- Translating any PostgreSQL error into a catalog entry (for the API)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.error_info(p_sqlstate text, p_constraint text DEFAULT NULL, p_hint text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(
        (SELECT jsonb_build_object('code', e.code, 'shortCode', e.short_code, 'category', e.category,
                                   'http', e.http_status, 'severity', e.severity, 'retryable', e.is_retryable,
                                   'message', e.message_template, 'translations', e.translations,
                                   'raisesAlert', e.raises_alert)
           FROM platform.error_code e
          WHERE e.code = coalesce(
                  (SELECT x.code FROM platform.error_code x WHERE x.short_code = p_hint),
                  (SELECT m.error_code FROM platform.constraint_error_map m WHERE m.constraint_name = p_constraint),
                  (SELECT m.error_code FROM platform.sqlstate_error_map m WHERE m.sqlstate = p_sqlstate),
                  (SELECT m.error_code FROM platform.sqlstate_error_map m WHERE m.sqlstate = left(p_sqlstate, 2)))),
        jsonb_build_object('code', 'CFMS-SYS-9000', 'shortCode', 'UNEXPECTED_ERROR', 'category', 'SYSTEM', 'http', 500,
                           'severity', 'CRITICAL', 'retryable', false, 'raisesAlert', true,
                           'message', 'Something went wrong. Please try again and quote the reference to support.'))
$$;

-- -----------------------------------------------------------------------------
-- Error logs
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.error_log (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    occurred_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    working_date     date DEFAULT app.working_date(),
    error_code       text NOT NULL,          -- CFMS-... (catalog code, or CFMS-SYS-9000)
    short_code       text,
    module           text,
    category         text,
    sqlstate         text,
    severity         text NOT NULL DEFAULT 'ERROR' CHECK (severity IN ('INFO','WARNING','ERROR','CRITICAL')),
    http_status      integer,
    message          text NOT NULL,
    detail           text,
    constraint_name  text,
    user_id          uuid DEFAULT app.user_id(),
    role_code        text DEFAULT app.role_code(),
    channel          text DEFAULT app.setting('app.channel'),
    correlation_id   text NOT NULL,          -- shown to the user as the reference number
    request_method   text,
    request_path     text,
    entity_type      text,
    entity_id        uuid,
    context          jsonb NOT NULL DEFAULT '{}'::jsonb,   -- request parameters; personal data masked, no passwords or tokens
    stack_trace      text,                   -- internal; never shown to users
    app_version      text,
    ip_address       inet,
    device_id        text,
    status           text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED','IGNORED')),
    resolved_by      uuid,
    resolved_at      timestamptz,
    resolution_note  text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    CHECK (status NOT IN ('RESOLVED','IGNORED') OR (resolved_by IS NOT NULL AND resolution_note IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS error_log_time_idx ON core.error_log (tenant_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS error_log_code_idx ON core.error_log (tenant_id, error_code, occurred_at DESC);
CREATE INDEX IF NOT EXISTS error_log_corr_idx ON core.error_log (tenant_id, correlation_id);
CREATE INDEX IF NOT EXISTS error_log_open_idx ON core.error_log (tenant_id, occurred_at DESC) WHERE status = 'OPEN';

-- Errors with no organisation (sign-in before a tenant is known, platform screens, jobs).
CREATE TABLE IF NOT EXISTS platform.platform_error_log (
    id               uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id        uuid,
    occurred_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    error_code       text NOT NULL,
    short_code       text,
    module           text,
    category         text,
    sqlstate         text,
    severity         text NOT NULL DEFAULT 'ERROR' CHECK (severity IN ('INFO','WARNING','ERROR','CRITICAL')),
    http_status      integer,
    message          text NOT NULL,
    detail           text,
    constraint_name  text,
    platform_user_id uuid,
    channel          text,
    correlation_id   text NOT NULL,
    request_method   text,
    request_path     text,
    context          jsonb NOT NULL DEFAULT '{}'::jsonb,
    stack_trace      text,
    app_version      text,
    ip_address       inet,
    status           text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED','IGNORED')),
    resolved_by      uuid,
    resolved_at      timestamptz,
    resolution_note  text
);
CREATE INDEX IF NOT EXISTS platform_error_log_time_idx ON platform.platform_error_log (occurred_at DESC);
CREATE INDEX IF NOT EXISTS platform_error_log_corr_idx ON platform.platform_error_log (correlation_id);

-- Log rows are never deleted, and only their handling status can change.
CREATE OR REPLACE FUNCTION core.trg_error_log_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_mutable text[] := ARRAY['status','resolved_by','resolved_at','resolution_note','updated_at','updated_by','row_version'];
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM app.fail('LOG_IMMUTABLE', 'Error log entries are never deleted (they follow the retention policy)');
    END IF;
    IF (to_jsonb(NEW) - v_mutable) <> (to_jsonb(OLD) - v_mutable) THEN
        PERFORM app.fail('LOG_IMMUTABLE', 'Only the handling status of an error log entry can change');
    END IF;
    IF NEW.status IN ('RESOLVED','IGNORED') AND OLD.status NOT IN ('RESOLVED','IGNORED') THEN
        NEW.resolved_at := coalesce(NEW.resolved_at, now());
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS error_log_guard ON core.error_log;
CREATE TRIGGER error_log_guard BEFORE UPDATE OR DELETE ON core.error_log
    FOR EACH ROW EXECUTE FUNCTION core.trg_error_log_guard();
DROP TRIGGER IF EXISTS error_log_guard ON platform.platform_error_log;
CREATE TRIGGER error_log_guard BEFORE UPDATE OR DELETE ON platform.platform_error_log
    FOR EACH ROW EXECUTE FUNCTION core.trg_error_log_guard();

-- Writes one error. Called by the API after rolling back the failed transaction:
--   SELECT app.log_error('{"sqlstate":"CF422","hint":"FEE_UNPAID","message":"...",
--                          "correlationId":"8f2c...","path":"/loans/123/submit","method":"POST",
--                          "context":{...},"stack":"..."}');
-- The catalog code is worked out from sqlstate / constraint / hint when not given.
-- Returns the log id.
CREATE OR REPLACE FUNCTION app.log_error(p jsonb)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_info   jsonb := app.error_info(p ->> 'sqlstate', p ->> 'constraint', p ->> 'hint');
    v_code   text  := coalesce(p ->> 'code', v_info ->> 'code');
    v_corr   text  := coalesce(p ->> 'correlationId', gen_random_uuid()::text);
    v_tenant uuid  := coalesce((p ->> 'tenantId')::uuid, app.tenant_id());
    v_id     uuid;
BEGIN
    IF v_tenant IS NOT NULL THEN
        INSERT INTO core.error_log (tenant_id, error_code, short_code, module, category, sqlstate, severity, http_status, message, detail,
                                    constraint_name, correlation_id, request_method, request_path, entity_type, entity_id,
                                    context, stack_trace, app_version, ip_address, device_id)
        VALUES (v_tenant, v_code, coalesce(p ->> 'hint', v_info ->> 'shortCode'),
                (SELECT module FROM platform.error_code WHERE code = v_code),
                coalesce(p ->> 'category', v_info ->> 'category'), p ->> 'sqlstate',
                coalesce(p ->> 'severity', v_info ->> 'severity', 'ERROR'),
                coalesce((p ->> 'http')::integer, (v_info ->> 'http')::integer),
                coalesce(p ->> 'message', v_info ->> 'message'), p ->> 'detail', p ->> 'constraint', v_corr,
                p ->> 'method', p ->> 'path', p ->> 'entityType', (p ->> 'entityId')::uuid,
                coalesce(p -> 'context', '{}'::jsonb), p ->> 'stack', p ->> 'appVersion',
                (p ->> 'ip')::inet, p ->> 'deviceId')
        RETURNING id INTO v_id;
    ELSE
        INSERT INTO platform.platform_error_log (error_code, short_code, module, category, sqlstate, severity, http_status, message, detail,
                                                 constraint_name, platform_user_id, channel, correlation_id, request_method,
                                                 request_path, context, stack_trace, app_version, ip_address)
        VALUES (v_code, coalesce(p ->> 'hint', v_info ->> 'shortCode'),
                (SELECT module FROM platform.error_code WHERE code = v_code),
                coalesce(p ->> 'category', v_info ->> 'category'), p ->> 'sqlstate',
                coalesce(p ->> 'severity', v_info ->> 'severity', 'ERROR'),
                coalesce((p ->> 'http')::integer, (v_info ->> 'http')::integer),
                coalesce(p ->> 'message', v_info ->> 'message'), p ->> 'detail', p ->> 'constraint',
                nullif(app.setting('app.platform_user_id'), '')::uuid, app.setting('app.channel'), v_corr,
                p ->> 'method', p ->> 'path', coalesce(p -> 'context', '{}'::jsonb), p ->> 'stack', p ->> 'appVersion',
                (p ->> 'ip')::inet)
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END
$$;

-- Daily error summary for the Administration and Auditor dashboards.
CREATE OR REPLACE VIEW core.v_error_summary AS
SELECT l.tenant_id, (l.occurred_at AT TIME ZONE 'UTC')::date AS day, l.error_code, e.short_code, e.module, e.category, l.severity,
       count(*) AS occurrences, count(*) FILTER (WHERE l.status = 'OPEN') AS open_count,
       count(DISTINCT l.user_id) AS users_affected, max(l.occurred_at) AS last_seen
  FROM core.error_log l
  LEFT JOIN platform.error_code e ON e.code = l.error_code
 GROUP BY 1, 2, 3, 4, 5, 6, 7;

-- Action failures carry the catalog code and the request's correlation id (Section 34.1).
ALTER TABLE wf.action_execution ADD COLUMN IF NOT EXISTS correlation_id text;
ALTER TABLE wf.action_execution_log
    ADD COLUMN IF NOT EXISTS error_code     text,
    ADD COLUMN IF NOT EXISTS correlation_id text;
CREATE INDEX IF NOT EXISTS action_execution_error_idx ON wf.action_execution (tenant_id, error_code) WHERE error_code IS NOT NULL;
