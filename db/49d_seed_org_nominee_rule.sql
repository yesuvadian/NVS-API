-- =============================================================================
-- CFMS / NVS  -  49d  NOMINEE rule at organisation level (MEMBER_RULES)
-- -----------------------------------------------------------------------------
-- Run as nvs after 49c. Safe to re-run.
--
-- Owner decisions:
--   * "Nominee will come into picture based on rule; there is no concept of a
--     nominee loan type": the NOMINEE rule (conditions firstLoan /
--     thresholdAmount / defaulter, allowOverride) moves out of every loan
--     type's rule set into the organisation's GENERAL rule set MEMBER_RULES,
--     next to NOMINATIONS. loan.get_active_loan_types hands every loan type
--     that one rule, and new loans snapshot it; existing loans keep their
--     snapshot.
--   * A rule without allowOverride means overrides are not allowed, so the
--     rules that allow them today say so explicitly (NOMINATIONS gains
--     "allowOverride": true where it was implied).
--   * The setting loans.nominee_mandatory_first_loan is no longer read: the
--     rule's firstLoan condition alone decides.
-- Template versions for new organisations (MEMBER_RULES v2, LOAN_TYPE_* v4)
-- and new published versions for existing organisations, effective today.
-- =============================================================================
SET app.channel TO 'MIGRATION';
SET app.reason TO 'NOMINEE rule at organisation level (MEMBER_RULES)';

-- Rules of a definition without the NOMINEE rule.
CREATE OR REPLACE FUNCTION platform.rules_without_nominee(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{rules}', coalesce((
        SELECT jsonb_agg(r ORDER BY ord) FROM jsonb_array_elements(p_definition -> 'rules') WITH ORDINALITY x(r, ord)
         WHERE r ->> 'code' <> 'NOMINEE'), '[]'::jsonb))
$$;

-- MEMBER_RULES with the NOMINEE rule and an explicit NOMINATIONS.allowOverride.
CREATE OR REPLACE FUNCTION platform.member_rules_with_nominee(p_definition jsonb, p_nominee jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{rules}', coalesce((
        SELECT jsonb_agg(CASE WHEN r ->> 'code' = 'NOMINATIONS' AND NOT (r -> 'value') ? 'allowOverride'
                              THEN jsonb_set(r, '{value}', (r -> 'value') || '{"allowOverride": true}')
                              ELSE r END ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'rules') WITH ORDINALITY x(r, ord)
         WHERE r ->> 'code' <> 'NOMINEE'), '[]'::jsonb) || jsonb_build_array(p_nominee))
$$;

-- Templates -------------------------------------------------------------------
INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT mt.id, 2, 'PUBLISHED',
       jsonb_set(platform.member_rules_with_nominee(mv.definition, (
           SELECT r FROM platform.config_template lt
             JOIN platform.config_template_version lv ON lv.template_id = lt.id
             CROSS JOIN LATERAL jsonb_array_elements(lv.definition -> 'rules') r
            WHERE lt.template_kind = 'RULESET' AND lt.code = 'LOAN_TYPE_INTEREST_BEARING' AND r ->> 'code' = 'NOMINEE'
            ORDER BY lv.version_no DESC LIMIT 1)), '{version}', '2'),
       mv.json_schema_id, 'NOMINEE rule at organisation level; NOMINATIONS.allowOverride explicit', now()
  FROM platform.config_template mt
  JOIN platform.config_template_version mv ON mv.template_id = mt.id AND mv.version_no = 1
 WHERE mt.template_kind = 'RULESET' AND mt.code = 'MEMBER_RULES'
ON CONFLICT (template_id, version_no) DO NOTHING;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 4, 'PUBLISHED',
       jsonb_set(platform.rules_without_nominee(v.definition), '{version}', '4'),
       v.json_schema_id, 'NOMINEE rule moved to MEMBER_RULES (organisation level)', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id = t.id AND v.version_no = 3
 WHERE t.template_kind = 'RULESET' AND t.code LIKE 'LOAN_TYPE_%'
ON CONFLICT (template_id, version_no) DO NOTHING;

-- Existing organisations --------------------------------------------------------
DO $$
DECLARE
    t       record;
    rs      record;
    m       record;
    v_rule  jsonb;
    v_next  integer;
    v_today date;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        v_today := app.tenant_today(t.id);

        SELECT s.id, v.definition, v.json_schema_id INTO m
          FROM cfg.rule_set s
          JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(s.id, v_today)
         WHERE s.tenant_id = t.id AND s.code = 'MEMBER_RULES';
        IF m.id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(m.definition -> 'rules') r
                                             WHERE r ->> 'code' = 'NOMINEE') THEN
            -- today's NOMINEE rule of the organisation (its loan types share it)
            SELECT r INTO v_rule
              FROM loan.loan_type lt
              JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(lt.rule_set_id, v_today)
              CROSS JOIN LATERAL jsonb_array_elements(v.definition -> 'rules') r
             WHERE lt.tenant_id = t.id AND r ->> 'code' = 'NOMINEE'
             ORDER BY (lt.code = 'INTEREST_BEARING') DESC, lt.sort_order LIMIT 1;
            IF v_rule IS NULL THEN
                SELECT r INTO v_rule
                  FROM platform.config_template ct
                  JOIN platform.config_template_version tv ON tv.template_id = ct.id
                  CROSS JOIN LATERAL jsonb_array_elements(tv.definition -> 'rules') r
                 WHERE ct.template_kind = 'RULESET' AND ct.code = 'MEMBER_RULES' AND r ->> 'code' = 'NOMINEE'
                 ORDER BY tv.version_no DESC LIMIT 1;
            END IF;
            UPDATE cfg.rule_set_version SET status = 'RETIRED'
             WHERE rule_set_id = m.id AND status = 'PUBLISHED' AND effective_from = v_today;
            SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.rule_set_version WHERE rule_set_id = m.id;
            INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                              effective_from, reason, source)
            VALUES (t.id, m.id, v_next, 'PUBLISHED',
                    jsonb_set(platform.member_rules_with_nominee(m.definition, v_rule), '{version}', to_jsonb(v_next)),
                    m.json_schema_id, v_today, 'NOMINEE rule at organisation level', 'TEMPLATE');
        END IF;

        FOR rs IN
            SELECT s.id, v.definition, v.json_schema_id
              FROM cfg.rule_set s
              JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(s.id, v_today)
             WHERE s.tenant_id = t.id AND s.scope_type = 'LOAN_TYPE'
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(v.definition -> 'rules') r WHERE r ->> 'code' = 'NOMINEE')
        LOOP
            UPDATE cfg.rule_set_version SET status = 'RETIRED'
             WHERE rule_set_id = rs.id AND status = 'PUBLISHED' AND effective_from = v_today;
            SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.rule_set_version WHERE rule_set_id = rs.id;
            INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                              effective_from, reason, source)
            VALUES (t.id, rs.id, v_next, 'PUBLISHED',
                    jsonb_set(platform.rules_without_nominee(rs.definition), '{version}', to_jsonb(v_next)),
                    rs.json_schema_id, v_today, 'NOMINEE rule moved to MEMBER_RULES', 'TEMPLATE');
        END LOOP;
    END LOOP;
    PERFORM app.clear_context();
END
$$;

RESET app.reason;
RESET app.channel;
