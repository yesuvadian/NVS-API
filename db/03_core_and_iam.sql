-- =============================================================================
-- CFMS / NVS  -  03  Core shared tables, users, roles and privileges
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Every tenant-owned table: id uuid PK, tenant_id NOT NULL, UNIQUE (tenant_id,id)
-- and foreign keys that include tenant_id, so a row can never point at another
-- tenant's row.
-- =============================================================================

-- Branches (single default branch per tenant; multi-branch is future scope) -------
CREATE TABLE IF NOT EXISTS core.branch (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code         text NOT NULL,
    name         text NOT NULL,
    address      jsonb,
    is_default   boolean NOT NULL DEFAULT false,
    status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code)
);
CREATE UNIQUE INDEX IF NOT EXISTS branch_one_default ON core.branch (tenant_id) WHERE is_default;

-- Documents / evidence files (object storage reference) -----------------------------
CREATE TABLE IF NOT EXISTS core.document (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    entity_type   text,                       -- e.g. loan.loan, mbr.member
    entity_id     uuid,
    document_type text NOT NULL,              -- ID_PROOF, DEATH_CERTIFICATE, BILL, PHOTO, EVIDENCE ...
    file_name     text NOT NULL,
    content_type  text,
    size_bytes    bigint CHECK (size_bytes >= 0),
    storage_key   text NOT NULL,              -- object storage path (India region)
    sha256        text,
    description   text,
    is_deleted    boolean NOT NULL DEFAULT false,
    archived_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS document_entity_idx ON core.document (tenant_id, entity_type, entity_id);

-- Public holidays (hall rates) -------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.public_holiday (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    holiday_date date NOT NULL,
    name         text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, holiday_date)
);

-- Legal hold (excludes records from purge) --------------------------------------------
CREATE TABLE IF NOT EXISTS core.legal_hold (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    entity_type  text NOT NULL,
    entity_id    uuid NOT NULL,
    reason       text NOT NULL,
    held_from    date NOT NULL DEFAULT current_date,
    released_on  date,
    released_reason text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS legal_hold_entity_idx ON core.legal_hold (tenant_id, entity_type, entity_id);

-- Generic tenant lookups (relationship types, id types, event types ...) -------------
CREATE TABLE IF NOT EXISTS core.lookup_value (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    lookup_type  text NOT NULL,
    code         text NOT NULL,
    name         text NOT NULL,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    sort_order   integer NOT NULL DEFAULT 0,
    is_active    boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, lookup_type, code)
);

-- Import / migration batches (audit channel IMPORT / MIGRATION) ----------------------
CREATE TABLE IF NOT EXISTS core.import_batch (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    batch_no      text NOT NULL,
    import_type   text NOT NULL,              -- MEMBERS, LOANS, OPENING_BALANCES ...
    source_file   text,
    status        text NOT NULL DEFAULT 'STAGED'
                  CHECK (status IN ('STAGED','VALIDATED','LOADED','FAILED','ROLLED_BACK')),
    record_count  integer,
    error_count   integer,
    validation_report jsonb,
    reconciliation    jsonb,
    loaded_at     timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, batch_no)
);

-- =============================================================================
-- Roles and privileges
-- =============================================================================
CREATE TABLE IF NOT EXISTS iam.role (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    role_code          text NOT NULL CHECK (role_code ~ '^[A-Z][A-Z0-9_]*$'),
    role_name          text NOT NULL,
    description        text,
    role_type          text NOT NULL DEFAULT 'CUSTOM' CHECK (role_type IN ('STANDARD','CUSTOM')),
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    default_home_module text REFERENCES platform.module (module_code),
    requires_mfa       boolean NOT NULL DEFAULT false,
    is_read_only       boolean NOT NULL DEFAULT false,
    copied_from_role_id uuid,
    sort_order         integer NOT NULL DEFAULT 100,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, role_code),
    FOREIGN KEY (tenant_id, copied_from_role_id) REFERENCES iam.role (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS iam.role_privilege (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    role_id         uuid NOT NULL,
    privilege_code  text NOT NULL REFERENCES platform.privilege (privilege_code),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, role_id, privilege_code),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id)
);

-- =============================================================================
-- Users (Section 3.6.1)
-- =============================================================================
CREATE TABLE IF NOT EXISTS iam.app_user (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    full_name          text NOT NULL,
    mobile             text,
    email              text,
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    web_access         boolean NOT NULL DEFAULT true,
    mobile_access      boolean NOT NULL DEFAULT false,
    username           text,                      -- mobile number or email
    password_hash      text,                      -- set by the user on activation only
    password_changed_at timestamptz,
    must_change_password boolean NOT NULL DEFAULT true,
    mfa_enabled        boolean NOT NULL DEFAULT false,
    mfa_method         text CHECK (mfa_method IN ('TOTP','SMS_OTP')),
    mfa_secret_enc     text,
    failed_attempts    integer NOT NULL DEFAULT 0,
    locked_until       timestamptz,
    last_login_at      timestamptz,
    primary_role_id    uuid,
    home_module_code   text REFERENCES platform.module (module_code),  -- personal preference
    employee_id        uuid,                      -- FK added in script 10 (ops.employee)
    is_default_org_admin boolean NOT NULL DEFAULT false,
    activated_at       timestamptz,
    deactivated_at     timestamptz,
    deactivation_reason text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, primary_role_id) REFERENCES iam.role (tenant_id, id),
    CONSTRAINT app_user_username_when_access
        CHECK (NOT (web_access OR mobile_access) OR username IS NOT NULL),
    CONSTRAINT app_user_contact_present CHECK (mobile IS NOT NULL OR email IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS app_user_username_uq ON iam.app_user (tenant_id, lower(username)) WHERE username IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS app_user_one_default_admin ON iam.app_user (tenant_id) WHERE is_default_org_admin;
CREATE INDEX IF NOT EXISTS app_user_access_idx ON iam.app_user (tenant_id, web_access, mobile_access);

CREATE TABLE IF NOT EXISTS iam.user_role (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id         uuid NOT NULL,
    role_id         uuid NOT NULL,
    effective_from  date NOT NULL DEFAULT current_date,
    effective_to    date,
    reason          text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id),
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CREATE INDEX IF NOT EXISTS user_role_user_idx ON iam.user_role (tenant_id, user_id);
CREATE UNIQUE INDEX IF NOT EXISTS user_role_open_uq ON iam.user_role (tenant_id, user_id, role_id) WHERE effective_to IS NULL;

-- Authorised exceptions to segregation-of-duties rules
CREATE TABLE IF NOT EXISTS iam.sod_exception (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id         uuid NOT NULL,
    role_code_a     text NOT NULL,
    role_code_b     text NOT NULL,
    reason          text NOT NULL,
    approved_by     uuid NOT NULL,
    valid_to        date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS iam.user_activation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id         uuid NOT NULL,
    token_hash      text NOT NULL,
    sent_via        text NOT NULL CHECK (sent_via IN ('SMS','EMAIL')),
    sent_to         text NOT NULL,
    sent_at         timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    used_at         timestamptz,
    revoked_at      timestamptz,
    purpose         text NOT NULL DEFAULT 'ACTIVATION' CHECK (purpose IN ('ACTIVATION','PASSWORD_RESET')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id),
    UNIQUE (token_hash)
);

CREATE TABLE IF NOT EXISTS iam.password_history (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id        uuid NOT NULL,
    password_hash  text NOT NULL,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS iam.sign_in_history (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id        uuid,
    username       text NOT NULL,
    platform       text NOT NULL CHECK (platform IN ('WEB','MOBILE')),
    attempted_at   timestamptz NOT NULL DEFAULT now(),
    success        boolean NOT NULL,
    failure_reason text,                -- WRONG_PASSWORD, NO_PLATFORM_ACCESS, LOCKED, INACTIVE, MFA_FAILED
    ip_address     inet,
    device         text,
    user_agent     text,
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS sign_in_history_user_idx ON iam.sign_in_history (tenant_id, user_id, attempted_at DESC);

CREATE TABLE IF NOT EXISTS iam.user_device (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id        uuid NOT NULL,
    device_id      text NOT NULL,
    device_name    text,
    platform_os    text,
    push_token     text,
    registered_at  timestamptz NOT NULL DEFAULT now(),
    signed_out_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id),
    UNIQUE (tenant_id, user_id, device_id)
);

CREATE TABLE IF NOT EXISTS iam.user_session (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    user_id        uuid NOT NULL,
    platform       text NOT NULL CHECK (platform IN ('WEB','MOBILE')),
    role_id        uuid,                       -- current role context
    device_id      text,
    ip_address     inet,
    started_at     timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz,
    ended_at       timestamptz,
    end_reason     text,                       -- LOGOUT, TIMEOUT, ACCESS_REMOVED, DEACTIVATED, ADMIN
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS user_session_open_idx ON iam.user_session (tenant_id, user_id) WHERE ended_at IS NULL;

-- -----------------------------------------------------------------------------
-- Integrity triggers
-- -----------------------------------------------------------------------------

-- Role privileges must stay within the Super Admin's ceiling and enabled modules.
CREATE OR REPLACE FUNCTION iam.trg_role_privilege_check()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE v_module text;
BEGIN
    SELECT p.module_code INTO v_module FROM platform.privilege p WHERE p.privilege_code = NEW.privilege_code;

    IF NOT EXISTS (SELECT 1 FROM platform.tenant_privilege_ceiling c
                    WHERE c.tenant_id = NEW.tenant_id AND c.privilege_code = NEW.privilege_code) THEN
        PERFORM app.fail('PRIVILEGE_ABOVE_CEILING',
            format('Privilege %s is not in the privilege set provided by the Super Administrator', NEW.privilege_code));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM platform.tenant_module tm
                    WHERE tm.tenant_id = NEW.tenant_id AND tm.module_code = v_module AND tm.is_enabled) THEN
        PERFORM app.fail('MODULE_NOT_ENABLED',
            format('Module %s is not enabled for this organisation', v_module));
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS role_privilege_check ON iam.role_privilege;
CREATE TRIGGER role_privilege_check BEFORE INSERT OR UPDATE ON iam.role_privilege
    FOR EACH ROW EXECUTE FUNCTION iam.trg_role_privilege_check();

-- Standard roles cannot be deleted; custom roles cannot be deleted once assigned.
CREATE OR REPLACE FUNCTION iam.trg_role_protect()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.role_type = 'STANDARD' THEN
            PERFORM app.fail('STANDARD_ROLE', 'Standard roles cannot be deleted');
        END IF;
        IF EXISTS (SELECT 1 FROM iam.user_role ur WHERE ur.tenant_id = OLD.tenant_id AND ur.role_id = OLD.id) THEN
            PERFORM app.fail('ROLE_IN_USE', 'A role that has been assigned to a user can only be made inactive');
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.role_type = 'STANDARD' AND (NEW.role_code <> OLD.role_code OR NEW.role_type <> OLD.role_type) THEN
        PERFORM app.fail('STANDARD_ROLE', 'The code and type of a standard role cannot change');
    END IF;
    IF OLD.role_type = 'STANDARD' AND NEW.status = 'INACTIVE' THEN
        PERFORM app.fail('STANDARD_ROLE', 'Standard roles cannot be made inactive');
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS role_protect ON iam.role;
CREATE TRIGGER role_protect BEFORE UPDATE OR DELETE ON iam.role
    FOR EACH ROW EXECUTE FUNCTION iam.trg_role_protect();

-- Segregation of duties on role assignment (e.g. AUD cannot hold any other role).
CREATE OR REPLACE FUNCTION iam.trg_user_role_sod()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE v_new_code text; v_conflict text;
BEGIN
    IF NEW.effective_to IS NOT NULL AND NEW.effective_to < current_date THEN
        RETURN NEW;
    END IF;
    SELECT r.role_code INTO v_new_code FROM iam.role r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.role_id;

    SELECT r.role_code INTO v_conflict
      FROM iam.user_role ur
      JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
      JOIN platform.sod_rule s
        ON (s.role_code_a = v_new_code AND (s.role_code_b = '*' OR s.role_code_b = r.role_code))
        OR (s.role_code_a = r.role_code AND (s.role_code_b = '*' OR s.role_code_b = v_new_code))
     WHERE ur.tenant_id = NEW.tenant_id
       AND ur.user_id = NEW.user_id
       AND ur.id <> NEW.id
       AND ur.role_id <> NEW.role_id
       AND (ur.effective_to IS NULL OR ur.effective_to >= current_date)
       AND NOT EXISTS (SELECT 1 FROM iam.sod_exception e
                        WHERE e.tenant_id = NEW.tenant_id AND e.user_id = NEW.user_id
                          AND ((e.role_code_a = v_new_code AND e.role_code_b = r.role_code)
                            OR (e.role_code_b = v_new_code AND e.role_code_a = r.role_code))
                          AND (e.valid_to IS NULL OR e.valid_to >= current_date))
     LIMIT 1;

    IF v_conflict IS NOT NULL THEN
        PERFORM app.fail('SOD_CONFLICT',
            format('Role %s cannot be held together with role %s (segregation of duties)', v_new_code, v_conflict));
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS user_role_sod ON iam.user_role;
CREATE TRIGGER user_role_sod BEFORE INSERT OR UPDATE ON iam.user_role
    FOR EACH ROW EXECUTE FUNCTION iam.trg_user_role_sod();

-- Removing a platform ends the user's sessions on it; deactivation ends all.
CREATE OR REPLACE FUNCTION iam.trg_app_user_access_change()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF OLD.web_access AND NOT NEW.web_access THEN
        UPDATE iam.user_session SET ended_at = now(), end_reason = 'ACCESS_REMOVED'
         WHERE tenant_id = NEW.tenant_id AND user_id = NEW.id AND platform = 'WEB' AND ended_at IS NULL;
    END IF;
    IF OLD.mobile_access AND NOT NEW.mobile_access THEN
        UPDATE iam.user_session SET ended_at = now(), end_reason = 'ACCESS_REMOVED'
         WHERE tenant_id = NEW.tenant_id AND user_id = NEW.id AND platform = 'MOBILE' AND ended_at IS NULL;
        UPDATE iam.user_device SET signed_out_at = now()
         WHERE tenant_id = NEW.tenant_id AND user_id = NEW.id AND signed_out_at IS NULL;
    END IF;
    IF OLD.status = 'ACTIVE' AND NEW.status = 'INACTIVE' THEN
        UPDATE iam.user_session SET ended_at = now(), end_reason = 'DEACTIVATED'
         WHERE tenant_id = NEW.tenant_id AND user_id = NEW.id AND ended_at IS NULL;
        NEW.deactivated_at := coalesce(NEW.deactivated_at, now());
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS app_user_access_change ON iam.app_user;
CREATE TRIGGER app_user_access_change BEFORE UPDATE OF web_access, mobile_access, status ON iam.app_user
    FOR EACH ROW EXECUTE FUNCTION iam.trg_app_user_access_change();

-- A user may sign in on a platform only if granted (helper for the API).
CREATE OR REPLACE FUNCTION iam.can_sign_in(p_user_id uuid, p_platform text)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT EXISTS (SELECT 1 FROM iam.app_user u
                    WHERE u.id = p_user_id AND u.status = 'ACTIVE'
                      AND (u.locked_until IS NULL OR u.locked_until < now())
                      AND CASE p_platform WHEN 'WEB' THEN u.web_access
                                          WHEN 'MOBILE' THEN u.mobile_access ELSE false END)
$$;

-- Does a user hold a privilege (through any active role)?
CREATE OR REPLACE FUNCTION iam.has_privilege(p_user_id uuid, p_privilege_code text)
RETURNS boolean LANGUAGE sql STABLE AS
$$
    SELECT EXISTS (
        SELECT 1
          FROM iam.user_role ur
          JOIN iam.role r            ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id AND r.status = 'ACTIVE'
          JOIN iam.role_privilege rp ON rp.tenant_id = r.tenant_id AND rp.role_id = r.id
          JOIN platform.privilege p  ON p.privilege_code = rp.privilege_code
          JOIN platform.tenant_module tm ON tm.tenant_id = ur.tenant_id AND tm.module_code = p.module_code AND tm.is_enabled
         WHERE ur.user_id = p_user_id
           AND rp.privilege_code = p_privilege_code
           AND ur.effective_from <= current_date
           AND (ur.effective_to IS NULL OR ur.effective_to >= current_date))
$$;
