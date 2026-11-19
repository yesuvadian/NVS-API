-- =============================================================================
-- CFMS / NVS  -  40  Platform seed data
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run (upserts for the module registry; templates are
-- inserted once and then only changed through new versions).
--   * Module registry (38 modules, dashboards D1-D6, menu groups, hidden
--     sub-functions, platform modules)
--   * Privilege types and the named privilege catalogue (e.g. loan.approve)
--   * Standard role templates and the default privilege matrix (Section 3.3)
--   * Segregation-of-duties rules
--   * Setting definitions and default settings template v1 (Sections 4.9, 4.10)
--   * Legal / tax features, payment modes, data categories
--   * Standard chart of accounts template (Section 21.1)
--   * Lookup templates, notification templates
--   * Action catalogue, JSON Schemas, rule set and workflow templates
-- =============================================================================

SET app.channel TO 'MIGRATION';
SET app.reason TO 'Platform seed script 40';

-- ----------------------------------------------------------------------------
-- Module registry (maintained by SQL only)
-- ----------------------------------------------------------------------------
INSERT INTO platform.module (module_code, module_name, module_type, parent_module_code, is_menu, menu_order,
                             icon, route, is_core, is_optional_legal, scope_ref, priority)
VALUES
 -- menu groups
 ('GRP_DASHBOARDS','Dashboards','GROUP',NULL,true,10,'dashboard',NULL,true,false,'3.8',NULL),
 ('GRP_MEMBERS','Members','GROUP',NULL,true,20,'people',NULL,true,false,'5',NULL),
 ('GRP_LOANS','Loans','GROUP',NULL,true,30,'account_balance',NULL,true,false,'6',NULL),
 ('GRP_DEPOSITS','Deposits','GROUP',NULL,true,40,'savings',NULL,true,false,'9',NULL),
 ('GRP_CHIT','Chit Funds','GROUP',NULL,true,50,'groups',NULL,true,false,'10',NULL),
 ('GRP_ASSISTANCE','Assistance','GROUP',NULL,true,60,'volunteer_activism',NULL,true,false,'13',NULL),
 ('GRP_OPERATIONS','Operations','GROUP',NULL,true,70,'work',NULL,true,false,'16',NULL),
 ('GRP_ASSETS','Assets','GROUP',NULL,true,80,'inventory',NULL,true,false,'19',NULL),
 ('GRP_ACCOUNTING','Accounting','GROUP',NULL,true,90,'calculate',NULL,true,false,'21',NULL),
 ('GRP_REPORTS','Reports','GROUP',NULL,true,100,'assessment',NULL,true,false,'23',NULL),
 ('GRP_APPROVALS','Approvals','GROUP',NULL,true,110,'task_alt',NULL,true,false,'28',NULL),
 ('GRP_ADMIN','Administration','GROUP',NULL,true,120,'settings',NULL,true,false,'3',NULL),
 ('GRP_PLATFORM','Platform','PLATFORM',NULL,true,900,'cloud',NULL,false,false,'35',NULL),
 -- dashboards (D1-D6)
 ('DASH_EMPLOYEE','Employee Dashboard','DASHBOARD','GRP_DASHBOARDS',true,10,'dashboard','/dashboard/employee',true,false,'32','D1'),
 ('DASH_MANAGER','Manager Dashboard','DASHBOARD','GRP_DASHBOARDS',true,20,'dashboard','/dashboard/manager',true,false,'32','D2'),
 ('DASH_ACCOUNTANT','Accountant Dashboard','DASHBOARD','GRP_DASHBOARDS',true,30,'dashboard','/dashboard/accountant',true,false,'32','D3'),
 ('DASH_LEADERSHIP','Leadership Dashboard','DASHBOARD','GRP_DASHBOARDS',true,40,'dashboard','/dashboard/leadership',true,false,'32','D4'),
 ('DASH_AUDITOR','Auditor Dashboard','DASHBOARD','GRP_DASHBOARDS',true,50,'dashboard','/dashboard/auditor',true,false,'32','D5'),
 ('DASH_ADMIN','Administration Dashboard','DASHBOARD','GRP_DASHBOARDS',true,60,'dashboard','/dashboard/admin',true,false,'32','D6'),
 -- the 38 organisation modules (Section 37)
 ('ORG','Organisation Management','CONFIGURATION','GRP_ADMIN',true,10,'business','/admin/organisation',true,false,'4','Critical'),
 ('USER_ROLE','User & Role Management','CONFIGURATION','GRP_ADMIN',true,20,'manage_accounts','/admin/users',true,false,'3.6','Critical'),
 ('MEMBER','Member Management','MODULE','GRP_MEMBERS',true,10,'person','/members',true,false,'5','Critical'),
 ('LOAN','Loan Management','MODULE','GRP_LOANS',true,10,'request_quote','/loans',false,false,'6','Critical'),
 ('LOAN_FEE','Loan Application Fee Management','MODULE','GRP_LOANS',true,20,'receipt','/loans/fees',false,false,'6.2','Critical'),
 ('LOAN_REPAY','Loan Repayment Management','MODULE','GRP_LOANS',true,30,'payments','/loans/repayments',false,false,'7','Critical'),
 ('LOAN_SETTLE','Early Full Settlement','MODULE','GRP_LOANS',true,40,'task','/loans/settlements',false,false,'7.3','Critical'),
 ('LOAN_DEFAULT','Default & Full Settlement Management','MODULE','GRP_LOANS',true,50,'warning','/loans/defaults',false,false,'8','Critical'),
 ('NOMINEE','Nominee Management','MODULE','GRP_MEMBERS',true,20,'family_restroom','/members/nominees',false,false,'11','High'),
 ('DECEASED','Deceased Member Management','MODULE','GRP_MEMBERS',true,30,'sentiment_dissatisfied','/members/deceased',false,false,'12','High'),
 ('ASSIST_EDU','Education Assistance','MODULE','GRP_ASSISTANCE',true,10,'school','/assistance/education',false,false,'13','High'),
 ('ASSIST_CREM','Cremation Assistance','MODULE','GRP_ASSISTANCE',true,20,'local_florist','/assistance/cremation',false,false,'14','High'),
 ('BDAY_GRANT','Birthday Grants','MODULE','GRP_ASSISTANCE',true,30,'cake','/assistance/birthday-grants',false,false,'15','Medium'),
 ('EXPENSE','Daily Expense Management','MODULE','GRP_OPERATIONS',true,10,'shopping_cart','/expenses',false,false,'16','Critical'),
 ('PAYROLL','Employee Payroll','MODULE','GRP_OPERATIONS',true,20,'badge','/payroll',false,false,'17','High'),
 ('HALL','Marriage Hall Management','MODULE','GRP_OPERATIONS',true,30,'celebration','/halls',false,false,'18','High'),
 ('ASSET','Community Asset Management','MODULE','GRP_ASSETS',true,10,'inventory_2','/assets',false,false,'19','High'),
 ('ASSET_PURCHASE','Asset Purchase & Approval','MODULE','GRP_ASSETS',true,20,'add_shopping_cart','/assets/purchases',false,false,'19.2','High'),
 ('ASSET_MAINT','Asset Maintenance & Depreciation','MODULE','GRP_ASSETS',true,30,'build','/assets/maintenance',false,false,'19.6','Medium'),
 ('ASSET_DISPOSAL','Asset Transfer & Disposal','MODULE','GRP_ASSETS',true,40,'swap_horiz','/assets/transfers',false,false,'19.8','Medium'),
 ('GEN_FUND','General Community Fund','MODULE','GRP_ACCOUNTING',true,10,'account_balance_wallet','/accounting/funds',true,false,'20','Critical'),
 ('GL','General Ledger','MODULE','GRP_ACCOUNTING',true,20,'menu_book','/accounting/ledger',true,false,'21','Critical'),
 ('COA','Chart of Accounts','MODULE','GRP_ACCOUNTING',true,30,'account_tree','/accounting/accounts',true,false,'21.1','Critical'),
 ('JOURNAL','Journal & Voucher Management','MODULE','GRP_ACCOUNTING',true,40,'edit_note','/accounting/journals',true,false,'21.3','Critical'),
 ('TRIAL_BAL','Trial Balance','REPORT','GRP_ACCOUNTING',true,50,'balance','/accounting/trial-balance',true,false,'23.1','Critical'),
 ('FIN_STMT','Financial Statements','REPORT','GRP_REPORTS',true,10,'summarize','/reports/statements',true,false,'23.2','Critical'),
 ('CASH_RECON','Cash Reconciliation','MODULE','GRP_ACCOUNTING',true,60,'point_of_sale','/accounting/cash',true,false,'21.6','Critical'),
 ('FIN_PERIOD','Financial Period Management','MODULE','GRP_ACCOUNTING',true,70,'event','/accounting/periods',true,false,'22','High'),
 ('FIN_REPORT','Financial Reports','REPORT','GRP_REPORTS',true,20,'description','/reports/financial',true,false,'23','Critical'),
 ('MGMT_REPORT','Management Reports & Analytics','REPORT','GRP_REPORTS',true,30,'insights','/reports/management',false,false,'23.5','High'),
 ('WORKFLOW','Workflow Engine','CONFIGURATION','GRP_ADMIN',true,30,'account_tree','/admin/workflows',true,false,'24','Critical'),
 ('RULES','Business Rules Engine','CONFIGURATION','GRP_ADMIN',true,40,'rule','/admin/rules',true,false,'29','Critical'),
 ('APPROVAL','Flexible Approval Management','MODULE','GRP_APPROVALS',true,10,'approval','/approvals',true,false,'28','Critical'),
 ('NOTIFICATION','Notification Engine','CONFIGURATION','GRP_ADMIN',true,50,'notifications','/admin/notifications',true,false,'30','High'),
 ('AUDIT','Audit Management','MODULE','GRP_ADMIN',true,60,'history','/admin/audit',true,false,'31','Critical'),
 ('DEPOSIT','Member Deposits','MODULE','GRP_DEPOSITS',true,10,'savings','/deposits',false,true,'9','High'),
 ('CHIT','Chit Fund Schemes','MODULE','GRP_CHIT',true,10,'groups','/chit-funds',false,true,'10','High'),
 ('CONTRIB','Contributions & Donations','MODULE','GRP_MEMBERS',true,40,'redeem','/contributions',false,false,'20.4','High'),
 -- hidden sub-functions (is_menu = false): inherit the parent's privileges
 ('LOAN_FEE_COLLECT','Application Fee Collection Step','MODULE','LOAN_FEE',false,10,NULL,'/loans/:id/fee',false,false,'6.2',NULL),
 ('LOAN_SETTLE_STATEMENT','Settlement Statement Generation','MODULE','LOAN_SETTLE',false,10,NULL,'/loans/:id/settlement-statement',false,false,'7.3',NULL),
 ('RECEIPT_PRINT','Receipt Printing','MODULE','GL',false,10,NULL,'/receipts/:id/print',false,false,'21.6',NULL),
 -- platform modules (platform roles only)
 ('P_TENANT','Tenant Management and Provisioning','PLATFORM','GRP_PLATFORM',true,10,'domain','/platform/tenants',false,false,'35.5','Critical'),
 ('P_TEMPLATES','Workflow and Rule Template Library and Governance','PLATFORM','GRP_PLATFORM',true,20,'library_books','/platform/templates',false,false,'35.4','Critical'),
 ('P_BILLING','Subscription Plans and Billing','PLATFORM','GRP_PLATFORM',true,30,'payments','/platform/billing',false,false,'35.7',NULL),
 ('P_ONBOARD','Tenant Onboarding and Migration Toolkit','PLATFORM','GRP_PLATFORM',true,40,'upload','/platform/onboarding',false,false,'35.11','High'),
 ('P_MONITOR','Platform Monitoring, Usage and Access Audit','PLATFORM','GRP_PLATFORM',true,50,'monitoring','/platform/monitoring',false,false,'35.12','High')
ON CONFLICT (module_code) DO UPDATE SET
    module_name = EXCLUDED.module_name, module_type = EXCLUDED.module_type,
    parent_module_code = EXCLUDED.parent_module_code, is_menu = EXCLUDED.is_menu,
    menu_order = EXCLUDED.menu_order, icon = EXCLUDED.icon, route = EXCLUDED.route,
    is_core = EXCLUDED.is_core, is_optional_legal = EXCLUDED.is_optional_legal,
    scope_ref = EXCLUDED.scope_ref, priority = EXCLUDED.priority, updated_at = now();

UPDATE platform.module SET is_active = false WHERE module_code = 'P_BILLING';   -- future scope

-- ----------------------------------------------------------------------------
-- Privilege types and catalogue
-- ----------------------------------------------------------------------------
INSERT INTO platform.privilege_type (type_code, name, description, sort_order) VALUES
 ('V','View','View records and reports',1),
 ('C','Create','Create new records or transactions',2),
 ('E','Edit','Modify records before they are approved or posted',3),
 ('A','Approve','Verify, approve, reject or return at assigned stages',4),
 ('D','Delete','Cancel, void or deactivate with a reason (posted transactions only by reversal)',5),
 ('X','Export','Export lists and reports (payroll, personal data and full member lists need this)',6),
 ('H','History','See the audit History tab of records',7),
 ('U','Unmask','See identity numbers and sensitive personal data unmasked',8)
ON CONFLICT (type_code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, sort_order = EXCLUDED.sort_order;

INSERT INTO platform.privilege (privilege_code, module_code, type_code, name)
SELECT lower(m.module_code) || '.' || CASE t.type_code WHEN 'V' THEN 'view' WHEN 'C' THEN 'create' WHEN 'E' THEN 'edit'
            WHEN 'A' THEN 'approve' WHEN 'D' THEN 'delete' WHEN 'X' THEN 'export' WHEN 'H' THEN 'history' ELSE 'unmask' END,
       m.module_code, t.type_code, m.module_name || ' - ' || t.name
  FROM platform.module m
  CROSS JOIN platform.privilege_type t
 WHERE m.is_menu AND m.module_type IN ('MODULE','CONFIGURATION','REPORT','DASHBOARD')
   AND CASE m.module_type
         WHEN 'DASHBOARD' THEN t.type_code = 'V'
         WHEN 'REPORT'    THEN t.type_code IN ('V','X')
         ELSE t.type_code IN ('V','C','E','A','D','X','H')
              OR (t.type_code = 'U' AND m.module_code IN ('MEMBER','NOMINEE')) END
ON CONFLICT (privilege_code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Standard role templates and default privilege matrix (Section 3.3)
-- ----------------------------------------------------------------------------
INSERT INTO platform.role_template (role_code, role_name, description, default_home_module, requires_mfa, is_read_only, sort_order) VALUES
 ('EMP','Community Employee','Member registration, loan applications, fee and repayment collection, bookings, expense and asset requests, recording offline decisions where authorised','DASH_EMPLOYEE',false,false,10),
 ('MGR','Manager','Verification, supervision, operational management and final approval of loans, assistance, waivers, overrides and other requests','DASH_MANAGER',true,false,20),
 ('ACC','Accountant','Chart of Accounts, journals and vouchers, payroll preparation, depreciation, cash reconciliation, period closing and financial reporting','DASH_ACCOUNTANT',true,false,30),
 ('LDR','Leadership Team','Organisation oversight, policy approval, payroll approval, high-value approvals and financial supervision','DASH_LEADERSHIP',true,false,40),
 ('AUD','Auditor','Read-only access to financial, operational and audit information','DASH_AUDITOR',false,true,50),
 ('ADM','System Administrator','Tenant administration: users, roles, settings, branding, notification templates; no workflow/rule configuration and no financial transactions','DASH_ADMIN',true,false,60)
ON CONFLICT (role_code) DO UPDATE SET role_name = EXCLUDED.role_name, description = EXCLUDED.description,
    default_home_module = EXCLUDED.default_home_module, requires_mfa = EXCLUDED.requires_mfa,
    is_read_only = EXCLUDED.is_read_only, sort_order = EXCLUDED.sort_order;

-- Matrix rows: module | EMP | MGR | ACC | LDR | AUD | ADM   ('-' = no access)
-- ADM views every tenant menu module (Members, Loans, Collections, Reports) but
-- has no create/edit/approve there: maker-checker separation stays. See 48.
WITH matrix(module_code, emp, mgr, acc, ldr, aud, adm) AS (VALUES
 ('ORG','-','V','V','VA','V','VCED'),
 ('USER_ROLE','-','V','-','VA','V','VCED'),
 ('MEMBER','VCE','VEAD','V','V','V','V'),
 ('LOAN','VCE','VA','V','V','V','V'),
 ('LOAN_FEE','VC','VAD','V','V','V','-'),
 ('LOAN_REPAY','VC','VAD','V','V','V','V'),
 ('LOAN_SETTLE','VC','VA','V','V','V','-'),
 ('LOAN_DEFAULT','VC','VEA','V','V','V','-'),
 ('NOMINEE','VCE','VA','-','V','V','-'),
 ('DECEASED','VC','VA','V','V','V','-'),
 ('ASSIST_EDU','VCE','VA','V','V','V','-'),
 ('ASSIST_CREM','VCE','VA','V','V','V','-'),
 ('BDAY_GRANT','-','VCE','V','VA','V','-'),
 ('EXPENSE','VCE','VA','V','VA','V','-'),
 ('PAYROLL','-','VA','VCE','VA','V','-'),
 ('HALL','VCE','VAD','V','V','V','-'),
 ('ASSET','V','VCE','V','V','V','-'),
 ('ASSET_PURCHASE','VCE','VA','V','VA','V','-'),
 ('ASSET_MAINT','VC','VA','VCE','V','V','-'),
 ('ASSET_DISPOSAL','VC','VA','V','VA','V','-'),
 ('GEN_FUND','-','V','V','V','V','-'),
 ('GL','-','V','V','V','V','-'),
 ('COA','-','V','VCED','VA','V','-'),
 ('JOURNAL','-','V','VCED','VA','V','-'),
 ('TRIAL_BAL','-','V','V','V','V','-'),
 ('FIN_STMT','-','V','V','V','V','-'),
 ('CASH_RECON','-','VA','VCE','V','V','-'),
 ('FIN_PERIOD','-','V','VCE','VA','V','-'),
 ('FIN_REPORT','-','V','V','V','V','V'),
 ('MGMT_REPORT','-','V','V','V','V','-'),
 ('WORKFLOW','-','V','-','V','V','V'),
 ('RULES','-','V','V','V','V','V'),
 ('APPROVAL','VC','VCA','-','VA','V','VE'),
 ('NOTIFICATION','VC','V','-','-','V','VCED'),
 ('AUDIT','-','V','V','V','V','V'),
 ('DEPOSIT','VC','VAD','V','V','V','-'),
 ('CHIT','VC','VAD','V','V','V','-'),
 ('CONTRIB','VC','VAD','V','V','V','-'),
 ('DASH_EMPLOYEE','V','V','-','-','-','-'),
 ('DASH_MANAGER','-','V','-','V','-','-'),
 ('DASH_ACCOUNTANT','-','-','V','V','V','-'),
 ('DASH_LEADERSHIP','-','-','-','V','-','-'),
 ('DASH_AUDITOR','-','-','-','-','V','-'),
 ('DASH_ADMIN','-','-','-','-','-','V')
),
cells AS (
    SELECT module_code, 'EMP' AS role_code, emp AS p FROM matrix UNION ALL
    SELECT module_code, 'MGR', mgr FROM matrix UNION ALL
    SELECT module_code, 'ACC', acc FROM matrix UNION ALL
    SELECT module_code, 'LDR', ldr FROM matrix UNION ALL
    SELECT module_code, 'AUD', aud FROM matrix UNION ALL
    SELECT module_code, 'ADM', adm FROM matrix
),
grants AS (
    SELECT c.role_code, c.module_code, ch AS type_code
      FROM cells c, regexp_split_to_table(c.p, '') ch
     WHERE ch <> '-'
    UNION
    -- export and history for MGR / ACC / LDR / AUD wherever they can view
    SELECT c.role_code, c.module_code, x.t
      FROM cells c, (VALUES ('X'), ('H')) x(t)
     WHERE c.p LIKE '%V%' AND c.role_code IN ('MGR','ACC','LDR','AUD')
    UNION
    -- administrator sees system and security history and can export user lists
    SELECT 'ADM', m, x.t FROM (VALUES ('ORG'), ('USER_ROLE'), ('AUDIT')) mm(m), (VALUES ('X'), ('H')) x(t)
    UNION
    -- unmasking identity data
    SELECT r, m, 'U' FROM (VALUES ('MGR'), ('AUD')) rr(r), (VALUES ('MEMBER'), ('NOMINEE')) mm(m)
)
INSERT INTO platform.role_template_privilege (role_code, privilege_code)
SELECT g.role_code, p.privilege_code
  FROM grants g
  JOIN platform.privilege p ON p.module_code = g.module_code AND p.type_code = g.type_code
ON CONFLICT DO NOTHING;

INSERT INTO platform.sod_rule (role_code_a, role_code_b, description) VALUES
 ('AUD','*','The Auditor is read-only and cannot hold any other role at the same time')
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------------
-- Legal and tax features, payment modes, data categories
-- ----------------------------------------------------------------------------
INSERT INTO platform.compliance_feature (feature_code, name, description, module_code, legal_warning, sort_order) VALUES
 ('GST','GST','GSTIN, GST rates by service, tax invoices, GST Payable accounts and GST reports',NULL,NULL,1),
 ('PAYROLL_STATUTORY','Payroll statutory deductions','TDS on salary, PF, ESI, Professional Tax and Labour Welfare Fund',NULL,NULL,2),
 ('TDS','TDS on payments','TDS on vendor and service payments, TDS Payable account and reports',NULL,NULL,3),
 ('DONATION_80G','Donation receipts (80G)','Donor records, 80G-compliant receipts and donation reports',NULL,NULL,4),
 ('MEMBER_DEPOSITS','Member deposits','Member Deposits module (Section 9)','DEPOSIT',
  'Obtain written legal advice before enabling. Accepting deposits and paying interest may fall under the Banning of Unregulated Deposit Schemes Act, 2019 and RBI rules. CFMS provides the functionality only and does not determine legality.',5),
 ('CHIT_FUNDS','Chit funds','Chit Fund Schemes module (Section 10)','CHIT',
  'Chit funds are regulated under the Chit Funds Act, 1982 and State rules. Prior sanction and registration with the State Registrar of Chits is required for each group. CFMS provides the functionality only and does not determine legality.',6),
 ('FCRA','Foreign contributions (FCRA)','Separate tracking, bank account and reporting of foreign contributions',NULL,NULL,7)
ON CONFLICT (feature_code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
    module_code = EXCLUDED.module_code, legal_warning = EXCLUDED.legal_warning;

INSERT INTO platform.payment_mode (mode_code, name, is_enabled, sort_order) VALUES
 ('CASH','Cash',true,1), ('CHEQUE','Cheque',false,2), ('UPI','UPI / payment link',false,3),
 ('BANK_TRANSFER','Bank transfer',false,4), ('NACH','NACH auto-debit',false,5), ('SALARY_DEDUCTION','Salary deduction',false,6)
ON CONFLICT (mode_code) DO NOTHING;

INSERT INTO platform.data_category (category_code, name, default_years, minimum_years, approval_mandatory) VALUES
 ('FINANCIAL','Financial transactions, journals, vouchers and receipts',8,8,true),
 ('AUDIT','Audit trail and approval evidence',8,8,true),
 ('PAYROLL','Payroll records',8,8,true),
 ('LOAN','Loan records (from loan closure)',8,8,true),
 ('MEMBER','Member records and documents (after last financial transaction)',8,1,true),
 ('DOCUMENTS','Supporting documents and evidence files',8,8,true),
 ('SECURITY_LOGS','Security and access logs (1 year online)',3,1,false),
 ('APP_LOGS','Application logs',0.25,0.25,false),
 ('NOTIFICATIONS','Notifications sent, sessions and temporary files',0.25,0.25,false)
ON CONFLICT (category_code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Setting definitions and default settings template v1 (Section 4.10)
-- ----------------------------------------------------------------------------
WITH s(setting_key, area, name, data_type, editable_by, value, scope_ref, is_proposed, sort_order) AS (VALUES
 ('general.time_zone','General','Time zone','string','ORG_ADMIN','"Asia/Kolkata"'::jsonb,'35.12',false,10),
 ('general.currency','General','Currency','string','ORG_ADMIN','"INR"','35.6',false,11),
 ('general.number_format','General','Number format','string','ORG_ADMIN','"en-IN"','35.6',false,12),
 ('general.date_format','General','Date format','string','ORG_ADMIN','"DD-MM-YYYY"','35.6',false,13),
 ('general.language','General','Default language','string','ORG_ADMIN','"en"','36',false,14),
 ('branding.theme','Branding','Colour theme','json','ORG_ADMIN','{"primary":"#1F4E79","accent":"#F2A900"}','35.6',false,20),
 ('branding.receipt_header','Branding','Receipt / statement header text','string','ORG_ADMIN','""','35.6',false,21),
 ('branding.receipt_footer','Branding','Receipt / statement footer text','string','ORG_ADMIN','""','35.6',false,22),
 ('branding.sms_sender_id','Branding','SMS sender ID (DLT registered)','string','ORG_ADMIN','""','30.3',false,23),
 ('users.activation_link_expiry_hours','Users and login','Activation link expiry (hours)','integer','ORG_ADMIN','48','3.6.1',false,30),
 ('users.mfa_method','Users and login','MFA method for privileged roles','string','ORG_ADMIN','"TOTP"','3.10',false,31),
 ('users.password_min_length','Users and login','Password minimum length','integer','ORG_ADMIN','10','3.10',false,32),
 ('users.password_history','Users and login','Password history (cannot reuse last N)','integer','SUPER_ADMIN','5','3.10',false,33),
 ('users.single_session','Users and login','Allow one active session per user','boolean','SUPER_ADMIN','false','3.10',false,38),
 ('users.password_expiry_days','Users and login','Forced periodic password change (days, null = off)','integer','ORG_ADMIN','null','3.10',false,34),
 ('users.lockout_attempts','Users and login','Account lockout after failed attempts','integer','ORG_ADMIN','5','36',false,35),
 ('users.idle_timeout_privileged_minutes','Users and login','Idle session timeout - privileged roles (minutes)','integer','ORG_ADMIN','15','36',false,36),
 ('users.idle_timeout_other_minutes','Users and login','Idle session timeout - other roles (minutes)','integer','ORG_ADMIN','30','36',false,37),
 ('accounting.basis','Accounting','Accounting basis','string','FIXED','"CASH"','21.5',false,40),
 ('accounting.financial_year_start','Accounting','Financial year start (MM-DD)','string','ORG_ADMIN','"04-01"','21',false,41),
 ('accounting.backdating_limit_days','Accounting','Backdating limit for the working date (days, null = no limit)','integer','SUPER_ADMIN','null','21.7',false,42),
 ('accounting.export_formats','Accounting','Export formats','list','FIXED','["XLSX","PDF","CSV"]','36',false,43),
 ('accounting.depreciation_posting','Accounting','Post depreciation to the ledger','boolean','ACCOUNTANT_WITH_LDR','false','21.5',false,44),
 ('rounding.loan_instalment','Rounding','Loan instalments (EMI)','json','ACCOUNTANT_WITH_LDR','{"mode":"FLOOR","precision":1}','4.9',true,50),
 ('rounding.interest','Rounding','Interest amounts','json','ACCOUNTANT_WITH_LDR','{"mode":"NEAREST","precision":1}','4.9',true,51),
 ('rounding.settlement','Rounding','Early and default settlement amounts','json','ACCOUNTANT_WITH_LDR','{"mode":"NEAREST","precision":1}','4.9',true,52),
 ('rounding.application_fee','Rounding','Application fees (percentage based)','json','ACCOUNTANT_WITH_LDR','{"mode":"NEAREST","precision":1}','4.9',true,53),
 ('rounding.hall_charges','Rounding','Marriage hall charges','json','ACCOUNTANT_WITH_LDR','{"mode":"NEAREST","precision":1}','4.9',true,54),
 ('rounding.payroll_net','Rounding','Payroll net salary','json','ACCOUNTANT_WITH_LDR','{"mode":"NEAREST","precision":1}','4.9',true,55),
 ('rounding.depreciation','Rounding','Depreciation','json','ACCOUNTANT_WITH_LDR','{"mode":"NONE","precision":0.01}','4.9',true,56),
 ('rounding.assistance','Rounding','Assistance amounts','json','ACCOUNTANT_WITH_LDR','{"mode":"NONE","precision":0.01}','4.9',true,57),
 ('loans.nominee_mandatory_first_loan','Loans','Nominee mandatory for a member''s first loan','boolean','SUPER_ADMIN','true','6.1',false,60),
 ('loans.disbursement_window_days','Loans','Disbursement window after approval (days)','integer','SUPER_ADMIN','30','6.6',false,61),
 ('loans.deduct_fee_from_disbursement','Loans','Allow fee deduction from disbursement','boolean','SUPER_ADMIN','false','6.6',false,62),
 ('loans.default_after_months','Loans','Default after unpaid months','integer','SUPER_ADMIN','2','8.1',false,63),
 ('loans.cooling_off','Loans','Cooling-off period','json','SUPER_ADMIN','{"appliesAfter":"DEFAULTED_LOAN_ONLY","months":6}','8.4',true,64),
 ('loans.min_membership_months','Loans','Minimum membership period for a loan (months)','integer','SUPER_ADMIN','6','6.8',true,65),
 ('loans.max_concurrent_loans','Loans','Maximum concurrent active loans per member','integer','SUPER_ADMIN','1','6.8',true,66),
 ('loans.guarantors_required','Loans','Guarantors required','json','SUPER_ADMIN','{"count":0,"aboveAmount":null}','6.9',false,67),
 ('loans.restructuring','Loans','Restructuring','json','SUPER_ADMIN','{"allowed":true,"maxPerLoan":1,"maxMoratoriumMonths":3}','6.10',false,68),
 ('loans.payment_allocation_order','Loans','Payment allocation order','list','SUPER_ADMIN','["LATE_FEE","OVERDUE_INTEREST","OVERDUE_PRINCIPAL","CURRENT_INTEREST","CURRENT_PRINCIPAL"]','7.4',false,69),
 ('loans.block_if_overdue_dues','Loans','Block new loans while any dues are overdue','boolean','SUPER_ADMIN','true','6.8',false,70),
 ('recovery.escalate_to_manager_days','Recovery','Escalate unpaid defaulters to the Manager after (days)','integer','SUPER_ADMIN','30','28.5',false,80),
 ('recovery.escalate_to_leadership_days','Recovery','Escalate further to Leadership after (days)','integer','SUPER_ADMIN','30','28.5',true,81),
 ('approvals.approver_role','Approvals','Approver (single approver for all amounts)','string','SUPER_ADMIN','"MGR"','4.7',false,90),
 ('approvals.offline_recorder_roles','Approvals','Roles that can record offline decisions','list','SUPER_ADMIN','["EMP","MGR"]','4.7',false,91),
 ('approvals.offline_evidence_types','Approvals','Offline evidence types (upload optional)','list','SUPER_ADMIN','["VERBAL","MEETING","PHONE","SIGNED_PAPER"]','4.7',false,92),
 ('notifications.channels','Notifications','Channels enabled','json','ORG_ADMIN','{"SMS":true,"WHATSAPP":false,"EMAIL":false,"INAPP":true}','30',false,100),
 ('notifications.quiet_hours','Notifications','Quiet hours (no routine reminders)','json','ORG_ADMIN','{"from":"21:00","to":"08:00"}','30.3',false,101),
 ('notifications.loan_reminder_schedule','Notifications','Loan reminder schedule (days relative to due date)','json','ORG_ADMIN','{"before":[7,3,1],"onDueDate":true,"overdueAfter":1,"repeatEveryDays":7}','30.1',false,102),
 ('notifications.whatsapp_sms_fallback','Notifications','Send SMS when WhatsApp fails','boolean','ORG_ADMIN','true','30.3',false,103),
 ('hall.tentative_hold_days','Hall','Tentative booking hold (days)','integer','ORG_ADMIN','3','18.6',false,110),
 ('data.archive_retention_years','Data','Archive retention before final deletion (years)','integer','ORG_ADMIN','2','36',false,120),
 ('cash.receipt_cancel_same_day_approver','Cash','Receipt cancellation before day-end: approver role','string','SUPER_ADMIN','"MGR"','7.7',false,130),
 ('cash.receipt_cancel_after_close_approvers','Cash','Receipt cancellation after day-end: approver roles','list','SUPER_ADMIN','["MGR","ACC"]','7.7',false,131),
 ('petty_cash.max_limit','Petty cash','Maximum petty cash advance per employee','decimal','SUPER_ADMIN','5000','16.1',true,140),
 ('petty_cash.flag_after_days','Petty cash','Flag outstanding advances older than (days)','integer','ORG_ADMIN','30','16.1',true,141)
),
d AS (
    INSERT INTO platform.setting_definition (setting_key, area, name, data_type, editable_by, scope_ref, is_proposed, sort_order)
    SELECT setting_key, area, name, data_type, editable_by, scope_ref, is_proposed, sort_order FROM s
    ON CONFLICT (setting_key) DO UPDATE SET area = EXCLUDED.area, name = EXCLUDED.name, data_type = EXCLUDED.data_type,
        editable_by = EXCLUDED.editable_by, scope_ref = EXCLUDED.scope_ref, is_proposed = EXCLUDED.is_proposed,
        sort_order = EXCLUDED.sort_order
    RETURNING setting_key
),
t AS (
    INSERT INTO platform.settings_template (version_no, status, description, reason, published_at)
    VALUES (1, 'PUBLISHED', 'Initial default settings (scope v1.7, Section 4.10)', 'Initial platform defaults', now())
    ON CONFLICT (version_no) DO NOTHING
    RETURNING version_no
)
SELECT count(*) AS settings_defined FROM d;

INSERT INTO platform.settings_template_item (version_no, setting_key, value)
SELECT 1, x.setting_key, x.value
  FROM (VALUES
 ('general.time_zone','"Asia/Kolkata"'::jsonb), ('general.currency','"INR"'), ('general.number_format','"en-IN"'),
 ('general.date_format','"DD-MM-YYYY"'), ('general.language','"en"'),
 ('branding.theme','{"primary":"#1F4E79","accent":"#F2A900"}'), ('branding.receipt_header','""'),
 ('branding.receipt_footer','""'), ('branding.sms_sender_id','""'),
 ('users.activation_link_expiry_hours','48'), ('users.mfa_method','"TOTP"'), ('users.password_min_length','10'),
 ('users.password_history','5'), ('users.single_session','false'), ('users.password_expiry_days','null'), ('users.lockout_attempts','5'),
 ('users.idle_timeout_privileged_minutes','15'), ('users.idle_timeout_other_minutes','30'),
 ('accounting.basis','"CASH"'), ('accounting.financial_year_start','"04-01"'), ('accounting.backdating_limit_days','null'),
 ('accounting.export_formats','["XLSX","PDF","CSV"]'), ('accounting.depreciation_posting','false'),
 ('rounding.loan_instalment','{"mode":"FLOOR","precision":1}'), ('rounding.interest','{"mode":"NEAREST","precision":1}'),
 ('rounding.settlement','{"mode":"NEAREST","precision":1}'), ('rounding.application_fee','{"mode":"NEAREST","precision":1}'),
 ('rounding.hall_charges','{"mode":"NEAREST","precision":1}'), ('rounding.payroll_net','{"mode":"NEAREST","precision":1}'),
 ('rounding.depreciation','{"mode":"NONE","precision":0.01}'), ('rounding.assistance','{"mode":"NONE","precision":0.01}'),
 ('loans.nominee_mandatory_first_loan','true'), ('loans.disbursement_window_days','30'),
 ('loans.deduct_fee_from_disbursement','false'), ('loans.default_after_months','2'),
 ('loans.cooling_off','{"appliesAfter":"DEFAULTED_LOAN_ONLY","months":6}'), ('loans.min_membership_months','6'),
 ('loans.max_concurrent_loans','1'), ('loans.guarantors_required','{"count":0,"aboveAmount":null}'),
 ('loans.restructuring','{"allowed":true,"maxPerLoan":1,"maxMoratoriumMonths":3}'),
 ('loans.payment_allocation_order','["LATE_FEE","OVERDUE_INTEREST","OVERDUE_PRINCIPAL","CURRENT_INTEREST","CURRENT_PRINCIPAL"]'),
 ('loans.block_if_overdue_dues','true'),
 ('recovery.escalate_to_manager_days','30'), ('recovery.escalate_to_leadership_days','30'),
 ('approvals.approver_role','"MGR"'), ('approvals.offline_recorder_roles','["EMP","MGR"]'),
 ('approvals.offline_evidence_types','["VERBAL","MEETING","PHONE","SIGNED_PAPER"]'),
 ('notifications.channels','{"SMS":true,"WHATSAPP":false,"EMAIL":false,"INAPP":true}'),
 ('notifications.quiet_hours','{"from":"21:00","to":"08:00"}'),
 ('notifications.loan_reminder_schedule','{"before":[7,3,1],"onDueDate":true,"overdueAfter":1,"repeatEveryDays":7}'),
 ('notifications.whatsapp_sms_fallback','true'), ('hall.tentative_hold_days','3'), ('data.archive_retention_years','2'),
 ('cash.receipt_cancel_same_day_approver','"MGR"'), ('cash.receipt_cancel_after_close_approvers','["MGR","ACC"]'),
 ('petty_cash.max_limit','5000'), ('petty_cash.flag_after_days','30')
 ) AS x(setting_key, value)
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------------
-- Standard chart of accounts template (Section 21.1)
-- ----------------------------------------------------------------------------
INSERT INTO platform.coa_template (account_code, account_name, account_type, parent_code, is_group, module_code,
                                   feature_code, is_cash, is_active_default, allow_manual, sub_ledger_type, notes, sort_order)
VALUES
 ('1000','Assets','ASSET',NULL,true,NULL,NULL,false,true,false,NULL,NULL,1000),
 ('1110','Cash in Hand','ASSET','1000',false,NULL,NULL,true,true,false,NULL,'The single common cash account, shown in the top bar',1110),
 ('1150','Bank Accounts','ASSET','1000',false,NULL,NULL,false,false,false,NULL,'Reserved for future use; not used now',1150),
 ('1210','Loan Principal Receivable','ASSET','1000',true,'LOAN',NULL,false,true,false,'LOAN_TYPE','One sub-account per loan type',1210),
 ('1310','Petty Cash Advances - Employees','ASSET','1000',false,NULL,NULL,false,true,false,'EMPLOYEE',NULL,1310),
 ('1320','Salary Advances - Employees','ASSET','1000',false,NULL,NULL,false,true,false,'EMPLOYEE',NULL,1320),
 ('1330','Advances to Vendors','ASSET','1000',false,NULL,NULL,false,true,false,'VENDOR',NULL,1330),
 ('1410','Land and Buildings','ASSET','1000',false,NULL,NULL,false,true,true,NULL,NULL,1410),
 ('1420','Furniture and Fixtures','ASSET','1000',false,NULL,NULL,false,true,true,NULL,NULL,1420),
 ('1430','Electronics and Office Equipment','ASSET','1000',false,NULL,NULL,false,true,true,NULL,NULL,1430),
 ('1440','Vehicles','ASSET','1000',false,NULL,NULL,false,true,true,NULL,NULL,1440),
 ('1450','Community Facilities','ASSET','1000',false,NULL,NULL,false,true,true,NULL,NULL,1450),
 ('1490','Accumulated Depreciation','CONTRA_ASSET','1000',false,NULL,NULL,false,false,true,NULL,'Only if depreciation posting is enabled',1490),
 ('2000','Liabilities (money held for others)','LIABILITY',NULL,true,NULL,NULL,false,true,false,NULL,NULL,2000),
 ('2110','Security Deposits Held - Hall Bookings','LIABILITY','2000',false,NULL,NULL,false,true,false,NULL,NULL,2110),
 ('2120','Member Unapplied Receipts','LIABILITY','2000',false,NULL,NULL,false,true,false,NULL,'Excess payments awaiting application or refund',2120),
 ('2210','Member Deposits - Recurring','LIABILITY','2000',false,'DEPOSIT',NULL,false,true,false,'DEPOSIT_PRODUCT','Member Deposits module',2210),
 ('2220','Member Deposits - Fixed','LIABILITY','2000',false,'DEPOSIT',NULL,false,true,false,'DEPOSIT_PRODUCT','Member Deposits module',2220),
 ('2310','Chit Subscriptions','LIABILITY','2000',true,'CHIT',NULL,false,true,false,'CHIT_GROUP','One sub-account per chit group',2310),
 ('2320','Chit Prize Payable','LIABILITY','2000',true,'CHIT',NULL,false,true,false,'CHIT_GROUP','One sub-account per chit group',2320),
 ('2330','Chit Dividend Payable','LIABILITY','2000',true,'CHIT',NULL,false,true,false,'CHIT_GROUP','One sub-account per chit group',2330),
 ('2410','Statutory Dues Payable (GST, TDS, PF, ESI)','LIABILITY','2000',false,NULL,NULL,false,false,false,NULL,'Activated when a legal and tax feature is enabled',2410),
 ('3000','Funds','FUND',NULL,true,NULL,NULL,false,true,false,NULL,NULL,3000),
 ('3100','General Community Fund (Accumulated Fund)','FUND','3000',false,NULL,NULL,false,true,true,'FUND','Surplus or deficit is transferred here at year end',3100),
 ('3200','Designated Funds','FUND','3000',true,NULL,NULL,false,true,false,'FUND','One sub-account per designated fund',3200),
 ('3300','Restricted Funds','FUND','3000',true,NULL,NULL,false,true,false,'FUND','Restricted donations are credited here directly',3300),
 ('3400','Corpus Fund','FUND','3000',false,NULL,NULL,false,true,true,'FUND',NULL,3400),
 ('4000','Income','INCOME',NULL,true,NULL,NULL,false,true,false,NULL,NULL,4000),
 ('4110','Loan Interest Income','INCOME','4000',false,'LOAN',NULL,false,true,false,'LOAN_TYPE',NULL,4110),
 ('4120','Application Fee Income','INCOME','4000',false,'LOAN',NULL,false,true,false,NULL,NULL,4120),
 ('4130','Late Fee Income','INCOME','4000',false,'LOAN',NULL,false,true,false,NULL,NULL,4130),
 ('4140','Default Penalty Income','INCOME','4000',false,'LOAN',NULL,false,true,false,NULL,NULL,4140),
 ('4150','Bad Debts Recovered','INCOME','4000',false,'LOAN',NULL,false,true,false,NULL,NULL,4150),
 ('4210','Marriage Hall Rental Income','INCOME','4000',false,'HALL',NULL,false,true,false,'HALL',NULL,4210),
 ('4220','Hall Additional Charges and Damages','INCOME','4000',false,'HALL',NULL,false,true,false,NULL,NULL,4220),
 ('4310','Member Contributions','INCOME','4000',false,NULL,NULL,false,true,false,NULL,NULL,4310),
 ('4320','Donations - Unrestricted','INCOME','4000',false,NULL,NULL,false,true,false,NULL,NULL,4320),
 ('4410','Foreman Commission Income','INCOME','4000',false,'CHIT',NULL,false,true,false,NULL,NULL,4410),
 ('4420','Chit Late Fee Income','INCOME','4000',false,'CHIT',NULL,false,true,false,NULL,NULL,4420),
 ('4510','Gain on Asset Disposal','INCOME','4000',false,NULL,NULL,false,true,true,NULL,NULL,4510),
 ('4900','Other Income','INCOME','4000',false,NULL,NULL,false,true,true,NULL,NULL,4900),
 ('5000','Expenditure','EXPENSE',NULL,true,NULL,NULL,false,true,false,NULL,NULL,5000),
 ('5110','Education Assistance','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,NULL,5110),
 ('5120','Cremation Assistance','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,NULL,5120),
 ('5130','Birthday Grants','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,NULL,5130),
 ('5140','Other Community Assistance','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,NULL,5140),
 ('5210','Salaries and Allowances','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,NULL,5210),
 ('5220','Bonus','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,NULL,5220),
 ('5310','Office Expenses','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5310),
 ('5320','Electricity and Water','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5320),
 ('5330','Maintenance and Repairs','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,'Includes asset maintenance',5330),
 ('5340','Travel and Fuel','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5340),
 ('5350','Food and Refreshments','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5350),
 ('5360','Medical','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5360),
 ('5370','Community Activities and Events','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5370),
 ('5390','Miscellaneous Expenses','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5390),
 ('5410','Interest on Member Deposits','EXPENSE','5000',false,'DEPOSIT',NULL,false,true,false,NULL,'Member Deposits module',5410),
 ('5510','Bad Debts Written Off','EXPENSE','5000',false,'LOAN',NULL,false,true,false,NULL,NULL,5510),
 ('5520','Loss on Asset Disposal','EXPENSE','5000',false,NULL,NULL,false,true,true,NULL,NULL,5520),
 ('5530','Depreciation','EXPENSE','5000',false,NULL,NULL,false,false,true,NULL,'Only if depreciation posting is enabled',5530),
 ('5540','Cash Shortage / Excess','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,'Day-end variances (may carry a credit balance)',5540),
 ('5550','Rounding Off','EXPENSE','5000',false,NULL,NULL,false,true,false,NULL,'May carry a credit balance',5550)
ON CONFLICT (account_code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Lookup templates (cloned into each tenant)
-- ----------------------------------------------------------------------------
INSERT INTO platform.lookup_template (lookup_type, code, name, attributes, sort_order) VALUES
 ('EXPENSE_CATEGORY','OFFICE','Office','{"account_code":"5310"}',1),
 ('EXPENSE_CATEGORY','ELECTRICITY','Electricity','{"account_code":"5320"}',2),
 ('EXPENSE_CATEGORY','WATER','Water','{"account_code":"5320"}',3),
 ('EXPENSE_CATEGORY','MAINTENANCE','Maintenance','{"account_code":"5330"}',4),
 ('EXPENSE_CATEGORY','TRAVEL','Travel','{"account_code":"5340"}',5),
 ('EXPENSE_CATEGORY','FUEL','Fuel','{"account_code":"5340"}',6),
 ('EXPENSE_CATEGORY','FOOD','Food','{"account_code":"5350"}',7),
 ('EXPENSE_CATEGORY','MEDICAL','Medical','{"account_code":"5360"}',8),
 ('EXPENSE_CATEGORY','COMMUNITY_ACTIVITIES','Community activities','{"account_code":"5370"}',9),
 ('EXPENSE_CATEGORY','EVENTS','Events','{"account_code":"5370"}',10),
 ('EXPENSE_CATEGORY','MISCELLANEOUS','Miscellaneous','{"account_code":"5390"}',11),
 ('ASSET_CATEGORY','LAND_PROPERTY','Land and property','{"account_code":"1410","method":"NONE"}',1),
 ('ASSET_CATEGORY','FURNITURE','Furniture','{"account_code":"1420","method":"STRAIGHT_LINE","life_months":120}',2),
 ('ASSET_CATEGORY','ELECTRONICS','Electronics','{"account_code":"1430","method":"STRAIGHT_LINE","life_months":36}',3),
 ('ASSET_CATEGORY','OFFICE_EQUIPMENT','Office equipment','{"account_code":"1430","method":"STRAIGHT_LINE","life_months":60}',4),
 ('ASSET_CATEGORY','VEHICLES','Vehicles','{"account_code":"1440","method":"WRITTEN_DOWN_VALUE","life_months":96}',5),
 ('ASSET_CATEGORY','COMMUNITY_FACILITIES','Community facilities','{"account_code":"1450","method":"STRAIGHT_LINE","life_months":240}',6),
 ('ASSET_CATEGORY','OTHER','Other assets','{"account_code":"1450","method":"NONE"}',7),
 ('HALL_CHARGE_TYPE','SECURITY_DEPOSIT','Security deposit','{"account_code":"2110","security_deposit":true}',1),
 ('HALL_CHARGE_TYPE','CLEANING','Cleaning','{"account_code":"4220"}',2),
 ('HALL_CHARGE_TYPE','ELECTRICITY','Electricity','{"account_code":"4220"}',3),
 ('HALL_CHARGE_TYPE','DECORATION','Decoration','{"account_code":"4220"}',4),
 ('HALL_CHARGE_TYPE','EXTRA_HOURS','Additional hours','{"account_code":"4220"}',5),
 ('HALL_CHARGE_TYPE','EXTRA_DAY','Additional day','{"account_code":"4210"}',6),
 ('HALL_CHARGE_TYPE','DAMAGES','Damages','{"account_code":"4220"}',7),
 ('SALARY_COMPONENT','BASIC','Basic salary','{"type":"EARNING","account_code":"5210"}',1),
 ('SALARY_COMPONENT','ALLOWANCE','Allowances','{"type":"EARNING","account_code":"5210"}',2),
 ('SALARY_COMPONENT','BONUS','Bonus','{"type":"EARNING","account_code":"5220","calc":"VARIABLE"}',3),
 ('SALARY_COMPONENT','LOP','Loss of pay','{"type":"DEDUCTION","calc":"VARIABLE"}',4),
 ('SALARY_COMPONENT','SALARY_ADVANCE','Salary advance recovery','{"type":"DEDUCTION","account_code":"1320","calc":"VARIABLE"}',5),
 ('SALARY_COMPONENT','LOAN_DEDUCTION','Authorised loan deduction','{"type":"DEDUCTION","calc":"VARIABLE"}',6),
 ('SALARY_COMPONENT','OTHER_DEDUCTION','Other deductions','{"type":"DEDUCTION","calc":"VARIABLE"}',7),
 ('OFFLINE_EVIDENCE_TYPE','VERBAL','Verbal instruction','{}',1),
 ('OFFLINE_EVIDENCE_TYPE','MEETING','Meeting','{}',2),
 ('OFFLINE_EVIDENCE_TYPE','PHONE','Phone call','{}',3),
 ('OFFLINE_EVIDENCE_TYPE','SIGNED_PAPER','Signed paper','{}',4),
 ('RELATIONSHIP','SPOUSE','Spouse','{}',1), ('RELATIONSHIP','SON','Son','{}',2), ('RELATIONSHIP','DAUGHTER','Daughter','{}',3),
 ('RELATIONSHIP','FATHER','Father','{}',4), ('RELATIONSHIP','MOTHER','Mother','{}',5), ('RELATIONSHIP','BROTHER','Brother','{}',6),
 ('RELATIONSHIP','SISTER','Sister','{}',7), ('RELATIONSHIP','OTHER','Other','{}',99),
 ('ID_TYPE','AADHAAR','Aadhaar','{}',1), ('ID_TYPE','PAN','PAN','{}',2), ('ID_TYPE','VOTER_ID','Voter ID','{}',3),
 ('ID_TYPE','PASSPORT','Passport','{}',4), ('ID_TYPE','DRIVING_LICENCE','Driving licence','{}',5), ('ID_TYPE','RATION_CARD','Ration card','{}',6),
 ('EVENT_TYPE','MARRIAGE','Marriage','{}',1), ('EVENT_TYPE','RECEPTION','Reception','{}',2), ('EVENT_TYPE','ENGAGEMENT','Engagement','{}',3),
 ('EVENT_TYPE','BIRTHDAY','Birthday','{}',4), ('EVENT_TYPE','MEETING','Meeting','{}',5), ('EVENT_TYPE','OTHER','Other','{}',99),
 ('DOCUMENT_TYPE','ID_PROOF','Identity proof','{}',1), ('DOCUMENT_TYPE','ADDRESS_PROOF','Address proof','{}',2),
 ('DOCUMENT_TYPE','PHOTO','Photo','{}',3), ('DOCUMENT_TYPE','DEATH_CERTIFICATE','Death certificate','{}',4),
 ('DOCUMENT_TYPE','ADMISSION_PROOF','Proof of admission','{}',5), ('DOCUMENT_TYPE','FEE_RECEIPT','Fee receipt','{}',6),
 ('DOCUMENT_TYPE','BILL','Bill','{}',7), ('DOCUMENT_TYPE','INVOICE','Invoice','{}',8), ('DOCUMENT_TYPE','QUOTATION','Quotation','{}',9),
 ('DOCUMENT_TYPE','EVIDENCE','Approval evidence','{}',10), ('DOCUMENT_TYPE','OTHER','Other','{}',99)
ON CONFLICT (lookup_type, code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Notification templates (platform defaults, English)
-- ----------------------------------------------------------------------------
INSERT INTO platform.notification_template_default (code, channel, language_code, name, subject, body, module_code, is_essential) VALUES
 ('LOAN_DUE_REMINDER','SMS','en','Loan instalment reminder',NULL,'Dear {{member_name}}, your loan {{loan_no}} instalment of Rs {{amount}} is due on {{due_date}}. - {{org_name}}','LOAN_REPAY',false),
 ('LOAN_OVERDUE','SMS','en','Loan instalment overdue',NULL,'Dear {{member_name}}, your loan {{loan_no}} instalment of Rs {{amount}} due on {{due_date}} is overdue. Please pay at the office. - {{org_name}}','LOAN_REPAY',true),
 ('LOAN_FEE_RECEIPT','SMS','en','Application fee receipt',NULL,'Received Rs {{amount}} as application fee for loan application {{loan_no}}. Receipt {{receipt_no}}. - {{org_name}}','LOAN_FEE',true),
 ('LOAN_APPROVED','SMS','en','Loan approved',NULL,'Dear {{member_name}}, your loan application {{loan_no}} for Rs {{amount}} is approved. - {{org_name}}','LOAN',true),
 ('LOAN_REJECTED','SMS','en','Loan rejected',NULL,'Dear {{member_name}}, your loan application {{loan_no}} was not approved. Please contact the office. - {{org_name}}','LOAN',true),
 ('LOAN_DISBURSED','SMS','en','Loan disbursed',NULL,'Dear {{member_name}}, Rs {{amount}} disbursed for loan {{loan_no}}. First instalment due {{due_date}}. - {{org_name}}','LOAN',true),
 ('REPAYMENT_RECEIPT','SMS','en','Repayment receipt',NULL,'Received Rs {{amount}} for loan {{loan_no}}. Receipt {{receipt_no}}. Outstanding Rs {{outstanding}}. - {{org_name}}','LOAN_REPAY',true),
 ('LOAN_SETTLED','SMS','en','Loan settled',NULL,'Dear {{member_name}}, your loan {{loan_no}} is fully settled. Thank you. - {{org_name}}','LOAN_SETTLE',true),
 ('LOAN_DEFAULTED','SMS','en','Loan defaulted',NULL,'Dear {{member_name}}, loan {{loan_no}} is in default. Total payable Rs {{amount}}. Please contact the office. - {{org_name}}','LOAN_DEFAULT',true),
 ('COOLING_OFF_COMPLETED','SMS','en','Cooling-off completed',NULL,'Dear {{member_name}}, your cooling-off period has ended. You may apply for a new loan. - {{org_name}}','LOAN_DEFAULT',false),
 ('HALL_BOOKING_CONFIRMED','SMS','en','Hall booking confirmed',NULL,'Booking {{booking_no}} confirmed for {{hall_name}} on {{event_date}}. Receipt {{receipt_no}}. - {{org_name}}','HALL',true),
 ('ASSISTANCE_APPROVED','SMS','en','Assistance approved',NULL,'Dear {{member_name}}, your {{scheme_name}} application {{application_no}} for Rs {{amount}} is approved. - {{org_name}}','ASSIST_EDU',true),
 ('USER_ACTIVATION','SMS','en','User activation link',NULL,'Welcome to {{org_name}} CFMS. Activate your account: {{link}} (valid {{hours}} hours).','USER_ROLE',true),
 ('USER_ACTIVATION','EMAIL','en','User activation link','Activate your CFMS account','Hello {{user_name}},\n\nAn account has been created for you at {{org_name}}. Activate it here: {{link}}\nThe link is valid for {{hours}} hours.','USER_ROLE',true),
 ('PASSWORD_RESET_OTP','SMS','en','Password reset OTP',NULL,'{{otp}} is your CFMS password reset code. It expires in 10 minutes. Do not share it.','USER_ROLE',true)
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------------
-- Action catalogue (Section 25.4) - seeded as approved
-- ----------------------------------------------------------------------------
INSERT INTO platform.action_definition (action_code, name, description, category, action_kind, default_execution_type,
                                        config_schema, implementation_version, status, approved_at, approval_reason)
SELECT a.code, a.name, a.description, a.category, a.kind, a.exec, a.cfg::jsonb, '1.0', 'APPROVED', now(), 'Initial catalogue'
  FROM (VALUES
 ('VALIDATE_MEMBER_STATUS','Validate Member Status','Member must be Active and not restricted','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('VALIDATE_LOAN_ELIGIBILITY','Validate Loan Eligibility','Default history, outstanding loans, cooling-off, membership period, limits','Validation','VALIDATION','SYNCHRONOUS',
   '{"type":"object","properties":{"checkDefaultHistory":{"type":"boolean"},"checkOutstandingLoans":{"type":"boolean"},"checkCoolingOff":{"type":"boolean"},"checkMemberStatus":{"type":"boolean"}}}'),
 ('VALIDATE_APPLICATION_FEE','Validate Application Fee','Fee must be paid or waived before submission','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('VALIDATE_NOMINEE','Validate Nominee','Nominee required for first loan / above threshold','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('VALIDATE_GUARANTORS','Validate Guarantors','Required guarantors present and within limits','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('VALIDATE_APPROVAL_AUTHORITY','Validate Approval Authority','Approver holds the stage role and is not the requester / beneficiary','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('VALIDATE_DUPLICATE_MEMBER','Validate Duplicate Member','Duplicate check by mobile, name + DOB and identity','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('VALIDATE_FUND_BALANCE','Validate Fund Balance','Restricted fund purpose and available balance','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('CHECK_HALL_AVAILABILITY','Check Hall Availability','One booking per hall per day','Validation','VALIDATION','SYNCHRONOUS',NULL),
 ('GENERATE_REFERENCE','Generate Reference Number','Assign the business reference number','Utility','DATA','SYNCHRONOUS',NULL),
 ('CALCULATE_APPLICATION_FEE','Calculate Application Fee','Fee from the loan type rule set','Loan','DATA','SYNCHRONOUS',NULL),
 ('GENERATE_RECEIPT','Generate Receipt','Create a numbered cash receipt','Finance','DATA','SYNCHRONOUS',NULL),
 ('GENERATE_JOURNAL_ENTRY','Generate Journal Entry','Post a balanced journal from a journal template','Accounting','DATA','SYNCHRONOUS',
   '{"type":"object","properties":{"journalTemplate":{"type":"string"},"debitMapping":{"type":"string"},"creditMapping":{"type":"string"},"postingMode":{"enum":["IMMEDIATE","ON_APPROVAL"]}},"required":["journalTemplate"]}'),
 ('GENERATE_REPAYMENT_SCHEDULE','Generate Repayment Schedule','Flat-interest schedule with rounding rules','Loan','DATA','SYNCHRONOUS',NULL),
 ('CREATE_DISBURSEMENT_INSTRUCTION','Create Disbursement Instruction','Prepare the payment voucher for maker-checker release','Loan','DATA','SYNCHRONOUS',NULL),
 ('UPDATE_LOAN_BALANCES','Update Loan Balances','Recalculate outstanding balances and status','Loan','DATA','SYNCHRONOUS',NULL),
 ('CALCULATE_SETTLEMENT','Calculate Settlement','Early / default settlement statement','Loan','DATA','SYNCHRONOUS',NULL),
 ('CLOSE_LOAN','Close Loan','Mark the loan Settled / Closed and cancel future instalments','Loan','DATA','SYNCHRONOUS',NULL),
 ('CALCULATE_DEFAULT','Calculate Default Amount','Full outstanding plus default penalty','Loan','DATA','SYNCHRONOUS',NULL),
 ('RESTRICT_ELIGIBILITY','Restrict Eligibility','Set member loan eligibility to Restricted / Cooling-off','Loan','DATA','SYNCHRONOUS',NULL),
 ('CREATE_RECOVERY_CASE','Create Recovery Case','Open and assign a recovery case','Loan','DATA','SYNCHRONOUS',NULL),
 ('ACTIVATE_MEMBER','Activate Member','Set member status Active with effective date','Member','DATA','SYNCHRONOUS',NULL),
 ('LOCK_HALL_PRICE','Lock Hall Price','Lock pricing on confirmation','Hall','DATA','SYNCHRONOUS',NULL),
 ('REGISTER_ASSET','Register Asset','Create the asset register entry','Asset','DATA','SYNCHRONOUS',NULL),
 ('RECORD_OFFLINE_APPROVAL','Record Offline Approval','Record a verbal / meeting / document decision with evidence','Approval','APPROVAL','MANUAL',NULL),
 ('COLLECT_DECISION','Collect Decision','Wait for the approver''s decision','Approval','MANUAL','MANUAL',NULL),
 ('SEND_NOTIFICATION','Send Notification','Queue an SMS / WhatsApp / email notification (retried on failure)','Notification','NOTIFICATION','ASYNCHRONOUS',
   '{"type":"object","properties":{"channel":{"enum":["SMS","WHATSAPP","EMAIL","INAPP"]},"recipientType":{"type":"string"},"template":{"type":"string"},"delayMinutes":{"type":"integer"},"retryCount":{"type":"integer"}},"required":["template"]}')
 ) AS a(code, name, description, category, kind, exec, cfg)
ON CONFLICT (action_code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- JSON Schemas for workflow and rule documents (v1.0)
-- ----------------------------------------------------------------------------
INSERT INTO platform.json_schema (schema_kind, schema_version, description, schema_doc) VALUES
('WORKFLOW','1.0','CFMS workflow document', $json$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "CFMS Workflow",
  "type": "object",
  "required": ["workflow", "schemaVersion", "startStage", "stages", "transitions"],
  "properties": {
    "workflow":      { "type": "string", "pattern": "^[A-Z][A-Z0-9_]*$" },
    "version":       { "type": "integer", "minimum": 1 },
    "schemaVersion": { "const": "1.0" },
    "startStage":    { "type": "string" },
    "stages": {
      "type": "array", "minItems": 1,
      "items": {
        "type": "object", "required": ["code"],
        "properties": {
          "code":     { "type": "string", "pattern": "^[A-Z][A-Z0-9_]*$" },
          "name":     { "type": "string" },
          "role":     { "type": "string" },
          "end":      { "type": "boolean" },
          "approval": { "type": "object", "properties": { "methods": { "type": "array", "items": { "enum": ["online", "offline"] } } } },
          "actions": {
            "type": "array",
            "items": {
              "type": "object", "required": ["seq", "action"],
              "properties": {
                "seq":       { "type": "integer", "minimum": 1 },
                "action":    { "type": "string", "pattern": "^[A-Z][A-Z0-9_]*$" },
                "type":      { "enum": ["validation", "sync", "async", "conditional", "parallel", "manual", "scheduled"] },
                "mandatory": { "type": "boolean" },
                "enabled":   { "type": "boolean" },
                "retry":     { "type": "integer", "minimum": 0 },
                "config":    { "type": "object" }
              }
            }
          }
        }
      }
    },
    "transitions": {
      "type": "array",
      "items": {
        "type": "object", "required": ["from", "to", "on"],
        "properties": {
          "from": { "type": "string" }, "to": { "type": "string" }, "on": { "type": "string" },
          "when": { "type": "object" }
        }
      }
    }
  }
}
$json$::jsonb),
('RULESET','1.0','CFMS rule set document', $json$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "CFMS Rule Set",
  "type": "object",
  "required": ["ruleSet", "schemaVersion", "rules"],
  "properties": {
    "ruleSet":       { "type": "string", "pattern": "^[A-Z][A-Z0-9_]*$" },
    "version":       { "type": "integer", "minimum": 1 },
    "schemaVersion": { "const": "1.0" },
    "effectiveFrom": { "type": "string", "format": "date" },
    "rules": {
      "type": "array",
      "items": {
        "type": "object", "required": ["code"],
        "properties": {
          "code":  { "type": "string", "pattern": "^[A-Z][A-Z0-9_]*$" },
          "value": {},
          "when":  { "$ref": "#/$defs/condition" },
          "then":  { "type": "object" }
        },
        "anyOf": [ { "required": ["value"] }, { "required": ["then"] } ]
      }
    }
  },
  "$defs": {
    "condition": {
      "type": "object",
      "properties": {
        "all":   { "type": "array", "items": { "$ref": "#/$defs/condition" } },
        "any":   { "type": "array", "items": { "$ref": "#/$defs/condition" } },
        "field": { "type": "string" },
        "op":    { "enum": ["eq", "ne", "gt", "gte", "lt", "lte", "between", "in", "notIn"] },
        "value": {}
      }
    }
  }
}
$json$::jsonb)
ON CONFLICT (schema_kind, schema_version) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Rule set templates (one per loan type)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.tpl_loan_rules(p_code text, p_rate numeric, p_method text, p_fee numeric)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
SELECT jsonb_build_object(
  'ruleSet', p_code, 'version', 1, 'schemaVersion', '1.0',
  'rules', jsonb_build_array(
    jsonb_build_object('code','INTEREST','value', jsonb_build_object('method', p_method, 'annualRatePercent', p_rate)),
    jsonb_build_object('code','AMOUNT_LIMITS','value', jsonb_build_object('min', 5000, 'max', 200000)),
    jsonb_build_object('code','TENURE_LIMITS','value', jsonb_build_object('minMonths', 6, 'maxMonths', 60)),
    jsonb_build_object('code','APPLICATION_FEE','value', jsonb_build_object('enabled', false, 'type', 'fixed', 'amount', p_fee,
                       'timing', 'BEFORE_SUBMISSION', 'waiverAllowed', true, 'refundable', false)),
    jsonb_build_object('code','NOMINEE','value', jsonb_build_object('firstLoan', true, 'thresholdAmount', null)),
    jsonb_build_object('code','GUARANTORS','value', jsonb_build_object('count', 0, 'aboveAmount', null)),
    jsonb_build_object('code','EARLY_SETTLEMENT','value', jsonb_build_object('enabled', true,
                       'interestPolicy', 'B_INTEREST_TO_DATE', 'charge', jsonb_build_object('type','none'),
                       'approvalRequired', true)),
    jsonb_build_object('code','OVERPAYMENT','value', jsonb_build_object('excessReducesPrincipal', true,
                       'regenerate', 'REDUCE_INSTALMENT', 'interestOnReducedPrincipal', true)),
    jsonb_build_object('code','LATE_FEE','value', jsonb_build_object('enabled', false, 'graceDays', 0, 'type', 'fixed',
                       'amount', 0, 'frequency', 'ONCE_PER_INSTALMENT', 'cap', null)),
    jsonb_build_object('code','DEFAULT_AFTER_MONTHS','value', 2),
    jsonb_build_object('code','DEFAULT_PENALTY',
                       'when', jsonb_build_object('all', jsonb_build_array(jsonb_build_object('field','loan.status','op','eq','value','DEFAULTED'))),
                       'then', jsonb_build_object('type','percent','of','outstandingPrincipal','value', 2)),
    jsonb_build_object('code','COOLING_OFF_AFTER_EARLY_SETTLEMENT','value', jsonb_build_object('enabled', false, 'months', 0)),
    jsonb_build_object('code','TRANCHES','value', jsonb_build_object('allowed', false, 'scheduleStartsFrom', 'FIRST_TRANCHE'))
  ))
$$;

INSERT INTO platform.config_template (template_kind, code, name, module_code, entity_type, description) VALUES
 ('RULESET','LOAN_TYPE_INTEREST_BEARING','Interest-Bearing Loan rules','LOAN','loan.loan','Flat interest, rule-driven'),
 ('RULESET','LOAN_TYPE_INTEREST_FREE','Interest-Free Loan rules','LOAN','loan.loan','0% interest'),
 ('RULESET','LOAN_TYPE_NORMAL','Normal Loan rules','LOAN','loan.loan','Rule-driven, as defined for this type')
ON CONFLICT (template_kind, code) DO NOTHING;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 1, 'PUBLISHED',
       CASE t.code WHEN 'LOAN_TYPE_INTEREST_BEARING' THEN platform.tpl_loan_rules(t.code, 12, 'FLAT', 200)
                   WHEN 'LOAN_TYPE_INTEREST_FREE'    THEN platform.tpl_loan_rules(t.code, 0, 'NONE', 100)
                   ELSE platform.tpl_loan_rules(t.code, 10, 'FLAT', 150) END,
       (SELECT id FROM platform.json_schema WHERE schema_kind = 'RULESET' AND schema_version = '1.0'),
       'Initial template (illustrative values from scope v1.7)', now()
  FROM platform.config_template t
 WHERE t.template_kind = 'RULESET' AND t.code LIKE 'LOAN_TYPE_%'
ON CONFLICT (template_id, version_no) DO NOTHING;

INSERT INTO platform.loan_type_template (code, name, description, interest_method, rule_template_code, sort_order) VALUES
 ('INTEREST_BEARING','Interest-Bearing Loan','Flat interest loan','FLAT','LOAN_TYPE_INTEREST_BEARING',1),
 ('INTEREST_FREE','Interest-Free Loan','0% interest loan','NONE','LOAN_TYPE_INTEREST_FREE',2),
 ('NORMAL','Normal Loan','Rule-driven loan','FLAT','LOAN_TYPE_NORMAL',3)
ON CONFLICT (code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Workflow templates
-- ----------------------------------------------------------------------------
-- Generic single-approver workflow: DRAFT -> [VERIFICATION] -> APPROVAL -> APPROVED,
-- with reject, return for correction and withdrawal.
CREATE OR REPLACE FUNCTION platform.tpl_approval_workflow(
    p_code text, p_creator_role text, p_approver_role text, p_verifier_role text DEFAULT NULL, p_notify_template text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS
$$
DECLARE
    v_stages jsonb;
    v_trans  jsonb;
    v_first  text := CASE WHEN p_verifier_role IS NULL THEN 'APPROVAL' ELSE 'VERIFICATION' END;
BEGIN
    v_stages := jsonb_build_array(
        jsonb_build_object('code','DRAFT','name','Draft','role',p_creator_role,
            'actions', jsonb_build_array(jsonb_build_object('seq',1,'action','GENERATE_REFERENCE','type','sync'))));
    v_trans := jsonb_build_array(
        jsonb_build_object('from','DRAFT','to',v_first,'on','SUBMIT'),
        jsonb_build_object('from','DRAFT','to','WITHDRAWN','on','WITHDRAW'));
    IF p_verifier_role IS NOT NULL THEN
        v_stages := v_stages || jsonb_build_object('code','VERIFICATION','name','Verification','role',p_verifier_role,
            'approval', jsonb_build_object('methods', jsonb_build_array('online','offline')),
            'actions', jsonb_build_array(jsonb_build_object('seq',1,'action','VALIDATE_APPROVAL_AUTHORITY','type','validation')));
        v_trans := v_trans
            || jsonb_build_object('from','VERIFICATION','to','APPROVAL','on','VERIFY')
            || jsonb_build_object('from','VERIFICATION','to','DRAFT','on','RETURN')
            || jsonb_build_object('from','VERIFICATION','to','REJECTED','on','REJECT')
            || jsonb_build_object('from','VERIFICATION','to','WITHDRAWN','on','WITHDRAW');
    END IF;
    v_stages := v_stages
        || jsonb_build_object('code','APPROVAL','name','Approval','role',p_approver_role,
              'approval', jsonb_build_object('methods', jsonb_build_array('online','offline')),
              'actions', jsonb_build_array(jsonb_build_object('seq',1,'action','VALIDATE_APPROVAL_AUTHORITY','type','validation')))
        || jsonb_build_object('code','APPROVED','name','Approved','end',true,
              'actions', CASE WHEN p_notify_template IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(
                  jsonb_build_object('seq',1,'action','SEND_NOTIFICATION','type','async','retry',3,
                                     'config', jsonb_build_object('channel','SMS','template',p_notify_template))) END)
        || jsonb_build_object('code','REJECTED','name','Rejected','end',true)
        || jsonb_build_object('code','WITHDRAWN','name','Withdrawn','end',true);
    v_trans := v_trans
        || jsonb_build_object('from','APPROVAL','to','APPROVED','on','APPROVE')
        || jsonb_build_object('from','APPROVAL','to','REJECTED','on','REJECT')
        || jsonb_build_object('from','APPROVAL','to','DRAFT','on','RETURN')
        || jsonb_build_object('from','APPROVAL','to','WITHDRAWN','on','WITHDRAW');
    RETURN jsonb_build_object('workflow', p_code, 'version', 1, 'schemaVersion', '1.0',
                              'startStage', 'DRAFT', 'stages', v_stages, 'transitions', v_trans);
END
$$;

INSERT INTO platform.config_template (template_kind, code, name, module_code, entity_type, description) VALUES
 ('WORKFLOW','LOAN_APPLICATION','Loan Application','LOAN','loan.loan','Application, fee, Manager approval, disbursement'),
 ('WORKFLOW','APPLICATION_FEE_WAIVER','Application Fee Waiver','LOAN_FEE','loan.loan_application_fee',NULL),
 ('WORKFLOW','EARLY_SETTLEMENT','Early Settlement','LOAN_SETTLE','loan.loan_settlement',NULL),
 ('WORKFLOW','DEFAULT_RECOVERY','Default and Recovery Settlement','LOAN_DEFAULT','loan.loan_settlement','Negotiated settlement with waiver'),
 ('WORKFLOW','LOAN_WRITE_OFF','Loan Write-off','LOAN_DEFAULT','loan.loan_write_off','Single approver: Leadership'),
 ('WORKFLOW','LOAN_RESTRUCTURE','Loan Restructuring','LOAN','loan.loan_restructure',NULL),
 ('WORKFLOW','COOLING_OFF_OVERRIDE','Cooling-off Override','LOAN_DEFAULT','loan.cooling_off_override',NULL),
 ('WORKFLOW','MEMBER_JOINING','Member Joining','MEMBER','mbr.member',NULL),
 ('WORKFLOW','EDUCATION_ASSISTANCE','Education Assistance','ASSIST_EDU','ops.assistance_application',NULL),
 ('WORKFLOW','CREMATION_ASSISTANCE','Cremation Assistance','ASSIST_CREM','ops.assistance_application',NULL),
 ('WORKFLOW','BIRTHDAY_GRANT','Birthday Grant','BDAY_GRANT','ops.birthday_grant','Leadership approves; a leader cannot approve own grant'),
 ('WORKFLOW','DAILY_EXPENSE','Daily Expense','EXPENSE','ops.expense',NULL),
 ('WORKFLOW','PAYROLL','Payroll','PAYROLL','ops.payroll_run','ACC prepares, MGR verifies, LDR approves'),
 ('WORKFLOW','HALL_BOOKING','Hall Booking','HALL','ops.hall_booking',NULL),
 ('WORKFLOW','ASSET_PURCHASE','Asset Purchase','ASSET_PURCHASE','ops.asset_purchase_request',NULL),
 ('WORKFLOW','MANUAL_JOURNAL','Manual Journal','JOURNAL','acct.journal','ACC creates, LDR approves')
ON CONFLICT (template_kind, code) DO NOTHING;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 1, 'PUBLISHED',
       CASE t.code
         WHEN 'LOAN_APPLICATION' THEN $json$
{
  "workflow": "LOAN_APPLICATION", "version": 1, "schemaVersion": "1.0", "startStage": "DRAFT",
  "stages": [
    { "code": "DRAFT", "name": "Application Created", "role": "EMP",
      "actions": [
        { "seq": 1, "action": "GENERATE_REFERENCE", "type": "sync" },
        { "seq": 2, "action": "VALIDATE_MEMBER_STATUS", "type": "validation" },
        { "seq": 3, "action": "VALIDATE_LOAN_ELIGIBILITY", "type": "validation",
          "config": { "checkDefaultHistory": true, "checkOutstandingLoans": true, "checkCoolingOff": true, "checkMemberStatus": true } },
        { "seq": 4, "action": "CALCULATE_APPLICATION_FEE", "type": "sync" } ] },
    { "code": "FEE_COLLECTION", "name": "Fee Collection", "role": "EMP",
      "actions": [
        { "seq": 1, "action": "GENERATE_RECEIPT", "type": "sync" },
        { "seq": 2, "action": "GENERATE_JOURNAL_ENTRY", "type": "sync", "config": { "journalTemplate": "APPLICATION_FEE" } },
        { "seq": 3, "action": "SEND_NOTIFICATION", "type": "async", "retry": 3, "config": { "channel": "SMS", "template": "LOAN_FEE_RECEIPT" } } ] },
    { "code": "MANAGER_APPROVAL", "name": "Manager Approval", "role": "MGR", "approval": { "methods": ["online", "offline"] },
      "actions": [
        { "seq": 1, "action": "VALIDATE_APPLICATION_FEE", "type": "validation" },
        { "seq": 2, "action": "VALIDATE_NOMINEE", "type": "validation" },
        { "seq": 3, "action": "VALIDATE_GUARANTORS", "type": "validation" },
        { "seq": 4, "action": "VALIDATE_LOAN_ELIGIBILITY", "type": "validation" },
        { "seq": 5, "action": "VALIDATE_APPROVAL_AUTHORITY", "type": "validation" } ] },
    { "code": "APPROVED", "name": "Approved", "role": "EMP",
      "actions": [
        { "seq": 1, "action": "CREATE_DISBURSEMENT_INSTRUCTION", "type": "sync" },
        { "seq": 2, "action": "SEND_NOTIFICATION", "type": "async", "retry": 3, "config": { "channel": "SMS", "template": "LOAN_APPROVED" } } ] },
    { "code": "DISBURSED", "name": "Disbursed", "end": true,
      "actions": [
        { "seq": 1, "action": "GENERATE_REPAYMENT_SCHEDULE", "type": "sync" },
        { "seq": 2, "action": "GENERATE_JOURNAL_ENTRY", "type": "sync", "config": { "journalTemplate": "LOAN_DISBURSEMENT" } },
        { "seq": 3, "action": "SEND_NOTIFICATION", "type": "async", "retry": 3, "config": { "channel": "SMS", "template": "LOAN_DISBURSED" } } ] },
    { "code": "REJECTED", "name": "Rejected", "end": true,
      "actions": [
        { "seq": 1, "action": "SEND_NOTIFICATION", "type": "async", "retry": 3, "config": { "channel": "SMS", "template": "LOAN_REJECTED" } } ] },
    { "code": "WITHDRAWN", "name": "Withdrawn", "end": true },
    { "code": "CANCELLED", "name": "Cancelled / Expired", "end": true }
  ],
  "transitions": [
    { "from": "DRAFT", "to": "FEE_COLLECTION", "on": "SUBMIT", "when": { "all": [ { "field": "fee.required", "op": "eq", "value": true } ] } },
    { "from": "DRAFT", "to": "MANAGER_APPROVAL", "on": "SUBMIT", "when": { "all": [ { "field": "fee.required", "op": "eq", "value": false } ] } },
    { "from": "DRAFT", "to": "WITHDRAWN", "on": "WITHDRAW" },
    { "from": "FEE_COLLECTION", "to": "MANAGER_APPROVAL", "on": "FEE_PAID" },
    { "from": "FEE_COLLECTION", "to": "WITHDRAWN", "on": "WITHDRAW" },
    { "from": "MANAGER_APPROVAL", "to": "APPROVED", "on": "APPROVE" },
    { "from": "MANAGER_APPROVAL", "to": "REJECTED", "on": "REJECT" },
    { "from": "MANAGER_APPROVAL", "to": "DRAFT", "on": "RETURN" },
    { "from": "MANAGER_APPROVAL", "to": "WITHDRAWN", "on": "WITHDRAW" },
    { "from": "APPROVED", "to": "DISBURSED", "on": "DISBURSE" },
    { "from": "APPROVED", "to": "CANCELLED", "on": "CANCEL" },
    { "from": "APPROVED", "to": "CANCELLED", "on": "EXPIRE" }
  ]
}
$json$::jsonb
         WHEN 'APPLICATION_FEE_WAIVER' THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'EARLY_SETTLEMENT'       THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR', NULL, 'LOAN_SETTLED')
         WHEN 'DEFAULT_RECOVERY'       THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'LOAN_WRITE_OFF'         THEN platform.tpl_approval_workflow(t.code, 'MGR', 'LDR')
         WHEN 'LOAN_RESTRUCTURE'       THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'COOLING_OFF_OVERRIDE'   THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'MEMBER_JOINING'         THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'EDUCATION_ASSISTANCE'   THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR', NULL, 'ASSISTANCE_APPROVED')
         WHEN 'CREMATION_ASSISTANCE'   THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'BIRTHDAY_GRANT'         THEN platform.tpl_approval_workflow(t.code, 'MGR', 'LDR')
         WHEN 'DAILY_EXPENSE'          THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'PAYROLL'                THEN platform.tpl_approval_workflow(t.code, 'ACC', 'LDR', 'MGR')
         WHEN 'HALL_BOOKING'           THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR', NULL, 'HALL_BOOKING_CONFIRMED')
         WHEN 'ASSET_PURCHASE'         THEN platform.tpl_approval_workflow(t.code, 'EMP', 'MGR')
         WHEN 'MANUAL_JOURNAL'         THEN platform.tpl_approval_workflow(t.code, 'ACC', 'LDR')
       END,
       (SELECT id FROM platform.json_schema WHERE schema_kind = 'WORKFLOW' AND schema_version = '1.0'),
       'Initial template (scope v1.7)', now()
  FROM platform.config_template t
 WHERE t.template_kind = 'WORKFLOW'
   AND t.code IN ('LOAN_APPLICATION','APPLICATION_FEE_WAIVER','EARLY_SETTLEMENT','DEFAULT_RECOVERY','LOAN_WRITE_OFF',
                  'LOAN_RESTRUCTURE','COOLING_OFF_OVERRIDE','MEMBER_JOINING','EDUCATION_ASSISTANCE','CREMATION_ASSISTANCE',
                  'BIRTHDAY_GRANT','DAILY_EXPENSE','PAYROLL','HALL_BOOKING','ASSET_PURCHASE','MANUAL_JOURNAL')
ON CONFLICT (template_id, version_no) DO NOTHING;

RESET app.reason;
RESET app.channel;
