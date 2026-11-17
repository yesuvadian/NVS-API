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
CREATE OR REPLACE FUNCTION iam.get_tenant_access(
    p_tenant_id uuid, p_user_id uuid, p_role_code text,
    p_working_date date, p_channel text)
RETURNS TABLE (status text, web_access boolean, mobile_access boolean, requires_mfa boolean)
LANGUAGE sql STABLE AS
$$
    SELECT u.status, u.web_access, u.mobile_access, r.requires_mfa
      FROM iam.app_user u
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
