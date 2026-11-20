-- =============================================================================
-- CFMS / NVS  -  31h  Workflow engine: stage -> rule checks -> actions
-- -----------------------------------------------------------------------------
-- Run as nvs after 31g. Safe to re-run.
--
-- All configuration stays in the versioned workflow JSON (cfg.workflow_version
-- .definition): stages (with "approval" settings), transitions (with
-- "ruleChecks" and "actions"). Relational pieces are only:
--   * the action registry (platform.action_definition + cfg.tenant_action):
--     handler codes with a parameter JSON Schema in config_schema;
--   * runtime state: wf.approval_request gains the approver roles, minimum
--     approvals, approvals given and routed checks of each request;
--   * the execution log (wf.action_execution) written by the engine.
-- The engine itself is app/workflow/engine.py.
--
-- Stage approval settings:
--   {"approval": {"roles": ["MGR"], "minApprovals": 1, "allowOfflineRecording": true,
--                 "offlineRecorderRoles": ["EMP","MGR"],
--                 "amountBands": [{"minAmount": 100000, "roles": ["LDR"], "minApprovals": 1}]}}
-- Transition actions: {"actions": [{"action": "CREATE_APPROVAL_REQUEST", "params": {}}]}
-- =============================================================================

-- Engine handlers (core actions wrap the existing SQL functions, so journals,
-- receipts and SMS stay exactly as before).
INSERT INTO platform.action_definition (action_code, name, description, category, action_kind,
                                        default_execution_type, config_schema, implementation_version,
                                        status, approved_at, approval_reason)
VALUES
 ('RULE_CHECKS', 'Rule checks', 'Evaluate the rule checks of a transition (logged for audit and statistics)',
  'Validation', 'VALIDATION', 'SYNCHRONOUS', '{"type": "object", "additionalProperties": false}', '1',
  'APPROVED', now(), 'Workflow engine'),
 ('CREATE_APPROVAL_REQUEST', 'Create approval request',
  'Submit the application and open an approval request for the next stage (roles from the stage approval settings)',
  'Approval', 'APPROVAL', 'SYNCHRONOUS', '{"type": "object", "additionalProperties": false}', '1',
  'APPROVED', now(), 'Workflow engine'),
 ('RECORD_APPROVAL_DECISION', 'Record approval decision',
  'Record an approve / reject / return decision; approve completes when minApprovals distinct approvers agreed',
  'Approval', 'APPROVAL', 'SYNCHRONOUS', '{"type": "object", "additionalProperties": false}', '1',
  'APPROVED', now(), 'Workflow engine'),
 ('SET_STATUS', 'Set statuses',
  'Record the stage status and set the entity status declared by the workflow (logged for audit)',
  'Data', 'DATA', 'SYNCHRONOUS', '{"type": "object", "additionalProperties": false}', '1',
  'APPROVED', now(), 'Workflow engine'),
 ('RELEASE_DISBURSEMENT', 'Release disbursement',
  'Release a prepared disbursement (cash receipt, journal, schedule, SMS)', 'Data', 'DATA', 'SYNCHRONOUS',
  '{"type": "object", "additionalProperties": false}', '1', 'APPROVED', now(), 'Workflow engine')
ON CONFLICT (action_code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
    category = EXCLUDED.category, action_kind = EXCLUDED.action_kind, config_schema = EXCLUDED.config_schema,
    implementation_version = EXCLUDED.implementation_version, status = 'APPROVED';

UPDATE platform.action_definition
   SET config_schema = '{"type": "object", "required": ["template"], "additionalProperties": false,
                         "properties": {"template": {"type": "string", "minLength": 1},
                                        "channel": {"enum": ["SMS", "WHATSAPP", "EMAIL"]}}}'::jsonb
 WHERE action_code = 'SEND_NOTIFICATION' AND config_schema IS NULL;

ALTER TABLE wf.approval_request ADD COLUMN IF NOT EXISTS approver_roles text[];
ALTER TABLE wf.approval_request ADD COLUMN IF NOT EXISTS min_approvals integer NOT NULL DEFAULT 1;
ALTER TABLE wf.approval_request ADD COLUMN IF NOT EXISTS approvals jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE wf.approval_request ADD COLUMN IF NOT EXISTS routed_checks text[] NOT NULL DEFAULT '{}';
ALTER TABLE wf.approval_request ADD COLUMN IF NOT EXISTS allow_offline boolean;
ALTER TABLE wf.approval_request ADD COLUMN IF NOT EXISTS offline_recorder_roles text[];
-- Stage status of the instance's current stage (codes come from the workflow JSON).
ALTER TABLE wf.workflow_instance ADD COLUMN IF NOT EXISTS current_stage_status text;

DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT id FROM platform.tenant LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        INSERT INTO cfg.tenant_action (tenant_id, action_code, is_enabled, reason)
        SELECT t.id, a, true, 'Workflow engine actions (31h)'
          FROM unnest(ARRAY['RULE_CHECKS','CREATE_APPROVAL_REQUEST','RECORD_APPROVAL_DECISION','RELEASE_DISBURSEMENT']) a
         WHERE NOT EXISTS (SELECT 1 FROM cfg.tenant_action ta WHERE ta.tenant_id = t.id AND ta.action_code = a);
    END LOOP;
    PERFORM app.clear_context();
END
$$;

-- Engine helpers -------------------------------------------------------------
-- Apply a stage's approval settings to an open request (roles chosen by the
-- highest amount band the amount reaches; the first role also fills the
-- legacy required_role_id).
CREATE OR REPLACE FUNCTION wf.configure_approval_request(
    p_request_id uuid, p_roles text[], p_min_approvals integer, p_allow_offline boolean,
    p_offline_recorder_roles text[])
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE wf.approval_request
       SET approver_roles = p_roles, min_approvals = greatest(coalesce(p_min_approvals, 1), 1),
           allow_offline = p_allow_offline, offline_recorder_roles = p_offline_recorder_roles,
           required_role_id = coalesce((SELECT r.id FROM iam.role r
                                         WHERE r.tenant_id = app.tenant_id() AND r.role_code = p_roles[1]
                                           AND r.status = 'ACTIVE'), required_role_id)
     WHERE tenant_id = app.tenant_id() AND id = p_request_id;
END
$$;

-- Record one approver's agreement (distinct people, never the requester).
-- Returns the approvals collected so far.
DROP FUNCTION IF EXISTS wf.add_approval(uuid, text);
CREATE OR REPLACE FUNCTION wf.add_approval(p_request_id uuid, p_role_code text, p_user_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_req  wf.approval_request%ROWTYPE;
    v_user uuid := coalesce(p_user_id, app.user_id());
BEGIN
    SELECT * INTO v_req FROM wf.approval_request
     WHERE tenant_id = app.tenant_id() AND id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('APPROVAL_REQUEST_NOT_FOUND', 'Approval request not found'); END IF;
    IF v_req.status <> 'PENDING' THEN PERFORM app.fail('REQUEST_CLOSED', 'The approval request is no longer pending'); END IF;
    IF v_req.requested_by = v_user THEN
        PERFORM app.fail('SOD_SELF_APPROVAL', 'The person who raised the request cannot approve it.');
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_req.approvals) a WHERE a ->> 'user_id' = v_user::text) THEN
        PERFORM app.fail('APPROVAL_ALREADY_GIVEN', 'You have already approved this request.');
    END IF;
    UPDATE wf.approval_request
       SET approvals = approvals || jsonb_build_array(jsonb_build_object(
               'user_id', v_user, 'role', p_role_code, 'recorded_by', app.user_id(), 'at', now()))
     WHERE tenant_id = app.tenant_id() AND id = p_request_id
    RETURNING approvals INTO v_req.approvals;
    RETURN v_req.approvals;
END
$$;

-- ROUTE_TO_ROLE: hand a pending request to other roles (approvals restart).
CREATE OR REPLACE FUNCTION wf.route_approval_request(p_request_id uuid, p_roles text[], p_check text)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM app.set_audit_reason(format('Routed to %s by rule check %s', array_to_string(p_roles, ', '), p_check),
                                 'WORKFLOW_ROUTE', p_request_id::text);
    UPDATE wf.approval_request
       SET approver_roles = p_roles, approvals = '[]'::jsonb, min_approvals = 1,
           routed_checks = array_append(routed_checks, p_check),
           required_role_id = coalesce((SELECT r.id FROM iam.role r
                                         WHERE r.tenant_id = app.tenant_id() AND r.role_code = p_roles[1]
                                           AND r.status = 'ACTIVE'), required_role_id)
     WHERE tenant_id = app.tenant_id() AND id = p_request_id AND status = 'PENDING';
END
$$;

CREATE OR REPLACE FUNCTION wf.approval_request_state(p_request_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object('id', ar.id, 'status', ar.status, 'approver_roles', ar.approver_roles,
                              'min_approvals', ar.min_approvals, 'approvals', ar.approvals,
                              'routed_checks', ar.routed_checks, 'allow_offline', ar.allow_offline,
                              'offline_recorder_roles', ar.offline_recorder_roles,
                              'requested_by', ar.requested_by, 'entity_id', ar.entity_id, 'amount', ar.amount)
      FROM wf.approval_request ar
     WHERE ar.tenant_id = app.tenant_id() AND ar.id = p_request_id
$$;

-- Approval inbox: requests whose approver roles include the user's active
-- role (or, for requests without engine roles, the legacy required role);
-- never the user's own requests or ones they already approved.
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
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ar.approvals) a WHERE a ->> 'user_id' = app.user_id()::text)
       AND EXISTS (
           SELECT 1 FROM iam.user_role ur
           JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
            WHERE ur.tenant_id = ar.tenant_id AND ur.user_id = app.user_id()
              AND r.role_code = app.role_code() AND r.status = 'ACTIVE'
              AND ur.effective_from <= app.working_date()
              AND (ur.effective_to IS NULL OR ur.effective_to >= app.working_date())
              AND (CASE WHEN ar.approver_roles IS NOT NULL THEN r.role_code = ANY (ar.approver_roles)
                        ELSE ur.role_id = ar.required_role_id END))
     ORDER BY ar.requested_at, ar.request_no
     LIMIT greatest(1, least(p_limit, 501)) OFFSET greatest(p_offset, 0)
$$;

REVOKE ALL ON FUNCTION wf.configure_approval_request(uuid, text[], integer, boolean, text[]),
    wf.add_approval(uuid, text, uuid), wf.route_approval_request(uuid, text[], text),
    wf.approval_request_state(uuid), loan.get_approval_inbox(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf.configure_approval_request(uuid, text[], integer, boolean, text[]),
    wf.add_approval(uuid, text, uuid), wf.route_approval_request(uuid, text[], text),
    wf.approval_request_state(uuid), loan.get_approval_inbox(integer, integer) TO nvs_app;

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-APPR-5010','APPROVAL_ALREADY_GIVEN','APPR','CONFLICT','WARNING',409,false,false,'You have already approved this request.','Another approver must give the next approval.'),
 ('CFMS-APPR-3010','OFFLINE_RECORDER_ROLE_REQUIRED','APPR','AUTHORISATION','ERROR',403,false,false,'Your role cannot record offline decisions for this approval.','Ask a user whose role may record offline decisions.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('APPROVAL_ALREADY_GIVEN','இந்தக் கோரிக்கைக்கு நீங்கள் ஏற்கனவே ஒப்புதல் அளித்துள்ளீர்கள்.'),
 ('OFFLINE_RECORDER_ROLE_REQUIRED','இந்த ஒப்புதலுக்கு ஆஃப்லைன் முடிவுகளைப் பதிவு செய்ய உங்கள் பங்குக்கு அனுமதி இல்லை.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;

-- Approval settings of a workflow stage for an amount: the stage's roles and
-- minimum, replaced by the highest amount band the amount reaches.
-- Refuses when the stage has no approval roles (nothing in code to fall back on).
CREATE OR REPLACE FUNCTION wf.stage_approval_config(p_workflow_version_id uuid, p_stage_code text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_approval jsonb;
    v_band     jsonb;
BEGIN
    SELECT s -> 'approval' INTO v_approval
      FROM cfg.workflow_version v, jsonb_array_elements(v.definition -> 'stages') s
     WHERE v.tenant_id = app.tenant_id() AND v.id = p_workflow_version_id AND s ->> 'code' = p_stage_code;
    IF v_approval IS NULL OR jsonb_array_length(coalesce(v_approval -> 'roles', '[]'::jsonb)) = 0
       OR (v_approval ->> 'minApprovals') IS NULL THEN
        PERFORM app.fail('LOAN_WORKFLOW_NOT_CONFIGURED',
            format('Workflow stage %s has no approval roles and minimum approvals.', p_stage_code));
    END IF;
    SELECT b INTO v_band
      FROM jsonb_array_elements(coalesce(v_approval -> 'amountBands', '[]'::jsonb)) b
     WHERE (b ->> 'minAmount')::numeric <= coalesce(p_amount, 0)
     ORDER BY (b ->> 'minAmount')::numeric DESC LIMIT 1;
    RETURN jsonb_build_object(
        'roles', coalesce(v_band -> 'roles', v_approval -> 'roles'),
        'minApprovals', coalesce((v_band ->> 'minApprovals')::integer, (v_approval ->> 'minApprovals')::integer),
        'allowOffline', coalesce((v_approval ->> 'allowOfflineRecording')::boolean, false),
        'offlineRecorderRoles', coalesce(v_approval -> 'offlineRecorderRoles', '[]'::jsonb),
        'band', v_band);
END
$$;
REVOKE ALL ON FUNCTION wf.stage_approval_config(uuid, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf.stage_approval_config(uuid, text, numeric) TO nvs_app;

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
    -- Offline recorders: the workflow stage's offlineRecorderRoles when the
    -- engine configured the request, else the legacy wf.offline_recorder_role.
    IF NEW.approval_channel = 'OFFLINE' AND v_req.offline_recorder_roles IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM iam.user_role ur
              JOIN iam.role r ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id AND r.status = 'ACTIVE'
             WHERE ur.tenant_id = NEW.tenant_id AND ur.user_id = NEW.recorded_by
               AND r.role_code = ANY (v_req.offline_recorder_roles)
               AND (ur.effective_to IS NULL OR ur.effective_to >= current_date)) THEN
            PERFORM app.fail('OFFLINE_RECORDER_ROLE_REQUIRED', 'Your role cannot record offline decisions for this approval.');
        END IF;
    ELSIF NEW.approval_channel = 'OFFLINE' AND NOT EXISTS (
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

-- Statuses an entity table allows: the fixed domain set in its status CHECK.
CREATE OR REPLACE FUNCTION cfg.entity_statuses(p_entity text)
RETURNS text[] LANGUAGE sql STABLE AS
$$
    SELECT array_agg(DISTINCT m[1] ORDER BY m[1])
      FROM pg_constraint c
      CROSS JOIN LATERAL regexp_matches(pg_get_constraintdef(c.oid), '''([A-Z_]+)''', 'g') m
     WHERE c.conrelid = to_regclass(p_entity) AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) ~ '^CHECK \(\(status = ANY'
$$;

-- Apply the statuses a workflow transition declares: the entity status (only
-- when it differs from what the action already set) and the stage status of
-- the instance. Returns the change for the execution log.
CREATE OR REPLACE FUNCTION loan.apply_workflow_status(
    p_loan_id uuid, p_entity_status text, p_instance_id uuid, p_stage_code text, p_stage_status text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_old text;
    v_old_stage text;
    v_old_stage_status text;
BEGIN
    SELECT status INTO v_old FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    IF p_entity_status IS NOT NULL AND p_entity_status IS DISTINCT FROM v_old THEN
        IF NOT p_entity_status = ANY (cfg.entity_statuses('loan.loan')) THEN
            PERFORM app.fail('INVALID_DOCUMENT', format('Status %s is not a loan status', p_entity_status));
        END IF;
        UPDATE loan.loan SET status = p_entity_status, status_date = app.working_date()
         WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    END IF;
    IF p_instance_id IS NOT NULL THEN
        SELECT current_stage_code, current_stage_status INTO v_old_stage, v_old_stage_status
          FROM wf.workflow_instance WHERE tenant_id = app.tenant_id() AND id = p_instance_id FOR UPDATE;
        UPDATE wf.workflow_instance
           SET current_stage_code = coalesce(p_stage_code, current_stage_code),
               current_stage_status = coalesce(p_stage_status, current_stage_status)
         WHERE tenant_id = app.tenant_id() AND id = p_instance_id
           AND (current_stage_code IS DISTINCT FROM coalesce(p_stage_code, current_stage_code)
                OR current_stage_status IS DISTINCT FROM coalesce(p_stage_status, current_stage_status));
    END IF;
    RETURN jsonb_build_object('entity_status_from', v_old, 'entity_status', coalesce(p_entity_status, v_old),
                              'stage_from', v_old_stage, 'stage_status_from', v_old_stage_status,
                              'stage', coalesce(p_stage_code, v_old_stage),
                              'stage_status', coalesce(p_stage_status, v_old_stage_status));
END
$$;
REVOKE ALL ON FUNCTION cfg.entity_statuses(text), loan.apply_workflow_status(uuid, text, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cfg.entity_statuses(text), loan.apply_workflow_status(uuid, text, uuid, text, text) TO nvs_app;

-- Maker steps are decided by privilege, not by role, also in the database:
-- a new application needs loan.create; submitting (DRAFT/RETURNED -> fee or
-- approval) needs loan.create. System and migration contexts (no user) pass;
-- loans created by restructuring or transfer are not DRAFT and are not
-- maker applications.
CREATE OR REPLACE FUNCTION loan.trg_loan_maker_privilege()
RETURNS trigger LANGUAGE plpgsql AS
$$
BEGIN
    IF app.user_id() IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' AND NEW.status = 'DRAFT'
       AND NOT iam.has_privilege(app.user_id(), 'loan.create') THEN
        PERFORM app.fail('NO_PRIVILEGE', 'Creating a loan application needs loan.create');
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status IN ('DRAFT', 'RETURNED')
       AND NEW.status IN ('FEE_PENDING', 'SUBMITTED', 'UNDER_APPROVAL')
       AND NOT iam.has_privilege(app.user_id(), 'loan.create') THEN
        PERFORM app.fail('NO_PRIVILEGE', 'Submitting a loan application needs loan.create');
    END IF;
    RETURN NEW;
END
$$;
DROP TRIGGER IF EXISTS loan_maker_privilege ON loan.loan;
CREATE TRIGGER loan_maker_privilege BEFORE INSERT OR UPDATE OF status ON loan.loan
    FOR EACH ROW EXECUTE FUNCTION loan.trg_loan_maker_privilege();

-- LOAN_APPLICATION workflow v3: approval roles and actions in the JSON ---------
CREATE OR REPLACE FUNCTION platform.loan_workflow_engine_config(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(jsonb_set(p_definition, '{stages}', (
        SELECT jsonb_agg(CASE s ->> 'code'
                   WHEN 'MANAGER_APPROVAL'
                        THEN jsonb_set(s - 'role', '{approval}', coalesce(s -> 'approval', '{}'::jsonb) || jsonb_build_object(
                                 'roles', jsonb_build_array('MGR'), 'minApprovals', 1,
                                 'allowOfflineRecording', true,
                                 'offlineRecorderRoles', jsonb_build_array('EMP', 'MGR')))
                   -- maker stages: anyone holding the privilege acts, not a role
                   WHEN 'DRAFT' THEN (s - 'role') || '{"actorPrivilege": "loan.create"}'::jsonb
                   WHEN 'FEE_COLLECTION' THEN (s - 'role') || '{"actorPrivilege": "loan_fee.create"}'::jsonb
                   WHEN 'APPROVED' THEN (s - 'role') || '{"actorPrivilege": "loan.edit"}'::jsonb
                   ELSE s END ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'stages') WITH ORDINALITY x(s, ord))),
        '{transitions}', (
        SELECT jsonb_agg(CASE
                   WHEN t ->> 'on' = 'SUBMIT'  THEN t || '{"actions": [{"action": "CREATE_APPROVAL_REQUEST"}]}'::jsonb
                   WHEN t ->> 'on' IN ('APPROVE', 'REJECT', 'RETURN')
                        THEN t || '{"actions": [{"action": "RECORD_APPROVAL_DECISION"}]}'::jsonb
                   WHEN t ->> 'on' = 'DISBURSE' THEN t || '{"actions": [{"action": "RELEASE_DISBURSEMENT"}]}'::jsonb
                   ELSE t END
                 -- stage status the transition records in its source stage;
                 -- RETURN keeps today's loan status RETURNED (the DRAFT stage
                 -- itself means DRAFT)
                 || jsonb_build_object('stageStatus', CASE t ->> 'on'
                        WHEN 'SUBMIT' THEN 'SUBMITTED' WHEN 'FEE_PAID' THEN 'PAID' WHEN 'APPROVE' THEN 'APPROVED'
                        WHEN 'REJECT' THEN 'REJECTED' WHEN 'RETURN' THEN 'RETURNED' WHEN 'WITHDRAW' THEN 'WITHDRAWN'
                        WHEN 'DISBURSE' THEN 'DISBURSED' WHEN 'CANCEL' THEN 'CANCELLED' WHEN 'EXPIRE' THEN 'EXPIRED' END)
                 || CASE WHEN t ->> 'on' = 'RETURN' THEN '{"entityStatus": "RETURNED"}'::jsonb ELSE '{}'::jsonb END
                 ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'transitions') WITH ORDINALITY x(t, ord)))
$$;

-- Stage statuses (today's mapping): the loan status each stage sets, the
-- stage's own statuses (labels in English and Tamil) and the initial one.
CREATE OR REPLACE FUNCTION platform.loan_workflow_stage_statuses(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{stages}', (
        SELECT jsonb_agg(s || jsonb_build_object('statuses', jsonb_build_object(
                   'entityStatus', CASE s ->> 'code'
                        WHEN 'DRAFT' THEN 'DRAFT' WHEN 'FEE_COLLECTION' THEN 'FEE_PENDING'
                        WHEN 'MANAGER_APPROVAL' THEN 'UNDER_APPROVAL' WHEN 'APPROVED' THEN 'APPROVED'
                        WHEN 'DISBURSED' THEN 'ACTIVE' WHEN 'REJECTED' THEN 'REJECTED'
                        WHEN 'WITHDRAWN' THEN 'WITHDRAWN' WHEN 'CANCELLED' THEN 'CANCELLED' END,
                   'initial', CASE WHEN s ->> 'code'='DRAFT' THEN 'DRAFT' ELSE 'PENDING' END,
                   'stageStatuses', CASE s ->> 'code'
                        WHEN 'DRAFT' THEN '[{"code":"DRAFT","label":{"en":"Draft","ta":"வரைவு"}},
                                            {"code":"SUBMITTED","label":{"en":"Submitted","ta":"சமர்ப்பிக்கப்பட்டது"}},
                                            {"code":"WITHDRAWN","label":{"en":"Withdrawn","ta":"திரும்பப் பெறப்பட்டது"}}]'::jsonb
                        WHEN 'FEE_COLLECTION' THEN '[{"code":"PENDING","label":{"en":"Fee due","ta":"கட்டணம் நிலுவை"}},
                                            {"code":"PAID","label":{"en":"Fee paid","ta":"கட்டணம் செலுத்தப்பட்டது"}},
                                            {"code":"WITHDRAWN","label":{"en":"Withdrawn","ta":"திரும்பப் பெறப்பட்டது"}}]'::jsonb
                        WHEN 'MANAGER_APPROVAL' THEN '[{"code":"PENDING","label":{"en":"Awaiting approval","ta":"ஒப்புதலுக்குக் காத்திருக்கிறது"}},
                                            {"code":"PARTIALLY_APPROVED","label":{"en":"Partly approved","ta":"பகுதி ஒப்புதல்"}},
                                            {"code":"ROUTED","label":{"en":"Routed","ta":"அனுப்பப்பட்டது"}},
                                            {"code":"APPROVED","label":{"en":"Approved","ta":"ஒப்புதல் அளிக்கப்பட்டது"}},
                                            {"code":"REJECTED","label":{"en":"Rejected","ta":"நிராகரிக்கப்பட்டது"}},
                                            {"code":"RETURNED","label":{"en":"Returned","ta":"திருப்பி அனுப்பப்பட்டது"}},
                                            {"code":"WITHDRAWN","label":{"en":"Withdrawn","ta":"திரும்பப் பெறப்பட்டது"}}]'::jsonb
                        WHEN 'APPROVED' THEN '[{"code":"PENDING","label":{"en":"Ready to disburse","ta":"வழங்கத் தயார்"}},
                                            {"code":"DISBURSED","label":{"en":"Disbursed","ta":"வழங்கப்பட்டது"}},
                                            {"code":"CANCELLED","label":{"en":"Cancelled","ta":"ரத்து செய்யப்பட்டது"}},
                                            {"code":"EXPIRED","label":{"en":"Expired","ta":"காலாவதியானது"}}]'::jsonb
                        ELSE '[{"code":"PENDING","label":{"en":"Done","ta":"முடிந்தது"}}]'::jsonb END)
                 || CASE WHEN s ->> 'code' = 'MANAGER_APPROVAL'
                         THEN '{"onPartialApproval":"PARTIALLY_APPROVED","onRouted":"ROUTED"}'::jsonb
                         ELSE '{}'::jsonb END)
               ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'stages') WITH ORDINALITY x(s, ord)))
$$;

-- Template and organisation seeding: db/49c_seed_workflow_engine.sql (runs after
-- the platform templates exist, so a fresh build gets it too).
