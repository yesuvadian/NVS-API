-- =============================================================================
-- CFMS / NVS  -  49c  Seed: workflow engine and configured business values
-- -----------------------------------------------------------------------------
-- Run as nvs after 49b. Safe to re-run.
--   1. LOAN_APPLICATION workflow v2 (rule checks on transitions; db/31g) and
--      v3 (stage approval roles, maker actorPrivilege, actions; db/31h), as a
--      template version and as a new published version for each organisation.
--   2. Settings that replace literals in code (approver roles, durations,
--      limits): definitions, template v1 defaults and existing organisations.
-- =============================================================================

SET app.channel TO 'MIGRATION';
SET app.reason TO 'Loan workflow v2: rules linked to transitions; nominee checked at approval';

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 2, 'PUBLISHED',
       jsonb_set(platform.loan_workflow_with_rule_checks(v.definition), '{version}', '2'),
       v.json_schema_id, 'Rules linked to transitions; nominee checked at approval and disbursement', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id AND v.version_no = 1
 WHERE t.template_kind = 'WORKFLOW' AND t.code = 'LOAN_APPLICATION'
ON CONFLICT (template_id, version_no) DO NOTHING;

DO $$
DECLARE
    t      record;
    w      record;
    v_next integer;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        SELECT d.id AS definition_id, v.definition, v.json_schema_id INTO w
          FROM cfg.workflow_definition d
          JOIN cfg.workflow_version v ON v.id = cfg.workflow_version_at('LOAN_APPLICATION', app.tenant_today(t.id), t.id)
         WHERE d.tenant_id = t.id AND d.code = 'LOAN_APPLICATION';
        IF w.definition_id IS NULL
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(w.definition -> 'transitions') x WHERE x ? 'ruleChecks') THEN
            CONTINUE;
        END IF;
        SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.workflow_version WHERE workflow_definition_id = w.definition_id;
        INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                          json_schema_id, effective_from, reason, source)
        VALUES (t.id, w.definition_id, v_next, 'PUBLISHED',
                jsonb_set(platform.loan_workflow_with_rule_checks(w.definition), '{version}', to_jsonb(v_next)),
                w.json_schema_id, app.tenant_today(t.id),
                'Rules linked to transitions; nominee checked at approval and disbursement', 'TEMPLATE');
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;

SET app.channel TO 'MIGRATION';
SET app.reason TO 'Loan workflow v3: approval roles and actions configured in the workflow';

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 3, 'PUBLISHED',
       jsonb_set(platform.loan_workflow_stage_statuses(platform.loan_workflow_engine_config(v.definition)), '{version}', '3'),
       v.json_schema_id, 'Approval roles and actions configured in the workflow', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id AND v.version_no = 2
 WHERE t.template_kind = 'WORKFLOW' AND t.code = 'LOAN_APPLICATION'
ON CONFLICT (template_id, version_no) DO NOTHING;

UPDATE platform.config_template_version tv
   SET definition = jsonb_set(platform.loan_workflow_stage_statuses(platform.loan_workflow_engine_config(v2.definition)), '{version}', '3')
  FROM platform.config_template t, platform.config_template_version v2
 WHERE tv.template_id = t.id AND tv.version_no = 3 AND v2.template_id = t.id AND v2.version_no = 2
   AND t.template_kind = 'WORKFLOW' AND t.code = 'LOAN_APPLICATION'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(tv.definition -> 'stages') s WHERE s ? 'role' OR NOT s ? 'statuses');

DO $$
DECLARE
    t      record;
    w      record;
    v_next integer;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        SELECT d.id AS definition_id, v.id AS version_id, v.definition, v.json_schema_id INTO w
          FROM cfg.workflow_definition d
          JOIN cfg.workflow_version v ON v.id = cfg.workflow_version_at('LOAN_APPLICATION', app.tenant_today(t.id), t.id)
         WHERE d.tenant_id = t.id AND d.code = 'LOAN_APPLICATION';
        IF w.definition_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(w.definition -> 'stages') x WHERE x ? 'role' OR NOT x ? 'statuses') THEN
            CONTINUE;
        END IF;
        -- strip engine keys a pre-release copy may already have, then re-apply
        w.definition := jsonb_set(w.definition, '{transitions}', (
            SELECT jsonb_agg(x - 'actions' - 'stageStatus' - 'entityStatus' ORDER BY ord)
              FROM jsonb_array_elements(w.definition -> 'transitions') WITH ORDINALITY y(x, ord)));
        UPDATE cfg.workflow_version SET status = 'RETIRED'
         WHERE workflow_definition_id = w.definition_id AND status = 'PUBLISHED'
           AND effective_from = app.tenant_today(t.id);
        SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.workflow_version WHERE workflow_definition_id = w.definition_id;
        INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                          json_schema_id, effective_from, reason, source)
        VALUES (t.id, w.definition_id, v_next, 'PUBLISHED',
                jsonb_set(platform.loan_workflow_stage_statuses(platform.loan_workflow_engine_config(w.definition)), '{version}', to_jsonb(v_next)),
                w.json_schema_id, app.tenant_today(t.id),
                'Approval roles and actions configured in the workflow', 'TEMPLATE');
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;

-- -----------------------------------------------------------------------------
-- 2. Settings that replace literals in code. Approver-role lists are JSON
--    arrays of role codes; durations are days.
-- -----------------------------------------------------------------------------
SET app.channel TO 'MIGRATION';
WITH s(setting_key, area, name, data_type, editable_by, value, scope_ref, is_proposed, sort_order) AS (VALUES
 ('loans.waiver_approver_roles','Loans','Roles that approve fee/charge waivers','list','SUPER_ADMIN','["MGR"]'::jsonb,'6.11',false,74),
 ('loans.cooling_off_override_approver_roles','Loans','Roles that approve cooling-off overrides','list','SUPER_ADMIN','["MGR"]','6.11',false,75),
 ('loans.cooling_off_override_valid_days','Loans','Cooling-off override valid for (days, when no date is given)','integer','SUPER_ADMIN','30','6.11',false,76),
 ('loans.cancellation_approver_roles','Loans','Roles that approve loan cancellations','list','SUPER_ADMIN','["MGR","LDR"]','6.11',false,77),
 ('loans.guarantor_replacement_approver_roles','Loans','Roles that approve guarantor replacements','list','SUPER_ADMIN','["MGR","LDR"]','6.11',false,78),
 ('loans.restructure_approver_roles','Loans','Roles that approve restructuring','list','SUPER_ADMIN','["MGR","LDR"]','6.11',false,79),
 ('loans.deceased_decision_approver_roles','Loans','Roles that decide loans of deceased members','list','SUPER_ADMIN','["MGR","LDR"]','6.11',false,80),
 ('loans.transfer_approver_roles','Loans','Roles that approve loan transfers','list','SUPER_ADMIN','["MGR","LDR"]','6.11',false,81),
 ('loans.migration_review_approver_roles','Loans','Roles that decide migrated-loan reviews','list','SUPER_ADMIN','["MGR","LDR"]','6.11',false,82),
 ('loans.max_nominees_per_loan','Loans','Maximum nominees linked to one loan','integer','SUPER_ADMIN','10','6.1',false,83),
 ('recovery.exception_approver_roles','Recovery','Roles that approve recovery exceptions','list','SUPER_ADMIN','["MGR","LDR"]','28.5',false,84),
 ('recovery.escalate_to_manager_role','Recovery','Role that receives cases escalated to the manager level','string','SUPER_ADMIN','"MGR"','28.5',false,85),
 ('recovery.escalate_to_leadership_role','Recovery','Role that receives cases escalated to the leadership level','string','SUPER_ADMIN','"LDR"','28.5',false,86),
 ('recovery.first_follow_up_days','Recovery','First follow-up after a recovery case opens (days)','integer','SUPER_ADMIN','3','28.5',false,87),
 ('recovery.follow_up_interval_days','Recovery','Next follow-up after a contact, when none is given (days)','integer','SUPER_ADMIN','7','28.5',false,88)
),
d AS (
    INSERT INTO platform.setting_definition (setting_key, area, name, data_type, editable_by, scope_ref, is_proposed, sort_order)
    SELECT setting_key, area, name, data_type, editable_by, scope_ref, is_proposed, sort_order FROM s
    ON CONFLICT (setting_key) DO UPDATE SET area = EXCLUDED.area, name = EXCLUDED.name, data_type = EXCLUDED.data_type,
        editable_by = EXCLUDED.editable_by, scope_ref = EXCLUDED.scope_ref, is_proposed = EXCLUDED.is_proposed,
        sort_order = EXCLUDED.sort_order
    RETURNING setting_key
)
INSERT INTO platform.settings_template_item (version_no, setting_key, value)
SELECT 1, s.setting_key, s.value FROM s
ON CONFLICT DO NOTHING;

SET app.scope TO 'platform';
INSERT INTO cfg.tenant_setting (tenant_id, setting_key, value, effective_from, status, source, template_version, reason)
SELECT t.id, i.setting_key, i.value, DATE '2000-01-01', 'ACTIVE', 'TEMPLATE', 1,
       'Default added from settings template v1 (values moved out of code)'
  FROM platform.tenant t
  JOIN platform.settings_template_item i ON i.version_no = 1
 WHERE i.setting_key IN ('loans.waiver_approver_roles','loans.cooling_off_override_approver_roles',
                         'loans.cooling_off_override_valid_days','loans.cancellation_approver_roles',
                         'loans.guarantor_replacement_approver_roles','loans.restructure_approver_roles',
                         'loans.deceased_decision_approver_roles','loans.transfer_approver_roles',
                         'loans.migration_review_approver_roles','loans.max_nominees_per_loan',
                         'recovery.exception_approver_roles','recovery.escalate_to_manager_role',
                         'recovery.escalate_to_leadership_role','recovery.first_follow_up_days',
                         'recovery.follow_up_interval_days')
   AND NOT EXISTS (SELECT 1 FROM cfg.tenant_setting x WHERE x.tenant_id = t.id AND x.setting_key = i.setting_key);
RESET app.scope;
RESET app.channel;
