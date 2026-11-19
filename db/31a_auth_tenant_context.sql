-- =============================================================================
-- CFMS / NVS  -  31a  Tenant context for sign-in functions
-- -----------------------------------------------------------------------------
-- Run as nvs after 31. Safe to re-run.
--
-- Sign-in runs before the API has a tenant context, but iam.app_user,
-- iam.user_role, iam.sign_in_history and cfg.tenant_setting are protected by
-- FORCED row-level security that only trusts signed context. Without this
-- script the pre-auth functions see no tenant rows, so every tenant user gets
-- INVALID_CREDENTIALS and Org Admin passwords set during provisioning are lost.
--
-- These functions are SECURITY DEFINER (owned by nvs), so they can read the
-- context signing key and sign a short-lived internal context for one tenant.
-- They save the caller's context first and restore it afterwards. The helpers
-- are not granted to nvs_app, so the runtime role cannot sign context itself.
-- =============================================================================

CREATE OR REPLACE FUNCTION app.push_internal_tenant_context(p_tenant_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, app AS
$$
DECLARE
    v_saved  jsonb := '{}'::jsonb;
    v_key    text;
    v_secret bytea;
BEGIN
    FOREACH v_key IN ARRAY ARRAY['app.tenant_id','app.user_id','app.role_code','app.channel',
                                 'app.working_date','app.client_ip','app.device','app.scope',
                                 'app.platform_user_id','app.context_signature'] LOOP
        v_saved := v_saved || jsonb_build_object(v_key, coalesce(current_setting(v_key, true), ''));
    END LOOP;
    PERFORM app.set_context(p_tenant_id, NULL, NULL, 'SYSTEM', NULL, NULL, NULL, true, NULL);
    SELECT secret INTO v_secret FROM app.context_signing_key WHERE key_id = 1;
    IF v_secret IS NOT NULL THEN
        PERFORM set_config('app.context_signature',
            encode(app.hmac(convert_to(app.context_payload(), 'UTF8'), v_secret, 'sha256'), 'hex'), true);
    END IF;
    RETURN v_saved;
END
$$;

CREATE OR REPLACE FUNCTION app.pop_internal_context(p_saved jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, app AS
$$
DECLARE v_key text;
BEGIN
    FOR v_key IN SELECT jsonb_object_keys(p_saved) LOOP
        PERFORM set_config(v_key, p_saved ->> v_key, true);
    END LOOP;
END
$$;

REVOKE ALL ON FUNCTION app.push_internal_tenant_context(uuid), app.pop_internal_context(jsonb)
    FROM PUBLIC, nvs_app;

-- Same result as the version in 31, but the tenant part is read once per
-- organisation under that organisation's internal context.
DROP FUNCTION IF EXISTS iam.login_candidates(text, text);
CREATE FUNCTION iam.login_candidates(p_identifier text, p_channel text)
RETURNS TABLE (
    principal_kind text, user_id uuid, tenant_id uuid, display_name text,
    password_hash text, account_status text, platform_role text, role_code text,
    channel_access boolean, mfa_enabled boolean, role_requires_mfa boolean,
    must_change_password boolean, locked_until timestamptz, tenant_status text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, iam, platform, app AS
$$
#variable_conflict use_column
DECLARE
    v_tenant record;
    v_saved  jsonb;
    v_found  integer := 0;
    v_rows   integer := 0;
BEGIN
    RETURN QUERY
    SELECT 'PLATFORM'::text, pu.id, NULL::uuid, pu.full_name::text, pu.password_hash::text,
           pu.status::text, pu.platform_role::text, NULL::text, p_channel = 'WEB',
           pu.mfa_enabled, pu.mfa_enabled, pu.must_change_password, pu.locked_until, NULL::text
      FROM platform.platform_user pu
     WHERE (lower(pu.email) = lower(btrim(p_identifier)) OR pu.id::text = lower(btrim(p_identifier)))
       AND pu.platform_role = 'SUPER_ADMIN';
    GET DIAGNOSTICS v_found = ROW_COUNT;

    FOR v_tenant IN SELECT t.id, t.status FROM platform.tenant t ORDER BY t.id LOOP
        EXIT WHEN v_found >= 3;
        v_saved := app.push_internal_tenant_context(v_tenant.id);
        RETURN QUERY
        SELECT 'TENANT'::text, u.id, u.tenant_id, u.full_name::text, u.password_hash::text,
               u.status::text, NULL::text, role_pick.role_code::text,
               v_tenant.status = 'ACTIVE' AND CASE p_channel WHEN 'WEB' THEN u.web_access
                                                         WHEN 'MOBILE' THEN u.mobile_access ELSE false END,
               u.mfa_enabled, coalesce(role_pick.requires_mfa, false), u.must_change_password,
               u.locked_until, v_tenant.status::text
          FROM iam.app_user u
          LEFT JOIN LATERAL (
              SELECT r.role_code, r.requires_mfa
                FROM iam.user_role ur
                JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
               WHERE ur.tenant_id = u.tenant_id AND ur.user_id = u.id
                 AND r.status = 'ACTIVE'
                 AND ur.effective_from <= current_date
                 AND (ur.effective_to IS NULL OR ur.effective_to >= current_date)
               ORDER BY (ur.role_id = u.primary_role_id) DESC, ur.effective_from DESC, r.role_code
               LIMIT 1
          ) role_pick ON true
         WHERE u.tenant_id = v_tenant.id
           AND (lower(btrim(p_identifier)) IN (lower(u.username), lower(u.email))
                OR u.mobile = btrim(p_identifier)
                OR u.id::text = lower(btrim(p_identifier)))
         LIMIT 3;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_found := v_found + v_rows;
        PERFORM app.pop_internal_context(v_saved);
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION iam.record_login_attempt(
    p_principal_kind text, p_user_id uuid, p_tenant_id uuid, p_identifier text,
    p_channel text, p_success boolean, p_failure_reason text,
    p_ip_address text DEFAULT NULL, p_device text DEFAULT NULL, p_user_agent text DEFAULT NULL)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, platform, cfg AS
$$
DECLARE
    v_locked_until timestamptz;
    v_threshold integer := 5;
    v_attempts integer;
    v_saved jsonb;
BEGIN
    IF p_principal_kind = 'PLATFORM' AND p_user_id IS NOT NULL THEN
        IF p_success THEN
            UPDATE platform.platform_user
               SET failed_attempts = 0, locked_until = NULL, last_login_at = now()
             WHERE id = p_user_id
             RETURNING locked_until INTO v_locked_until;
        ELSIF p_failure_reason <> 'LOCKED' THEN
            UPDATE platform.platform_user
               SET failed_attempts = failed_attempts + 1,
                   locked_until = CASE WHEN failed_attempts + 1 >= v_threshold
                                       THEN now() + interval '30 minutes' ELSE locked_until END
             WHERE id = p_user_id
             RETURNING locked_until INTO v_locked_until;
        ELSE
            SELECT locked_until INTO v_locked_until FROM platform.platform_user WHERE id = p_user_id;
        END IF;
        INSERT INTO platform.platform_sign_in(platform_user_id, username, success, failure_reason,
                                              ip_address, device, user_agent)
        VALUES (p_user_id, p_identifier, p_success, CASE WHEN p_success THEN NULL ELSE p_failure_reason END,
                nullif(p_ip_address, '')::inet, p_device, p_user_agent);
    ELSIF p_principal_kind = 'TENANT' AND p_user_id IS NOT NULL AND p_tenant_id IS NOT NULL THEN
        v_saved := app.push_internal_tenant_context(p_tenant_id);
        v_threshold := coalesce((cfg.get_setting('users.lockout_attempts', current_date, p_tenant_id) #>> '{}')::integer, 5);
        IF p_success THEN
            UPDATE iam.app_user
               SET failed_attempts = 0, locked_until = NULL, last_login_at = now()
             WHERE tenant_id = p_tenant_id AND id = p_user_id
             RETURNING locked_until INTO v_locked_until;
        ELSIF p_failure_reason <> 'LOCKED' THEN
            UPDATE iam.app_user
               SET failed_attempts = failed_attempts + 1,
                   locked_until = CASE WHEN failed_attempts + 1 >= v_threshold
                                       THEN now() + interval '30 minutes' ELSE locked_until END
             WHERE tenant_id = p_tenant_id AND id = p_user_id
             RETURNING locked_until INTO v_locked_until;
        ELSE
            SELECT locked_until INTO v_locked_until FROM iam.app_user
             WHERE tenant_id = p_tenant_id AND id = p_user_id;
        END IF;
        INSERT INTO iam.sign_in_history(tenant_id, user_id, username, platform, success,
                                        failure_reason, ip_address, device, user_agent)
        VALUES (p_tenant_id, p_user_id, p_identifier, p_channel, p_success,
                CASE WHEN p_success THEN NULL ELSE p_failure_reason END,
                nullif(p_ip_address, '')::inet, p_device, p_user_agent);
        PERFORM app.pop_internal_context(v_saved);
    ELSE
        INSERT INTO platform.platform_sign_in(username, success, failure_reason,
                                              ip_address, device, user_agent)
        VALUES (p_identifier, false, coalesce(p_failure_reason, 'INVALID_CREDENTIALS'),
                nullif(p_ip_address, '')::inet, p_device, p_user_agent);
    END IF;
    RETURN v_locked_until;
END
$$;

CREATE OR REPLACE FUNCTION iam.prepare_auth_session(
    p_kind text, p_user_id uuid, p_tenant_id uuid, p_session_id uuid,
    p_expires_at timestamptz, p_force_logout boolean, p_client_ip text, p_device text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, cfg AS
$$
DECLARE v_single boolean := false; v_active boolean; v_saved jsonb;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_kind || ':' || coalesce(p_tenant_id::text,'') || ':' || p_user_id::text, 0));
    IF p_kind='TENANT' THEN
        v_saved := app.push_internal_tenant_context(p_tenant_id);
        v_single := coalesce((cfg.get_setting('users.single_session', current_date, p_tenant_id)#>>'{}')::boolean, false);
        PERFORM app.pop_internal_context(v_saved);
    END IF;
    UPDATE iam.auth_session SET revoked_at=now(), revoked_reason='EXPIRED'
     WHERE expires_at <= now() AND revoked_at IS NULL
       AND principal_kind=p_kind AND user_id=p_user_id
       AND tenant_id IS NOT DISTINCT FROM p_tenant_id;
    SELECT EXISTS (SELECT 1 FROM iam.auth_session s WHERE s.principal_kind=p_kind
       AND s.user_id=p_user_id AND s.tenant_id IS NOT DISTINCT FROM p_tenant_id
       AND s.revoked_at IS NULL AND s.expires_at>now()) INTO v_active;
    IF v_single AND v_active AND NOT p_force_logout THEN RETURN false; END IF;
    IF v_single AND v_active AND p_force_logout THEN
        UPDATE iam.auth_session SET revoked_at=now(), revoked_reason='FORCE_LOGOUT'
         WHERE principal_kind=p_kind AND user_id=p_user_id
           AND tenant_id IS NOT DISTINCT FROM p_tenant_id
           AND revoked_at IS NULL AND expires_at>now();
    END IF;
    INSERT INTO iam.auth_session(session_id,principal_kind,user_id,tenant_id,expires_at,client_ip,device)
    VALUES(p_session_id,p_kind,p_user_id,p_tenant_id,p_expires_at,
           nullif(p_client_ip,'')::inet,p_device);
    RETURN true;
END
$$;

CREATE OR REPLACE FUNCTION iam.set_initial_password(
    p_principal_kind text, p_user_id uuid, p_tenant_id uuid, p_password_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, platform AS
$$
DECLARE v_changed integer; v_saved jsonb;
BEGIN
    IF p_password_hash IS NULL OR p_password_hash !~ '^scrypt\$1\$32768\$8\$1\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'Invalid password hash format';
    END IF;
    IF p_principal_kind = 'PLATFORM' AND p_tenant_id IS NULL THEN
        UPDATE platform.platform_user SET password_hash = p_password_hash, must_change_password = true,
               failed_attempts = 0,
               locked_until = NULL, updated_at = now(), row_version = row_version + 1
         WHERE id = p_user_id AND status = 'ACTIVE' AND password_hash IS NULL;
    ELSIF p_principal_kind = 'TENANT' AND p_tenant_id IS NOT NULL THEN
        v_saved := app.push_internal_tenant_context(p_tenant_id);
        UPDATE iam.app_user SET password_hash = p_password_hash, password_changed_at = now(),
               must_change_password = true, failed_attempts = 0, locked_until = NULL,
               updated_at = now(), row_version = row_version + 1
         WHERE tenant_id = p_tenant_id AND id = p_user_id AND status = 'ACTIVE'
           AND password_hash IS NULL;
        GET DIAGNOSTICS v_changed = ROW_COUNT;
        PERFORM app.pop_internal_context(v_saved);
        RETURN v_changed = 1;
    ELSE
        RETURN false;
    END IF;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    RETURN v_changed = 1;
END
$$;

CREATE OR REPLACE FUNCTION iam.set_default_org_admin_password(p_tenant_id uuid, p_password_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam AS
$$
DECLARE v_user_id uuid; v_saved jsonb;
BEGIN
    v_saved := app.push_internal_tenant_context(p_tenant_id);
    UPDATE iam.app_user
       SET password_hash = p_password_hash, password_changed_at = now(),
           must_change_password = true, failed_attempts = 0, locked_until = NULL,
           updated_at = now(), row_version = row_version + 1
     WHERE tenant_id = p_tenant_id AND is_default_org_admin AND status = 'ACTIVE'
       AND password_hash IS NULL
    RETURNING id INTO v_user_id;
    PERFORM app.pop_internal_context(v_saved);
    RETURN v_user_id;
END
$$;

CREATE OR REPLACE FUNCTION iam.set_default_user_password(
    p_tenant_id uuid, p_user_id uuid, p_password_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam AS
$$
DECLARE v_changed integer; v_saved jsonb;
BEGIN
    v_saved := app.push_internal_tenant_context(p_tenant_id);
    UPDATE iam.app_user
       SET password_hash = p_password_hash, password_changed_at = now(),
           must_change_password = true, failed_attempts = 0, locked_until = NULL,
           updated_at = now(), row_version = row_version + 1
     WHERE tenant_id = p_tenant_id AND id = p_user_id AND status = 'ACTIVE'
       AND password_hash IS NULL;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    PERFORM app.pop_internal_context(v_saved);
    RETURN v_changed = 1;
END
$$;

REVOKE ALL ON FUNCTION iam.login_candidates(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.login_candidates(text, text) TO nvs_app;
