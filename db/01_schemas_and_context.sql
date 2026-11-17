-- =============================================================================
-- CFMS / NVS  -  01  Schemas, session context and common helper functions
-- -----------------------------------------------------------------------------
-- Run as : nvs, connected to database nvs. Safe to re-run.
--
-- Schemas
--   app       helper functions (session context, triggers, utilities)
--   platform  SaaS platform tables: tenants, platform users, module registry,
--             templates, action catalogue (NOT tenant-owned, no RLS)
--   core      shared tenant data: branches, documents, holidays, legal holds
--   iam       users, roles, privileges, sessions (tenant-owned)
--   cfg       tenant settings, workflow and rule versions (tenant-owned)
--   wf        workflow instances, action executions, approvals (tenant-owned)
--   audit     append-only record-level audit history (tenant-owned)
--   mbr       members, nominees, family, successors (tenant-owned)
--   acct      chart of accounts, journals, cash, periods, funds (tenant-owned)
--   loan      loans, schedules, repayments, default, recovery (tenant-owned)
--   ops       expenses, vendors, payroll, assistance, halls, assets,
--             contributions and donations (tenant-owned)
--   dep       member deposits (optional module)
--   chit      chit fund schemes (optional module)
--   notif     notification templates and messages
--
-- Tenant isolation: every tenant-owned table has tenant_id NOT NULL, is
-- protected by row-level security (script 20) and only shows the rows of the
-- tenant set in the session with app.set_context(...).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS app      AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS core     AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS iam      AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS cfg      AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS wf       AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS audit    AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS mbr      AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS acct     AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS loan     AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS ops      AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS dep      AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS chit     AUTHORIZATION nvs;
CREATE SCHEMA IF NOT EXISTS notif    AUTHORIZATION nvs;

-- Default search path for new sessions (DBeaver, application).
ALTER DATABASE nvs SET search_path = app, platform, core, iam, cfg, wf, audit,
    mbr, acct, loan, ops, dep, chit, notif, public;

-- -----------------------------------------------------------------------------
-- Session context
-- The application sets these at the start of every request / job, from the
-- authenticated token (never from user input):
--   SELECT app.set_context(tenant_id, user_id, role_code, channel,
--                          working_date, ip, device);
-- Settings used:
--   app.tenant_id          tenant of the request (drives RLS)
--   app.user_id            iam.app_user.id of the acting user
--   app.platform_user_id   platform.platform_user.id (Super Admin console)
--   app.scope              'platform' when the Super Admin console is acting
--   app.role_code          role the user is acting in
--   app.channel            WEB | MOBILE | SUPER_ADMIN | IMPORT | MIGRATION | SYSTEM
--   app.working_date       working (value) date chosen in the top bar
--   app.client_ip, app.device, app.reason, app.reference_type, app.reference_id
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.setting(p_name text)
RETURNS text LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting(p_name, true), '') $$;

CREATE OR REPLACE FUNCTION app.tenant_id()
RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT app.setting('app.tenant_id')::uuid $$;

CREATE OR REPLACE FUNCTION app.user_id()
RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT coalesce(app.setting('app.user_id'), app.setting('app.platform_user_id'))::uuid $$;

CREATE OR REPLACE FUNCTION app.platform_user_id()
RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT app.setting('app.platform_user_id')::uuid $$;

CREATE OR REPLACE FUNCTION app.role_code()
RETURNS text LANGUAGE sql STABLE AS
$$ SELECT app.setting('app.role_code') $$;

CREATE OR REPLACE FUNCTION app.channel()
RETURNS text LANGUAGE sql STABLE AS
$$ SELECT coalesce(app.setting('app.channel'), 'DB') $$;

CREATE OR REPLACE FUNCTION app.is_platform_scope()
RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT coalesce(app.setting('app.scope') = 'platform', false) $$;

-- Today's date in the tenant's time zone (falls back to server date).
CREATE OR REPLACE FUNCTION app.tenant_today(p_tenant_id uuid DEFAULT NULL)
RETURNS date LANGUAGE plpgsql STABLE AS
$$
DECLARE v_tz text;
BEGIN
    SELECT t.time_zone INTO v_tz
      FROM platform.tenant t
     WHERE t.id = coalesce(p_tenant_id, app.tenant_id());
    RETURN (now() AT TIME ZONE coalesce(v_tz, 'Asia/Kolkata'))::date;
END
$$;

-- Working (value) date of the session; defaults to the tenant's today.
CREATE OR REPLACE FUNCTION app.working_date()
RETURNS date LANGUAGE sql STABLE AS
$$ SELECT coalesce(app.setting('app.working_date')::date, app.tenant_today()) $$;

CREATE OR REPLACE FUNCTION app.set_context(
    p_tenant_id    uuid,
    p_user_id      uuid    DEFAULT NULL,
    p_role_code    text    DEFAULT NULL,
    p_channel      text    DEFAULT 'WEB',
    p_working_date date    DEFAULT NULL,
    p_client_ip    inet    DEFAULT NULL,
    p_device       text    DEFAULT NULL,
    p_is_local     boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    IF p_channel NOT IN ('WEB','MOBILE','SUPER_ADMIN','IMPORT','MIGRATION','SYSTEM','DB') THEN
        PERFORM app.fail('INVALID_CHANNEL', format('Invalid channel %s', p_channel));
    END IF;
    PERFORM set_config('app.tenant_id',    coalesce(p_tenant_id::text, ''),    p_is_local);
    PERFORM set_config('app.user_id',      coalesce(p_user_id::text, ''),      p_is_local);
    PERFORM set_config('app.role_code',    coalesce(p_role_code, ''),          p_is_local);
    PERFORM set_config('app.channel',      coalesce(p_channel, ''),            p_is_local);
    PERFORM set_config('app.working_date', coalesce(p_working_date::text, ''), p_is_local);
    PERFORM set_config('app.client_ip',    coalesce(p_client_ip::text, ''),    p_is_local);
    PERFORM set_config('app.device',       coalesce(p_device, ''),             p_is_local);
    PERFORM set_config('app.scope',        '',                                 p_is_local);
    PERFORM set_config('app.platform_user_id', '',                             p_is_local);
END
$$;

-- Super Admin console context: platform scope, optionally on one tenant.
CREATE OR REPLACE FUNCTION app.set_platform_context(
    p_platform_user_id uuid,
    p_tenant_id        uuid    DEFAULT NULL,
    p_client_ip        inet    DEFAULT NULL,
    p_is_local         boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM app.set_context(p_tenant_id, NULL, 'SUPER_ADMIN', 'SUPER_ADMIN',
                            NULL, p_client_ip, NULL, p_is_local);
    PERFORM set_config('app.platform_user_id', coalesce(p_platform_user_id::text, ''), p_is_local);
    PERFORM set_config('app.scope', 'platform', p_is_local);
END
$$;

-- Reason / reference for the next changes in this transaction (audit history).
CREATE OR REPLACE FUNCTION app.set_audit_reason(
    p_reason text, p_reference_type text DEFAULT NULL, p_reference_id text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM set_config('app.reason',         coalesce(p_reason, ''),         true);
    PERFORM set_config('app.reference_type', coalesce(p_reference_type, ''), true);
    PERFORM set_config('app.reference_id',   coalesce(p_reference_id, ''),   true);
END
$$;

CREATE OR REPLACE FUNCTION app.clear_context()
RETURNS void LANGUAGE plpgsql AS
$$
DECLARE k text;
BEGIN
    FOREACH k IN ARRAY ARRAY['app.tenant_id','app.user_id','app.platform_user_id',
        'app.scope','app.role_code','app.channel','app.working_date','app.client_ip',
        'app.device','app.reason','app.reference_type','app.reference_id',
        'app.audit_operation']
    LOOP
        PERFORM set_config(k, '', false);
    END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- Generic trigger: maintain created_by / updated_at / updated_by / row_version
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.trg_touch()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at  := coalesce(NEW.created_at, now());
        NEW.created_by  := coalesce(NEW.created_by, app.user_id());
        NEW.row_version := 1;
    ELSE
        NEW.created_at  := OLD.created_at;      -- never changes
        NEW.created_by  := OLD.created_by;
        NEW.updated_at  := now();
        NEW.updated_by  := app.user_id();
        NEW.row_version := OLD.row_version + 1;
    END IF;
    RETURN NEW;
END
$$;

-- Idempotent "ADD CONSTRAINT" helper (used for foreign keys added later).
CREATE OR REPLACE FUNCTION app.add_constraint_if_missing(
    p_table regclass, p_name text, p_definition text)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = p_table AND conname = p_name) THEN
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', p_table, p_name, p_definition);
    END IF;
END
$$;

-- Raise a readable business error.
CREATE OR REPLACE FUNCTION app.fail(p_code text, p_message text)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = p_message, HINT = p_code;
END
$$;
