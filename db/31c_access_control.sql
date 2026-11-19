-- =============================================================================
-- CFMS / NVS  -  31c  Module and role-privilege administration
-- -----------------------------------------------------------------------------
-- Run as nvs after 31b (and after 30, which defines platform.apply_module_enabled).
-- Safe to re-run.
--
-- Super Admin:
--   platform.list_tenant_modules(tenant)            -> menu modules + enabled flag
--   platform.set_tenant_module(tenant, module, ...) -> enable / disable one module
-- Organisation (signed tenant context):
--   iam.get_role_privilege_matrix()                 -> roles x module actions
--   iam.set_role_privilege(role, privilege, grant)  -> grant / revoke, immediately
--
-- Owner decision (2026-11-19): a user whose role holds user_role.edit changes
-- role privileges directly, without Leadership approval. The access change
-- request tables stay for the older approval flow but are not used here.
-- Guardrails: no lockout of your own role, no grant for a disabled module or
-- above the Super Admin ceiling, workflow/rule configuration stays protected,
-- read-only roles stay read-only. Every change is audited (audit.audit_event
-- through the standard trigger, with the reason set below).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Role and role-privilege changes are gated by the user_role.edit privilege
-- (was: any ADM change needed an approved access change request).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.trg_adm_change_needs_approval()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF app.user_id() IS NOT NULL
       AND app.is_platform_scope() IS NOT TRUE   -- NULL outside platform scope
       AND coalesce(app.setting('app.access_change_request'), '') = ''
       AND NOT iam.has_privilege(app.user_id(), 'user_role.edit') THEN
        PERFORM app.fail('NO_PRIVILEGE',
            'Changing roles and role privileges needs the user_role.edit privilege');
    END IF;
    RETURN coalesce(NEW, OLD);
END
$$;

-- Privileges an organisation can never change itself: workflow and rule
-- configuration beyond viewing belongs to the platform.
CREATE OR REPLACE FUNCTION iam.is_protected_privilege(p_privilege_code text)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT EXISTS (SELECT 1 FROM platform.privilege p
                    WHERE p.privilege_code = p_privilege_code
                      AND p.module_code IN ('WORKFLOW', 'RULES')
                      AND p.type_code NOT IN ('V', 'X', 'H'))
$$;

-- -----------------------------------------------------------------------------
-- Super Admin: modules of one organisation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.list_tenant_modules(p_tenant_id uuid)
RETURNS TABLE (module_code text, module_name text, module_type text, parent_module_code text,
               menu_order integer, is_core boolean, is_optional_legal boolean, is_enabled boolean,
               reason text, row_version integer, updated_at timestamptz)
LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE THEN
        PERFORM app.fail('PLATFORM_CONTEXT_REQUIRED', 'A valid platform administrator context is required');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.tenant t WHERE t.id = p_tenant_id) THEN
        PERFORM app.fail('ORGANISATION_NOT_FOUND', 'Organisation not found');
    END IF;
    RETURN QUERY
    SELECT m.module_code, m.module_name, m.module_type, m.parent_module_code, m.menu_order,
           m.is_core, m.is_optional_legal, coalesce(tm.is_enabled, false), tm.reason,
           tm.row_version, coalesce(tm.updated_at, tm.created_at)
      FROM platform.module m
      LEFT JOIN platform.tenant_module tm ON tm.tenant_id = p_tenant_id AND tm.module_code = m.module_code
     WHERE m.is_active AND m.is_menu
       AND m.module_type IN ('MODULE', 'CONFIGURATION', 'REPORT')
     ORDER BY m.menu_order, m.module_code;
END
$$;

-- Enable or disable one module. SECURITY DEFINER so it can sign a short-lived
-- context for the organisation (the change also creates tenant accounts and
-- defaults); the caller's platform context is checked first and restored after.
CREATE OR REPLACE FUNCTION platform.set_tenant_module(
    p_tenant_id uuid, p_module_code text, p_enabled boolean, p_reason text,
    p_expected_row_version integer DEFAULT NULL, p_legal_warning_ack boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform, app AS
$$
DECLARE
    v_platform_user uuid;
    v_version       integer;
    v_saved         jsonb;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can change organisation modules');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.tenant t WHERE t.id = p_tenant_id) THEN
        PERFORM app.fail('ORGANISATION_NOT_FOUND', 'Organisation not found');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.module m WHERE m.module_code = p_module_code AND m.is_menu) THEN
        PERFORM app.fail('UNKNOWN_MODULE', 'Unknown module ' || coalesce(p_module_code, ''));
    END IF;
    SELECT tm.row_version INTO v_version FROM platform.tenant_module tm
     WHERE tm.tenant_id = p_tenant_id AND tm.module_code = p_module_code;
    IF p_expected_row_version IS NOT NULL AND v_version IS DISTINCT FROM p_expected_row_version THEN
        PERFORM app.fail('STALE_RECORD', 'The module setting was changed after it was opened');
    END IF;

    v_platform_user := app.platform_user_id();
    v_saved := app.push_internal_tenant_context(p_tenant_id);
    PERFORM app.set_audit_reason(p_reason, 'MODULE', p_module_code);
    PERFORM platform.apply_module_enabled(p_tenant_id, p_module_code, p_enabled, p_reason,
                                          v_platform_user, p_legal_warning_ack);
    PERFORM app.pop_internal_context(v_saved);
END
$$;

-- -----------------------------------------------------------------------------
-- Organisation: role x privilege matrix
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.get_role_privilege_matrix()
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.tenant_id() IS NULL THEN
        PERFORM app.fail('NO_PRIVILEGE', 'A signed organisation context is required');
    END IF;
    IF NOT iam.has_privilege(app.user_id(), 'user_role.view') THEN
        PERFORM app.fail('NO_PRIVILEGE', 'Viewing role privileges needs user_role.view');
    END IF;
    RETURN jsonb_build_object(
        'can_edit', iam.has_privilege(app.user_id(), 'user_role.edit'),
        'roles', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', r.id, 'role_code', r.role_code, 'role_name', r.role_name,
                       'role_type', r.role_type, 'status', r.status, 'is_read_only', r.is_read_only,
                       'is_my_role', iam.user_holds_role(app.user_id(), r.role_code, r.tenant_id),
                       'privileges', coalesce((
                           SELECT jsonb_agg(rp.privilege_code ORDER BY rp.privilege_code)
                             FROM iam.role_privilege rp
                            WHERE rp.tenant_id = r.tenant_id AND rp.role_id = r.id), '[]'::jsonb))
                     ORDER BY r.sort_order, r.role_code)
              FROM iam.role r
             WHERE r.tenant_id = app.tenant_id() AND r.status = 'ACTIVE'), '[]'::jsonb),
        'modules', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'module_code', m.module_code, 'module_name', m.module_name,
                       'actions', (
                           SELECT jsonb_agg(jsonb_build_object(
                                      'privilege_code', p.privilege_code, 'type_code', p.type_code,
                                      'name', p.name,
                                      'protected', iam.is_protected_privilege(p.privilege_code))
                                    ORDER BY p.type_code)
                             FROM platform.privilege p
                             JOIN platform.tenant_privilege_ceiling c
                               ON c.tenant_id = app.tenant_id() AND c.privilege_code = p.privilege_code
                            WHERE p.module_code = m.module_code))
                     ORDER BY m.menu_order, m.module_code)
              FROM platform.module m
              JOIN platform.tenant_module tm
                ON tm.tenant_id = app.tenant_id() AND tm.module_code = m.module_code AND tm.is_enabled
             WHERE m.is_active AND m.is_menu
               AND EXISTS (SELECT 1 FROM platform.privilege p
                             JOIN platform.tenant_privilege_ceiling c
                               ON c.tenant_id = app.tenant_id() AND c.privilege_code = p.privilege_code
                            WHERE p.module_code = m.module_code)), '[]'::jsonb));
END
$$;

-- Grant or revoke one privilege on one role, immediately.
CREATE OR REPLACE FUNCTION iam.set_role_privilege(
    p_role_id uuid, p_privilege_code text, p_granted boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_role    iam.role%ROWTYPE;
    v_priv    platform.privilege%ROWTYPE;
    v_held    boolean;
    v_changed boolean := false;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.tenant_id() IS NULL OR app.user_id() IS NULL THEN
        PERFORM app.fail('NO_PRIVILEGE', 'A signed organisation user context is required');
    END IF;
    IF NOT iam.has_privilege(app.user_id(), 'user_role.edit') THEN
        PERFORM app.fail('NO_PRIVILEGE', 'Changing role privileges needs user_role.edit');
    END IF;
    SELECT * INTO v_role FROM iam.role r WHERE r.tenant_id = app.tenant_id() AND r.id = p_role_id;
    IF NOT FOUND OR v_role.status <> 'ACTIVE' THEN
        PERFORM app.fail('NOT_FOUND', 'Role not found');
    END IF;
    SELECT * INTO v_priv FROM platform.privilege p WHERE p.privilege_code = p_privilege_code;
    IF NOT FOUND THEN
        PERFORM app.fail('INVALID_DATA', 'Unknown privilege ' || coalesce(p_privilege_code, ''));
    END IF;
    IF iam.is_protected_privilege(p_privilege_code) THEN
        PERFORM app.fail('PRIVILEGE_PROTECTED', 'This privilege is managed by the platform');
    END IF;

    v_held := EXISTS (SELECT 1 FROM iam.role_privilege rp
                       WHERE rp.tenant_id = v_role.tenant_id AND rp.role_id = v_role.id
                         AND rp.privilege_code = p_privilege_code);

    IF p_granted THEN
        IF NOT EXISTS (SELECT 1 FROM platform.tenant_module tm
                        WHERE tm.tenant_id = v_role.tenant_id AND tm.module_code = v_priv.module_code
                          AND tm.is_enabled) THEN
            PERFORM app.fail('MODULE_NOT_ENABLED', 'Module ' || v_priv.module_code || ' is not enabled');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM platform.tenant_privilege_ceiling c
                        WHERE c.tenant_id = v_role.tenant_id AND c.privilege_code = p_privilege_code) THEN
            PERFORM app.fail('PRIVILEGE_ABOVE_CEILING', 'Privilege is not in the set provided by the Super Administrator');
        END IF;
        IF v_role.is_read_only AND v_priv.type_code NOT IN ('V', 'X', 'H') THEN
            PERFORM app.fail('READ_ONLY_ROLE', 'A read-only role can only view, export and see history');
        END IF;
    ELSIF p_privilege_code IN ('user_role.edit', 'user_role.view')
          AND iam.user_holds_role(app.user_id(), v_role.role_code, v_role.tenant_id) THEN
        PERFORM app.fail('ROLE_ADMIN_LOCKOUT', 'You cannot remove role management from your own role');
    END IF;

    PERFORM app.set_audit_reason(
        coalesce(nullif(btrim(p_reason), ''),
                 format('%s %s %s role %s', CASE WHEN p_granted THEN 'Granted' ELSE 'Revoked' END,
                        p_privilege_code, CASE WHEN p_granted THEN 'to' ELSE 'from' END, v_role.role_code)),
        'ROLE_PRIVILEGE', v_role.id::text);

    IF p_granted AND NOT v_held THEN
        INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
        VALUES (v_role.tenant_id, v_role.id, p_privilege_code);
        v_changed := true;
    ELSIF NOT p_granted AND v_held THEN
        DELETE FROM iam.role_privilege rp
         WHERE rp.tenant_id = v_role.tenant_id AND rp.role_id = v_role.id
           AND rp.privilege_code = p_privilege_code;
        v_changed := true;
    END IF;

    RETURN jsonb_build_object('role_id', v_role.id, 'role_code', v_role.role_code,
                              'privilege_code', p_privilege_code, 'granted', p_granted,
                              'changed', v_changed);
END
$$;

REVOKE ALL ON FUNCTION platform.list_tenant_modules(uuid),
    platform.set_tenant_module(uuid, text, boolean, text, integer, boolean),
    iam.get_role_privilege_matrix(), iam.set_role_privilege(uuid, text, boolean, text),
    iam.is_protected_privilege(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.list_tenant_modules(uuid),
    platform.set_tenant_module(uuid, text, boolean, text, integer, boolean),
    iam.get_role_privilege_matrix(), iam.set_role_privilege(uuid, text, boolean, text),
    iam.is_protected_privilege(text) TO nvs_app;

-- -----------------------------------------------------------------------------
-- Error codes
-- -----------------------------------------------------------------------------
INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-AUTH-3020','ROLE_ADMIN_LOCKOUT','AUTH','AUTHORISATION','ERROR',409,false,false,'You cannot remove role management from your own role.','Ask another administrator, or change a different role.'),
 ('CFMS-AUTH-3021','PRIVILEGE_PROTECTED','AUTH','AUTHORISATION','ERROR',403,false,false,'This privilege is managed by the platform and cannot be changed here.','Contact the platform administrator.'),
 ('CFMS-AUTH-2020','READ_ONLY_ROLE','AUTH','BUSINESS_RULE','ERROR',422,false,false,'A read-only role can only view, export and see history.','Choose a different role for this privilege.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('ROLE_ADMIN_LOCKOUT','உங்கள் சொந்த பங்கிலிருந்து பங்கு நிர்வாகத்தை நீக்க முடியாது.'),
 ('PRIVILEGE_PROTECTED','இந்த அனுமதி தளத்தால் நிர்வகிக்கப்படுகிறது; இங்கே மாற்ற முடியாது.'),
 ('READ_ONLY_ROLE','படிக்க மட்டுமான பங்கு பார்க்க, ஏற்றுமதி செய்ய மற்றும் வரலாற்றைப் பார்க்க மட்டுமே முடியும்.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;
