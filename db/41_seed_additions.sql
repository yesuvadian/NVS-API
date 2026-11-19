-- =============================================================================
-- CFMS 41 - Seed data for the gap review additions (idempotent)
--   * extra organisation settings (template v1) and backfill for existing orgs
--   * dashboard widget library, data sources and default dashboards D1-D6
--   * background job catalogue
-- =============================================================================
SET app.channel TO 'MIGRATION';

-- -----------------------------------------------------------------------------
-- Settings (Section 4.10, 35.6, 36)
-- -----------------------------------------------------------------------------
WITH s(setting_key, area, name, data_type, editable_by, value, scope_ref, is_proposed, sort_order) AS (VALUES
 ('general.enabled_languages','General','Languages enabled for the organisation','list','ORG_ADMIN','["en"]'::jsonb,'36',false,15),
 ('branding.whatsapp_number','Branding','WhatsApp business number','string','ORG_ADMIN','""','35.6',false,24),
 ('branding.email_sender','Branding','Email sender address','string','ORG_ADMIN','""','35.6',false,25),
 ('branding.document_headers','Branding','Headers and footers for statements, payslips and reports','json','ORG_ADMIN',
  '{"statement":{"header":"","footer":""},"payslip":{"header":"","footer":""},"report":{"header":"","footer":""}}','35.6',false,26),
 ('payroll.frequency','Payroll','Payroll frequency','string','ORG_ADMIN','"MONTHLY"','4.3',true,150),
 ('ui.auto_refresh_minutes','User interface','Dashboard and queue auto-refresh (minutes, 0 = off)','integer','ORG_ADMIN','5','36',false,160),
 ('ui.page_size','User interface','Rows per page','integer','ORG_ADMIN','15','36',false,161)
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

-- Existing organisations receive any setting they do not have yet (template value).
SET app.scope TO 'platform';
INSERT INTO cfg.tenant_setting (tenant_id, setting_key, value, effective_from, status, source, template_version, reason)
SELECT t.id, i.setting_key, i.value, DATE '2000-01-01', 'ACTIVE', 'TEMPLATE', 1,
       'Default added from settings template v1 (gap review)'
  FROM platform.tenant t
  JOIN platform.settings_template_item i ON i.version_no = 1
 WHERE NOT EXISTS (SELECT 1 FROM cfg.tenant_setting x WHERE x.tenant_id = t.id AND x.setting_key = i.setting_key);
RESET app.scope;

-- -----------------------------------------------------------------------------
-- Dashboard widget library and data sources (Section 3.8)
-- -----------------------------------------------------------------------------
INSERT INTO platform.widget_type (widget_code, name, category, description) VALUES
 ('COUNT','Count tile','COUNT','A single number with a label and link'),
 ('KPI','KPI tile','KPI','A value compared with a target or previous period'),
 ('LIST','List','LIST','Top rows of a list with a link to the full list'),
 ('BAR_CHART','Bar chart','CHART','Values by category or period'),
 ('LINE_CHART','Line chart','CHART','Trend over time'),
 ('PENDING_TASKS','Pending tasks','PENDING_TASKS','The user''s pending approvals and tasks')
ON CONFLICT (widget_code) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description;

INSERT INTO platform.dashboard_data_source (source_code, name, module_code) VALUES
 ('MY_PENDING_TASKS','My pending approvals and tasks','APPROVAL'),
 ('APPROVALS_AWAITING','Approvals awaiting decision','APPROVAL'),
 ('OFFLINE_TO_RECORD','Offline decisions awaiting recording','APPROVAL'),
 ('RECENT_DECISIONS','Recent approval decisions','APPROVAL'),
 ('DUE_TODAY','Repayments due today','LOAN_REPAY'),
 ('UPCOMING_DUES','Upcoming due dates','LOAN_REPAY'),
 ('RETURNED_APPLICATIONS','Returned applications','LOAN'),
 ('APPLICATIONS_AWAITING','Loan applications awaiting verification','LOAN'),
 ('LOAN_PORTFOLIO','Loan portfolio and outstanding principal','LOAN'),
 ('OVERDUE_DEFAULTED','Overdue and defaulted loans','LOAN_DEFAULT'),
 ('RECOVERY_CASES','Recovery cases and escalations','LOAN_DEFAULT'),
 ('SETTLEMENT_REQUESTS','Early settlement requests','LOAN_SETTLE'),
 ('HALL_BOOKINGS','Upcoming hall bookings','HALL'),
 ('EXPENSES_AWAITING','Expenses awaiting approval','EXPENSE'),
 ('ASSET_REQUESTS','Asset purchase requests','ASSET_PURCHASE'),
 ('CASH_POSITION','Cash position and day-end status','CASH_RECON'),
 ('UNPOSTED_VOUCHERS','Unposted and draft vouchers','JOURNAL'),
 ('MANUAL_JOURNALS_AWAITING','Manual journals awaiting approval','JOURNAL'),
 ('PERIOD_STATUS','Current accounting period and closing checklist','FIN_PERIOD'),
 ('TRIAL_BALANCE_SUMMARY','Trial balance summary','TRIAL_BAL'),
 ('PAYROLL_RUNS','Payroll runs awaiting preparation or posting','PAYROLL'),
 ('FAILED_POSTINGS','Failed or pending automatic postings','GL'),
 ('GENERAL_FUND_BALANCE','General Fund balance','GEN_FUND'),
 ('INCOME_EXPENDITURE','Income and expenditure','FIN_STMT'),
 ('AUDIT_EXCEPTIONS','Audit exceptions and backdated entries','AUDIT'),
 ('USERS_PENDING','Users awaiting activation or deactivation','USER_ROLE'),
 ('ACCESS_CHANGES','Recent role and permission changes','USER_ROLE'),
 ('FAILED_ACTIONS','Failed action executions','WORKFLOW'),
 ('FAILED_NOTIFICATIONS','Failed notifications','NOTIFICATION'),
 ('SECURITY_ALERTS','Login and security alerts','USER_ROLE'),
 ('JOB_HEALTH','Background job status','ORG')
ON CONFLICT (source_code) DO UPDATE SET name = EXCLUDED.name, module_code = EXCLUDED.module_code;

-- Default dashboards (Section 32). Each widget is shown only when the user can view
-- the module of its data source.
INSERT INTO platform.dashboard_template (module_code, version_no, definition)
SELECT x.module_code, 1, jsonb_build_object('widgets', x.widgets)
  FROM (VALUES
  ('DASH_EMPLOYEE', '[{"widget":"PENDING_TASKS","source":"MY_PENDING_TASKS","title":"My pending tasks"},
                      {"widget":"LIST","source":"DUE_TODAY","title":"Due today"},
                      {"widget":"LIST","source":"RETURNED_APPLICATIONS","title":"Returned applications"},
                      {"widget":"LIST","source":"UPCOMING_DUES","title":"Upcoming due dates"},
                      {"widget":"LIST","source":"HALL_BOOKINGS","title":"Hall bookings"}]'::jsonb),
  ('DASH_MANAGER',  '[{"widget":"PENDING_TASKS","source":"MY_PENDING_TASKS","title":"My pending tasks"},
                      {"widget":"COUNT","source":"APPROVALS_AWAITING","title":"Awaiting my approval"},
                      {"widget":"COUNT","source":"OFFLINE_TO_RECORD","title":"Offline decisions to record"},
                      {"widget":"LIST","source":"APPLICATIONS_AWAITING","title":"Applications awaiting verification"},
                      {"widget":"LIST","source":"EXPENSES_AWAITING","title":"Expenses awaiting approval"},
                      {"widget":"LIST","source":"OVERDUE_DEFAULTED","title":"Overdue and defaulted loans"},
                      {"widget":"LIST","source":"RECOVERY_CASES","title":"Recovery cases"},
                      {"widget":"LIST","source":"SETTLEMENT_REQUESTS","title":"Early settlement requests"},
                      {"widget":"LIST","source":"RECENT_DECISIONS","title":"Previous decisions"}]'),
  ('DASH_ACCOUNTANT','[{"widget":"PENDING_TASKS","source":"MY_PENDING_TASKS","title":"My pending tasks"},
                      {"widget":"KPI","source":"CASH_POSITION","title":"Cash position"},
                      {"widget":"COUNT","source":"UNPOSTED_VOUCHERS","title":"Unposted vouchers"},
                      {"widget":"COUNT","source":"MANUAL_JOURNALS_AWAITING","title":"Manual journals awaiting approval"},
                      {"widget":"LIST","source":"PERIOD_STATUS","title":"Period status"},
                      {"widget":"LIST","source":"PAYROLL_RUNS","title":"Payroll runs"},
                      {"widget":"BAR_CHART","source":"TRIAL_BALANCE_SUMMARY","title":"Trial balance"},
                      {"widget":"LIST","source":"FAILED_POSTINGS","title":"Failed postings"}]'),
  ('DASH_LEADERSHIP','[{"widget":"PENDING_TASKS","source":"MY_PENDING_TASKS","title":"Pending approvals"},
                      {"widget":"KPI","source":"GENERAL_FUND_BALANCE","title":"General Fund"},
                      {"widget":"BAR_CHART","source":"INCOME_EXPENDITURE","title":"Income and expenditure"},
                      {"widget":"KPI","source":"LOAN_PORTFOLIO","title":"Loan portfolio"},
                      {"widget":"LIST","source":"OVERDUE_DEFAULTED","title":"Defaults"}]'),
  ('DASH_AUDITOR',  '[{"widget":"LIST","source":"AUDIT_EXCEPTIONS","title":"Audit exceptions"},
                      {"widget":"BAR_CHART","source":"INCOME_EXPENDITURE","title":"Income and expenditure"},
                      {"widget":"BAR_CHART","source":"TRIAL_BALANCE_SUMMARY","title":"Trial balance"},
                      {"widget":"LIST","source":"RECENT_DECISIONS","title":"Approval records"}]'),
  ('DASH_ADMIN',    '[{"widget":"PENDING_TASKS","source":"MY_PENDING_TASKS","title":"My pending tasks"},
                      {"widget":"LIST","source":"USERS_PENDING","title":"Users awaiting activation"},
                      {"widget":"LIST","source":"ACCESS_CHANGES","title":"Role and permission changes"},
                      {"widget":"LIST","source":"FAILED_ACTIONS","title":"Failed actions"},
                      {"widget":"LIST","source":"FAILED_NOTIFICATIONS","title":"Failed notifications"},
                      {"widget":"LIST","source":"SECURITY_ALERTS","title":"Security alerts"},
                      {"widget":"LIST","source":"JOB_HEALTH","title":"Background jobs"}]')
  ) AS x(module_code, widgets)
ON CONFLICT (module_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Background job catalogue (Section 35.12)
-- -----------------------------------------------------------------------------
INSERT INTO platform.job_definition (job_code, name, module_code, default_schedule, description) VALUES
 ('LOAN_STATUS_DAILY','Overdue and default status update','LOAN','15 0 * * *','Marks loans overdue or defaulted on the working date'),
 ('LOAN_REMINDERS','Loan repayment reminders','LOAN_REPAY','0 9 * * *','Queues reminders per the reminder schedule (respects quiet hours)'),
 ('RECOVERY_ESCALATION','Recovery case escalation','LOAN_DEFAULT','30 0 * * *','Escalates unpaid defaulters to Manager, then Leadership'),
 ('APPROVAL_EXPIRY','Loan approval expiry','LOAN','45 0 * * *','Expires approvals not disbursed within the window'),
 ('COOLING_OFF_END','Cooling-off completion','MEMBER','50 0 * * *','Restores eligibility when cooling-off ends'),
 ('HALL_TENTATIVE_EXPIRY','Tentative booking expiry','HALL','0 1 * * *','Releases tentative hall bookings past their hold'),
 ('DEPOSIT_INTEREST','Deposit interest calculation','DEPOSIT','0 2 1 * *','Calculates monthly deposit interest (memo)'),
 ('DEPOSIT_MATURITY','Deposit maturity and reminders','DEPOSIT','15 2 * * *','Marks matured deposits and sends reminders'),
 ('CHIT_DUES','Chit instalment dues and late fees','CHIT','30 2 * * *','Applies late fees and defaults for chit instalments'),
 ('CONTRIBUTION_DUES','Contribution dues generation','CONTRIB','0 3 1 * *','Generates member contribution dues'),
 ('DEPRECIATION','Asset depreciation run','ASSET_MAINT','0 4 1 * *','Calculates depreciation for the period'),
 ('ASSET_REMINDERS','Maintenance and warranty reminders','ASSET','0 8 * * *','Queues maintenance and warranty expiry reminders'),
 ('BIRTHDAY_GRANTS','Birthday grant scheduling','BDAY_GRANT','0 5 * * *','Schedules upcoming birthday grants'),
 ('PETTY_CASH_FLAG','Old petty cash advances','EXPENSE','0 6 * * *','Flags advances older than the configured days'),
 ('NOTIFICATION_DISPATCH','Notification dispatch and retries','NOTIFICATION','*/1 * * * *','Sends queued notifications and retries failures'),
 ('EXPORT_GENERATION','Background exports','ORG','*/1 * * * *','Generates large Excel and PDF exports'),
 ('PURGE_CANDIDATES','Purge candidate report','AUDIT','0 3 15 4 *','Lists records past retention (only when purge is enabled)')
ON CONFLICT (job_code) DO UPDATE SET name = EXCLUDED.name, module_code = EXCLUDED.module_code,
    default_schedule = EXCLUDED.default_schedule, description = EXCLUDED.description;

-- Existing organisations receive the default dashboards.
SET app.scope TO 'platform';
DO $$ BEGIN PERFORM platform.apply_dashboard_templates(t.id) FROM platform.tenant t; END $$;
RESET app.scope;

RESET app.channel;
