# CFMS – Timeline and Cost Estimate

**Basis:** `CFMS_Updated_Scope_v1.7.md` as of 14 Nov 2026 (38 organisation modules, SaaS multi-tenancy limited to Super Admin creating organisations and their first admin user).

**Revised after Yesu's decisions:** no committee voting (single approver), no amount-based approvals, no budgeting, no banks (cash only), multiple halls without advance or cancellation policies, and no subscription billing or self sign-up for now. These reduce the estimate by about 5.5 development person-months.
**Accuracy:** rough order of magnitude (±25%). 21 business decisions are still open. The estimate should be re-baselined after Phase 0 and after the SRS.

## 1. Assumptions

- **Technology:** Python API (for example FastAPI or Django), Flutter client (web first, Android later), PostgreSQL, deployed as containers on Azure or AWS in an Indian region.
- **Payments:** cash only. No payment gateway, UPI, NACH or cheque integration.
- **Workflow:** a custom workflow and action engine as specified. Using an existing open-source engine could save about 6 person-months.
- **Legal and tax features** (GST, payroll statutory deductions, TDS, 80G, FCRA): built as optional toggles. **Member Deposits** and **Chit Funds** are included but depend on legal advice.
- **Languages:** English and Tamil UI, with backend translation tables, language packs and a Super Admin translation screen included. Writing the Tamil translations themselves is excluded (provided by your side or a translator).
- **Data migration:** one existing system with a usable export; custom extraction from an unknown system is excluded.
- **Team:** an Indian development team (agency or in-house) working in two-week sprints, with one product owner on your side available for decisions and UAT.
- **Excluded:** native iOS app, hardware (printers, biometric devices), SMS and WhatsApp message charges, legal fees, registration costs and data entry.

## 2. Effort by Module Group (Full Scope)

"Development" covers backend, frontend and unit tests. "Total" adds QA, business analysis, UI/UX, DevOps and project management, at about 1.55 × development effort.

| No. | Module Group | Development (person-months) | Total (person-months) |
|---:|---|---:|---:|
| 1 | SaaS platform foundation: tenancy and RLS, provisioning, Super Admin console, login and MFA, roles and privilege matrix, module registry and menu, configuration versioning | 10 | 15.5 |
| 2 | Workflow engine, action engine and designer, business rules engine, approval management (single approver, offline approvals, defaulter escalation) | 14 | 21.5 |
| 3 | Accounting core: Chart of Accounts, GL, vouchers, posting rules (both bases), periods, funds, cash management and cash reconciliation | 10.5 | 16.5 |
| 4 | Members: lifecycle, duplicates, nominees, deceased, contributions and donations | 5 | 7.5 |
| 5 | Loans: applications, fees, schedules, repayments, settlement, default, recovery, restructuring, write-off, guarantors | 14 | 21.5 |
| 6 | Member Deposits | 4 | 6 |
| 7 | Chit Fund Schemes | 5 | 8 |
| 8 | Assistance: education, cremation, birthday grants | 3 | 4.5 |
| 9 | Expenses, petty cash, vendors | 3 | 4.5 |
| 10 | Payroll | 3 | 4.5 |
| 11 | Marriage hall (multiple halls, no advance or cancellation policies) | 2.5 | 4 |
| 12 | Assets: purchase, register, maintenance, depreciation, disposal | 4 | 6 |
| 13 | Notifications: SMS (DLT), WhatsApp, email, templates | 3 | 4.5 |
| 14 | Reports, statements, exports and configurable dashboards | 7 | 11 |
| 15 | Audit engine, archival and purge | 3 | 4.5 |
| 16 | Tenant onboarding (Super Admin creates organisation and admin), migration toolkit | 2.5 | 4 |
| 17 | Optional legal and tax toggles | 3 | 4.5 |
| | **Total** | **96.5** | **≈ 150** |

**Full scope: about 140–160 person-months.**

## 3. Suggested Team

| Role | Full Scope | MVP |
|---|---:|---:|
| Technical architect / lead | 1 | 1 |
| Project manager / Scrum master | 1 | 0.5 |
| Business analyst | 1 | 0.5 |
| UI/UX designer | 0.5 | 0.5 (first 3 months) |
| Senior backend developer (Python) | 2 | 1 |
| Backend developer (Python) | 2 | 2 |
| Senior Flutter developer | 1 | 1 |
| Flutter developer | 2 | 1 |
| QA engineer (one with automation skills) | 2 | 1 |
| DevOps engineer | 1 | 0.5 |
| **Team size** | **≈ 13.5** | **≈ 9** |

## 4. Timeline

### Option A – Full scope in one programme

| Phase | Content | Duration | Months (elapsed) |
|---|---|---:|---|
| 0 | Current-system analysis, data profiling, architecture, UX design, SRS | 1.5 months | 1–2 |
| 1 | Platform foundation, login and roles, audit, workflow and rules engines | 3 months | 2–4 |
| 2 | Accounting core, cash management, approvals, members | 2.5 months | 5–7 |
| 3 | Loans, fees, repayments, notifications | 2.5 months | 7–9 |
| 4 | Settlement, default, recovery, restructuring, write-off, deceased, deposits, chit funds | 2.5 months | 9–11 |
| 5 | Assistance, expenses, petty cash, vendors, contributions | 1.5 months | 10–11 (parallel) |
| 6 | Payroll, cash reconciliation, financial statements and reports | 2 months | 11–13 |
| 7 | Marriage hall (multiple halls) | 1 month | 12–13 (parallel) |
| 8 | Assets | 1.5 months | 13–14 |
| 9 | Dashboards, onboarding toolkit, performance and security testing, deployment | 2 months | 14–15 |
| — | Data migration, UAT and pilot go-live with the first organisation | 1.5 months | 14–16 |

**Full go-live: about 14–16 months** from kick-off.

### Option B – MVP first, then releases (recommended)

| Release | Content | Duration | Live By |
|---|---|---:|---|
| **MVP (Release 1)** | Platform foundation (basic tenancy, Super Admin creating organisations and admin users, login, roles, menu), single-approver workflows with the action engine (no visual designer), accounting core with cash management, members, loans with fees, repayments, settlement, default and basic recovery, SMS notifications, core reports and statements, audit, data migration for the first organisation | ≈ 8 months | Month 8 |
| Release 2 | Assistance, expenses, petty cash and vendors, contributions and donations, marriage hall, payroll, restructuring and write-off, WhatsApp, more reports | ≈ 4 months | Month 12 |
| Release 3 | Assets, Member Deposits and Chit Funds, visual workflow designer, configurable dashboards, purge, legal and tax toggles | ≈ 4 months | Month 15–16 |

The MVP puts your own organisation live on its core business (members, loans, cash and accounts) in about 8 months, gives real usage feedback before the rest is built, and spreads the cost.

**MVP effort:** about 38 development person-months, or about 58 person-months in total.

## 5. Cost Estimate

### Rates assumed (per person-month, INR)

| Role | Agency / Vendor Billing | In-house (loaded cost: salary plus about 20% overhead) |
|---|---:|---:|
| Technical architect / lead | ₹3.5 L | ₹2.8 L |
| Project manager | ₹2.8 L | ₹2.0 L |
| Business analyst | ₹2.2 L | ₹1.4 L |
| UI/UX designer | ₹2.0 L | ₹1.2 L |
| Senior developer | ₹2.6 L | ₹1.8 L |
| Developer | ₹1.8 L | ₹1.1 L |
| QA engineer | ₹1.5 L | ₹0.85 L |
| DevOps engineer | ₹2.5 L | ₹1.6 L |
| **Blended average** | **≈ ₹2.4 L** | **≈ ₹1.6 L** |

These are typical mid-tier Indian rates for 2026; tier-1 firms charge more and small firms or freelancers less.

### Build cost

| Option | Effort | Agency | In-house |
|---|---:|---:|---:|
| **MVP (Release 1)** | ≈ 58 person-months | **₹1.2 – 1.6 Cr** | **₹0.8 – 1.05 Cr** |
| Releases 2 + 3 | ≈ 91 person-months | ₹1.9 – 2.5 Cr | ₹1.3 – 1.6 Cr |
| **Full scope (Option A)** | ≈ 150 person-months | **₹3.1 – 4.1 Cr** | **₹2.0 – 2.7 Cr** |

Add a **15% contingency** for open decisions and changes. In-house is cheaper per month, but hiring a full team typically adds 2–3 months before productive work starts.

### Ways to reduce cost

| Change | Approximate Saving |
|---|---:|
| Use an existing open-source workflow engine instead of a custom one | ≈ 6–9 person-months (₹15–20 L agency) |
| Defer Member Deposits and Chit Funds (pending legal advice) | ≈ 14 person-months (₹30–35 L agency) |
| Defer the optional legal and tax toggles | ≈ 4.5 person-months (₹10–12 L agency) |

## 6. Hosting Cost (Monthly, Production)

Assumes Azure Central India / South India or AWS Mumbai / Hyderabad, at ₹85 per USD. Azure and AWS are within about ±10% of each other for this setup.

| Component | Small (launch: up to ~20 organisations, ~300 users) | Medium (~100–300 organisations, ~3,000 users) |
|---|---|---|
| Application containers (Azure Container Apps / AWS ECS Fargate) | 2 small instances | 4–6 instances, autoscaling |
| Managed PostgreSQL | 2 vCPU, 8 GB, single zone with backups | 4 vCPU, 16 GB, high availability (multi-zone) plus read replica |
| Redis cache, queue | Small | Standard |
| Object storage (documents) | ~50 GB | ~1 TB |
| Load balancer / CDN / WAF | Basic | With WAF |
| Monitoring, logs, backup, DR copy | Basic | Full |
| **Production total** | **≈ $300–450 → ₹25,000–40,000** | **≈ $1,500–2,200 → ₹1.3–1.9 L** |
| Non-production (dev, test, staging) | ≈ ₹10,000–15,000 | ≈ ₹25,000–40,000 |
| **All environments** | **≈ ₹35,000–55,000 per month** | **≈ ₹1.5–2.3 L per month** |

### Other running costs

| Item | Estimate |
|---|---|
| SMS (DLT-registered transactional) | ≈ ₹0.15–0.25 per SMS, usually passed on to organisations |
| WhatsApp utility messages | ≈ ₹0.12–0.15 per message (Meta pricing plus provider margin), passed on |
| Email | Negligible at this volume |
| Development tools (code hosting, error tracking, CI) | ≈ ₹10,000–20,000 per month |
| Annual penetration test | ≈ ₹3–6 L per year |
| Maintenance and support after go-live (small team for fixes, upgrades, minor changes) | ≈ 15–20% of build cost per year (₹45–80 L per year for the full scope) |

## 7. Main Risks to the Estimate

| Risk | Effect |
|---|---|
| 21 open business decisions | Late decisions cause rework; settle the MVP decisions in Phase 0 |
| Custom workflow engine complexity | The largest technical item; a proof of concept is recommended in Phase 1 |
| Legal outcome for deposits and chit funds | May remove or change those modules |
| Unknown current system and data quality | Migration effort can grow; known after Phase 0 |
| Flutter Web for data-heavy screens | Validate in Phase 0 with a prototype of a report and a data-entry screen |
| SaaS hardening (security, isolation tests) | Must not be cut, even for the MVP |
