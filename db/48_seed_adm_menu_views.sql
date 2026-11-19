-- =============================================================================
-- CFMS / NVS  -  48  Org Admin sees every tenant menu (view only)
-- -----------------------------------------------------------------------------
-- Run as nvs after 40-47. Safe to re-run.
--
-- The System Administrator (ADM) gets the view privilege of each module that
-- has a tenant menu item: Members, Loans, Collections (loan repayments) and
-- Reports. Approvals is already viewable. ADM gets no create/edit/approve on
-- these business modules, so maker-checker separation is unchanged.
--
-- 1. Role template (used when a new organisation is provisioned).
-- 2. Each existing organisation's ADM role, where the module is enabled and the
--    privilege is within the Super Admin's ceiling (the role_privilege trigger
--    enforces both). iam.role_privilege has forced row-level security, so each
--    organisation is updated under its own context.
-- =============================================================================

INSERT INTO platform.role_template_privilege (role_code, privilege_code)
SELECT 'ADM', p.privilege_code
  FROM platform.privilege p
 WHERE p.privilege_code IN ('member.view', 'loan.view', 'loan_repay.view', 'fin_report.view')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    t record;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        -- System context (no role): this is a platform seed, not an Org Admin change,
        -- so it does not go through the access-change approval for ADM.
        PERFORM app.set_context(t.id, NULL, NULL, 'WEB', NULL, NULL, NULL, true, NULL);

        -- The ceiling already holds these privileges (other standard roles use
        -- them); add them for organisations provisioned before they existed.
        INSERT INTO platform.tenant_privilege_ceiling (tenant_id, privilege_code, reason)
        SELECT t.id, rtp.privilege_code, 'Org Admin menu view privileges (48)'
          FROM platform.role_template_privilege rtp
         WHERE rtp.role_code = 'ADM'
           AND rtp.privilege_code IN ('member.view', 'loan.view', 'loan_repay.view', 'fin_report.view')
           AND NOT EXISTS (SELECT 1 FROM platform.tenant_privilege_ceiling c
                            WHERE c.tenant_id = t.id AND c.privilege_code = rtp.privilege_code);

        INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
        SELECT t.id, r.id, p.privilege_code
          FROM iam.role r
          JOIN platform.privilege p
            ON p.privilege_code IN ('member.view', 'loan.view', 'loan_repay.view', 'fin_report.view')
          JOIN platform.tenant_module tm
            ON tm.tenant_id = t.id AND tm.module_code = p.module_code AND tm.is_enabled
         WHERE r.tenant_id = t.id AND r.role_code = 'ADM'
        ON CONFLICT (tenant_id, role_id, privilege_code) DO NOTHING;
    END LOOP;
    PERFORM app.clear_context();
END
$$;
