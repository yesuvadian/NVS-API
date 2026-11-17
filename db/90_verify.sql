-- =============================================================================
-- CFMS / NVS  -  90  Verification queries (read-only)
-- -----------------------------------------------------------------------------
-- Run as nvs at any time. Every result in section 1 should be empty.
-- =============================================================================

-- 1a. Tenant-owned tables WITHOUT forced row-level security (expect no rows)
SELECT n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND a.attnotnull AND NOT a.attisdropped
 WHERE c.relkind = 'r'
   AND n.nspname IN ('platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
   AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
 ORDER BY 1, 2;

-- 1b. Tenant-owned tables without an audit trigger (expect only the intentional exclusions:
--     append-only logs and high-volume technical tables)
SELECT n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND a.attnotnull AND NOT a.attisdropped
 WHERE c.relkind = 'r'
   AND n.nspname IN ('platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
   AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname = 'zz_audit')
 ORDER BY 1, 2;

-- 1c. Foreign keys from tenant tables that do NOT include tenant_id (expect only
--     references to platform tables, plus audit_field_change -> audit_event by design)
SELECT con.conrelid::regclass AS from_table, con.confrelid::regclass AS to_table, con.conname
  FROM pg_constraint con
  JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = con.conrelid)
 WHERE con.contype = 'f'
   AND n.nspname IN ('core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
   AND (SELECT relnamespace FROM pg_class WHERE oid = con.confrelid) <> 'platform'::regnamespace
   AND NOT EXISTS (SELECT 1 FROM unnest(con.conkey) k
                    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k
                   WHERE a.attname = 'tenant_id')
 ORDER BY 1;

-- 1d. Foreign keys without a supporting index (expect no rows)
SELECT con.conrelid::regclass AS table_name, con.conname
  FROM pg_constraint con
  JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = con.conrelid)
 WHERE con.contype = 'f'
   AND n.nspname IN ('platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
   AND NOT EXISTS (SELECT 1 FROM pg_index i
                    WHERE i.indrelid = con.conrelid
                      AND (i.indkey::int2[])[0:array_length(con.conkey,1)-1] @> con.conkey
                      AND (i.indkey::int2[])[0:array_length(con.conkey,1)-1] <@ con.conkey)
 ORDER BY 1, 2;

-- 2. Object counts per schema
SELECT n.nspname AS schema_name,
       count(*) FILTER (WHERE c.relkind = 'r') AS tables,
       count(*) FILTER (WHERE c.relkind = 'v') AS views
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('app','platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
 GROUP BY 1 ORDER BY 1;

-- 3. Platform seed summary
SELECT 'modules' AS item, count(*) FROM platform.module
UNION ALL SELECT 'privileges', count(*) FROM platform.privilege
UNION ALL SELECT 'role templates', count(*) FROM platform.role_template
UNION ALL SELECT 'role template privileges', count(*) FROM platform.role_template_privilege
UNION ALL SELECT 'setting definitions', count(*) FROM platform.setting_definition
UNION ALL SELECT 'settings template items (published)', count(*) FROM platform.settings_template_item i
          JOIN platform.settings_template t ON t.version_no = i.version_no AND t.status = 'PUBLISHED'
UNION ALL SELECT 'chart of accounts template', count(*) FROM platform.coa_template
UNION ALL SELECT 'actions (approved)', count(*) FROM platform.action_definition WHERE status = 'APPROVED'
UNION ALL SELECT 'workflow templates', count(*) FROM platform.config_template WHERE template_kind = 'WORKFLOW'
UNION ALL SELECT 'rule set templates', count(*) FROM platform.config_template WHERE template_kind = 'RULESET'
UNION ALL SELECT 'dashboard widget types', count(*) FROM platform.widget_type
UNION ALL SELECT 'dashboard data sources', count(*) FROM platform.dashboard_data_source
UNION ALL SELECT 'dashboard templates', count(*) FROM platform.dashboard_template
UNION ALL SELECT 'background job definitions', count(*) FROM platform.job_definition
UNION ALL SELECT 'account mapping template', count(*) FROM platform.account_mapping_template
UNION ALL SELECT 'approval policy template', count(*) FROM platform.approval_policy_template
UNION ALL SELECT 'number series template', count(*) FROM platform.number_series_template
UNION ALL SELECT 'segregation of duties rules', count(*) FROM platform.sod_rule
UNION ALL SELECT 'lookup / scheme templates', count(*) FROM platform.lookup_template
UNION ALL SELECT 'notification templates', count(*) FROM platform.notification_template_default
UNION ALL SELECT 'import templates', count(*) FROM platform.import_template
UNION ALL SELECT 'error codes', count(*) FROM platform.error_code
UNION ALL SELECT 'constraint / sqlstate error maps', (SELECT count(*) FROM platform.constraint_error_map) + (SELECT count(*) FROM platform.sqlstate_error_map)
UNION ALL SELECT 'tenants', count(*) FROM platform.tenant;

-- 4. Default privilege matrix as provided to new organisations (compare with Section 3.3)
SELECT p.module_code,
       string_agg(DISTINCT CASE WHEN rtp.role_code = 'EMP' THEN p.type_code END, '') AS emp,
       string_agg(DISTINCT CASE WHEN rtp.role_code = 'MGR' THEN p.type_code END, '') AS mgr,
       string_agg(DISTINCT CASE WHEN rtp.role_code = 'ACC' THEN p.type_code END, '') AS acc,
       string_agg(DISTINCT CASE WHEN rtp.role_code = 'LDR' THEN p.type_code END, '') AS ldr,
       string_agg(DISTINCT CASE WHEN rtp.role_code = 'AUD' THEN p.type_code END, '') AS aud,
       string_agg(DISTINCT CASE WHEN rtp.role_code = 'ADM' THEN p.type_code END, '') AS adm
  FROM platform.role_template_privilege rtp
  JOIN platform.privilege p ON p.privilege_code = rtp.privilege_code
  JOIN platform.module m ON m.module_code = p.module_code
 GROUP BY p.module_code, m.menu_order, m.parent_module_code
 ORDER BY m.parent_module_code, m.menu_order;

\echo '1e. Error short codes raised by database functions but missing from the error catalogue (expect none)'
SELECT DISTINCT m[1] AS short_code
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
       regexp_matches(p.prosrc, 'app\.fail\(''([A-Z][A-Z0-9_]*)''', 'g') AS m
 WHERE n.nspname IN ('app','platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
   AND NOT EXISTS (SELECT 1 FROM platform.error_code e WHERE e.short_code = m[1])
 ORDER BY 1;
\echo '1f. Mapped constraints that do not exist (expect none)'
SELECT m.constraint_name FROM platform.constraint_error_map m
 WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = m.constraint_name)
   AND NOT EXISTS (SELECT 1 FROM pg_class i WHERE i.relkind = 'i' AND i.relname = m.constraint_name);
