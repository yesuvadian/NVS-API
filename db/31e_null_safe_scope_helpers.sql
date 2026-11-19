-- =============================================================================
-- CFMS / NVS  -  31e  Null-safe scope and context helpers
-- -----------------------------------------------------------------------------
-- Run as nvs after 31d (last of the 3x function files). Safe to re-run.
--
-- app.is_platform_scope() returned NULL outside platform scope (app.setting()
-- turns an empty setting into NULL), so a guard written as
--     IF NOT app.context_is_valid() OR NOT app.is_platform_scope() THEN fail
-- evaluated to NULL and never failed. Both helpers now always return true or
-- false. Guards in 30/31/31b/31c also use IS NOT TRUE, so they stay safe even
-- if a helper changes again.
--
-- Checked and already never NULL: iam.has_privilege, iam.user_holds_role,
-- iam.is_auth_session_active, iam.is_protected_privilege,
-- platform.is_active_language (all EXISTS).
-- =============================================================================

CREATE OR REPLACE FUNCTION app.is_platform_scope()
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce(app.context_is_valid() AND app.setting('app.scope') = 'platform', false)
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
    RETURN coalesce(v_signature IS NOT NULL AND v_secret IS NOT NULL
       AND v_signature = encode(app.hmac(convert_to(app.context_payload(), 'UTF8'), v_secret, 'sha256'), 'hex'),
       false);
END $$;
REVOKE ALL ON FUNCTION app.context_is_valid() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.context_is_valid() TO nvs_app;
