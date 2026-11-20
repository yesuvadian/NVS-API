-- =============================================================================
-- CFMS / NVS  -  49e  LOAN_APPLICATION v4: transitions as buttons, ordered
--                     action sequences
-- -----------------------------------------------------------------------------
-- Run as nvs after 49d. Safe to re-run.
-- Same behaviour as v3; the transitions gain button metadata (code, label in
-- English and Tamil, style, confirm, actor, input form) and their actions
-- become ordered sequences [{seq, code, onError}]. The API's start-up sync
-- writes the full action registry; WITHDRAW_APPLICATION is seeded here so a
-- fresh build can publish v4 before the API has started.
-- =============================================================================
SET app.channel TO 'MIGRATION';
SET app.reason TO 'Loan workflow v4: transitions as buttons, ordered action sequences';

INSERT INTO platform.action_definition (action_code, name, name_translations, description, category, action_kind,
                                        default_execution_type, config_schema, implementation_version, status,
                                        approved_at, approval_reason, supported_entities, supported_events)
VALUES ('WITHDRAW_APPLICATION', 'Withdraw application',
        '{"en": "Withdraw application", "ta": "விண்ணப்பத்தைத் திரும்பப் பெறு"}',
        'Withdraw before approval: closes the approval request, its task and the workflow', 'Loan', 'DATA',
        'SYNCHRONOUS', '{"type": "object", "additionalProperties": false}', '1', 'APPROVED', now(),
        'Shipped with the platform', ARRAY['LOAN'], ARRAY['onTransition'])
ON CONFLICT (action_code) DO NOTHING;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 4, 'PUBLISHED',
       jsonb_set(platform.loan_workflow_buttons(v.definition), '{version}', '4'),
       v.json_schema_id, 'Transitions as buttons; ordered action sequences', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id AND v.version_no = 3
 WHERE t.template_kind = 'WORKFLOW' AND t.code = 'LOAN_APPLICATION'
ON CONFLICT (template_id, version_no) DO NOTHING;

DO $$
DECLARE
    t      record;
    w      record;
    v_next integer;
    v_today date;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        v_today := app.tenant_today(t.id);
        SELECT d.id AS definition_id, v.definition, v.json_schema_id INTO w
          FROM cfg.workflow_definition d
          JOIN cfg.workflow_version v ON v.id = cfg.workflow_version_at('LOAN_APPLICATION', v_today, t.id)
         WHERE d.tenant_id = t.id AND d.code = 'LOAN_APPLICATION';
        IF w.definition_id IS NULL
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(w.definition -> 'transitions') x WHERE x ? 'label') THEN
            CONTINUE;
        END IF;
        UPDATE cfg.workflow_version SET status = 'RETIRED'
         WHERE workflow_definition_id = w.definition_id AND status = 'PUBLISHED' AND effective_from = v_today;
        SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.workflow_version WHERE workflow_definition_id = w.definition_id;
        INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                          json_schema_id, effective_from, reason, source)
        VALUES (t.id, w.definition_id, v_next, 'PUBLISHED',
                jsonb_set(platform.loan_workflow_buttons(w.definition), '{version}', to_jsonb(v_next)),
                w.json_schema_id, v_today, 'Transitions as buttons; ordered action sequences', 'TEMPLATE');
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;
