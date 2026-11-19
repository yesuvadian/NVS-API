-- =============================================================================
-- CFMS / NVS  -  49a  Nominee rules as ordinary rule-set rules
-- -----------------------------------------------------------------------------
-- Run as nvs after 49 (and 31d). Safe to re-run.
--
-- A. Loan types: the NOMINEE rule gains "everyLoan": true (every new loan
--    application needs an ACTIVE nominee). "thresholdAmount" (nominee needed
--    when the amount is at or above it) is now evaluated too.
--      * template versions 2 for LOAN_TYPE_* (new organisations clone these)
--      * existing organisations: a new published version of each loan-type
--        rule set, effective from the organisation's today. Loans already
--        created keep their rule snapshot.
-- B. Members: a GENERAL rule set MEMBER_RULES (module NOMINEE) with rule
--    NOMINATIONS {"maxPerPerson": 2, "maxPerMember": null}: a person can be an
--    active nominee for at most 2 members (null = no limit).
--      * template MEMBER_RULES v1 (provisioning clones it for new orgs)
--      * existing organisations: rule set + published version 1
-- Both are ordinary rules, editable later through the Super Admin rules API.
-- =============================================================================
SET app.channel TO 'MIGRATION';
SET app.reason TO 'Nominee rules: every loan needs a nominee; nominations per person';

-- Template versions -----------------------------------------------------------
INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 2, 'PUBLISHED',
       jsonb_set(jsonb_set(v.definition, '{version}', '2'), '{rules}', (
           SELECT jsonb_agg(CASE WHEN r ->> 'code' = 'NOMINEE'
                                 THEN jsonb_set(r, '{value}', (r -> 'value') || '{"everyLoan": true}')
                                 ELSE r END)
             FROM jsonb_array_elements(v.definition -> 'rules') r)),
       v.json_schema_id, 'Every new loan needs a nominee (NOMINEE.everyLoan)', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id AND v.version_no = 1
 WHERE t.template_kind = 'RULESET' AND t.code LIKE 'LOAN_TYPE_%'
ON CONFLICT (template_id, version_no) DO NOTHING;

INSERT INTO platform.config_template (template_kind, code, name, module_code, entity_type, description)
VALUES ('RULESET', 'MEMBER_RULES', 'Member rules', 'NOMINEE', 'mbr.nominee',
        'Nominations: how many members one person can be a nominee for')
ON CONFLICT (template_kind, code) DO NOTHING;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 1, 'PUBLISHED',
       jsonb_build_object('ruleSet', 'MEMBER_RULES', 'version', 1, 'schemaVersion', '1.0',
           'rules', jsonb_build_array(
               jsonb_build_object('code', 'NOMINATIONS',
                                  'value', jsonb_build_object('maxPerPerson', 2, 'maxPerMember', NULL)))),
       (SELECT id FROM platform.json_schema WHERE schema_kind = 'RULESET' AND schema_version = '1.0'),
       'Initial template', now()
  FROM platform.config_template t
 WHERE t.template_kind = 'RULESET' AND t.code = 'MEMBER_RULES'
ON CONFLICT (template_id, version_no) DO NOTHING;

-- Existing organisations ------------------------------------------------------
DO $$
DECLARE
    t       record;
    rs      record;
    v_def   jsonb;
    v_next  integer;
    v_tpl   record;
    v_rs_id uuid;
BEGIN
    SELECT tv.id AS tv_id, tv.version_no, tv.definition, tv.json_schema_id, ct.id AS template_id,
           ct.code, ct.name, ct.module_code
      INTO v_tpl
      FROM platform.config_template ct
      JOIN platform.config_template_version tv ON tv.template_id = ct.id AND tv.version_no = 1
     WHERE ct.template_kind = 'RULESET' AND ct.code = 'MEMBER_RULES';

    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);

        -- A. NOMINEE.everyLoan on each loan-type rule set still without it.
        FOR rs IN
            SELECT s.id, v.definition, v.json_schema_id
              FROM cfg.rule_set s
              JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(s.id, app.tenant_today(t.id))
             WHERE s.tenant_id = t.id AND s.scope_type = 'LOAN_TYPE'
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(v.definition -> 'rules') r
                            WHERE r ->> 'code' = 'NOMINEE'
                              AND NOT coalesce((r -> 'value' ->> 'everyLoan')::boolean, false))
        LOOP
            SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.rule_set_version WHERE rule_set_id = rs.id;
            v_def := jsonb_set(rs.definition, '{rules}', (
                SELECT jsonb_agg(CASE WHEN r ->> 'code' = 'NOMINEE'
                                      THEN jsonb_set(r, '{value}', (r -> 'value') || '{"everyLoan": true}')
                                      ELSE r END)
                  FROM jsonb_array_elements(rs.definition -> 'rules') r));
            v_def := jsonb_set(v_def, '{version}', to_jsonb(v_next));
            INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                              effective_from, reason, source)
            VALUES (t.id, rs.id, v_next, 'PUBLISHED', v_def, rs.json_schema_id, app.tenant_today(t.id),
                    'Every new loan needs a nominee (NOMINEE.everyLoan)', 'TEMPLATE');
        END LOOP;

        -- B. MEMBER_RULES rule set with NOMINATIONS.
        IF v_tpl.template_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM cfg.rule_set WHERE tenant_id = t.id AND code = 'MEMBER_RULES') THEN
            INSERT INTO cfg.rule_set (tenant_id, code, name, module_code, scope_type, template_id, template_version)
            VALUES (t.id, v_tpl.code, v_tpl.name, v_tpl.module_code, 'GENERAL', v_tpl.template_id, v_tpl.version_no)
            RETURNING id INTO v_rs_id;
            INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                              effective_from, reason, source, source_template_version_id)
            VALUES (t.id, v_rs_id, 1, 'PUBLISHED', v_tpl.definition, v_tpl.json_schema_id, DATE '2000-01-01',
                    'Cloned from template MEMBER_RULES v1', 'TEMPLATE', v_tpl.tv_id);
        END IF;
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;
