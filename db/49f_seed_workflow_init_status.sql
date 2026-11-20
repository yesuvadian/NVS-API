-- Workflow init is the configured first stage; for loan applications its
-- initial *stage* status starts at DRAFT. The stage's entityStatus remains a
-- separate entity-domain value. Existing published versions are preserved.
SET app.channel TO 'MIGRATION';
SET app.reason TO 'Loan initialization stage status default';

CREATE OR REPLACE FUNCTION platform.loan_workflow_init_draft(p_definition jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT jsonb_set(p_definition, '{stages}', (
        SELECT jsonb_agg(CASE WHEN s ->> 'code' = p_definition ->> 'startStage'
            THEN jsonb_set(jsonb_set(s, '{statuses,initial}', '"DRAFT"'::jsonb),
                 '{statuses,stageStatuses}', (
                    SELECT coalesce(jsonb_agg(CASE WHEN x ->> 'code' = 'PENDING'
                        THEN jsonb_set(x, '{code}', '"DRAFT"'::jsonb) ELSE x END ORDER BY ord), '[]'::jsonb)
                      FROM jsonb_array_elements(s -> 'statuses' -> 'stageStatuses') WITH ORDINALITY a(x,ord)
                 ), true)
            ELSE s END ORDER BY ord)
          FROM jsonb_array_elements(p_definition -> 'stages') WITH ORDINALITY a(s,ord)
    ), true)
$$;

INSERT INTO platform.config_template_version
    (template_id,version_no,status,definition,json_schema_id,reason,published_at)
SELECT t.id, 5, 'PUBLISHED',
       jsonb_set(platform.loan_workflow_init_draft(v.definition), '{version}', '5'::jsonb),
       v.json_schema_id, 'Initialization stage starts with configured DRAFT status', now()
  FROM platform.config_template t
  JOIN platform.config_template_version v ON v.template_id=t.id AND v.version_no=4
 WHERE t.template_kind='WORKFLOW' AND t.code='LOAN_APPLICATION'
ON CONFLICT (template_id,version_no) DO NOTHING;

RESET app.reason;
RESET app.channel;
