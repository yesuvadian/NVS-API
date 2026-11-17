-- =============================================================================
-- CFMS / NVS  -  20  Row-level security, audit triggers, grants
-- -----------------------------------------------------------------------------
-- Run as nvs AFTER all table scripts (02-11). Safe to re-run; re-run it after
-- adding any new table so the table is protected and audited automatically.
--
-- Policies
--   TENANT       rows visible / writable only for app.tenant_id()
--   CONFIG       as TENANT, plus the Super Admin console (app.scope='platform')
--                for configuration the platform governs
--   APPEND_ONLY  SELECT for the tenant, INSERT only; no UPDATE / DELETE policy
-- RLS is FORCED, so it also applies to the table owner (nvs). To browse data
-- in DBeaver, first run:  SELECT app.set_context('<tenant uuid>');
-- =============================================================================

CREATE OR REPLACE FUNCTION app.secure_tenant_table(p_table regclass, p_policy text)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE
    v_using text;
BEGIN
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', p_table);

    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', p_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_select ON %s', p_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_insert ON %s', p_table);

    IF p_policy = 'APPEND_ONLY' THEN
        EXECUTE format('CREATE POLICY tenant_select ON %s FOR SELECT
                        USING (tenant_id = app.tenant_id() OR app.is_platform_scope())', p_table);
        EXECUTE format('CREATE POLICY tenant_insert ON %s FOR INSERT
                        WITH CHECK (tenant_id = app.tenant_id() OR app.is_platform_scope())', p_table);
    ELSE
        v_using := CASE p_policy
                     WHEN 'CONFIG' THEN '(tenant_id = app.tenant_id() OR app.is_platform_scope())'
                     ELSE '(tenant_id = app.tenant_id())' END;
        EXECUTE format('CREATE POLICY tenant_isolation ON %s FOR ALL USING %s WITH CHECK %s',
                       p_table, v_using, v_using);
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION app.attach_standard_triggers(p_table regclass, p_audit boolean)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE
    v_has_version boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = p_table AND attname = 'row_version' AND NOT attisdropped)
      INTO v_has_version;

    EXECUTE format('DROP TRIGGER IF EXISTS zz_touch ON %s', p_table);
    IF v_has_version THEN
        EXECUTE format('CREATE TRIGGER zz_touch BEFORE INSERT OR UPDATE ON %s
                        FOR EACH ROW EXECUTE FUNCTION app.trg_touch()', p_table);
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS zz_audit ON %s', p_table);
    IF p_audit THEN
        EXECUTE format('CREATE TRIGGER zz_audit AFTER INSERT OR UPDATE OR DELETE ON %s
                        FOR EACH ROW EXECUTE FUNCTION audit.trg_record_change()', p_table);
    END IF;
END
$$;

DO $$
DECLARE
    r record;
    v_policy text;
    v_audit  boolean;
    -- configuration governed by the platform (Super Admin console may act on it)
    v_config text[] := ARRAY[
        'platform.tenant_module','platform.tenant_privilege_ceiling','platform.tenant_compliance_setting',
        'platform.purge_policy','platform.purge_run','platform.purge_certificate',
        'platform.platform_access_request','platform.usage_record','platform.tenant_subscription',
        'cfg.tenant_setting','cfg.tenant_action','cfg.action_configuration','cfg.workflow_definition',
        'cfg.workflow_version','cfg.workflow_stage','cfg.workflow_transition','cfg.workflow_condition',
        'cfg.workflow_stage_action','cfg.rule_set','cfg.rule_set_version',
        'iam.role','iam.role_privilege',
        'wf.approval_policy','wf.offline_recorder_role','wf.offline_evidence_type',
        'loan.loan_type','cfg.dashboard_definition','cfg.dashboard_version','platform.job_run'];
    v_append text[] := ARRAY[
        'audit.audit_event','audit.audit_field_change','cfg.config_change_log',
        'platform.platform_access_log','iam.sign_in_history','wf.action_execution_log'];
    -- high-volume technical tables with their own status history: not audited
    v_no_audit text[] := ARRAY[
        'wf.action_execution','iam.user_session','notif.notification_message','platform.usage_record',
        'platform.job_run','core.import_row','core.error_log'];
BEGIN
    FOR r IN
        SELECT c.oid::regclass AS tbl, n.nspname || '.' || c.relname AS qname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped AND a.attnotnull
         WHERE c.relkind IN ('r','p')
           AND n.nspname IN ('platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
         ORDER BY 2
    LOOP
        v_policy := CASE WHEN r.qname = ANY (v_append) THEN 'APPEND_ONLY'
                         WHEN r.qname = ANY (v_config) THEN 'CONFIG'
                         ELSE 'TENANT' END;
        v_audit  := NOT (r.qname = ANY (v_append) OR r.qname = ANY (v_no_audit));
        PERFORM app.secure_tenant_table(r.tbl, v_policy);
        PERFORM app.attach_standard_triggers(r.tbl, v_audit);
    END LOOP;

    -- Platform-level tables (no tenant_id): touch + audit into platform log.
    FOR r IN
        SELECT c.oid::regclass AS tbl
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind = 'r' AND n.nspname = 'platform'
           AND c.relname IN ('tenant','platform_user','module','privilege_type','privilege','role_template',
                             'role_template_privilege','sod_rule','setting_definition','settings_template',
                             'settings_template_item','compliance_feature','payment_mode','json_schema',
                             'action_definition','config_template','config_template_version','coa_template',
                             'loan_type_template','lookup_template','notification_template_default',
                             'data_category','subscription_plan','widget_type','dashboard_data_source',
                             'dashboard_template','job_definition','account_mapping_template',
                             'approval_policy_template','number_series_template','import_template',
                             'error_code','sqlstate_error_map','constraint_error_map','action_error_code')
    LOOP
        PERFORM app.attach_standard_triggers(r.tbl, true);
    END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- Grants for the application runtime role (nvs_app): DML only, no DDL.
-- -----------------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
    FOREACH s IN ARRAY ARRAY['app','platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif']
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO nvs_app', s);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO nvs_app', s);
        EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO nvs_app', s);
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO nvs_app', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO nvs_app', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO nvs_app', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO nvs_app', s);
    END LOOP;
END
$$;

-- Module registry and privilege catalogue are maintained by SQL scripts only.
REVOKE INSERT, UPDATE, DELETE ON platform.module, platform.privilege, platform.privilege_type FROM nvs_app;
-- Append-only tables: insert and read only.
REVOKE UPDATE, DELETE ON audit.audit_event, audit.audit_field_change, cfg.config_change_log,
    platform.platform_audit_event, platform.platform_access_log, iam.sign_in_history,
    platform.platform_sign_in, wf.action_execution_log FROM nvs_app;
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA audit FROM nvs_app;
