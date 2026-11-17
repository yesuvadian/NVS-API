# CFMS API

Starter API using a router → service → repository/database structure. The first
vertical slice covers organisation listing/provisioning and platform language
packs. Every Super Admin route requires a signed JWT with a `SUPER_ADMIN` role.
MFA is required by default. `CFMS_REQUIRE_PLATFORM_MFA=false` is only for local
development; it does not bypass JWT validation or the Super Admin role check.
Routes also declare explicit platform actions (`can_view`, `can_add`, `can_edit`,
`can_approve`) through `require_platform_permission`, following the method/action
and role permission checks used by `Customer-API/middleware/auth_privilege.py`.
That middleware itself stays in its original app: it depends on Customer API
SQLAlchemy models and its organisation-role tables, which are separate from the
CFMS platform schema.

## Run locally

1. Create a virtual environment and install the project: `pip install -e .`.
2. Copy `.env.example` to `.env` and set the database connection
   (`CFMS_DB_HOST`, `CFMS_DB_PORT`, `CFMS_DB_NAME`, the runtime login
   `CFMS_DB_USER`/`CFMS_DB_PASSWORD`, and the schema owner
   `CFMS_SEED_DB_USER`/`CFMS_SEED_DB_PASSWORD` used by `seed.py` and the
   database tests), JWT, and database-context signing secrets. Nothing about
   the connection is hard-coded; `.env` is gitignored. `CFMS_DB_CONTEXT_SIGNING_KEY` is the hex value returned once
   by the privileged DB function `app.context_signing_key_for_api()`. Before
   using this configuration anywhere beyond a local workstation, set
   `CFMS_REQUIRE_PLATFORM_MFA=true`.
3. Run `python -m app.main` to start with the worker count configured by
   `WEB_CONCURRENCY`. For development with auto-reload, run
   `uvicorn app.main:app --reload --env-file .env --workers 1`.
4. Open `/docs`; protected routes require the platform authentication service to
   issue an access token with the configured issuer, audience, role, MFA claim,
   and expiration.

The API uses the `nvs_app` runtime role. Do not connect it as the schema owner
`nvs`. Database request context is signed against PostgreSQL's canonical
`app.context_payload()` value for each transaction before RLS-protected queries.

The API uses one async Psycopg connection pool per Uvicorn worker. Configure
`CFMS_DATABASE_POOL_MIN` and `CFMS_DATABASE_POOL_MAX` for each worker, and set
`WEB_CONCURRENCY` for the number of worker processes. The example uses a pool
minimum of 5, maximum of 10, and one worker (up to 10 pooled connections per
instance). This API has no separate background database pool, so the
`DB_BACKGROUND_POOL_SIZE` / `DB_BACKGROUND_MAX_OVERFLOW` settings from
CustomerAPI do not apply here.

## Structure

- `app/routers`: HTTP parameters, request/response contracts, dependency wiring
- `app/services`: authorization-independent business rules and validation
- `app/repositories`: SQL statements and row mapping
- `app/db`: async connection pool, per-request transaction, signed DB context
- `app/core`: configuration and platform JWT validation

## Tenant API foundation

Tenant routes use a separate signed JWT from platform Super Admin routes. Set
`CFMS_TENANT_JWT_SECRET`, `CFMS_TENANT_JWT_ISSUER`, and
`CFMS_TENANT_JWT_AUDIENCE` to match the tenant authentication service. Tokens
must carry `sub` (tenant user UUID), `tenant_id`, `role_code`, `channel`
(`WEB` or `MOBILE`), issuer, audience, and expiry. `mfa_verified` is required
when the assigned database role has `requires_mfa=true`. The API confirms the
user, active role assignment, and platform access against the database before
serving a request. It sets and signs the tenant RLS context per transaction;
the tenant ID is never accepted from a route or query parameter.

The first tenant resource module is Member Management:

- `GET /api/v1/members` — search and load-more pagination (`limit`, `offset`,
  `has_more`, `next_offset`)
- `GET /api/v1/members/{member_id}` — member details
- `POST /api/v1/members` — register an applicant and allocate a member number
- `PATCH /api/v1/members/{member_id}` — edit profile fields, with optional
  optimistic concurrency via `X-Expected-Row-Version`

Each endpoint checks its named tenant privilege through `iam.has_privilege`.
Workflow state changes are not exposed as direct member edits. Authentication
issuance, member lifecycle approvals, and the remaining business modules are
subsequent implementation slices; do not issue tenant tokens until an approved
tenant login/activation flow is in place.

## Loan origination API

Tenant loan endpoints consume published loan product/rule versions as read-only
configuration. Workflow and rule editing/publishing remains Super Admin only.
New applications pin the published rule and workflow version IDs used at draft
creation; submission creates a Manager approval request and role-assigned task.
The creator is excluded from their own approval inbox.

- `GET /api/v1/loan-types` — enabled loan types with published terms
- `POST /api/v1/loans/eligibility` — member, amount, tenure, nominee, and
  estimated flat-interest checks
- `GET /api/v1/loans` — filtered, load-more application list
- `POST /api/v1/loans` — create an application draft and calculate its fee
- `GET /api/v1/loans/{loan_id}` — application detail
- `POST /api/v1/loans/{loan_id}/submit` — recheck eligibility and submit to the
  Manager workflow
- `GET /api/v1/loan-approvals/inbox` — current approver's loan tasks
- `POST /api/v1/loans/{loan_id}/application-fee` — collect and post a fee receipt.
- `POST /api/v1/loan-approvals/{approval_request_id}/decision` — record an online
  approval, rejection, or return. Reject/return requires a reason.
- `POST /api/v1/loans/{loan_id}/disbursements` — prepare a payment voucher.
- `POST /api/v1/loans/{loan_id}/disbursements/{disbursement_id}/release` — pay
  the voucher, require payee acknowledgement, and create the schedule.
- `POST /api/v1/loans/{loan_id}/repayments` — post a cash receipt and allocate
  it interest then principal across due instalments.

- `PATCH /api/v1/loan-applications/{loan_id}` — change a draft or returned
  application (eligibility is checked again).
- `POST /api/v1/loan-applications/{loan_id}/withdraw` — withdraw before approval.
- `POST /api/v1/loans/{loan_id}/cancellation`, `GET /api/v1/loan-cancellations/{id}`,
  `POST /api/v1/loan-cancellations/{id}/decision` — cancel an approved loan that is
  not disbursed (Manager approval).
- `POST /api/v1/loan-approvals/{id}/offline-decision` — record a decision given
  offline (approver, evidence type, decision date); `.../verification` — the
  approver confirms it.
- `POST /api/v1/loans/{loan_id}/settlement-quote` — early or default settlement
  quote; optional body `{"interest_waiver", "waiver_reason"}`.
- `POST /api/v1/loan-repayments/{id}/reversal`, `GET /api/v1/loans/{loan_id}/repayment-reversals`,
  `GET /api/v1/repayment-reversals/{id}`, `POST /api/v1/repayment-reversals/{id}/decision`
  — reverse the latest receipt of a loan.

Defaulted-loan servicing (router `loan_servicing`):

- Recovery cases: `GET /recovery-cases`, `GET /recovery-cases/{id}`,
  `POST /recovery-cases/{id}/assign`, `/contacts`, `/status`.
- Waivers: `GET|POST /loans/{loan_id}/waivers`, `GET /loan-waivers/{id}`,
  `POST /loan-waivers/{id}/decision`.
- Cooling-off override: `POST /members/{member_id}/cooling-off-overrides`,
  `GET /cooling-off-overrides/{id}`, `POST /cooling-off-overrides/{id}/decision`.
- Write-off: `POST /loans/{loan_id}/write-off`, `GET /loan-write-offs/{id}`,
  `POST /loan-write-offs/{id}/decision`, `POST /loans/{loan_id}/written-off-recoveries`.

- Guarantors: `GET|POST /loans/{loan_id}/guarantors`, `DELETE /loan-guarantors/{id}`,
  `POST /loan-guarantors/{id}/replacement`, `GET /guarantor-replacements/{id}`,
  `POST /guarantor-replacements/{id}/decision`.
- Cash above the limit: `POST /loan-disbursements/{id}/cash-approval`. Disbursement
  bodies accept `payment_mode` and `payment_reference`; later tranches use the same
  endpoint when the loan type allows tranches.
- Restructuring: `GET|POST /loans/{loan_id}/restructures`, `GET /loan-restructures/{id}`,
  `POST /loan-restructures/{id}/decision`.
- Deceased member: `POST /loans/{loan_id}/deceased-decision`,
  `GET|POST /loans/{loan_id}/transfers`, `POST /loans/{loan_id}/transfers/decision`.
- Migrated loans: `GET /migration-reviews`, `POST /migration-reviews/{id}/decision`.
- Documents: `GET|POST /loans/{loan_id}/documents` (lists missing required types),
  `DELETE /loan-documents/{id}`. Files are stored by the client; the API keeps the
  metadata and storage key.
- Sanction letter: `GET /loans/{loan_id}/sanction-letter` (`?format=html` for a
  printable page).

Loan reports (router `loan_reports`, privilege `mgmt_report.view`):
`GET /loan-reports/outstanding`, `/interest?from&to`, `/ageing`,
`/demand-collection?from&to`, `/due-list`, `/overdue-list?min_days`,
`/restructured-written-off`, `/guarantor-exposure`.

Repayments allocate late fees, penalty, overdue interest and principal, then the
current instalment, in the loan's configured order; an amount above the dues
reduces principal and regenerates the schedule. Business rules, maker-checker and
approver roles are enforced in PostgreSQL. Workflow and rule configuration
remains Super Admin only.

## Tests and reports

`python -m pytest` runs the unit tests and, when the database in `.env` is
reachable, the PostgreSQL integration tests. Each database test provisions its
own throw-away organisation inside one transaction and rolls it back, so the
local data is never changed. Generate the HTML test report and coverage report
with:

    python -m pytest --html=reports/test-report.html --self-contained-html --cov --cov-report=html:reports/coverage --cov-report=term
