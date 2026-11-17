# COMMUNITY FINANCIAL MANAGEMENT SYSTEM (CFMS)
## Business Requirements, Functional Scope & Technical Architecture
**Version 1.7 – Consolidated Scope**

### Change Log

| Version | Date | Changes |
|---|---|---|
| 1.6 | — | Consolidated business scope and architecture |
| 1.7 | 14 Nov 2026 | Requirements review applied. Added: modules, roles and privilege matrix; default home page and dashboards as modules; module registry with SQL-only `is_menu`; legal and tax features as organisation settings (off by default); rounding settings; Member Deposits and Chit Fund Schemes (optional, with legal warnings); accounting basis and posting rules; cash management and cash-only operation; loan statuses, eligibility, guarantors, disbursement controls, restructuring, write-off and recovery; membership lifecycle; restricted funds and contributions; SaaS multi-tenancy; data migration; measurable non-functional requirements; archival and purge. Decided: PostgreSQL; rule-driven loan types; non-refundable optional application fees; lump-sum payments reduce principal; nominee mandatory for first loan; default after 2 months (configurable) with full amount plus penalty; single approver (Manager) with no committee or voting; no top-up loans; no banks; no budgeting; multiple halls without advance or cancellation policies; SaaS limited to Super Admin creating organisations and their first admin. Early settlement charges and waivers rule-driven per loan type; cooling-off, eligibility, guarantors and restructuring as organisation settings; no income-tax cash limits, no cash-in-hand or single payment limits; working date selected at the top of the screen. Cash basis only (no accrual); one common cash account with the cash position in the top bar; standard Chart of Accounts; financial year April–March by default; exports in Excel and PDF wherever applicable. Org admin appoints and replaces all roles; roles permitted to record offline decisions are configurable; offline approval evidence is a configurable dropdown with optional upload; branches moved to future scope. Organisation administrator user created by default with each organisation; users have separate Web and Mobile platform access options (either, both or neither) that control login access, with activation-link credential delivery. Workflows, business rules and actions configurable by the Super Administrator only (never by the organisation administrator), separately for each organisation. Modules enabled per organisation by the Super Administrator only. Every new organisation provisioned with default values for all settings (Section 4.10). Workflows and rules JSON-driven: stored per organisation as versioned `jsonb`, validated against a JSON Schema, edited only by the Super Administrator through a designer that produces JSON, with JSON view, diff, import and export; full audit history of every version (who, when, reason, effective date), restore as a new version, and each transaction stamped with the workflow and rule versions it used. Record-level audit history on all data: field-level old and new values, user, role, actual time and working date, channel (web, mobile), reason, append-only, with a History tab on every record and a central Audit Log. English and Tamil language support from backend translation tables (page names, labels, messages, master data), versioned language packs, English fallback, missing translations report, Excel export and import, managed by the Super Administrator only. Exception management with a central error code catalogue (`CFMS-<MODULE>-<NNNN>`), categories, severity, a standard API error response with correlation id, logging, alerting and retry rules. Search, refresh and Excel/PDF export on all lists, queues, reports, logs and dashboards. Organisation administrator can create custom roles within the enabled modules and the Super Administrator's privilege ceiling. Super Administrator registers and approves new actions, provides default modules, roles and privileges to each organisation, and requests and makes all workflow and rule changes; action failures handled by enforced validation with rollback and a failure log (notifications only are retried). Technology stack otherwise technology-neutral |

---

## 1. Project Overview

The Community Financial Management System (CFMS) will centralise the organisation's financial, administrative and operational activities.

CFMS will be delivered as a multi-tenant SaaS product, deployable on Microsoft Azure or AWS, serving many community organisations from one platform (Section 35). In this document, "the organisation" means a single tenant.

It is a comprehensive financial management system, not merely a loan management application. It will cover:

- Community member management.
- Loan management and application fees.
- Repayments, partial payments and early settlements.
- Default and recovery management.
- Education and other community assistance.
- Employee payroll and daily expenses.
- Marriage hall bookings.
- Community asset management.
- General Community Fund.
- General Ledger and double-entry accounting.
- Financial and management reporting.
- Flexible approvals and workflow automation.
- Audit management.

### 1.1 Application Users

Only authorised internal personnel will access CFMS. Community members and borrowers will not have login accounts.

Employees will interact with members and perform transactions on their behalf. Members may receive SMS, WhatsApp or email notifications through their registered contact details.

Leadership members may log in if they wish, but the system must support offline approval processes without requiring them to use the application.

Every person who holds a role in the organisation (employees, managers, accountant, leadership, auditor, administrator) is recorded as a **user**. Only users given **platform access** (Web, Mobile or both) get a login and can use the application on the platforms granted to them; other users exist as records only, for example Leadership members who approve offline, so that they can be named as approvers, assigned roles and kept in history (Section 3.6.1).

---

## 2. Core System Architecture

CFMS should be configuration-driven and built around reusable engines and services.

| No. | Component | Responsibility |
|---:|---|---|
| 1 | Organisation Configuration | Organisation policies and settings |
| 2 | Workflow Engine | Workflow definitions, stages and transitions |
| 3 | Workflow State Action Engine | Executes configured actions at workflow stages |
| 4 | Business Rules Engine | Calculations, eligibility and conditional rules |
| 5 | Approval Management Engine | Online, offline, verbal and meeting approvals |
| 6 | Financial Accounting Engine | General Ledger and double-entry accounting |
| 7 | Asset Register | Community-owned assets |
| 8 | Notification Engine | SMS, WhatsApp, email and system notifications |
| 9 | Audit Engine | Activity history and accountability |
| 10 | Reporting Engine | Financial and operational reports |

### 2.1 Configuration-Driven Principles

- Changing loan interest rates must not require code changes.
- Changing approval limits must not require code changes.
- Replacing a manager must not require workflow redesign.
- Adding a workflow stage should be possible through configuration.
- Adding a registered action should make it available in the Workflow Designer.
- Existing transactions must retain the configuration and workflow versions under which they were initiated.
- Changes to policies must have effective dates, version history and audit records.
- Workflows, business rules and actions are configured only by the Platform Super Administrator (Section 35.4). Organisation users, including the organisation administrator, cannot configure them, because this needs detailed knowledge of the engine.

---

## 3. Modules, Roles and Privileges

### 3.1 Roles

The system will support six primary roles within each organisation (tenant). Roles are templates of privileges; the final privileges of each role are configurable through Permission Management. Platform roles above the organisation, including the Platform Super Administrator who controls each organisation's workflows and business rules, are defined in Section 35.3.

| Code | Role | Responsibilities |
|---|---|---|
| EMP | Community Employee | Member registration, loan applications, fee and repayment collection, bookings, expense and asset requests, recording offline decisions where authorised |
| MGR | Manager | Verification, supervision, operational management, employee management, and final approval of loans, assistance, waivers, overrides and other operational requests |
| ACC | Accountant | Chart of Accounts, journals and vouchers, payroll preparation, depreciation, cash reconciliation, period closing and financial reporting |
| LDR | Leadership Team | Organisation oversight, policy approval, payroll approval, high-value approvals and financial supervision |
| AUD | Auditor | Read-only access to financial, operational and audit information |
| ADM | System Administrator | Tenant-level administration: user accounts, role assignment, organisation settings, branding, notification templates, and privileges within the default modules and roles provided by the Platform Super Administrator; no access to configure workflows, business rules or actions (Super Administrator only); no access to create or approve financial transactions |

**Custom roles:** in addition to these six standard roles, the organisation administrator can create custom roles for the organisation (for example "Cashier", "Hall Supervisor" or "Field Officer").

- A custom role has a code, name, description, status (Active or Inactive) and a default home page.
- Its privileges are chosen from the privilege matrix, limited to the modules enabled for the organisation (Section 3.9.1) and to the privileges the Super Administrator has provided (Section 35.4). A custom role can never receive more than this ceiling.
- A custom role can be created by copying a standard or another custom role and then adjusting its privileges.
- Custom roles are used in the same way as standard roles: users are assigned to them, and they follow the segregation-of-duties rules in Section 3.5. Workflow stages and approvals can be assigned to a custom role only by the Super Administrator.
- The six standard roles cannot be deleted. A custom role can be made inactive, but not deleted, once it has been assigned to any user; its history is kept.
- Creating, changing or deactivating a custom role is audited, with its privileges before and after.

### 3.2 Privilege Types

| Code | Privilege | Meaning |
|---|---|---|
| V | View | View records and reports, and export where permitted |
| C | Create | Create new records or transactions |
| E | Edit | Modify records before they are approved or posted |
| A | Approve | Verify, approve, reject or return records at the stages assigned to the role |
| D | Delete | Cancel, void or deactivate records with a reason; posted financial transactions are never deleted and are corrected only by reversal |

Approval privileges are further limited by the configured approval limits, workflow stage assignments and delegation rules.

### 3.3 Module Privilege Matrix

Default privileges per module. "—" means no access.

| No. | Module | EMP | MGR | ACC | LDR | AUD | ADM |
|---:|---|---|---|---|---|---|---|
| 1 | Organisation Management | — | V | V | V A | V | V C E D |
| 2 | User & Role Management | — | V | — | V A | V | V C E D |
| 3 | Member Management | V C E | V E A D | V | V | V | — |
| 4 | Loan Management | V C E | V A | V | V | V | — |
| 5 | Loan Application Fee Management | V C | V A D | V | V | V | — |
| 6 | Loan Repayment Management | V C | V A D | V | V | V | — |
| 7 | Early Full Settlement | V C | V A | V | V | V | — |
| 8 | Default & Full Settlement Management | V C | V E A | V | V | V | — |
| 9 | Nominee Management | V C E | V A | — | V | V | — |
| 10 | Deceased Member Management | V C | V A | V | V | V | — |
| 11 | Education Assistance | V C E | V A | V | V | V | — |
| 12 | Cremation Assistance | V C E | V A | V | V | V | — |
| 13 | Birthday Grants | — | V C E | V | V A | V | — |
| 14 | Daily Expense Management | V C E | V A | V | V A | V | — |
| 15 | Employee Payroll | — | V A | V C E | V A | V | — |
| 16 | Marriage Hall Management | V C E | V A D | V | V | V | — |
| 17 | Community Asset Management | V | V C E | V | V | V | — |
| 18 | Asset Purchase & Approval | V C E | V A | V | V A | V | — |
| 19 | Asset Maintenance & Depreciation | V C | V A | V C E | V | V | — |
| 20 | Asset Transfer & Disposal | V C | V A | V | V A | V | — |
| 21 | General Community Fund | — | V | V | V | V | — |
| 22 | General Ledger | — | V | V | V | V | — |
| 23 | Chart of Accounts | — | V | V C E D | V A | V | — |
| 24 | Journal & Voucher Management | — | V | V C E D | V A | V | — |
| 25 | Trial Balance | — | V | V | V | V | — |
| 26 | Financial Statements | — | V | V | V | V | — |
| 27 | Cash Reconciliation | — | V A | V C E | V | V | — |
| 28 | Financial Period Management | — | V | V C E | V A | V | — |
| 29 | Financial Reports | — | V | V | V | V | — |
| 30 | Management Reports & Analytics | — | V | V | V | V | — |
| 31 | Workflow Engine | — | V | — | V | V | V |
| 32 | Business Rules Engine | — | V | V | V | V | V |
| 33 | Flexible Approval Management | V C | V C A | — | V A | V | V E |
| 34 | Notification Engine | V C | V | — | — | V | V C E D |
| 35 | Audit Management | — | V | V | V | V | V |
| 36 | Member Deposits | V C | V A D | V | V | V | — |
| 37 | Chit Fund Schemes | V C | V A D | V | V | V | — |
| 38 | Contributions & Donations | V C | V A D | V | V | V | — |
| D1 | Employee Dashboard | V | V | — | — | — | — |
| D2 | Manager Dashboard | — | V | — | V | — | — |
| D3 | Accountant Dashboard | — | — | V | V | V | — |
| D4 | Leadership Dashboard | — | — | — | V | — | — |
| D5 | Auditor Dashboard | — | — | — | — | V | — |
| D6 | Administration Dashboard | — | — | — | — | — | V |

Notes on the matrix:

- **Approvals:** there is no committee voting. Each approval is given by a single authorised approver, irrespective of amount. By default the Manager is the final approver for loans, assistance, settlements, waivers, cooling-off overrides and write-offs. The approver must be a different person from the requester.
- **Fees, repayments and hall bookings:** MGR "D" means cancelling an unposted receipt or booking with a reason. After posting, only a reversal is allowed.
- **Payroll:** ACC prepares, MGR verifies and LDR approves.
- **Journals and Chart of Accounts:** ACC creates; LDR approves manual journals, Chart of Accounts changes and period reopening.
- **Configuration modules (1, 2):** ADM makes changes, including appointing and replacing role holders, within the modules, roles and privileges provided by the Super Administrator.
- **Workflow and rules (31, 32):** workflows, business rules and approval limits are controlled by the Platform Super Administrator for each organisation (Section 35.4). The Super Administrator requests and makes all workflow and rule changes; ADM and LDR can view them but cannot configure workflows, rules or actions.
- **Approval Management:** EMP "C" means recording an offline decision, and only where the employee is authorised to do so.
- **Notifications:** EMP "C" means sending an ad-hoc notification to a member.
- **Dashboards (D1–D6):** dashboards are modules and are granted through this matrix like any other module (see Section 3.8). The rows shown are the default set; more dashboard modules can be added.
- **Audit:** MGR sees operational audit records, ACC sees financial audit records, ADM sees system and security logs, and AUD and LDR see all audit records.

### 3.4 Data Visibility Rules

- **Payroll:** salary and payroll data are visible only to MGR, ACC, LDR and AUD.
- **Identity data:** identity numbers and sensitive personal data are masked by default and shown in full only to roles with an explicit privilege.
- **Exports:** exporting payroll, personal data or full member lists requires a separate export privilege and is audited.

### 3.5 Segregation of Duties

- No user may approve a request that they created, requested or benefit from (for example, a leader approving their own birthday grant).
- For offline approvals, Requested By, Approved By and Recorded By must be different people where the approval policy requires it.
- The payroll preparer cannot approve the same payroll run.
- The creator of a manual journal cannot approve it.
- A user who collected cash cannot reconcile the same cash account for the same period.
- ADM cannot create, approve or post financial transactions, and configuration changes made by ADM require LDR approval before taking effect.
- Platform staff cannot create, edit or approve tenant transactions, and any access to tenant transaction or personal data is break-glass access approved by the tenant (Section 35.3).
- AUD is read-only and cannot hold any other role at the same time.
- The system must block incompatible role combinations and record any authorised exceptions.

### 3.6 User Management Features

- User registration, activation and deactivation.
- Role assignment and changes. The organisation's System Administrator (org admin) appoints, changes and replaces the holders of all organisation roles; every change is audited.
- Employee and manager replacement.
- Leadership membership management.
- Permission management at module and privilege level.
- Creation and maintenance of custom roles by the organisation administrator (Section 3.1).
- Immediate access revocation.
- Pending task reassignment.
- User activity and role-change history.

#### 3.6.1 User Creation and App Access

- When the Platform Super Administrator creates an organisation, an **organisation administrator user** (ADM role) is created with it by default (Section 35.5).
- The organisation administrator creates all other users and assigns their roles. Users are created only by the organisation administrator; there is no self sign-up.
- Each user has a **Platform access** setting with two separate options, chosen by the organisation administrator. Not every user gets both:
  - **Web access** (`web_access`): the user can sign in to the web application.
  - **Mobile access** (`mobile_access`): the user can sign in to the mobile app.
  - **Neither:** the user is a record only, with no login. They can still hold a role, be named as an approver in offline approvals, appear in reports and history, and be selected in workflows.
- Default for a new user: Web access on, Mobile access off. The organisation administrator user is created with Web access on.
- A user who tries to sign in on a platform they do not have is refused with a clear message; the attempt is recorded in the sign-in history.
- Removing a platform immediately ends the user's active sessions on that platform (and signs out registered mobile devices when Mobile access is removed). Adding the first platform to a record-only user sends an activation link. All changes are audited.
- What a user can do is the same on both platforms and is decided by their roles and privileges; screens not yet available on mobile are simply not shown there.
- A record-only user cannot be the recorder of any transaction or approval.
- Users can be filtered by platform access, and a report lists users with web, mobile, both or no access.

User fields: name, mobile number, email, role(s), status (Active, Inactive), Web access (yes/no), Mobile access (yes/no), username (when either access is on), linked employee record (optional, for payroll), created by and date.

Credential delivery (users with Web or Mobile access):

- When a user with platform access is created, or a record-only user is given access, the system sends a one-time activation link by SMS or email to the user's registered mobile number or email. The link expires after a configurable period (default 48 hours) and can be re-sent by the organisation administrator.
- The user sets their own password on activation (and MFA where required, Section 3.10). Administrators never see or set passwords.
- The username is the user's mobile number or email.

### 3.7 Access Rules

- Every system user must have an individual account; shared accounts are prohibited.
- Leadership members are not required to log in for offline approvals.
- Workflow assignments must use dynamic roles rather than fixed individual names.
- Historical actions must retain the original actor's identity and role at the time.
- Deactivated users must not lose historical records.
- Multi-factor authentication is mandatory for ADM, ACC, MGR and LDR users.
- Permissions are implemented as named privileges (for example `loan.approve`, `journal.create`) so that roles can be adjusted without code changes.

### 3.8 Default Home Page per Role

Each role has a default module that is displayed as the home page after login. By default this is the role's dashboard (Section 32), which shows the role's pending work first and links to the role's most-used module.

**Dashboards are modules.** Any number of dashboard modules can be defined (for example a Loan Portfolio Dashboard, Hall Bookings Dashboard or Asset Dashboard), in addition to the default set. Each dashboard module:

- Is registered as a module with its own code, name, widgets and data sources.
- Is granted to roles through the privilege matrix (Section 3.3), so a role can have several dashboards.
- Shows each widget only if the user holds View privilege on the underlying module.
- Can be selected as a role's default home page.
- Is created, changed and retired through configuration, without code changes, using a library of approved widgets (counts, lists, charts, KPIs and pending-task panels). New widget types require development.
- Is versioned and audited like other configuration.

| Role | Default Home Page | Shows First | Primary Quick Actions |
|---|---|---|---|
| Community Employee | Employee Dashboard | Today's due repayments, pending tasks, returned applications | Find member, collect repayment, new loan application, new hall booking, new expense |
| Manager | Manager Dashboard | Items awaiting verification, offline decisions awaiting recording, provisional approvals awaiting confirmation | Open approval queue, view overdue and defaulted loans |
| Accountant | Accountant Dashboard | Unposted vouchers, cash position and day-end status, current period status | New journal or voucher, cash reconciliation, Trial Balance |
| Leadership Team | Leadership Dashboard | Pending high-value and policy approvals, General Fund balance | Open approval queue, management reports |
| Auditor | Auditor Dashboard | Audit exceptions, recent approval records | Trial Balance, financial reports, audit log search |
| System Administrator | Administration Dashboard | Pending user requests, failed actions and notifications | User management, role management, organisation settings |

Rules:

- **Configurable:** the System Administrator can change the default home page of each role to any module or dashboard that the role can view. A change takes effect at the user's next login and is audited.
- **Users with several roles:** the user has one primary role, set by the administrator, and lands on that role's home page. The user can switch role context from the header without logging out, and each role's dashboard shows only data that role is permitted to see.
- **Personal preference:** a user may set a different home page from the modules their roles permit. This preference never grants additional access.
- **Fallback:** if the configured home page is not accessible to the user, the system shows the dashboard of the user's primary role. If no dashboard is accessible, it shows a page with the user's pending tasks.
- **Pending work first:** a home page must always show the count of the user's pending approvals and tasks, regardless of role.

### 3.9 Module Registry and Side Menu (is_menu)

Every module, dashboard and report screen is registered in a **Module Registry** table. Each entry has an `is_menu` flag that decides whether the module is visible as a module anywhere in the user interface.

Module Registry fields:

| Field | Description |
|---|---|
| module_code | Stable unique code (for example `LOAN`, `LOAN_FEE`, `DASH_MANAGER`) |
| module_name | Display name |
| module_type | Module, Dashboard, Report, Configuration or Platform |
| parent_module_code | Parent menu group or module, for nested menus |
| is_menu | `true`: the module is shown in the side menu and in module lists. `false`: the module is not shown anywhere in the UI as a module |
| menu_order | Sort order within its parent group |
| icon | Icon name shown in the menu |
| route | Screen or page address used for navigation |
| is_active | Whether the module is available at all |
| plan_feature_code | Reserved for future subscription plans (Section 35.7); not used in the current scope |

**is_menu = true:** the module appears in the side menu, in module lists (such as the privilege matrix, home-page selection and dashboard configuration screens) and in search, provided the module is active, enabled for the organisation (Section 3.9.1) and the user holds View privilege on it. A menu group with no visible children is hidden.

**is_menu = false:** the module does not appear anywhere in the UI as a module: not in the side menu, not in any module list, and not in any administration or configuration screen. Such modules are sub-functions that exist only as part of a parent screen (for example application-fee collection inside the loan application). They:

- Are opened only from within their parent module's screens or workflow tasks.
- Inherit their privileges from the parent module (`parent_module_code`), because they are not listed in the privilege matrix.
- Still have every screen and API call checked against the inherited privileges; `is_menu` controls visibility, not security.

**Maintained in the database only:**

- `is_menu` and the other Module Registry fields are set only directly in the database through SQL. There is no UI screen or toggle to change them, for any user, including the Platform Super Administrator and tenant administrators.
- The registry is platform-wide; there are no per-organisation or per-role overrides of `is_menu`.
- Changes must be made through version-controlled database scripts deployed with the application release, so that every change is reviewed and traceable.

#### 3.9.1 Module Enablement per Organisation

Which modules each organisation can use is decided by the Platform Super Administrator only.

- The Super Administrator selects the enabled modules when creating an organisation and can enable or disable modules later from the Super Admin console. Organisation users, including the organisation administrator, cannot enable or disable modules.
- Each organisation can have a different set of modules (for example one organisation uses Loans and Marriage Hall, another Loans and Payroll only).
- Core modules are always enabled and cannot be disabled: organisation settings, user and role management, accounting core and cash, members, audit and the administration dashboard.
- A disabled module is hidden for that organisation everywhere: side menu, module lists, privilege matrix, home-page selection, dashboards, reports, notifications and APIs. Its child modules (`is_menu = false`) are disabled with it.
- The organisation administrator can grant privileges only on enabled modules.
- Disabling a module keeps all its data; enabling it again restores access. A module with open items (for example active loans, open deposit accounts or running chit groups) cannot be disabled until they are closed.
- Optional modules with legal conditions (Member Deposits, Chit Funds) and purge follow the same rule, with the extra conditions in their own sections.
- Every enable or disable records who made the change, the reason and the date, in both the platform and the organisation's audit logs.

### 3.10 Authentication and Login

- Only users with Web or Mobile access (Section 3.6.1) can sign in, and only on the platform they have been granted. They sign in with a username (mobile number or email) and password.
- Multi-factor authentication for privileged roles (Section 3.7) uses an authenticator app (TOTP) by default, with SMS one-time password (OTP) as an organisation-configurable alternative.
- Password reset uses an OTP sent to the user's registered mobile number or email, and is audited.
- Password policy: minimum 10 characters, not one of the user's last 5 passwords, and no forced periodic change unless the organisation configures it.
- First login and administrator-issued resets require a password change.
- Sign-in history (time, device, IP address, success or failure) is kept for each user.

### 3.11 Branches and Locations *(future scope)*

Branches are not needed at this time: each organisation operates as a single location. The data model keeps a single default branch per organisation so that branches can be added later without migration. The points below are design guidance for that future release only.

- Branches are optional; an organisation with one office uses a single default branch.
- Each user is assigned to one or more branches.
- Members, loans, receipts, cash, hall bookings and assets record the branch where they were created.
- Data visibility can be restricted by branch: Employees and Managers see only their branches; Accountant, Leadership and Auditor see all branches unless configured otherwise.
- All reports can be filtered by branch, and consolidated across branches.
- The General Ledger is maintained for the organisation as a whole, with branch as a reporting dimension.

---

## 4. Organisation Configuration

The organisation configuration module controls policies and settings across CFMS.

### 4.1 Loan Configuration

- Loan categories and interest rates.
- Flat interest calculation.
- Minimum and maximum loan amounts.
- Repayment period limits.
- Application fees per loan type (optional) and waivers; fees are non-refundable.
- Nominee rules (mandatory for a member's first loan; thresholds for later loans).
- Early settlement policies.
- Default and cooling-off periods.

### 4.2 Assistance Configuration

- Education assistance amounts and deadlines.
- Cremation assistance amounts.
- Birthday grants.
- Eligibility conditions and approval requirements.

### 4.3 Expense and Payroll Configuration

- Expense categories and approving role.
- Payroll components, frequency and approval rules.

### 4.4 Marriage Hall Configuration

- Member and non-member rates, per hall.
- Weekday, weekend and public holiday rates.
- Half-day and full-day rates.
- Additional charges and security deposits.
- Hall master: multiple halls, each with its own name, capacity, facilities, rates and status (active or under maintenance).
- Advance-payment and cancellation-charge policies are not in the current scope.

### 4.5 Asset Configuration

- Asset categories.
- Purchase approving role.
- Depreciation methods and useful life.
- Maintenance categories.
- Transfer and disposal approval policies.

### 4.6 Financial Configuration

- Chart of Accounts.
- One common cash account per organisation. Bank accounts are not used; the design keeps them available as a future option.
- General Fund configuration.
- Accounting basis: cash basis only (Section 21.5).
- Financial year (organisation setting, default 1 April to 31 March) and monthly accounting periods.
- Journal posting rules.

### 4.7 Workflow and Approval Configuration

All settings in this section are configured by the Platform Super Administrator only. The organisation administrator and other organisation users can view them but cannot change them.

- Workflow definitions, stages, actions and transitions.
- Approving role and approval methods.
- Roles permitted to record verbal and other offline decisions (configuration setting; by default Employee and Manager).
- Offline approval evidence types: a configurable dropdown list (for example Verbal instruction, Meeting, Phone call, Signed paper). The person recording selects one; uploading a document is optional, not mandatory.
- Delegation rules, and escalation rules for defaulters.

All significant configuration changes must be versioned and audited.

### 4.8 Legal and Tax Compliance Settings

CFMS is designed primarily for NGOs and community organisations, where tax and statutory compliance features are often not applicable. All legal and tax features are therefore **optional organisation-level settings, disabled by default**.

- The Platform Super Administrator enables or disables each feature when creating the organisation (Section 35.5), and can change it later at the organisation's request.
- Tenant users, including the organisation's System Administrator, cannot enable or disable these features.
- When a feature is disabled, its fields, calculations, accounts, screens and reports are hidden and play no part in transactions.
- When a feature is enabled, its configuration (registration numbers, rates, thresholds, accounts) is completed by the organisation's Accountant, and its reports become available.
- Enabling or disabling a feature takes effect from an effective date, never changes existing posted transactions, and is audited.

| Setting | Default | What It Enables When Turned On |
|---|---|---|
| GST | Off | GSTIN, GST rates by service (for example hall rental, application fees), tax invoices, GST Payable accounts and GST reports |
| Payroll statutory deductions | Off | TDS on salary, Provident Fund, ESI, Professional Tax and Labour Welfare Fund calculations, payslip lines, liability accounts and statutory reports |
| TDS on payments | Off | TDS deduction on vendor and service payments, TDS Payable account and TDS reports |
| Donation receipts (80G) | Off | Donor records, 80G-compliant donation receipts and donation reports |
| Member deposits | Off | Member Deposits module (Section 9). Legal advice is strongly recommended before enabling (see legal warning) |
| Chit funds | Off | Chit Fund Schemes module (Section 10). Legal advice and registration are strongly recommended before enabling (see legal warning) |
| Foreign contributions (FCRA) | Off | Separate tracking, bank account and reporting of foreign contributions |

Rates and rules for each feature are maintained as versioned configuration, so that changes in law require configuration updates, not code changes.


### 4.9 Rounding Settings

Rounding of calculated amounts is an organisation-level setting. It is configured when the organisation is created and can be changed later by the organisation's Accountant with Leadership approval. Changes are versioned, take effect from an effective date and never change existing loans, schedules or posted transactions.

**Rounding modes**

| Mode | Behaviour | Example (precision ₹1) |
|---|---|---|
| Floor | Always round down | ₹15,285.71 → ₹15,285 |
| Ceiling | Always round up | ₹15,285.21 → ₹15,286 |
| Nearest (half-up) | Round to nearest; exact halves go up | ₹15,285.50 → ₹15,286; ₹15,285.49 → ₹15,285 |
| None | Keep two decimals (paise) | ₹15,285.71 → ₹15,285.71 |

**Precision options:** ₹0.01 (two decimals), ₹0.50, ₹1, ₹5 and ₹10.

**Where rounding applies** (mode and precision set separately for each)

| Area | Default Mode | Default Precision |
|---|---|---|
| Loan instalments (EMI) | Floor | ₹1 |
| Interest amounts | Nearest | ₹1 |
| Early settlement and default settlement amounts | Nearest | ₹1 |
| Application fees (percentage-based) | Nearest | ₹1 |
| Marriage hall charges | Nearest | ₹1 |
| Payroll net salary | Nearest | ₹1 |
| Depreciation | None | ₹0.01 |
| Assistance amounts | None (configured as fixed amounts) | ₹0.01 |

Defaults are proposed and are copied from the platform template when the organisation is created.

**Calculation rules**

- Internal calculations always use full precision. Rounding is applied only to the final amount that is shown to the member, charged, paid or posted.
- Intermediate results are never rounded and then reused in further calculations.
- Amounts entered by users (for example cash received) are recorded exactly as entered and are not rounded.
- All posted journal amounts are stored with two decimals.
- For each instalment, the interest component is rounded using the interest rule, and the principal component is the rounded instalment less the rounded interest.

**Where the rounding difference goes**

| Situation | Treatment |
|---|---|
| Loan repayment schedule | The difference between the total of rounded instalments and the total repayable (principal plus total interest) is added to or deducted from the **final instalment**, so that the loan total is exact |
| Payroll | The difference between net salary and its rounded value is posted to a **Rounding Off** account |
| Any other computed amount where components must still balance | Posted to the Rounding Off account |
| Single charged amounts (fees, hall charges, settlement amounts) | The rounded amount is the amount charged; no difference arises |

Example: principal ₹1,00,000 at 12% flat for 7 months gives total interest ₹7,000 and an unrounded instalment of ₹15,285.71.

| Mode (₹1) | Instalments 1–6 | Final Instalment | Total |
|---|---:|---:|---:|
| Floor | ₹15,285 | ₹15,290 | ₹1,07,000 |
| Ceiling | ₹15,286 | ₹15,284 | ₹1,07,000 |

Settlement statements, schedules and receipts must show the rounding applied where it changes an amount.

### 4.10 Default Organisation Settings

Every new organisation is provisioned with a **default value for every organisation setting**, so that it can be used immediately after creation. No setting is left empty.

- Default values are held in a platform-level **default settings template**, maintained by the Platform Super Administrator and versioned.
- When the Super Administrator creates an organisation, all settings are copied from the current template version into that organisation (Section 35.5). The organisation's copy is then independent; later template changes do not change existing organisations.
- Settings can then be changed only by the role shown below, from an effective date, with an audit record. Workflow, rule, module and legal settings stay with the Super Administrator.
- Each setting can be reset to the template default, and a report shows every setting where the organisation differs from the default.
- Defaults marked "proposed" are suggestions to be confirmed with the first organisation.

| Area | Setting | Default Value | Can Be Changed By | See |
|---|---|---|---|---|
| General | Organisation name, address, logo, contact details | Entered by the Super Admin at creation | Org Admin | Section 35.6 |
| General | Time zone | Asia/Kolkata (IST) | Org Admin | Section 35.12 |
| General | Currency and number format | INR (₹), Indian grouping (1,00,000.00) | Org Admin | Section 35.6 |
| General | Date format | DD-MM-YYYY | Org Admin | Section 35.6 |
| General | Enabled languages | English and Tamil | Super Admin | Section 36 |
| General | Default language | English | Org Admin | Section 36 |
| Modules | Enabled modules | Core modules only (Section 3.9.1); optional modules off | Super Admin | Section 3.9.1 |
| Modules | Default home page per role | As in the Section 3.8 table | Org Admin | Section 3.8 |
| Users and login | Activation link expiry | 48 hours | Org Admin | Section 3.6.1 |
| Users and login | MFA method for privileged roles | Authenticator app (TOTP) | Org Admin | Section 3.10 |
| Users and login | Password: minimum length / history | 10 characters / last 5 passwords | Org Admin | Section 3.10 |
| Users and login | Forced periodic password change | Off | Org Admin | Section 3.10 |
| Users and login | Account lockout | After 5 failed attempts | Org Admin | Section 36 |
| Accounting | Accounting basis | Cash basis (fixed) | — | Section 21.5 |
| Accounting | Financial year | 1 April to 31 March | Org Admin | Section 21 |
| Accounting | Chart of Accounts | Standard template (Section 21.1) | Accountant | Section 21.1 |
| Accounting | Cash account | One common cash account | Super Admin | Section 21.6 |
| Accounting | Backdating limit for the working date | No limit (closed periods and closed days excluded) | Super Admin | Section 21.7 |
| Accounting | Export formats | Excel (.xlsx) and PDF; CSV also for lists | — | Section 36 (Export) |
| Rounding | Mode and precision per area | As in the Section 4.9 table | Accountant, with Leadership approval | Section 4.9 |
| Loans | Loan types and their rules (interest, fees, late fee, penalty, settlement charges) | Platform template loan types | Super Admin | Section 6, Section 35.4 |
| Loans | Application fee | Off per loan type until configured | Super Admin | Section 6.2 |
| Loans | Nominee mandatory | Yes for a member's first loan | Super Admin | Section 6.1 |
| Loans | Disbursement window after approval | 30 days | Super Admin | Section 6.6 |
| Loans | Default after unpaid months | 2 months | Super Admin | Section 8.1 |
| Loans | Cooling-off period | Applies after a defaulted loan only; length 6 months (proposed) | Super Admin | Section 8.4 |
| Loans | Minimum membership period for a loan | 6 months (proposed) | Super Admin | Section 6.8 |
| Loans | Maximum concurrent active loans per member | 1 (proposed) | Super Admin | Section 6.8 |
| Loans | Guarantors required | None | Super Admin | Section 6.9 |
| Loans | Restructuring | Allowed, at most 1 per loan | Super Admin | Section 6.10 |
| Recovery | Escalation of unpaid defaulters to the Manager | After 30 days | Super Admin | Section 28.5 |
| Approvals | Approver | Manager, single approver for all amounts | Super Admin | Section 4.7 |
| Approvals | Roles that can record offline decisions | Employee and Manager | Super Admin | Section 4.7 |
| Approvals | Offline evidence types | Verbal instruction, Meeting, Phone call, Signed paper; upload optional | Super Admin | Section 4.7 |
| Notifications | Channels enabled | SMS on; WhatsApp and email off | Org Admin | Section 30 |
| Notifications | Quiet hours | 9 PM to 8 AM | Org Admin | Section 30.3 |
| Notifications | Templates | Platform default templates (English) | Org Admin | Section 30 |
| Hall | Tentative booking hold | 3 days | Org Admin | Section 18.6 |
| Legal and tax | GST, payroll statutory, TDS, 80G, FCRA | All off | Super Admin | Section 4.8 |
| Optional modules | Member Deposits, Chit Funds | Off | Super Admin | Section 9, Section 10 |
| Data | Purge | Off | Super Admin | Section 36 |
| Data | Retention period per data category | As in the Data Retention table (8-year floor for financial data) | Org Admin | Section 36 |
| Data | Archive retention before final deletion | 2 years | Org Admin | Section 36 |

---

## 5. Member Management

Maintain a centralised member database.

### 5.1 Member Information

- Unique Member ID.
- Full name and date of birth.
- Gender, if required.
- Address, mobile number and email.
- Membership date and status.
- Family and children details.
- Nominee information.
- Supporting documents.

### 5.2 Member Statuses

- Applied (membership application pending approval).
- Active.
- Inactive.
- Suspended.
- Exited (resigned or removed).
- Deceased.

### 5.3 Member Financial Profile

Each member should have a consolidated history of:

- Loan applications and application fees.
- Loan approvals and disbursements.
- Repayments, partial repayments and early settlements.
- Outstanding balances and default history.
- Education and cremation assistance.
- Birthday grants.
- Marriage hall bookings.
- Deposit accounts, balances and interest (when Member Deposits is enabled).
- Chit tickets, instalments, dividends and prizes (when Chit Funds is enabled).
- Contributions and donations.

### 5.4 Membership Lifecycle

| Event | Workflow |
|---|---|
| Joining | Employee registers the applicant → documents and duplicate check → Manager verification → approval by the configured authority → membership fee or first contribution collected (if configured) → status Active |
| Suspension | Reason recorded (for example default, misconduct, non-payment of contributions) → Manager approval → status Suspended; new loans, deposits and chit enrolment are blocked |
| Reinstatement | Request → approval → status Active |
| Exit (resignation or removal) | Request → check for open loans, deposits, chit tickets, guarantees and dues → settlement of all balances → approval → status Exited |
| Readmission | Treated as a new joining linked to the earlier member record and history |
| Death | As in Section 12 |

- A member cannot exit while any loan, deposit, chit ticket or guarantee is open.
- The approving authority for each event is configurable.
- Status changes are effective-dated and audited.

### 5.5 Duplicate Member Prevention

- On registration and on changes to key details, the system checks for possible duplicates by mobile number, name with date of birth, and identity document number.
- Possible duplicates are shown to the employee; continuing requires a reason and Manager approval.
- A confirmed duplicate can be merged by the Manager, keeping all history under one member ID and recording the merge in the audit trail.
- Changing a member's mobile number requires verification by OTP to the new number or Manager approval.

---

## 6. Loan Management

Loan types are configurable by the organisation. Interest and repayment rules are defined for each loan type through the Business Rules Engine, so new loan types can be added without code changes.

Illustrative loan types:

| Loan Type | Interest |
|---|---|
| Interest-Bearing Loan | Rule-driven (for example flat rate) |
| Interest-Free Loan | 0% |
| Normal Loan | Rule-driven, as defined for this type |

Rules defined per loan type include: interest rate and method, minimum and maximum amount, repayment period limits, application fee, nominee and guarantor requirements, early settlement interest option, late fee, overpayment treatment, default period and default penalty.

**No top-up loans.** Additional borrowing is always a separate new loan, subject to the eligibility rules (Section 6.8). An existing loan's amount is never increased.

Education assistance will be handled through a separate module.

### 6.1 Loan Application

Employees create loan applications on behalf of members.

Application fields include:

- Member ID.
- Loan category.
- Requested amount and purpose.
- Repayment duration.
- Nominee details, if required.
- Supporting documents.
- Application fee and application date.

### 6.2 Loan Application Fee Management

The organisation collects an application fee when members apply for loans.

Configurable settings:

- Enable or disable the fee for each loan type (not all loan types have a fee).
- Fixed amount or percentage, per loan type.
- Payment before or after submission.
- Fee waiver permission and approval.
- Effective date.

Application fees are **non-refundable** in all cases, including rejected or withdrawn applications.

Illustrative fees:

| Loan Category | Fee |
|---|---:|
| Interest-Bearing | ₹200 |
| Interest-Free | ₹100 |
| Normal | ₹150 |

Application fee workflow:

```text
Create Application
       |
       v
Select Loan Category
       |
       v
Calculate Application Fee
       |
       v
Collect Fee
       |
       v
Generate Receipt
       |
       v
Submit Application
       |
       v
Manager Approval
```

The system must prevent submission when the loan type's application fee remains unpaid. Fees are never refunded. Application fees must be accounted for separately from loan principal and interest.

### 6.3 Flat Interest Calculation

Interest is calculated on the original loan principal.

**Formula:**

`Total Interest = Principal × Annual Interest Rate × (Repayment Months / 12)`

Example:

| Description | Amount |
|---|---:|
| Principal | ₹1,20,000 |
| Annual Interest | 12% |
| Repayment Period | 12 months |
| Total Interest | ₹14,400 |
| Monthly Principal | ₹10,000 |
| Monthly Interest | ₹1,200 |
| Monthly Instalment | ₹11,200 |

The final instalment absorbs rounding differences, according to the organisation's rounding settings (Section 4.9).

### 6.4 Repayment Period

The organisation configures minimum and maximum repayment periods. Example values are 6 and 60 months. Employees can select any whole number of months within the configured limits.

### 6.5 Loan Approval

```text
Employee Creates Application
           |
           v
Application Fee Collection
           |
           v
Business Rule Validation
           |
           v
Manager Approval
           |
      +----+----+
      |         |
   Approved  Rejected
      |
      v
Loan Disbursement
      |
      v
Repayment Schedule
```

The Manager has final loan approval authority, as a single approver irrespective of the loan amount. There is no committee or voting. The approver cannot be the employee who created the application. Decisions can be recorded online or through authorised offline approval processes.

### 6.6 Loan Disbursement

Record the approved amount, loan category, interest rate, repayment period, approval date, actual disbursement date, payment method, payment reference and responsible employee.

The actual disbursement/receipt date determines the repayment schedule.

Disbursement controls:

- An approved loan must be disbursed within a configurable period (default 30 days); otherwise the approval expires and the application must be re-approved.
- Disbursement requires maker-checker: one user prepares the disbursement and a different authorised user releases the cash.
- The member (borrower) signs or gives a thumb impression on the disbursement voucher.
- Application fees and other permitted charges may be deducted from the disbursement amount if the organisation's policy allows it, with the deduction shown on the voucher.
- An approved loan can be cancelled before disbursement, with a reason and approval.
- Disbursement in more than one instalment (tranches) is configurable per loan category; the repayment schedule starts from the first tranche unless configured otherwise.
- Cash disbursement limits apply (Section 21.6).

### 6.7 Loan Statuses

| Status | Meaning |
|---|---|
| Draft | Application being entered |
| Fee Pending | Waiting for a mandatory application fee |
| Submitted | Submitted for verification |
| Under Approval | With the Manager for approval |
| Returned | Sent back for correction |
| Approved | Approved, not yet disbursed |
| Rejected | Rejected, with reason |
| Withdrawn | Withdrawn by the member before a decision |
| Cancelled | Approved but cancelled or expired before disbursement |
| Active | Disbursed and repaying |
| Overdue | One or more instalments past due and unpaid |
| Defaulted | Default rule triggered (Section 8.1) |
| Restructured | Terms changed under an approved restructuring (Section 6.10) |
| Transferred | Transferred to successor loans (Section 12.1) |
| Settled | Fully repaid early or after default |
| Closed | Fully repaid as scheduled |
| Written Off | Balance written off (Section 8.7) |

Allowed status transitions are defined in the loan workflow; every change is recorded with date, user and reason.

### 6.8 Eligibility Limits

Organisation settings (per loan type where relevant), enforced by the Business Rules Engine:

- Member status must be Active, with a minimum membership period (for example 6 months).
- Minimum and maximum age of the borrower at application and at loan end.
- Maximum number of concurrent active loans per member (overall and per category).
- Maximum total outstanding per member, and optionally per household.
- No loan while the member is Restricted or in a cooling-off period, unless a Manager override exists.
- No loan while the member has overdue instalments on any loan or overdue chit or contribution dues, if configured.
- Maximum number of loans a member can guarantee and maximum guaranteed amount.

### 6.9 Guarantors

Guarantors are separate from nominees (Section 11).

- Guarantor requirements are organisation settings: a loan type can require zero, one or more guarantors above a configured amount.
- A guarantor must be an Active member (or an approved non-member, if configured) and meet guarantor limits.
- Guarantor details, consent (signature or thumb impression) and documents are recorded.
- Guarantors are notified at approval, when the loan becomes overdue, and on default.
- On default, the guaranteed amount can be recovered from the guarantor through the recovery workflow (Section 8.6).
- A guarantor cannot exit membership while the guarantee is open; a replacement guarantor requires approval.

### 6.10 Loan Restructuring

A loan may be restructured when a member faces genuine hardship. Whether restructuring is allowed, and its options and limits, are organisation settings.

- Options: extend the repayment period, reduce the instalment, grant a moratorium (pause) of up to a configured number of months, or combine overdue amounts into a new schedule.
- Requires a member request with reason and Manager approval.
- The original loan and schedule are preserved; the restructured schedule is a new version linked to the original.
- Interest on the restructured loan follows the configured policy (for example, no additional interest for interest-free loans; flat interest on the outstanding principal for the extended period for interest-bearing loans).
- The number of restructurings per loan is limited (default 1).
- A restructured loan is flagged in reports.


---

## 7. Loan Repayment Management

The system must support:

1. Regular monthly repayment.
2. Partial repayment.
3. Full lump-sum repayment.

### 7.1 Repayment Schedule

The first instalment is due one calendar month after the actual loan disbursement date.

Example: if the loan is received on 14 January, the instalments are due on 14 February, 14 March, 14 April and so on. If a corresponding date does not exist in a month, use that month's final calendar day.

### 7.2 Partial Repayments

The system must:

- Record the actual payment.
- Update outstanding balances.
- Track principal and interest separately.
- Generate receipts.
- Preserve the original repayment schedule.
- Apply configurable payment allocation rules.

### 7.3 Early Full Settlement

Members can settle the entire outstanding loan amount at any time during the repayment period.

The organisation selects one of two interest policies separately for each loan category:

| Option | Policy |
|---|---|
| A | Collect all remaining scheduled interest |
| B | Collect interest only up to the actual settlement date |

Configurable settings include whether early settlement is enabled, applicable loan types, interest policy, approval requirements and effective date. **Early settlement charges, rebates and waivers are defined by rule for each loan type.**

Early settlement workflow:

```text
Member Requests Settlement
          |
          v
Employee Opens Loan Account
          |
          v
Calculate Settlement Amount
          |
          v
Generate Settlement Statement
          |
          v
Manager Verification (if required)
          |
          v
Collect Full Amount
          |
          v
Generate Receipt
          |
          v
Post Accounting Entries
          |
          v
Mark Loan as SETTLED
          |
          v
Start Cooling-off Period (only if configured for early settlement; see Section 8.4)
```

Settlement rules:

- Previously paid principal and interest must not be counted twice.
- Future instalments must be cancelled after full settlement.
- Historical transactions must remain unchanged.
- Settlement calculations must show detailed components.
- Waivers require authorised approval.
- The actual settlement date must be preserved.
- The loan becomes `SETTLED` only after the required amount is received.

### 7.4 Payment Allocation Order

Every repayment is allocated in a configurable order. The default order is:

1. Late fees (if enabled).
2. Overdue interest (oldest first).
3. Overdue principal (oldest first).
4. Current instalment interest.
5. Current instalment principal.

The allocation is shown on the receipt and recorded per instalment.

### 7.5 Lump-Sum Partial Payments and Overpayments

When a member pays more than the amount currently due, but less than the full outstanding balance:

- The amount due (including any overdue amounts and late fees) is settled first, as in Section 7.4.
- The **excess reduces the outstanding principal**.
- The remaining schedule is regenerated. Whether the instalment amount is reduced (same tenure) or the tenure is shortened (same instalment), and how interest is recalculated on the reduced principal, is defined by rule for each loan type.
- The receipt and the new schedule show the principal reduction.
- An amount that clears the full outstanding balance is treated as early settlement (Section 7.3).

### 7.6 Late Fees

Late fees and penalties are organisation settings defined **per loan type** by rule.

- For each loan type: whether a late fee applies, grace period in days, fixed amount or percentage of the overdue instalment, frequency (once per instalment or monthly), and maximum cap.
- A separate default penalty can be defined per loan type (Section 8.1).
- Waivers require approval as configured.
- Late fee income is posted to a separate income account.

### 7.7 Receipt Cancellation and Reversal

- A receipt entered in error can be cancelled only by a reversal, never by deletion or edit.
- Same-day cancellation before day-end closing requires Manager approval; after day-end closing it requires Manager and Accountant approval.
- Cancellation requires a reason; the original receipt is marked "Cancelled" and the reversal entry is linked to it.
- Loan balances, schedules, allocations and accounting entries are restored automatically.
- Cancelled receipt numbers are never reused.

### 7.8 Payment Mode

- All receipts and payments are in **cash** for the current scope.
- The design must support adding organisation-configurable payment channels later (cheque with bounce handling, UPI and payment links, bank transfer, NACH auto-debit, salary deduction) without redesign. Each receipt and payment therefore records a payment mode, even though only Cash is enabled initially.

---

## 8. Default and Recovery Management

### 8.1 Default Rule

When an instalment remains unpaid for the configured number of months (organisation setting, default **2 months**), the loan becomes defaulted. The defaulter must then pay the **full outstanding amount plus a default penalty**. The penalty amount or percentage is defined by rule for each loan type. This applies to all loan types, including interest-free loans, unless configured otherwise for a type.

Definitions (configurable, defaults shown):

- An instalment is **unpaid** until it is paid in full; a partly paid instalment remains unpaid.
- A loan becomes **Overdue** the day after an instalment due date (after any grace period) while that instalment is unpaid.
- A loan becomes **Defaulted** when the oldest unpaid instalment is still unpaid the configured number of calendar months (default 2) after its due date (for example, an instalment due on 14 March that is still unpaid at the end of 14 May).
- Restructured loans follow their new schedule.

### 8.2 System Actions

- Mark loan as Defaulted.
- Calculate the full outstanding amount (principal and interest as defined by the loan type's rule) and the default penalty.
- Generate a settlement statement.
- Restrict new loan applications.
- Notify the member, nominee or guarantor (if any) and the Manager.
- Start the recovery workflow.

### 8.3 Separate Statuses

| Status Type | Values |
|---|---|
| Loan Status | As in Section 6.7 |
| Member Loan Eligibility | Eligible, Restricted, Cooling-off, Reinstated |
| Recovery Status | Pending, Contacted, Promise to Pay, Legal Notice, Settlement Agreed, Settlement Received, Exception Approved, Written Off |

### 8.4 Cooling-off Period

Cooling-off is an **organisation setting**: its length, and whether it applies only after a defaulted loan or also after voluntary early settlement (per loan type), are configured by the organisation. By default it starts from the date the member fully settles a **defaulted** loan.

- By default, no cooling-off applies after normal completion or voluntary early settlement of a loan that never defaulted.
- The organisation can optionally configure a cooling-off period after voluntary early settlement, separately for each loan category.

### 8.5 Cooling-off Override

The Manager may approve an exception to the cooling-off restriction. Record the request, reason, decision, approver, approval date, evidence and audit history. Historical default records must not be deleted or overwritten.

### 8.6 Recovery Workflow

```text
Loan Defaulted
      |
      v
Recovery Case Created and Assigned
      |
      v
Contact Member (calls, visits, letters) -- logged
      |
      v
Promise to Pay? --yes--> Track promised date --> Paid? --> Settlement Received
      |no
      v
Contact Guarantor(s)
      |
      v
Formal / Legal Notice (if configured)
      |
      v
Negotiated Settlement (with waiver, Manager approval)
      |
      v
Settled, or Proposed for Write-off
```

- Every contact attempt is logged with date, method, person, outcome and next follow-up date.
- Follow-up reminders are generated for the assigned employee.
- A negotiated settlement that waives principal or interest requires Manager approval.
- Recovery cases are visible on the Manager dashboard.

### 8.7 Write-off

- A loan may be proposed for write-off when recovery has failed or is not possible (for example a deceased member with no successor or estate).
- Write-off requires approval by a single authorised approver (default: Leadership), irrespective of amount.
- Accounting: Dr Bad Debts Written Off / Cr Loan Principal Receivable.
- A written-off loan remains on record; the member remains Restricted unless the Manager decides otherwise.
- Any later recovery is posted as Bad Debts Recovered income.

---

## 9. Member Deposits

Members may place money with the organisation and earn interest on it. This module is an **optional organisation-level setting, disabled by default** (Section 4.8).

> **Legal warning – obtain legal advice before enabling.** An NGO, trust or society that accepts deposits from members or the public and pays interest may fall under the **Banning of Unregulated Deposit Schemes Act, 2019** and Reserve Bank of India rules on acceptance of deposits. Running an unregulated deposit scheme is a serious offence. The organisation must obtain written legal advice confirming that its deposit scheme is lawful before this module is enabled. CFMS provides the functionality only and does not determine legality.

### 9.1 Enabling the Module

- Enabled per organisation by the Platform Super Administrator only.
- Obtaining legal advice is the organisation's responsibility and is out of the system's scope for now. The system does not block enabling, but the legal warning above is shown to the Super Administrator when enabling the module, and the acknowledgement is recorded in the audit log. An optional field allows the advice document to be uploaded.
- When disabled, all deposit screens, accounts, notifications and reports are hidden.
- Disabling is allowed only when no deposit account is open.

### 9.2 Deposit Products

The organisation configures one or more deposit products of these types. There is **no on-demand withdrawal**: money is paid out only at maturity or on approved premature closure.

| Type | Description |
|---|---|
| Recurring Deposit (RD) | Fixed amount deposited every month for a fixed tenure; paid out with interest at maturity |
| Fixed Deposit (FD) | Lump sum deposited for a fixed tenure; interest paid periodically or at maturity |

Configurable settings per product:

- Product name, type and status.
- Eligibility (members only, minimum membership period, member status).
- Minimum and maximum amount per deposit and per member.
- Tenure options (for RD and FD), for example 6 to 60 months.
- Interest rate, by tenure and amount band.
- Interest method: simple or compound, with compounding frequency (for example quarterly).
- Day-count convention (for example actual days / 365).
- Interest payout frequency: monthly, quarterly, at maturity, or cumulative (added to the deposit).
- Payout method: cash.
- Premature withdrawal allowed or not, lock-in period, and penalty (for example interest rate reduced by a set percentage).
- Missed RD instalment rules: grace days, penalty, and how many missed instalments close the account.
- Maturity action: pay out, or auto-renew for the same tenure at the then-current rate.
- Approval requirements (account opening, premature closure).
- Effective date and version history.

The interest rate of an RD or FD is fixed when the account is opened and does not change with later rate changes.

### 9.3 Deposit Account Lifecycle

| Status | Meaning |
|---|---|
| Applied | Opening request entered, awaiting approval |
| Active | Open and accepting transactions |
| Matured | Tenure completed, awaiting payout or renewal |
| Renewed | Matured and rolled into a new term |
| Prematurely Closed | Closed before maturity with any penalty applied |
| Closed | Fully paid out |
| Frozen | Transactions blocked (deceased member, legal hold or lien) |

### 9.4 Transactions and Workflows

- Account opening: application, nominee capture, approval, first deposit, receipt.
- Deposits and RD instalments: cash receipt with a pre-numbered receipt.
- Interest calculation and payout as configured (Section 9.6).
- Maturity: reminder before maturity, then payout or renewal as per the member's instruction or product default.
- Premature closure: request, penalty calculation shown to the member, approval, payout.
- Death of a depositor: account frozen, nominee or legal successor claim, verification, payout of balance and interest due up to the date of death (linked to Section 12).
- Lien: a deposit may be marked as security for a loan; liened amounts cannot be withdrawn. Setting a defaulted loan off against a deposit requires Manager approval and the member's prior written consent.

### 9.5 Nominee

- Each deposit account must have at least one nominee, with share percentages when there are several.
- Nominee details follow Section 11. A nominee receives the balance on the depositor's death after verification; a nominee is not the legal owner during the depositor's lifetime.

### 9.6 Interest Calculation and Accounting

- Interest is calculated with full precision and rounded as per the organisation's rounding settings (Section 4.9).
- Interest is calculated monthly and is recorded as an expense only when it is paid or credited, according to the product's payout frequency (cash basis).
- If the TDS feature is enabled (Section 4.8), TDS on deposit interest is deducted as configured.

Additional accounts:

| Account | Type |
|---|---|
| Member Deposits – Recurring | Liability |
| Member Deposits – Fixed | Liability |
| Interest on Member Deposits | Expense |

Posting rules:

| Event | Posting |
|---|---|
| Deposit or RD instalment received | Dr Cash / Cr Member Deposits – [type] |
| Interest credited to the deposit (cumulative) | Dr Interest on Member Deposits / Cr Member Deposits – [type] |
| Interest paid in cash | Dr Interest on Member Deposits / Cr Cash |
| Maturity or closure payout | Dr Member Deposits – [type] / Cr Cash |
| Premature-closure penalty | Lower interest is paid or credited; no separate entry |

### 9.7 Receipts, Statements and Notifications

- Receipt for every deposit and payout voucher for every maturity or closure payout, signed or acknowledged by the member.
- Deposit passbook or statement, printable and sendable on request.
- Interest certificate per financial year.
- Notifications: deposit receipt, RD instalment due and missed, interest credited, maturity reminder (for example 15 and 3 days before), maturity payout.

### 9.8 Reports and Controls

- Deposit register by product and member.
- Maturity schedule (deposits maturing by month), to plan cash availability.
- Interest paid or credited, and interest calculated but not yet due.
- Deposits versus loans outstanding and cash available, so that the organisation can see whether it could repay deposits when due.
- Frozen accounts.
- Cash controls apply as for all cash transactions (Section 21.6).

---

## 10. Chit Fund Schemes

Members join a chit group and pay a fixed amount every month for a fixed number of months. Each month the pooled amount (the chit value) is given to one member, chosen by auction, lottery or a fixed turn, until every member has received it once. This module is an **optional organisation-level setting, disabled by default** (Section 4.8).

> **Legal warning – registration and legal advice required.** Chit funds are regulated under the **Chit Funds Act, 1982** and the chit fund rules of each State. Starting or running a chit without prior sanction and registration with the State Registrar of Chits is an offence. The Act also sets requirements such as the foreman's security deposit, a written chit agreement, a cap on the foreman's commission, maximum discount limits and the filing of auction minutes. The organisation must obtain written legal advice and the required registration for each chit group before this module is used. CFMS provides the functionality only and does not determine legality.

**Chit fund compared with Member Deposits:**

| Aspect | Chit Fund (this section) | Recurring Deposit (Section 9) |
|---|---|---|
| Who pays the return | Other members, through the bid discount | The organisation pays interest |
| When a member gets money | Any month, when they win the auction, draw or turn | At maturity (or premature closure) |
| Amount received | Chit value less the winning discount | Own deposits plus interest |
| Organisation's role | Foreman: runs the group and earns commission | Deposit taker: owes the money and interest |
| Regulation | Chit Funds Act 1982 and State rules | Deposit regulations (Section 9 warning) |

If the organisation's scheme is simply members saving a fixed amount monthly and withdrawing their own savings after a set number of months, with no pooling or auction, it should be configured as a Recurring Deposit (Section 9), with or without interest, rather than as a chit fund.

### 10.1 Enabling the Module

- Enabled per organisation by the Platform Super Administrator only.
- Obtaining legal advice and chit registration is the organisation's responsibility and is out of the system's scope for now. The system does not block enabling or starting a chit group, but the legal warning above is shown when enabling the module and when starting a group, and the acknowledgement is recorded in the audit log. Optional fields allow registration details and documents to be recorded for each group.
- When disabled, all chit screens, accounts, notifications and reports are hidden.

### 10.2 Chit Scheme Configuration

The organisation defines chit schemes (templates) and starts chit groups from them.

| Setting | Description | Example |
|---|---|---|
| Duration (months) | Number of monthly instalments | 20 |
| Number of members | Usually equal to the duration | 20 |
| Monthly subscription | Amount each member pays per month | ₹5,000 |
| Chit value | Monthly subscription × number of members | ₹1,00,000 |
| Payout method | Auction (bid), Lottery (draw), Fixed turn, or a combination (for example foreman's chit in month 1, then auction) | Auction |
| Maximum discount | Highest discount a bidder may offer, within statutory limits | 30% of chit value |
| Foreman commission | Percentage of chit value retained by the organisation, within statutory limits | 5% |
| Dividend treatment | Deducted from the next month's subscription, or paid out | Deducted |
| Auction day and time | Monthly draw or auction date | 10th of each month |
| Late payment rules | Grace days, late fee or interest, number of missed instalments before default | 7 days; ₹100 |
| Security from prized members | Guarantor or other security required before paying the prize, to cover remaining instalments | Guarantor required |
| Eligibility | Members only, member status, maximum chit tickets per member | 2 tickets |

Scheme settings are versioned. A chit group keeps the settings it started with.

### 10.3 Chit Group Lifecycle

| Group Status | Meaning |
|---|---|
| Draft | Created, not yet open for enrolment |
| Registered | Registration details recorded; open for enrolment |
| Active | All tickets filled, first instalment collected |
| Completed | All months paid out |
| Closed | Final settlement and accounts closed |
| Terminated | Stopped early under the Act or by decision, with refunds as per rules |

| Ticket (Member) Status | Meaning |
|---|---|
| Enrolled / Non-prized | Paying, has not yet received the prize |
| Prized | Has received the prize, continues paying until the end |
| Defaulted | Missed the configured number of instalments |
| Substituted | Non-prized defaulter replaced by a new member as per rules |
| Withdrawn | Left the group as per rules |
| Completed | All instalments paid and prize received |

### 10.4 Monthly Cycle

```text
Collect Monthly Subscriptions (cash, with receipts)
          |
          v
Check Eligible Non-prized Members (no arrears)
          |
          v
Auction / Lottery / Fixed Turn
          |
          v
Record Result and Auction Minutes
          |
          v
Calculate Prize, Commission and Dividend
          |
          v
Obtain Security from Prized Member
          |
          v
Approve and Pay Prize (cash, with payee acknowledgement)
          |
          v
Post Accounting Entries and Notify Members
```

Calculation example (auction): chit value ₹1,00,000; winning discount ₹20,000; foreman commission 5% = ₹5,000.

| Item | Amount |
|---|---:|
| Prize paid to winner | ₹80,000 |
| Foreman commission (organisation income) | ₹5,000 |
| Dividend to all members (₹20,000 − ₹5,000) | ₹15,000 |
| Dividend per member (20 members) | ₹750 |
| Next month's net subscription per member | ₹4,250 |

Rules:

- Only non-prized members with no arrears can bid or be drawn.
- In an auction, the highest discount within the maximum wins; ties are resolved by a configured rule (for example draw of lots).
- Auction results, bids and attendance are recorded as auction minutes, with approval by the authorised persons.
- The prize is paid only after required security is provided and approval is recorded.

### 10.5 Defaults and Late Payment

- Late fees or interest apply after the grace period, as configured.
- A **non-prized** member who defaults may be removed and substituted as per rules; amounts paid are refunded as per the chit agreement (for example at the end of the group, less dues).
- A **prized** member who defaults remains liable for all remaining instalments; recovery follows the recovery workflow (Section 8), including the guarantor or security.
- Defaults are visible on the member's financial profile and can restrict new loans or chit enrolment.

### 10.6 Death of a Member

- **Non-prized member:** the nominee or legal successor may continue the ticket, or withdraw with refund of amounts paid as per the chit agreement.
- **Prized member:** remaining instalments are recovered from the security, guarantor or estate, or as decided by the Manager.
- Notifications to the deceased member stop immediately (linked to Section 12).

### 10.7 Accounting

Each chit group has its own sub-ledger. Members' subscriptions are liabilities held for the group until paid out; only the foreman commission and fees are the organisation's income.

| Account | Type |
|---|---|
| Chit Subscriptions – [Group] | Liability |
| Chit Prize Payable – [Group] | Liability |
| Chit Dividend Payable – [Group] | Liability |
| Foreman Commission Income | Income |
| Chit Late Fee Income | Income |

| Event | Posting |
|---|---|
| Subscription received | Dr Cash / Cr Chit Subscriptions – [Group] (net subscription), Dr Chit Dividend Payable (dividend adjusted) |
| Auction or draw result | Dr Chit Subscriptions – [Group] (chit value) / Cr Chit Prize Payable (prize), Cr Foreman Commission Income (commission), Cr Chit Dividend Payable (dividend) |
| Prize paid | Dr Chit Prize Payable / Cr Cash |
| Late fee received | Dr Cash / Cr Chit Late Fee Income |
| Refund to withdrawn or substituted member | Dr Chit Subscriptions – [Group] / Cr Cash |

Group balances must reconcile every month: total subscriptions collected equal prizes paid, plus commission, plus dividends, plus balance held.

### 10.8 Receipts, Statements, Notifications and Reports

- Receipt for every subscription; payout voucher with payee acknowledgement for every prize and refund.
- Member chit statement: instalments paid, dividends received, prize received, dues.
- Notifications: instalment due, payment received, auction date, auction result, prize payment, overdue.
- Reports: chit group register, monthly auction register and minutes, collection and arrears by group, dividend register, foreman commission, group-wise reconciliation, and statutory returns where required by State rules.

---

## 11. Nominee Management

A nominee is **mandatory for a member's first loan**. For later loans, the organisation can require a nominee by loan type or when the loan amount exceeds a configurable threshold.

Nominee details:

- Full name and relationship.
- Date of birth.
- Mobile number and address.
- Identity information, where appropriate.
- Consent and supporting documents.

Nominees, guarantors and legal successors must remain separate concepts. A nominee is not automatically legally liable for a member's debt.

---

## 12. Deceased Member Management

When a member dies:

1. Employee reports the death.
2. Manager verifies the information.
3. Death certificate is uploaded.
4. Member status changes to Deceased.
5. Outstanding loans are identified.
6. Nominee and legal successor information is reviewed.
7. Cremation assistance is processed.
8. Any proposed loan transfer is handled separately.

### 12.1 Loan Transfer to Children

The system should support transfer to one child, division among multiple children, approved successor assignment, separate repayment schedules, Manager approval and linkage to the original loan.

Any transfer requires appropriate consent and legal verification.

### 12.2 Outstanding Loans of a Deceased Member

The Manager decides one of the following for each outstanding loan:

| Option | Effect |
|---|---|
| Recover from nominee or legal successor | Successor agrees to repay; loan continues or is transferred (Section 12.1) |
| Recover from guarantor | Recovery workflow against the guarantor (Section 8.6) |
| Recover from deposits or chit dues | Set off against the member's deposits or chit amounts, where agreed and lawful |
| Waive or write off | Write-off workflow (Section 8.7) |

- Cremation assistance is paid in full and is **not** set off against an outstanding loan unless the organisation's policy explicitly allows it and the family consents.
- Interest stops accruing from the date of death unless the Manager decides otherwise.

### 12.3 Immediate Effects of Marking a Member Deceased

- All reminders and marketing or routine notifications to the member stop immediately.
- Deposit accounts and chit tickets are frozen pending claims.
- The member's loans are flagged for Manager decision (Section 12.2).

---

## 13. Education Assistance Management

The community provides equal financial assistance to eligible applicants.

Configuration:

- Assistance amount.
- Application opening date and deadline.
- Eligibility conditions.
- Required documents.
- Approval workflow.
- Funding source.

Illustrative example:

| Setting | Value |
|---|---|
| Assistance Amount | ₹10,000 |
| Opening Date | 1 January |
| Closing Date | 31 March |
| Interest | 0% |
| Funding Source | General Community Fund |

Every eligible applicant receives the same amount for the relevant cycle.

Workflow: Employee Registration → Eligibility Verification → Manager Approval → Payment → Accounting Entry.

**Policy to confirm:** whether education assistance is a non-repayable grant or a repayable interest-free loan.

Additional rules (configurable):

- **Cycle limit:** a maximum total amount is set for each cycle. If eligible applications exceed the limit, the configured rule applies: reduce the amount equally for all eligible applicants, or approve in order of application until the limit is reached, or ask the Manager to increase the cycle limit.
- **Limits:** maximum number of beneficiaries per family per cycle, and whether a student may receive assistance in consecutive years.
- **Evidence:** proof of admission and fee receipt required before payment.
- **Payment:** to the member or parent in cash with acknowledgement (or directly to the institution when non-cash channels are enabled).
- **Rejection:** reason recorded and notified.

---

## 14. Cremation Assistance Management

The community provides financial assistance when a member dies.

Configuration includes assistance amount, eligibility criteria, supporting documents, approval requirements and payment method.

Funding source: General Community Fund.

Workflow: Employee Reports Death → Manager Verification → Request → Approval → Payment → General Ledger Posting → Audit.

Cremation assistance is a non-repayable expenditure, separate from outstanding loans.

---

## 15. Leadership Birthday Grants

The organisation provides financial grants on selected leadership members' birthdays.

Configuration includes eligible leaders, birthday dates, grant amounts, eligible beneficiaries, payment dates and approval requirements.

Features:

- Birthday management.
- Annual grant scheduling.
- Beneficiary registration.
- Payment tracking.
- Annual expenditure reporting.

---

## 16. Daily Expense Management

The system must record all organisational expenses.

Expense categories include office, electricity, water, maintenance, travel, fuel, food, medical, community activities, events and miscellaneous.

Expense details include date, category, description, amount, payment method, submitter, supporting bill, approval status and payment reference.

Workflow: Employee Submission → Manager Approval → Payment → General Ledger Posting → Audit.

### 16.1 Petty Cash (Imprest)

- An employee can be given a petty cash advance (imprest) up to a configured limit, approved by the Manager.
- Expenses paid from the advance are submitted with bills; approved bills reduce the advance.
- The unspent balance is returned in cash or the advance is topped up to its limit.
- Outstanding advances older than a configured number of days are flagged.
- Accounting: Dr Petty Cash Advance – [Employee] / Cr Cash on issue; Dr Expense / Cr Petty Cash Advance on settlement.

### 16.2 Vendors and Bills

- Vendor master: name, contact, address, category, identity or registration details where required.
- Vendor bills (for expenses, services and asset purchases) are recorded on receipt, approved, and paid in full or in parts.
- Advances to vendors are recorded and adjusted against bills.
- Vendor bills are tracked in the vendor ledger until paid. Under cash basis the expense or asset is posted only when payment is made: Dr Expense or Asset / Cr Cash.
- Reports: vendor ledger, bills outstanding and payments by vendor.

---

## 17. Employee Payroll Management

Employee details include employee ID, name, joining date, designation, department, salary structure and employment status. Salaries are paid in cash.

Payroll components include basic salary, allowances, bonuses, deductions, salary advances, authorised loan deductions and net salary.

Features:

- Payroll preparation and salary calculation.
- Verification and leadership approval.
- Payment tracking.
- Payslip generation.
- Payroll history and reports.

Preparation and approval must be separate responsibilities.

Attendance and leave management are out of scope. Loss-of-pay days and other variable inputs are entered for each payroll run, with a note of the source.

---

## 18. Marriage Hall Management

The community owns a marriage hall and receives rental income.

### 18.1 Customer Categories

- Community members.
- Non-members.

Member status is verified through the member database.

### 18.2 Configurable Rental Rates

| Category (per hall) | Member | Non-Member |
|---|---:|---:|
| Weekday | ₹12,000 | ₹25,000 |
| Weekend | ₹18,000 | ₹35,000 |
| Public Holiday | ₹20,000 | ₹40,000 |
| Half Day | ₹7,000 | ₹15,000 |
| Additional Day | ₹8,000 | ₹18,000 |

These are illustrative values. Each hall has its own rate table.

### 18.3 Additional Charges

- Security deposit.
- Cleaning and electricity.
- Decoration.
- Additional hours or days.

### 18.4 Booking Rules

**One confirmed booking per hall per calendar day.** The organisation can have multiple halls. Once a hall is booked for a date, no other booking can be made for that hall on that date, regardless of time slot; other halls remain available. A booking may cover more than one hall (for example, a main hall and a dining hall) for the same event.

Features include a hall master, an availability calendar per hall and across all halls, booking registration, member/non-member pricing, rent and security deposit collection, rescheduling and receipts.

Advance payments and cancellation-charge policies are **not in the current scope**: a booking is confirmed when the rent and security deposit are paid in full. If a confirmed booking is cancelled, the Manager records the cancellation and decides any refund case by case, with a reason.

Pricing must be locked for confirmed bookings. Rental income must flow into the General Community Fund. Refundable security deposits must be accounted for as liabilities.

### 18.5 Hall Customers

- Every booking is linked to a customer. Members are selected from the member database; non-members are recorded as hall customers with name, mobile number, address and identity document.
- Repeat non-member customers are recognised by mobile number.
- When a member books on behalf of a non-member, the non-member rate applies unless the event is for the member's own family, as declared and approved.

### 18.6 Booking Lifecycle

| Status | Meaning |
|---|---|
| Enquiry | Availability checked, no hold |
| Tentative | Date held without payment; expires automatically after a configured number of days (default 3) |
| Confirmed | Rent and security deposit paid; date blocked; price locked |
| Rescheduled | Moved to another date as per policy |
| Cancelled | Cancelled; any refund decided by the Manager with a reason |
| Completed | Event held; awaiting settlement |
| Settled | Final bill paid and security deposit refunded or adjusted |

Only Tentative and Confirmed bookings block the calendar; a Tentative booking is released when its hold period expires.

### 18.7 Event Settlement and Deposit Refund

- After the event, the Manager records hall inspection, damages, extra hours and electricity or other usage.
- A final bill is generated: rental balance, additional charges and damages.
- Damages and unpaid charges are deducted from the security deposit, with reasons and evidence (photos).
- The remaining deposit is refunded in cash against the customer's acknowledgement; any shortfall is collected.
- Refunds and deductions require Manager approval.

---

## 19. Community Asset Management

The organisation may procure, own, assign, maintain, transfer and dispose of assets.

### 19.1 Asset Categories

- Land and property.
- Furniture.
- Electronics.
- Office equipment.
- Vehicles.
- Community facilities.
- Other assets.

Categories must be configurable.

### 19.2 Asset Purchase Management

Purchase request fields:

- Purchase request ID.
- Asset category, name and description.
- Quantity and estimated cost.
- Purpose and required date.
- Requester.
- Quotations and preferred supplier.
- Department/location.
- Approval status.

Purchase record fields:

- Actual purchase price and date.
- Vendor and invoice number.
- Invoice copy.
- Payment method and reference.
- Warranty.
- Responsible employee.
- Approval details.

### 19.3 Asset Purchase Workflow

```text
Purchase Request
       |
       v
Manager Verification
       |
       v
Business Rule Validation
       |
       v
Approval Stage
       |
       +---- Online Approval
       |
       +---- Offline/Verbal Approval
       |
       +---- Meeting-Based Approval
       |
       v
Record Decision in CFMS
       |
       v
Purchase Authorisation
       |
       v
Procurement
       |
       v
Invoice and Payment
       |
       v
Asset Registration
       |
       v
General Ledger Posting
```

### 19.4 Asset Register

Every asset receives a unique Asset ID.

Maintain asset name, category, description, purchase date and value, supplier, invoice, location, assigned employee/department, warranty expiry, useful life, condition, status and documents.

Statuses: Requested, Approved, Purchased, In Use, Under Maintenance, Transferred, Disposed and Written Off.

### 19.5 Asset Assignment and Transfer

- Assign assets to employees, departments and locations.
- Record transfers and handover acknowledgement.
- Maintain complete assignment history.

### 19.6 Asset Maintenance

Record maintenance date, type, description, service provider, cost, invoice, next maintenance date, warranty claims and repair history.

### 19.7 Asset Depreciation and Valuation

Support purchase value, useful life, depreciation method and rate, depreciation schedule, accumulated depreciation, book value and revaluation.

### 19.8 Asset Disposal

Record asset ID, disposal date and reason, approval, sale value, buyer details, supporting documents, gain or loss and accounting entries.

Historical asset records must remain accessible.

---

## 20. General Community Fund

The General Community Fund is the central fund accounting area.

### 20.1 Income

- Community contributions.
- Loan interest.
- Application fees.
- Marriage hall rental.
- Asset disposal proceeds.
- Other income.

Loan principal repayments are reductions of loan receivables, not income.

### 20.2 Expenditure

- Education assistance.
- Cremation assistance.
- Birthday grants.
- Payroll.
- Daily expenses.
- Asset maintenance.
- Other community expenses.

Loan disbursements are recorded as loan receivables, not ordinary expenses. Asset purchases are recorded as assets where appropriate, not automatically as ordinary expenses.

### 20.3 Restricted and Designated Funds

In addition to the General Community Fund, the organisation can define further funds:

| Fund Type | Example | Rule |
|---|---|---|
| Unrestricted | General Community Fund | Used for any approved purpose |
| Designated | Education Fund, Building Fund set aside by Leadership | Earmarked internally; can be re-designated with Leadership approval |
| Restricted | Donation given only for education or cremation | Used only for the donor's stated purpose |
| Corpus / Endowment | Permanent fund | Principal is not spent; only income may be used if allowed |

- Every income and expenditure transaction records the fund it belongs to (default: General Community Fund).
- Spending from a restricted fund is allowed only for its stated purpose and only up to its available balance.
- Transfers between funds require Leadership approval and are audited.
- Reports: fund balance statement, fund-wise income and expenditure, and restricted fund utilisation.

### 20.4 Member Contributions and Donations

- **Contributions:** the organisation can define contribution schemes (for example monthly or annual membership subscription, special collections), with amount, frequency and due dates. Dues are generated for each member, collected in cash with receipts, and tracked for arrears.
- **Donations:** one-off donations from members or non-members are recorded with donor details, amount, purpose and target fund (restricted or unrestricted).
- When the 80G feature is enabled (Section 4.8), eligible donation receipts are issued in the required format.
- Overdue contributions can be configured to restrict loans or other benefits.
- Reports: contribution collection and arrears, donor register and donations by fund.

---

## 21. General Ledger and Accounting Engine

The General Ledger is the single source of truth for official financial balances. All financial modules must integrate with the accounting engine.

### 21.1 Chart of Accounts

Standard Chart of Accounts template for a cash-basis community organisation. It is cloned into each new organisation, which can add sub-accounts (for example per loan type, fund or expense category) but cannot change the account types. Accounts for optional modules and features appear only when those are enabled.

| Code | Account | Type | Notes |
|---|---|---|---|
| **1000** | **Assets** | | |
| 1110 | Cash in Hand | Asset | The single common cash account, shown in the top bar |
| 1150 | Bank Accounts | Asset | Reserved for future use; not used now |
| 1210 | Loan Principal Receivable – [Loan Type] | Asset | One sub-account per loan type |
| 1310 | Petty Cash Advances – Employees | Asset | |
| 1320 | Salary Advances – Employees | Asset | |
| 1330 | Advances to Vendors | Asset | |
| 1410 | Land and Buildings | Asset | |
| 1420 | Furniture and Fixtures | Asset | |
| 1430 | Electronics and Office Equipment | Asset | |
| 1440 | Vehicles | Asset | |
| 1450 | Community Facilities | Asset | |
| 1490 | Accumulated Depreciation | Contra Asset | Only if depreciation posting is enabled |
| **2000** | **Liabilities (money held for others)** | | |
| 2110 | Security Deposits Held – Hall Bookings | Liability | |
| 2120 | Member Unapplied Receipts | Liability | Excess payments awaiting application or refund |
| 2210 | Member Deposits – Recurring | Liability | Member Deposits module |
| 2220 | Member Deposits – Fixed | Liability | Member Deposits module |
| 2310 | Chit Subscriptions – [Group] | Liability | Chit Funds module |
| 2320 | Chit Prize Payable – [Group] | Liability | Chit Funds module |
| 2330 | Chit Dividend Payable – [Group] | Liability | Chit Funds module |
| 2410 | Statutory Dues Payable (GST, TDS, PF, ESI) | Liability | Only if legal and tax features are enabled |
| **3000** | **Funds** | | |
| 3100 | General Community Fund (Accumulated Fund) | Fund | Surplus or deficit is transferred here at year end |
| 3200 | Designated Funds – [Name] | Fund | |
| 3300 | Restricted Funds – [Name] | Fund | Restricted donations are credited here directly |
| 3400 | Corpus Fund | Fund | |
| **4000** | **Income** | | |
| 4110 | Loan Interest Income | Income | Sub-accounts per loan type if needed |
| 4120 | Application Fee Income | Income | |
| 4130 | Late Fee Income | Income | |
| 4140 | Default Penalty Income | Income | |
| 4150 | Bad Debts Recovered | Income | |
| 4210 | Marriage Hall Rental Income | Income | Sub-accounts per hall if needed |
| 4220 | Hall Additional Charges and Damages | Income | |
| 4310 | Member Contributions | Income | |
| 4320 | Donations – Unrestricted | Income | |
| 4410 | Foreman Commission Income | Income | Chit Funds module |
| 4420 | Chit Late Fee Income | Income | Chit Funds module |
| 4510 | Gain on Asset Disposal | Income | |
| 4900 | Other Income | Income | |
| **5000** | **Expenditure** | | |
| 5110 | Education Assistance | Expense | |
| 5120 | Cremation Assistance | Expense | |
| 5130 | Birthday Grants | Expense | |
| 5140 | Other Community Assistance | Expense | |
| 5210 | Salaries and Allowances | Expense | |
| 5220 | Bonus | Expense | |
| 5310 | Office Expenses | Expense | |
| 5320 | Electricity and Water | Expense | |
| 5330 | Maintenance and Repairs | Expense | Includes asset maintenance |
| 5340 | Travel and Fuel | Expense | |
| 5350 | Food and Refreshments | Expense | |
| 5360 | Medical | Expense | |
| 5370 | Community Activities and Events | Expense | |
| 5390 | Miscellaneous Expenses | Expense | |
| 5410 | Interest on Member Deposits | Expense | Member Deposits module |
| 5510 | Bad Debts Written Off | Expense | |
| 5520 | Loss on Asset Disposal | Expense | |
| 5530 | Depreciation | Expense | Only if depreciation posting is enabled |
| 5540 | Cash Shortage / Excess | Expense (or Income) | Day-end variances |
| 5550 | Rounding Off | Expense (or Income) | |

Mapping rules link each transaction type, loan type, expense category, hall and fund to its accounts, so users never pick accounts for routine transactions.

### 21.2 Double-Entry Accounting

Every posted transaction must contain balanced debit and credit entries.

**Loan disbursement of ₹1,00,000**

| Account | Debit | Credit |
|---|---:|---:|
| Loan Principal Receivable | ₹1,00,000 | — |
| Cash | — | ₹1,00,000 |

**Repayment of ₹10,000: ₹9,000 principal and ₹1,000 interest**

| Account | Debit | Credit |
|---|---:|---:|
| Cash | ₹10,000 | — |
| Loan Principal Receivable | — | ₹9,000 |
| Loan Interest Income | — | ₹1,000 |

**Asset purchase of ₹50,000**

| Account | Debit | Credit |
|---|---:|---:|
| Community Assets | ₹50,000 | — |
| Cash | — | ₹50,000 |

### 21.3 GL Features

- Chart of Accounts.
- General Ledger.
- Automatic journal generation.
- Manual journals with approval.
- Account-wise history.
- Opening balances.
- Debit and credit balances.
- Period-wise balances.
- Journal, payment, receipt, contra and adjustment vouchers.
- Reversal entries.
- Financial period management.
- Daily cash reconciliation and day-end closing.
- Audit trail.

### 21.4 Financial Controls

- Every journal must balance.
- Duplicate posting must be prevented.
- Posted transactions must not be silently deleted.
- Corrections must use reversal or adjustment entries.
- Manual journals require authorised approval.
- Closed periods must be protected.
- All adjustments must be audited.

### 21.5 Accounting Basis and Posting Rules

CFMS uses the **cash basis** of accounting only. Income and expenditure are recorded when cash is actually received or paid. There is no accrual option.

Effects of cash basis to note:

- Interest, late fees and penalties that are due but unpaid are **not** shown as income or receivables in the accounts; they are tracked in the loan module and shown in loan reports (for example interest due and overdue amounts).
- Salaries, vendor bills and other amounts owed are recorded only when paid.
- The Balance Sheet shows cash, loan principal outstanding, advances, fixed assets, money held for others (deposits, chit funds, security deposits) and funds, but not interest receivable or unpaid bills.
- Depreciation is recorded in the asset register; posting it to the ledger is optional.

Standard posting rules:

| Event | Posting |
|---|---|
| Loan disbursement | Dr Loan Principal Receivable / Cr Cash |
| Repayment received | Dr Cash / Cr Loan Principal Receivable (principal), Cr Loan Interest Income (interest), Cr Late Fee Income (late fee) |
| Lump-sum payment reducing principal | Dr Cash / Cr Loan Principal Receivable |
| Early settlement | Dr Cash / Cr Loan Principal Receivable, Cr Loan Interest Income, and any charge to the relevant income account |
| Default penalty received | Dr Cash / Cr Default Penalty Income |
| Interest or penalty waiver | No entry (less is received); the waiver is recorded in the loan module with approval |
| Loan write-off | Dr Bad Debts Written Off / Cr Loan Principal Receivable |
| Application fee | Dr Cash / Cr Application Fee Income |
| Hall rent received | Dr Cash / Cr Marriage Hall Rental Income |
| Security deposit received or refunded | Dr Cash / Cr Security Deposits Held, and the reverse on refund; deductions: Dr Security Deposits Held / Cr Hall Additional Charges and Damages |
| Contribution or unrestricted donation | Dr Cash / Cr Member Contributions or Donations – Unrestricted |
| Restricted donation | Dr Cash / Cr Restricted Funds – [Name] |
| Expense paid | Dr Expense / Cr Cash |
| Salary paid | Dr Salaries and Allowances / Cr Cash |
| Assistance paid | Dr Assistance Expense / Cr Cash |
| Asset purchase | Dr Fixed Asset / Cr Cash |
| Depreciation (optional) | Dr Depreciation / Cr Accumulated Depreciation |
| Year-end close | Surplus or deficit of the year transferred to the General Community Fund |

Rules:

- Posting rules are maintained as versioned configuration (`GENERATE_JOURNAL_ENTRY` journal templates, Section 25.5).
- Financial statements available: Receipts and Payments Account, Income and Expenditure Statement (cash basis), Balance Sheet and fund statements.

### 21.6 Cash Management

All transactions are currently in cash, so cash controls are mandatory.

**Common cash account and day-end closing**

- The organisation uses one common cash account. All users record receipts and payments against it.
- The **top bar** shows the common cash position for the selected working date: opening balance, receipts, payments and current balance.
- The system shows each user's receipts and payments for the day, so collections can be traced to the person.
- At day end, the Manager counts the cash by denomination; the system compares the count with the book balance and records any shortage or excess with a reason.
- Shortages and excesses are posted to the Cash Shortage / Excess account with Manager approval; repeated variances are flagged.
- Once the day is closed, transactions for that date can no longer be added or changed.

**Receipt and voucher series**

- Receipts and payment vouchers are numbered automatically in continuous series per organisation and financial year.
- Numbers are never skipped or reused; cancelled numbers remain visible as cancelled.
- Reprints are marked "DUPLICATE" with the reprint date and user.
- Receipts can be printed on A4 or thermal printers, in the organisation's branding and language.

**Cash payment controls**

- Every cash payment (loan disbursement, assistance, salary, refund, prize, withdrawal, expense) requires the payee's signature or thumb impression on the payment voucher, recorded or scanned.
- There are no limits on single cash receipts or payments.
- There is no cash-in-hand limit.
- No bank accounts are used in the current scope; all money is held as cash. The custodian of the cash and the physical verification are recorded at day end.

**Reports**

- Daily cash book, user-wise collection and payment summary, denomination report, and shortage and excess report.

### 21.7 Working Date Selection

- A **working date** selector is shown at the top of every screen. Users choose the date on which they are recording transactions, and that date becomes the transaction (value) date for everything they enter until they change it.
- The working date is shown in the top bar next to the cash position (Section 21.6).
- The system also records the actual **entry date and time** of every transaction automatically.
- Interest, schedules and overdue status use the working (value) date.
- There is no limit on how far back the working date can be set, except that it cannot fall in a closed accounting period or on a day that has been closed.
- Future working dates are not allowed.
- Every transaction where the working date differs from the entry date is shown in a "Backdated entries" report for the Accountant and Auditor, because backdating affects interest, overdue status and audit trails.

---

## 22. Financial Period Management

The financial year is an organisation setting, defaulting to 1 April to 31 March.

Features:

- Financial year configuration.
- Monthly accounting periods.
- Period opening and closing.
- Year-end closing, with the year's surplus or deficit transferred to the General Community Fund.
- Opening balance carry-forward.
- Adjustment entries.
- Period reopening with authorised approval.

---

## 23. Financial Reports

Reports must be separate from transaction-entry screens and integrated with the General Ledger.

### 23.1 Accounting Reports

- Trial Balance.
- General Ledger.
- Journal Register.
- Cash Book.
- Receipt Register.
- Payment Register.
- Day Book.
- Account Balance.

### 23.2 Financial Statements

- Income and Expenditure Statement.
- Receipts and Payments Account.
- Balance Sheet.
- Cash Flow Statement.
- Fund Position Statement.
- Fixed Asset Schedule.
- Depreciation Schedule.
- Loans outstanding and money held for others.

### 23.3 Loan Reports

- Loan applications and disbursements.
- Outstanding principal.
- Interest due (from loan schedules) and interest collected.
- Repayment history and partial repayments.
- Early settlements.
- Defaulted loans and full settlements.
- Member-wise loan statements.
- Loan ageing.
- Portfolio at risk (outstanding principal of loans overdue more than 30, 60 and 90 days, as a percentage of total outstanding).
- Demand versus collection (amount due versus collected, by day, month and employee).
- Collection efficiency.
- Daily due list and overdue follow-up list.
- Restructured and written-off loans.
- Guarantor exposure.

### 23.4 Other Reports

- Application fee collections.
- Education and cremation assistance.
- Birthday grants.
- Daily expenses and payroll.
- Marriage hall income.
- Asset purchases, maintenance, transfers and disposal.

### 23.5 Management Reports

- Monthly income and expenditure.
- Annual financial summary.
- General Fund balance.
- Cash balance.
- Outstanding loans and default percentage.
- Total assistance distributed.
- Employee expenditure.
- Total asset value.

Reports must support **Excel (.xlsx) and PDF** exports, following the general export standard (Section 36, Export).

---

## 24. Workflow Engine – Core Architecture

The Workflow Engine must be generic and reusable across all modules. It must not contain module-specific business logic.

### 24.1 Workflow Components

1. Workflow Definition.
2. Workflow Version.
3. Workflow Instance.
4. Workflow Stage/State.
5. Workflow Transition.
6. Workflow State Action.
7. Action Definition.
8. Action Configuration.
9. Action Execution.
10. Workflow History.

| Component | Responsibility |
|---|---|
| Workflow Definition | Defines a business process |
| Workflow Version | Maintains workflow revisions |
| Workflow Instance | Represents an active business process |
| Workflow Stage | Defines the current process stage |
| Workflow Transition | Determines the next stage |
| State Action | Defines what executes at a stage |
| Action Definition | Defines available executable actions |
| Action Configuration | Stores action parameters |
| Action Execution | Stores execution results |
| Workflow History | Maintains historical state changes |

### 24.2 JSON-Driven Workflows and Rules

Workflows and business rules are **JSON-driven**. Every workflow and every rule set is a JSON document; the engines read these documents at run time, so changing a process or a rule never requires a code change or a release.

- **One JSON per organisation and version:** each organisation has its own workflow and rule JSON documents (Section 35.4). Templates are JSON too and are copied into an organisation at onboarding.
- **Stored in PostgreSQL** as `jsonb`, with a version number, status (Draft, Published, Retired), effective date, checksum, author and publisher. Published versions are never edited; a change creates a new version. Running transactions keep the version they started with.
- **Validated against a JSON Schema** before saving and again before publishing. Validation also checks references: every stage, transition, action code, rule code, role and account must exist and be enabled for the organisation; there must be exactly one start stage, every stage must be reachable, and no stage may be a dead end except end stages. An invalid document cannot be published.
- **Configured by the Super Administrator only.** The Super Admin console provides:
  - a visual designer for workflows and a form-based editor for rules, both of which produce the JSON;
  - a read-only JSON view of any version, and a side-by-side comparison (diff) between versions;
  - JSON export, and JSON import (for example to copy a workflow from a template or another organisation), always followed by schema validation and saved as a Draft;
  - a test run of a draft against sample data before publishing.
- Organisation users never see or edit JSON.

**Audit history of workflow and rule JSON**

- **Every version is kept permanently**, including drafts that were published, retired or replaced. Versions are never overwritten or deleted, and are kept at least as long as the transactions processed under them (Section 36, Data Retention).
- Each version records: version number, who created it, who published it, date and time of each, the **reason for the change** (mandatory), effective date, status, checksum, and the source (designer, import, template upgrade or restore).
- Every action on a document is logged: create draft, edit, validate (with result), test run, publish, retire, import, export and restore.
- **History screen:** for any workflow or rule set, the Super Administrator sees the full version list and can open any version as JSON or in the designer.
- **Compare (diff):** any two versions can be compared side by side, highlighting added, removed and changed stages, transitions, actions and rule values.
- **Restore:** an earlier version can be restored by creating a new version that copies it, with a mandatory reason. The history itself is never rewritten, and restore follows the same validation and publishing steps as any change.
- **Version stamping:** every transaction records the workflow version and the rule set version it was processed under (for example a loan keeps the interest, fee and penalty rule version in force when it was approved). Its screens, statements and audit trail show those versions, and recalculations use them.
- The organisation's Auditor and Leadership can view the change history of their organisation's workflows and rules (who, when, reason, effective date and a readable summary of the change), but not edit them.
- History is exportable to Excel and PDF, and each JSON version can be exported for audit.

Simplified workflow JSON example:

```json
{
  "workflow": "LOAN_APPLICATION",
  "version": 3,
  "schemaVersion": "1.0",
  "startStage": "DRAFT",
  "stages": [
    { "code": "DRAFT", "role": "EMP",
      "actions": [
        { "seq": 1, "action": "VALIDATE_MEMBER_STATUS", "type": "validation" },
        { "seq": 2, "action": "VALIDATE_LOAN_ELIGIBILITY", "type": "validation" }
      ] },
    { "code": "MANAGER_APPROVAL", "role": "MGR", "approval": { "methods": ["online", "offline"] },
      "actions": [
        { "seq": 1, "action": "SEND_NOTIFICATION", "type": "async",
          "config": { "channel": "SMS", "template": "LOAN_APPROVED" } }
      ] },
    { "code": "APPROVED", "end": false },
    { "code": "REJECTED", "end": true }
  ],
  "transitions": [
    { "from": "DRAFT", "to": "MANAGER_APPROVAL", "on": "SUBMIT" },
    { "from": "MANAGER_APPROVAL", "to": "APPROVED", "on": "APPROVE" },
    { "from": "MANAGER_APPROVAL", "to": "REJECTED", "on": "REJECT" }
  ]
}
```

The exact JSON Schema for workflows and rules is defined in the SRS.

---

## 25. Workflow State Action Engine – IAction Architecture

This is a mandatory technical requirement.

CFMS must support a plugin-style action architecture based on a common action contract (referred to in this document as `IAction`). Every registered implementation of this contract should be discoverable and available for selection in the Workflow Designer. When a workflow stage executes, the configured actions associated with that stage are triggered.

**Technology neutrality:** The application stack has not been decided (PostgreSQL is the chosen database; a Python API with a Flutter client is under consideration). The requirement is the behaviour of the action contract and registry, not any particular language feature. The code samples in this section use C#-style notation for illustration only and are not a technology decision. In the chosen stack the contract may be implemented as an interface, abstract base class, protocol or equivalent, and discovery may use decorators, entry points, plugin registration or configuration.

### 25.1 Action Contract (IAction)

Every action must provide:

| Element | Requirement |
|---|---|
| Action Code | Stable, unique identifier stored in the database |
| Name | Display name for the Workflow Designer |
| Execute | Operation that receives an Action Context and returns an Action Result, supports cancellation and may run asynchronously |

Illustrative pseudocode (C#-style notation):

```csharp
public interface IAction
{
    string ActionCode { get; }

    string Name { get; }

    Task<ActionResult> ExecuteAsync(
        ActionContext context,
        CancellationToken cancellationToken
    );
}
```

### 25.2 ActionResult

Illustrative structure:

```csharp
public class ActionResult
{
    public bool Success { get; set; }

    public string Message { get; set; }

    public object? Output { get; set; }

    public bool ShouldContinue { get; set; }

    public string? ErrorCode { get; set; }
}
```

### 25.3 ActionContext

Illustrative structure:

```csharp
public class ActionContext
{
    public Guid WorkflowInstanceId { get; set; }

    public Guid WorkflowStageId { get; set; }

    public Guid TransactionId { get; set; }

    public string TransactionType { get; set; }

    public string CurrentState { get; set; }

    public string CurrentUserId { get; set; }

    public IDictionary<string, object> Data { get; set; }
}
```

The context provides controlled access to the transaction and workflow information required by an action. Actions should access business functionality through registered application services, not directly manipulate unrestricted database tables.

### 25.4 Dynamic Action Discovery

When the application starts:

1. Discover available action implementations.
2. Register actions with the application's service container or registry mechanism.
3. Read action metadata.
4. Register actions in the Action Registry.
5. Make available actions visible in the Workflow Designer.

**Approval of new actions:** new action implementations are registered and approved by the Platform Super Administrator only. A newly discovered action stays in "Pending approval" and is not visible in any organisation's Workflow Designer until the Super Administrator approves it and enables it for the organisations that should use it. Organisation users cannot register or approve actions.

Example action catalogue:

| Action Code | Display Name | Category |
|---|---|---|
| VALIDATE_LOAN_ELIGIBILITY | Validate Loan Eligibility | Validation |
| VALIDATE_APPLICATION_FEE | Validate Application Fee | Validation |
| VALIDATE_NOMINEE | Validate Nominee | Validation |
| SEND_NOTIFICATION | Send Notification | Notification |
| GENERATE_REPAYMENT_SCHEDULE | Generate Repayment Schedule | Loan |
| GENERATE_JOURNAL_ENTRY | Generate Journal Entry | Accounting |
| RECORD_OFFLINE_APPROVAL | Record Offline Approval | Approval |
| GENERATE_RECEIPT | Generate Receipt | Finance |

When a developer adds a new valid action implementation and registers it, it should become available in the Workflow Designer without changes to the Workflow Engine.

The database should store stable action codes rather than arbitrary class names. Only approved, registered implementations should be executable.

### 25.5 Action Metadata and Dynamic Configuration

Each action should expose metadata describing its configuration fields.

Examples:

**SEND_NOTIFICATION**
- Notification channel.
- Recipient type.
- Message template.
- Delay.
- Retry count.

**VALIDATE_LOAN_ELIGIBILITY**
- Check default history.
- Check outstanding loans.
- Check cooling-off period.
- Check member status.

**GENERATE_JOURNAL_ENTRY**
- Journal template.
- Debit account mapping.
- Credit account mapping.
- Posting mode.

The Workflow Designer should display the appropriate configuration fields based on the selected action.

### 25.6 Workflow Designer

The Workflow Designer is a Platform Super Administrator tool only; it is not available to any organisation user. The Super Administrator selects an organisation's workflow and configures actions for every stage.

Example: **Loan Application – Manager Verification**

| Sequence | Action | Execution Type |
|---:|---|---|
| 1 | Validate Member Status | Synchronous |
| 2 | Validate Application Fee | Synchronous |
| 3 | Validate Nominee | Synchronous |
| 4 | Validate Loan Eligibility | Synchronous |
| 5 | Send Manager Notification | Asynchronous |

Super Administrator capabilities:

- Add and remove actions.
- Change execution sequence.
- Configure action parameters.
- Enable or disable an action.
- Mark an action mandatory.
- Mark an action as a validation (blocks the stage on failure).
- Configure the retry count for notification actions.
- Configure execution type.

Actions should be reusable across workflows and modules.

### 25.7 Stage Execution

When a workflow enters a stage:

1. Load the stage definition.
2. Load its configured actions.
3. Order actions by execution sequence.
4. Resolve each action through the Action Registry.
5. Build the Action Context.
6. Execute the action.
7. Store the execution result.
8. Evaluate failure handling.
9. Continue or pause the stage.

**Failure policy (validation enforced):**

- Validation actions run first. If any mandatory validation fails, the transaction does not move to the next stage; the user sees the reason and must correct the data and resubmit.
- An action that changes data (for example posting a journal or generating a schedule) runs only after all validations pass, inside a database transaction. If it fails, the whole step is rolled back and the transaction stays in its current stage.
- Every failure is written to a failure log (action, transaction, error, user, time), visible on the Administration Dashboard.
- Notification actions (SMS, WhatsApp, email) are the only actions retried automatically, a configurable number of times; a notification failure never blocks the transaction.
- There is no automatic compensation logic in the current scope. A failed step is either corrected and resubmitted, or reversed through the normal reversal process.
10. Evaluate workflow transition rules when the stage is complete.

Illustrative execution logic (pseudocode, C#-style notation):

```csharp
public async Task ExecuteStageAsync(
    WorkflowInstance instance,
    WorkflowStage stage,
    CancellationToken cancellationToken)
{
    var actions = await repository
        .GetStageActionsAsync(stage.Id);

    foreach (var stageAction in actions.OrderBy(x => x.Sequence))
    {
        var action = actionRegistry.Get(
            stageAction.ActionCode);

        var context = BuildActionContext(instance, stage);

        var result = await action.ExecuteAsync(
            context,
            cancellationToken);

        await SaveActionExecutionAsync(
            stageAction,
            result);

        if (!result.Success || !result.ShouldContinue)
        {
            // Apply configured failure handling.
            break;
        }
    }
}
```

This is conceptual implementation logic. Production execution must include persistence, idempotency, retries, concurrency controls and recovery.

### 25.8 Action Execution Types

| Type | Description |
|---|---|
| Synchronous | Execute immediately and wait for result |
| Asynchronous | Execute through a background queue |
| Conditional | Execute when configured conditions are satisfied |
| Parallel | Execute independent actions concurrently |
| Manual | Wait for a user or authorised person |
| Scheduled | Execute at a configured future time |

Example after loan approval:

- Generate repayment schedule: synchronous.
- Create accounting posting instruction: synchronous.
- Send SMS: asynchronous.
- Notify manager: asynchronous.

A notification being queued must not be treated as proof that the recipient received it.

### 25.9 Supporting Interfaces

Illustrative contracts (pseudocode); equivalents are required in the chosen stack.

```csharp
public interface IActionMetadata
{
    string ActionCode { get; }

    string Name { get; }

    string Description { get; }

    string Category { get; }

    string ConfigurationSchema { get; }
}
```

```csharp
public interface IActionValidator
{
    Task<ActionValidationResult> ValidateAsync(
        ActionContext context,
        CancellationToken cancellationToken
    );
}
```

```csharp
public interface IActionRegistry
{
    IAction Get(string actionCode);

    IEnumerable<IActionMetadata> GetAvailableActions();
}
```

The Action Registry provides the list of actions available to the Workflow Designer.

### 25.10 Action Execution History

Every execution must be recorded.

| Field | Example |
|---|---|
| Workflow | Loan Application |
| Transaction | LOAN-2026-00125 |
| Stage | Manager Verification |
| Action | Validate Loan Eligibility |
| Execution Type | Automatic |
| Status | Success |
| Executed By | System |
| Start Time | Date/time |
| Completion Time | Date/time |
| Result | Eligible |

Failed actions must retain error details. Retries must not create duplicate financial postings or duplicate business transactions.

---

## 26. State Actions and State Transitions Must Be Separate

This is an important architectural rule.

- **State Action:** Defines what the system does when a stage executes.
- **State Transition:** Determines where the workflow moves next.

Example:

```text
Manager Verification
         |
         v
Validate Loan Application
         |
         v
Manager Decision
         |
      +--+--+
      |     |
   Approved Rejected
      |     |
      v     v
 Approval  Rejection
 Approval  Process
```

The validation action does not independently decide the next workflow stage. The Transition Engine evaluates conditions and action results to determine the next state.

---

## 27. Example: Loan Workflow Using IAction

| Stage | Configured Actions |
|---|---|
| Application Created | Generate application reference, calculate application fee, send acknowledgement |
| Fee Collection | Validate fee, generate receipt, post fee accounting entry |
| Manager Verification | Validate member, validate nominee, validate eligibility |
| Manager Approval | Validate approval authority, collect decision, record online/offline approval |
| Loan Approved | Generate repayment schedule, create disbursement instruction |
| Loan Disbursement | Record payment, generate receipt, post GL entry |
| Repayment Active | Generate reminders, update loan balances |
| Early Settlement | Calculate settlement, generate statement, validate payment, close loan |
| Default | Calculate outstanding amount, restrict eligibility, generate recovery notification |

Each stage executes only the actions configured for that workflow version.

---

## 28. Flexible Approval Management

Approval management must be integrated with the Workflow State Action Engine.

The system must support:

- Online approval.
- Offline approval.
- Verbal approval.
- Meeting-based approval.
- Document-based approval.
- Delegated approval.
- Single approver per decision, irrespective of amount (no committee voting or quorum).
- Independent verification.
- Approval evidence.
- Approval history.

### 28.1 Offline Approval Recording

| Field | Description |
|---|---|
| Transaction Reference | Related request |
| Approved By | Actual decision-maker |
| Approver Role | Manager, Leadership or other authority |
| Approval Method | Verbal, meeting or document |
| Evidence Type | Selected from the organisation's configurable evidence list (mandatory selection) |
| Decision | Approved, rejected or returned |
| Approval Date | Actual decision date |
| Recorded By | Person entering decision |
| Recorded Date | System entry date |
| Meeting Reference | Meeting reference, if applicable |
| Supporting Document | Optional upload |
| Remarks | Additional explanation |

Only roles configured as permitted (Section 4.7) can record an offline decision.

### 28.2 Three Separate Identities

Every approval must distinguish:

1. Requested By.
2. Approved By.
3. Recorded By.

An offline decision must never be represented as an online approval.

### 28.3 Example Workflow

```text
Approval Stage
           |
           v
Decision Required
           |
      +----+----+
      |         |
   Online     Offline
   Approval   Decision
      |         |
      |    Record Decision
      |         |
      +----+----+
           |
           v
   Validate Approval Authority
           |
           v
     Approval Recorded
           |
           v
     Continue Workflow
```

### 28.4 Single Approver Rule

- Every approval is given by one authorised person, irrespective of the transaction amount. There are no amount-based approval levels, no provisional approval and no independent confirmation step.
- The approver must be a different person from the requester and the person who recorded the transaction.
- The approving role for each workflow stage is configurable (default: Manager).

### 28.5 Escalation (Defaulters Only)

- Escalation applies only to defaulted loans. There are no time-limit escalations for ordinary approvals.
- When a loan defaults, the recovery case is assigned to the responsible employee. If the defaulter has not paid within a configurable number of days (default 30), the case escalates to the Manager, and then to Leadership after a further configurable period.
- Pending approvals are still shown on dashboards and in an approval ageing report, without automatic escalation.

### 28.6 Return, Resubmission, Withdrawal and Cancellation

- An approver can **approve**, **reject** (with reason) or **return for correction** (with comments).
- A returned request goes back to the creator, who corrects and resubmits it; the history of each round is kept.
- The requester can **withdraw** a request before a final decision.
- An authorised user can **cancel** an in-flight workflow with a reason; any completed financial postings are reversed through the normal reversal process.
- Rejected, withdrawn and cancelled requests remain on record.

---

## 29. Business Rules Engine

The Business Rules Engine controls configurable business conditions.

Rules include:

- Loan eligibility and interest calculations.
- Application fees and waivers.
- Nominee requirements.
- Early settlement.
- Default calculations and cooling-off.
- Education, cremation and birthday assistance.
- Expense limits and payroll calculations.
- Marriage hall pricing.
- Asset purchase approval and depreciation.
- Approval authority and offline approval permissions.
- Financial posting rules.

Each rule must maintain:

- Rule ID.
- Module.
- Condition and action.
- Effective and expiry dates.
- Version and status.
- Created by and approved by.

Rule changes must not retroactively alter existing approved transactions unless an authorised correction process explicitly permits it.

### 29.1 JSON Rule Definitions

Business rules are stored as JSON documents per organisation, versioned and validated against a JSON Schema in the same way as workflows (Section 24.2), and configured only by the Super Administrator. Rules are grouped in rule sets (for example one rule set per loan type).

Simplified rule JSON example (default penalty for a loan type):

```json
{
  "ruleSet": "LOAN_TYPE_NORMAL",
  "version": 2,
  "effectiveFrom": "2027-04-01",
  "rules": [
    { "code": "DEFAULT_AFTER_MONTHS", "value": 2 },
    { "code": "DEFAULT_PENALTY",
      "when": { "all": [ { "field": "loan.status", "op": "eq", "value": "DEFAULTED" } ] },
      "then": { "type": "percent", "of": "outstandingPrincipal", "value": 2 } },
    { "code": "APPLICATION_FEE", "then": { "type": "fixed", "value": 100 } }
  ]
}
```

- Conditions use a fixed set of operators (equals, not equals, greater or less than, between, in list, all, any) on a published list of fields, so that rules cannot run arbitrary code.
- The engine evaluates the version in force on the transaction's working date.

---

## 30. Notification Engine

The system must support SMS, WhatsApp, email and in-app notifications.

### 30.1 Loan Reminders

| Reminder | Timing |
|---|---|
| First | 7 days before |
| Second | 3 days before |
| Third | 1 day before |
| Due Date | On due date |
| Overdue | 1 day after |
| Further Overdue | Every 7 days |

Intervals must be configurable.

### 30.2 Other Notifications

- Loan application status and fee receipt.
- Loan approval/rejection and disbursement.
- Repayment and partial repayment receipts.
- Early settlement, default and full settlement.
- Cooling-off completion.
- Education and cremation assistance.
- Marriage hall booking.
- Expense and payroll approval.
- Asset approval and registration.
- Maintenance reminders and warranty expiry.
- Pending offline approval recording.
- Provisional approval confirmation.

The Notification Engine should expose reusable actions such as `SendNotificationAction`.

### 30.3 SMS and WhatsApp Compliance and Delivery

- **SMS:** each organisation's sender ID and every message template must be registered on the telecom DLT (Distributed Ledger Technology) platform as required by TRAI; CFMS stores the registered template ID with each template and sends only registered templates.
- **WhatsApp:** messages use the WhatsApp Business Platform through an approved provider; templates must be approved before use, and members must have opted in.
- **Consent:** each member's consent and preferred channel and language are recorded; members can opt out of non-essential messages.
- **Delivery status:** delivery reports from providers (sent, delivered, failed, read where available) are stored per message.
- **Fallback:** if a WhatsApp message fails, the system can send SMS instead, as configured.
- **Quiet hours:** routine reminders are not sent between 9 PM and 8 AM (configurable).
- **Costs:** messages are counted per organisation for reporting (and for billing in future, Section 35.7).

---

## 31. Audit Management

The Audit Engine must record all significant actions and changes, including:

- Member management.
- Loans, fees, repayments, settlements and defaults.
- Expenses and payroll.
- Hall bookings and assistance.
- Assets and accounting entries.
- Manual journals.
- Workflow and action executions.
- Approval decisions and offline approvals.
- User and role changes.

Each audit record should capture:

- User and role at the time.
- Action and record affected.
- Previous and new values.
- Date and time.
- Reason.
- Approval reference.
- Actual approver.
- Recording user.
- Approval method.
- Supporting evidence reference.

Action execution logs and financial audit logs should be linked but remain logically distinct.

### 31.1 Record-Level Audit History on All Data

Every record in CFMS keeps a complete audit history of its data, not only of rules and workflows.

**Scope:** every business and master entity, including members, nominees, guarantors, loans, schedules, fees, receipts and payments, settlements, defaults and recovery cases, deposits, chit groups and tickets, assistance, expenses, vendors, payroll, employees, hall bookings and customers, assets, Chart of Accounts and journals, users, roles and privileges, organisation settings, and the Super Admin's tenant and module settings.

**What is recorded for every create, change, status change, cancellation, reversal and soft deletion:**

| Field | Description |
|---|---|
| Record | Entity type and record identifier (for example Loan LN-2027-0045) |
| Operation | Create, Update, Status change, Cancel, Reverse, Delete (soft), Restore |
| Field-level changes | For each changed field: field name, old value and new value |
| Changed by | User and the role they acted in at the time |
| When | Actual system date and time (server time, in the organisation's time zone) |
| Working date | The working date selected in the top bar, shown separately when it differs from the actual date (backdated entries) |
| Channel | Web, Mobile, Super Admin console, import or migration, or system job |
| Device and IP address | Device type and IP address of the session |
| Reason | Mandatory for corrections, cancellations, reversals, overrides, waivers and changes to sensitive fields (such as name, mobile number, amounts, interest and dates); optional otherwise |
| Reference | Linked workflow instance, approval, transaction or batch, where applicable |

**Rules**

- The audit history is **append-only**. No user, including the organisation administrator and the Super Administrator, can edit or delete audit records; this is enforced in the database, not only in the application.
- Posted financial transactions are never edited; corrections are made by reversal and re-entry, and both appear in the history.
- Records are not physically deleted during normal use; "delete" is a soft deletion that stays in the history. Physical removal happens only through the approved purge process (Section 36, Data Archival and Purge), which itself leaves a purge certificate.
- Personal data shown in the history follows the same privileges as the record; sensitive values (for example identity numbers) are masked for roles that cannot see them on the record.
- Changes made by background jobs and data migration are recorded with the job or batch name as the source.

**Viewing**

- Every record screen has a **History** tab showing a timeline of all changes, newest first, with field-level old and new values, who, when, working date, channel and reason.
- The History tab is visible to users who can view the record and hold the audit-history privilege (by default Manager, Accountant, Leadership and Auditor; Employees see the history of records they created).
- A central **Audit Log** screen (Audit Management module) lets the Auditor and Leadership search across all records by entity, record, user, date range, operation, channel, working-date versus actual-date difference, and field.
- History and audit log results support search, refresh and Excel/PDF export (Section 36).
- Audit history is retained as set out in the Data Retention table (at least 8 years for financial records).

---

## 32. Dashboards

Dashboards are modules (Section 3.8). The dashboards below are the default set, and each is the default home page for its role. Additional dashboard modules can be added at any time through configuration and granted to roles through the privilege matrix (Section 3.3).

### Employee Dashboard

- Member registration.
- Loan applications and fee collections.
- Repayments, partial payments and early settlements.
- Upcoming due dates.
- Hall bookings.
- Expense and asset purchase requests.
- Pending tasks.

### Manager Dashboard

- Applications awaiting verification.
- Expenses awaiting approval.
- Defaulted loans and upcoming repayments.
- Early settlement requests.
- Hall bookings.
- Asset purchase requests and maintenance.
- Loans, assistance, waivers and cooling-off overrides awaiting approval.
- Recovery cases and escalated defaulters.
- Offline decisions awaiting recording.
- Previous approval decisions.

### Accountant Dashboard

- Unposted and draft vouchers.
- Manual journals awaiting approval.
- Cash position and day-end closing status.
- Current accounting period status and closing checklist.
- Cash balances.
- Trial Balance summary.
- Payroll runs awaiting preparation or posting.
- Depreciation runs due.
- Failed or pending automatic postings.

### Auditor Dashboard

- Income and expenditure.
- Outstanding loans and interest collections.
- Application fees and early settlements.
- Payroll and expenses.
- Hall income.
- Asset register, purchases and disposals.
- Trial Balance.
- Approval records and audit exceptions.

### Leadership Dashboard

- General Fund balance.
- Total income and expenditure.
- Loan portfolio and defaults.
- Early settlements.
- Interest and application fee income.
- Assistance.
- Payroll.
- Hall rental income.
- Asset portfolio, procurement and maintenance.
- Pending approvals.

### Administration Dashboard

- User accounts awaiting activation or deactivation.
- Recent role and permission changes.
- Configuration, workflow and rule changes awaiting approval.
- Failed action executions and retries.
- Failed notifications.
- Login and security alerts.
- Background job and system health status.

---

## 33. Database Architecture

In addition to business module tables, the following core tables are required. Every tenant-owned table carries a `tenant_id` column protected by PostgreSQL Row-Level Security (Section 35.2).

### 33.1 Workflow Tables

| Table | Purpose |
|---|---|
| WorkflowDefinition | Workflow master |
| WorkflowVersion | Workflow versions, each holding the full workflow JSON (`jsonb`), status, effective date and checksum |
| WorkflowInstance | Active workflow instances |
| WorkflowStage | Workflow stages |
| WorkflowTransition | State transitions |
| WorkflowCondition | Transition conditions |
| WorkflowContext | Persisted workflow data |
| WorkflowHistory | State change history |
| RuleSet | Rule sets per organisation (for example per loan type) |
| RuleSetVersion | Rule set versions, each holding the rules JSON (`jsonb`), status, effective date and checksum |
| JsonSchemaVersion | JSON Schemas used to validate workflow and rule documents |
| AuditEvent | One row per create, change, status change, cancellation, reversal or soft deletion of any record: entity, record, operation, user, role, actual time, working date, channel, device, IP, reason, reference (append-only, tenant-owned) |
| AuditFieldChange | Field-level old and new values for each audit event (append-only) |
| ConfigChangeLog | Every action on workflow and rule versions (create, edit, validate, test, publish, retire, import, export, restore) with user, time and reason |

### 33.2 Action Tables

| Table | Purpose |
|---|---|
| ActionDefinition | Registered action catalogue, with Super Administrator approval status and per-tenant enablement |
| ActionFailureLog | Failed action executions (action, transaction, error code, message, correlation id, user, time) |
| ActionConfiguration | Action configuration |
| WorkflowStageAction | Actions assigned to stages |
| ActionExecution | Execution records |
| ActionExecutionLog | Detailed execution logs |

### 33.3 Approval Tables

| Table | Purpose |
|---|---|
| ApprovalRequest | Approval requests |
| ApprovalDecision | Actual approval decisions |
| ApprovalParticipant | Individual approvers |
| ApprovalEvidence | Documents and supporting evidence |
| ApprovalMeeting | Meeting references |
| ApprovalDelegation | Delegated authority |
| ApprovalPolicy | Approval rules |
| ApprovalVerification | Independent verification records |

### 33.4 Platform Tables

| Table | Purpose |
|---|---|
| Tenant | Organisation (tenant) master and status |
| Module | Module Registry: code, type, parent, is_menu, menu order, icon, route, plan feature; maintained by SQL only (Section 3.9) |
| TenantSettings | Branding and tenant-level settings, copied from the default settings template at creation |
| TranslationText | One row per text ID and language: text, module, text type, status, version (platform-level, Super Admin only) |
| LanguagePack | Published language pack versions per language |
| ErrorCode | Error code catalogue `platform.error_code`, with action codes, error logs and database error maps (platform-level, Section 34.1) |
| DefaultSettingsTemplate | Platform default value for every organisation setting, versioned (Section 4.10) |
| TenantModule | Modules enabled for each tenant, with enabled/disabled dates and who changed them (Super Administrator only) |
| PurgePolicy | Purge on/off and retention years per data category, per tenant |
| PurgeRun | Purge candidate reports, approvals, archive references and status |
| PurgeCertificate | Permanent record of each completed purge run |
| TenantComplianceSetting | Legal and tax features enabled per tenant, with effective dates (Section 4.8) |
| SubscriptionPlan | Plans, features and limits (future scope) |
| TenantSubscription | Tenant plan, billing cycle and status (future scope) |
| UsageRecord | Metered usage (SMS, WhatsApp, storage) for reporting |
| PlatformUser | Platform operator accounts |
| AppUser | Organisation users: name, contact, status, `web_access` and `mobile_access` flags, username, linked employee (tenant-owned) |
| Role | Standard and custom roles per tenant, with type (standard or custom), status and default home page (tenant-owned) |
| RolePrivilege | Privileges granted to each role per module, within the Super Administrator's ceiling (tenant-owned) |
| UserRole | Roles assigned to each user, with effective dates (tenant-owned) |
| UserActivation | Activation links sent, expiry and use |
| SignInHistory | Sign-in attempts per user (time, device, IP address, result) |
| WorkflowTemplate | Template workflows and rule sets cloned into tenants |
| ConfigurationDelegation | Default modules, roles and privileges provided to each tenant |
| PlatformAccessLog | Break-glass and platform access to tenant data |

### 33.5 Deposit Tables

| Table | Purpose |
|---|---|
| DepositProduct | Deposit product definitions and versions |
| DepositRateSlab | Interest rates by tenure and amount band |
| DepositAccount | Member deposit accounts and status |
| DepositTransaction | Deposits, withdrawals, interest and payouts |
| DepositNominee | Nominees and share percentages |
| DepositLien | Liens against loans |

### 33.6 Chit Fund Tables

| Table | Purpose |
|---|---|
| ChitScheme | Chit scheme templates and versions |
| ChitGroup | Chit groups, optional registration details and status |
| ChitTicket | Member enrolments (tickets) and status |
| ChitInstalment | Monthly subscriptions due and paid |
| ChitAuction | Auctions, bids, draws, results and minutes |
| ChitDividend | Dividend per month and per ticket |
| ChitPrize | Prize calculation, security and payout |

### 33.7 Operational Tables

| Table | Purpose |
|---|---|
| Branch | Single default branch per organisation (multiple branches are future scope) |
| MemberStatusHistory | Membership lifecycle events |
| Guarantor | Loan guarantors and consent |
| LoanRestructure | Restructuring requests and new schedule versions |
| RecoveryCase / RecoveryContact | Recovery cases and contact log |
| WriteOff | Write-off proposals and approvals |
| CashDay | Daily cash position, denomination count, variance and day-end closing |
| VoucherSeries | Receipt and voucher numbering series |
| PettyCashAdvance | Imprest advances and settlements |
| Vendor / VendorBill | Vendor master and vendor bills |
| Fund | Unrestricted, designated, restricted and corpus funds |
| ContributionScheme / ContributionDue | Contribution schemes and member dues |
| Donation | Donations and donors |
| Hall | Hall master: name, capacity, facilities, status |
| HallRate | Rates per hall, customer category and day type |
| HallCustomer | Non-member hall customers |
| HallSettlement | Post-event inspection, charges and deposit refunds |

### 33.8 Accounting Tables

| Table | Purpose |
|---|---|
| ChartOfAccounts | Account master |
| JournalHeader | Journal master |
| JournalLine | Debit and credit lines |
| FinancialPeriod | Accounting periods |
| BankAccount | Bank account master (future use) |
| CashAccount | Cash account master |
| Reconciliation | Cash reconciliation |

The database should enforce appropriate foreign keys, unique constraints, financial integrity and transaction consistency.

---

## 34. Technical Architecture

The database is decided: **PostgreSQL**. The rest of the technology stack is not yet decided; a Python API with a Flutter client is under consideration. This scope therefore states required capabilities rather than specific products; the selected stack must satisfy all of them.

| Component | Required Capability |
|---|---|
| Client | Responsive user interface for internal users; must handle data-heavy screens, tables and reports |
| Backend API | Service layer exposing business functionality through documented APIs |
| Database | **PostgreSQL (decided).** Use ACID transactions, foreign keys, unique constraints, row-level locking and check constraints for financial integrity |
| Authentication | Secure authentication, RBAC and multi-factor authentication for privileged roles |
| Workflow Engine | Configurable workflow engine (custom-built or an existing engine, to be evaluated) |
| State Actions | Action contract with Action Registry and dynamic discovery (Section 25) |
| Background Processing | Durable job queue for asynchronous, scheduled and retried actions |
| Business Rules | Central, versioned rules engine |
| Approval Management | Flexible approval service |
| Accounting | Double-entry accounting engine |
| File Storage | Secure object storage for documents and evidence |
| Notifications | SMS, WhatsApp and email provider integrations |
| Reporting | Reporting with Excel and PDF export |
| Hosting | Multi-tenant SaaS on Microsoft Azure or AWS, in Indian regions (Section 35) |

**Client platform to confirm:** A responsive web application should be developed first. A dedicated mobile application can be considered later. If Flutter is chosen, confirm whether the first release targets web, Android or both, because Flutter Web has trade-offs for report-heavy and table-heavy screens. This decision affects the screen specifications in the SRS.

### 34.1 Exception Management and Error Codes

Every error that CFMS raises, whether shown to a user, returned by the API or written to a log, carries a **stable error code** from a central catalogue. This lets users report problems precisely, lets support find the cause quickly, and keeps messages consistent across web, mobile and the Super Admin console.

**Error code format:** `CFMS-<MODULE>-<NNNN>`

- `<MODULE>` is a short module code, for example `AUTH`, `USER`, `ORG`, `MEM`, `LOAN`, `FEE`, `REPAY`, `SETL`, `DEF`, `DEP`, `CHIT`, `ASST`, `EXP`, `PAY`, `HALL`, `ASSET`, `ACC` (accounting and cash), `WF` (workflow), `RULE`, `ACT` (actions), `APPR` (approvals), `NOTIF`, `RPT`, `AUDIT`, `PLAT` (platform and tenancy), `SYS` (system).
- `<NNNN>` is a four-digit number. The first digit gives the category, so that the type of error can be seen from the code itself:

| Range | Category | Meaning | HTTP Status | Example |
|---|---|---|---|---|
| 1000–1999 | Validation | Input is missing, malformed or out of range | 400 / 422 | `CFMS-MEM-1003` Mobile number is not valid |
| 2000–2999 | Business rule | Input is valid but a business rule does not allow it | 422 | `CFMS-LOAN-2007` Member is in a cooling-off period |
| 3000–3999 | Authorisation | Not signed in, session expired, no privilege, module disabled or platform not allowed | 401 / 403 | `CFMS-AUTH-3004` Mobile access is not enabled for this user |
| 4000–4999 | Not found | The record does not exist or is outside the user's tenant or access | 404 | `CFMS-LOAN-4001` Loan not found |
| 5000–5999 | Conflict and concurrency | The record was changed by someone else, a duplicate exists, or the state does not allow the step | 409 | `CFMS-REPAY-5002` Receipt already posted |
| 6000–6999 | Integration | An external service failed (SMS, WhatsApp, email, storage) | 502 / 503 | `CFMS-NOTIF-6001` SMS provider did not respond |
| 9000–9999 | System | Unexpected internal error | 500 | `CFMS-SYS-9000` Unexpected error |

**Severity:** each code has a severity: **Info** (no action needed), **Warning** (user can continue, for example a soft eligibility warning), **Error** (the step is blocked until corrected) or **Critical** (system or data-integrity problem; support is alerted).

**Error code catalogue**

The catalogue is a platform-level table maintained by the platform team and deployed with releases (like the Module Registry, it is not edited in the UI). Each entry holds: code, module, category, severity, HTTP status, default user message (with placeholders, for example "Member {memberId} has {count} overdue instalments"), translations per language, internal description, suggested resolution for support, whether the error is retryable, and whether it raises an alert. Codes are never reused or renumbered; a retired code stays in the catalogue marked inactive. The catalogue is exportable for the user manual and support team.

Database names (kept aligned with the database scripts):

| Item | Database Object |
|---|---|
| Catalogue | `platform.error_code`: code, module, category, severity, http_status, message_template, translations (`jsonb` per language), internal_description, resolution, is_retryable, raises_alert, is_active, short_code (internal name raised by the database, for example `FEE_UNPAID`), sqlstate (generated as `CF` + category digit + `00`, that is CF100 to CF900) |
| Category values | VALIDATION, BUSINESS_RULE, AUTHORISATION, NOT_FOUND, CONFLICT, INTEGRATION, SYSTEM. Checks enforce that the first digit of the number matches the category and the module part of the code matches the module column |
| Codes per action | `platform.action_error_code` (action_code, error_code) |
| Error logs | `core.error_log` (per organisation) and `platform.platform_error_log` (errors outside an organisation), both with correlation_id and status OPEN, ACKNOWLEDGED, RESOLVED or IGNORED |
| Action logs | `wf.action_execution` and `wf.action_execution_log` carry error_code and correlation_id |
| Database-raised errors | Unique, foreign key, check, row-level security and deadlock errors raised by PostgreSQL are translated to catalogue codes through `platform.constraint_error_map` and `platform.sqlstate_error_map`, so users never see raw database messages |

**Standard API error response**

All API errors use one JSON shape:

```json
{
  "error": {
    "code": "CFMS-LOAN-2007",
    "category": "BUSINESS_RULE",
    "severity": "ERROR",
    "message": "This member cannot take a new loan until 14-08-2027 (cooling-off period).",
    "fieldErrors": [
      { "field": "memberId", "code": "CFMS-LOAN-2007", "message": "Member is in a cooling-off period" }
    ],
    "correlationId": "7f3c9a2e-1b4d-4e8a-9c61-2d5f0b7a8e11",
    "timestamp": "2027-05-14T10:32:05+05:30",
    "retryable": false
  }
}
```

- Validation errors return all field errors at once, not one at a time.
- `correlationId` is generated for every request and passed through every service, background job and log entry, so that one user report can be traced end to end.

**User messages versus internal detail**

- Users see a short, plain message in their language with the error code and, for System and Integration errors, the reference (correlation id) to quote to support, for example: "Something went wrong. Please try again. Reference: CFMS-SYS-9000 / 7f3c9a2e".
- Stack traces, SQL, internal identifiers, other tenants' data and personal data are never shown to users or returned by the API.
- Field errors are shown next to the field; other errors are shown in a message bar on the screen. Warnings ask for confirmation instead of blocking.

**Logging and alerting**

- Every Error and Critical event is logged with code, correlation id, tenant, user, role, module, record reference, channel (web, mobile, API, job) and internal detail. Personal data in logs is masked.
- Validation and business-rule errors are logged at a lower level and counted for reporting (for example, the most frequent validation errors per screen).
- Critical errors, repeated Integration failures and spikes in System errors raise an alert to the platform team. Tenant-level failures that the organisation must act on (for example a failed notification batch) appear on the Administration Dashboard.
- The Super Admin console has an error log screen with search by code, tenant, module, date and correlation id, with Excel and PDF export.

**Retry policy**

- Validation, Business rule, Authorisation, Not found and Conflict errors are never retried automatically; the user corrects the input or refreshes and tries again.
- Integration errors (notifications) are retried automatically with increasing delay, up to the configured retry count (Section 25.7); after the last attempt the failure is logged and shown on the Administration Dashboard.
- System errors in background jobs are retried once; financial steps are never retried automatically, and idempotency keys prevent duplicate postings if a user resubmits.

**Workflow action failures**

- Every `ActionResult` that fails carries an error code from the catalogue. A failed validation action returns a Validation or Business rule code and blocks the stage (Section 25.7); a failed data-changing action returns its code and the step is rolled back.
- Action failures are stored in the action execution and failure logs with the error code, message, correlation id and workflow instance, so that they can be searched by code.
- New action implementations must register the error codes they can return; the Super Administrator sees these codes when approving an action (Section 25.4).

---

## 35. SaaS Delivery and Multi-Tenancy

CFMS will be delivered as a multi-tenant Software-as-a-Service (SaaS) product. One deployment serves many community organisations, and each organisation is a **tenant**. The platform must be deployable on either Microsoft Azure or Amazon Web Services (AWS) from the same codebase.

**Current SaaS scope.** For now, the SaaS scope is limited to: the Platform Super Administrator creates organisations (tenants), and creates one organisation administrator user for each organisation, who then sets up the organisation's own users. Tenant data isolation (Section 35.2) and Super Administrator governance of workflows and rules (Section 35.4) remain in scope. Subscription plans and billing, self-service sign-up, custom domains, payment gateway, plan-based service levels and the Platform Support and Platform Billing roles are **future scope** and are kept below only as design guidance.

### 35.1 Tenancy Principles

- Each organisation is a separate tenant with fully isolated data, users, configuration, workflows, Chart of Accounts and branding.
- All requirements in this document apply per tenant. "Organisation Configuration" (Section 4) is tenant configuration.
- All tenants run the same application version. Tenant differences are achieved through configuration, plan features and feature flags, never through tenant-specific code.
- No user, report, export, notification or background job may read or change another tenant's data.
- New action implementations (Section 25) are released by the platform for all tenants. Tenants cannot upload their own code.

### 35.2 Tenant Data Isolation in PostgreSQL

| Model | Description | Strengths | Weaknesses |
|---|---|---|---|
| Shared schema with Row-Level Security (RLS) | All tenants share tables; every row carries `tenant_id`; PostgreSQL RLS policies restrict each session to its tenant | Lowest cost, one set of schema migrations, scales to many small tenants | Isolation depends on correct RLS and tenant context; single-tenant restore needs tooling |
| Schema per tenant | Each tenant has its own schema in a shared database | Clear separation, simpler single-tenant export | Migrations must run across every schema; becomes hard to manage beyond a few hundred tenants |
| Database per tenant | Each tenant has its own database | Strongest isolation, independent backup, restore and scaling | Highest cost and operational effort; not economical for small organisations |

**Recommendation:** Use **shared schema with Row-Level Security** as the default for all tenants, because most tenants will be small community organisations and the cost per tenant must stay low. Design the data layer so that a large or premium tenant can be moved to a **dedicated database** without code changes (a hybrid model).

Isolation requirements:

- Every tenant-owned table must have a non-null `tenant_id` column, included in primary or unique keys and indexes where relevant.
- RLS must be enabled and enforced on every tenant-owned table, including for the application's database role.
- The tenant context must be set from the authenticated user's token for every request and background job, and never from user input.
- Platform-level tables (tenants, plans, subscriptions, platform users) are kept separate from tenant tables.
- Automated tests must verify that no API, report, export or job can return another tenant's data.
- Unique business references (member IDs, loan numbers, receipt numbers) are unique within a tenant, not across the platform.

### 35.3 Platform Roles

The following platform roles sit above the tenant roles in Section 3. They belong to the SaaS operator, not to any tenant.

| Role | Responsibilities | Access to Tenant Data |
|---|---|---|
| Platform Super Administrator | Create, suspend and close tenants; create each organisation's first administrator user; manage feature flags, platform configuration and releases; **control each organisation's workflows, business rules, approval rules and limits** (Section 35.4) | Full access to each tenant's configuration; no access to transaction or personal data by default |
| Platform Support *(future scope)* | Troubleshoot tenant issues, view system logs and job status | Only through time-limited, audited access approved by the tenant's System Administrator |
| Platform Billing *(future scope)* | Manage subscriptions, invoices and payments | Billing and usage data only |

Rules:

- Platform users cannot create, edit or approve tenant transactions (loans, payments, journals, approvals).
- Any access to tenant data by platform staff ("break-glass" access) must be requested, approved by the tenant, time-limited and recorded in both the platform audit log and the tenant's audit log.
- Multi-factor authentication is mandatory for all platform roles.
- The tenant's System Administrator (ADM, Section 3) manages only their own tenant.

### 35.4 Workflow and Business Rule Governance per Organisation

The Platform Super Administrator alone configures the workflows, business rules, actions, approval rules and approval limits of every organisation; no organisation user, including the organisation administrator, can configure them, because this needs detailed knowledge of the engine. Every organisation can have **different workflows, rules and actions**: the Super Administrator configures each organisation separately, and a change for one organisation never affects another. This keeps workflow design consistent and safe across tenants, while each organisation's policies are still decided by that organisation.

**Template library**

- The Super Administrator maintains a library of **template workflows and rule sets**, for example: Loan Application, Application Fee Waiver, Early Settlement, Default and Recovery, Education Assistance, Cremation Assistance, Daily Expense, Payroll, Hall Booking, Asset Purchase and Manual Journal.
- Templates are versioned. Each template records its version, description and the actions and rules it uses.
- When an organisation is onboarded, the Super Administrator clones the templates into that organisation. The organisation's copy is then independent: later changes to a template do not change any organisation's live workflow.
- When a template is improved, the Super Administrator can see which organisations use older versions and offer an upgrade. Upgrading an organisation creates a new workflow version for that organisation; in-flight transactions continue on their original version.

**Per-organisation control**

The Super Administrator can, for each organisation:

- Create, modify, publish, deactivate and roll back workflows.
- Configure stages, actions, transitions and which actions are validations.
- Configure business rules, approval authorities and offline-approval policies.
- Lock any organisation setting so the organisation cannot change it (workflows, rules and actions are never editable by the organisation).
- Hand over to each organisation a default set of **modules, roles and privileges** at onboarding. The organisation administrator can then assign users to roles and adjust privileges within that default set, but cannot add modules or grant privileges the Super Administrator has not provided.
- Override an organisation's setting where needed for correctness, security or compliance, with a mandatory reason.

**Split of responsibilities**

| Area | Platform Super Administrator | Tenant System Administrator (ADM) | Tenant Leadership (LDR) |
|---|---|---|---|
| Workflow templates | Create and maintain | View | — |
| Organisation workflows | Request, create, modify, publish, deactivate, lock | View | View |
| Business rules and approval limits | Request, configure, publish, lock | View | View |
| Actions (registration, approval, stage configuration) | Register, approve, configure | No access | No access |
| Organisation settings and branding | Set up at onboarding | Maintain | — |
| Module enablement | Enable and disable modules per organisation | View | View |
| Modules, roles and privileges | Provide the default set at onboarding | Create custom roles; assign users to roles; adjust privileges within the default set | — |
| Users and role assignment | Organisation administrator created with the organisation | Create users, appoint and replace all role holders | — |
| Transactions and personal data | No access by default | No transaction rights | As per Section 3 |

**Change control**

- A change to an organisation's workflow or rule is prepared as a draft, tested in the organisation's sandbox or with a test transaction, and then published.
- Workflow and business rule changes are requested and made by the Super Administrator. The organisation does not raise change requests in the system; where a change follows a discussion with the organisation, the Super Administrator records the reason.
- Every change records who made it, who approved it, the reason, the effective date and the previous version.
- Published changes take effect from their effective date and never alter transactions already in progress or completed (Sections 2.1 and 29).

**Audit of Super Administrator access**

- Configuration changes by the Super Administrator are recorded in both the platform audit log and the organisation's own audit log, visible to the organisation's Auditor and Leadership.
- The Super Administrator may view an organisation's configuration and anonymised workflow statistics (counts, stage durations, failure rates) without special approval.
- Viewing transaction or personal data requires break-glass access (Section 35.3): requested with a reason, approved by the organisation, limited in time and fully logged, including every record viewed.
- Organisations receive a periodic report of all platform access to their tenant.

### 35.5 Tenant Onboarding

Onboarding workflow (current scope):

```text
Super Administrator Creates Organisation
        |
        v
Tenant Provisioned (identifier, subdomain, storage)
        |
        v
Apply Configuration Templates and Default Organisation Settings (Section 4.10)
        |
        v
Enable Modules and Optional Features (legal and tax, deposits, chit funds, purge)
        |
        v
Organisation Administrator User Created by Default
        |
        v
Organisation Administrator Creates Users (Web, Mobile or Record-only), Branding and Settings
        |
        v
Data Migration (if applicable)
        |
        v
Go-Live
```

- Organisations are created only by the Platform Super Administrator. There is no self-service sign-up in the current scope.
- Provisioning must be automated: create the tenant record, tenant identifier, subdomain (for example `name.cfms-domain.com`), storage area and the organisation administrator account. The organisation administrator user is created by default as part of creating the organisation, with Web access and the ADM role; the Super Administrator enters only their name, mobile number and email.
- The organisation administrator receives an activation link and must set a password and MFA at first login.
- When creating the organisation, the Super Administrator enables any optional features that apply (Section 4.8). All are disabled by default.
- New tenants start from **configuration templates** maintained by the platform: standard Chart of Accounts, loan types, approval workflows, notification templates, roles and default dashboards. Tenants then adjust these to their own policies.
- A sandbox tenant must be available for training, with no real data.

### 35.6 Per-Tenant Configuration and Branding

Each tenant can configure:

- Organisation name, logo, address and registration details.
- Colour theme for the application.
- Receipt, statement, payslip and report headers and footers.
- SMS sender ID, WhatsApp business number and email sender address.
- Financial year, currency format and language preferences.
- All business configuration in Section 4.

Branding changes must not require a deployment.

### 35.7 Subscription Plans and Billing *(future scope)*

Not in the current scope. Organisations are created and managed by the Super Administrator without subscription plans or billing in the application. The design should allow the following to be added later without restructuring:

- Subscription plans controlling modules, limits and support levels.
- Billing in Indian Rupees with GST-compliant invoices, payment gateway, usage metering for SMS and WhatsApp.
- Trial periods, upgrades and downgrades, and handling of non-payment (with member reminders paused and statements still available while read-only).
- Self-service sign-up and custom domains per organisation.
- Platform revenue must always stay separate from each tenant's General Ledger.

### 35.8 Cloud-Agnostic Deployment

The application must be portable between Azure and AWS. Requirements:

- All application components are packaged as containers.
- Infrastructure is defined as code (for example Terraform), with modules for each cloud.
- The application uses managed services through abstraction layers (storage, queue, email, secrets) so that switching cloud changes configuration, not business code.
- Observability uses open standards (for example OpenTelemetry).
- Separate environments for development, testing, staging and production.

Service equivalents:

| Capability | Azure | AWS |
|---|---|---|
| Container hosting | Azure Container Apps or Azure Kubernetes Service (AKS) | Amazon ECS on Fargate or Amazon EKS |
| Container registry | Azure Container Registry | Amazon ECR |
| Managed PostgreSQL | Azure Database for PostgreSQL – Flexible Server | Amazon RDS for PostgreSQL or Aurora PostgreSQL |
| Object storage (documents, evidence) | Azure Blob Storage | Amazon S3 |
| Message queue / background jobs | Azure Service Bus | Amazon SQS |
| Cache | Azure Cache for Redis | Amazon ElastiCache for Redis |
| Secrets and keys | Azure Key Vault | AWS Secrets Manager and AWS KMS |
| Load balancing, CDN and WAF | Azure Front Door with WAF, Application Gateway | Amazon CloudFront, Application Load Balancer and AWS WAF |
| Email | Azure Communication Services | Amazon SES |
| Monitoring and logs | Azure Monitor and Application Insights | Amazon CloudWatch |
| Backup | Azure Backup and PostgreSQL point-in-time restore | AWS Backup and RDS point-in-time restore |

SMS and WhatsApp are provided through third-party providers integrated by API, independent of the cloud.

### 35.9 Data Residency, Backup and Recovery

- All tenant data, including backups and documents, must be stored in India: Azure Central India or South India regions, or AWS Asia Pacific (Mumbai) or Asia Pacific (Hyderabad) regions.
- Database backups use managed point-in-time restore, plus a secondary copy in a second Indian region for disaster recovery.
- The platform must be able to **export and restore a single tenant** without affecting other tenants.
- Each tenant can request a full export of its data in a documented format.
- Restoration of backups must be tested regularly, including a single-tenant restore.
- Data is encrypted in transit and at rest.

Proposed service levels (to be confirmed):

| Measure | Proposed Target | Future Premium Option |
|---|---|---|
| Monthly availability | 99.5% | 99.9% |
| Recovery Point Objective (RPO) | 1 hour | 15 minutes |
| Recovery Time Objective (RTO) | 8 hours | 4 hours |
| Support response (critical issue) | 8 business hours | 2 hours |

Planned maintenance must be announced in advance and scheduled outside business hours in India.

### 35.10 Data Protection Responsibilities

- Each tenant organisation is the data fiduciary for its members' personal data; the SaaS operator acts as a data processor under a data processing agreement.
- The platform must support tenant requests for data correction, export and deletion in line with applicable Indian data protection law.
- When a tenant leaves, its data is exported to the tenant, kept for an agreed retention period and then permanently deleted, with deletion confirmed in writing.

### 35.11 Data Migration for Each New Tenant

The migration process in Section 39 applies to each tenant that has an existing system. Because migration will be repeated for many tenants, the platform must provide a reusable migration toolkit:

- Standard import templates (Excel/CSV) for members, nominees, loans part-way through repayment, repayment history, opening balances, assets, employees and hall bookings.
- A per-tenant staging area where imported data is validated before loading.
- Automatic validation and reconciliation reports (record counts, loan totals, trial balance).
- Re-runnable imports that do not create duplicates.
- Custom extraction for tenants whose existing system cannot produce the standard templates, handled as a separate onboarding service.
- Migration into one tenant must never affect another tenant.

### 35.12 Platform Operations

- All tenants are upgraded together; database schema changes must be backward compatible so that upgrades do not require downtime.
- New features can be enabled per tenant through feature flags.
- Background jobs (reminders, defaults, depreciation, scheduled actions) run per tenant and use each tenant's time zone and configuration.
- Resource limits per tenant protect other tenants from one tenant's heavy usage.
- Platform monitoring shows health and usage per tenant.

---

## 36. Security and Non-Functional Requirements

### Security

- Encrypted communication.
- Secure password hashing.
- Role-based access.
- Multi-factor authentication for privileged roles.
- Session management.
- Immediate access revocation.

### Data Integrity

- No permanent deletion of posted financial transactions, except through an approved archival and purge run after the retention period (Data Archival and Purge).
- Unique transaction references.
- Duplicate payment prevention.
- Balanced accounting entries.
- Reconciliation.
- Protected audit history.

### Tenant Isolation

- Row-Level Security on every tenant-owned table.
- Tenant context derived only from authentication.
- Automated cross-tenant leakage tests.
- Audited, tenant-approved platform access.

### Workflow Integrity

- Workflow versioning.
- Action version compatibility.
- Idempotent action execution.
- Action execution history.
- Validation-enforced failure handling with a failure log.
- Concurrency control.
- Prevention of duplicate financial postings.
- Controlled action registration.
- Protected workflow configuration.

### Approval Integrity

- Actual approver identification.
- Recording user identification.
- Accurate approval method.
- Evidence retention.
- Independent verification when required.

### Backup and Recovery

- Automated database backups with point-in-time restore for 35 days.
- Monthly backups retained for 1 year.
- Disaster recovery to a second Indian region (Section 35.9).
- Backup restoration tested at least quarterly, including a single-tenant restore.
- Availability, RPO and RTO as defined in Section 35.9 (single service level in the current scope).

### Measurable Non-Functional Requirements

The values below are **proposed defaults** for an NGO-focused SaaS product, based on typical community organisations. They must be confirmed before the SRS is finalised and may be adjusted per subscription plan.

#### Capacity per Organisation

| Measure | Typical Organisation | Maximum per Organisation |
|---|---:|---:|
| Members | 5,000 | 50,000 |
| Active loans | 2,000 | 20,000 |
| Named users | 25 | 200 |
| Concurrent users | 15 | 100 |
| Financial transactions per year | 50,000 | 500,000 |
| Document storage | 20 GB | 200 GB |

#### Platform Capacity

| Measure | Launch Target | Design Target |
|---|---:|---:|
| Organisations (tenants) | 100 | 2,000 |
| Concurrent users across the platform | 500 | 5,000 |
| Notifications per day | 50,000 | 500,000 |

The platform must scale to the design target by adding application instances and database capacity, without redesign.

#### Response Times

Measured at the 95th percentile under normal load, on a 4G or broadband connection in India.

| Operation | Target |
|---|---:|
| Initial application load | 3 seconds |
| Screen navigation | 2 seconds |
| Member or loan search | 1 second |
| Saving a transaction (receipt, repayment, voucher) | 2 seconds |
| Receipt or statement PDF generation | 3 seconds |
| Dashboard load | 3 seconds |
| Standard reports (up to one financial year) | 5 seconds |
| Large reports and exports | Run in background; complete within 2 minutes with a notification |
| Daily batch per organisation (reminders, defaults, interest calculations, depreciation) | 10 minutes |
| Notification handed to provider after trigger | 1 minute |

#### Browsers and Devices

- Latest two major versions of Google Chrome, Microsoft Edge, Mozilla Firefox and Safari.
- Chrome on Android and Safari on iOS for mobile browser use.
- Usable on screens from 360 px (phones) to desktop; primary data-entry screens optimised for 1366 × 768 and above.
- Usable on low-bandwidth connections (1 Mbps), with compressed assets and paginated lists.
- If native mobile apps are built (for example with Flutter): Android 9 or later and iOS 15 or later.

#### Language and Localisation

CFMS supports **English and Tamil** from the first release. All user-facing text is stored in the backend, so that languages can be maintained without code changes and more Indian languages can be added later.

**Mandatory requirement:** every system page, menu and UI display item must support both Tamil and English. This applies to the organisation portal, the mobile app and the Super Admin console alike. No display text may be hard-coded in the web or mobile code: every page title, menu, label, button, tab, column heading, placeholder, tooltip, message, dialog, empty-state text, report heading and export heading must come from the translation tables through its text ID. A screen is not accepted as complete unless every display item has approved English and Tamil text, and automated checks in the build reject hard-coded display text.

**Translation tables (backend)**

- Every piece of user-facing text has a stable **text ID** (key), for example `page.loan.application.title`, `menu.loans`, `label.member.mobile`, `button.save`, `help.loan.amount`, `msg.saved`.
- A translation table holds one row per text ID and language: text ID, language code (`en`, `ta`), text, module, text type (page name, menu, label, button, placeholder, help text, message, report heading, notification), status (Draft, Approved), version, last changed by and date.
- This covers page names, menu items, control labels, buttons, placeholders, tooltips and help text, validation and confirmation messages, report and column headings, dashboard titles, and PDF and Excel export headings.
- Error messages use the same approach: each error code's message has a translation per language (Section 34.1).
- Business master data that users see also has translatable names: modules, standard and custom roles, lookup values (statuses, relationships, evidence types and so on), loan types, assistance types, expense categories, hall names and notification templates. Each such record stores its name per language.
- Text may contain placeholders (for example "Loan {loanNo} approved"), which must be kept in every translation; the editor checks this.

**How the apps use it**

- At sign-in (and when a new version is published), the web and mobile apps download a **versioned language pack** for the user's language and cache it, so screens do not call the server for each label. The mobile app keeps the last pack for offline start-up.
- If a text ID has no translation in the selected language, the English text is shown (fallback), and the gap is recorded.
- A user can switch between English and Tamil from the header at any time; the screen changes immediately.
- Language preference: each user has a preferred language, defaulting from the organisation's default language (English unless set otherwise).

**Managing translations (Super Admin only for now)**

- Translations are maintained only by the Platform Super Administrator, in a Translation screen in the Super Admin console. Organisations cannot override or add translations in the current scope.
- The screen supports search and filter by module, text type, language and status, side-by-side English and Tamil editing, and a **missing translations report** (text IDs with no approved Tamil text).
- **Excel export and import:** all text for a language (or a module) can be exported to Excel, translated offline, and imported back. Import validates text IDs and placeholders, shows the changes before saving, and imports as Draft.
- Publishing approved translations creates a new language pack version; apps pick it up at the next sign-in or refresh. Every change is kept in the audit history (Section 31.1).
- Developers add new text IDs with English text as part of each release; the missing translations report then shows what needs Tamil.

**Member-facing output**

- Member notifications (SMS, WhatsApp, email) use per-language templates and are sent in the member's preferred language (English or Tamil), with English as fallback. Tamil SMS uses Unicode, which allows fewer characters per SMS; templates must be sized for this.
- Receipts, statements, vouchers and other PDFs can be printed in the member's preferred language or the user's language, using an embedded Tamil font (for example Noto Sans Tamil) so that text renders correctly on every device and printer.
- Data entered by users (names, addresses, remarks) is stored as entered, in Unicode; members' names may be stored in both English and Tamil where the organisation wants both on receipts.

**Formats**

- Indian number formatting (₹1,23,456.00), DD-MM-YYYY dates and Indian Standard Time by default, configurable per organisation. Numbers and dates use the same format in both languages.
- Search works on both English and Tamil text.

#### Data Retention

| Data | Retention |
|---|---|
| Financial transactions, journals and vouchers | At least 8 years after the end of the financial year |
| Audit trail and approval evidence | At least 8 years after the end of the financial year |
| Member records and documents | While the member is active, then 8 years after the last financial transaction |
| Payroll records | At least 8 years |
| Application logs | 90 days online, 1 year archived |
| Security and access logs (including platform access) | 1 year online, 3 years archived |
| Data of an organisation that leaves the platform | Exported to the organisation, retained 90 days, then permanently deleted |

Retention periods are configurable per organisation where its own policy or law requires longer.

#### Data Archival and Purge

CFMS must provide a controlled mechanism to archive and then permanently purge data that is older than the organisation's retention period.

**Organisation-level settings**

| Setting | Description | Default |
|---|---|---|
| Purge enabled | Turns archival and purge on or off for the organisation | Off |
| Retention period (years), per data category | Number of years after which data becomes eligible for archive and purge | As in the Data Retention table |
| Archive retention (years) | How long archived data is kept before final deletion | 2 years |
| Approval required | Whether each purge run needs the organisation's approval before it runs | Yes (cannot be switched off for financial data) |

- Purge is enabled per organisation by the Platform Super Administrator, at the organisation's written request or when creating the organisation (Section 35.5).
- Retention periods are entered in whole years by the organisation's System Administrator, within the limits below. Changes are audited.
- When purge is disabled, no data is ever purged automatically.

**Minimum retention floors** (the system rejects lower values)

| Data Category | Minimum Years |
|---|---:|
| Financial transactions, journals, vouchers and receipts | 8 |
| Audit trail and approval evidence | 8 |
| Payroll records | 8 |
| Loan records (from loan closure) | 8 |
| Application logs | 0.25 (90 days) |
| Notifications sent, sessions and temporary files | 0.25 (90 days) |

**What can be purged**

| Data | Treatment After Retention Period |
|---|---|
| Personal data of members who have exited (inactive or deceased) with no open loans, obligations or recovery cases | Anonymised: name, contact details, identity information, family details and documents are deleted; financial amounts remain under an anonymous reference so that accounts and reports still balance |
| Closed financial years beyond the retention period | Archived, then purged; opening balances of the oldest retained year remain so that the General Ledger stays complete and balanced |
| Supporting documents and evidence files | Archived, then deleted from object storage |
| Notification history, application logs, sessions and temporary files | Deleted without archive |
| Data of an organisation that has left the platform | Exported to the organisation, held for the export window (90 days), then permanently deleted including archives |

**Exclusions**

- Records under legal hold, dispute, recovery, open audit query or pending approval are never purged until the hold is released.
- Records linked to an open loan, unrefunded deposit or unreconciled cash item are never purged.
- Open financial years and the current year are never purged.

**Process**

```text
Scheduled Job Identifies Eligible Records
          |
          v
Purge Candidate Report
          |
          v
Organisation Approval (Leadership)
          |
          v
Super Administrator Authorisation
          |
          v
Archive to Read-only Storage (India region)
          |
          v
Verify Archive
          |
          v
Purge or Anonymise
          |
          v
Purge Certificate and Log
```

- The job runs on a configurable schedule (default: once per year after the financial year is closed) and only produces a candidate report; nothing is deleted without approval.
- The archive is a read-only, encrypted copy that authorised users (Auditor, Leadership, Accountant) can search and restore from until the archive retention ends.
- Each run produces a **purge certificate** listing the organisation, data categories, record counts, date range, approvers and completion time. The certificate and run log are kept permanently and contain no purged personal data.
- Purged data disappears from database backups once the backup retention period (Backup and Recovery above) has passed.
- Purge and anonymisation must not break referential integrity, reports or balances for retained periods.

#### Security Measures

- TLS 1.2 or higher for all traffic; AES-256 encryption at rest.
- Idle session timeout: 15 minutes for privileged roles, 30 minutes for others.
- Account lockout after 5 consecutive failed sign-in attempts.
- Application security verified against OWASP ASVS Level 2.
- Independent penetration test before go-live and at least annually.
- Critical security patches applied within 7 days, high within 30 days.

#### Search and Refresh

Search and refresh must be available on every screen where they apply. This is a general UI standard for all modules, including the Super Admin console.

**Where they apply:** every list and grid (members, loans, receipts, vouchers, deposits, chit groups, bookings, assets, users, organisations), approval and work queues, reports, the audit log, failure and notification logs, and dashboards. Single-record entry forms do not need them.

**Search**

- A quick search box at the top of each list, searching the main fields of that list (for example member ID, name, mobile number, loan number, receipt number) as the user types, after at least 2 characters.
- Partial and case-insensitive matching; mobile numbers and IDs also match on their last digits.
- Filters suited to each list, such as status, date range, loan type, employee and amount range, which can be combined with the search text.
- A global search in the top bar to find a member, loan, receipt or booking from any screen, limited to the modules and records the user is permitted to see.
- Results respect privileges and tenant isolation; a user never sees records outside their access.
- Search text and filters are kept while the user moves to a record and back, and can be cleared with one action.
- Results are paged (default 25 rows, with 50 and 100 options) and sortable by column.
- Response target: within 1 second for member and loan search (Section 36, Response Times).

**Refresh**

- A refresh button on every list, queue, report and dashboard reloads the data without losing the current search, filters, sort or page.
- Each screen shows when its data was last refreshed.
- The top-bar cash position refreshes after every cash transaction and on demand.
- Dashboards and approval queues can refresh automatically at a configurable interval (default 5 minutes, or off); reports refresh only on request.
- After a user saves, approves or cancels a record, the list they return to is refreshed automatically.

#### Export to Excel and PDF

Export to **Excel (.xlsx)** and **PDF** must be available on every screen where it applies, as a general UI standard for all modules, including the Super Admin console.

**Where it applies:** lists and grids, reports and financial statements, member and loan statements, registers, approval and work queues, the audit log, failure and notification logs, and dashboards (PDF snapshot, with the underlying data in Excel). Single-record documents such as receipts, vouchers and certificates are printed or saved as PDF.

- The export contains exactly what the user sees: the current search text, filters, sort order and visible columns, but all pages of the result, not only the page on screen.
- **Excel:** real numbers and dates (not text), so that totals and filters work in Excel; column headings, totals where the screen shows them, and the organisation name, report title, filters applied, generated by and date-time at the top. CSV is also offered for lists, for large data and for re-import.
- **PDF:** the organisation's branding, title, filters applied, page numbers, generated by and date-time; A4 portrait or landscape chosen automatically by width.
- Exports respect privileges and tenant isolation. A user can export only data they are allowed to view; sensitive exports (payroll, personal data, full member lists) also need the separate export privilege (Section 3.5) and are audited.
- Large exports run in the background and the user is notified when the file is ready (Section 36, Response Times).
- Amounts use Indian number formatting in PDF; Excel keeps the raw value with Indian-format display.

#### Accessibility

- User interface conforms to WCAG 2.1 Level AA.

#### Maintainability and Quality

- All financial calculations (interest, schedules, settlements, defaults, posting rules) covered by automated tests with documented reference cases.
- Automated test coverage of at least 70% for business logic.
- Automated build and deployment pipeline; production releases without downtime.
- Centralised logging, metrics and alerting with per-tenant visibility.

---

## 37. Complete Module Inventory

The consolidated CFMS will contain 38 primary modules, plus a Data Migration workstream (Section 39).

| No. | Module | Priority | Menu Group | is_menu (default) |
|---:|---|---|---|---|
| 1 | Organisation Management | Critical | Administration | Yes |
| 2 | User & Role Management | Critical | Administration | Yes |
| 3 | Member Management | Critical | Members | Yes |
| 4 | Loan Management | Critical | Loans | Yes |
| 5 | Loan Application Fee Management | Critical | Loans | Yes |
| 6 | Loan Repayment Management | Critical | Loans | Yes |
| 7 | Early Full Settlement | Critical | Loans | Yes |
| 8 | Default & Full Settlement Management | Critical | Loans | Yes |
| 9 | Nominee Management | High | Members | Yes |
| 10 | Deceased Member Management | High | Members | Yes |
| 11 | Education Assistance | High | Assistance | Yes |
| 12 | Cremation Assistance | High | Assistance | Yes |
| 13 | Birthday Grants | Medium | Assistance | Yes |
| 14 | Daily Expense Management (incl. petty cash and vendors) | Critical | Operations | Yes |
| 15 | Employee Payroll | High | Operations | Yes |
| 16 | Marriage Hall Management | High | Operations | Yes |
| 17 | Community Asset Management | High | Assets | Yes |
| 18 | Asset Purchase & Approval | High | Assets | Yes |
| 19 | Asset Maintenance & Depreciation | Medium | Assets | Yes |
| 20 | Asset Transfer & Disposal | Medium | Assets | Yes |
| 21 | General Community Fund | Critical | Accounting | Yes |
| 22 | General Ledger (incl. cash management) | Critical | Accounting | Yes |
| 23 | Chart of Accounts | Critical | Accounting | Yes |
| 24 | Journal & Voucher Management | Critical | Accounting | Yes |
| 25 | Trial Balance | Critical | Accounting | Yes |
| 26 | Financial Statements | Critical | Reports | Yes |
| 27 | Cash Reconciliation | Critical | Accounting | Yes |
| 28 | Financial Period Management | High | Accounting | Yes |
| 29 | Financial Reports | Critical | Reports | Yes |
| 30 | Management Reports & Analytics | High | Reports | Yes |
| 31 | Workflow Engine | Critical | Administration | Yes |
| 32 | Business Rules Engine | Critical | Administration | Yes |
| 33 | Flexible Approval Management | Critical | Approvals | Yes |
| 34 | Notification Engine | High | Administration | Yes |
| 35 | Audit Management | Critical | Administration | Yes |
| 36 | Member Deposits (optional, Section 9) | High | Deposits | Yes |
| 37 | Chit Fund Schemes (optional, Section 10) | High | Chit Funds | Yes |
| 38 | Contributions & Donations | High | Members | Yes |

All 38 modules default to is_menu = Yes, because each has its own privileges in the privilege matrix (Section 3.3). is_menu = No is intended for sub-screens and technical entries registered in the Module Registry that exist only inside a parent screen, for example receipt printing, settlement statement generation or the fee collection step of a loan application. These are not shown anywhere in the UI as modules and inherit their parent module's privileges. Dashboards (D1–D6) have is_menu = Yes under the Dashboards group. See Section 3.9.

**SaaS platform modules (Section 35):** in addition to the 38 organisation modules, the platform requires these modules, operated by platform roles:

| No. | Platform Module | Priority |
|---:|---|---|
| P1 | Tenant Management and Provisioning | Critical |
| P2 | Workflow and Rule Template Library and Per-Tenant Governance | Critical |
| P3 | Subscription Plans and Billing (future scope) | — |
| P4 | Tenant Onboarding and Migration Toolkit | High |
| P5 | Platform Monitoring, Usage and Access Audit | High |

**Dashboards:** Dashboards are configurable modules (Section 3.8). The default set (D1–D6) is listed in Section 3.3; any number of further dashboard modules can be added without changing this inventory.

**Technical architecture addition:** The Workflow State Action Engine is a core component of the Workflow Engine, not a separate business module. It must nevertheless be implemented as a distinct technical subsystem.

---

## 38. Implementation Roadmap

| Phase | Deliverables |
|---|---|
| Phase 0 | Existing system analysis, data profiling, mapping specification and migration tooling |
| Phase 1 | Multi-tenant foundation (tenant model, RLS, Super Administrator console to create organisations and their first admin user, workflow templates), organisation, users, roles, Audit Engine, workflow engine, state actions and business rules |
| Phase 2 | Accounting core: Chart of Accounts, General Ledger, journals and vouchers, receipts and payments, cash management (common cash account, top-bar cash position, day-end closing, voucher series), financial periods, General Community Fund and funds; approval management; member management and membership lifecycle |
| Phase 3 | Loan management (statuses, eligibility, guarantors, disbursement controls), application fees, repayments (allocation, overpayments, late fees, reversals) and Notification Engine (receipts and reminders) |
| Phase 4 | Early settlement, default management, recovery, restructuring, write-off, nominees, deceased members, Member Deposits and Chit Fund Schemes (if required) |
| Phase 5 | Education, cremation and birthday assistance; daily expenses, petty cash and vendors; contributions and donations |
| Phase 6 | Payroll, cash reconciliation, financial statements and financial reports |
| Phase 7 | Marriage hall management (multiple halls) |
| Phase 8 | Asset procurement, asset register, maintenance, depreciation and disposal |
| Phase 9 | Management dashboards and analytics, tenant onboarding and migration toolkit, performance and security testing, and deployment to Azure or AWS |
| Migration | Trial migrations alongside Phases 2–8; final migration, reconciliation, cutover and parallel running before go-live |

The Workflow Engine, IAction architecture, Approval Engine, Accounting Engine and Audit Engine are built in Phases 1–2, before any financial module, because every financial module must post to the General Ledger and record audit history from its first release. No module may go live with financial transactions that are not posted to the General Ledger. Data migration analysis should start in Phase 0, because the existing data may reveal loan terms and balances that the CFMS design must support.

---

## 39. Data Migration from the Existing System

An existing system is currently in operation. CFMS must take over from it without loss of financial data, member history or audit trail, and without interrupting loan collections. Data migration is a separate workstream with its own plan, test cycles and sign-off.

### 39.1 Migration Objectives

1. Every active member, loan, balance and open obligation in the existing system exists correctly in CFMS on the go-live date.
2. Migrated financial balances reconcile exactly with the existing system and with the physical cash count at the cutover date.
3. Members experience no change in their outstanding amounts, due dates or entitlements because of the migration.
4. Historical records needed for member statements, audit and reporting remain available.
5. Every migrated record can be traced back to its source record.

### 39.2 Migration Scope

| No. | Data Area | Migration Approach |
|---:|---|---|
| 1 | Members, family, children and nominees | Full migration of all members, including Inactive, Suspended and Deceased |
| 2 | Member documents | Migrate files and link to members; record missing documents as exceptions |
| 3 | Active loans (part-way through repayment) | Migrate as open loans with original terms, disbursement date, paid-to-date amounts and remaining schedule |
| 4 | Closed and settled loans | Migrate summary and repayment history for the agreed history period |
| 5 | Defaulted loans and recovery cases | Migrate with default date, outstanding amount, recovery status and notes |
| 6 | Member eligibility and cooling-off status | Migrate current status and cooling-off end date |
| 7 | Application fees | Migrate collected fees for the history period |
| 8 | Repayment and receipt history | Migrate transaction-level history for the agreed history period |
| 9 | Education, cremation and birthday assistance | Migrate payments made and open applications |
| 10 | Marriage hall bookings | Migrate all future confirmed bookings with locked pricing, advances received and security deposits held |
| 11 | Employees and payroll | Migrate employee master, salary structures, open advances and payroll history for the current financial year |
| 12 | Assets | Migrate asset register with cost, accumulated depreciation, book value, location and assignment |
| 13 | Chart of Accounts | Map existing accounts to the approved CFMS Chart of Accounts |
| 14 | Opening balances | Load opening trial balance at the cutover date |
| 15 | Cash | Load the opening cash balance |
| 16 | Open approvals and in-progress requests | Either complete in the existing system before cutover or re-enter in CFMS; no partial workflow migration |
| 17 | Users | Create fresh CFMS accounts; passwords are not migrated |
| 18 | Existing audit logs | Archive in read-only form; not loaded as CFMS audit records |

The history period (for example, current and previous financial year, or full history) is a business decision. History older than that period must be archived in a read-only, searchable form.

### 39.3 Migration of Loans Part-Way Through Repayment

Active loans are the highest-risk data. For each active loan, the migration must carry:

- Original loan reference, member, category and purpose.
- Principal, interest rate, repayment period and total interest as originally agreed.
- Actual disbursement date.
- Original instalment schedule.
- Principal and interest paid to date, recorded separately.
- Outstanding principal and outstanding interest at the cutover date.
- Overdue instalments and days overdue.
- Partial payments and any unallocated amounts.
- Nominee, guarantor and supporting documents.
- Application fee paid.

Rules:

- Migrated loans retain the terms under which they were originally approved, even where current CFMS configuration differs.
- CFMS must not recalculate interest or regenerate schedules for migrated loans unless the result is identical to the existing system or a variance has been approved.
- Where the existing system's figures differ from a manual recalculation, the existing figure is migrated and the difference is logged as an exception for business review.
- Migrated loans are flagged as `MIGRATED` with a reference to the source record.
- Default and reminder rules apply to migrated loans from the go-live date onwards. Defaults that would have been triggered retroactively are listed for review, not applied automatically.

### 39.4 Financial Opening Balances

- Cutover is at the end of an accounting period, preferably a month end or financial year end.
- The opening trial balance is loaded as a single, approved opening balance journal.
- Loan Principal Receivable in the GL must equal the sum of outstanding principal across all migrated loans.
- Security Deposits Held must equal the sum of deposits held for migrated hall bookings.
- Asset cost and accumulated depreciation must equal the migrated asset register totals.
- Cash balances must agree with a physical cash count at the cutover date.
- The organisation's accountant approves the opening balances before go-live.

### 39.5 Data Mapping and Cleansing

A mapping specification must be produced for every data area, defining source field, target field, transformation rule, default value and validation rule.

Cleansing activities:

- Remove or merge duplicate members.
- Standardise names, mobile numbers, addresses and dates.
- Assign CFMS member IDs while retaining legacy IDs.
- Map legacy statuses to CFMS statuses.
- Map legacy loan types to CFMS loan categories.
- Map legacy account codes to the CFMS Chart of Accounts.
- Identify loans with missing or inconsistent data.
- Identify members without valid contact details for notifications.

Data that cannot be cleansed automatically is placed on an exception list, owned by a named business user and resolved before the final migration run.

### 39.6 Migration Process and Trial Runs

```text
Extract from Existing System
          |
          v
Profile and Cleanse
          |
          v
Transform to CFMS Format
          |
          v
Load into Staging
          |
          v
Validate and Reconcile
          |
          v
Business Review and Sign-off
          |
          v
Load into CFMS
```

- At least two full trial migrations (mock runs) must be performed in a non-production environment before the final run.
- Each trial run is measured for duration, record counts, exceptions and reconciliation results.
- The final run must be repeatable from the same scripts used in the trial runs.
- Migration tooling must be re-runnable and must not create duplicates when run again.
- Every migration run must be logged with counts loaded, rejected and corrected.

### 39.7 Reconciliation and Validation

Each trial run and the final run must pass the following checks:

| Check | Rule |
|---|---|
| Record counts | Source and target counts match per data area, or differences are explained |
| Member totals | Active, inactive, suspended and deceased counts match |
| Loan totals | Count and value of active, overdue, defaulted and closed loans match |
| Outstanding balances | Total outstanding principal and interest match to the rupee |
| Member-level sample | A sample of member loan statements matches the existing system line by line |
| Trial balance | CFMS opening trial balance equals the existing system's closing trial balance |
| Cash | Balances agree with the physical cash count |
| Hall bookings | Future bookings, advances and deposits match |
| Assets | Count, cost and book value match |

The sample for member-level checks must include every loan category, partially paid loans, overdue and defaulted loans, early settlements and loans with unusual terms.

### 39.8 Cutover and Parallel Running

Cutover approach:

1. Announce a cutover date and freeze period.
2. Stop new transactions in the existing system at the freeze point.
3. Complete or cancel all in-progress approvals and requests.
4. Close the accounting period in the existing system.
5. Take a final backup of the existing system.
6. Run the final migration.
7. Complete reconciliation and obtain sign-off.
8. Open CFMS for live transactions.

Transactions received during the freeze period (for example, cash repayments) must be recorded manually and entered into CFMS immediately after go-live.

Parallel running:

- For an agreed period (for example, one full month-end cycle), key results from CFMS are compared with the existing system or with manual calculations.
- During parallel running, CFMS is the system of record. The existing system is used for comparison only, and the procedure for avoiding double entry must be documented.
- Parallel running ends when month-end reconciliation, member statements and reports match and the business signs off.

### 39.9 Sign-off and Governance

| Sign-off | Owner |
|---|---|
| Mapping specification | Business owner and accountant |
| Trial run results | Migration lead and business owner |
| Opening balances | Accountant |
| Member and loan data | Manager responsible for loans |
| Go-live decision | Leadership Team |

Go/no-go criteria include: all reconciliation checks passed, no open critical exceptions, user training complete and rollback plan tested.

### 39.10 Rollback

- The existing system must remain intact and restorable until parallel running is signed off.
- A rollback decision point and owner must be defined for the cutover weekend and for the parallel running period.
- If rollback is required after live transactions have been entered in CFMS, those transactions must be exported and re-entered in the existing system.
- The existing system must be kept in read-only form for an agreed retention period after decommissioning.

### 39.11 Migration Non-Functional Requirements

- Personal data must be protected during extraction, transfer and staging, and staging data must be deleted after sign-off.
- The full migration must complete within the agreed cutover window.
- Every migrated record must retain its legacy ID for traceability.
- Migration scripts, mapping documents and reconciliation reports must be retained as audit evidence.

### 39.12 Information Required About the Existing System

The following must be answered before the migration plan can be finalised:

| No. | Question |
|---:|---|
| 1 | What is the existing system (product name, or custom-built), and who supports it? |
| 2 | What database or storage does it use (for example SQL Server, MySQL, Access, Excel, Tally)? |
| 3 | Can data be exported directly from the database, or only through reports or Excel exports? |
| 4 | Is there documentation of the data structure, or someone who knows it? |
| 5 | Which modules does it cover today (members, loans, accounts, hall, payroll, assets)? |
| 6 | Which data is kept outside the system (Excel sheets, paper registers, accounting software)? |
| 7 | Approximately how many members, active loans, closed loans and transactions exist? |
| 8 | How many years of history exist, and how much must be carried into CFMS? |
| 9 | Does the existing system calculate interest and schedules the same way as CFMS (flat interest, due-date rules)? |
| 10 | Are accounting entries maintained in the existing system or in separate accounting software? |
| 11 | Are member documents stored digitally, and where? |
| 12 | Is the data considered accurate, or are known corrections pending? |
| 13 | Which date is preferred for cutover (month end or financial year end)? |
| 14 | Can the existing system remain available in read-only form after go-live, and for how long? |
| 15 | Who will own data cleansing and sign-off on the business side? |

---

## 40. Outstanding Business Decisions

The following decisions remain open before finalising the developer-ready SRS.

| No. | Area | Decision Required |
|---:|---|---|
| 1 | Education Assistance | Non-repayable grant or repayable interest-free loan |
| 2 | Payroll | Frequency and processing rules |
| 3 | Education Assistance | Eligibility and documents |
| 4 | Asset Management | Depreciation categories and policies |
| 5 | Asset Management | Transfer and disposal authorities |
| 6 | Asset Management | Donated asset support |
| 7 | Data Migration | Amount of history to migrate versus archive |
| 8 | Data Migration | Cutover date and freeze period |
| 9 | Data Migration | Length of parallel running |
| 10 | Data Migration | Treatment of figures that differ from CFMS recalculation |
| 11 | Data Migration | Business owners for cleansing and sign-off |
| 12 | Technology | Backend language and framework (database decided: PostgreSQL) |
| 13 | Technology | Client platform for first release (web, Android or both) |
| 14 | Technology | Build the JSON workflow and rule engine in-house, or adapt an existing engine to run the CFMS JSON definitions (JSON-driven design is decided, Section 24.2) |
| 15 | SaaS | Confirm tenancy model (recommended: shared schema with Row-Level Security) |
| 16 | SaaS | First target cloud: Azure or AWS |
| 17 | SaaS | Data retention and deletion after a tenant leaves |
| 18 | SaaS | Identity provider (built-in, or a managed/open-source identity service) |
| 19 | Member Deposits | Deposit products, rates, tenures, payout options and premature-withdrawal penalties |
| 20 | Chit Funds | Payout method, maximum discount, foreman commission and default/substitution rules (owner: Yesu, to be defined) |
| 21 | User Management | Whether one person may hold both the organisation administrator and Manager roles (Section 3.5) |

---

## 41. Final Architectural Recommendation

The most important architectural principle is the separation of workflow orchestration from business execution.

```text
                CFMS MODULES
                     |
                     v
               WORKFLOW ENGINE
                     |
          +----------+----------+
          |                     |
          v                     v
     STATE ENGINE        TRANSITION ENGINE
          |
          v
    STATE ACTION ENGINE
          |
          v
        IAction
          |
     +----+----------------------------+
     |          |          |           |
     v          v          v           v
   Loan      Finance    Approval   Notification
  Actions    Actions     Actions     Actions
     |          |          |           |
     +----------+----------+-----------+
                     |
                     v
              BUSINESS SERVICES
                     |
       +-------------+-------------+
       |             |             |
       v             v             v
    Loan Service  Accounting   Member Service
                    Service
                     |
                     v
                 DATABASE
```

### Mandatory Architectural Principles

1. Every workflow stage can have multiple configured actions.
2. Every action implements the common action contract (`IAction`), in whatever form the chosen stack supports.
3. Registered action implementations are dynamically discoverable.
4. Available actions appear in the Workflow Designer.
5. Each action can expose its own configuration schema.
6. Actions can be reused across different modules and workflows.
7. Actions execute when their associated workflow stage executes.
8. Execution order must be configurable.
9. Synchronous, asynchronous, conditional, parallel, manual and scheduled execution must be supported.
10. Every action execution must be logged.
11. Action failures follow the validation-enforced failure policy (Section 25.7): a failed validation blocks the stage, failed data changes roll back, and only notifications are retried.
12. Financial actions must be idempotent to prevent duplicate postings.
13. State actions and state transitions must remain separate.
14. Workflow and action versions must be preserved for historical transactions.
15. Offline approvals must be supported as first-class workflow activities.
16. Every tenant's data must be isolated, and each organisation's workflows and rules are controlled per tenant by the Platform Super Administrator.

**Final recommendation:** Build CFMS around a generic Workflow Engine, reusable `IAction` implementations, configurable approval management and a central double-entry accounting engine. This architecture will allow new business processes and actions to be introduced without redesigning the entire application.

The next development document should be the detailed Software Requirements Specification (SRS), including functional requirements, technical architecture, workflow diagrams, database ERD, API contracts, action catalogue, screen specifications and accounting posting matrix.
