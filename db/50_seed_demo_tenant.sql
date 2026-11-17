-- =============================================================================
-- CFMS / NVS  -  50  OPTIONAL demo data for local development
-- -----------------------------------------------------------------------------
-- Run as nvs after 40. Safe to re-run (skips if the demo tenant exists).
-- Creates: a Platform Super Administrator, a demo organisation "demo" with the
-- common optional modules, its default org admin, one user per standard role
-- (with web / mobile / record-only examples) and two members.
-- Do NOT run this in production.
-- =============================================================================

DO $$
DECLARE
    v_super  uuid;
    v_tenant uuid;
    v_user   uuid;
    r        record;
BEGIN
    INSERT INTO platform.platform_user (full_name, email, mobile, platform_role, mfa_enabled)
    VALUES ('Platform Super Admin', 'superadmin@example.com', '9000000000', 'SUPER_ADMIN', false)
    ON CONFLICT DO NOTHING;
    -- MFA bypass is for this optional local-only demo account, never production.
    UPDATE platform.platform_user SET mfa_enabled = false
     WHERE lower(email) = 'superadmin@example.com';
    SELECT id INTO v_super FROM platform.platform_user WHERE lower(email) = 'superadmin@example.com';

    IF EXISTS (SELECT 1 FROM platform.tenant WHERE code = 'demo') THEN
        RAISE NOTICE 'Demo tenant already exists - skipped';
        RETURN;
    END IF;

    v_tenant := platform.provision_tenant(
        p_code             => 'demo',
        p_name             => 'Demo Community Trust',
        p_admin_name       => 'Demo Org Admin',
        p_admin_mobile     => '9000000001',
        p_admin_email      => 'admin@demo.example.com',
        p_optional_modules => ARRAY['LOAN','LOAN_FEE','LOAN_REPAY','LOAN_SETTLE','LOAN_DEFAULT','NOMINEE','DECEASED',
                                    'ASSIST_EDU','ASSIST_CREM','BDAY_GRANT','EXPENSE','PAYROLL','HALL','ASSET',
                                    'ASSET_PURCHASE','ASSET_MAINT','ASSET_DISPOSAL','MGMT_REPORT','CONTRIB'],
        p_platform_user_id => v_super);

    -- act as the org admin of the demo tenant
    PERFORM app.set_context(
        p_tenant_id => v_tenant,
        p_user_id => (SELECT id FROM iam.app_user WHERE tenant_id = v_tenant AND is_default_org_admin),
        p_role_code => 'ADM', p_channel => 'WEB', p_working_date => NULL,
        p_client_ip => NULL, p_device => NULL, p_is_local => true, p_signature => NULL);

    FOR r IN SELECT * FROM (VALUES
        ('Demo Employee',   '9000000011', 'emp@demo.example.com', 'EMP', true,  true),
        ('Demo Manager',    '9000000012', 'mgr@demo.example.com', 'MGR', true,  true),
        ('Demo Accountant', '9000000013', 'acc@demo.example.com', 'ACC', true,  false),
        ('Demo Leader',     '9000000014', NULL,                   'LDR', false, false),   -- record-only (offline approvals)
        ('Demo Auditor',    '9000000015', 'aud@demo.example.com', 'AUD', true,  false)
      ) AS u(full_name, mobile, email, role_code, web, mob)
    LOOP
        INSERT INTO iam.app_user (tenant_id, full_name, mobile, email, web_access, mobile_access, username, primary_role_id)
        VALUES (v_tenant, r.full_name, r.mobile, r.email, r.web, r.mob,
                CASE WHEN r.web OR r.mob THEN coalesce(r.email, r.mobile) END,
                (SELECT id FROM iam.role WHERE tenant_id = v_tenant AND role_code = r.role_code))
        RETURNING id INTO v_user;
        INSERT INTO iam.user_role (tenant_id, user_id, role_id, reason)
        VALUES (v_tenant, v_user, (SELECT id FROM iam.role WHERE tenant_id = v_tenant AND role_code = r.role_code), 'Demo data');
    END LOOP;

    INSERT INTO mbr.member (tenant_id, member_no, full_name, date_of_birth, gender, mobile, city, state,
                            membership_date, status, status_effective_date)
    VALUES (v_tenant, acct.next_number('MEMBER', NULL, v_tenant), 'Ravi Kumar', '1980-05-14', 'MALE', '9100000001',
            'Chennai', 'Tamil Nadu', '2020-01-10', 'ACTIVE', '2020-01-10'),
           (v_tenant, acct.next_number('MEMBER', NULL, v_tenant), 'Lakshmi Devi', '1975-11-02', 'FEMALE', '9100000002',
            'Chennai', 'Tamil Nadu', '2019-06-01', 'ACTIVE', '2019-06-01');

    PERFORM app.clear_context();
    RAISE NOTICE 'Demo tenant created: %', v_tenant;
END
$$;
