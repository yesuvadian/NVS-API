-- =============================================================================
-- CFMS 42 - Workflow and rule-set templates for the remaining approval flows
-- (functional review, second pass, items 6 and 7). Idempotent.
--   * 28 more workflow templates (approval matrix, Section 3.4 and module sections)
--   * 6 more rule-set templates (assistance, expense, payroll, hall, asset,
--     posting rules)
--   * platform.apply_config_templates(tenant): clones any template an existing
--     organisation does not have yet (new organisations get them at onboarding)
-- =============================================================================
SET app.channel TO 'MIGRATION';

-- -----------------------------------------------------------------------------
-- Workflow templates
-- -----------------------------------------------------------------------------
WITH w(code, name, module_code, entity_type, creator, approver, verifier, notify, description) AS (VALUES
 -- members
 ('MEMBER_SUSPENSION',    'Member Suspension',         'MEMBER',   'mbr.member',                 'EMP','MGR',NULL,NULL,NULL),
 ('MEMBER_REINSTATEMENT', 'Member Reinstatement',      'MEMBER',   'mbr.member',                 'EMP','MGR',NULL,NULL,NULL),
 ('MEMBER_EXIT',          'Member Exit',               'MEMBER',   'mbr.member',                 'EMP','MGR',NULL,NULL,'Allowed only when nothing is open'),
 ('DEATH_VERIFICATION',   'Death Verification',        'DECEASED', 'mbr.death_record',           'EMP','MGR',NULL,NULL,NULL),
 ('DUPLICATE_OVERRIDE',   'Duplicate Member Override', 'MEMBER',   'mbr.member_duplicate_check', 'EMP','MGR',NULL,NULL,NULL),
 ('MEMBER_MERGE',         'Member Merge',              'MEMBER',   'mbr.member_merge',           'MGR','LDR',NULL,NULL,NULL),
 -- loans
 ('LOAN_CANCELLATION',    'Loan Cancellation',         'LOAN',         'loan.loan',                 'EMP','MGR',NULL,NULL,NULL),
 ('GUARANTOR_REPLACEMENT','Guarantor Replacement',     'LOAN',         'loan.loan_guarantor',       'EMP','MGR',NULL,NULL,NULL),
 ('LOAN_TRANSFER',        'Loan Transfer',             'DECEASED',     'loan.loan_transfer',        'EMP','MGR',NULL,NULL,NULL),
 ('DECEASED_LOAN_DECISION','Deceased Member Loan Decision','DECEASED', 'loan.deceased_loan_decision','MGR','LDR',NULL,NULL,NULL),
 ('LOAN_WAIVER',          'Loan Waiver',               'LOAN_DEFAULT', 'loan.loan_waiver',          'MGR','LDR',NULL,NULL,NULL),
 -- cash and accounts
 ('RECEIPT_CANCELLATION', 'Receipt Cancellation (same day)', 'GL',     'acct.cash_receipt',  'EMP','MGR',NULL,NULL,'Before the cash day is closed'),
 ('RECEIPT_CANCELLATION_AFTER_DAY_END','Receipt Cancellation (after day-end)','GL','acct.cash_receipt','EMP','ACC','MGR',NULL,
  'After the cash day is closed: Manager verifies, Accountant approves the reversal'),
 ('PERIOD_REOPEN',        'Accounting Period Reopen',  'FIN_PERIOD', 'acct.financial_period', 'ACC','LDR',NULL,NULL,NULL),
 ('FUND_TRANSFER',        'Fund Transfer',             'GEN_FUND',   'acct.fund_transfer',    'ACC','LDR',NULL,NULL,NULL),
 ('COA_CHANGE',           'Chart of Accounts Change',  'COA',        'acct.account',          'ACC','LDR',NULL,NULL,NULL),
 -- operations
 ('PETTY_CASH_ADVANCE',   'Petty Cash Advance',        'EXPENSE',       'ops.petty_cash_advance', 'EMP','MGR',NULL,NULL,NULL),
 ('VENDOR_BILL',          'Vendor Bill',               'EXPENSE',       'ops.vendor_bill',        'EMP','MGR',NULL,NULL,NULL),
 ('SALARY_ADVANCE',       'Salary Advance',            'PAYROLL',       'ops.salary_advance',     'ACC','MGR',NULL,NULL,NULL),
 ('HALL_CANCELLATION',    'Hall Booking Cancellation and Refund','HALL','ops.hall_booking',       'EMP','MGR',NULL,NULL,NULL),
 ('HALL_SETTLEMENT',      'Hall Security Deposit Settlement','HALL',    'ops.hall_settlement',    'EMP','MGR',NULL,NULL,NULL),
 ('ASSET_TRANSFER',       'Asset Transfer / Assignment','ASSET',        'ops.asset_assignment',   'EMP','MGR',NULL,NULL,NULL),
 ('ASSET_DISPOSAL',       'Asset Disposal',            'ASSET_DISPOSAL','ops.asset_disposal',     'MGR','LDR',NULL,NULL,NULL),
 ('ASSET_MAINTENANCE',    'Asset Maintenance',         'ASSET_MAINT',   'ops.asset_maintenance',  'EMP','MGR',NULL,NULL,NULL),
 -- optional modules
 ('DEPOSIT_OPENING',      'Deposit Account Opening',   'DEPOSIT', 'dep.deposit_account',         'EMP','MGR',NULL,NULL,NULL),
 ('DEPOSIT_PREMATURE_CLOSURE','Deposit Premature Closure','DEPOSIT','dep.deposit_closure_request','EMP','MGR',NULL,NULL,NULL),
 ('DEPOSIT_CLAIM',        'Deposit Death Claim',       'DEPOSIT', 'dep.deposit_claim',           'EMP','MGR',NULL,NULL,NULL),
 ('CHIT_PRIZE',           'Chit Prize Payment',        'CHIT',    'chit.chit_prize',             'EMP','MGR',NULL,NULL,NULL)
)
INSERT INTO platform.config_template (template_kind, code, name, module_code, entity_type, description)
SELECT 'WORKFLOW', code, name, module_code, entity_type, description FROM w
ON CONFLICT (template_kind, code) DO NOTHING;

WITH w(code, creator, approver, verifier) AS (VALUES
 ('MEMBER_SUSPENSION','EMP','MGR',NULL), ('MEMBER_REINSTATEMENT','EMP','MGR',NULL), ('MEMBER_EXIT','EMP','MGR',NULL),
 ('DEATH_VERIFICATION','EMP','MGR',NULL), ('DUPLICATE_OVERRIDE','EMP','MGR',NULL), ('MEMBER_MERGE','MGR','LDR',NULL),
 ('LOAN_CANCELLATION','EMP','MGR',NULL), ('GUARANTOR_REPLACEMENT','EMP','MGR',NULL), ('LOAN_TRANSFER','EMP','MGR',NULL),
 ('DECEASED_LOAN_DECISION','MGR','LDR',NULL), ('LOAN_WAIVER','MGR','LDR',NULL),
 ('RECEIPT_CANCELLATION','EMP','MGR',NULL), ('RECEIPT_CANCELLATION_AFTER_DAY_END','EMP','ACC','MGR'),
 ('PERIOD_REOPEN','ACC','LDR',NULL), ('FUND_TRANSFER','ACC','LDR',NULL), ('COA_CHANGE','ACC','LDR',NULL),
 ('PETTY_CASH_ADVANCE','EMP','MGR',NULL), ('VENDOR_BILL','EMP','MGR',NULL), ('SALARY_ADVANCE','ACC','MGR',NULL),
 ('HALL_CANCELLATION','EMP','MGR',NULL), ('HALL_SETTLEMENT','EMP','MGR',NULL), ('ASSET_TRANSFER','EMP','MGR',NULL),
 ('ASSET_DISPOSAL','MGR','LDR',NULL), ('ASSET_MAINTENANCE','EMP','MGR',NULL),
 ('DEPOSIT_OPENING','EMP','MGR',NULL), ('DEPOSIT_PREMATURE_CLOSURE','EMP','MGR',NULL), ('DEPOSIT_CLAIM','EMP','MGR',NULL),
 ('CHIT_PRIZE','EMP','MGR',NULL)
)
INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 1, 'PUBLISHED', platform.tpl_approval_workflow(t.code, w.creator, w.approver, w.verifier),
       (SELECT id FROM platform.json_schema WHERE schema_kind = 'WORKFLOW' AND schema_version = '1.0'),
       'Initial template (approval matrix, scope v1.7)', now()
  FROM w JOIN platform.config_template t ON t.template_kind = 'WORKFLOW' AND t.code = w.code
ON CONFLICT (template_id, version_no) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Rule-set templates (illustrative defaults; organisations change them by
-- publishing a new version of their own copy)
-- -----------------------------------------------------------------------------
INSERT INTO platform.config_template (template_kind, code, name, module_code, entity_type, description) VALUES
 ('RULESET','ASSISTANCE','Assistance rules','ASSIST_EDU','ops.assistance_application','Education and cremation assistance eligibility and limits'),
 ('RULESET','EXPENSE','Expense rules','EXPENSE','ops.expense','Approval limits, petty cash and advances'),
 ('RULESET','PAYROLL','Payroll rules','PAYROLL','ops.payroll_run','Pay frequency, rounding, advances and loan deductions'),
 ('RULESET','HALL','Hall booking rules','HALL','ops.hall_booking','Rates, security deposit, cancellation and refunds'),
 ('RULESET','ASSET','Asset rules','ASSET','ops.asset','Capitalisation, depreciation and disposal'),
 ('RULESET','POSTING_RULES','Posting rules','GL','acct.journal','Journal template for each business event (uses account mapping keys)')
ON CONFLICT (template_kind, code) DO NOTHING;

INSERT INTO platform.config_template_version (template_id, version_no, status, definition, json_schema_id, reason, published_at)
SELECT t.id, 1, 'PUBLISHED',
       jsonb_build_object('ruleSet', t.code, 'version', 1, 'schemaVersion', '1.0', 'rules',
       CASE t.code
         WHEN 'ASSISTANCE' THEN $j$[
  {"code":"EDUCATION_ELIGIBILITY","value":{"memberStatus":["ACTIVE"],"minMembershipMonths":12,"noOverdueLoan":true,"oncePerChildPerCycle":true}},
  {"code":"EDUCATION_AMOUNT","value":{"type":"fixed","amount":5000,"maxChildrenPerMember":2}},
  {"code":"CREMATION_ELIGIBILITY","value":{"memberStatus":["ACTIVE","DECEASED"],"coveredRelations":["SELF","SPOUSE","PARENT","CHILD"]}},
  {"code":"CREMATION_AMOUNT","value":{"type":"fixed","amount":10000}},
  {"code":"CLAIM_WINDOW_DAYS","value":90}]$j$::jsonb
         WHEN 'EXPENSE' THEN $j$[
  {"code":"APPROVAL_LIMITS","value":{"MGR":{"max":25000},"LDR":{"max":null}}},
  {"code":"PETTY_CASH","value":{"floatLimit":10000,"advanceSettlementDays":7}},
  {"code":"BILL_REQUIRED_ABOVE","value":500},
  {"code":"HIGH_VALUE","when":{"all":[{"field":"expense.amount","op":"gt","value":25000}]},"then":{"approverRole":"LDR"}}]$j$::jsonb
         WHEN 'PAYROLL' THEN $j$[
  {"code":"FREQUENCY","value":"MONTHLY"},
  {"code":"ROUNDING","value":{"mode":"NEAREST","to":1}},
  {"code":"SALARY_ADVANCE","value":{"maxPercentOfNet":50,"recoverInMonths":3}},
  {"code":"LOAN_DEDUCTION","value":{"allowed":true,"needsAuthorisation":true,"maxPercentOfNet":50}}]$j$::jsonb
         WHEN 'HALL' THEN $j$[
  {"code":"SECURITY_DEPOSIT","value":{"type":"fixed","amount":5000}},
  {"code":"CONFIRMATION","value":{"rentPaidInFull":true,"depositPaidInFull":true}},
  {"code":"FAMILY_EVENT_MEMBER_RATE","value":{"allowed":true,"approvalRequired":true}},
  {"code":"CANCELLATION_REFUND","value":[{"daysBeforeEvent":30,"refundPercent":100},{"daysBeforeEvent":7,"refundPercent":50},{"daysBeforeEvent":0,"refundPercent":0}]},
  {"code":"DEPOSIT_SETTLEMENT_DAYS","value":15}]$j$::jsonb
         WHEN 'ASSET' THEN $j$[
  {"code":"CAPITALISATION_THRESHOLD","value":5000},
  {"code":"DEPRECIATION","value":{"method":"STRAIGHT_LINE","frequency":"MONTHLY","residualPercent":0}},
  {"code":"QUOTATIONS_REQUIRED","when":{"all":[{"field":"purchase.amount","op":"gt","value":50000}]},"then":{"count":3}},
  {"code":"DISPOSAL_APPROVER","value":"LDR"}]$j$::jsonb
         WHEN 'POSTING_RULES' THEN $j$[
  {"code":"APPLICATION_FEE","value":{"lines":[{"dr":"CASH"},{"cr":"APPLICATION_FEE"}]}},
  {"code":"LOAN_DISBURSEMENT","value":{"lines":[{"dr":"LOAN_PRINCIPAL"},{"cr":"CASH"}]}},
  {"code":"LOAN_REPAYMENT","value":{"lines":[{"dr":"CASH"},{"cr":"LOAN_PRINCIPAL","part":"principal"},{"cr":"LOAN_INTEREST","part":"interest"},{"cr":"LATE_FEE","part":"lateFee"},{"cr":"DEFAULT_PENALTY","part":"penalty"}]}},
  {"code":"SALARY_DEDUCTION_REPAYMENT","value":{"lines":[{"dr":"SALARY"},{"cr":"LOAN_PRINCIPAL","part":"principal"},{"cr":"LOAN_INTEREST","part":"interest"}]}},
  {"code":"UNAPPLIED_RECEIPT","value":{"lines":[{"dr":"CASH"},{"cr":"MEMBER_UNAPPLIED"}]}},
  {"code":"UNAPPLIED_APPLIED","value":{"lines":[{"dr":"MEMBER_UNAPPLIED"},{"cr":"LOAN_PRINCIPAL"}]}},
  {"code":"LOAN_WRITE_OFF","value":{"lines":[{"dr":"BAD_DEBTS_WRITTEN_OFF"},{"cr":"LOAN_PRINCIPAL"}]}},
  {"code":"BAD_DEBT_RECOVERY","value":{"lines":[{"dr":"CASH"},{"cr":"BAD_DEBTS_RECOVERED"}]}},
  {"code":"HALL_RENT","value":{"lines":[{"dr":"CASH"},{"cr":"HALL_RENT"}]}},
  {"code":"HALL_SECURITY_DEPOSIT","value":{"lines":[{"dr":"CASH"},{"cr":"HALL_SECURITY_DEPOSIT"}]}},
  {"code":"HALL_DEPOSIT_REFUND","value":{"lines":[{"dr":"HALL_SECURITY_DEPOSIT"},{"cr":"CASH"}]}},
  {"code":"CONTRIBUTION","value":{"lines":[{"dr":"CASH"},{"cr":"CONTRIBUTION"}]}},
  {"code":"DONATION","value":{"lines":[{"dr":"CASH"},{"cr":"DONATION_UNRESTRICTED"}]}},
  {"code":"EDUCATION_ASSISTANCE","value":{"lines":[{"dr":"EDUCATION_ASSISTANCE"},{"cr":"CASH"}]}},
  {"code":"CREMATION_ASSISTANCE","value":{"lines":[{"dr":"CREMATION_ASSISTANCE"},{"cr":"CASH"}]}},
  {"code":"BIRTHDAY_GRANT","value":{"lines":[{"dr":"BIRTHDAY_GRANT"},{"cr":"CASH"}]}},
  {"code":"SALARY_PAYMENT","value":{"lines":[{"dr":"SALARY"},{"cr":"CASH"}]}},
  {"code":"SALARY_ADVANCE","value":{"lines":[{"dr":"SALARY_ADVANCE"},{"cr":"CASH"}]}},
  {"code":"PETTY_CASH_ADVANCE","value":{"lines":[{"dr":"PETTY_CASH_ADVANCE"},{"cr":"CASH"}]}},
  {"code":"DEPRECIATION","value":{"lines":[{"dr":"DEPRECIATION"},{"cr":"ACCUMULATED_DEPRECIATION"}]}},
  {"code":"CASH_SHORTAGE","value":{"lines":[{"dr":"CASH_SHORT_EXCESS"},{"cr":"CASH"}]}},
  {"code":"DEPOSIT_RECEIPT","value":{"lines":[{"dr":"CASH"},{"cr":"DEPOSIT_FD"}]}},
  {"code":"DEPOSIT_INTEREST","value":{"lines":[{"dr":"DEPOSIT_INTEREST"},{"cr":"DEPOSIT_FD"}]}},
  {"code":"FOREMAN_COMMISSION","value":{"lines":[{"dr":"CASH"},{"cr":"FOREMAN_COMMISSION"}]}}]$j$::jsonb
       END),
       (SELECT id FROM platform.json_schema WHERE schema_kind = 'RULESET' AND schema_version = '1.0'),
       'Initial template (illustrative values from scope v1.7)', now()
  FROM platform.config_template t
 WHERE t.template_kind = 'RULESET' AND t.code IN ('ASSISTANCE','EXPENSE','PAYROLL','HALL','ASSET','POSTING_RULES')
ON CONFLICT (template_id, version_no) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Clone templates an organisation does not have yet (latest published version).
-- Onboarding already clones every template; this brings existing organisations
-- up to date after new templates are published. Returns the number cloned.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.apply_config_templates(p_tenant_id uuid, p_platform_user_id uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    r      record;
    v_id   uuid;
    v_n    integer := 0;
BEGIN
    FOR r IN SELECT t.id AS template_id, t.template_kind, t.code, t.name, t.module_code, t.entity_type,
                    v.id AS tv_id, v.version_no, v.definition, v.json_schema_id
               FROM platform.config_template t
               JOIN platform.config_template_version v ON v.template_id = t.id AND v.status = 'PUBLISHED'
              WHERE t.is_active
                AND v.version_no = (SELECT max(v2.version_no) FROM platform.config_template_version v2
                                     WHERE v2.template_id = t.id AND v2.status = 'PUBLISHED')
              ORDER BY t.template_kind, t.code
    LOOP
        IF r.template_kind = 'RULESET' THEN
            CONTINUE WHEN EXISTS (SELECT 1 FROM cfg.rule_set WHERE tenant_id = p_tenant_id AND code = r.code);
            INSERT INTO cfg.rule_set (tenant_id, code, name, module_code, scope_type, template_id, template_version)
            VALUES (p_tenant_id, r.code, r.name, r.module_code,
                    CASE WHEN r.code LIKE 'LOAN_TYPE_%' THEN 'LOAN_TYPE' ELSE 'GENERAL' END, r.template_id, r.version_no)
            RETURNING id INTO v_id;
            INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                              effective_from, reason, source, source_template_version_id, published_by, published_at)
            VALUES (p_tenant_id, v_id, 1, 'PUBLISHED', r.definition, r.json_schema_id, DATE '2000-01-01',
                    'Cloned from template ' || r.code || ' v' || r.version_no, 'TEMPLATE', r.tv_id, p_platform_user_id, now());
        ELSE
            CONTINUE WHEN EXISTS (SELECT 1 FROM cfg.workflow_definition WHERE tenant_id = p_tenant_id AND code = r.code);
            INSERT INTO cfg.workflow_definition (tenant_id, code, name, module_code, entity_type, template_id, template_version)
            VALUES (p_tenant_id, r.code, r.name, r.module_code, r.entity_type, r.template_id, r.version_no)
            RETURNING id INTO v_id;
            INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                              json_schema_id, effective_from, reason, source, source_template_version_id,
                                              published_by, published_at)
            VALUES (p_tenant_id, v_id, 1, 'PUBLISHED', r.definition, r.json_schema_id, DATE '2000-01-01',
                    'Cloned from template ' || r.code || ' v' || r.version_no, 'TEMPLATE', r.tv_id, p_platform_user_id, now());
        END IF;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END
$$;

-- Existing organisations receive the new templates.
SET app.scope TO 'platform';
DO $$ BEGIN PERFORM platform.apply_config_templates(t.id) FROM platform.tenant t WHERE t.status <> 'CLOSED'; END $$;
RESET app.scope;

RESET app.channel;
