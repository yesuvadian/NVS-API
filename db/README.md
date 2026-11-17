# CFMS database scripts (PostgreSQL 16)

Built from CFMS_Updated_Scope_v1.7. Tested on PostgreSQL 16: fresh install and re-run both pass `90_verify.sql`.

## Run order

| Step | File | Run as | Connected to |
|---|---|---|---|
| 1 | `00a_bootstrap_role_and_database.sql` | postgres | postgres DB |
| 2 | `00b_bootstrap_database_setup.sql` | postgres | **nvs** |
| 3 | `01` … `46` in the order of `99_run_all.psql` (01–14, 16, 20, 15, 30–36, 40–46) | **nvs / nvs_admin** | nvs |
| 4 | `90_verify.sql` (optional checks) | nvs | nvs |
| 5 | `50_seed_demo_tenant.sql` (optional, dev only) | nvs | nvs |

`00a` creates the login role `nvs` (password `nvs_admin`) and the runtime group role `nvs_app`, then creates the database.

**DBeaver note:** `CREATE DATABASE` cannot run inside a transaction. Turn auto-commit on and run STEP 2 of `00a` on its own (select the statement, Ctrl+Enter). Then open a new connection to database `nvs` for everything after that.

With psql you can run steps 3 and 4 in one go:

```
psql -h localhost -U nvs -d nvs -f 99_run_all.psql
```

All scripts 01–45 are idempotent and can be re-run. To apply later changes to an existing database, just run `99_run_all.psql` again.

Database transaction routines are installed from `30_functions_provisioning.sql`
as part of `99_run_all.psql`. `acct.post_cash_receipt(...)` allocates the receipt
number, resolves configured account mappings, and posts the receipt and balanced
journal atomically. Member create/update, loan application create/submit and
lifecycle transitions, and translation draft/save/publish operations also use
database routines so multi-table writes and their rules stay in PostgreSQL.
Error short codes and localized messages are seeded by `44_seed_error_codes.sql`.
Read queries used by the API (member and loan lookups, the approval inbox,
tenant access checks, organisation search and translation lists) are database
functions in `31_functions_api_queries.sql`, so the API repositories send no
inline SQL.

Loan servicing lives in `32_functions_loan_servicing.sql`: the repayment
schedule, repayment history and member loan statement views, early settlement
(`quote_early_settlement`, `approve_early_settlement`, `collect_early_settlement`,
driven by the loan's `EARLY_SETTLEMENT` rule), and the daily job
`loan.run_daily_status()` (approval expiry, overdue, back to current, default
with penalty and member restriction). Run the job once a day with
`python jobs.py loan-status` from the API folder (cron or Windows Task
Scheduler); it connects as the runtime role, signs the context with
`CFMS_DB_CONTEXT_SIGNING_KEY`, and records each run in `platform.job_run`.
A loan repaid on schedule becomes CLOSED; SETTLED is used for early settlement.

Loan module additions from the functional gap review (Nov 2026):

| Script | What it adds |
|---|---|
| `16_loan_gap_tables.sql` | Tables for migrated-loan default review, receipt reversal and loan cancellation; cooling-off override columns |
| `32_functions_loan_servicing.sql` | Default settlement quotes (rule `DEFAULT_SETTLEMENT`), settlement interest waiver, and a daily job that also assesses late fees, opens recovery cases, ends cooling-off, sends reminders and escalates recovery |
| `33_functions_loan_repayment.sql` | Repayment allocation order (rule `PAYMENT_ALLOCATION`, else setting `loans.payment_allocation_order`), late fees (rule `LATE_FEE`), advance payments, overpayment with schedule regeneration (rule `OVERPAYMENT`), closing a default and ending cooling-off |
| `34_functions_loan_notifications.sql` | Templated notifications with opt-out, deceased suppression and quiet hours; due and overdue reminders (`notifications.loan_reminder_schedule`) |
| `35_functions_loan_recovery.sql` | Recovery cases, contacts and escalation (`recovery.escalate_to_*_days`), waivers of late fees, penalties and the application fee, cooling-off override, write-off (approver `loans.write_off_approver_role`) and bad-debt recovery |
| `36_functions_loan_lifecycle.sql` | Offline approval recording and verification (scope 28.1), editing a draft or returned application, withdrawal, cancellation of an approved loan, and receipt reversal (Manager before day-end; Manager and Accountant after, from the `cash.receipt_cancel_*` settings) |
| `37_functions_loan_guarantors.sql` | Guarantors with consent, guarantor limits (`loans.guarantor_limits`), replacement on a running loan, release when the loan ends; member exposure for age, per-type, member and household limits |
| `38_functions_loan_restructure.sql` | Disbursement tranches (loan type `allows_tranches` and rule `TRANCHES`), cash limit approval (`cash.disbursement_limit`), restructuring (`loans.restructuring`), deceased member's loan decisions and transfer to successors, migrated-loan review decisions |
| `39_functions_loan_reports.sql` | Loan reports (outstanding, interest, ageing and PAR, demand vs collection, due and overdue lists, restructured and written-off, guarantor exposure), loan documents with required types (`loan_type.required_documents` or rule `REQUIRED_DOCUMENTS`) and the sanction letter data |
| `46_seed_loan_gaps.sql` | Error codes (English and Tamil), the new settings and the default-notice templates |

Supported languages live in `platform.language` (script 15): language packs and
`mbr.member.preferred_language` reference it, and the API validates language
codes with `platform.is_active_language()`. Add a language there, not in code.
The API loads `platform.get_error_catalogue()` at start-up and answers every
error with its catalogue code and the message in the caller's
`Accept-Language` (English fallback); add Tamil text to
`platform.error_code.translations` in script 44.

### Signed request context (script 15)

RLS trusts only session context signed by the API, except for a direct database-owner (`nvs`) session used for administration. The API secret manager must be provisioned with the database key using a privileged deployment connection; retrieve it once with `SELECT app.context_signing_key_for_api();` and store it as a secret. Never give this key to `nvs_app` or end users. The API signs the UTF-8 payload fields in this order, joined by `|`: `tenant_id|user_id|platform_user_id|scope|role_code|channel|working_date|client_ip|device` (empty string for NULL), using HMAC-SHA256 and lowercase hex. Pass the signature as the final argument to `app.set_context` or `app.set_platform_context`. Unsigned context from the runtime role is intentionally invisible under RLS. Rotate only with a coordinated API/database deployment.

Script 15 also adds platform-managed, versioned English/Tamil translations and archive manifests, record indexes, restore requests and per-category purge tracking. Archive payloads remain encrypted, immutable objects in external storage; the database stores their URI, checksum and searchable index. The API/jobs must enforce object-store encryption and immutability, archive/restore workflows, and purge execution.

## Browsing data

Every tenant table has FORCED row-level security, so even the owner sees nothing until a tenant is set in the session:

```sql
SELECT id, code, name FROM platform.tenant;          -- find the tenant uuid
SELECT app.set_context('<tenant uuid>');             -- now tenant rows are visible
SELECT app.set_platform_context('<platform_user uuid>');  -- super-admin scope (config/templates)
```

Audit and change reasons: `SELECT app.set_audit_reason('why');` before a change. History per record: `audit.v_record_history`.

## Onboarding an organisation

```sql
SELECT platform.provision_tenant('ACME', 'Acme Welfare Society', 'Admin Name', '9999999999',
       'admin@acme.example', ARRAY['HALL','LOAN']);   -- returns the new tenant uuid
SELECT platform.set_module_enabled('<tenant uuid>', 'DEPOSIT', true, 'reason', NULL, true);
```

Provisioning creates the branch, modules, privilege ceiling, standard roles, settings (copied from the versioned template), chart of accounts, cash account, fund, financial year, rule sets, workflows, approval policy, notification templates and the default org admin.

## Production

Let the application connect with a login role that is a member of `nvs_app` (DML only), not as `nvs`:

```sql
CREATE ROLE nvs_api LOGIN PASSWORD '...' IN ROLE nvs_app;
```

`nvs_app` cannot change modules or privileges and cannot update or delete audit rows. Change the `nvs_admin` password before going live.

## Controls added after the gap review (scripts 12, 41, 45)

- **Admin changes need Leadership approval.** A user acting as ADM cannot change `iam.role` or `iam.role_privilege` directly. Create a row in `iam.access_change_request`; an LDR user (not the requester) sets it to APPROVED; then `SELECT iam.apply_access_change('<request id>')`. Settings saved by ADM go in as `PENDING_APPROVAL` and an LDR user runs `cfg.approve_tenant_setting(id, true)`.
- **Cash segregation.** Whoever collected or paid out cash on a day cannot count, approve or close that cash day. An approved `iam.sod_exception` with `CASH_COLLECT` / `CASH_RECONCILE` allows it for very small teams.
- **Restricted and corpus funds** cannot go below zero (`acct.v_fund_balance`). List allowed expense accounts for a fund in `acct.fund_allowed_account` to enforce its purpose.
- **Migration:** `legacy_ref` and `import_batch_id` on migrated tables (legacy_ref unique per organisation), `loan.is_migrated`, staging rows in `core.import_row`, exceptions in `core.import_exception`.
- **Dashboards:** widget library `platform.widget_type`, data sources `platform.dashboard_data_source`, default layouts `platform.dashboard_template`, per-organisation versions in `cfg.dashboard_version` (published versions are immutable).
- **Tasks:** `wf.task` with reassignment history; `wf.reassign_open_tasks(from_user, to_user, reason)` for replacements.
- **Jobs and exports:** `platform.job_definition` / `platform.job_run`, and `core.export_request` (sensitive exports need the module's export privilege).
- **Deposits:** monthly interest memo in `dep.deposit_interest_calc` (not posted until credited or paid).
- **Search:** every foreign key has an index, plus trigram indexes (pg_trgm) for partial search on names, mobile numbers and reference numbers.

## Controls added after the functional review (scripts 13, 42)

- **Non-cash repayments.** `loan.loan_repayment` can come from a cash receipt, a payslip line (salary deduction), a deposit transaction (set-off) or a journal. Exactly one source is required (migrated history may have none).
- **Totals checked at commit.** Receipt and voucher lines must add up to the amount, and the linked journal must move exactly that amount through cash accounts. Repayment allocations must add up to the repayment. Final or paid payslips must match their lines (gross − deductions = net).
- **Business rules.** A loan cannot be submitted while a before-submission fee is unpaid, or approved while any fee is unpaid (except one deducted from disbursement). Disbursement needs an approved loan, an Active member, a date within the approval window for the first tranche, and a total that does not exceed the approved amount. A member cannot exit while anything is open (`mbr.open_obligations(member)` lists what). A hall booking is confirmed only when rent and security deposit are paid in full, and the member rate for a family event needs an approver.
- **Period and year close.** `acct.close_period(id)` checks earlier periods, draft or pending journals, unclosed cash days and unpaid vouchers (`acct.period_close_problems(id)` lists them). `acct.reopen_period(id, approval_request_id, reason)` needs a new approved request; periods of a closed year never reopen. `acct.close_financial_year(year_id)` posts the YEAR_END journal (income and expense to each fund's account, unrestricted to General Fund 3100), closes the year and opens the next.
- **Member unapplied money** (account 2120): `acct.member_unapplied` movements and `acct.v_member_unapplied_balance`. Movements are never edited and the balance cannot go negative.
- **Views:** `loan.v_loan_balance` (balances from transactions), `acct.v_loan_control_reconciliation` (ledger vs loan sub-ledger per loan type), `mbr.v_member_financial_profile`, `chit.v_group_reconciliation`.
- **Deposits:** `dep.deposit_claim` (death claims), `dep.deposit_closure_request` (one open request per account), nominee shares must total 100%.
- **Chit funds:** foreman security and agreement on `chit.chit_group`, `chit.chit_dividend_payout`, `chit.chit_refund`.
- **Hall approvals:** family-event approval, cancellation approval and refund amount on `ops.hall_booking`.
- **Templates:** 28 more workflow templates (member status changes, death verification, merges, loan cancellation, guarantor replacement, transfers, waivers, receipt cancellation, period reopen, fund transfer, chart of accounts change, petty cash, vendor bills, salary advance, hall cancellation and settlement, asset transfer, disposal and maintenance, deposits, chit prize) and rule sets for assistance, expense, payroll, hall, asset and posting rules. `platform.apply_config_templates(tenant)` gives existing organisations any template they do not have yet.

## Platform template library (what every new organisation copies)

All common data lives in platform tables maintained by the Super Administrator. The seed scripts `40`–`43` fill them; onboarding (`platform.provision_tenant`) copies from them, and `platform.apply_platform_defaults(tenant)` gives an existing organisation anything it is missing (it never changes what the organisation already has). It runs automatically when a module is switched on.

| Template | Platform table | Seeded in | Copied into |
|---|---|---|---|
| Modules and menu | `platform.module` (65) | 40 | `platform.tenant_module` |
| Privileges | `platform.privilege` (254), `platform.privilege_type` | 40 | privilege ceiling |
| Roles and their privileges | `platform.role_template` (6), `platform.role_template_privilege` (568) | 40 | `iam.role`, `iam.role_privilege` |
| Incompatible roles | `platform.sod_rule` (5) | 40, 43 | enforced on `iam.user_role` |
| Who records offline decisions | `platform.role_template.records_offline` | 43 | `wf.offline_recorder_role` |
| Approval policy | `platform.approval_policy_template` | 43 | `wf.approval_policy` |
| Settings and defaults | `platform.setting_definition`, `platform.settings_template[_item]` (62) | 40, 41 | `cfg.tenant_setting` |
| Workflows | `platform.config_template` / `_version` (44 workflows) | 40, 42 | `cfg.workflow_definition` / `_version` |
| Rule sets | same tables (9 rule sets) | 40, 42 | `cfg.rule_set` / `_version` |
| Actions | `platform.action_definition` (27) | 40 | `cfg.tenant_action` |
| Chart of accounts | `platform.coa_template` (62) | 40 | `acct.account` |
| Posting accounts | `platform.account_mapping_template` (36) | 43 | `acct.account_mapping` |
| Loan types | `platform.loan_type_template` (3) | 40 | `loan.loan_type` |
| Numbering | `platform.number_series_template` (16) | 43 | `acct.voucher_series` (used by `acct.next_number`) |
| Reference lists | `platform.lookup_template` | 40, 43 | expense and asset categories, hall charges, salary components, offline evidence types, `core.lookup_value` (relationships, ID types, reasons, purposes, designations, languages ...) |
| Assistance schemes | `lookup_template` type `ASSISTANCE_SCHEME` | 43 | `ops.assistance_scheme` |
| Deposit products, chit schemes | `lookup_template` types `DEPOSIT_PRODUCT`, `CHIT_SCHEME` | 43 | `dep.deposit_product`, `chit.chit_scheme` (as DRAFT, when the module is on) |
| Notifications | `platform.notification_template_default` (42) | 40, 43 | `notif.notification_template` |
| Payment modes, legal features | `platform.payment_mode`, `platform.compliance_feature` | 40 | organisation settings |
| Dashboards | `platform.widget_type`, `platform.dashboard_data_source`, `platform.dashboard_template` | 41 | `cfg.dashboard_definition` / `_version` |
| Background jobs | `platform.job_definition` (17) | 41 | run log `platform.job_run` |
| Data retention | `platform.data_category` | 40 | `platform.purge_policy` |
| Migration file layouts | `platform.import_template` (8) | 43 | used by the import screens |

Keeping templates current: `platform.v_tenant_template_versions` shows which organisations use an older workflow or rule-set template, and `platform.upgrade_tenant_template(tenant, 'WORKFLOW'|'RULESET', code, reason)` creates a DRAFT version from the latest template for the Super Administrator to publish. `cfg.v_setting_differences` lists settings where an organisation differs from the default.

## Exception management and error codes (scripts 14, 44; scope Section 34.1)

- **Catalogue:** `platform.error_code` (107 codes), format `CFMS-<MODULE>-<NNNN>`. The first digit of the number is the category: 1 validation, 2 business rule, 3 authorisation, 4 not found, 5 conflict, 6 integration, 9 system. Each code has a severity, HTTP status, message template with `{placeholders}`, translations, resolution, retryable and alert flags. Codes are never reused; retire them with `is_active = false`.
- **Raising:** every database rule fails through `app.fail(short_code, message)`. The error carries SQLSTATE `CF<digit>00`, the specific message, the short code in HINT, and JSON in DETAIL: `{"code":"CFMS-FEE-2001","category":"BUSINESS_RULE","http":422,"severity":"ERROR","retryable":false,"shortCode":"FEE_UNPAID"}`. The API reads DETAIL and returns the standard error JSON.
- **PostgreSQL's own errors** (duplicate, foreign key, check, not null, row-level security, deadlock, timeout) are translated with `app.error_info(sqlstate, constraint_name, hint)`, using `platform.constraint_error_map` for business constraints and `platform.sqlstate_error_map` for the rest. Anything unknown becomes `CFMS-SYS-9000`.
- **Logging:** after rolling back, the API calls `app.log_error(jsonb)` in a new transaction (code, message, correlationId, path, method, context, stack). The entry goes to `core.error_log` inside an organisation (row-level security), otherwise to `platform.platform_error_log`. Entries are never deleted; only their status changes (OPEN, ACKNOWLEDGED, RESOLVED, IGNORED). `core.v_error_summary` gives daily counts per code.
- **Actions:** `platform.action_error_code` lists the codes each action can return. `wf.action_execution` and its log carry `error_code` and `correlation_id`.
- `90_verify.sql` checks that every short code raised in the database is in the catalogue (1e) and that mapped constraints exist (1f).

## Interpretation notes

- Engines and dashboards from the scope are seeded as core modules (always on).
- Workflow and rule JSON is checked structurally in the database on publish. Full JSON Schema validation is expected in the API (or add the `pg_jsonschema` extension).
- Account 2410 (Statutory Dues Payable) is created inactive and is activated when a legal/tax feature is enabled.
- High-volume or log tables (audit tables themselves, sessions, sign-in history, change logs, action logs) are excluded from the audit trigger; they are append-only instead.
- Only CASH is enabled as a payment mode; bank accounts exist but are reserved for later.
