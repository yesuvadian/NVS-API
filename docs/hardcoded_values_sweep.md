# Hard-coded business values: sweep (2026-11-20)

Rule from Yesu: no hard-coded setting for anything. Every business value comes
from a privilege, the rule-set JSON, the workflow JSON, or an org/platform
setting whose default is seeded as data.

Each entry gives file:line, the literal, and its proposed home.

Status values:
- **FIX-NOW**: fixed with the engine work (loan module).
- **PROPOSED**: waiting for approval.

## 1. Loans (fixed in the engine increment unless noted)

| Where | Literal | Proposed home |
|---|---|---|
| db/30_functions_provisioning.sql:442 | approver role `'MGR'` on submit | workflow JSON: stage `approval.roles` (engine configures the request) |
| db/36_functions_loan_lifecycle.sql:142 | `approval_expires_on = working_date + 30` | setting `loans.disbursement_window_days` (already seeded as 30, never read) |
| db/36_functions_loan_lifecycle.sql:130-136 | interest formula `amount*rate*tenure/1200`, fallbacks `'FLAT'` and `0` | INTEREST rule `method` (required). Refuse if the rule is missing. |
| db/36_functions_loan_lifecycle.sql:408 | `assert_approver('MGR,LDR')` (charge waiver/cancel) | privilege + setting `loans.charge_waiver_approver_roles` |
| db/36_functions_loan_lifecycle.sql:508 | fallback `ARRAY['MGR','ACC']` | setting `cash.receipt_cancel_after_close_approvers` (seeded). No fallback: refuse if missing. |
| db/36_functions_loan_lifecycle.sql:513 | fallback `'MGR'` | setting `cash.receipt_cancel_same_day_approver` (seeded). No fallback. |
| db/35_functions_loan_recovery.sql:226 | `role_code IN ('MGR','LDR')` for EXCEPTION_APPROVED | setting `recovery.exception_approver_roles` |
| db/35_functions_loan_recovery.sql:261 / 270 | escalate to roles `'MGR'` / `'LDR'` | settings `recovery.escalate_to_manager_role` / `recovery.escalate_to_leadership_role` |
| db/35_functions_loan_recovery.sql:254-255 | fallback `30` days | settings already seeded. No fallback. |
| db/35_functions_loan_recovery.sql:95 | first follow-up `+3` days | setting `recovery.first_follow_up_days` |
| db/35_functions_loan_recovery.sql:205 | next follow-up `+7` days | setting `recovery.follow_up_interval_days` |
| db/35_functions_loan_recovery.sql:370 / 463 | `assert_approver('MGR')` (waiver, OTS) | setting `recovery.waiver_approver_roles` / `recovery.settlement_offer_approver_roles` |
| db/35_functions_loan_recovery.sql:472 | OTS valid `+30` days | setting `recovery.settlement_offer_valid_days` |
| db/35_functions_loan_recovery.sql:542 | fallback `'LDR'` | setting `loans.write_off_approver_role` (seeded). No fallback. |
| db/37_functions_loan_guarantors.sql:239 | `assert_approver('MGR,LDR')` (guarantor substitution) | setting `loans.guarantor_change_approver_roles` |
| db/38_functions_loan_restructure.sql:155 | fallback `'LDR'` | `cash.disbursement_limit.approverRole` (seeded). No fallback. |
| db/38_functions_loan_restructure.sql:459 / 489 / 629 / 717 | `assert_approver('MGR,LDR')` (restructure, tranche, transfer) | setting `loans.restructure_approver_roles` / `loans.tranche_approver_roles` / `loans.transfer_approver_roles` |
| db/38_functions_loan_restructure.sql:328 / 334 | restructure fallbacks `maxPerLoan 1`, `maxMoratoriumMonths 3` | RESTRUCTURING rule/setting (seeded). Refuse if missing. |
| db/38_functions_loan_restructure.sql:259 / 660 | first due date `+1 month` | kept: monthly instalments (tenure is in months), a domain rule; listed in section 6 |
| db/33_functions_loan_repayment.sql:147 | cooling-off fallback `6` months | setting `loans.cooling_off` (seeded). No fallback. |
| db/31_functions_api_queries.sql:125-128 | fallbacks `6`, `1`, `true`, `true` (membership months, concurrent loans, first-loan nominee, overdue block) | settings already seeded. No fallback. |
| db/31g_workflow_rule_checks.sql:279 | fallback `true` for `loans.nominee_mandatory_first_loan` | seeded setting. No fallback. |
| db/34_functions_loan_notifications.sql:208-209 | `overdueAfter 1`, `repeatEveryDays 7` | REMINDERS rule (seeded). Refuse if missing. |
| db/30_functions_provisioning.sql:49 | rounding precision fallback `0.01` | kept: the currency's minor unit (amounts are numeric(18,2)); listed in section 6 |
| db/31f/31g (`allowOverride` fallback `true`) | | NOMINEE rule field. Left as is in this increment: the seeded rules all set it. To confirm: absent = not allowed? |
| app/services/loans.py:224-226 | `max 999999999999`, `minMonths 1`, `maxMonths 600` | AMOUNT_LIMITS / TENURE_LIMITS rule. Refuse with `LOAN_RULE_MISSING` if absent. |
| app/services/loans.py:247-254 | fee fallbacks `type fixed`, `timing BEFORE_SUBMISSION` | APPLICATION_FEE rule (required fields) |
| app/services/loans.py:256-262 | interest `/1200`, method fallback | INTEREST rule `method`. A single shared formula per method. |
| app/schemas/loans.py:13/20/30/42 | `requested_tenure_months le=600` | drop the cap. TENURE_LIMITS rule decides. |
| app/schemas/loans.py:15/22/49 | `nominee_ids max_length=10` | NOMINATIONS rule `maxPerLoan` (31g also checks `> 10`) |
| app/schemas/loans.py:34/67/77/91, db/38:50/64 | `payment_mode` default `"CASH"` | setting `cash.default_payment_mode`. Moved to the cash part of the sweep (touches cash flows). |
| db/31h_workflow_engine.sql:244-246 | seed `MGR` / `EMP,MGR` | this is seed data (template JSON). OK as data. |
| db/31f_nominee_override.sql:27/51 | default grant to `MGR` | seed data (role-privilege defaults). OK as data. |

## 2. Auth, users and sessions (PROPOSED)

| Where | Literal | Proposed home |
|---|---|---|
| db/31a_auth_tenant_context.sql:142/164, db/31_functions_api_queries.sql:459/480 | lockout `30 minutes` | new setting `users.lockout_minutes` |
| db/31a:154, db/31:470 | lockout attempts fallback `5` | seeded setting. No fallback. |
| db/31:619 | password history fallback `5` | seeded setting. No fallback. |
| db/31a:198, db/31:1259 | single-session fallback `false` | seeded setting. No fallback. |
| app/services/auth.py:237/284 | `minimum_length=10` | setting `users.password_min_length` (seeded, not read) |
| app/schemas/auth.py:31/36 | `new_password min_length=10` | same setting (validate in service) |
| app/core/config.py:49 | access token `60` min | platform setting `auth.access_token_minutes` (env stays as deploy bootstrap?) |
| flutter/lib/ui/auth/password_change_screen.dart:110 | `< 10` | from the server (`users.password_min_length` in session/settings) |
| flutter/lib/app.dart:19 | session check every `30 s` | setting `users.session_check_seconds` |

## 3. Users, roles and settings administration (PROPOSED)

| Where | Literal | Proposed home |
|---|---|---|
| db/31_functions_api_queries.sql:667/676/688/715/728/729/740/745/799 | `role_code = 'ADM'` (list users, assignable roles, create/update user) | privilege `user.view` / `user.create` / `user.edit` |
| db/31:842 | `role_code = 'LDR'` (settings approval) | privilege `settings.approve` |
| db/12_gap_additions.sql:230/354/377 | `user_holds_role(…,'LDR')` (access change/settings approval) | privilege `settings.approve` / `access.approve` |
| db/12:248/351 | `role_code = 'ADM'` triggers (access change request, settings activation) | privilege. Note Yesu's earlier decision: role-privilege changes by an org admin need no approval. |
| app/routers/tenant_settings.py:23 | `role_code in {'ADM','LDR'}` include pending | privilege `settings.view_pending` |
| flutter/lib/ui/shared/app_shell.dart:202 | `{'ADM','LDR'}` show Settings | privilege `settings.view` from session privileges |
| flutter/lib/ui/tenant/organisation_settings_screen.dart:40-41 | `== 'ADM'` / `== 'LDR'` | privileges `settings.edit` / `settings.approve` |
| db/31:718/780/805 | page size fallback `15` | seeded `ui.page_size`. No fallback. |
| db/31:802 | page size cap `100` | platform setting `ui.page_size_max` |
| db/31:913 | count `1..24` (super admin limit) | platform setting |
| flutter/lib/providers/user_management_provider.dart:22 | `pageSize = 15` | from `ui.page_size` |
| flutter/lib/ui/tenant/organisation_settings_screen.dart:135 | sizes `5..100 step 5` | from setting definition (min/max/step) |
| app/routers/*: `limit default 50, le 200/500` | API list limits | platform setting `api.max_page_size` (or confirm as technical) |

## 4. Members and nominees (PROPOSED)

| Where | Literal | Proposed home |
|---|---|---|
| flutter/lib/providers/member_provider.dart:139 | name length `2..200` | confirm as technical (DB column limit) or MEMBER_RULES |
| db/30_functions_provisioning.sql:303 | preferred channel fallback `'SMS'` | setting `notifications.default_channel` |
| db/30:249-257 | mobile last `10` digits | setting `members.mobile_match_digits` (or technical: Indian numbers) |

## 5. Cash, accounting and other (PROPOSED)

| Where | Literal | Proposed home |
|---|---|---|
| db/30_functions_provisioning.sql:807 | financial-year start month fallback `4` | seeded setting. No fallback. |
| db/17_concurrency_controls.sql:110 | idempotency purge `30 days` | platform setting `system.idempotency_retention_days` |
| db/13_functional_controls.sql:847 | `<> 100` (percent split must total 100) | technical (percent arithmetic). Confirm. |
| flutter/lib/ui/shared/reason_dialog.dart:53/78, app/schemas/*: reason `3..500` | reason length | setting `ui.reason_min_length` / confirm max as technical |

## 6. Domain enums and technical constants (kept; please confirm)

- Status state machines and CHECK lists: loan/recovery/nominee statuses, `DRAFT/RETURNED/…`.
- Channels (`WEB, MOBILE, SUPER_ADMIN, IMPORT, MIGRATION, SYSTEM, DB`), `platform_role` (`SUPER_ADMIN, SUPPORT, BILLING`) and `editable_by` levels.
- Rule onFail codes (`BLOCK/REQUIRE_OVERRIDE/ROUTE_TO_ROLE/WARN`) and rule-check codes.
- Calendar arithmetic: `*12` months/year, `/100` percent, month stepping for schedules.
- HTTP status codes, `HS256`, scrypt parameters (`_KEY_BYTES 32`, 64 MiB, salt 16), the DB pool size.
- API timeout `20 s` (flutter/lib/services/api_error.dart:9), max_length on free-text fields and headers, path regexes.
- Error-catalogue fallback status `422/500` (app/core/errors.py) and the catalogue refresh `300 s`.
- Seed data in db/40-50 (role-privilege defaults, template JSON, demo tenant): this is data, not code.
