-- =============================================================================
-- CFMS / NVS  -  31  Read functions used by the API
-- -----------------------------------------------------------------------------
-- Run as nvs, after 30_functions_provisioning.sql. Safe to re-run.
--
-- Every SELECT the API used to send as inline SQL now lives here, so the
-- repositories only call database functions. Tenant functions scope rows to
-- app.tenant_id() explicitly (RLS still applies, these are SECURITY INVOKER).
--
--   iam.get_tenant_access(...)              -> active user / role / channel check
--   mbr.get_member(member_id)               -> member detail
--   loan.get_member_eligibility_context(id) -> member facts for eligibility
--   loan.get_loan_settings()                -> loan settings with defaults
--   loan.get_application(loan_id, lock)     -> loan application detail
--   loan.count_application_nominees(loan_id)
--   loan.get_current_workflow()             -> published LOAN_APPLICATION version
--   loan.get_workflow_version(version_id)   -> pinned LOAN_APPLICATION version
--   loan.validate_nominees(member, ids[])   -> all nominees active for the member
--   loan.get_application_fee(loan_id)
--   loan.get_approval_inbox(limit, offset)  -> current approver's pending loans
--   platform.search_tenants(...)            -> organisation list
--   platform.list_language_packs(lang)
--   platform.search_translation_entries(...)
--   platform.list_languages()               -> active languages (platform.language)
--   platform.is_active_language(code)
--   platform.get_error_catalogue()          -> error codes, translations and maps
-- =============================================================================

-- -----------------------------------------------------------------------------
-- IAM
-- -----------------------------------------------------------------------------
-- Confirms the token's user, role assignment and channel access are active on
-- the working date. Returns no row when access must be refused.
DROP FUNCTION IF EXISTS iam.get_tenant_access(uuid,uuid,text,date,text);
CREATE OR REPLACE FUNCTION iam.get_tenant_access(
    p_tenant_id uuid, p_user_id uuid, p_role_code text,
    p_working_date date, p_channel text)
RETURNS TABLE (status text, web_access boolean, mobile_access boolean, requires_mfa boolean,
               tenant_enabled boolean)
LANGUAGE sql STABLE AS
$$
    SELECT u.status, u.web_access, u.mobile_access, r.requires_mfa, t.status = 'ACTIVE'
      FROM iam.app_user u
      JOIN platform.tenant t ON t.id = u.tenant_id
      JOIN iam.user_role ur ON ur.tenant_id = u.tenant_id AND ur.user_id = u.id
      JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
     WHERE u.tenant_id = p_tenant_id AND u.id = p_user_id AND r.role_code = p_role_code
       AND u.status = 'ACTIVE' AND r.status = 'ACTIVE'
       AND ur.effective_from <= coalesce(p_working_date, current_date)
       AND (ur.effective_to IS NULL OR ur.effective_to >= coalesce(p_working_date, current_date))
       AND CASE p_channel WHEN 'WEB' THEN u.web_access
                          WHEN 'MOBILE' THEN u.mobile_access ELSE false END
     LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- Members
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mbr.get_member(p_member_id uuid)
RETURNS TABLE (
    id uuid, member_no text, full_name text, date_of_birth date, gender text,
    mobile text, alt_mobile text, email text, address_line1 text, address_line2 text,
    city text, district text, state text, pincode text, membership_date date,
    status text, loan_eligibility text, preferred_language text,
    preferred_channel text, previous_member_id uuid, created_at timestamptz,
    updated_at timestamptz, row_version integer)
LANGUAGE sql STABLE AS
$$
    SELECT m.id, m.member_no, m.full_name, m.date_of_birth, m.gender,
           m.mobile, m.alt_mobile, m.email, m.address_line1, m.address_line2,
           m.city, m.district, m.state, m.pincode, m.membership_date,
           m.status, m.loan_eligibility, m.preferred_language,
           m.preferred_channel, m.previous_member_id, m.created_at,
           m.updated_at, m.row_version
      FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_member_id AND m.is_deleted = false
$$;

-- -----------------------------------------------------------------------------
-- Loans
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.get_member_eligibility_context(p_member_id uuid)
RETURNS TABLE (
    id uuid, member_no text, full_name text, status text, loan_eligibility text,
    membership_date date, cooling_off_until date, working_date date,
    is_first_loan boolean, concurrent_loan_count bigint,
    outstanding_principal numeric, has_overdue_instalment boolean)
LANGUAGE sql STABLE AS
$$
    SELECT m.id, m.member_no, m.full_name, m.status, m.loan_eligibility,
           m.membership_date, m.cooling_off_until, app.working_date(),
           NOT EXISTS (
               SELECT 1 FROM loan.loan prior
                WHERE prior.tenant_id = m.tenant_id AND prior.member_id = m.id
                  AND prior.is_deleted = false
                  AND prior.status NOT IN ('REJECTED','WITHDRAWN','CANCELLED')),
           (SELECT count(*) FROM loan.loan active
             WHERE active.tenant_id = m.tenant_id AND active.member_id = m.id
               AND active.is_deleted = false
               AND active.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')),
           (SELECT coalesce(sum(active.outstanding_principal), 0) FROM loan.loan active
             WHERE active.tenant_id = m.tenant_id AND active.member_id = m.id
               AND active.is_deleted = false
               AND active.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')),
           EXISTS (
               SELECT 1 FROM loan.loan overdue
               JOIN loan.loan_instalment i
                 ON i.tenant_id = overdue.tenant_id AND i.loan_id = overdue.id
                WHERE overdue.tenant_id = m.tenant_id AND overdue.member_id = m.id
                  AND overdue.is_deleted = false
                  AND overdue.status IN ('ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED')
                  AND i.status IN ('DUE','PARTLY_PAID') AND i.due_date < app.working_date())
      FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_member_id AND m.is_deleted = false
$$;

-- Loan settings used by the eligibility check, with platform defaults when a
-- tenant has not configured a value.
CREATE OR REPLACE FUNCTION loan.get_loan_settings()
RETURNS TABLE (
    min_membership_months integer, max_concurrent_loans integer,
    nominee_mandatory_first_loan boolean, block_if_overdue_dues boolean)
LANGUAGE sql STABLE AS
$$
    SELECT coalesce((cfg.get_setting('loans.min_membership_months') #>> '{}')::integer, 6),
           coalesce((cfg.get_setting('loans.max_concurrent_loans') #>> '{}')::integer, 1),
           coalesce((cfg.get_setting('loans.nominee_mandatory_first_loan') #>> '{}')::boolean, true),
           coalesce((cfg.get_setting('loans.block_if_overdue_dues') #>> '{}')::boolean, true)
$$;

-- Loan application detail. p_lock = true takes a row lock on the loan for the
-- rest of the transaction (used before submission), so this is VOLATILE.
CREATE OR REPLACE FUNCTION loan.get_application(p_loan_id uuid, p_lock boolean DEFAULT false)
RETURNS TABLE (
    id uuid, loan_no text, member_id uuid, member_no text, member_name text,
    loan_type_id uuid, loan_type_code text, loan_type_name text, purpose text,
    requested_amount numeric, requested_tenure_months integer, application_date date,
    status text, status_date date, is_first_loan boolean, approved_amount numeric,
    tenure_months integer, interest_rate_annual numeric, interest_method text,
    total_interest numeric, instalment_amount numeric, rule_set_version_id uuid,
    workflow_version_id uuid, created_at timestamptz, updated_at timestamptz,
    row_version integer)
LANGUAGE plpgsql VOLATILE AS
$$
BEGIN
    IF p_lock THEN
        PERFORM 1 FROM loan.loan l
         WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND l.is_deleted = false
           FOR UPDATE;
    END IF;
    RETURN QUERY
    SELECT l.id, l.loan_no, l.member_id, m.member_no, m.full_name,
           l.loan_type_id, lt.code, lt.name, l.purpose, l.requested_amount,
           l.requested_tenure_months, l.application_date, l.status, l.status_date,
           l.is_first_loan, l.approved_amount, l.tenure_months,
           l.interest_rate_annual, l.interest_method, l.total_interest,
           l.instalment_amount, l.rule_set_version_id, l.workflow_version_id,
           l.created_at, l.updated_at, l.row_version
      FROM loan.loan l
      JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
      JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id AND l.is_deleted = false;
END
$$;

CREATE OR REPLACE FUNCTION loan.count_application_nominees(p_loan_id uuid)
RETURNS bigint LANGUAGE sql STABLE AS
$$
    SELECT count(*) FROM loan.loan_nominee
     WHERE tenant_id = app.tenant_id() AND loan_id = p_loan_id
$$;

-- Published LOAN_APPLICATION workflow in force on the working date.
CREATE OR REPLACE FUNCTION loan.get_current_workflow()
RETURNS TABLE (workflow_definition_id uuid, workflow_version_id uuid, version_no integer, definition jsonb)
LANGUAGE sql STABLE AS
$$
    SELECT d.id, v.id, v.version_no, v.definition
      FROM cfg.workflow_definition d
      JOIN cfg.workflow_version v
        ON v.tenant_id = d.tenant_id AND v.workflow_definition_id = d.id
     WHERE d.tenant_id = app.tenant_id()
       AND d.code = 'LOAN_APPLICATION' AND d.status = 'ACTIVE'
       AND v.status = 'PUBLISHED' AND v.effective_from <= app.working_date()
       AND (v.effective_to IS NULL OR v.effective_to >= app.working_date())
     ORDER BY v.effective_from DESC, v.version_no DESC
     LIMIT 1
$$;

-- Workflow version pinned on an application (still usable once retired).
CREATE OR REPLACE FUNCTION loan.get_workflow_version(p_version_id uuid)
RETURNS TABLE (workflow_definition_id uuid, workflow_version_id uuid, version_no integer, definition jsonb)
LANGUAGE sql STABLE AS
$$
    SELECT d.id, v.id, v.version_no, v.definition
      FROM cfg.workflow_version v
      JOIN cfg.workflow_definition d
        ON d.tenant_id = v.tenant_id AND d.id = v.workflow_definition_id
     WHERE v.tenant_id = app.tenant_id() AND v.id = p_version_id
       AND v.status IN ('PUBLISHED','RETIRED')
       AND d.code = 'LOAN_APPLICATION'
$$;

-- True when every distinct nominee id is an active nominee of the member.
CREATE OR REPLACE FUNCTION loan.validate_nominees(p_member_id uuid, p_nominee_ids uuid[])
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT (SELECT count(*) FROM mbr.nominee n
             WHERE n.tenant_id = app.tenant_id() AND n.member_id = p_member_id
               AND n.id = ANY (p_nominee_ids)
               AND n.status = 'ACTIVE' AND n.is_deleted = false)
         = (SELECT count(DISTINCT x) FROM unnest(coalesce(p_nominee_ids, '{}'::uuid[])) x)
$$;

CREATE OR REPLACE FUNCTION loan.get_application_fee(p_loan_id uuid)
RETURNS TABLE (fee_amount numeric, collect_timing text, status text)
LANGUAGE sql STABLE AS
$$
    SELECT f.fee_amount, f.collect_timing, f.status
      FROM loan.loan_application_fee f
     WHERE f.tenant_id = app.tenant_id() AND f.loan_id = p_loan_id
$$;

-- Pending loan approvals for the current user's active role, excluding
-- requests the user raised. The caller passes limit + 1 to detect "has more".
CREATE OR REPLACE FUNCTION loan.get_approval_inbox(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS TABLE (
    approval_request_id uuid, request_no text, loan_id uuid, loan_no text,
    summary text, amount numeric, requested_at timestamptz, approval_status text,
    member_no text, member_name text, requested_amount numeric,
    requested_tenure_months integer, loan_type_name text)
LANGUAGE sql STABLE AS
$$
    SELECT ar.id, ar.request_no, ar.entity_id, ar.business_ref, ar.summary,
           ar.amount, ar.requested_at, ar.status, m.member_no, m.full_name,
           l.requested_amount, l.requested_tenure_months, lt.name
      FROM wf.approval_request ar
      JOIN loan.loan l ON l.tenant_id = ar.tenant_id AND l.id = ar.entity_id
      JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
      JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
     WHERE ar.tenant_id = app.tenant_id()
       AND ar.entity_type = 'loan.loan' AND ar.status = 'PENDING'
       AND ar.requested_by <> app.user_id()
       AND EXISTS (
           SELECT 1 FROM iam.user_role ur
           JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
            WHERE ur.tenant_id = ar.tenant_id AND ur.role_id = ar.required_role_id
              AND ur.user_id = app.user_id()
              AND r.role_code = app.role_code() AND r.status = 'ACTIVE'
              AND ur.effective_from <= app.working_date()
              AND (ur.effective_to IS NULL OR ur.effective_to >= app.working_date()))
     ORDER BY ar.requested_at, ar.request_no
     LIMIT greatest(1, least(p_limit, 501)) OFFSET greatest(p_offset, 0)
$$;

-- -----------------------------------------------------------------------------
-- Platform administration
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.search_tenants(
    p_query text DEFAULT NULL, p_status text DEFAULT NULL,
    p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS TABLE (
    id uuid, code text, name text, legal_name text, status text, is_sandbox boolean,
    time_zone text, contact_email text, contact_mobile text, created_at timestamptz,
    activated_at timestamptz)
LANGUAGE sql STABLE AS
$$
    SELECT t.id, t.code, t.name, t.legal_name, t.status, t.is_sandbox, t.time_zone,
           t.contact_email, t.contact_mobile, t.created_at, t.activated_at
      FROM platform.tenant t
     WHERE (p_query IS NULL OR t.name ILIKE '%' || p_query || '%'
            OR t.code ILIKE '%' || p_query || '%')
       AND (p_status IS NULL OR t.status = p_status)
     ORDER BY t.created_at DESC, t.name
     LIMIT greatest(1, least(p_limit, 500)) OFFSET greatest(p_offset, 0)
$$;

CREATE OR REPLACE FUNCTION platform.list_language_packs(p_language_code text)
RETURNS TABLE (
    language_code text, version_no integer, status text, created_at timestamptz,
    published_at timestamptz, created_by uuid, published_by uuid, approved_count bigint)
LANGUAGE sql STABLE AS
$$
    SELECT p.language_code, p.version_no, p.status, p.created_at,
           p.published_at, p.created_by, p.published_by,
           count(e.text_id) FILTER (WHERE e.status = 'APPROVED')
      FROM platform.language_pack p
      LEFT JOIN platform.translation_entry e
        ON e.language_code = p.language_code AND e.version_no = p.version_no
     WHERE p.language_code = p_language_code
     GROUP BY p.language_code, p.version_no
     ORDER BY p.version_no DESC
$$;

CREATE OR REPLACE FUNCTION platform.search_translation_entries(
    p_language_code text, p_version_no integer,
    p_query text DEFAULT NULL, p_module_code text DEFAULT NULL,
    p_text_type text DEFAULT NULL, p_status text DEFAULT NULL,
    p_missing_only boolean DEFAULT false,
    p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS TABLE (
    text_id text, module_code text, text_type text, english_text text,
    translated_text text, translation_status text, updated_at timestamptz, updated_by uuid)
LANGUAGE sql STABLE AS
$$
    SELECT t.text_id, t.module_code, t.text_type, t.english_text,
           e.translated_text, coalesce(e.status, 'MISSING'), e.updated_at, e.updated_by
      FROM platform.translation_text t
      LEFT JOIN platform.translation_entry e
        ON e.text_id = t.text_id AND e.language_code = p_language_code
       AND e.version_no = p_version_no
     WHERE t.status = 'ACTIVE'
       AND (p_module_code IS NULL OR t.module_code = p_module_code)
       AND (p_text_type IS NULL OR t.text_type = p_text_type)
       AND (p_query IS NULL OR t.text_id ILIKE '%' || p_query || '%'
            OR t.english_text ILIKE '%' || p_query || '%'
            OR e.translated_text ILIKE '%' || p_query || '%')
       AND (p_status IS NULL OR coalesce(e.status, 'MISSING') = p_status)
       AND (NOT coalesce(p_missing_only, false) OR e.text_id IS NULL)
     ORDER BY t.module_code NULLS LAST, t.text_type, t.text_id
     LIMIT greatest(1, least(p_limit, 500)) OFFSET greatest(p_offset, 0)
$$;

-- -----------------------------------------------------------------------------
-- Languages and the error catalogue (cached by the API at start-up)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.list_languages()
RETURNS TABLE (language_code text, name text, native_name text, is_default boolean, sort_order integer)
LANGUAGE sql STABLE AS
$$
    SELECT l.language_code, l.name, l.native_name, l.is_default, l.sort_order
      FROM platform.language l
     WHERE l.is_active
     ORDER BY l.sort_order, l.language_code
$$;

CREATE OR REPLACE FUNCTION platform.is_active_language(p_language_code text)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT EXISTS (SELECT 1 FROM platform.language
                    WHERE language_code = p_language_code AND is_active)
$$;

-- Everything the API needs to turn a short code, SQLSTATE or constraint name
-- into a coded, localised message: {"codes": {short_code: {...}}, "sqlstates":
-- {sqlstate: short_code}, "constraints": {name: short_code}}.
CREATE OR REPLACE FUNCTION platform.get_error_catalogue()
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object(
        'codes', coalesce((
            SELECT jsonb_object_agg(e.short_code, jsonb_build_object(
                       'code', e.code, 'category', e.category, 'severity', e.severity,
                       'http', e.http_status, 'retryable', e.is_retryable,
                       'message', e.message_template, 'translations', e.translations))
              FROM platform.error_code e WHERE e.is_active), '{}'::jsonb),
        'sqlstates', coalesce((
            SELECT jsonb_object_agg(m.sqlstate, e.short_code)
              FROM platform.sqlstate_error_map m
              JOIN platform.error_code e ON e.code = m.error_code AND e.is_active), '{}'::jsonb),
        'constraints', coalesce((
            SELECT jsonb_object_agg(m.constraint_name, e.short_code)
              FROM platform.constraint_error_map m
              JOIN platform.error_code e ON e.code = m.error_code AND e.is_active), '{}'::jsonb))
$$;

-- The runtime role gets EXECUTE through the default privileges set in script
-- 20; grant explicitly as well so a re-run of this file alone is enough.
GRANT EXECUTE ON FUNCTION
    iam.get_tenant_access(uuid, uuid, text, date, text),
    mbr.get_member(uuid),
    loan.get_member_eligibility_context(uuid),
    loan.get_loan_settings(),
    loan.get_application(uuid, boolean),
    loan.count_application_nominees(uuid),
    loan.get_current_workflow(),
    loan.get_workflow_version(uuid),
    loan.validate_nominees(uuid, uuid[]),
    loan.get_application_fee(uuid),
    loan.get_approval_inbox(integer, integer),
    platform.search_tenants(text, text, integer, integer),
    platform.list_language_packs(text),
    platform.search_translation_entries(text, integer, text, text, text, text, boolean, integer, integer),
    platform.list_languages(),
    platform.is_active_language(text),
    platform.get_error_catalogue()
TO nvs_app;

-- -----------------------------------------------------------------------------
-- Authentication (called before any tenant/platform DB context exists)
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER is limited to these credential/attempt operations. Password
-- hashes are returned only to the API runtime for verification; raw passwords
-- are never sent to PostgreSQL.
DROP FUNCTION IF EXISTS iam.login_candidates(text,text);
CREATE OR REPLACE FUNCTION iam.login_candidates(p_identifier text, p_channel text)
RETURNS TABLE (
    principal_kind text, user_id uuid, tenant_id uuid, display_name text,
    password_hash text, account_status text, platform_role text, role_code text,
    channel_access boolean, mfa_enabled boolean, role_requires_mfa boolean,
    must_change_password boolean, locked_until timestamptz, tenant_status text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, iam, platform AS
$$
    SELECT 'PLATFORM'::text, pu.id, NULL::uuid, pu.full_name, pu.password_hash,
           pu.status, pu.platform_role, NULL::text, p_channel = 'WEB',
           pu.mfa_enabled, pu.mfa_enabled, pu.must_change_password, pu.locked_until, NULL::text
      FROM platform.platform_user pu
     WHERE (lower(pu.email) = lower(btrim(p_identifier)) OR pu.id::text = lower(btrim(p_identifier)))
       AND pu.platform_role = 'SUPER_ADMIN'
    UNION ALL
    SELECT 'TENANT'::text, u.id, u.tenant_id, u.full_name, u.password_hash,
           u.status, NULL::text, role_pick.role_code,
           t.status = 'ACTIVE' AND CASE p_channel WHEN 'WEB' THEN u.web_access
                                                  WHEN 'MOBILE' THEN u.mobile_access ELSE false END,
           u.mfa_enabled, coalesce(role_pick.requires_mfa, false), u.must_change_password, u.locked_until, t.status
      FROM iam.app_user u
      JOIN platform.tenant t ON t.id = u.tenant_id
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
     WHERE lower(btrim(p_identifier)) IN (lower(u.username), lower(u.email))
        OR u.mobile = btrim(p_identifier)
        OR u.id::text = lower(btrim(p_identifier))
     ORDER BY 1, 3 NULLS FIRST
     LIMIT 3
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
    ELSE
        INSERT INTO platform.platform_sign_in(username, success, failure_reason,
                                              ip_address, device, user_agent)
        VALUES (p_identifier, false, coalesce(p_failure_reason, 'INVALID_CREDENTIALS'),
                nullif(p_ip_address, '')::inet, p_device, p_user_agent);
    END IF;
    RETURN v_locked_until;
END
$$;

-- Operator-only, one-time provisioning for accounts which have no password.
-- The API runtime role cannot execute this function.
CREATE OR REPLACE FUNCTION iam.set_initial_password(
    p_principal_kind text, p_user_id uuid, p_tenant_id uuid, p_password_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, platform AS
$$
DECLARE v_changed integer;
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
        UPDATE iam.app_user SET password_hash = p_password_hash, password_changed_at = now(),
               must_change_password = true, failed_attempts = 0, locked_until = NULL,
               updated_at = now(), row_version = row_version + 1
         WHERE tenant_id = p_tenant_id AND id = p_user_id AND status = 'ACTIVE'
           AND password_hash IS NULL;
    ELSE
        RETURN false;
    END IF;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    RETURN v_changed = 1;
END
$$;

REVOKE ALL ON FUNCTION iam.login_candidates(text, text),
    iam.record_login_attempt(text, uuid, uuid, text, text, boolean, text, text, text, text),
    iam.set_initial_password(text, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.login_candidates(text, text),
    iam.record_login_attempt(text, uuid, uuid, text, text, boolean, text, text, text, text)
TO nvs_app;
GRANT EXECUTE ON FUNCTION iam.set_initial_password(text, uuid, uuid, text) TO nvs;

-- Provisioning uses the shared first-use password only for the newly created
-- default Org Admin. User-management services can call the generic helper for
-- additional tenant users created with the same first-login requirement.
CREATE OR REPLACE FUNCTION iam.set_default_org_admin_password(p_tenant_id uuid, p_password_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam AS
$$
DECLARE v_user_id uuid;
BEGIN
    UPDATE iam.app_user
       SET password_hash = p_password_hash, password_changed_at = now(),
           must_change_password = true, failed_attempts = 0, locked_until = NULL,
           updated_at = now(), row_version = row_version + 1
     WHERE tenant_id = p_tenant_id AND is_default_org_admin AND status = 'ACTIVE'
       AND password_hash IS NULL
    RETURNING id INTO v_user_id;
    RETURN v_user_id;
END
$$;

CREATE OR REPLACE FUNCTION iam.set_default_user_password(
    p_tenant_id uuid, p_user_id uuid, p_password_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam AS
$$
DECLARE v_changed integer;
BEGIN
    UPDATE iam.app_user
       SET password_hash = p_password_hash, password_changed_at = now(),
           must_change_password = true, failed_attempts = 0, locked_until = NULL,
           updated_at = now(), row_version = row_version + 1
     WHERE tenant_id = p_tenant_id AND id = p_user_id AND status = 'ACTIVE'
       AND password_hash IS NULL;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    RETURN v_changed = 1;
END
$$;

CREATE OR REPLACE FUNCTION iam.complete_initial_password_change(
    p_principal_kind text, p_user_id uuid, p_tenant_id uuid,
    p_expected_hash text, p_new_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, platform AS
$$
DECLARE v_changed integer;
BEGIN
    IF p_principal_kind = 'PLATFORM' AND p_tenant_id IS NULL THEN
        UPDATE platform.platform_user
           SET password_hash = p_new_hash, must_change_password = false,
               failed_attempts = 0, locked_until = NULL, updated_at = now(),
               row_version = row_version + 1
         WHERE id = p_user_id AND status = 'ACTIVE' AND must_change_password
           AND password_hash = p_expected_hash;
    ELSE
        RETURN false;
    END IF;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    RETURN v_changed = 1;
END
$$;

REVOKE ALL ON FUNCTION iam.set_default_org_admin_password(uuid, text),
    iam.set_default_user_password(uuid, uuid, text),
    iam.complete_initial_password_change(text, uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.set_default_org_admin_password(uuid, text),
    iam.set_default_user_password(uuid, uuid, text),
    iam.complete_initial_password_change(text, uuid, uuid, text, text)
TO nvs_app;

-- Password policy and user password operations. History depth is organization
-- configured but clamped to at least one so reuse protection cannot be disabled.
DROP FUNCTION IF EXISTS iam.get_password_hashes_for_policy(uuid,uuid);
CREATE OR REPLACE FUNCTION iam.get_password_hashes_for_policy()
RETURNS TABLE(password_hash text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, iam, cfg, app AS
$$
    WITH policy AS (
        SELECT greatest(1, coalesce((cfg.get_setting('users.password_history', NULL, app.tenant_id())->>0)::integer, 5)) AS depth
    ), hashes AS (
        SELECT u.password_hash, 0 AS position, u.password_changed_at AS changed_at
          FROM iam.app_user u
         WHERE app.context_is_valid() AND u.tenant_id = app.tenant_id() AND u.id = app.user_id()
        UNION ALL
        SELECT h.password_hash, row_number() OVER (ORDER BY h.created_at DESC)::integer,
               h.created_at
          FROM iam.password_history h
         WHERE app.context_is_valid() AND h.tenant_id = app.tenant_id() AND h.user_id = app.user_id()
    )
    SELECT h.password_hash FROM hashes h, policy p
     WHERE h.password_hash IS NOT NULL AND h.position <= p.depth
     ORDER BY h.position, h.changed_at DESC
$$;

CREATE OR REPLACE FUNCTION iam.change_own_password(
    p_expected_hash text, p_new_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, app AS
$$
DECLARE v_changed integer;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.tenant_id() IS NULL OR app.user_id() IS NULL THEN
        RAISE EXCEPTION 'Signed tenant context required' USING ERRCODE = '42501';
    END IF;
    INSERT INTO iam.password_history(tenant_id, user_id, password_hash)
    SELECT tenant_id, id, password_hash FROM iam.app_user
     WHERE tenant_id = app.tenant_id() AND id = app.user_id()
       AND status = 'ACTIVE' AND password_hash = p_expected_hash;
    UPDATE iam.app_user
       SET password_hash = p_new_hash, password_changed_at = now(),
           must_change_password = false, failed_attempts = 0, locked_until = NULL,
           updated_at = now(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = app.user_id()
       AND status = 'ACTIVE' AND password_hash = p_expected_hash;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    RETURN v_changed = 1;
END
$$;

CREATE OR REPLACE FUNCTION iam.reset_user_password(
    p_target_user_id uuid, p_default_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, app AS
$$
DECLARE v_changed integer;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.role_code() IS DISTINCT FROM 'ADM' THEN
        RAISE EXCEPTION 'No privilege' USING ERRCODE = '42501';
    END IF;
    INSERT INTO iam.password_history(tenant_id, user_id, password_hash)
    SELECT u.tenant_id, u.id, u.password_hash FROM iam.app_user u
     WHERE u.tenant_id = app.tenant_id() AND u.id = p_target_user_id
       AND u.id <> app.user_id() AND u.status='ACTIVE'
       AND u.password_hash IS NOT NULL AND u.primary_role_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM iam.role r WHERE r.tenant_id=u.tenant_id
                        AND r.role_code='ADM' AND EXISTS (
                            SELECT 1 FROM iam.user_role ur WHERE ur.tenant_id=u.tenant_id
                             AND ur.user_id=u.id AND ur.role_id=r.id
                             AND ur.effective_from <= current_date
                             AND (ur.effective_to IS NULL OR ur.effective_to >= current_date)));
    UPDATE iam.app_user u
       SET password_hash = p_default_hash, password_changed_at = now(),
           must_change_password = true, failed_attempts = 0, locked_until = NULL,
           updated_at = now(), row_version = row_version + 1
     WHERE u.tenant_id = app.tenant_id() AND u.id = p_target_user_id
       AND u.id <> app.user_id() AND u.status = 'ACTIVE' AND u.primary_role_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM iam.role r WHERE r.tenant_id=u.tenant_id
                        AND r.role_code='ADM' AND EXISTS (
                            SELECT 1 FROM iam.user_role ur WHERE ur.tenant_id=u.tenant_id
                             AND ur.user_id=u.id AND ur.role_id=r.id
                             AND ur.effective_from <= current_date
                             AND (ur.effective_to IS NULL OR ur.effective_to >= current_date)));
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    RETURN v_changed = 1;
END
$$;

REVOKE ALL ON FUNCTION iam.get_password_hashes_for_policy(),
    iam.change_own_password(text,text), iam.reset_user_password(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.get_password_hashes_for_policy(),
    iam.change_own_password(text,text), iam.reset_user_password(uuid,text) TO nvs_app;

DROP FUNCTION IF EXISTS iam.list_tenant_users();
CREATE OR REPLACE FUNCTION iam.list_tenant_users(p_offset integer DEFAULT 0)
RETURNS TABLE(id uuid, full_name text, username text, email text, mobile text,
              status text, role_code text, locked_until timestamptz,
              must_change_password boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, iam, cfg, app AS
$$
    SELECT u.id, u.full_name, u.username, u.email, u.mobile, u.status,
           r.role_code, u.locked_until, u.must_change_password
      FROM iam.app_user u
      LEFT JOIN iam.role r ON r.tenant_id=u.tenant_id AND r.id=u.primary_role_id
     WHERE app.context_is_valid() AND app.role_code()='ADM'
       AND u.tenant_id=app.tenant_id() AND u.status <> 'INACTIVE'
     ORDER BY lower(u.full_name), u.id
     LIMIT greatest(1, coalesce((cfg.get_setting('ui.page_size', app.working_date())#>>'{}')::integer, 15))
     OFFSET greatest(coalesce(p_offset, 0), 0)
$$;

CREATE OR REPLACE FUNCTION iam.list_assignable_roles()
RETURNS TABLE(role_code text, role_name text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, iam, app AS
$$
    SELECT r.role_code, r.role_name FROM iam.role r
     WHERE app.context_is_valid() AND app.role_code()='ADM'
       AND r.tenant_id=app.tenant_id() AND r.status='ACTIVE' AND r.role_code <> 'ADM'
     ORDER BY r.sort_order, r.role_name
$$;

CREATE OR REPLACE FUNCTION iam.create_tenant_user(
    p_full_name text, p_mobile text, p_email text, p_role_code text, p_password_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, app AS
$$
DECLARE v_role_id uuid; v_user_id uuid;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.role_code() IS DISTINCT FROM 'ADM' THEN
        RAISE EXCEPTION 'No privilege' USING ERRCODE = '42501';
    END IF;
    IF nullif(btrim(p_full_name),'') IS NULL OR
       (nullif(btrim(p_mobile),'') IS NULL AND nullif(btrim(p_email),'') IS NULL) OR
       p_role_code IS NULL OR p_role_code='ADM' THEN
        PERFORM app.fail('INVALID_DATA', 'A name, contact and non-administrator role are required');
    END IF;
    IF p_password_hash IS NULL OR p_password_hash !~ '^scrypt\$1\$32768\$8\$1\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+$' THEN
        PERFORM app.fail('INVALID_DATA', 'Initial password hash is invalid');
    END IF;
    SELECT id INTO v_role_id FROM iam.role
     WHERE tenant_id=app.tenant_id() AND role_code=p_role_code AND status='ACTIVE';
    IF v_role_id IS NULL THEN
        PERFORM app.fail('INVALID_REFERENCE', 'Selected role is unavailable');
    END IF;
    INSERT INTO iam.app_user(tenant_id,full_name,mobile,email,web_access,mobile_access,
                             username,password_hash,password_changed_at,must_change_password,
                             primary_role_id,created_by)
    VALUES(app.tenant_id(),btrim(p_full_name),nullif(btrim(p_mobile),''),
           nullif(lower(btrim(p_email)),''),true,false,
           coalesce(nullif(lower(btrim(p_email)),''),nullif(btrim(p_mobile),'')),
           p_password_hash,now(),true,v_role_id,app.user_id())
    RETURNING id INTO v_user_id;
    INSERT INTO iam.user_role(tenant_id,user_id,role_id,effective_from,reason,created_by)
    VALUES(app.tenant_id(),v_user_id,v_role_id,current_date,'Created by Org Admin',app.user_id());
    RETURN v_user_id;
END
$$;

REVOKE ALL ON FUNCTION iam.list_tenant_users(integer), iam.list_assignable_roles(),
    iam.create_tenant_user(text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.list_tenant_users(integer), iam.list_assignable_roles(),
    iam.create_tenant_user(text,text,text,text,text) TO nvs_app;

CREATE OR REPLACE FUNCTION cfg.get_ui_page_size()
RETURNS TABLE(page_size integer, pending_setting_id uuid, pending_page_size integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, cfg, app AS
$$
    SELECT coalesce((cfg.get_setting('ui.page_size', app.working_date())#>>'{}')::integer, 15),
           pending.id, (pending.value#>>'{}')::integer
      FROM (SELECT 1) AS seed
      LEFT JOIN LATERAL (
          SELECT s.id, s.value FROM cfg.tenant_setting s
           WHERE s.tenant_id=app.tenant_id() AND s.setting_key='ui.page_size'
             AND s.status='PENDING_APPROVAL'
           ORDER BY s.created_at DESC LIMIT 1
      ) pending ON true
     WHERE app.context_is_valid()
$$;

CREATE OR REPLACE FUNCTION cfg.request_ui_page_size(p_page_size integer)
RETURNS TABLE(setting_id uuid, status text, page_size integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, cfg, app AS
$$
DECLARE v_id uuid; v_current integer;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.role_code() IS DISTINCT FROM 'ADM' THEN
        RAISE EXCEPTION 'No privilege' USING ERRCODE = '42501';
    END IF;
    IF p_page_size IS NULL OR p_page_size < 1 OR p_page_size > 100 THEN
        PERFORM app.fail('INVALID_DATA', 'Page size must be between 1 and 100');
    END IF;
    v_current := coalesce((cfg.get_setting('ui.page_size', app.working_date())#>>'{}')::integer, 15);
    SELECT s.id INTO v_id FROM cfg.tenant_setting s
     WHERE s.tenant_id=app.tenant_id() AND s.setting_key='ui.page_size'
       AND s.status='PENDING_APPROVAL'
     ORDER BY s.created_at DESC LIMIT 1 FOR UPDATE;
    IF p_page_size = v_current THEN
        IF v_id IS NOT NULL THEN
            UPDATE cfg.tenant_setting
               SET status='CANCELLED', updated_at=now(), updated_by=app.user_id(),
                   reason='Cancelled by Org Admin; requested value matches the active setting',
                   row_version=row_version+1
             WHERE tenant_id=app.tenant_id() AND id=v_id;
        END IF;
        RETURN QUERY SELECT NULL::uuid, 'UNCHANGED'::text, v_current;
        RETURN;
    END IF;
    IF v_id IS NULL THEN
        INSERT INTO cfg.tenant_setting(tenant_id,setting_key,value,effective_from,status,source,reason,created_by)
        VALUES(app.tenant_id(),'ui.page_size',to_jsonb(p_page_size),app.working_date(),
               'PENDING_APPROVAL','ORG_ADMIN','Page size changed by Org Admin',app.user_id())
        RETURNING id INTO v_id;
    ELSE
        UPDATE cfg.tenant_setting
           SET value=to_jsonb(p_page_size), reason='Page size changed by Org Admin',
               updated_at=now(), updated_by=app.user_id(), row_version=row_version+1
         WHERE tenant_id=app.tenant_id() AND id=v_id;
    END IF;
    RETURN QUERY SELECT v_id, 'PENDING_APPROVAL'::text, p_page_size;
END
$$;

CREATE OR REPLACE FUNCTION cfg.decide_ui_page_size(
    p_setting_id uuid, p_approve boolean, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, cfg, app AS
$$
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.role_code() IS DISTINCT FROM 'LDR' THEN
        RAISE EXCEPTION 'No privilege' USING ERRCODE = '42501';
    END IF;
    PERFORM cfg.approve_tenant_setting(p_setting_id,p_approve,p_reason);
END
$$;

REVOKE ALL ON FUNCTION cfg.get_ui_page_size(), cfg.request_ui_page_size(integer),
    cfg.decide_ui_page_size(uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cfg.get_ui_page_size(), cfg.request_ui_page_size(integer),
    cfg.decide_ui_page_size(uuid,boolean,text) TO nvs_app;

CREATE OR REPLACE FUNCTION iam.get_user_capabilities(p_role_code text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, iam, platform, app AS
$$
    SELECT CASE WHEN app.context_is_valid() THEN jsonb_build_object(
      'role_code', app.role_code(),
      'privileges', coalesce((
        SELECT jsonb_agg(DISTINCT rp.privilege_code ORDER BY rp.privilege_code)
          FROM iam.user_role ur
          JOIN iam.role r ON r.tenant_id=ur.tenant_id AND r.id=ur.role_id
          JOIN iam.role_privilege rp ON rp.tenant_id=r.tenant_id AND rp.role_id=r.id
          JOIN platform.tenant_privilege_ceiling pc ON pc.tenant_id=rp.tenant_id
             AND pc.privilege_code=rp.privilege_code
          JOIN platform.privilege p ON p.privilege_code=rp.privilege_code
          JOIN platform.tenant_module tm ON tm.tenant_id=rp.tenant_id
             AND tm.module_code=p.module_code AND tm.is_enabled
         WHERE ur.tenant_id=app.tenant_id() AND ur.user_id=app.user_id()
           AND r.role_code=p_role_code AND r.status='ACTIVE'
           AND ur.effective_from<=app.working_date()
           AND (ur.effective_to IS NULL OR ur.effective_to>=app.working_date())
      ), '[]'::jsonb),
      'modules', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
            'module_code',m.module_code,'module_name',m.module_name,
            'module_type',m.module_type,'route',m.route,'icon',m.icon,
            'parent_module_code',m.parent_module_code,'menu_order',m.menu_order
        ) ORDER BY m.menu_order,m.module_code)
          FROM platform.module m
         WHERE m.is_active AND m.is_menu
           AND m.module_type IN ('MODULE','CONFIGURATION','REPORT','DASHBOARD')
           AND EXISTS (SELECT 1 FROM platform.tenant_module tm
                        WHERE tm.tenant_id=app.tenant_id() AND tm.module_code=m.module_code
                          AND tm.is_enabled)
           AND EXISTS (
               SELECT 1 FROM iam.user_role ur
               JOIN iam.role r ON r.tenant_id=ur.tenant_id AND r.id=ur.role_id
               JOIN iam.role_privilege rp ON rp.tenant_id=r.tenant_id AND rp.role_id=r.id
               JOIN platform.privilege p ON p.privilege_code=rp.privilege_code
               WHERE ur.tenant_id=app.tenant_id() AND ur.user_id=app.user_id()
                 AND r.role_code=p_role_code AND r.status='ACTIVE'
                 AND p.module_code=m.module_code
                 AND ur.effective_from<=app.working_date()
                 AND (ur.effective_to IS NULL OR ur.effective_to>=app.working_date())
           )
      ), '[]'::jsonb)
    ) ELSE '{}'::jsonb END
$$;
REVOKE ALL ON FUNCTION iam.get_user_capabilities(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.get_user_capabilities(text) TO nvs_app;

CREATE OR REPLACE FUNCTION platform.set_tenant_password_history(p_tenant_id uuid, p_count integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform, cfg, app AS
$$
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can set password history policy');
    END IF;
    IF p_count < 1 OR p_count > 24 THEN
        PERFORM app.fail('INVALID_DATA', 'Password history must be between 1 and 24');
    END IF;
    UPDATE cfg.tenant_setting
       SET value = to_jsonb(p_count), source = 'SUPER_ADMIN', is_locked = true,
           reason = 'Set by Super Administrator during organisation provisioning',
           updated_at = now(), updated_by = app.platform_user_id(),
           row_version = row_version + 1
     WHERE tenant_id = p_tenant_id AND setting_key = 'users.password_history'
       AND status = 'ACTIVE';
    IF NOT FOUND THEN
        PERFORM app.fail('ORGANISATION_NOT_FOUND', 'Password history setting was not provisioned');
    END IF;
END
$$;
REVOKE ALL ON FUNCTION platform.set_tenant_password_history(uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.set_tenant_password_history(uuid,integer) TO nvs_app;

CREATE OR REPLACE FUNCTION platform.set_tenant_enabled(p_tenant_id uuid, p_enabled boolean, p_reason text)
RETURNS TABLE(tenant_id uuid, status text, status_reason text, suspended_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform, iam, app AS
$$
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can enable or disable an organisation');
    END IF;
    RETURN QUERY
    UPDATE platform.tenant t
       SET status = CASE WHEN p_enabled THEN 'ACTIVE' ELSE 'SUSPENDED' END,
           suspended_at = CASE WHEN p_enabled THEN NULL ELSE coalesce(t.suspended_at, now()) END,
           status_reason = nullif(btrim(p_reason), ''),
           updated_at = now(), row_version = row_version + 1
     WHERE t.id = p_tenant_id AND t.status IN ('ACTIVE','SUSPENDED')
    RETURNING t.id, t.status, t.status_reason, t.suspended_at;
    IF NOT FOUND THEN
        PERFORM app.fail('ORGANISATION_NOT_FOUND', 'Organisation was not found or cannot be changed');
    END IF;
    IF NOT p_enabled THEN
        UPDATE iam.auth_session SET revoked_at=now(), revoked_reason='ORGANISATION_DISABLED'
         WHERE principal_kind='TENANT' AND tenant_id=p_tenant_id AND revoked_at IS NULL;
    END IF;
END
$$;
REVOKE ALL ON FUNCTION platform.set_tenant_enabled(uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.set_tenant_enabled(uuid,boolean,text) TO nvs_app;

CREATE OR REPLACE FUNCTION platform.set_tenant_single_session(p_tenant_id uuid, p_enabled boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform, cfg, app AS
$$
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can set single-session policy');
    END IF;
    UPDATE cfg.tenant_setting
       SET value = to_jsonb(p_enabled), source = 'SUPER_ADMIN', is_locked = true,
           reason = 'Set by Super Administrator during organisation provisioning',
           updated_at = now(), updated_by = app.platform_user_id(),
           row_version = row_version + 1
     WHERE tenant_id = p_tenant_id AND setting_key = 'users.single_session'
       AND status = 'ACTIVE';
    IF NOT FOUND THEN
        PERFORM app.fail('ORGANISATION_NOT_FOUND', 'Single-session setting was not provisioned');
    END IF;
END
$$;
REVOKE ALL ON FUNCTION platform.set_tenant_single_session(uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.set_tenant_single_session(uuid,boolean) TO nvs_app;

-- Super Admin organisation wizard: published defaults and configurable setup choices.
CREATE OR REPLACE FUNCTION platform.get_organisation_setup_options()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, platform, app AS
$$
DECLARE v_version integer;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can view organisation setup options');
    END IF;
    SELECT version_no INTO v_version FROM platform.settings_template WHERE status='PUBLISHED';
    IF v_version IS NULL THEN
        PERFORM app.fail('NO_SETTINGS_TEMPLATE', 'No published default settings template');
    END IF;
    RETURN jsonb_build_object(
        'settings_template_version', v_version,
        'defaults', jsonb_build_object(
            'time_zone', coalesce((SELECT value #>> '{}' FROM platform.settings_template_item
                                    WHERE version_no=v_version AND setting_key='general.time_zone'), 'Asia/Kolkata'),
            'currency_code', coalesce((SELECT value #>> '{}' FROM platform.settings_template_item
                                        WHERE version_no=v_version AND setting_key='general.currency'), 'INR'),
            'data_region', 'IN',
            'is_sandbox', false,
            'password_history', coalesce((SELECT (value #>> '{}')::integer FROM platform.settings_template_item
                                           WHERE version_no=v_version AND setting_key='users.password_history'), 5),
            'single_session', coalesce((SELECT (value #>> '{}')::boolean FROM platform.settings_template_item
                                         WHERE version_no=v_version AND setting_key='users.single_session'), false),
            'page_size', coalesce((SELECT (value #>> '{}')::integer FROM platform.settings_template_item
                                    WHERE version_no=v_version AND setting_key='ui.page_size'), 15),
            'language', coalesce((SELECT value #>> '{}' FROM platform.settings_template_item
                                   WHERE version_no=v_version AND setting_key='general.language'), 'en')
        ),
        'modules', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'code', m.module_code, 'name', m.module_name, 'description', m.description,
                'is_core', m.is_core, 'is_optional_legal', m.is_optional_legal,
                'default_enabled', m.is_core
            ) ORDER BY m.menu_order, m.module_code)
              FROM platform.module m
             WHERE m.is_active AND m.is_menu
               AND m.module_type IN ('MODULE','CONFIGURATION','REPORT')
        ), '[]'::jsonb),
        'features', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'code', f.feature_code, 'name', f.name, 'description', f.description,
                'module_code', f.module_code, 'legal_warning', f.legal_warning,
                'default_enabled', false
            ) ORDER BY f.sort_order, f.feature_code)
              FROM platform.compliance_feature f
        ), '[]'::jsonb),
        'settings', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'key', d.setting_key, 'area', d.area, 'name', d.name,
                'description', d.description, 'data_type', d.data_type,
                'editable_by', d.editable_by, 'validation', d.validation,
                'is_proposed', d.is_proposed, 'default_value', i.value
            ) ORDER BY d.sort_order, d.setting_key)
              FROM platform.setting_definition d
              LEFT JOIN platform.settings_template_item i
                ON i.version_no=v_version AND i.setting_key=d.setting_key
        ), '[]'::jsonb)
    );
END
$$;

CREATE OR REPLACE FUNCTION platform.apply_tenant_onboarding_profile(
    p_tenant_id uuid, p_profile jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform, app AS
$$
DECLARE v_zone text; v_currency text; v_region text;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can configure organisation profile defaults');
    END IF;
    IF jsonb_typeof(p_profile) IS DISTINCT FROM 'object' THEN
        PERFORM app.fail('INVALID_DATA', 'Organisation profile settings must be an object');
    END IF;
    v_zone := p_profile->>'time_zone';
    v_currency := p_profile->>'currency_code';
    v_region := p_profile->>'data_region';
    IF v_zone IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name=v_zone) THEN
        PERFORM app.fail('INVALID_DATA', 'Choose a valid time zone');
    END IF;
    IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$' THEN
        PERFORM app.fail('INVALID_DATA', 'Currency must be a three-letter uppercase code');
    END IF;
    IF v_region IS NULL OR v_region !~ '^[A-Z]{2,8}$' THEN
        PERFORM app.fail('INVALID_DATA', 'Data region code is invalid');
    END IF;
    UPDATE platform.tenant
       SET legal_name=nullif(btrim(p_profile->>'legal_name'),''),
           registration_no=nullif(btrim(p_profile->>'registration_no'),''),
           address=coalesce(p_profile->'address','{}'::jsonb),
           time_zone=v_zone, currency_code=v_currency, data_region=v_region,
           is_sandbox=coalesce((p_profile->>'is_sandbox')::boolean,false),
           updated_at=now(), updated_by=app.platform_user_id(), row_version=row_version+1
     WHERE id=p_tenant_id;
    IF NOT FOUND THEN PERFORM app.fail('ORGANISATION_NOT_FOUND','Organisation not found'); END IF;
END
$$;

CREATE OR REPLACE FUNCTION platform.apply_tenant_onboarding_settings(
    p_tenant_id uuid, p_settings jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform, cfg, app AS
$$
DECLARE v_item record; v_count integer := 0; v_kind text; v_number numeric;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED', 'Only a Super Administrator can configure organisation settings');
    END IF;
    IF jsonb_typeof(p_settings) IS DISTINCT FROM 'object' THEN
        PERFORM app.fail('INVALID_DATA', 'Organisation settings must be an object');
    END IF;
    FOR v_item IN SELECT d.*, e.key AS supplied_key, e.value AS supplied_value
                    FROM jsonb_each(p_settings) e
                    LEFT JOIN platform.setting_definition d ON d.setting_key=e.key
    LOOP
        IF v_item.setting_key IS NULL OR v_item.editable_by='FIXED' THEN
            PERFORM app.fail('INVALID_DATA', 'Unknown or fixed organisation setting: ' || v_item.supplied_key);
        END IF;
        v_kind := jsonb_typeof(v_item.supplied_value);
        IF v_kind<>'null' AND (
               (v_item.data_type='boolean' AND v_kind<>'boolean')
            OR (v_item.data_type IN ('integer','decimal') AND v_kind<>'number')
            OR (v_item.data_type='string' AND v_kind<>'string')
            OR (v_item.data_type='list' AND v_kind<>'array')
            OR (v_item.data_type='json' AND v_kind NOT IN ('object','array'))
            OR (v_item.data_type='date' AND (v_kind<>'string' OR v_item.supplied_value #>> '{}' !~ '^\\d{4}-\\d{2}-\\d{2}$'))
        ) THEN
            PERFORM app.fail('INVALID_DATA', 'Setting value has the wrong type: ' || v_item.supplied_key);
        END IF;
        IF v_kind='number' THEN
            v_number := (v_item.supplied_value #>> '{}')::numeric;
            IF v_item.data_type='integer' AND trunc(v_number)<>v_number THEN
                PERFORM app.fail('INVALID_DATA', 'Setting must be a whole number: ' || v_item.supplied_key);
            END IF;
            IF v_item.validation ? 'min' AND v_number < (v_item.validation->>'min')::numeric THEN
                PERFORM app.fail('INVALID_DATA', 'Setting is below its minimum: ' || v_item.supplied_key);
            END IF;
            IF v_item.validation ? 'max' AND v_number > (v_item.validation->>'max')::numeric THEN
                PERFORM app.fail('INVALID_DATA', 'Setting exceeds its maximum: ' || v_item.supplied_key);
            END IF;
        END IF;
        IF v_item.validation ? 'enum' AND NOT (v_item.validation->'enum' @> jsonb_build_array(v_item.supplied_value)) THEN
            PERFORM app.fail('INVALID_DATA', 'Setting value is not allowed: ' || v_item.supplied_key);
        END IF;
        UPDATE cfg.tenant_setting
           SET value=v_item.supplied_value, source='SUPER_ADMIN',
               is_locked=(v_item.editable_by='SUPER_ADMIN'),
               reason='Configured by Super Administrator during organisation creation',
               updated_at=now(), updated_by=app.platform_user_id(), row_version=row_version+1
         WHERE id=(SELECT s.id FROM cfg.tenant_setting s
                    WHERE s.tenant_id=p_tenant_id AND s.setting_key=v_item.setting_key
                      AND s.status='ACTIVE'
                    ORDER BY s.effective_from DESC, s.created_at DESC LIMIT 1);
        IF NOT FOUND THEN
            INSERT INTO cfg.tenant_setting(
                tenant_id,setting_key,value,effective_from,status,source,template_version,
                is_locked,reason,created_by,updated_by
            )
            SELECT p_tenant_id,v_item.setting_key,v_item.supplied_value,current_date,'ACTIVE','SUPER_ADMIN',
                   t.settings_template_version,(v_item.editable_by='SUPER_ADMIN'),
                   'Configured by Super Administrator during organisation creation',
                   app.platform_user_id(),app.platform_user_id()
              FROM platform.tenant t WHERE t.id=p_tenant_id;
        END IF;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END
$$;

REVOKE ALL ON FUNCTION platform.get_organisation_setup_options(),
    platform.apply_tenant_onboarding_profile(uuid,jsonb),
    platform.apply_tenant_onboarding_settings(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.get_organisation_setup_options(),
    platform.apply_tenant_onboarding_profile(uuid,jsonb),
    platform.apply_tenant_onboarding_settings(uuid,jsonb) TO nvs_app;

CREATE TABLE IF NOT EXISTS iam.auth_session (
    session_id uuid PRIMARY KEY,
    principal_kind text NOT NULL CHECK (principal_kind IN ('PLATFORM','TENANT')),
    user_id uuid NOT NULL,
    tenant_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoked_reason text,
    client_ip inet,
    device text,
    CHECK ((principal_kind='PLATFORM' AND tenant_id IS NULL) OR
           (principal_kind='TENANT' AND tenant_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS auth_session_user_active_idx
    ON iam.auth_session(principal_kind, tenant_id, user_id, expires_at)
    WHERE revoked_at IS NULL;

-- Local E2E account reset. Callable only by the schema owner (nvs), never by
-- the API role. It synchronizes an ignored local test config with account
-- passwords without exposing plaintext to PostgreSQL or requiring inline SQL.
CREATE OR REPLACE FUNCTION iam.reset_e2e_account_password(
    p_identifier text, p_expected_kind text, p_password_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, platform AS
$$
DECLARE v_user record; v_count integer; v_changed integer;
BEGIN
    IF p_expected_kind NOT IN ('PLATFORM','TENANT') OR
       p_password_hash IS NULL OR
       p_password_hash !~ '^scrypt\$1\$32768\$8\$1\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'Invalid E2E account reset request' USING ERRCODE = '22023';
    END IF;
    SELECT count(*) INTO v_count FROM iam.login_candidates(p_identifier,'WEB')
     WHERE principal_kind=p_expected_kind;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'E2E account must resolve to exactly one identity' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_user FROM iam.login_candidates(p_identifier,'WEB')
     WHERE principal_kind=p_expected_kind;
    IF v_user.account_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'E2E account is not active' USING ERRCODE = '22023';
    END IF;

    IF p_expected_kind='PLATFORM' THEN
        IF v_user.platform_role <> 'SUPER_ADMIN' THEN
            RAISE EXCEPTION 'E2E platform account must be Super Admin' USING ERRCODE = '42501';
        END IF;
        UPDATE platform.platform_user
           SET password_hash=p_password_hash, must_change_password=false,
               failed_attempts=0, locked_until=NULL, updated_at=now(),
               row_version=row_version+1
         WHERE id=v_user.user_id AND status='ACTIVE';
    ELSE
        IF v_user.role_code <> 'ADM' OR v_user.tenant_status <> 'ACTIVE' THEN
            RAISE EXCEPTION 'E2E tenant account must be an active Org Admin' USING ERRCODE = '42501';
        END IF;
        INSERT INTO iam.password_history(tenant_id,user_id,password_hash)
        SELECT v_user.tenant_id,id,password_hash FROM iam.app_user
         WHERE tenant_id=v_user.tenant_id AND id=v_user.user_id
           AND password_hash IS NOT NULL AND password_hash <> p_password_hash;
        UPDATE iam.app_user
           SET password_hash=p_password_hash, password_changed_at=now(),
               must_change_password=false, failed_attempts=0, locked_until=NULL,
               updated_at=now(), row_version=row_version+1
         WHERE tenant_id=v_user.tenant_id AND id=v_user.user_id AND status='ACTIVE';
    END IF;
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    IF v_changed <> 1 THEN RETURN false; END IF;

    UPDATE iam.auth_session
       SET revoked_at=now(), revoked_reason='E2E_PASSWORD_RESET'
     WHERE principal_kind=p_expected_kind AND user_id=v_user.user_id
       AND tenant_id IS NOT DISTINCT FROM v_user.tenant_id AND revoked_at IS NULL;
    RETURN true;
END
$$;
REVOKE ALL ON FUNCTION iam.reset_e2e_account_password(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.reset_e2e_account_password(text,text,text) TO nvs;

CREATE OR REPLACE FUNCTION iam.prepare_auth_session(
    p_kind text, p_user_id uuid, p_tenant_id uuid, p_session_id uuid,
    p_expires_at timestamptz, p_force_logout boolean, p_client_ip text, p_device text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam, cfg AS
$$
DECLARE v_single boolean := false; v_active boolean;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_kind || ':' || coalesce(p_tenant_id::text,'') || ':' || p_user_id::text, 0));
    IF p_kind='TENANT' THEN
        v_single := coalesce((cfg.get_setting('users.single_session', current_date, p_tenant_id)#>>'{}')::boolean, false);
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

CREATE OR REPLACE FUNCTION iam.is_auth_session_active(
    p_kind text, p_user_id uuid, p_tenant_id uuid, p_session_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, iam AS
$$
    SELECT EXISTS (SELECT 1 FROM iam.auth_session s
      WHERE s.principal_kind=p_kind AND s.user_id=p_user_id
        AND s.tenant_id IS NOT DISTINCT FROM p_tenant_id
        AND s.session_id=p_session_id AND s.revoked_at IS NULL AND s.expires_at>now())
$$;

CREATE OR REPLACE FUNCTION iam.revoke_auth_session(
    p_kind text, p_user_id uuid, p_tenant_id uuid, p_session_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, iam AS
$$
DECLARE v_count integer;
BEGIN
    UPDATE iam.auth_session SET revoked_at=now(), revoked_reason='LOGOUT'
     WHERE principal_kind=p_kind AND user_id=p_user_id
       AND tenant_id IS NOT DISTINCT FROM p_tenant_id
       AND session_id=p_session_id AND revoked_at IS NULL;
    GET DIAGNOSTICS v_count=ROW_COUNT;
    RETURN v_count=1;
END
$$;
REVOKE ALL ON FUNCTION iam.prepare_auth_session(text,uuid,uuid,uuid,timestamptz,boolean,text,text),
    iam.is_auth_session_active(text,uuid,uuid,uuid), iam.revoke_auth_session(text,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.prepare_auth_session(text,uuid,uuid,uuid,timestamptz,boolean,text,text),
    iam.is_auth_session_active(text,uuid,uuid,uuid), iam.revoke_auth_session(text,uuid,uuid,uuid) TO nvs_app;
