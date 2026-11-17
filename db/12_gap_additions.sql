-- =============================================================================
-- CFMS 12 - Gap review additions (review of scope v1.7, 15 Nov 2026)
--   2  Data migration traceability (legacy refs, staging rows, exceptions)
--   3  Segregation of duties: cash collector vs reconciler; ADM changes need LDR
--   4  Restricted / corpus fund protection
--   5  Configurable dashboards (widget library, versioned definitions)
--   6  Pending tasks and reassignment
--   7  Background job runs
--   8  Export requests and export audit
--   9  Deposit interest calculated but not yet due
--  10  User preferred language; payment voucher reprint fields
-- Item 1 (indexes) is in 45_indexes_and_search.sql; settings are in 40.
-- Runs before 20 so RLS, touch and audit triggers are applied there. Idempotent.
-- =============================================================================

-- =============================================================================
-- 2. Data migration traceability (Section 39)
-- =============================================================================
ALTER TABLE core.import_batch
    ADD COLUMN IF NOT EXISTS data_area       text,
    ADD COLUMN IF NOT EXISTS is_trial        boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS run_no          integer,
    ADD COLUMN IF NOT EXISTS loaded_count    integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS rejected_count  integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS corrected_count integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS started_at      timestamptz,
    ADD COLUMN IF NOT EXISTS completed_at    timestamptz,
    ADD COLUMN IF NOT EXISTS signed_off_by   uuid,
    ADD COLUMN IF NOT EXISTS signed_off_at   timestamptz;

-- Staged rows: validated here before loading into CFMS tables.
CREATE TABLE IF NOT EXISTS core.import_row (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    import_batch_id uuid NOT NULL,
    row_no          integer NOT NULL,
    data_area       text NOT NULL,                  -- MEMBER, NOMINEE, LOAN, REPAYMENT, OPENING_BALANCE ...
    legacy_ref      text,
    raw_data        jsonb NOT NULL,
    mapped_data     jsonb,
    status          text NOT NULL DEFAULT 'STAGED'
                    CHECK (status IN ('STAGED','VALID','INVALID','LOADED','SKIPPED')),
    errors          jsonb,
    target_table    text,
    target_id       uuid,
    loaded_at       timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, import_batch_id, row_no),
    FOREIGN KEY (tenant_id, import_batch_id) REFERENCES core.import_batch (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS import_row_legacy_idx ON core.import_row (tenant_id, data_area, legacy_ref);

-- Exception list: owned by a named business user, resolved before the final run.
CREATE TABLE IF NOT EXISTS core.import_exception (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    import_batch_id uuid NOT NULL,
    import_row_id   uuid,
    data_area       text NOT NULL,
    legacy_ref      text,
    exception_type  text NOT NULL,                  -- MISSING_DATA, DUPLICATE, VARIANCE, INVALID_VALUE ...
    description     text NOT NULL,
    severity        text NOT NULL DEFAULT 'NORMAL' CHECK (severity IN ('CRITICAL','NORMAL','INFO')),
    owner_user_id   uuid,
    status          text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RESOLVED','ACCEPTED','WONT_FIX')),
    resolution      text,
    resolved_by     uuid,
    resolved_at     timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, import_batch_id) REFERENCES core.import_batch (tenant_id, id),
    FOREIGN KEY (tenant_id, import_row_id) REFERENCES core.import_row (tenant_id, id),
    FOREIGN KEY (tenant_id, owner_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, resolved_by) REFERENCES iam.app_user (tenant_id, id),
    CHECK (status = 'OPEN' OR resolution IS NOT NULL)
);

-- Legacy reference and source batch on every migrated table; legacy_ref is unique
-- per tenant, so re-running an import cannot create duplicates.
DO $$
DECLARE
    t text;
    v_name text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'mbr.member','mbr.member_family','mbr.nominee','mbr.member_identity',
        'loan.loan','loan.loan_guarantor','loan.loan_repayment','loan.loan_default','loan.recovery_case',
        'loan.loan_application_fee',
        'acct.account','acct.cash_receipt','acct.payment_voucher','acct.journal',
        'ops.employee','ops.employee_salary_structure','ops.salary_advance','ops.payroll_run',
        'ops.hall_booking','ops.hall_customer','ops.asset','ops.assistance_application','ops.vendor',
        'core.document']
    LOOP
        v_name := split_part(t, '.', 2);
        EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS legacy_ref text', t);
        EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS import_batch_id uuid', t);
        PERFORM app.add_constraint_if_missing(t::regclass, v_name || '_import_batch_fk',
            'FOREIGN KEY (tenant_id, import_batch_id) REFERENCES core.import_batch (tenant_id, id)');
        EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON %s (tenant_id, legacy_ref) WHERE legacy_ref IS NOT NULL',
                       v_name || '_legacy_uq', t);
    END LOOP;
END
$$;

-- Migrated loans keep original terms and are never recalculated automatically.
ALTER TABLE loan.loan
    ADD COLUMN IF NOT EXISTS is_migrated              boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS migrated_outstanding_principal numeric(18,2),
    ADD COLUMN IF NOT EXISTS migrated_outstanding_interest  numeric(18,2),
    ADD COLUMN IF NOT EXISTS migration_variance_note  text;
DO $$ BEGIN
    PERFORM app.add_constraint_if_missing('loan.loan', 'loan_migrated_needs_ref',
        'CHECK (NOT is_migrated OR legacy_ref IS NOT NULL)');
END $$;

-- =============================================================================
-- 3a. Segregation of duties: the user who collected or paid out cash cannot count,
--     approve or close the same cash account for the same day (Section 3.5).
--     An approved iam.sod_exception (CASH_COLLECT / CASH_RECONCILE) allows it.
-- =============================================================================
CREATE OR REPLACE FUNCTION acct.trg_cash_day_sod()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_user uuid;
BEGIN
    FOREACH v_user IN ARRAY ARRAY[NEW.counted_by, NEW.approved_by, NEW.closed_by]
    LOOP
        CONTINUE WHEN v_user IS NULL;
        CONTINUE WHEN TG_OP = 'UPDATE' AND v_user IN (OLD.counted_by, OLD.approved_by, OLD.closed_by);
        IF (EXISTS (SELECT 1 FROM acct.cash_receipt r
                     WHERE r.tenant_id = NEW.tenant_id AND r.cash_account_id = NEW.cash_account_id
                       AND r.value_date = NEW.business_date AND r.collected_by = v_user)
            OR EXISTS (SELECT 1 FROM acct.payment_voucher p
                        WHERE p.tenant_id = NEW.tenant_id AND p.cash_account_id = NEW.cash_account_id
                          AND p.value_date = NEW.business_date AND p.released_by = v_user))
           AND NOT EXISTS (SELECT 1 FROM iam.sod_exception e
                            WHERE e.tenant_id = NEW.tenant_id AND e.user_id = v_user
                              AND e.role_code_a = 'CASH_COLLECT' AND e.role_code_b = 'CASH_RECONCILE'
                              AND (e.valid_to IS NULL OR e.valid_to >= NEW.business_date)) THEN
            PERFORM app.fail('SOD_CASH_RECONCILE',
                'A user who collected or paid out cash on this day cannot count, approve or close the same cash day');
        END IF;
    END LOOP;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS cash_day_sod ON acct.cash_day;
CREATE TRIGGER cash_day_sod BEFORE INSERT OR UPDATE ON acct.cash_day
    FOR EACH ROW EXECUTE FUNCTION acct.trg_cash_day_sod();

-- =============================================================================
-- 3b. Configuration changes made by ADM take effect only after LDR approval
--     (Section 3.5): custom roles, role privileges and organisation settings.
--     Role assignment to users stays immediate (ADM appoints role holders).
-- =============================================================================
CREATE OR REPLACE FUNCTION iam.user_holds_role(p_user_id uuid, p_role_code text, p_tenant_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT EXISTS (
        SELECT 1 FROM iam.user_role ur
          JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id AND r.status = 'ACTIVE'
         WHERE ur.user_id = p_user_id AND r.role_code = p_role_code
           AND ur.tenant_id = coalesce(p_tenant_id, app.tenant_id())
           AND ur.effective_from <= current_date
           AND (ur.effective_to IS NULL OR ur.effective_to >= current_date))
$$;

CREATE TABLE IF NOT EXISTS iam.access_change_request (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    request_no      text,
    change_type     text NOT NULL CHECK (change_type IN
                    ('ROLE_CREATE','ROLE_UPDATE','ROLE_DEACTIVATE','ROLE_ACTIVATE','PRIVILEGE_GRANT','PRIVILEGE_REVOKE')),
    role_id         uuid,                            -- null only for ROLE_CREATE until applied
    payload         jsonb NOT NULL,                  -- see iam.apply_access_change
    before_state    jsonb,                           -- role and privileges when applied
    reason          text NOT NULL,
    status          text NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED','APPLIED')),
    requested_by    uuid NOT NULL DEFAULT app.user_id(),
    requested_at    timestamptz NOT NULL DEFAULT now(),
    decided_by      uuid,
    decided_at      timestamptz,
    decision_reason text,
    approval_request_id uuid,
    applied_at      timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, requested_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, decided_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    CHECK (change_type = 'ROLE_CREATE' OR role_id IS NOT NULL),
    CHECK (status NOT IN ('APPROVED','REJECTED','APPLIED') OR decided_by IS NOT NULL),
    CHECK (decided_by IS NULL OR decided_by <> requested_by)
);
CREATE INDEX IF NOT EXISTS access_change_request_status_idx ON iam.access_change_request (tenant_id, status);

-- Decider must hold the LDR role; decisions are final.
CREATE OR REPLACE FUNCTION iam.trg_access_change_request_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM app.fail('ACCESS_CHANGE_KEPT', 'Access change requests are kept; cancel instead');
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.status IN ('REJECTED','CANCELLED','APPLIED') AND NEW.status <> OLD.status THEN
            PERFORM app.fail('ACCESS_CHANGE_CLOSED', 'This access change request is already closed');
        END IF;
        IF OLD.status <> 'PENDING' AND (NEW.payload IS DISTINCT FROM OLD.payload OR NEW.change_type <> OLD.change_type) THEN
            PERFORM app.fail('ACCESS_CHANGE_FROZEN', 'A decided request cannot be changed');
        END IF;
    END IF;
    IF NEW.status IN ('APPROVED','REJECTED') AND (TG_OP = 'INSERT' OR OLD.status = 'PENDING') THEN
        IF NOT iam.user_holds_role(NEW.decided_by, 'LDR', NEW.tenant_id) THEN
            PERFORM app.fail('ACCESS_CHANGE_APPROVER', 'Only a Leadership (LDR) user can approve or reject an access change');
        END IF;
        NEW.decided_at := coalesce(NEW.decided_at, now());
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS access_change_request_guard ON iam.access_change_request;
CREATE TRIGGER access_change_request_guard BEFORE INSERT OR UPDATE OR DELETE ON iam.access_change_request
    FOR EACH ROW EXECUTE FUNCTION iam.trg_access_change_request_guard();

-- ADM cannot change roles or role privileges directly; changes go through an
-- approved request applied with iam.apply_access_change().
CREATE OR REPLACE FUNCTION iam.trg_adm_change_needs_approval()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF app.role_code() = 'ADM' AND coalesce(app.setting('app.access_change_request'), '') = '' THEN
        PERFORM app.fail('NEEDS_LDR_APPROVAL',
            'Role and privilege changes by the organisation administrator need Leadership approval (create an access change request)');
    END IF;
    RETURN coalesce(NEW, OLD);
END
$$;
DROP TRIGGER IF EXISTS adm_change_needs_approval ON iam.role;
CREATE TRIGGER adm_change_needs_approval BEFORE INSERT OR UPDATE OR DELETE ON iam.role
    FOR EACH ROW EXECUTE FUNCTION iam.trg_adm_change_needs_approval();
DROP TRIGGER IF EXISTS adm_change_needs_approval ON iam.role_privilege;
CREATE TRIGGER adm_change_needs_approval BEFORE INSERT OR UPDATE OR DELETE ON iam.role_privilege
    FOR EACH ROW EXECUTE FUNCTION iam.trg_adm_change_needs_approval();

-- Apply an approved request. Payload formats:
--   ROLE_CREATE      {"role_code","role_name","description","default_home_module","copy_from_role_id","privileges":[...]}
--   ROLE_UPDATE      {"role_name","description","default_home_module"}   (only keys present are changed)
--   ROLE_DEACTIVATE / ROLE_ACTIVATE  {}
--   PRIVILEGE_GRANT / PRIVILEGE_REVOKE {"privileges":["loan.view", ...]}
CREATE OR REPLACE FUNCTION iam.apply_access_change(p_request_id uuid)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    r       iam.access_change_request;
    v_role  uuid;
    v_priv  text;
    v_before jsonb;
BEGIN
    SELECT * INTO r FROM iam.access_change_request
     WHERE tenant_id = app.tenant_id() AND id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('NOT_FOUND', 'Access change request not found');
    END IF;
    IF r.status <> 'APPROVED' THEN
        PERFORM app.fail('ACCESS_CHANGE_NOT_APPROVED', 'Only an approved access change request can be applied');
    END IF;

    PERFORM set_config('app.access_change_request', r.id::text, true);
    PERFORM app.set_audit_reason(r.reason, 'ACCESS_CHANGE_REQUEST', r.id::text);
    v_role := r.role_id;

    IF v_role IS NOT NULL THEN
        SELECT jsonb_build_object('role', to_jsonb(ro) - 'tenant_id',
                                  'privileges', coalesce((SELECT jsonb_agg(rp.privilege_code ORDER BY rp.privilege_code)
                                                            FROM iam.role_privilege rp
                                                           WHERE rp.tenant_id = ro.tenant_id AND rp.role_id = ro.id), '[]'))
          INTO v_before
          FROM iam.role ro WHERE ro.tenant_id = r.tenant_id AND ro.id = v_role;
    END IF;

    CASE r.change_type
    WHEN 'ROLE_CREATE' THEN
        INSERT INTO iam.role (tenant_id, role_code, role_name, description, role_type, status,
                              default_home_module, copied_from_role_id)
        VALUES (r.tenant_id, r.payload->>'role_code', r.payload->>'role_name', r.payload->>'description',
                'CUSTOM', 'ACTIVE', r.payload->>'default_home_module',
                nullif(r.payload->>'copy_from_role_id','')::uuid)
        RETURNING id INTO v_role;
        IF r.payload ? 'copy_from_role_id' AND NOT r.payload ? 'privileges' THEN
            INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
            SELECT r.tenant_id, v_role, rp.privilege_code FROM iam.role_privilege rp
             WHERE rp.tenant_id = r.tenant_id AND rp.role_id = (r.payload->>'copy_from_role_id')::uuid;
        END IF;
        FOR v_priv IN SELECT jsonb_array_elements_text(coalesce(r.payload->'privileges','[]')) LOOP
            INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
            VALUES (r.tenant_id, v_role, v_priv) ON CONFLICT DO NOTHING;
        END LOOP;
    WHEN 'ROLE_UPDATE' THEN
        UPDATE iam.role SET
            role_name           = coalesce(r.payload->>'role_name', role_name),
            description         = CASE WHEN r.payload ? 'description' THEN r.payload->>'description' ELSE description END,
            default_home_module = CASE WHEN r.payload ? 'default_home_module' THEN r.payload->>'default_home_module'
                                       ELSE default_home_module END
         WHERE tenant_id = r.tenant_id AND id = v_role;
    WHEN 'ROLE_DEACTIVATE' THEN
        UPDATE iam.role SET status = 'INACTIVE' WHERE tenant_id = r.tenant_id AND id = v_role;
    WHEN 'ROLE_ACTIVATE' THEN
        UPDATE iam.role SET status = 'ACTIVE' WHERE tenant_id = r.tenant_id AND id = v_role;
    WHEN 'PRIVILEGE_GRANT' THEN
        FOR v_priv IN SELECT jsonb_array_elements_text(coalesce(r.payload->'privileges','[]')) LOOP
            INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
            VALUES (r.tenant_id, v_role, v_priv) ON CONFLICT DO NOTHING;
        END LOOP;
    WHEN 'PRIVILEGE_REVOKE' THEN
        DELETE FROM iam.role_privilege
         WHERE tenant_id = r.tenant_id AND role_id = v_role
           AND privilege_code IN (SELECT jsonb_array_elements_text(coalesce(r.payload->'privileges','[]')));
    END CASE;

    UPDATE iam.access_change_request
       SET status = 'APPLIED', applied_at = now(), role_id = v_role, before_state = v_before
     WHERE tenant_id = r.tenant_id AND id = r.id;
    PERFORM set_config('app.access_change_request', '', true);
    RETURN v_role;
END
$$;

-- Organisation settings changed by ADM: saved as PENDING_APPROVAL and become
-- ACTIVE only with an LDR approver who is not the requester.
CREATE OR REPLACE FUNCTION cfg.trg_tenant_setting_adm_approval()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF app.role_code() = 'ADM' AND NEW.status = 'ACTIVE'
       AND (TG_OP = 'INSERT' OR OLD.status <> 'ACTIVE' OR NEW.value IS DISTINCT FROM OLD.value) THEN
        IF NEW.approved_by IS NULL OR NEW.approved_by = coalesce(NEW.created_by, app.user_id())
           OR NOT iam.user_holds_role(NEW.approved_by, 'LDR', NEW.tenant_id) THEN
            PERFORM app.fail('NEEDS_LDR_APPROVAL',
                'Settings changed by the organisation administrator take effect only after Leadership approval');
        END IF;
        NEW.approved_at := coalesce(NEW.approved_at, now());
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS tenant_setting_adm_approval ON cfg.tenant_setting;
CREATE TRIGGER tenant_setting_adm_approval BEFORE INSERT OR UPDATE ON cfg.tenant_setting
    FOR EACH ROW EXECUTE FUNCTION cfg.trg_tenant_setting_adm_approval();

-- An LDR user approves a pending setting (the approver's own session).
CREATE OR REPLACE FUNCTION cfg.approve_tenant_setting(p_setting_id uuid, p_approve boolean, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE s cfg.tenant_setting;
BEGIN
    SELECT * INTO s FROM cfg.tenant_setting WHERE tenant_id = app.tenant_id() AND id = p_setting_id FOR UPDATE;
    IF NOT FOUND OR s.status <> 'PENDING_APPROVAL' THEN
        PERFORM app.fail('NOT_PENDING', 'Setting change is not awaiting approval');
    END IF;
    IF NOT iam.user_holds_role(app.user_id(), 'LDR') OR app.user_id() = s.created_by THEN
        PERFORM app.fail('NEEDS_LDR_APPROVAL', 'Only a Leadership user other than the requester can decide this change');
    END IF;
    PERFORM app.set_audit_reason(coalesce(p_reason, s.reason), 'TENANT_SETTING', s.id::text);
    UPDATE cfg.tenant_setting
       SET status = CASE WHEN p_approve THEN 'ACTIVE' ELSE 'REJECTED' END,
           approved_by = app.user_id(), approved_at = now()
     WHERE tenant_id = s.tenant_id AND id = s.id;
END
$$;

-- =============================================================================
-- 4. Restricted and corpus funds (Section 20.3)
--    Fund balance = credits - debits on FUND, INCOME and EXPENSE lines tagged with
--    the fund. A posted journal may not take a RESTRICTED or CORPUS fund below
--    zero, and where allowed accounts are listed for a fund, its spending lines
--    must use one of them (the fund's stated purpose).
-- =============================================================================
CREATE TABLE IF NOT EXISTS acct.fund_allowed_account (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    fund_id     uuid NOT NULL,
    account_id  uuid NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, fund_id, account_id),
    FOREIGN KEY (tenant_id, fund_id) REFERENCES acct.fund (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE OR REPLACE VIEW acct.v_fund_balance AS
SELECT f.tenant_id, f.id AS fund_id, f.code, f.name, f.fund_type,
       coalesce(sum(l.credit - l.debit) FILTER (WHERE a.account_type IN ('FUND','INCOME','EXPENSE')
                                                  AND j.status IN ('POSTED','REVERSED')), 0) AS balance,
       coalesce(sum(l.credit) FILTER (WHERE a.account_type IN ('FUND','INCOME') AND j.status IN ('POSTED','REVERSED')), 0) AS total_in,
       coalesce(sum(l.debit)  FILTER (WHERE a.account_type = 'EXPENSE' AND j.status IN ('POSTED','REVERSED')), 0) AS total_spent
  FROM acct.fund f
  LEFT JOIN acct.journal_line l ON l.tenant_id = f.tenant_id AND l.fund_id = f.id
  LEFT JOIN acct.journal j      ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
  LEFT JOIN acct.account a      ON a.tenant_id = l.tenant_id AND a.id = l.account_id
 GROUP BY f.tenant_id, f.id, f.code, f.name, f.fund_type;

CREATE OR REPLACE FUNCTION acct.trg_journal_fund_check()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_journal_id uuid;
    v_tenant     uuid;
    v_status     text;
    f            record;
BEGIN
    IF TG_TABLE_NAME = 'journal' THEN
        v_journal_id := NEW.id; v_tenant := NEW.tenant_id;
    ELSE
        v_journal_id := coalesce(NEW.journal_id, OLD.journal_id);
        v_tenant := coalesce(NEW.tenant_id, OLD.tenant_id);
    END IF;
    SELECT status INTO v_status FROM acct.journal WHERE tenant_id = v_tenant AND id = v_journal_id;
    IF v_status <> 'POSTED' THEN
        RETURN NULL;
    END IF;

    FOR f IN
        SELECT DISTINCT fd.id, fd.code, fd.fund_type
          FROM acct.journal_line l
          JOIN acct.fund fd ON fd.tenant_id = l.tenant_id AND fd.id = l.fund_id
         WHERE l.tenant_id = v_tenant AND l.journal_id = v_journal_id
           AND fd.fund_type IN ('RESTRICTED','CORPUS')
    LOOP
        -- purpose: spending lines must use an allowed account when a list exists
        IF EXISTS (SELECT 1 FROM acct.fund_allowed_account x WHERE x.tenant_id = v_tenant AND x.fund_id = f.id)
           AND EXISTS (SELECT 1 FROM acct.journal_line l
                         JOIN acct.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
                        WHERE l.tenant_id = v_tenant AND l.journal_id = v_journal_id AND l.fund_id = f.id
                          AND a.account_type = 'EXPENSE' AND l.debit > 0
                          AND NOT EXISTS (SELECT 1 FROM acct.fund_allowed_account x
                                           WHERE x.tenant_id = v_tenant AND x.fund_id = f.id AND x.account_id = l.account_id)) THEN
            PERFORM app.fail('FUND_PURPOSE',
                format('Fund %s can only be spent on its allowed accounts (its stated purpose)', f.code));
        END IF;
        IF (SELECT b.balance FROM acct.v_fund_balance b WHERE b.tenant_id = v_tenant AND b.fund_id = f.id) < 0 THEN
            PERFORM app.fail('FUND_INSUFFICIENT',
                format('%s fund %s does not have enough balance for this posting', initcap(f.fund_type), f.code));
        END IF;
    END LOOP;
    RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS journal_fund_check ON acct.journal;
CREATE CONSTRAINT TRIGGER journal_fund_check AFTER INSERT OR UPDATE ON acct.journal
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION acct.trg_journal_fund_check();
DROP TRIGGER IF EXISTS journal_line_fund_check ON acct.journal_line;
CREATE CONSTRAINT TRIGGER journal_line_fund_check AFTER INSERT OR UPDATE ON acct.journal_line
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION acct.trg_journal_fund_check();

-- =============================================================================
-- 5. Configurable dashboards (Sections 3.8, 32)
-- =============================================================================
-- Approved widget library (new widget types need development).
CREATE TABLE IF NOT EXISTS platform.widget_type (
    widget_code   text PRIMARY KEY,
    name          text NOT NULL,
    category      text NOT NULL CHECK (category IN ('COUNT','LIST','CHART','KPI','PENDING_TASKS')),
    description   text,
    config_schema jsonb NOT NULL DEFAULT '{}',
    status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_at    timestamptz,
    updated_by    uuid,
    row_version   integer NOT NULL DEFAULT 1
);

-- Named data sources a widget can read; each belongs to a module, so a widget is
-- shown only when the user can view that module.
CREATE TABLE IF NOT EXISTS platform.dashboard_data_source (
    source_code   text PRIMARY KEY,
    name          text NOT NULL,
    module_code   text NOT NULL REFERENCES platform.module (module_code),
    description   text,
    params_schema jsonb NOT NULL DEFAULT '{}',
    status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_at    timestamptz,
    updated_by    uuid,
    row_version   integer NOT NULL DEFAULT 1
);

-- Platform default layout per dashboard module (copied into each organisation).
CREATE TABLE IF NOT EXISTS platform.dashboard_template (
    module_code   text PRIMARY KEY REFERENCES platform.module (module_code),
    version_no    integer NOT NULL DEFAULT 1,
    definition    jsonb NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_at    timestamptz,
    updated_by    uuid,
    row_version   integer NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS cfg.dashboard_definition (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    module_code   text NOT NULL REFERENCES platform.module (module_code),
    name          text NOT NULL,
    status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
    template_version integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, module_code)
);

CREATE TABLE IF NOT EXISTS cfg.dashboard_version (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    dashboard_definition_id uuid NOT NULL,
    version_no     integer NOT NULL,
    status         text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','RETIRED','DISCARDED')),
    definition     jsonb NOT NULL,             -- {"widgets":[{"widget":"COUNT","source":"...","title":"...","position":{...}}]}
    checksum       text GENERATED ALWAYS AS (md5(definition::text)) STORED,
    effective_from date,
    reason         text NOT NULL,
    published_by   uuid,
    published_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, dashboard_definition_id, version_no),
    FOREIGN KEY (tenant_id, dashboard_definition_id) REFERENCES cfg.dashboard_definition (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS dashboard_version_one_published
    ON cfg.dashboard_version (tenant_id, dashboard_definition_id) WHERE status = 'PUBLISHED';

-- Published versions are immutable; every widget and source must exist and be active.
CREATE OR REPLACE FUNCTION cfg.trg_dashboard_version_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE w jsonb;
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM app.fail('VERSION_IMMUTABLE', 'Dashboard versions are never deleted (discard a draft instead)');
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status IN ('PUBLISHED','RETIRED','DISCARDED')
       AND (NEW.definition IS DISTINCT FROM OLD.definition OR NEW.version_no <> OLD.version_no
            OR NOT (NEW.status = OLD.status OR (OLD.status = 'PUBLISHED' AND NEW.status = 'RETIRED'))) THEN
        PERFORM app.fail('VERSION_IMMUTABLE', 'A published dashboard version cannot be changed; create a new version');
    END IF;
    IF NEW.status = 'PUBLISHED' AND (TG_OP = 'INSERT' OR OLD.status <> 'PUBLISHED') THEN
        IF jsonb_typeof(NEW.definition->'widgets') IS DISTINCT FROM 'array' THEN
            PERFORM app.fail('INVALID_DOCUMENT', 'Dashboard definition needs a "widgets" array');
        END IF;
        FOR w IN SELECT jsonb_array_elements(NEW.definition->'widgets') LOOP
            IF NOT EXISTS (SELECT 1 FROM platform.widget_type t WHERE t.widget_code = w->>'widget' AND t.status = 'ACTIVE') THEN
                PERFORM app.fail('INVALID_DOCUMENT', format('Unknown widget type %s', w->>'widget'));
            END IF;
            IF w ? 'source' AND NOT EXISTS (SELECT 1 FROM platform.dashboard_data_source s
                                             WHERE s.source_code = w->>'source' AND s.status = 'ACTIVE') THEN
                PERFORM app.fail('INVALID_DOCUMENT', format('Unknown data source %s', w->>'source'));
            END IF;
        END LOOP;
        NEW.published_at   := coalesce(NEW.published_at, now());
        NEW.published_by   := coalesce(NEW.published_by, app.platform_user_id());
        NEW.effective_from := coalesce(NEW.effective_from, app.tenant_today(NEW.tenant_id));
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS dashboard_version_guard ON cfg.dashboard_version;
CREATE TRIGGER dashboard_version_guard BEFORE INSERT OR UPDATE OR DELETE ON cfg.dashboard_version
    FOR EACH ROW EXECUTE FUNCTION cfg.trg_dashboard_version_guard();

-- Copy platform dashboard templates into an organisation (called by provisioning
-- and safe to call again; only missing dashboards are added).
CREATE OR REPLACE FUNCTION platform.apply_dashboard_templates(p_tenant_id uuid)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    t     record;
    v_def uuid;
    v_n   integer := 0;
BEGIN
    FOR t IN
        SELECT dt.module_code, dt.version_no, dt.definition, m.module_name
          FROM platform.dashboard_template dt
          JOIN platform.module m ON m.module_code = dt.module_code
          JOIN platform.tenant_module tm ON tm.tenant_id = p_tenant_id AND tm.module_code = dt.module_code AND tm.is_enabled
         WHERE NOT EXISTS (SELECT 1 FROM cfg.dashboard_definition d
                            WHERE d.tenant_id = p_tenant_id AND d.module_code = dt.module_code)
    LOOP
        INSERT INTO cfg.dashboard_definition (tenant_id, module_code, name, template_version)
        VALUES (p_tenant_id, t.module_code, t.module_name, t.version_no)
        RETURNING id INTO v_def;
        INSERT INTO cfg.dashboard_version (tenant_id, dashboard_definition_id, version_no, status, definition,
                                           effective_from, reason)
        VALUES (p_tenant_id, v_def, 1, 'PUBLISHED', t.definition, DATE '2000-01-01',
                'Default from dashboard template v' || t.version_no);
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END
$$;

-- =============================================================================
-- 6. Pending tasks and reassignment (Section 3.6)
-- =============================================================================
CREATE TABLE IF NOT EXISTS wf.task (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    task_type        text NOT NULL CHECK (task_type IN
                     ('WORKFLOW_STEP','APPROVAL','RETURNED_ITEM','OFFLINE_RECORDING','RECOVERY_FOLLOW_UP',
                      'DOCUMENT_PENDING','MANUAL_ACTION','OTHER')),
    title            text NOT NULL,
    entity_type      text,
    entity_id        uuid,
    business_ref     text,
    workflow_instance_id uuid,
    approval_request_id  uuid,
    action_execution_id  uuid,
    assigned_role_id uuid,
    assigned_user_id uuid,
    due_date         date,
    priority         text NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('HIGH','NORMAL','LOW')),
    status           text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','DONE','CANCELLED')),
    completed_at     timestamptz,
    completed_by     uuid,
    cancel_reason    text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, action_execution_id) REFERENCES wf.action_execution (tenant_id, id),
    FOREIGN KEY (tenant_id, assigned_role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, assigned_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, completed_by) REFERENCES iam.app_user (tenant_id, id),
    CHECK (assigned_role_id IS NOT NULL OR assigned_user_id IS NOT NULL),
    CHECK (status <> 'CANCELLED' OR cancel_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS task_open_user_idx ON wf.task (tenant_id, assigned_user_id) WHERE status IN ('OPEN','IN_PROGRESS');
CREATE INDEX IF NOT EXISTS task_open_role_idx ON wf.task (tenant_id, assigned_role_id) WHERE status IN ('OPEN','IN_PROGRESS');
CREATE INDEX IF NOT EXISTS task_entity_idx ON wf.task (tenant_id, entity_type, entity_id);

CREATE TABLE IF NOT EXISTS wf.task_reassignment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    task_id        uuid NOT NULL,
    from_user_id   uuid,
    to_user_id     uuid,
    from_role_id   uuid,
    to_role_id     uuid,
    reason         text NOT NULL,
    reassigned_by  uuid NOT NULL DEFAULT app.user_id(),
    reassigned_at  timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, task_id) REFERENCES wf.task (tenant_id, id),
    FOREIGN KEY (tenant_id, from_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, to_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, from_role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, to_role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, reassigned_by) REFERENCES iam.app_user (tenant_id, id)
);

-- A task can be assigned only to an active user with web or mobile access
-- (record-only users cannot act); every reassignment is logged.
CREATE OR REPLACE FUNCTION wf.trg_task_guard()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.assigned_user_id IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id)
       AND NOT EXISTS (SELECT 1 FROM iam.app_user u
                        WHERE u.tenant_id = NEW.tenant_id AND u.id = NEW.assigned_user_id
                          AND u.status = 'ACTIVE' AND (u.web_access OR u.mobile_access)) THEN
        PERFORM app.fail('TASK_ASSIGNEE', 'Tasks can only be assigned to an active user with web or mobile access');
    END IF;
    IF TG_OP = 'UPDATE'
       AND (NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id OR NEW.assigned_role_id IS DISTINCT FROM OLD.assigned_role_id) THEN
        IF OLD.status IN ('DONE','CANCELLED') THEN
            PERFORM app.fail('TASK_CLOSED', 'A completed or cancelled task cannot be reassigned');
        END IF;
        INSERT INTO wf.task_reassignment (tenant_id, task_id, from_user_id, to_user_id, from_role_id, to_role_id, reason)
        VALUES (NEW.tenant_id, NEW.id, OLD.assigned_user_id, NEW.assigned_user_id, OLD.assigned_role_id, NEW.assigned_role_id,
                coalesce(nullif(app.setting('app.reason'), ''), 'Reassigned'));
    END IF;
    IF NEW.status = 'DONE' AND (TG_OP = 'INSERT' OR OLD.status <> 'DONE') THEN
        NEW.completed_at := coalesce(NEW.completed_at, now());
        NEW.completed_by := coalesce(NEW.completed_by, app.user_id());
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS task_guard ON wf.task;
CREATE TRIGGER task_guard BEFORE INSERT OR UPDATE ON wf.task
    FOR EACH ROW EXECUTE FUNCTION wf.trg_task_guard();

-- Move all open tasks of one user to another (employee or manager replacement).
CREATE OR REPLACE FUNCTION wf.reassign_open_tasks(p_from_user uuid, p_to_user uuid, p_reason text)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE v_n integer;
BEGIN
    IF coalesce(p_reason, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required to reassign tasks');
    END IF;
    PERFORM app.set_audit_reason(p_reason, 'TASK_REASSIGNMENT', p_from_user::text);
    UPDATE wf.task SET assigned_user_id = p_to_user
     WHERE tenant_id = app.tenant_id() AND assigned_user_id = p_from_user AND status IN ('OPEN','IN_PROGRESS');
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END
$$;

-- =============================================================================
-- 7. Background jobs (Section 35.12, Administration Dashboard)
-- =============================================================================
CREATE TABLE IF NOT EXISTS platform.job_definition (
    job_code         text PRIMARY KEY,
    name             text NOT NULL,
    description      text,
    module_code      text REFERENCES platform.module (module_code),
    default_schedule text NOT NULL,           -- cron expression, evaluated in the tenant's time zone
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz,
    updated_by       uuid,
    row_version      integer NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS platform.job_run (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    job_code          text NOT NULL REFERENCES platform.job_definition (job_code),
    working_date      date,
    scheduled_for     timestamptz,
    started_at        timestamptz,
    completed_at      timestamptz,
    status            text NOT NULL DEFAULT 'QUEUED'
                      CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','PARTIAL','FAILED','CANCELLED')),
    triggered_by      text NOT NULL DEFAULT 'SCHEDULE' CHECK (triggered_by IN ('SCHEDULE','USER','SUPER_ADMIN','SYSTEM')),
    triggered_by_user_id uuid,
    records_processed integer NOT NULL DEFAULT 0,
    records_failed    integer NOT NULL DEFAULT 0,
    error_message     text,
    details           jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS job_run_recent_idx ON platform.job_run (tenant_id, job_code, started_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS job_run_one_per_day_uq
    ON platform.job_run (tenant_id, job_code, working_date) WHERE status IN ('QUEUED','RUNNING','SUCCEEDED');

-- =============================================================================
-- 8. Export requests and export audit (Section 36, Export)
-- =============================================================================
CREATE TABLE IF NOT EXISTS core.export_request (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    requested_by    uuid NOT NULL DEFAULT app.user_id(),
    role_code       text DEFAULT app.role_code(),
    module_code     text REFERENCES platform.module (module_code),
    screen_code     text NOT NULL,                  -- list, report or statement identifier
    export_kind     text NOT NULL CHECK (export_kind IN ('LIST','REPORT','STATEMENT','AUDIT_LOG','DASHBOARD')),
    format          text NOT NULL CHECK (format IN ('XLSX','PDF','CSV')),
    filters         jsonb NOT NULL DEFAULT '{}',
    columns         jsonb,
    sort_order      jsonb,
    is_sensitive    boolean NOT NULL DEFAULT false, -- payroll, personal data, full member lists
    privilege_code  text REFERENCES platform.privilege (privilege_code),
    run_in_background boolean NOT NULL DEFAULT false,
    status          text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','RUNNING','READY','FAILED','EXPIRED')),
    row_count       integer,
    document_id     uuid,
    requested_at    timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    expires_at      timestamptz,
    error_message   text,
    channel         text DEFAULT nullif(app.setting('app.channel'), ''),
    ip_address      inet DEFAULT nullif(app.setting('app.client_ip'), '')::inet,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, requested_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES core.document (tenant_id, id),
    CHECK (NOT is_sensitive OR privilege_code IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS export_request_user_idx ON core.export_request (tenant_id, requested_by, requested_at DESC);

-- Sensitive exports need the export privilege held by the requester.
CREATE OR REPLACE FUNCTION core.trg_export_request_check()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.privilege_code IS NOT NULL AND NOT iam.has_privilege(NEW.requested_by, NEW.privilege_code) THEN
        PERFORM app.fail('EXPORT_NOT_PERMITTED', format('Export needs privilege %s', NEW.privilege_code));
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS export_request_check ON core.export_request;
CREATE TRIGGER export_request_check BEFORE INSERT ON core.export_request
    FOR EACH ROW EXECUTE FUNCTION core.trg_export_request_check();

-- =============================================================================
-- 9. Deposit interest calculated monthly (memo only; posted when credited or paid)
-- =============================================================================
CREATE TABLE IF NOT EXISTS dep.deposit_interest_calc (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    deposit_account_id uuid NOT NULL,
    calc_month        date NOT NULL CHECK (calc_month = date_trunc('month', calc_month)::date),
    period_from       date NOT NULL,
    period_to         date NOT NULL,
    principal_basis   numeric(18,2) NOT NULL,
    rate_annual       numeric(9,4) NOT NULL,
    day_count_days    integer NOT NULL,
    amount_unrounded  numeric(20,6) NOT NULL,
    amount            numeric(18,2) NOT NULL,
    status            text NOT NULL DEFAULT 'CALCULATED'
                      CHECK (status IN ('CALCULATED','CREDITED','PAID','FORFEITED','REVERSED')),
    deposit_transaction_id uuid,
    rule_set_version_id uuid,
    job_run_id        uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, deposit_account_id, calc_month),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_transaction_id) REFERENCES dep.deposit_transaction (tenant_id, id),
    FOREIGN KEY (tenant_id, job_run_id) REFERENCES platform.job_run (tenant_id, id),
    CHECK (period_to >= period_from),
    CHECK (status NOT IN ('CREDITED','PAID') OR deposit_transaction_id IS NOT NULL)
);

-- =============================================================================
-- 10. User preferred language; payment voucher reprint fields
-- =============================================================================
ALTER TABLE iam.app_user ADD COLUMN IF NOT EXISTS preferred_language text NOT NULL DEFAULT 'en';
ALTER TABLE acct.payment_voucher
    ADD COLUMN IF NOT EXISTS last_printed_at timestamptz,
    ADD COLUMN IF NOT EXISTS last_printed_by uuid;
