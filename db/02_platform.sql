-- =============================================================================
-- CFMS / NVS  -  02  Platform (SaaS) tables
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Platform-level tables (tenant, platform users, module registry, templates,
-- action catalogue) have no tenant_id and no RLS. Per-tenant platform tables
-- (enabled modules, privilege ceiling, compliance features, purge, break-glass
-- access) carry tenant_id and get RLS in script 20 (tenant can read its own
-- rows; the Super Admin console works in platform scope).
-- =============================================================================

-- Tenant (organisation) ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform.tenant (
    id                 uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code               text NOT NULL,                 -- subdomain / short code
    name               text NOT NULL,
    legal_name         text,
    registration_no    text,
    status             text NOT NULL DEFAULT 'PROVISIONING'
                       CHECK (status IN ('PROVISIONING','ACTIVE','SUSPENDED','CLOSED')),
    is_sandbox         boolean NOT NULL DEFAULT false,
    time_zone          text NOT NULL DEFAULT 'Asia/Kolkata',
    currency_code      char(3) NOT NULL DEFAULT 'INR',
    address            jsonb,
    contact_email      text,
    contact_mobile     text,
    logo_url           text,
    data_region        text NOT NULL DEFAULT 'IN',
    settings_template_version integer,
    dedicated_database text,                         -- hybrid model: tenant moved to its own DB
    activated_at       timestamptz,
    suspended_at       timestamptz,
    closed_at          timestamptz,
    status_reason      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid DEFAULT app.user_id(),
    updated_at         timestamptz,
    updated_by         uuid,
    row_version        integer NOT NULL DEFAULT 1,
    CONSTRAINT tenant_code_format CHECK (code ~ '^[a-z0-9][a-z0-9-]{1,62}$')
);
CREATE UNIQUE INDEX IF NOT EXISTS tenant_code_uq ON platform.tenant (lower(code));

-- Platform operator accounts --------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform.platform_user (
    id               uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    full_name        text NOT NULL,
    email            text NOT NULL,
    mobile           text,
    platform_role    text NOT NULL DEFAULT 'SUPER_ADMIN'
                     CHECK (platform_role IN ('SUPER_ADMIN','SUPPORT','BILLING')),
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE','LOCKED')),
    password_hash    text,
    must_change_password boolean NOT NULL DEFAULT true,
    mfa_enabled      boolean NOT NULL DEFAULT true,   -- MFA mandatory for platform roles
    mfa_secret_enc   text,
    failed_attempts  integer NOT NULL DEFAULT 0,
    locked_until     timestamptz,
    last_login_at    timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT app.user_id(),
    updated_at       timestamptz,
    updated_by       uuid,
    row_version      integer NOT NULL DEFAULT 1
);
ALTER TABLE platform.platform_user ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT true;
CREATE UNIQUE INDEX IF NOT EXISTS platform_user_email_uq ON platform.platform_user (lower(email));

CREATE TABLE IF NOT EXISTS platform.platform_sign_in (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    platform_user_id uuid REFERENCES platform.platform_user (id),
    username         text NOT NULL,
    attempted_at     timestamptz NOT NULL DEFAULT now(),
    success          boolean NOT NULL,
    failure_reason   text,
    ip_address       inet,
    device           text,
    user_agent       text
);
CREATE INDEX IF NOT EXISTS platform_sign_in_user_idx ON platform.platform_sign_in (platform_user_id, attempted_at DESC);

-- Module registry (Section 3.9) - maintained by SQL scripts only -----------------
CREATE TABLE IF NOT EXISTS platform.module (
    module_code        text PRIMARY KEY CHECK (module_code ~ '^[A-Z][A-Z0-9_]*$'),
    module_name        text NOT NULL,
    module_type        text NOT NULL
                       CHECK (module_type IN ('GROUP','MODULE','DASHBOARD','REPORT','CONFIGURATION','PLATFORM')),
    parent_module_code text REFERENCES platform.module (module_code),
    is_menu            boolean NOT NULL DEFAULT true,
    menu_order         integer NOT NULL DEFAULT 0,
    icon               text,
    route              text,
    is_active          boolean NOT NULL DEFAULT true,
    is_core            boolean NOT NULL DEFAULT false, -- always enabled, cannot be disabled
    is_optional_legal  boolean NOT NULL DEFAULT false, -- deposits / chit funds: legal warning on enable
    scope_ref          text,                            -- scope document section
    priority           text,
    plan_feature_code  text,                            -- reserved (future plans)
    description        text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz
);
COMMENT ON TABLE platform.module IS
  'Module Registry. is_menu and all other fields are changed ONLY through version-controlled SQL scripts; there is no UI for it.';

-- Privilege catalogue -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform.privilege_type (
    type_code   char(1) PRIMARY KEY,
    name        text NOT NULL,
    description text,
    sort_order  integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS platform.privilege (
    privilege_code text PRIMARY KEY,                 -- e.g. loan.approve
    module_code    text NOT NULL REFERENCES platform.module (module_code),
    type_code      char(1) NOT NULL REFERENCES platform.privilege_type (type_code),
    name           text NOT NULL,
    is_active      boolean NOT NULL DEFAULT true,
    UNIQUE (module_code, type_code)
);

-- Standard role templates and the default privilege matrix (Section 3.3) ------------
CREATE TABLE IF NOT EXISTS platform.role_template (
    role_code         text PRIMARY KEY,
    role_name         text NOT NULL,
    description       text,
    default_home_module text REFERENCES platform.module (module_code),
    requires_mfa      boolean NOT NULL DEFAULT false,
    is_read_only      boolean NOT NULL DEFAULT false,
    sort_order        integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS platform.role_template_privilege (
    role_code      text NOT NULL REFERENCES platform.role_template (role_code),
    privilege_code text NOT NULL REFERENCES platform.privilege (privilege_code),
    PRIMARY KEY (role_code, privilege_code)
);

-- Segregation of duties: incompatible standard role pairs (Section 3.5)
CREATE TABLE IF NOT EXISTS platform.sod_rule (
    role_code_a text NOT NULL REFERENCES platform.role_template (role_code),
    role_code_b text NOT NULL,                       -- '*' = any other role
    description text NOT NULL,
    PRIMARY KEY (role_code_a, role_code_b)
);

-- Settings: definitions and the versioned default template (Section 4.10) ------------
CREATE TABLE IF NOT EXISTS platform.setting_definition (
    setting_key    text PRIMARY KEY CHECK (setting_key ~ '^[a-z][a-z0-9_.]*$'),
    area           text NOT NULL,
    name           text NOT NULL,
    description    text,
    data_type      text NOT NULL CHECK (data_type IN ('string','integer','decimal','boolean','date','json','list')),
    editable_by    text NOT NULL CHECK (editable_by IN ('SUPER_ADMIN','ORG_ADMIN','ACCOUNTANT','ACCOUNTANT_WITH_LDR','FIXED')),
    module_code    text REFERENCES platform.module (module_code),
    validation     jsonb,                            -- e.g. {"min":0} / {"enum":[...]} / JSON Schema
    scope_ref      text,
    is_proposed    boolean NOT NULL DEFAULT false,
    sort_order     integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS platform.settings_template (
    version_no     integer PRIMARY KEY,
    status         text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','RETIRED')),
    description    text,
    reason         text NOT NULL,
    published_by   uuid REFERENCES platform.platform_user (id),
    published_at   timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT app.user_id()
);
CREATE UNIQUE INDEX IF NOT EXISTS settings_template_one_published
    ON platform.settings_template ((true)) WHERE status = 'PUBLISHED';

CREATE TABLE IF NOT EXISTS platform.settings_template_item (
    version_no   integer NOT NULL REFERENCES platform.settings_template (version_no),
    setting_key  text NOT NULL REFERENCES platform.setting_definition (setting_key),
    value        jsonb NOT NULL,
    PRIMARY KEY (version_no, setting_key)
);

-- Legal and tax compliance features (Section 4.8) --------------------------------------
CREATE TABLE IF NOT EXISTS platform.compliance_feature (
    feature_code   text PRIMARY KEY,
    name           text NOT NULL,
    description    text,
    module_code    text REFERENCES platform.module (module_code),
    legal_warning  text,
    sort_order     integer NOT NULL DEFAULT 0
);

-- Payment modes (only CASH enabled in current scope) -------------------------------------
CREATE TABLE IF NOT EXISTS platform.payment_mode (
    mode_code   text PRIMARY KEY,
    name        text NOT NULL,
    is_enabled  boolean NOT NULL DEFAULT false,
    sort_order  integer NOT NULL DEFAULT 0
);

-- JSON Schemas used to validate workflow / rule / action-config documents --------------
CREATE TABLE IF NOT EXISTS platform.json_schema (
    id             uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    schema_kind    text NOT NULL CHECK (schema_kind IN ('WORKFLOW','RULESET','ACTION_CONFIG','SETTING')),
    schema_version text NOT NULL,
    schema_doc     jsonb NOT NULL,
    status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT app.user_id(),
    UNIQUE (schema_kind, schema_version)
);

-- Action catalogue (Section 25.4) - discovered, approved by the Super Admin -----------
CREATE TABLE IF NOT EXISTS platform.action_definition (
    action_code         text PRIMARY KEY CHECK (action_code ~ '^[A-Z][A-Z0-9_]*$'),
    name                text NOT NULL,
    description         text,
    category            text NOT NULL,
    action_kind         text NOT NULL DEFAULT 'DATA'
                        CHECK (action_kind IN ('VALIDATION','DATA','NOTIFICATION','APPROVAL','MANUAL')),
    default_execution_type text NOT NULL DEFAULT 'SYNCHRONOUS'
                        CHECK (default_execution_type IN ('SYNCHRONOUS','ASYNCHRONOUS','CONDITIONAL','PARALLEL','MANUAL','SCHEDULED')),
    config_schema       jsonb,
    implementation_version text,
    status              text NOT NULL DEFAULT 'PENDING_APPROVAL'
                        CHECK (status IN ('PENDING_APPROVAL','APPROVED','REJECTED','RETIRED')),
    discovered_at       timestamptz NOT NULL DEFAULT now(),
    approved_by         uuid REFERENCES platform.platform_user (id),
    approved_at         timestamptz,
    approval_reason     text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz
);

-- Template library: workflows and rule sets (Section 35.4) -------------------------------
CREATE TABLE IF NOT EXISTS platform.config_template (
    id            uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    template_kind text NOT NULL CHECK (template_kind IN ('WORKFLOW','RULESET')),
    code          text NOT NULL,
    name          text NOT NULL,
    module_code   text REFERENCES platform.module (module_code),
    entity_type   text,
    description   text,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT app.user_id(),
    UNIQUE (template_kind, code)
);

CREATE TABLE IF NOT EXISTS platform.config_template_version (
    id             uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    template_id    uuid NOT NULL REFERENCES platform.config_template (id),
    version_no     integer NOT NULL,
    status         text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','RETIRED')),
    definition     jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    json_schema_id uuid REFERENCES platform.json_schema (id),
    checksum       text GENERATED ALWAYS AS (md5(definition::text)) STORED,
    reason         text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT app.user_id(),
    published_at   timestamptz,
    published_by   uuid REFERENCES platform.platform_user (id),
    UNIQUE (template_id, version_no)
);

-- Templates cloned into every new tenant --------------------------------------------------
CREATE TABLE IF NOT EXISTS platform.coa_template (
    account_code     text PRIMARY KEY,
    account_name     text NOT NULL,
    account_type     text NOT NULL CHECK (account_type IN ('ASSET','CONTRA_ASSET','LIABILITY','FUND','INCOME','EXPENSE')),
    parent_code      text REFERENCES platform.coa_template (account_code),
    is_group         boolean NOT NULL DEFAULT false,
    module_code      text REFERENCES platform.module (module_code),      -- created only when enabled
    feature_code     text REFERENCES platform.compliance_feature (feature_code),
    is_cash          boolean NOT NULL DEFAULT false,
    is_active_default boolean NOT NULL DEFAULT true,  -- e.g. bank / depreciation start inactive
    allow_manual     boolean NOT NULL DEFAULT true,
    sub_ledger_type  text,                              -- LOAN_TYPE, FUND, HALL, CHIT_GROUP ...
    notes            text,
    sort_order       integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS platform.loan_type_template (
    code               text PRIMARY KEY,
    name               text NOT NULL,
    description        text,
    interest_method    text NOT NULL CHECK (interest_method IN ('FLAT','NONE')),
    rule_template_code text,                            -- RULESET config_template.code
    sort_order         integer NOT NULL DEFAULT 0
);

-- Generic lookup templates (expense / asset categories, evidence types, ...)
CREATE TABLE IF NOT EXISTS platform.lookup_template (
    lookup_type  text NOT NULL,
    code         text NOT NULL,
    name         text NOT NULL,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    sort_order   integer NOT NULL DEFAULT 0,
    is_active    boolean NOT NULL DEFAULT true,
    PRIMARY KEY (lookup_type, code)
);

CREATE TABLE IF NOT EXISTS platform.notification_template_default (
    code             text NOT NULL,
    channel          text NOT NULL CHECK (channel IN ('SMS','WHATSAPP','EMAIL','INAPP')),
    language_code    text NOT NULL DEFAULT 'en',
    name             text NOT NULL,
    subject          text,
    body             text NOT NULL,
    module_code      text REFERENCES platform.module (module_code),
    is_essential     boolean NOT NULL DEFAULT true,
    PRIMARY KEY (code, channel, language_code)
);

-- Data categories and retention floors (Section 36) --------------------------------------
CREATE TABLE IF NOT EXISTS platform.data_category (
    category_code      text PRIMARY KEY,
    name               text NOT NULL,
    default_years      numeric(5,2) NOT NULL,
    minimum_years      numeric(5,2) NOT NULL,
    approval_mandatory boolean NOT NULL DEFAULT true,
    CHECK (default_years >= minimum_years)
);

-- ===== Per-tenant platform tables (RLS applied in script 20) ===============

-- Modules enabled per tenant (Section 3.9.1) - Super Admin only
CREATE TABLE IF NOT EXISTS platform.tenant_module (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    module_code      text NOT NULL REFERENCES platform.module (module_code),
    is_enabled       boolean NOT NULL DEFAULT true,
    enabled_at       timestamptz,
    enabled_by       uuid REFERENCES platform.platform_user (id),
    disabled_at      timestamptz,
    disabled_by      uuid REFERENCES platform.platform_user (id),
    reason           text,
    legal_warning_ack_at  timestamptz,               -- deposits / chit funds
    legal_warning_ack_by  uuid REFERENCES platform.platform_user (id),
    legal_advice_document_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, module_code)
);

-- Privilege ceiling = default modules/roles/privileges handed to the tenant
-- (ConfigurationDelegation, Section 35.4). Roles can never exceed it.
CREATE TABLE IF NOT EXISTS platform.tenant_privilege_ceiling (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    privilege_code   text NOT NULL REFERENCES platform.privilege (privilege_code),
    granted_by       uuid REFERENCES platform.platform_user (id),
    reason           text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, privilege_code)
);

-- Legal and tax features per tenant, effective-dated (Section 4.8)
CREATE TABLE IF NOT EXISTS platform.tenant_compliance_setting (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    feature_code     text NOT NULL REFERENCES platform.compliance_feature (feature_code),
    is_enabled       boolean NOT NULL DEFAULT false,
    effective_from   date NOT NULL,
    reason           text,
    legal_warning_ack_at timestamptz,
    config           jsonb NOT NULL DEFAULT '{}'::jsonb,   -- registration numbers, rates (by Accountant)
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, feature_code, effective_from)
);

-- Purge policy, runs and certificates (Section 36)
CREATE TABLE IF NOT EXISTS platform.purge_policy (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    category_code     text NOT NULL REFERENCES platform.data_category (category_code),
    purge_enabled     boolean NOT NULL DEFAULT false,
    retention_years   numeric(5,2) NOT NULL,
    archive_retention_years numeric(5,2) NOT NULL DEFAULT 2,
    approval_required boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, category_code)
);

CREATE TABLE IF NOT EXISTS platform.purge_run (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    run_no            text NOT NULL,
    status            text NOT NULL DEFAULT 'CANDIDATES'
                      CHECK (status IN ('CANDIDATES','ORG_APPROVED','AUTHORISED','ARCHIVED','VERIFIED','PURGED','REJECTED','FAILED')),
    candidate_report  jsonb,
    org_approved_by   uuid,
    org_approved_at   timestamptz,
    authorised_by     uuid REFERENCES platform.platform_user (id),
    authorised_at     timestamptz,
    archive_reference text,
    archive_verified_at timestamptz,
    completed_at      timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, run_no)
);

CREATE TABLE IF NOT EXISTS platform.purge_certificate (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    purge_run_id      uuid NOT NULL,
    certificate_no    text NOT NULL,
    categories        jsonb NOT NULL,         -- category, record counts, date ranges
    approvers         jsonb NOT NULL,
    completed_at      timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, purge_run_id) REFERENCES platform.purge_run (tenant_id, id),
    UNIQUE (tenant_id, certificate_no)
);

-- Break-glass access by platform staff (Section 35.3)
CREATE TABLE IF NOT EXISTS platform.platform_access_request (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    platform_user_id  uuid NOT NULL REFERENCES platform.platform_user (id),
    reason            text NOT NULL,
    scope             text,
    status            text NOT NULL DEFAULT 'REQUESTED'
                      CHECK (status IN ('REQUESTED','APPROVED','REJECTED','EXPIRED','REVOKED')),
    requested_at      timestamptz NOT NULL DEFAULT now(),
    decided_by_user_id uuid,                -- tenant user (iam.app_user) who approved
    decided_at        timestamptz,
    valid_from        timestamptz,
    valid_to          timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE IF NOT EXISTS platform.platform_access_log (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    platform_user_id  uuid NOT NULL REFERENCES platform.platform_user (id),
    access_request_id uuid REFERENCES platform.platform_access_request (id),
    accessed_at       timestamptz NOT NULL DEFAULT now(),
    entity_type       text,
    record_id         text,
    action            text NOT NULL,
    ip_address        inet
);

-- Metered usage (SMS, WhatsApp, storage) for reporting
CREATE TABLE IF NOT EXISTS platform.usage_record (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    metric            text NOT NULL CHECK (metric IN ('SMS','WHATSAPP','EMAIL','STORAGE_MB','USERS','MEMBERS')),
    period_month      date NOT NULL,
    quantity          numeric(18,2) NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, metric, period_month)
);

-- Future scope: subscription plans and billing (kept minimal)
CREATE TABLE IF NOT EXISTS platform.subscription_plan (
    plan_code   text PRIMARY KEY,
    name        text NOT NULL,
    features    jsonb NOT NULL DEFAULT '{}'::jsonb,
    limits      jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_active   boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS platform.tenant_subscription (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    plan_code     text NOT NULL REFERENCES platform.subscription_plan (plan_code),
    billing_cycle text CHECK (billing_cycle IN ('MONTHLY','ANNUAL')),
    status        text NOT NULL DEFAULT 'ACTIVE',
    starts_on     date NOT NULL,
    ends_on       date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id)
);

-- Platform audit log (Super Admin actions, tenant/module changes, platform tables)
CREATE TABLE IF NOT EXISTS platform.platform_audit_event (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_time        timestamptz NOT NULL DEFAULT clock_timestamp(),
    tenant_id         uuid,
    platform_user_id  uuid,
    user_id           uuid,
    channel           text,
    entity_schema     text NOT NULL,
    entity_table      text NOT NULL,
    record_id         text,
    operation         text NOT NULL,
    changes           jsonb,                 -- {"field": {"old": .., "new": ..}}
    reason            text,
    ip_address        inet,
    db_user           text NOT NULL DEFAULT session_user,
    txid              bigint NOT NULL DEFAULT txid_current()
);
CREATE INDEX IF NOT EXISTS platform_audit_event_tenant_idx ON platform.platform_audit_event (tenant_id, event_time DESC);
CREATE INDEX IF NOT EXISTS platform_audit_event_entity_idx ON platform.platform_audit_event (entity_table, record_id);
