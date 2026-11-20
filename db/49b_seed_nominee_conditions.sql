-- =============================================================================
-- CFMS / NVS  -  49b  NOMINEE rule: conditions instead of "every loan"
-- -----------------------------------------------------------------------------
-- Run as nvs after 49a (and 31g). Safe to re-run.
--
-- Owner decision: the deciding factors for a nominee are the amount, a past
-- default, or the member's first loan - not every loan. The NOMINEE rule value
-- becomes:
--   {"conditions": {"firstLoan": true, "thresholdAmount": 100000,
--                   "defaulter": {"enabled": true, "lookbackMonths": 24}},
--    "allowOverride": true}
-- A nominee is required if ANY enabled condition is met (thresholdAmount null
-- = off; lookbackMonths null = any past default). Replaces the everyLoan
-- versions from 49a: template version 3 for new organisations and a new
-- published rule version for each existing organisation's loan types,
-- effective from its today. Loans keep their rule snapshot.
-- =============================================================================
SET app.channel TO 'MIGRATION';
SET app.reason TO 'NOMINEE rule: first loan, amount threshold or past default';

CREATE OR REPLACE FUNCTION platform.nominee_rule_conditions(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{rules}', (
        SELECT jsonb_agg(CASE WHEN r ->> 'code' = 'NOMINEE' THEN
                   jsonb_build_object('code', 'NOMINEE', 'value', jsonb_build_object(
                       'conditions', jsonb_build_object(
                           'firstLoan', coalesce((r -> 'value' ->> 'firstLoan')::boolean, true),
                           'thresholdAmount', 100000,
                           'defaulter', jsonb_build_object('enabled', true, 'lookbackMonths', 24)),
                       'allowOverride', coalesce((r -> 'value' ->> 'allowOverride')::boolean, true)))
               ELSE r END ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'rules') WITH ORDINALITY x(r, ord)))
$$;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 3, 'PUBLISHED',
       jsonb_set(platform.nominee_rule_conditions(v.definition), '{version}', '3'),
       v.json_schema_id, 'NOMINEE rule: first loan, amount threshold or past default', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id
       AND v.version_no = (SELECT max(v2.version_no) FROM platform.config_template_version v2
                            WHERE v2.template_id = t.id AND v2.version_no < 3)
 WHERE t.template_kind = 'RULESET' AND t.code LIKE 'LOAN_TYPE_%'
ON CONFLICT (template_id, version_no) DO NOTHING;

DO $$
DECLARE
    t      record;
    rs     record;
    v_next integer;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        FOR rs IN
            SELECT s.id, v.definition, v.json_schema_id
              FROM cfg.rule_set s
              JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(s.id, app.tenant_today(t.id))
             WHERE s.tenant_id = t.id AND s.scope_type = 'LOAN_TYPE'
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(v.definition -> 'rules') r
                            WHERE r ->> 'code' = 'NOMINEE' AND NOT (r -> 'value') ? 'conditions')
        LOOP
            -- One published version per effective date: a version published
            -- today (the everyLoan one from 49a) is retired and replaced.
            UPDATE cfg.rule_set_version SET status = 'RETIRED'
             WHERE rule_set_id = rs.id AND status = 'PUBLISHED' AND effective_from = app.tenant_today(t.id);
            SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.rule_set_version WHERE rule_set_id = rs.id;
            INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                              effective_from, reason, source)
            VALUES (t.id, rs.id, v_next, 'PUBLISHED',
                    jsonb_set(platform.nominee_rule_conditions(rs.definition), '{version}', to_jsonb(v_next)),
                    rs.json_schema_id, app.tenant_today(t.id),
                    'NOMINEE rule: first loan, amount threshold or past default', 'TEMPLATE');
        END LOOP;
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;
