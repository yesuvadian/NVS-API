-- =============================================================================
-- CFMS 43 - Platform template library: the remaining common data (idempotent)
--
-- Every new organisation is built only from platform tables. Before this script,
-- onboarding still had some defaults written into the provisioning function.
-- They are now platform templates the Super Administrator can maintain:
--   1  platform.account_mapping_template   posting account for each mapping key
--   2  platform.approval_policy_template   default single approver; role_template
--                                           .records_offline (who may record offline decisions)
--   3  platform.number_series_template     receipt / voucher / member ... numbering
--   4  platform.sod_rule                   incompatible role pairs (Section 3.5)
--   5  platform.lookup_template            more reference lists, and scheme / product
--                                           templates (assistance, deposits, chit)
--   6  platform.notification_template_default  messages for every module
--   7  platform.import_template            standard migration file layouts (Section 34)
--   8  platform.v_tenant_template_versions + platform.upgrade_tenant_template
--                                           (offer template upgrades, Section 35.4)
--   9  cfg.v_setting_differences           settings that differ from the template (4.10)
--  10  platform.apply_platform_defaults(tenant): brings an organisation up to date
--      with every template it is missing (safe to run any time)
-- The full list of template tables is in README.md ("Platform template library").
-- =============================================================================
SET app.channel TO 'MIGRATION';

-- =============================================================================
-- 1. Account mapping template
-- =============================================================================
CREATE TABLE IF NOT EXISTS platform.account_mapping_template (
    mapping_key   text PRIMARY KEY CHECK (mapping_key ~ '^[A-Z][A-Z0-9_]*$'),
    account_code  text NOT NULL,
    description   text NOT NULL,
    module_code   text REFERENCES platform.module (module_code),
    sort_order    integer NOT NULL DEFAULT 0,
    is_active     boolean NOT NULL DEFAULT true
);
INSERT INTO platform.account_mapping_template (mapping_key, account_code, description, module_code, sort_order) VALUES
 ('CASH','1110','Cash in hand',NULL,1),
 ('APPLICATION_FEE','4120','Loan application fee income','LOAN_FEE',10),
 ('LOAN_INTEREST','4110','Loan interest income','LOAN',11),
 ('LATE_FEE','4130','Late fee income','LOAN_REPAY',12),
 ('DEFAULT_PENALTY','4140','Default penalty income','LOAN_DEFAULT',13),
 ('BAD_DEBTS_RECOVERED','4150','Bad debts recovered','LOAN_DEFAULT',14),
 ('BAD_DEBTS_WRITTEN_OFF','5510','Bad debts written off','LOAN_DEFAULT',15),
 ('HALL_RENT','4210','Hall rental income','HALL',20),
 ('HALL_CHARGES','4220','Hall additional charges and damages','HALL',21),
 ('HALL_SECURITY_DEPOSIT','2110','Hall security deposits held','HALL',22),
 ('MEMBER_UNAPPLIED','2120','Member unapplied receipts',NULL,30),
 ('CONTRIBUTION','4310','Member contributions','CONTRIB',31),
 ('DONATION_UNRESTRICTED','4320','Unrestricted donations','GEN_FUND',32),
 ('EDUCATION_ASSISTANCE','5110','Education assistance','ASSIST_EDU',40),
 ('CREMATION_ASSISTANCE','5120','Cremation assistance','ASSIST_CREM',41),
 ('BIRTHDAY_GRANT','5130','Birthday grants','BDAY_GRANT',42),
 ('OTHER_ASSISTANCE','5140','Other community assistance',NULL,43),
 ('SALARY','5210','Salaries and allowances','PAYROLL',50),
 ('BONUS','5220','Bonus','PAYROLL',51),
 ('SALARY_ADVANCE','1320','Salary advances','PAYROLL',52),
 ('PETTY_CASH_ADVANCE','1310','Petty cash advances','EXPENSE',53),
 ('VENDOR_ADVANCE','1330','Advances to vendors','EXPENSE',54),
 ('CASH_SHORT_EXCESS','5540','Cash shortage / excess','CASH_RECON',60),
 ('ROUNDING_OFF','5550','Rounding off',NULL,61),
 ('GAIN_ON_DISPOSAL','4510','Gain on asset disposal','ASSET_DISPOSAL',70),
 ('LOSS_ON_DISPOSAL','5520','Loss on asset disposal','ASSET_DISPOSAL',71),
 ('DEPRECIATION','5530','Depreciation','ASSET',72),
 ('ACCUMULATED_DEPRECIATION','1490','Accumulated depreciation','ASSET',73),
 ('GENERAL_FUND','3100','General Community Fund (year-end surplus)',NULL,80),
 ('CORPUS_FUND','3400','Corpus fund',NULL,81),
 ('OTHER_INCOME','4900','Other income',NULL,82),
 ('DEPOSIT_RD','2210','Recurring deposits held','DEPOSIT',90),
 ('DEPOSIT_FD','2220','Fixed deposits held','DEPOSIT',91),
 ('DEPOSIT_INTEREST','5410','Interest on member deposits','DEPOSIT',92),
 ('FOREMAN_COMMISSION','4410','Foreman commission income','CHIT',95),
 ('CHIT_LATE_FEE','4420','Chit late fee income','CHIT',96)
ON CONFLICT (mapping_key) DO NOTHING;

-- =============================================================================
-- 2. Approval policy template and offline recorders
-- =============================================================================
CREATE TABLE IF NOT EXISTS platform.approval_policy_template (
    code               text PRIMARY KEY CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    name               text NOT NULL,
    approver_role_code text NOT NULL REFERENCES platform.role_template (role_code),
    module_code        text REFERENCES platform.module (module_code),
    workflow_code      text,
    stage_code         text,
    allow_online       boolean NOT NULL DEFAULT true,
    allow_offline      boolean NOT NULL DEFAULT true,
    require_distinct_identities boolean NOT NULL DEFAULT true,
    require_verification boolean NOT NULL DEFAULT false,
    is_active          boolean NOT NULL DEFAULT true
);
INSERT INTO platform.approval_policy_template (code, name, approver_role_code) VALUES
 ('DEFAULT','Single approver - Manager','MGR')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE platform.role_template ADD COLUMN IF NOT EXISTS records_offline boolean NOT NULL DEFAULT false;
UPDATE platform.role_template SET records_offline = true WHERE role_code IN ('EMP','MGR') AND NOT records_offline;

-- =============================================================================
-- 3. Number series template
-- =============================================================================
CREATE TABLE IF NOT EXISTS platform.number_series_template (
    series_code    text PRIMARY KEY CHECK (series_code ~ '^[A-Z][A-Z0-9_]*$'),
    name           text NOT NULL,
    prefix_pattern text NOT NULL,          -- {FY} is replaced by the financial year code, e.g. 2026-27
    yearly_reset   boolean NOT NULL DEFAULT false,
    pad_length     integer NOT NULL DEFAULT 5 CHECK (pad_length BETWEEN 1 AND 12),
    is_active      boolean NOT NULL DEFAULT true
);
INSERT INTO platform.number_series_template (series_code, name, prefix_pattern, yearly_reset, pad_length) VALUES
 ('RECEIPT','Cash receipt','REC/{FY}/',true,5),
 ('PAYMENT','Payment voucher','PAY/{FY}/',true,5),
 ('JOURNAL','Journal voucher','JOU/{FY}/',true,5),
 ('CONTRA','Contra voucher','CON/{FY}/',true,5),
 ('ADJUSTMENT','Adjustment voucher','ADJ/{FY}/',true,5),
 ('MEMBER','Member number','MEM-',false,5),
 ('LOAN','Loan number','LN/{FY}/',true,5),
 ('BOOKING','Hall booking','HB/{FY}/',true,4),
 ('ASSISTANCE','Assistance application','AS/{FY}/',true,4),
 ('EXPENSE','Expense','EX/{FY}/',true,5),
 ('APPROVAL','Approval request','APR/{FY}/',true,5),
 ('ASSET','Asset tag','AST-',false,5),
 ('DEPOSIT','Deposit account','DEP-',false,6),
 ('CHIT_GROUP','Chit group','CG-',false,4),
 ('CLAIM','Deposit claim','CLM/{FY}/',true,4),
 ('PAYROLL','Payroll run','PR/{FY}/',true,3)
ON CONFLICT (series_code) DO NOTHING;

-- Next number in a series: prefix, reset and padding come from the template
-- (unknown series fall back to the first three letters). Gapless because the
-- series row stays locked until commit.
CREATE OR REPLACE FUNCTION acct.next_number(p_series_code text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS
$$
DECLARE
    v_tenant uuid := coalesce(p_tenant_id, app.tenant_id());
    v_fy     acct.financial_year%ROWTYPE;
    t        platform.number_series_template%ROWTYPE;
    v_no     bigint;
    v_prefix text;
    v_pad    integer;
    v_yearly boolean;
BEGIN
    SELECT * INTO t FROM platform.number_series_template WHERE series_code = p_series_code AND is_active;
    v_yearly := coalesce(t.yearly_reset, p_series_code IN ('RECEIPT','PAYMENT','JOURNAL','CONTRA','ADJUSTMENT'));
    IF v_yearly THEN
        SELECT * INTO v_fy FROM acct.financial_year
         WHERE tenant_id = v_tenant AND coalesce(p_on, app.working_date()) BETWEEN start_date AND end_date;
        IF NOT FOUND THEN
            PERFORM app.fail('NO_FINANCIAL_YEAR', 'No financial year covers the date');
        END IF;
        INSERT INTO acct.voucher_series (tenant_id, series_code, financial_year_id, prefix, pad_length)
        VALUES (v_tenant, p_series_code, v_fy.id,
                replace(coalesce(t.prefix_pattern, left(p_series_code, 3) || '/{FY}/'), '{FY}', v_fy.code),
                coalesce(t.pad_length, 5))
        ON CONFLICT DO NOTHING;
    ELSE
        INSERT INTO acct.voucher_series (tenant_id, series_code, financial_year_id, prefix, pad_length)
        VALUES (v_tenant, p_series_code, NULL, coalesce(t.prefix_pattern, left(p_series_code, 3) || '-'),
                coalesce(t.pad_length, 5))
        ON CONFLICT DO NOTHING;
    END IF;

    UPDATE acct.voucher_series s
       SET next_no = s.next_no + 1
     WHERE s.tenant_id = v_tenant AND s.series_code = p_series_code
       AND s.financial_year_id IS NOT DISTINCT FROM (CASE WHEN v_yearly THEN v_fy.id END)
    RETURNING s.next_no - 1, s.prefix, s.pad_length INTO v_no, v_prefix, v_pad;

    RETURN v_prefix || lpad(v_no::text, v_pad, '0');
END
$$;

-- =============================================================================
-- 4. Segregation of duties: incompatible role pairs (Section 3.5). A user may
--    hold both only with an approved iam.sod_exception.
-- =============================================================================
INSERT INTO platform.sod_rule (role_code_a, role_code_b, description) VALUES
 ('ADM','EMP','The administrator cannot create financial transactions'),
 ('ADM','MGR','The administrator cannot approve financial transactions'),
 ('ADM','ACC','The administrator cannot post or reconcile financial transactions'),
 ('ADM','LDR','Administrator changes need Leadership approval, so one person cannot hold both')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- 5. More reference lists, and scheme / product templates
-- =============================================================================
INSERT INTO platform.lookup_template (lookup_type, code, name, attributes, sort_order) VALUES
 -- reasons used across the application
 ('EXIT_REASON','RESIGNED','Resigned','{}',1), ('EXIT_REASON','RELOCATED','Relocated','{}',2),
 ('EXIT_REASON','EXPELLED','Expelled','{}',3), ('EXIT_REASON','DECEASED','Deceased','{}',4), ('EXIT_REASON','OTHER','Other','{}',99),
 ('SUSPENSION_REASON','NON_PAYMENT','Non-payment of dues','{}',1), ('SUSPENSION_REASON','LOAN_DEFAULT','Loan default','{}',2),
 ('SUSPENSION_REASON','MISCONDUCT','Misconduct','{}',3), ('SUSPENSION_REASON','OTHER','Other','{}',99),
 ('REJECTION_REASON','NOT_ELIGIBLE','Not eligible','{}',1), ('REJECTION_REASON','INCOMPLETE_DOCUMENTS','Incomplete documents','{}',2),
 ('REJECTION_REASON','INSUFFICIENT_FUNDS','Insufficient funds','{}',3), ('REJECTION_REASON','POLICY','Against policy','{}',4),
 ('REJECTION_REASON','OTHER','Other','{}',99),
 ('RETURN_REASON','CORRECTION_NEEDED','Correction needed','{}',1), ('RETURN_REASON','MISSING_DOCUMENT','Missing document','{}',2),
 ('RETURN_REASON','CLARIFICATION','Clarification needed','{}',3), ('RETURN_REASON','OTHER','Other','{}',99),
 ('CANCEL_REASON','ENTERED_IN_ERROR','Entered in error','{}',1), ('CANCEL_REASON','DUPLICATE','Duplicate','{}',2),
 ('CANCEL_REASON','CUSTOMER_REQUEST','Requested by member or customer','{}',3), ('CANCEL_REASON','OTHER','Other','{}',99),
 ('WAIVER_REASON','HARDSHIP','Financial hardship','{}',1), ('WAIVER_REASON','DEATH','Death of member','{}',2),
 ('WAIVER_REASON','GOODWILL','Goodwill / community decision','{}',3), ('WAIVER_REASON','OTHER','Other','{}',99),
 ('REVERSAL_REASON','WRONG_AMOUNT','Wrong amount','{}',1), ('REVERSAL_REASON','WRONG_MEMBER','Wrong member','{}',2),
 ('REVERSAL_REASON','WRONG_ACCOUNT','Wrong account','{}',3), ('REVERSAL_REASON','DUPLICATE','Duplicate','{}',4), ('REVERSAL_REASON','OTHER','Other','{}',99),
 ('LOAN_PURPOSE','EDUCATION','Education','{}',1), ('LOAN_PURPOSE','MEDICAL','Medical','{}',2), ('LOAN_PURPOSE','MARRIAGE','Marriage','{}',3),
 ('LOAN_PURPOSE','HOUSING','House repair / construction','{}',4), ('LOAN_PURPOSE','BUSINESS','Small business','{}',5),
 ('LOAN_PURPOSE','AGRICULTURE','Agriculture','{}',6), ('LOAN_PURPOSE','EMERGENCY','Emergency','{}',7), ('LOAN_PURPOSE','OTHER','Other','{}',99),
 ('RECOVERY_ACTION','CALL','Phone call','{}',1), ('RECOVERY_ACTION','VISIT','Home visit','{}',2), ('RECOVERY_ACTION','LETTER','Letter / notice','{}',3),
 ('RECOVERY_ACTION','GUARANTOR_CONTACT','Guarantor contacted','{}',4), ('RECOVERY_ACTION','MEETING','Meeting','{}',5),
 ('RECOVERY_ACTION','PROMISE_TO_PAY','Promise to pay','{}',6),
 ('DESIGNATION','OFFICE_ASSISTANT','Office assistant','{}',1), ('DESIGNATION','CASHIER','Cashier','{}',2),
 ('DESIGNATION','ACCOUNTANT','Accountant','{}',3), ('DESIGNATION','MANAGER','Manager','{}',4), ('DESIGNATION','CARETAKER','Caretaker','{}',5),
 ('DESIGNATION','SECURITY','Security','{}',6), ('DESIGNATION','CLEANER','Cleaner','{}',7), ('DESIGNATION','OTHER','Other','{}',99),
 ('DEPARTMENT','ADMINISTRATION','Administration','{}',1), ('DEPARTMENT','ACCOUNTS','Accounts','{}',2),
 ('DEPARTMENT','HALL','Hall','{}',3), ('DEPARTMENT','MAINTENANCE','Maintenance','{}',4),
 ('VENDOR_CATEGORY','SUPPLIES','Office supplies','{}',1), ('VENDOR_CATEGORY','UTILITIES','Utilities','{}',2),
 ('VENDOR_CATEGORY','MAINTENANCE','Maintenance and repairs','{}',3), ('VENDOR_CATEGORY','CATERING','Catering','{}',4),
 ('VENDOR_CATEGORY','DECORATION','Decoration','{}',5), ('VENDOR_CATEGORY','EQUIPMENT','Equipment','{}',6), ('VENDOR_CATEGORY','OTHER','Other','{}',99),
 ('DONATION_PURPOSE','GENERAL','General','{}',1), ('DONATION_PURPOSE','EDUCATION','Education','{}',2),
 ('DONATION_PURPOSE','MEDICAL','Medical','{}',3), ('DONATION_PURPOSE','FESTIVAL','Festival / event','{}',4),
 ('DONATION_PURPOSE','BUILDING','Building / corpus','{}',5), ('DONATION_PURPOSE','OTHER','Other','{}',99),
 ('GENDER','MALE','Male','{}',1), ('GENDER','FEMALE','Female','{}',2), ('GENDER','OTHER','Other','{}',3),
 ('LANGUAGE','en','English','{}',1), ('LANGUAGE','ta','Tamil','{}',2), ('LANGUAGE','hi','Hindi','{}',3),
 ('LANGUAGE','te','Telugu','{}',4), ('LANGUAGE','kn','Kannada','{}',5), ('LANGUAGE','ml','Malayalam','{}',6),
 ('EDUCATION_LEVEL','SCHOOL','School','{}',1), ('EDUCATION_LEVEL','HIGHER_SECONDARY','Higher secondary','{}',2),
 ('EDUCATION_LEVEL','DIPLOMA','Diploma','{}',3), ('EDUCATION_LEVEL','UNDERGRADUATE','Undergraduate','{}',4),
 ('EDUCATION_LEVEL','POSTGRADUATE','Postgraduate','{}',5), ('EDUCATION_LEVEL','PROFESSIONAL','Professional course','{}',6),
 ('DOCUMENT_TYPE','MARKSHEET','Marksheet','{}',11), ('DOCUMENT_TYPE','NOMINATION_FORM','Nomination form','{}',12),
 ('DOCUMENT_TYPE','GUARANTOR_FORM','Guarantor form','{}',13), ('DOCUMENT_TYPE','LEGAL_HEIR_CERTIFICATE','Legal heir certificate','{}',14),
 ('DOCUMENT_TYPE','AGREEMENT','Agreement','{}',15), ('DOCUMENT_TYPE','REGISTRATION_CERTIFICATE','Registration certificate','{}',16),
 -- scheme and product templates (cloned into the organisation's own tables when the module is on)
 ('ASSISTANCE_SCHEME','EDUCATION','Education Assistance',
  '{"assistance_type":"EDUCATION","module_code":"ASSIST_EDU","default_amount":5000,"account_code":"5110","rule_set":"ASSISTANCE","required_documents":["ADMISSION_PROOF","FEE_RECEIPT","MARKSHEET"]}',1),
 ('ASSISTANCE_SCHEME','CREMATION','Cremation Assistance',
  '{"assistance_type":"CREMATION","module_code":"ASSIST_CREM","default_amount":10000,"account_code":"5120","rule_set":"ASSISTANCE","required_documents":["DEATH_CERTIFICATE"]}',2),
 ('ASSISTANCE_SCHEME','BIRTHDAY_GRANT','Birthday Grant',
  '{"assistance_type":"BIRTHDAY_GRANT","module_code":"BDAY_GRANT","default_amount":1000,"account_code":"5130","required_documents":[]}',3),
 ('DEPOSIT_PRODUCT','RD_STANDARD','Recurring Deposit (standard)',
  '{"product_type":"RD","min_amount":100,"max_amount":10000,"min_tenure_months":12,"max_tenure_months":60,"interest_method":"COMPOUND","compounding_frequency":"QUARTERLY","payout_frequency":"AT_MATURITY","premature_allowed":true,"lock_in_months":6,"premature_rate_reduction":1,"rd_grace_days":7,"rd_max_missed":3,"liability_account_code":"2210","interest_account_code":"5410"}',1),
 ('DEPOSIT_PRODUCT','FD_STANDARD','Fixed Deposit (standard)',
  '{"product_type":"FD","min_amount":1000,"max_amount":500000,"min_tenure_months":6,"max_tenure_months":60,"interest_method":"SIMPLE","payout_frequency":"AT_MATURITY","premature_allowed":true,"lock_in_months":3,"premature_rate_reduction":1,"liability_account_code":"2220","interest_account_code":"5410"}',2),
 ('CHIT_SCHEME','CHIT_20X5000','Chit 20 members x Rs 5,000',
  '{"duration_months":20,"member_count":20,"subscription_amount":5000,"payout_method":"AUCTION","max_discount_pct":30,"foreman_commission_pct":5,"dividend_treatment":"DEDUCT_NEXT","auction_day":10,"late_rules":{"graceDays":5,"lateFee":50,"missedBeforeDefault":2},"eligibility":{"maxTicketsPerMember":2}}',1)
ON CONFLICT (lookup_type, code) DO NOTHING;

-- =============================================================================
-- 6. Notification templates for the other modules
-- =============================================================================
INSERT INTO platform.notification_template_default (code, channel, language_code, name, subject, body, module_code, is_essential) VALUES
 ('MEMBER_WELCOME','SMS','en','Member welcome',NULL,'Dear {{member_name}}, welcome to {{org_name}}. Your member number is {{member_no}}.','MEMBER',true),
 ('MEMBER_STATUS_CHANGED','SMS','en','Member status changed',NULL,'Dear {{member_name}}, your membership status is now {{status}}. - {{org_name}}','MEMBER',true),
 ('CASH_RECEIPT','SMS','en','Cash receipt',NULL,'Received Rs {{amount}} towards {{purpose}}. Receipt {{receipt_no}} dated {{date}}. - {{org_name}}','GL',true),
 ('RECEIPT_CANCELLED','SMS','en','Receipt cancelled',NULL,'Receipt {{receipt_no}} for Rs {{amount}} has been cancelled. Reason: {{reason}}. - {{org_name}}','GL',true),
 ('GUARANTOR_NOTICE','SMS','en','Guarantor notice',NULL,'Dear {{member_name}}, you are a guarantor for loan {{loan_no}} of {{borrower_name}}, which is overdue. - {{org_name}}','LOAN_DEFAULT',true),
 ('SETTLEMENT_QUOTE','SMS','en','Settlement quote',NULL,'Loan {{loan_no}}: amount to settle Rs {{amount}}, valid until {{valid_until}}. - {{org_name}}','LOAN_SETTLE',false),
 ('CONTRIBUTION_DUE','SMS','en','Contribution due',NULL,'Dear {{member_name}}, your {{scheme_name}} contribution of Rs {{amount}} is due on {{due_date}}. - {{org_name}}','CONTRIB',false),
 ('CONTRIBUTION_OVERDUE','SMS','en','Contribution overdue',NULL,'Dear {{member_name}}, your {{scheme_name}} contribution of Rs {{amount}} is overdue. - {{org_name}}','CONTRIB',false),
 ('DONATION_THANKS','SMS','en','Donation thank you',NULL,'Thank you for your donation of Rs {{amount}}. Receipt {{receipt_no}}. - {{org_name}}','GEN_FUND',false),
 ('ASSISTANCE_REJECTED','SMS','en','Assistance not approved',NULL,'Dear {{member_name}}, your {{scheme_name}} application {{application_no}} was not approved. - {{org_name}}','ASSIST_EDU',true),
 ('ASSISTANCE_PAID','SMS','en','Assistance paid',NULL,'Dear {{member_name}}, Rs {{amount}} paid for {{scheme_name}} application {{application_no}}. - {{org_name}}','ASSIST_EDU',true),
 ('BIRTHDAY_GREETING','SMS','en','Birthday greeting',NULL,'Happy birthday {{member_name}}! Best wishes from {{org_name}}.','BDAY_GRANT',false),
 ('HALL_BOOKING_TENTATIVE','SMS','en','Hall booking held',NULL,'Booking {{booking_no}} for {{hall_name}} on {{event_date}} is held until {{hold_until}}. Pay to confirm. - {{org_name}}','HALL',true),
 ('HALL_BOOKING_CANCELLED','SMS','en','Hall booking cancelled',NULL,'Booking {{booking_no}} for {{event_date}} is cancelled. Refund Rs {{refund_amount}}. - {{org_name}}','HALL',true),
 ('HALL_DEPOSIT_REFUNDED','SMS','en','Hall deposit settled',NULL,'Security deposit for booking {{booking_no}} settled: refund Rs {{refund_amount}}, deductions Rs {{deductions}}. - {{org_name}}','HALL',true),
 ('DEPOSIT_OPENED','SMS','en','Deposit opened',NULL,'Dear {{member_name}}, deposit {{account_no}} opened for Rs {{amount}}, matures on {{maturity_date}}. - {{org_name}}','DEPOSIT',true),
 ('DEPOSIT_INSTALMENT_DUE','SMS','en','RD instalment due',NULL,'Dear {{member_name}}, RD {{account_no}} instalment of Rs {{amount}} is due on {{due_date}}. - {{org_name}}','DEPOSIT',false),
 ('DEPOSIT_MATURITY','SMS','en','Deposit maturity',NULL,'Dear {{member_name}}, deposit {{account_no}} matures on {{maturity_date}} for Rs {{amount}}. - {{org_name}}','DEPOSIT',true),
 ('DEPOSIT_CLOSED','SMS','en','Deposit closed',NULL,'Deposit {{account_no}} closed. Rs {{amount}} paid. - {{org_name}}','DEPOSIT',true),
 ('CHIT_INSTALMENT_DUE','SMS','en','Chit instalment due',NULL,'Chit {{group_code}} ticket {{ticket_no}}: Rs {{amount}} due on {{due_date}}. - {{org_name}}','CHIT',false),
 ('CHIT_AUCTION_NOTICE','SMS','en','Chit auction notice',NULL,'Chit {{group_code}} auction for month {{month_no}} is on {{auction_date}}. - {{org_name}}','CHIT',false),
 ('CHIT_PRIZE_PAID','SMS','en','Chit prize paid',NULL,'Chit {{group_code}} ticket {{ticket_no}}: prize of Rs {{amount}} paid. - {{org_name}}','CHIT',true),
 ('APPROVAL_PENDING','INAPP','en','Approval pending',NULL,'{{entity_label}} {{business_ref}} is waiting for your approval.','APPROVAL',true),
 ('APPROVAL_DECIDED','INAPP','en','Approval decided',NULL,'{{entity_label}} {{business_ref}} was {{decision}} by {{approver}}.','APPROVAL',true),
 ('TASK_REASSIGNED','INAPP','en','Task reassigned',NULL,'{{task_count}} task(s) were reassigned to you by {{by_user}}.','APPROVAL',true),
 ('PERIOD_CLOSED','INAPP','en','Accounting period closed',NULL,'Accounting period {{period_name}} was closed by {{by_user}}.','FIN_PERIOD',false),
 ('ACCESS_CHANGE_PENDING','INAPP','en','Access change pending',NULL,'An access change ({{change_type}}) requested by {{by_user}} needs your approval.','USER_ROLE',true)
ON CONFLICT DO NOTHING;

-- =============================================================================
-- 7. Standard import templates (Section 34, data migration)
-- =============================================================================
CREATE TABLE IF NOT EXISTS platform.import_template (
    code          text PRIMARY KEY CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    name          text NOT NULL,
    target_entity text NOT NULL,
    module_code   text REFERENCES platform.module (module_code),
    columns       jsonb NOT NULL CHECK (jsonb_typeof(columns) = 'array'),
    notes         text,
    sort_order    integer NOT NULL DEFAULT 0,
    version_no    integer NOT NULL DEFAULT 1,
    is_active     boolean NOT NULL DEFAULT true
);
INSERT INTO platform.import_template (code, name, target_entity, module_code, columns, notes, sort_order) VALUES
 ('MEMBERS','Members','mbr.member','MEMBER', $j$[
  {"name":"legacy_ref","type":"text","required":true},{"name":"member_no","type":"text","required":false},
  {"name":"full_name","type":"text","required":true},{"name":"date_of_birth","type":"date"},{"name":"gender","type":"lookup:GENDER"},
  {"name":"mobile","type":"text","required":true},{"name":"email","type":"text"},{"name":"address_line1","type":"text"},
  {"name":"city","type":"text"},{"name":"pincode","type":"text"},{"name":"membership_date","type":"date","required":true},
  {"name":"status","type":"enum:ACTIVE,SUSPENDED,EXITED,DECEASED","required":true}]$j$, 'Duplicate check on mobile and ID number runs before import', 1),
 ('NOMINEES','Nominees','mbr.nominee','NOMINEE', $j$[
  {"name":"member_legacy_ref","type":"text","required":true},{"name":"full_name","type":"text","required":true},
  {"name":"relationship","type":"lookup:RELATIONSHIP","required":true},{"name":"share_percent","type":"number"},
  {"name":"mobile","type":"text"},{"name":"date_of_birth","type":"date"}]$j$, NULL, 2),
 ('LOANS','Loans part-way through repayment','loan.loan','LOAN', $j$[
  {"name":"legacy_ref","type":"text","required":true},{"name":"member_legacy_ref","type":"text","required":true},
  {"name":"loan_type","type":"text","required":true},{"name":"disbursed_on","type":"date","required":true},
  {"name":"approved_amount","type":"number","required":true},{"name":"tenure_months","type":"integer","required":true},
  {"name":"interest_rate_annual","type":"number","required":true},{"name":"outstanding_principal","type":"number","required":true},
  {"name":"outstanding_interest","type":"number"},{"name":"next_due_date","type":"date"},{"name":"status","type":"enum:ACTIVE,OVERDUE,DEFAULTED"}]$j$,
  'Imported as migrated loans (loan.is_migrated); balances are reconciled against the opening trial balance', 3),
 ('REPAYMENT_HISTORY','Repayment history','loan.loan_repayment','LOAN_REPAY', $j$[
  {"name":"legacy_ref","type":"text","required":true},{"name":"loan_legacy_ref","type":"text","required":true},
  {"name":"value_date","type":"date","required":true},{"name":"amount","type":"number","required":true},
  {"name":"principal_amount","type":"number"},{"name":"interest_amount","type":"number"},{"name":"receipt_ref","type":"text"}]$j$, NULL, 4),
 ('OPENING_BALANCES','Opening balances (trial balance)','acct.journal','GL', $j$[
  {"name":"account_code","type":"text","required":true},{"name":"fund_code","type":"text"},
  {"name":"debit","type":"number"},{"name":"credit","type":"number"},{"name":"as_of_date","type":"date","required":true}]$j$,
  'Posted as one OPENING journal; total debit must equal total credit', 5),
 ('ASSETS','Assets register','ops.asset','ASSET', $j$[
  {"name":"legacy_ref","type":"text","required":true},{"name":"asset_name","type":"text","required":true},
  {"name":"category","type":"lookup:ASSET_CATEGORY","required":true},{"name":"purchase_date","type":"date"},
  {"name":"cost","type":"number","required":true},{"name":"accumulated_depreciation","type":"number"},{"name":"location","type":"text"}]$j$, NULL, 6),
 ('EMPLOYEES','Employees','ops.employee','PAYROLL', $j$[
  {"name":"legacy_ref","type":"text","required":true},{"name":"employee_code","type":"text","required":true},
  {"name":"full_name","type":"text","required":true},{"name":"joining_date","type":"date","required":true},
  {"name":"designation","type":"lookup:DESIGNATION"},{"name":"mobile","type":"text"},{"name":"basic_salary","type":"number"}]$j$, NULL, 7),
 ('HALL_BOOKINGS','Future hall bookings','ops.hall_booking','HALL', $j$[
  {"name":"legacy_ref","type":"text","required":true},{"name":"hall_code","type":"text","required":true},
  {"name":"event_date","type":"date","required":true},{"name":"customer_name","type":"text","required":true},
  {"name":"member_legacy_ref","type":"text"},{"name":"rent_amount","type":"number","required":true},
  {"name":"deposit_amount","type":"number"},{"name":"amount_paid","type":"number"}]$j$, NULL, 8)
ON CONFLICT (code) DO NOTHING;

-- touch and platform audit triggers for the new template tables (as script 20 does)
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['platform.account_mapping_template','platform.approval_policy_template',
                             'platform.number_series_template','platform.import_template'] LOOP
        PERFORM app.attach_standard_triggers(t::regclass, true);
    END LOOP;
END $$;

-- =============================================================================
-- 8. Template versions per organisation, and upgrade offers (Section 35.4)
-- =============================================================================
CREATE OR REPLACE VIEW platform.v_tenant_template_versions AS
WITH latest AS (
    SELECT t.id AS template_id, t.template_kind, t.code, max(v.version_no) AS latest_version
      FROM platform.config_template t
      JOIN platform.config_template_version v ON v.template_id = t.id AND v.status = 'PUBLISHED'
     GROUP BY t.id, t.template_kind, t.code)
SELECT d.tenant_id, 'WORKFLOW'::text AS template_kind, d.code, d.template_version AS tenant_template_version,
       l.latest_version, d.template_version < l.latest_version AS upgrade_available
  FROM cfg.workflow_definition d JOIN latest l ON l.template_id = d.template_id
UNION ALL
SELECT r.tenant_id, 'RULESET', r.code, r.template_version, l.latest_version, r.template_version < l.latest_version
  FROM cfg.rule_set r JOIN latest l ON l.template_id = r.template_id;

-- Creates a DRAFT version of the organisation's workflow or rule set from the
-- latest published template. The Super Administrator reviews and publishes it;
-- transactions already in flight keep their original version.
CREATE OR REPLACE FUNCTION platform.upgrade_tenant_template(
    p_tenant_id uuid, p_kind text, p_code text, p_reason text, p_platform_user_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    tv     record;
    v_def  uuid;
    v_next integer;
    v_new  uuid;
BEGIN
    IF coalesce(p_reason, '') = '' THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required for a template upgrade');
    END IF;
    SELECT v.* INTO tv
      FROM platform.config_template t
      JOIN platform.config_template_version v ON v.template_id = t.id AND v.status = 'PUBLISHED'
     WHERE t.template_kind = p_kind AND t.code = p_code
     ORDER BY v.version_no DESC LIMIT 1;
    IF NOT FOUND THEN
        PERFORM app.fail('NOT_FOUND', format('No published %s template %s', p_kind, p_code));
    END IF;
    IF p_kind = 'WORKFLOW' THEN
        SELECT id INTO v_def FROM cfg.workflow_definition WHERE tenant_id = p_tenant_id AND code = p_code;
        IF v_def IS NULL THEN PERFORM app.fail('NOT_FOUND', 'The organisation has no workflow ' || p_code); END IF;
        SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.workflow_version
         WHERE tenant_id = p_tenant_id AND workflow_definition_id = v_def;
        INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition, json_schema_id,
                                          effective_from, reason, source, source_template_version_id)
        VALUES (p_tenant_id, v_def, v_next, 'DRAFT', tv.definition, tv.json_schema_id, current_date,
                p_reason, 'TEMPLATE_UPGRADE', tv.id)
        RETURNING id INTO v_new;
    ELSIF p_kind = 'RULESET' THEN
        SELECT id INTO v_def FROM cfg.rule_set WHERE tenant_id = p_tenant_id AND code = p_code;
        IF v_def IS NULL THEN PERFORM app.fail('NOT_FOUND', 'The organisation has no rule set ' || p_code); END IF;
        SELECT coalesce(max(version_no), 0) + 1 INTO v_next FROM cfg.rule_set_version
         WHERE tenant_id = p_tenant_id AND rule_set_id = v_def;
        INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                          effective_from, reason, source, source_template_version_id)
        VALUES (p_tenant_id, v_def, v_next, 'DRAFT', tv.definition, tv.json_schema_id, current_date,
                p_reason, 'TEMPLATE_UPGRADE', tv.id)
        RETURNING id INTO v_new;
    ELSE
        PERFORM app.fail('BAD_KIND', 'Template kind must be WORKFLOW or RULESET');
    END IF;
    RETURN v_new;
END
$$;

-- =============================================================================
-- 9. Settings that differ from the platform default (Section 4.10)
-- =============================================================================
CREATE OR REPLACE VIEW cfg.v_setting_differences AS
WITH tpl AS (
    SELECT i.setting_key, i.value
      FROM platform.settings_template_item i
     WHERE i.version_no = (SELECT max(version_no) FROM platform.settings_template WHERE status = 'PUBLISHED')),
cur AS (
    SELECT DISTINCT ON (s.tenant_id, s.setting_key) s.tenant_id, s.setting_key, s.value, s.effective_from, s.source
      FROM cfg.tenant_setting s
     WHERE s.status = 'ACTIVE' AND s.effective_from <= current_date
     ORDER BY s.tenant_id, s.setting_key, s.effective_from DESC, s.created_at DESC)
SELECT c.tenant_id, c.setting_key, d.area, d.name, c.value AS organisation_value, t.value AS default_value,
       c.effective_from, c.source
  FROM cur c
  JOIN platform.setting_definition d ON d.setting_key = c.setting_key
  LEFT JOIN tpl t ON t.setting_key = c.setting_key
 WHERE t.value IS DISTINCT FROM c.value;

-- =============================================================================
-- 10. Bring an organisation up to date with the template library
-- =============================================================================
-- Adds only what is missing: never changes or removes what the organisation has.
-- Run at onboarding, when a module is switched on, and after new templates are
-- published. Returns the number of rows added.
CREATE OR REPLACE FUNCTION platform.apply_platform_defaults(p_tenant_id uuid)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_n   integer := 0;
    v_c   integer;
    c_tenant text := current_setting('app.tenant_id', true);
BEGIN
    -- act inside the organisation (row-level security), restored at the end
    PERFORM set_config('app.tenant_id', p_tenant_id::text, true);
    -- account mappings whose account exists in the organisation's chart
    INSERT INTO acct.account_mapping (tenant_id, mapping_key, account_id)
    SELECT p_tenant_id, m.mapping_key, a.id
      FROM platform.account_mapping_template m
      JOIN acct.account a ON a.tenant_id = p_tenant_id AND a.code = m.account_code
     WHERE m.is_active
       AND NOT EXISTS (SELECT 1 FROM acct.account_mapping x
                        WHERE x.tenant_id = p_tenant_id AND x.mapping_key = m.mapping_key AND x.scope_type = 'NONE');
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    -- general reference lists (types with their own tables are handled by onboarding)
    INSERT INTO core.lookup_value (tenant_id, lookup_type, code, name, attributes, sort_order)
    SELECT p_tenant_id, l.lookup_type, l.code, l.name, l.attributes, l.sort_order
      FROM platform.lookup_template l
     WHERE l.is_active
       AND l.lookup_type NOT IN ('EXPENSE_CATEGORY','ASSET_CATEGORY','HALL_CHARGE_TYPE','SALARY_COMPONENT',
                                 'OFFLINE_EVIDENCE_TYPE','ASSISTANCE_SCHEME','DEPOSIT_PRODUCT','CHIT_SCHEME')
    ON CONFLICT (tenant_id, lookup_type, code) DO NOTHING;
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    INSERT INTO wf.offline_evidence_type (tenant_id, code, name, sort_order)
    SELECT p_tenant_id, l.code, l.name, l.sort_order
      FROM platform.lookup_template l
     WHERE l.lookup_type = 'OFFLINE_EVIDENCE_TYPE' AND l.is_active
       AND NOT EXISTS (SELECT 1 FROM wf.offline_evidence_type e WHERE e.tenant_id = p_tenant_id AND e.code = l.code);
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    -- notification templates (English defaults)
    INSERT INTO notif.notification_template (tenant_id, code, channel, language_code, name, subject, body, module_code, is_essential)
    SELECT p_tenant_id, d.code, d.channel, d.language_code, d.name, d.subject, d.body, d.module_code, d.is_essential
      FROM platform.notification_template_default d
    ON CONFLICT (tenant_id, code, channel, language_code) DO NOTHING;
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    -- default approval policy and offline recorders
    INSERT INTO wf.approval_policy (tenant_id, code, name, module_code, workflow_code, stage_code, approver_role_id,
                                    allow_online, allow_offline, require_distinct_identities, require_verification, effective_from)
    SELECT p_tenant_id, t.code, t.name, t.module_code, t.workflow_code, t.stage_code, r.id,
           t.allow_online, t.allow_offline, t.require_distinct_identities, t.require_verification, DATE '2000-01-01'
      FROM platform.approval_policy_template t
      JOIN iam.role r ON r.tenant_id = p_tenant_id AND r.role_code = t.approver_role_code
     WHERE t.is_active
       AND NOT EXISTS (SELECT 1 FROM wf.approval_policy p WHERE p.tenant_id = p_tenant_id AND p.code = t.code);
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    INSERT INTO wf.offline_recorder_role (tenant_id, role_id)
    SELECT p_tenant_id, r.id
      FROM iam.role r JOIN platform.role_template rt ON rt.role_code = r.role_code AND rt.records_offline
     WHERE r.tenant_id = p_tenant_id
       AND NOT EXISTS (SELECT 1 FROM wf.offline_recorder_role o WHERE o.tenant_id = p_tenant_id AND o.role_id = r.id);
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    -- assistance schemes for enabled modules
    INSERT INTO ops.assistance_scheme (tenant_id, code, name, assistance_type, module_code, default_amount,
                                       account_id, rule_set_id, required_documents)
    SELECT p_tenant_id, l.code, l.name, l.attributes ->> 'assistance_type', l.attributes ->> 'module_code',
           (l.attributes ->> 'default_amount')::numeric, a.id, rs.id, coalesce(l.attributes -> 'required_documents', '[]')
      FROM platform.lookup_template l
      JOIN platform.tenant_module tm ON tm.tenant_id = p_tenant_id AND tm.module_code = l.attributes ->> 'module_code' AND tm.is_enabled
      LEFT JOIN acct.account a ON a.tenant_id = p_tenant_id AND a.code = l.attributes ->> 'account_code'
      LEFT JOIN cfg.rule_set rs ON rs.tenant_id = p_tenant_id AND rs.code = l.attributes ->> 'rule_set'
     WHERE l.lookup_type = 'ASSISTANCE_SCHEME' AND l.is_active
       AND NOT EXISTS (SELECT 1 FROM ops.assistance_scheme s WHERE s.tenant_id = p_tenant_id AND s.code = l.code);
    GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;

    -- deposit products and chit schemes (optional modules) start as DRAFT:
    -- the organisation reviews the terms before using them
    IF EXISTS (SELECT 1 FROM platform.tenant_module WHERE tenant_id = p_tenant_id AND module_code = 'DEPOSIT' AND is_enabled) THEN
        INSERT INTO dep.deposit_product (tenant_id, code, name, product_type, status, min_amount, max_amount,
                                         min_tenure_months, max_tenure_months, interest_method, compounding_frequency,
                                         payout_frequency, premature_allowed, lock_in_months, premature_rate_reduction,
                                         rd_grace_days, rd_max_missed, liability_account_id, interest_account_id, reason)
        SELECT p_tenant_id, l.code, l.name, x.product_type, 'DRAFT', x.min_amount, x.max_amount,
               x.min_tenure_months, x.max_tenure_months, coalesce(x.interest_method, 'SIMPLE'), x.compounding_frequency,
               coalesce(x.payout_frequency, 'AT_MATURITY'), coalesce(x.premature_allowed, true), coalesce(x.lock_in_months, 0),
               coalesce(x.premature_rate_reduction, 0), x.rd_grace_days, x.rd_max_missed, la.id, ia.id,
               'From platform template ' || l.code
          FROM platform.lookup_template l
          CROSS JOIN LATERAL jsonb_to_record(l.attributes) AS x(product_type text, min_amount numeric, max_amount numeric,
                 min_tenure_months integer, max_tenure_months integer, interest_method text, compounding_frequency text,
                 payout_frequency text, premature_allowed boolean, lock_in_months integer, premature_rate_reduction numeric,
                 rd_grace_days integer, rd_max_missed integer, liability_account_code text, interest_account_code text)
          LEFT JOIN acct.account la ON la.tenant_id = p_tenant_id AND la.code = x.liability_account_code
          LEFT JOIN acct.account ia ON ia.tenant_id = p_tenant_id AND ia.code = x.interest_account_code
         WHERE l.lookup_type = 'DEPOSIT_PRODUCT' AND l.is_active
           AND NOT EXISTS (SELECT 1 FROM dep.deposit_product d WHERE d.tenant_id = p_tenant_id AND d.code = l.code);
        GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;
    END IF;
    IF EXISTS (SELECT 1 FROM platform.tenant_module WHERE tenant_id = p_tenant_id AND module_code = 'CHIT' AND is_enabled) THEN
        INSERT INTO chit.chit_scheme (tenant_id, code, name, duration_months, member_count, subscription_amount, payout_method,
                                      max_discount_pct, foreman_commission_pct, dividend_treatment, auction_day,
                                      late_rules, eligibility, status)
        SELECT p_tenant_id, l.code, l.name, x.duration_months, x.member_count, x.subscription_amount, x.payout_method,
               x.max_discount_pct, x.foreman_commission_pct, coalesce(x.dividend_treatment, 'DEDUCT_NEXT'), x.auction_day,
               coalesce(l.attributes -> 'late_rules', '{}'), coalesce(l.attributes -> 'eligibility', '{}'), 'DRAFT'
          FROM platform.lookup_template l
          CROSS JOIN LATERAL jsonb_to_record(l.attributes) AS x(duration_months integer, member_count integer,
                 subscription_amount numeric, payout_method text, max_discount_pct numeric, foreman_commission_pct numeric,
                 dividend_treatment text, auction_day integer)
         WHERE l.lookup_type = 'CHIT_SCHEME' AND l.is_active
           AND NOT EXISTS (SELECT 1 FROM chit.chit_scheme c WHERE c.tenant_id = p_tenant_id AND c.code = l.code);
        GET DIAGNOSTICS v_c = ROW_COUNT; v_n := v_n + v_c;
    END IF;

    -- workflows, rule sets and dashboards
    v_n := v_n + platform.apply_config_templates(p_tenant_id);
    v_n := v_n + platform.apply_dashboard_templates(p_tenant_id);
    PERFORM set_config('app.tenant_id', coalesce(c_tenant, ''), true);
    RETURN v_n;
END
$$;

-- Existing organisations receive anything they are missing.
SET app.scope TO 'platform';
DO $$ BEGIN PERFORM platform.apply_platform_defaults(t.id) FROM platform.tenant t WHERE t.status <> 'CLOSED'; END $$;
RESET app.scope;

RESET app.channel;
