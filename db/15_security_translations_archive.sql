-- CFMS / NVS - 15 Security context, translations and archive catalogue
-- Apply after 14_exception_handling.sql and before 20_security_rls_audit.sql.
-- Re-runnable. The application must sign request context (see README).

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA app;

-- Session GUCs are caller-controlled. This secret-backed signature lets RLS
-- distinguish context set by the trusted API from arbitrary set_config calls.
CREATE TABLE IF NOT EXISTS app.context_signing_key (
    key_id smallint PRIMARY KEY DEFAULT 1 CHECK (key_id = 1),
    secret bytea NOT NULL,
    rotated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO app.context_signing_key (key_id, secret)
VALUES (1, app.gen_random_bytes(32)) ON CONFLICT (key_id) DO NOTHING;
REVOKE ALL ON app.context_signing_key FROM PUBLIC, nvs_app;

CREATE OR REPLACE FUNCTION app.context_payload()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT concat_ws('|',
        coalesce(app.setting('app.tenant_id'), ''),
        coalesce(app.setting('app.user_id'), ''),
        coalesce(app.setting('app.platform_user_id'), ''),
        coalesce(app.setting('app.scope'), ''),
        coalesce(app.setting('app.role_code'), ''),
        coalesce(app.setting('app.channel'), ''),
        coalesce(app.setting('app.working_date'), ''),
        coalesce(app.setting('app.client_ip'), ''),
        coalesce(app.setting('app.device'), ''))
$$;

CREATE OR REPLACE FUNCTION app.context_is_valid()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, app, public AS $$
DECLARE v_secret bytea; v_signature text;
BEGIN
    -- The database owner is an administrative principal, not the API runtime.
    -- Keep local SQL administration usable while requiring signed context for
    -- the shared runtime role and its login members.
    IF session_user = 'nvs' THEN
        RETURN true;
    END IF;
    SELECT secret INTO v_secret FROM app.context_signing_key WHERE key_id = 1;
    v_signature := app.setting('app.context_signature');
    RETURN v_signature IS NOT NULL AND v_secret IS NOT NULL
       AND v_signature = encode(app.hmac(convert_to(app.context_payload(), 'UTF8'), v_secret, 'sha256'), 'hex');
END $$;
REVOKE ALL ON FUNCTION app.context_is_valid() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.context_is_valid() TO nvs_app;

-- The signer is held by the API secret manager. Do not expose it to nvs_app.
CREATE OR REPLACE FUNCTION app.context_signing_key_for_api()
RETURNS text LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, app AS $$
    SELECT encode(secret, 'hex') FROM app.context_signing_key WHERE key_id = 1
$$;
REVOKE ALL ON FUNCTION app.context_signing_key_for_api() FROM PUBLIC, nvs_app;

-- Existing unsigned context setters remain useful for local administration,
-- but unsigned context is intentionally rejected by tenant RLS policies.
CREATE OR REPLACE FUNCTION app.set_context(
    p_tenant_id uuid, p_user_id uuid DEFAULT NULL, p_role_code text DEFAULT NULL,
    p_channel text DEFAULT 'WEB', p_working_date date DEFAULT NULL,
    p_client_ip inet DEFAULT NULL, p_device text DEFAULT NULL,
    p_is_local boolean DEFAULT true, p_signature text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_channel NOT IN ('WEB','MOBILE','SUPER_ADMIN','IMPORT','MIGRATION','SYSTEM','DB') THEN
        PERFORM app.fail('INVALID_CHANNEL', format('Invalid channel %s', p_channel));
    END IF;
    PERFORM set_config('app.tenant_id', coalesce(p_tenant_id::text,''), p_is_local);
    PERFORM set_config('app.user_id', coalesce(p_user_id::text,''), p_is_local);
    PERFORM set_config('app.role_code', coalesce(p_role_code,''), p_is_local);
    PERFORM set_config('app.channel', coalesce(p_channel,''), p_is_local);
    PERFORM set_config('app.working_date', coalesce(p_working_date::text,''), p_is_local);
    PERFORM set_config('app.client_ip', coalesce(p_client_ip::text,''), p_is_local);
    PERFORM set_config('app.device', coalesce(p_device,''), p_is_local);
    PERFORM set_config('app.scope', '', p_is_local);
    PERFORM set_config('app.platform_user_id', '', p_is_local);
    PERFORM set_config('app.context_signature', coalesce(p_signature,''), p_is_local);
END $$;

CREATE OR REPLACE FUNCTION app.set_platform_context(
    p_platform_user_id uuid, p_tenant_id uuid DEFAULT NULL,
    p_client_ip inet DEFAULT NULL, p_is_local boolean DEFAULT true,
    p_signature text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM app.set_context(p_tenant_id, NULL, 'SUPER_ADMIN', 'SUPER_ADMIN', NULL,
                            p_client_ip, NULL, p_is_local, NULL);
    PERFORM set_config('app.platform_user_id', coalesce(p_platform_user_id::text,''), p_is_local);
    PERFORM set_config('app.scope', 'platform', p_is_local);
    PERFORM set_config('app.context_signature', coalesce(p_signature,''), p_is_local);
END $$;

CREATE OR REPLACE FUNCTION app.tenant_id()
RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN app.context_is_valid() THEN app.setting('app.tenant_id')::uuid END
$$;
CREATE OR REPLACE FUNCTION app.is_platform_scope()
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT app.context_is_valid() AND app.setting('app.scope') = 'platform'
$$;

-- Replace policy expressions so a caller cannot bypass RLS by setting GUCs.
DO $$
DECLARE r record; v_policy text; v_expr text;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS tbl, n.nspname || '.' || c.relname AS qname
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_attribute a ON a.attrelid=c.oid AND a.attname='tenant_id' AND a.attnotnull AND NOT a.attisdropped
     WHERE c.relkind IN ('r','p') AND n.nspname IN
       ('platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
  LOOP
    v_policy := CASE WHEN r.qname IN ('audit.audit_event','audit.audit_field_change',
      'cfg.config_change_log','platform.platform_access_log','iam.sign_in_history',
      'wf.action_execution_log') THEN 'APPEND_ONLY'
      WHEN r.qname IN ('platform.tenant_module','platform.tenant_privilege_ceiling',
      'platform.tenant_compliance_setting','platform.purge_policy','platform.purge_run',
      'platform.purge_certificate','platform.platform_access_request','platform.usage_record',
      'platform.tenant_subscription','cfg.tenant_setting','cfg.tenant_action',
      'cfg.action_configuration','cfg.workflow_definition','cfg.workflow_version',
      'cfg.workflow_stage','cfg.workflow_transition','cfg.workflow_condition',
      'cfg.workflow_stage_action','cfg.rule_set','cfg.rule_set_version','iam.role',
      'iam.role_privilege','wf.approval_policy','wf.offline_recorder_role',
      'wf.offline_evidence_type','loan.loan_type','cfg.dashboard_definition',
      'cfg.dashboard_version','platform.job_run') THEN 'CONFIG' ELSE 'TENANT' END;
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', r.tbl);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', r.tbl);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', r.tbl);
    EXECUTE format('DROP POLICY IF EXISTS tenant_select ON %s', r.tbl);
    EXECUTE format('DROP POLICY IF EXISTS tenant_insert ON %s', r.tbl);
    IF v_policy = 'APPEND_ONLY' THEN
      EXECUTE format('CREATE POLICY tenant_select ON %s FOR SELECT USING (app.context_is_valid() AND (tenant_id=app.tenant_id() OR app.is_platform_scope()))', r.tbl);
      EXECUTE format('CREATE POLICY tenant_insert ON %s FOR INSERT WITH CHECK (app.context_is_valid() AND (tenant_id=app.tenant_id() OR app.is_platform_scope()))', r.tbl);
    ELSE
      v_expr := CASE WHEN v_policy='CONFIG'
        THEN '(app.context_is_valid() AND (tenant_id=app.tenant_id() OR app.is_platform_scope()))'
        ELSE '(app.context_is_valid() AND tenant_id=app.tenant_id())' END;
      EXECUTE format('CREATE POLICY tenant_isolation ON %s FOR ALL USING %s WITH CHECK %s', r.tbl, v_expr, v_expr);
    END IF;
  END LOOP;
END $$;

-- Platform-managed translation catalogue and immutable published language packs.
CREATE TABLE IF NOT EXISTS platform.translation_text (
    text_id text PRIMARY KEY,
    module_code text,
    text_type text NOT NULL CHECK (text_type IN ('PAGE','LABEL','MESSAGE','MASTER_DATA')),
    english_text text NOT NULL,
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);
-- Languages the platform supports. This table is the single list of language
-- codes: language packs, member preferences and the API all validate against it.
-- Add a language here (is_active = false until its pack is ready), never in code.
CREATE TABLE IF NOT EXISTS platform.language (
    language_code text PRIMARY KEY CHECK (language_code ~ '^[a-z]{2,3}$'),
    name          text NOT NULL,              -- English name
    native_name   text NOT NULL,              -- name in the language itself
    is_default    boolean NOT NULL DEFAULT false,
    is_active     boolean NOT NULL DEFAULT true,
    sort_order    integer NOT NULL DEFAULT 100,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS language_single_default_uq ON platform.language (is_default) WHERE is_default;
INSERT INTO platform.language (language_code, name, native_name, is_default, is_active, sort_order) VALUES
    ('en', 'English', 'English', true, true, 1),
    ('ta', 'Tamil', 'தமிழ்', false, true, 2)
ON CONFLICT (language_code) DO NOTHING;
-- Reference data: the runtime role reads it; only the owner changes it.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON platform.language FROM nvs_app;
GRANT SELECT ON platform.language TO nvs_app;

CREATE TABLE IF NOT EXISTS platform.language_pack (
    language_code text NOT NULL REFERENCES platform.language (language_code),
    version_no integer NOT NULL CHECK (version_no > 0),
    status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','RETIRED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    created_by uuid,
    published_by uuid,
    PRIMARY KEY (language_code, version_no),
    CHECK (status <> 'PUBLISHED' OR published_at IS NOT NULL)
);
CREATE TABLE IF NOT EXISTS platform.translation_entry (
    language_code text NOT NULL,
    version_no integer NOT NULL,
    text_id text NOT NULL REFERENCES platform.translation_text(text_id),
    translated_text text NOT NULL,
    status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid,
    PRIMARY KEY (language_code, version_no, text_id),
    FOREIGN KEY (language_code, version_no) REFERENCES platform.language_pack(language_code, version_no)
);
CREATE INDEX IF NOT EXISTS translation_entry_missing_idx ON platform.translation_entry(language_code, version_no, status);

-- Existing databases: replace the old hard-coded ('en','ta') check with the
-- reference to platform.language, and validate member language preferences.
ALTER TABLE platform.language_pack DROP CONSTRAINT IF EXISTS language_pack_language_code_check;
DO $$
BEGIN
    PERFORM app.add_constraint_if_missing('platform.language_pack', 'language_pack_language_code_fkey',
        'FOREIGN KEY (language_code) REFERENCES platform.language (language_code)');
    PERFORM app.add_constraint_if_missing('mbr.member', 'member_preferred_language_fkey',
        'FOREIGN KEY (preferred_language) REFERENCES platform.language (language_code)');
END
$$;

-- Searchable archive manifests reference encrypted immutable objects in storage;
-- payload bytes remain outside PostgreSQL. Purge is tracked per data category.
CREATE TABLE IF NOT EXISTS platform.archive_manifest (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES platform.tenant(id),
    data_category_code text NOT NULL REFERENCES platform.data_category(category_code),
    object_uri text NOT NULL,
    object_version text,
    format text NOT NULL DEFAULT 'PARQUET' CHECK (format IN ('PARQUET','JSONL','CSV')),
    encrypted boolean NOT NULL DEFAULT true CHECK (encrypted),
    read_only boolean NOT NULL DEFAULT true CHECK (read_only),
    record_count bigint NOT NULL CHECK (record_count >= 0),
    min_recorded_at timestamptz,
    max_recorded_at timestamptz,
    checksum_sha256 text NOT NULL CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),
    archived_at timestamptz NOT NULL DEFAULT now(),
    retain_until date NOT NULL,
    verification_status text NOT NULL DEFAULT 'PENDING' CHECK (verification_status IN ('PENDING','VERIFIED','FAILED')),
    verified_at timestamptz,
    created_by uuid,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, data_category_code, object_uri),
    CHECK ((verification_status = 'VERIFIED') = (verified_at IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS platform.archive_record_index (
    tenant_id uuid NOT NULL,
    archive_id uuid NOT NULL,
    record_type text NOT NULL,
    record_id uuid NOT NULL,
    record_date date,
    search_terms tsvector,
    PRIMARY KEY (tenant_id, archive_id, record_type, record_id),
    FOREIGN KEY (tenant_id, archive_id) REFERENCES platform.archive_manifest(tenant_id,id)
);
CREATE INDEX IF NOT EXISTS archive_record_search_idx ON platform.archive_record_index USING gin(search_terms);
CREATE TABLE IF NOT EXISTS platform.archive_restore_request (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES platform.tenant(id),
    archive_id uuid NOT NULL,
    requested_by uuid NOT NULL,
    reason text NOT NULL,
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','RESTORING','RESTORED','REJECTED','FAILED')),
    approved_by uuid,
    requested_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    result_reference text,
    FOREIGN KEY (tenant_id, archive_id) REFERENCES platform.archive_manifest(tenant_id,id),
    CHECK (approved_by IS NULL OR approved_by <> requested_by)
);
CREATE TABLE IF NOT EXISTS platform.purge_category_run (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES platform.tenant(id),
    purge_run_id uuid NOT NULL,
    data_category_code text NOT NULL REFERENCES platform.data_category(category_code),
    archived_count bigint NOT NULL DEFAULT 0 CHECK (archived_count >= 0),
    purged_count bigint NOT NULL DEFAULT 0 CHECK (purged_count >= 0),
    held_count bigint NOT NULL DEFAULT 0 CHECK (held_count >= 0),
    archive_id uuid,
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ARCHIVED','PURGED','BLOCKED','FAILED')),
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    FOREIGN KEY (tenant_id, purge_run_id) REFERENCES platform.purge_run(tenant_id,id),
    FOREIGN KEY (tenant_id, archive_id) REFERENCES platform.archive_manifest(tenant_id,id),
    UNIQUE (tenant_id, purge_run_id, data_category_code)
);

-- Platform-language tables have no tenant scope; runtime may read published packs only.
GRANT SELECT, INSERT, UPDATE, DELETE ON platform.translation_text, platform.language_pack,
    platform.translation_entry TO nvs_app;
GRANT SELECT ON platform.archive_manifest, platform.archive_record_index, platform.archive_restore_request,
    platform.purge_category_run TO nvs_app;
GRANT SELECT, INSERT ON platform.archive_restore_request TO nvs_app;
REVOKE UPDATE, DELETE, TRUNCATE ON platform.archive_manifest, platform.archive_record_index,
    platform.purge_category_run FROM nvs_app;

-- Protect the new tenant-owned archive tables with forced RLS and audit hooks.
DO $$ DECLARE t regclass; BEGIN
  FOREACH t IN ARRAY ARRAY['platform.archive_manifest'::regclass,'platform.archive_record_index'::regclass,
      'platform.archive_restore_request'::regclass,'platform.purge_category_run'::regclass]
  LOOP
    PERFORM app.secure_tenant_table(t, 'TENANT');
    PERFORM app.attach_standard_triggers(t, true);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['platform.translation_text'::regclass,'platform.language_pack'::regclass,
      'platform.translation_entry'::regclass]
  LOOP
    PERFORM app.attach_standard_triggers(t, true);
  END LOOP;
END $$;

-- A published language pack and its entries are immutable; edits go into the
-- next draft version so existing clients can keep using their pinned pack.
CREATE OR REPLACE FUNCTION platform.guard_language_pack_immutability()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_pack_status text;
BEGIN
    IF TG_TABLE_NAME = 'language_pack' THEN
        IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;
        IF OLD.status <> 'DRAFT' THEN
            PERFORM app.fail('PUBLISHED_PACK_IMMUTABLE', 'Published language-pack versions cannot be changed or deleted');
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;

    SELECT status INTO v_pack_status FROM platform.language_pack
     WHERE language_code = coalesce(NEW.language_code, OLD.language_code)
       AND version_no = coalesce(NEW.version_no, OLD.version_no);
    IF v_pack_status IS DISTINCT FROM 'DRAFT' THEN
        PERFORM app.fail('PUBLISHED_PACK_IMMUTABLE', 'Translations can only be changed in a draft language pack');
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS language_pack_immutability ON platform.language_pack;
CREATE TRIGGER language_pack_immutability BEFORE UPDATE OR DELETE ON platform.language_pack
    FOR EACH ROW EXECUTE FUNCTION platform.guard_language_pack_immutability();
DROP TRIGGER IF EXISTS translation_entry_immutability ON platform.translation_entry;
CREATE TRIGGER translation_entry_immutability BEFORE INSERT OR UPDATE OR DELETE ON platform.translation_entry
    FOR EACH ROW EXECUTE FUNCTION platform.guard_language_pack_immutability();

-- Script 20 grants function execution broadly, so keep the API signing secret
-- getter owner-only even when the full install is rerun.
REVOKE ALL ON FUNCTION app.context_signing_key_for_api() FROM PUBLIC, nvs_app;

