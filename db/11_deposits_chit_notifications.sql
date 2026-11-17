-- =============================================================================
-- CFMS / NVS  -  11  Member deposits, chit funds (optional modules) and
--                   notifications (Sections 9, 10, 30)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Deposits and chit funds are disabled by default; the Super Admin enables them
-- per tenant (platform.tenant_module) after acknowledging the legal warning.
-- =============================================================================

-- ===== Member deposits =======================================================
CREATE TABLE IF NOT EXISTS dep.deposit_product (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code               text NOT NULL,
    version_no         integer NOT NULL DEFAULT 1,
    name               text NOT NULL,
    product_type       text NOT NULL CHECK (product_type IN ('RD','FD')),
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','INACTIVE','RETIRED')),
    effective_from     date NOT NULL DEFAULT current_date,
    min_amount         numeric(18,2),
    max_amount         numeric(18,2),
    max_per_member     numeric(18,2),
    min_tenure_months  integer,
    max_tenure_months  integer,
    interest_method    text NOT NULL DEFAULT 'SIMPLE' CHECK (interest_method IN ('SIMPLE','COMPOUND')),
    compounding_frequency text CHECK (compounding_frequency IN ('MONTHLY','QUARTERLY','HALF_YEARLY','ANNUAL')),
    day_count          text NOT NULL DEFAULT 'ACTUAL_365' CHECK (day_count IN ('ACTUAL_365','ACTUAL_360','30_360')),
    payout_frequency   text NOT NULL DEFAULT 'AT_MATURITY' CHECK (payout_frequency IN ('MONTHLY','QUARTERLY','AT_MATURITY','CUMULATIVE')),
    premature_allowed  boolean NOT NULL DEFAULT true,
    lock_in_months     integer NOT NULL DEFAULT 0,
    premature_rate_reduction numeric(7,4) NOT NULL DEFAULT 0,
    rd_grace_days      integer,
    rd_missed_penalty  numeric(18,2),
    rd_max_missed      integer,
    maturity_action    text NOT NULL DEFAULT 'PAY_OUT' CHECK (maturity_action IN ('PAY_OUT','AUTO_RENEW')),
    eligibility        jsonb NOT NULL DEFAULT '{}'::jsonb,
    rule_set_id        uuid,
    liability_account_id uuid,
    interest_account_id  uuid,
    reason             text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code, version_no),
    FOREIGN KEY (tenant_id, rule_set_id) REFERENCES cfg.rule_set (tenant_id, id),
    FOREIGN KEY (tenant_id, liability_account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, interest_account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS dep.deposit_rate_slab (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    deposit_product_id uuid NOT NULL,
    tenure_from_months integer NOT NULL,
    tenure_to_months   integer NOT NULL,
    amount_from        numeric(18,2) NOT NULL DEFAULT 0,
    amount_to          numeric(18,2),
    rate_annual        numeric(7,4) NOT NULL CHECK (rate_annual >= 0),
    effective_from     date NOT NULL DEFAULT current_date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_product_id) REFERENCES dep.deposit_product (tenant_id, id),
    CHECK (tenure_to_months >= tenure_from_months)
);

CREATE TABLE IF NOT EXISTS dep.deposit_account (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    account_no         text NOT NULL,
    member_id          uuid NOT NULL,
    deposit_product_id uuid NOT NULL,
    opened_on          date NOT NULL DEFAULT app.working_date(),
    principal_amount   numeric(18,2),             -- FD lump sum
    instalment_amount  numeric(18,2),             -- RD monthly amount
    tenure_months      integer NOT NULL CHECK (tenure_months > 0),
    interest_rate_annual numeric(7,4) NOT NULL,   -- fixed at opening
    maturity_date      date NOT NULL,
    estimated_maturity_amount numeric(18,2),
    balance            numeric(18,2) NOT NULL DEFAULT 0,
    status             text NOT NULL DEFAULT 'APPLIED' CHECK (status IN ('APPLIED','ACTIVE','MATURED','RENEWED',
                                                                         'PREMATURELY_CLOSED','CLOSED','FROZEN','REJECTED')),
    freeze_reason      text,
    renewed_from_id    uuid,
    maturity_instruction text CHECK (maturity_instruction IN ('PAY_OUT','AUTO_RENEW')),
    closed_on          date,
    approval_request_id uuid,
    rule_set_version_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, account_no),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_product_id) REFERENCES dep.deposit_product (tenant_id, id),
    FOREIGN KEY (tenant_id, renewed_from_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, rule_set_version_id) REFERENCES cfg.rule_set_version (tenant_id, id),
    CHECK (principal_amount IS NOT NULL OR instalment_amount IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS dep.deposit_rd_instalment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    deposit_account_id uuid NOT NULL,
    instalment_no      integer NOT NULL,
    due_date           date NOT NULL,
    amount             numeric(18,2) NOT NULL,
    paid_amount        numeric(18,2) NOT NULL DEFAULT 0,
    penalty_amount     numeric(18,2) NOT NULL DEFAULT 0,
    status             text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DUE','PAID','MISSED','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, deposit_account_id, instalment_no),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS dep.deposit_transaction (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    deposit_account_id uuid NOT NULL,
    txn_type           text NOT NULL CHECK (txn_type IN ('DEPOSIT','RD_INSTALMENT','INTEREST_CREDIT','INTEREST_PAYOUT',
                                                         'MATURITY_PAYOUT','PREMATURE_PAYOUT','PENALTY','TDS','DEATH_CLAIM_PAYOUT')),
    value_date         date NOT NULL DEFAULT app.working_date(),
    amount             numeric(18,2) NOT NULL CHECK (amount > 0),
    balance_after      numeric(18,2),
    deposit_rd_instalment_id uuid,
    cash_receipt_id    uuid,
    payment_voucher_id uuid,
    journal_id         uuid,
    status             text NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','REVERSED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_rd_instalment_id) REFERENCES dep.deposit_rd_instalment (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS dep.deposit_nominee (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    deposit_account_id uuid NOT NULL,
    nominee_id         uuid NOT NULL,
    share_percent      numeric(5,2) NOT NULL CHECK (share_percent > 0 AND share_percent <= 100),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, deposit_account_id, nominee_id),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, nominee_id) REFERENCES mbr.nominee (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS dep.deposit_lien (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    deposit_account_id uuid NOT NULL,
    loan_id            uuid NOT NULL,
    lien_amount        numeric(18,2) NOT NULL CHECK (lien_amount > 0),
    consent_document_id uuid,
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RELEASED','INVOKED')),
    released_on        date,
    invoke_approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, deposit_account_id) REFERENCES dep.deposit_account (tenant_id, id),
    FOREIGN KEY (tenant_id, loan_id) REFERENCES loan.loan (tenant_id, id),
    FOREIGN KEY (tenant_id, consent_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, invoke_approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

-- ===== Chit funds ============================================================
CREATE TABLE IF NOT EXISTS chit.chit_scheme (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code               text NOT NULL,
    version_no         integer NOT NULL DEFAULT 1,
    name               text NOT NULL,
    duration_months    integer NOT NULL CHECK (duration_months > 0),
    member_count       integer NOT NULL CHECK (member_count > 0),
    subscription_amount numeric(18,2) NOT NULL CHECK (subscription_amount > 0),
    chit_value         numeric(18,2) GENERATED ALWAYS AS (subscription_amount * member_count) STORED,
    payout_method      text NOT NULL CHECK (payout_method IN ('AUCTION','LOTTERY','FIXED_TURN','COMBINATION')),
    max_discount_pct   numeric(5,2) NOT NULL,
    foreman_commission_pct numeric(5,2) NOT NULL,
    dividend_treatment text NOT NULL DEFAULT 'DEDUCT_NEXT' CHECK (dividend_treatment IN ('DEDUCT_NEXT','PAY_OUT')),
    auction_day        integer CHECK (auction_day BETWEEN 1 AND 31),
    late_rules         jsonb NOT NULL DEFAULT '{}'::jsonb,   -- grace days, late fee, missed before default
    security_rules     jsonb NOT NULL DEFAULT '{}'::jsonb,
    eligibility        jsonb NOT NULL DEFAULT '{}'::jsonb,   -- max tickets per member ...
    tie_break_rule     text NOT NULL DEFAULT 'DRAW_OF_LOTS',
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code, version_no)
);

CREATE TABLE IF NOT EXISTS chit.chit_group (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    group_code         text NOT NULL,
    chit_scheme_id     uuid NOT NULL,
    scheme_snapshot    jsonb NOT NULL,             -- the group keeps the settings it started with
    start_date         date,
    status             text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','REGISTERED','ACTIVE','COMPLETED','CLOSED','TERMINATED')),
    registration_no    text,
    registration_date  date,
    registrar          text,
    registration_document_id uuid,
    legal_warning_ack_at timestamptz,
    legal_warning_ack_by uuid,
    subscriptions_account_id uuid,
    prize_payable_account_id uuid,
    dividend_payable_account_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, group_code),
    FOREIGN KEY (tenant_id, chit_scheme_id) REFERENCES chit.chit_scheme (tenant_id, id),
    FOREIGN KEY (tenant_id, registration_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, legal_warning_ack_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, subscriptions_account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, prize_payable_account_id) REFERENCES acct.account (tenant_id, id),
    FOREIGN KEY (tenant_id, dividend_payable_account_id) REFERENCES acct.account (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_ticket (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_group_id      uuid NOT NULL,
    ticket_no          integer NOT NULL,
    member_id          uuid NOT NULL,
    nominee_id         uuid,
    enrolled_on        date NOT NULL DEFAULT app.working_date(),
    status             text NOT NULL DEFAULT 'NON_PRIZED' CHECK (status IN ('NON_PRIZED','PRIZED','DEFAULTED','SUBSTITUTED',
                                                                            'WITHDRAWN','COMPLETED','FROZEN')),
    prized_month       integer,
    substituted_by_ticket_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, chit_group_id, ticket_no),
    FOREIGN KEY (tenant_id, chit_group_id) REFERENCES chit.chit_group (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, nominee_id) REFERENCES mbr.nominee (tenant_id, id),
    FOREIGN KEY (tenant_id, substituted_by_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_instalment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_ticket_id     uuid NOT NULL,
    month_no           integer NOT NULL,
    due_date           date NOT NULL,
    gross_amount       numeric(18,2) NOT NULL,
    dividend_adjusted  numeric(18,2) NOT NULL DEFAULT 0,
    net_amount         numeric(18,2) GENERATED ALWAYS AS (gross_amount - dividend_adjusted) STORED,
    paid_amount        numeric(18,2) NOT NULL DEFAULT 0,
    late_fee           numeric(18,2) NOT NULL DEFAULT 0,
    status             text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DUE','PARTLY_PAID','PAID','DEFAULTED','CANCELLED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, chit_ticket_id, month_no),
    FOREIGN KEY (tenant_id, chit_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_instalment_payment (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_instalment_id uuid NOT NULL,
    cash_receipt_id    uuid NOT NULL,
    amount             numeric(18,2) NOT NULL CHECK (amount > 0),
    late_fee_amount    numeric(18,2) NOT NULL DEFAULT 0,
    status             text NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','REVERSED')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_instalment_id) REFERENCES chit.chit_instalment (tenant_id, id),
    FOREIGN KEY (tenant_id, cash_receipt_id) REFERENCES acct.cash_receipt (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_auction (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_group_id      uuid NOT NULL,
    month_no           integer NOT NULL,
    auction_date       date NOT NULL,
    method             text NOT NULL CHECK (method IN ('AUCTION','LOTTERY','FIXED_TURN','FOREMAN')),
    winning_ticket_id  uuid,
    winning_discount   numeric(18,2) NOT NULL DEFAULT 0,
    attendance         jsonb,
    minutes_document_id uuid,
    status             text NOT NULL DEFAULT 'SCHEDULED' CHECK (status IN ('SCHEDULED','HELD','APPROVED','CANCELLED')),
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, chit_group_id, month_no),
    FOREIGN KEY (tenant_id, chit_group_id) REFERENCES chit.chit_group (tenant_id, id),
    FOREIGN KEY (tenant_id, winning_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id),
    FOREIGN KEY (tenant_id, minutes_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_bid (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_auction_id    uuid NOT NULL,
    chit_ticket_id     uuid NOT NULL,
    discount_amount    numeric(18,2) NOT NULL CHECK (discount_amount >= 0),
    bid_at             timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_auction_id) REFERENCES chit.chit_auction (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_dividend (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_group_id      uuid NOT NULL,
    month_no           integer NOT NULL,
    total_dividend     numeric(18,2) NOT NULL,
    per_ticket         numeric(18,2) NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, chit_group_id, month_no),
    FOREIGN KEY (tenant_id, chit_group_id) REFERENCES chit.chit_group (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS chit.chit_prize (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    chit_auction_id    uuid NOT NULL,
    chit_ticket_id     uuid NOT NULL,
    chit_value         numeric(18,2) NOT NULL,
    discount           numeric(18,2) NOT NULL,
    commission         numeric(18,2) NOT NULL,
    prize_amount       numeric(18,2) NOT NULL,
    security_type      text,
    guarantor_member_id uuid,
    security_document_id uuid,
    status             text NOT NULL DEFAULT 'CALCULATED' CHECK (status IN ('CALCULATED','SECURED','APPROVED','PAID','CANCELLED')),
    approval_request_id uuid,
    payment_voucher_id uuid,
    journal_id         uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, chit_auction_id),
    FOREIGN KEY (tenant_id, chit_auction_id) REFERENCES chit.chit_auction (tenant_id, id),
    FOREIGN KEY (tenant_id, chit_ticket_id) REFERENCES chit.chit_ticket (tenant_id, id),
    FOREIGN KEY (tenant_id, guarantor_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, security_document_id) REFERENCES core.document (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, payment_voucher_id) REFERENCES acct.payment_voucher (tenant_id, id),
    FOREIGN KEY (tenant_id, journal_id) REFERENCES acct.journal (tenant_id, id),
    CHECK (prize_amount = chit_value - discount)
);

-- ===== Notifications (Section 30) ===========================================
CREATE TABLE IF NOT EXISTS notif.notification_template (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    code               text NOT NULL,
    channel            text NOT NULL CHECK (channel IN ('SMS','WHATSAPP','EMAIL','INAPP')),
    language_code      text NOT NULL DEFAULT 'en',
    name               text NOT NULL,
    subject            text,
    body               text NOT NULL,
    dlt_template_id    text,                       -- TRAI DLT registration (SMS)
    provider_template_id text,                     -- WhatsApp approved template
    module_code        text REFERENCES platform.module (module_code),
    is_essential       boolean NOT NULL DEFAULT true,
    status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','INACTIVE')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, code, channel, language_code)
);

CREATE TABLE IF NOT EXISTS notif.notification_message (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    notification_template_id uuid,
    channel            text NOT NULL CHECK (channel IN ('SMS','WHATSAPP','EMAIL','INAPP')),
    recipient_type     text NOT NULL CHECK (recipient_type IN ('MEMBER','USER','NOMINEE','GUARANTOR','HALL_CUSTOMER','OTHER')),
    recipient_id       uuid,
    to_address         text NOT NULL,
    subject            text,
    body               text NOT NULL,
    entity_type        text,
    entity_id          uuid,
    is_adhoc           boolean NOT NULL DEFAULT false,
    status             text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','DELIVERED','READ','FAILED','SUPPRESSED','CANCELLED')),
    suppress_reason    text,                       -- QUIET_HOURS, OPTED_OUT, DECEASED ...
    scheduled_at       timestamptz NOT NULL DEFAULT now(),
    sent_at            timestamptz,
    delivered_at       timestamptz,
    attempts           integer NOT NULL DEFAULT 0,
    provider           text,
    provider_message_id text,
    failure_reason     text,
    fallback_of_id     uuid,                       -- SMS fallback after WhatsApp failure
    cost_units         numeric(10,2),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, notification_template_id) REFERENCES notif.notification_template (tenant_id, id),
    FOREIGN KEY (tenant_id, fallback_of_id) REFERENCES notif.notification_message (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS notification_message_queue_idx ON notif.notification_message (status, scheduled_at) WHERE status = 'QUEUED';
CREATE INDEX IF NOT EXISTS notification_message_entity_idx ON notif.notification_message (tenant_id, entity_type, entity_id);
