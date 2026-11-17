-- =============================================================================
-- CFMS / NVS  -  05  Workflow runtime, action executions and approvals
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Each workflow instance is pinned to the workflow version and the rule set
-- versions in force when it started (version stamping, Section 24.2).
-- =============================================================================

CREATE TABLE IF NOT EXISTS wf.workflow_instance (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_definition_id uuid NOT NULL,
    workflow_version_id    uuid NOT NULL,
    entity_type        text NOT NULL,              -- e.g. loan.loan
    entity_id          uuid NOT NULL,
    business_ref       text,                       -- e.g. LN-2027-0045
    current_stage_code text NOT NULL,
    status             text NOT NULL DEFAULT 'RUNNING'
                       CHECK (status IN ('RUNNING','PAUSED','COMPLETED','REJECTED','WITHDRAWN','CANCELLED','FAILED')),
    rule_set_versions  jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {"LOAN_TYPE_NORMAL": "<rule_set_version_id>"}
    working_date       date NOT NULL DEFAULT app.working_date(),
    started_by         uuid,
    started_at         timestamptz NOT NULL DEFAULT now(),
    completed_at       timestamptz,
    cancel_reason      text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_definition_id) REFERENCES cfg.workflow_definition (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_version_id) REFERENCES cfg.workflow_version (tenant_id, id),
    FOREIGN KEY (tenant_id, started_by) REFERENCES iam.app_user (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS workflow_instance_entity_idx ON wf.workflow_instance (tenant_id, entity_type, entity_id);
CREATE INDEX IF NOT EXISTS workflow_instance_stage_idx ON wf.workflow_instance (tenant_id, current_stage_code) WHERE status = 'RUNNING';

CREATE TABLE IF NOT EXISTS wf.workflow_context (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_instance_id uuid NOT NULL,
    data            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, workflow_instance_id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS wf.workflow_history (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_instance_id uuid NOT NULL,
    from_stage_code text,
    to_stage_code   text NOT NULL,
    trigger_event   text NOT NULL,
    acted_by        uuid,
    acted_role_code text,
    acted_at        timestamptz NOT NULL DEFAULT now(),
    working_date    date NOT NULL DEFAULT app.working_date(),
    round_no        integer NOT NULL DEFAULT 1,        -- return / resubmission rounds
    approval_decision_id uuid,
    remarks         text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, acted_by) REFERENCES iam.app_user (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS workflow_history_instance_idx ON wf.workflow_history (tenant_id, workflow_instance_id, acted_at);

CREATE TABLE IF NOT EXISTS wf.action_execution (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    workflow_instance_id uuid NOT NULL,
    workflow_stage_action_id uuid,
    stage_code      text NOT NULL,
    action_code     text NOT NULL REFERENCES platform.action_definition (action_code),
    seq             integer NOT NULL,
    execution_type  text NOT NULL,
    status          text NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','RUNNING','SUCCESS','FAILED','SKIPPED','RETRYING','CANCELLED')),
    attempt         integer NOT NULL DEFAULT 1,
    idempotency_key text NOT NULL,                -- retries never duplicate postings
    executed_by     uuid,                         -- null = SYSTEM
    scheduled_for   timestamptz,
    started_at      timestamptz,
    completed_at    timestamptz,
    result          jsonb,                        -- ActionResult
    error_code      text,
    error_message   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, idempotency_key),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_stage_action_id) REFERENCES cfg.workflow_stage_action (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS action_execution_instance_idx ON wf.action_execution (tenant_id, workflow_instance_id);
CREATE INDEX IF NOT EXISTS action_execution_pending_idx ON wf.action_execution (status, scheduled_for) WHERE status IN ('PENDING','RETRYING');

CREATE TABLE IF NOT EXISTS wf.action_execution_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    action_execution_id uuid NOT NULL,
    logged_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
    level           text NOT NULL DEFAULT 'INFO' CHECK (level IN ('DEBUG','INFO','WARN','ERROR')),
    message         text NOT NULL,
    data            jsonb,
    FOREIGN KEY (tenant_id, action_execution_id) REFERENCES wf.action_execution (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS wf.action_failure_log (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    action_execution_id uuid,
    action_code     text NOT NULL,
    workflow_instance_id uuid,
    entity_type     text,
    entity_id       uuid,
    business_ref    text,
    error_code      text,
    error_message   text NOT NULL,
    user_id         uuid,
    failed_at       timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz,
    resolved_by     uuid,
    resolution      text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, action_execution_id) REFERENCES wf.action_execution (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS action_failure_open_idx ON wf.action_failure_log (tenant_id, failed_at DESC) WHERE resolved_at IS NULL;

-- =============================================================================
-- Approvals (Section 28)
-- =============================================================================

-- Offline approval evidence types (configurable dropdown, Section 4.7)
CREATE TABLE IF NOT EXISTS wf.offline_evidence_type (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code         text NOT NULL,
    name         text NOT NULL,
    upload_optional boolean NOT NULL DEFAULT true,
    sort_order   integer NOT NULL DEFAULT 0,
    is_active    boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code)
);

CREATE TABLE IF NOT EXISTS wf.approval_policy (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code              text NOT NULL,
    name              text NOT NULL,
    module_code       text REFERENCES platform.module (module_code),
    workflow_code     text,
    stage_code        text,
    approver_role_id  uuid NOT NULL,                  -- single approver, irrespective of amount
    allow_online      boolean NOT NULL DEFAULT true,
    allow_offline     boolean NOT NULL DEFAULT true,
    require_distinct_identities boolean NOT NULL DEFAULT true,  -- requested/approved/recorded by different people
    require_verification boolean NOT NULL DEFAULT false,
    effective_from    date NOT NULL DEFAULT current_date,
    status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code, effective_from),
    FOREIGN KEY (tenant_id, approver_role_id) REFERENCES iam.role (tenant_id, id)
);

-- Roles allowed to record offline decisions (default EMP and MGR)
CREATE TABLE IF NOT EXISTS wf.offline_recorder_role (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    role_id      uuid NOT NULL,
    approval_policy_id uuid,                         -- null = all policies
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_policy_id) REFERENCES wf.approval_policy (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS offline_recorder_role_uq
    ON wf.offline_recorder_role (tenant_id, role_id, coalesce(approval_policy_id, '00000000-0000-0000-0000-000000000000'::uuid));

CREATE TABLE IF NOT EXISTS wf.approval_meeting (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    meeting_ref     text NOT NULL,
    meeting_date    date NOT NULL,
    venue           text,
    attendees       text,
    minutes_document_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, meeting_ref),
    FOREIGN KEY (tenant_id, minutes_document_id) REFERENCES core.document (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS wf.approval_delegation (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    from_user_id    uuid NOT NULL,
    to_user_id      uuid NOT NULL,
    role_id         uuid NOT NULL,
    valid_from      date NOT NULL,
    valid_to        date NOT NULL,
    reason          text NOT NULL,
    approved_by     uuid,
    status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REVOKED','EXPIRED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, from_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, to_user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id),
    CHECK (from_user_id <> to_user_id),
    CHECK (valid_to >= valid_from)
);

CREATE TABLE IF NOT EXISTS wf.approval_request (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    request_no        text,
    approval_policy_id uuid,
    workflow_instance_id uuid,
    stage_code        text,
    entity_type       text NOT NULL,
    entity_id         uuid NOT NULL,
    business_ref      text,
    summary           text,
    amount            numeric(18,2),
    requested_by      uuid NOT NULL,
    requested_at      timestamptz NOT NULL DEFAULT now(),
    required_role_id  uuid,
    beneficiary_user_id uuid,                        -- for "cannot approve own benefit" checks
    round_no          integer NOT NULL DEFAULT 1,
    status            text NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING','APPROVED','REJECTED','RETURNED','WITHDRAWN','CANCELLED')),
    closed_at         timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_policy_id) REFERENCES wf.approval_policy (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id),
    FOREIGN KEY (tenant_id, requested_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, required_role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, beneficiary_user_id) REFERENCES iam.app_user (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS approval_request_pending_idx ON wf.approval_request (tenant_id, required_role_id) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS approval_request_entity_idx ON wf.approval_request (tenant_id, entity_type, entity_id);

-- One decision per request round; offline decisions are never shown as online.
CREATE TABLE IF NOT EXISTS wf.approval_decision (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    approval_request_id uuid NOT NULL,
    round_no          integer NOT NULL DEFAULT 1,
    decision          text NOT NULL CHECK (decision IN ('APPROVED','REJECTED','RETURNED')),
    approval_channel  text NOT NULL CHECK (approval_channel IN ('ONLINE','OFFLINE')),
    approval_method   text NOT NULL CHECK (approval_method IN ('ONLINE','VERBAL','MEETING','DOCUMENT','PHONE','OTHER')),
    approved_by       uuid NOT NULL,                 -- actual decision maker
    approver_role_id  uuid NOT NULL,
    decision_date     date NOT NULL,                 -- actual decision date
    recorded_by       uuid NOT NULL,                 -- person entering the decision
    recorded_at       timestamptz NOT NULL DEFAULT now(),
    evidence_type_id  uuid,
    meeting_id        uuid,
    delegation_id     uuid,
    reason            text,                          -- mandatory for reject / return
    remarks           text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, approval_request_id, round_no),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, approver_role_id) REFERENCES iam.role (tenant_id, id),
    FOREIGN KEY (tenant_id, recorded_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, evidence_type_id) REFERENCES wf.offline_evidence_type (tenant_id, id),
    FOREIGN KEY (tenant_id, meeting_id) REFERENCES wf.approval_meeting (tenant_id, id),
    FOREIGN KEY (tenant_id, delegation_id) REFERENCES wf.approval_delegation (tenant_id, id),
    CONSTRAINT approval_online_consistency CHECK (
        approval_channel = 'OFFLINE' OR (approval_method = 'ONLINE' AND recorded_by = approved_by)),
    CONSTRAINT approval_offline_consistency CHECK (
        approval_channel = 'ONLINE' OR (approval_method <> 'ONLINE' AND evidence_type_id IS NOT NULL)),
    CONSTRAINT approval_reason_required CHECK (decision = 'APPROVED' OR reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS wf.approval_participant (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    approval_request_id uuid NOT NULL,
    user_id         uuid NOT NULL,
    role_id         uuid,
    participation   text NOT NULL CHECK (participation IN ('REQUESTER','APPROVER','DELEGATE','RECORDER','VERIFIER')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES iam.role (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS wf.approval_evidence (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    approval_decision_id uuid NOT NULL,
    document_id     uuid,
    description     text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_decision_id) REFERENCES wf.approval_decision (tenant_id, id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES core.document (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS wf.approval_verification (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    approval_request_id uuid NOT NULL,
    verified_by     uuid NOT NULL,
    verified_at     timestamptz NOT NULL DEFAULT now(),
    result          text NOT NULL CHECK (result IN ('VERIFIED','DISCREPANCY')),
    remarks         text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, verified_by) REFERENCES iam.app_user (tenant_id, id)
);

-- Approval integrity: approver differs from requester / beneficiary / recorder
-- (where required) and record-only users cannot record decisions.
CREATE OR REPLACE FUNCTION wf.trg_approval_decision_check()
RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    v_req     wf.approval_request%ROWTYPE;
    v_distinct boolean := true;
BEGIN
    SELECT * INTO v_req FROM wf.approval_request
     WHERE tenant_id = NEW.tenant_id AND id = NEW.approval_request_id;

    IF v_req.status <> 'PENDING' THEN
        PERFORM app.fail('REQUEST_CLOSED', 'The approval request is no longer pending');
    END IF;

    SELECT coalesce(p.require_distinct_identities, true) INTO v_distinct
      FROM wf.approval_policy p WHERE p.tenant_id = NEW.tenant_id AND p.id = v_req.approval_policy_id;
    v_distinct := coalesce(v_distinct, true);

    IF NEW.approved_by = v_req.requested_by THEN
        PERFORM app.fail('SOD_SELF_APPROVAL', 'The approver must be a different person from the requester');
    END IF;
    IF NEW.approved_by = v_req.beneficiary_user_id THEN
        PERFORM app.fail('SOD_SELF_BENEFIT', 'A user cannot approve a request they benefit from');
    END IF;
    IF NEW.approval_channel = 'OFFLINE' AND v_distinct
       AND (NEW.recorded_by = NEW.approved_by) THEN
        PERFORM app.fail('SOD_RECORDER', 'Requested By, Approved By and Recorded By must be different people');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam.app_user u
                    WHERE u.tenant_id = NEW.tenant_id AND u.id = NEW.recorded_by
                      AND (u.web_access OR u.mobile_access)) THEN
        PERFORM app.fail('RECORD_ONLY_USER', 'A record-only user cannot record a decision');
    END IF;
    IF NEW.approval_channel = 'OFFLINE' AND NOT EXISTS (
        SELECT 1 FROM wf.offline_recorder_role orr
          JOIN iam.user_role ur ON ur.tenant_id = orr.tenant_id AND ur.role_id = orr.role_id
         WHERE orr.tenant_id = NEW.tenant_id AND ur.user_id = NEW.recorded_by
           AND (orr.approval_policy_id IS NULL OR orr.approval_policy_id = v_req.approval_policy_id)
           AND (ur.effective_to IS NULL OR ur.effective_to >= current_date)) THEN
        PERFORM app.fail('NOT_OFFLINE_RECORDER', 'The recording user''s role is not permitted to record offline decisions');
    END IF;

    UPDATE wf.approval_request
       SET status = NEW.decision, closed_at = now()
     WHERE tenant_id = NEW.tenant_id AND id = NEW.approval_request_id;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS approval_decision_check ON wf.approval_decision;
CREATE TRIGGER approval_decision_check BEFORE INSERT ON wf.approval_decision
    FOR EACH ROW EXECUTE FUNCTION wf.trg_approval_decision_check();
