-- =============================================================================
-- CFMS / NVS  -  06  Record-level audit history (Section 31.1)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- * audit.audit_event: one row per create / update / status change / cancel /
--   reverse / soft delete / restore of ANY tenant record.
-- * audit.audit_field_change: field-level old and new values.
-- * Written by the generic trigger audit.trg_record_change(), attached to every
--   tenant table by script 20. Who / role / channel / working date / device /
--   IP / reason / reference come from the session context (app.set_context,
--   app.set_audit_reason).
-- * Append-only: UPDATE, DELETE and TRUNCATE are rejected by triggers, and RLS
--   has no update/delete policy. The only exception is an approved purge run
--   (session setting app.purge_run_id), which leaves a purge certificate.
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.audit_event (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES platform.tenant (id),
    event_time      timestamptz NOT NULL DEFAULT clock_timestamp(),  -- actual server time
    working_date    date NOT NULL,                                   -- top-bar working date
    is_backdated    boolean NOT NULL DEFAULT false,                  -- working date <> actual date (tenant time zone)
    entity_schema   text NOT NULL,
    entity_table    text NOT NULL,
    record_id       text NOT NULL,
    record_ref      text,                                            -- business reference (LN-2027-0045)
    operation       text NOT NULL CHECK (operation IN ('CREATE','UPDATE','STATUS_CHANGE','CANCEL','REVERSE',
                                                       'DELETE','RESTORE','PURGE')),
    old_status      text,
    new_status      text,
    user_id         uuid,
    platform_user_id uuid,
    role_code       text,
    channel         text NOT NULL,          -- WEB, MOBILE, SUPER_ADMIN, IMPORT, MIGRATION, SYSTEM, DB
    device          text,
    ip_address      inet,
    reason          text,
    reference_type  text,                   -- WORKFLOW, APPROVAL, TRANSACTION, BATCH, JOB
    reference_id    text,
    db_user         text NOT NULL DEFAULT session_user,
    txid            bigint NOT NULL DEFAULT txid_current()
);
CREATE INDEX IF NOT EXISTS audit_event_record_idx ON audit.audit_event (tenant_id, entity_table, record_id, event_time DESC);
CREATE INDEX IF NOT EXISTS audit_event_time_idx   ON audit.audit_event (tenant_id, event_time DESC);
CREATE INDEX IF NOT EXISTS audit_event_user_idx   ON audit.audit_event (tenant_id, user_id, event_time DESC);
CREATE INDEX IF NOT EXISTS audit_event_backdated_idx ON audit.audit_event (tenant_id, working_date) WHERE is_backdated;

CREATE TABLE IF NOT EXISTS audit.audit_field_change (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES platform.tenant (id),
    audit_event_id  bigint NOT NULL REFERENCES audit.audit_event (id),
    field_name      text NOT NULL,
    old_value       jsonb,
    new_value       jsonb
);
CREATE INDEX IF NOT EXISTS audit_field_change_event_idx ON audit.audit_field_change (audit_event_id);
CREATE INDEX IF NOT EXISTS audit_field_change_field_idx ON audit.audit_field_change (tenant_id, field_name);

-- Columns never recorded as field changes (maintained automatically).
-- Sensitive columns are still recorded; the API masks them for roles without
-- the unmask privilege, as on the record itself.
CREATE OR REPLACE FUNCTION audit.ignored_columns()
RETURNS text[] LANGUAGE sql IMMUTABLE AS
$$ SELECT ARRAY['updated_at','updated_by','row_version','created_at','created_by',
                'password_hash','mfa_secret_enc','token_hash'] $$;

-- Generic audit trigger (AFTER INSERT OR UPDATE OR DELETE, FOR EACH ROW)
CREATE OR REPLACE FUNCTION audit.trg_record_change()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_old     jsonb;
    v_new     jsonb;
    v_row     jsonb;
    v_op      text;
    v_tenant  uuid;
    v_event   bigint;
    v_ignore  text[] := audit.ignored_columns();
    v_wd      date;
    v_changes jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_new := to_jsonb(NEW);
        v_op  := 'CREATE';
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_new := to_jsonb(NEW);
        IF (v_old - v_ignore) = (v_new - v_ignore) THEN
            RETURN NULL;                         -- nothing meaningful changed
        END IF;
        v_op := 'UPDATE';
        IF v_new ? 'is_deleted' AND (v_old ->> 'is_deleted') IS DISTINCT FROM (v_new ->> 'is_deleted') THEN
            v_op := CASE WHEN (v_new ->> 'is_deleted')::boolean THEN 'DELETE' ELSE 'RESTORE' END;
        ELSIF v_new ? 'status' AND (v_old ->> 'status') IS DISTINCT FROM (v_new ->> 'status') THEN
            v_op := CASE WHEN v_new ->> 'status' IN ('CANCELLED') THEN 'CANCEL'
                         WHEN v_new ->> 'status' IN ('REVERSED')  THEN 'REVERSE'
                         ELSE 'STATUS_CHANGE' END;
        END IF;
        -- explicit override for this statement (CANCEL / REVERSE ...)
        v_op := coalesce(app.setting('app.audit_operation'), v_op);
    ELSE
        v_old := to_jsonb(OLD);
        v_op  := 'PURGE';                        -- physical delete (purge process only)
    END IF;

    v_row    := coalesce(v_new, v_old);
    v_tenant := (v_row ->> 'tenant_id')::uuid;
    v_wd     := coalesce(app.setting('app.working_date')::date, app.tenant_today(v_tenant));

    IF v_tenant IS NOT NULL THEN
        INSERT INTO audit.audit_event (
            tenant_id, working_date, is_backdated, entity_schema, entity_table, record_id, record_ref,
            operation, old_status, new_status, user_id, platform_user_id, role_code, channel,
            device, ip_address, reason, reference_type, reference_id)
        VALUES (
            v_tenant, v_wd, v_wd <> app.tenant_today(v_tenant), TG_TABLE_SCHEMA, TG_TABLE_NAME,
            coalesce(v_row ->> 'id', v_row ->> 'code', '?'),
            coalesce(v_row ->> 'loan_no', v_row ->> 'member_no', v_row ->> 'receipt_no',
                     v_row ->> 'voucher_no', v_row ->> 'journal_no', v_row ->> 'booking_no',
                     v_row ->> 'asset_no', v_row ->> 'account_no', v_row ->> 'request_no',
                     v_row ->> 'application_no', v_row ->> 'case_no', v_row ->> 'code',
                     v_row ->> 'role_code', v_row ->> 'username', v_row ->> 'setting_key'),
            v_op, v_old ->> 'status', v_new ->> 'status',
            app.setting('app.user_id')::uuid, app.platform_user_id(), app.role_code(), app.channel(),
            app.setting('app.device'), app.setting('app.client_ip')::inet,
            app.setting('app.reason'), app.setting('app.reference_type'), app.setting('app.reference_id'))
        RETURNING id INTO v_event;

        INSERT INTO audit.audit_field_change (tenant_id, audit_event_id, field_name, old_value, new_value)
        SELECT v_tenant, v_event, k.key, v_old -> k.key, v_new -> k.key
          FROM (SELECT jsonb_object_keys(coalesce(v_new, '{}'::jsonb) || coalesce(v_old, '{}'::jsonb)) AS key) k
         WHERE k.key <> ALL (v_ignore)
           AND (v_old -> k.key) IS DISTINCT FROM (v_new -> k.key)
           AND NOT (TG_OP = 'INSERT' AND v_new -> k.key = 'null'::jsonb);
    END IF;

    -- Platform-scope changes (Super Admin) and platform tables also go to the platform log.
    IF v_tenant IS NULL OR app.is_platform_scope() THEN
        SELECT jsonb_object_agg(k.key, jsonb_build_object('old', v_old -> k.key, 'new', v_new -> k.key))
          INTO v_changes
          FROM (SELECT jsonb_object_keys(coalesce(v_new, '{}'::jsonb) || coalesce(v_old, '{}'::jsonb)) AS key) k
         WHERE k.key <> ALL (v_ignore)
           AND (v_old -> k.key) IS DISTINCT FROM (v_new -> k.key);

        INSERT INTO platform.platform_audit_event (tenant_id, platform_user_id, user_id, channel,
            entity_schema, entity_table, record_id, operation, changes, reason, ip_address)
        VALUES (v_tenant, app.platform_user_id(), app.setting('app.user_id')::uuid, app.channel(),
            TG_TABLE_SCHEMA, TG_TABLE_NAME,
            coalesce(v_row ->> 'id', v_row ->> 'module_code', v_row ->> 'action_code', v_row ->> 'privilege_code',
                     v_row ->> 'role_code', v_row ->> 'setting_key', v_row ->> 'account_code', v_row ->> 'code'),
            v_op, v_changes, app.setting('app.reason'), app.setting('app.client_ip')::inet);
    END IF;
    RETURN NULL;
END
$$;

-- Append-only guard
CREATE OR REPLACE FUNCTION audit.trg_append_only()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'DELETE' AND app.setting('app.purge_run_id') IS NOT NULL THEN
        RETURN NULL;                             -- approved purge run only
    END IF;
    PERFORM app.fail('APPEND_ONLY', format('Table %s.%s is append-only: %s is not allowed', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP));
END
$$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['audit.audit_event','audit.audit_field_change','cfg.config_change_log',
                             'platform.platform_audit_event','platform.platform_access_log',
                             'iam.sign_in_history','platform.platform_sign_in','wf.action_execution_log']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS append_only_row ON %s', t);
        -- statement level, so the attempt fails even when RLS hides every row
        EXECUTE format('DROP TRIGGER IF EXISTS append_only_stmt ON %s', t);
        EXECUTE format('CREATE TRIGGER append_only_stmt BEFORE UPDATE OR DELETE ON %s
                        FOR EACH STATEMENT EXECUTE FUNCTION audit.trg_append_only()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS append_only_truncate ON %s', t);
        EXECUTE format('CREATE TRIGGER append_only_truncate BEFORE TRUNCATE ON %s
                        FOR EACH STATEMENT EXECUTE FUNCTION audit.trg_append_only()', t);
    END LOOP;
END
$$;

-- Readable history of one record (History tab), newest first.
CREATE OR REPLACE VIEW audit.v_record_history AS
SELECT e.tenant_id, e.entity_schema, e.entity_table, e.record_id, e.record_ref,
       e.id AS audit_event_id, e.event_time, e.working_date, e.is_backdated,
       e.operation, e.old_status, e.new_status,
       e.user_id, u.full_name AS user_name, e.platform_user_id, e.role_code,
       e.channel, e.device, e.ip_address, e.reason, e.reference_type, e.reference_id,
       f.field_name, f.old_value, f.new_value
  FROM audit.audit_event e
  LEFT JOIN audit.audit_field_change f ON f.audit_event_id = e.id
  LEFT JOIN iam.app_user u ON u.tenant_id = e.tenant_id AND u.id = e.user_id;
