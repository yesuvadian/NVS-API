-- =============================================================================
-- CFMS / NVS  -  31b  Overview dashboard summaries
-- -----------------------------------------------------------------------------
-- Run as nvs after 31a. Safe to re-run.
--
--   platform.get_platform_summary()        -> organisation counts + 5 newest
--   core.get_tenant_summary(sections[])    -> live counts for the tenant
--                                             Overview, under signed context
--
-- Both are SECURITY INVOKER: row-level security limits the tenant summary to
-- the signed tenant, and the platform summary refuses any non-platform scope.
-- =============================================================================

CREATE OR REPLACE FUNCTION platform.get_platform_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_counts jsonb;
    v_newest jsonb;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE THEN
        PERFORM app.fail('PLATFORM_CONTEXT_REQUIRED', 'A valid platform administrator context is required');
    END IF;

    SELECT jsonb_build_object(
               'total',        count(*),
               'ACTIVE',       count(*) FILTER (WHERE t.status = 'ACTIVE'),
               'PROVISIONING', count(*) FILTER (WHERE t.status = 'PROVISIONING'),
               'SUSPENDED',    count(*) FILTER (WHERE t.status = 'SUSPENDED'),
               'CLOSED',       count(*) FILTER (WHERE t.status = 'CLOSED'))
      INTO v_counts
      FROM platform.tenant t;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'id', n.id, 'code', n.code, 'name', n.name,
               'status', n.status, 'created_at', n.created_at)
             ORDER BY n.created_at DESC, n.name), '[]'::jsonb)
      INTO v_newest
      FROM (SELECT t.id, t.code, t.name, t.status, t.created_at
              FROM platform.tenant t
             ORDER BY t.created_at DESC, t.name
             LIMIT 5) n;

    RETURN jsonb_build_object(
        'organisations', jsonb_build_object(
            'total',  (v_counts->>'total')::integer,
            'by_status', jsonb_build_object(
                'ACTIVE',       (v_counts->>'ACTIVE')::integer,
                'PROVISIONING', (v_counts->>'PROVISIONING')::integer,
                'SUSPENDED',    (v_counts->>'SUSPENDED')::integer,
                'CLOSED',       (v_counts->>'CLOSED')::integer)),
        'newest_organisations', v_newest);
END
$$;
REVOKE ALL ON FUNCTION platform.get_platform_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.get_platform_summary() TO nvs_app;

-- p_sections chooses which parts to compute; the API passes only the sections
-- the user may see: 'members' (member.view), 'loans' (loan.view),
-- 'approvals' (loan.approve), 'collections' (loan_repay.view).
-- Sections the tenant has no data for return zeros.
CREATE OR REPLACE FUNCTION core.get_tenant_summary(p_sections text[])
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_result jsonb := '{}'::jsonb;
    v_today  date;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.tenant_id() IS NULL THEN
        PERFORM app.fail('NO_PRIVILEGE', 'A signed organisation context is required');
    END IF;
    v_today := app.working_date();

    IF 'members' = ANY (p_sections) THEN
        v_result := v_result || jsonb_build_object('members', (
            SELECT jsonb_build_object(
                       'total',  count(*),
                       'active', count(*) FILTER (WHERE m.status = 'ACTIVE'))
              FROM mbr.member m
             WHERE m.tenant_id = app.tenant_id()));
    END IF;

    IF 'loans' = ANY (p_sections) THEN
        -- Applications still in progress: not yet disbursed and not closed
        -- by rejection, withdrawal or cancellation.
        v_result := v_result || jsonb_build_object('loans', (
            SELECT jsonb_build_object('open_applications', count(*))
              FROM loan.loan l
             WHERE l.tenant_id = app.tenant_id()
               AND l.status IN ('DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED','APPROVED')));
    END IF;

    IF 'approvals' = ANY (p_sections) THEN
        -- Same rules as loan.get_approval_inbox, counted.
        v_result := v_result || jsonb_build_object('approvals', (
            SELECT jsonb_build_object('pending', count(*))
              FROM wf.approval_request ar
              JOIN loan.loan l ON l.tenant_id = ar.tenant_id AND l.id = ar.entity_id
             WHERE ar.tenant_id = app.tenant_id()
               AND ar.entity_type = 'loan.loan' AND ar.status = 'PENDING'
               AND ar.requested_by <> app.user_id()
               AND EXISTS (
                   SELECT 1 FROM iam.user_role ur
                   JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
                    WHERE ur.tenant_id = ar.tenant_id AND ur.role_id = ar.required_role_id
                      AND ur.user_id = app.user_id()
                      AND r.role_code = app.role_code() AND r.status = 'ACTIVE'
                      AND ur.effective_from <= v_today
                      AND (ur.effective_to IS NULL OR ur.effective_to >= v_today))));
    END IF;

    IF 'collections' = ANY (p_sections) THEN
        v_result := v_result || jsonb_build_object('collections', (
            SELECT jsonb_build_object(
                       'date',   v_today,
                       'count',  count(*),
                       'amount', coalesce(sum(r.amount), 0))
              FROM loan.loan_repayment r
             WHERE r.tenant_id = app.tenant_id()
               AND r.value_date = v_today
               AND r.status = 'POSTED'));
    END IF;

    RETURN v_result || jsonb_build_object('working_date', v_today);
END
$$;
REVOKE ALL ON FUNCTION core.get_tenant_summary(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.get_tenant_summary(text[]) TO nvs_app;
