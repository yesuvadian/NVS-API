-- =============================================================================
-- CFMS / NVS  -  07  Members, family, nominees, successors (Sections 5, 11, 12)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run.
-- Members are customers, not users: they never log in.
-- =============================================================================

CREATE TABLE IF NOT EXISTS mbr.member (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_no          text NOT NULL,
    branch_id          uuid,
    full_name          text NOT NULL,
    date_of_birth      date,
    gender             text CHECK (gender IN ('MALE','FEMALE','OTHER','UNDISCLOSED')),
    mobile             text,
    alt_mobile         text,
    email              text,
    address_line1      text,
    address_line2      text,
    city               text,
    district           text,
    state              text,
    pincode            text,
    membership_date    date,
    status             text NOT NULL DEFAULT 'APPLIED'
                       CHECK (status IN ('APPLIED','ACTIVE','INACTIVE','SUSPENDED','EXITED','DECEASED')),
    status_effective_date date,
    loan_eligibility   text NOT NULL DEFAULT 'ELIGIBLE'
                       CHECK (loan_eligibility IN ('ELIGIBLE','RESTRICTED','COOLING_OFF','REINSTATED')),
    cooling_off_until  date,
    date_of_death      date,
    preferred_language text NOT NULL DEFAULT 'en',
    preferred_channel  text NOT NULL DEFAULT 'SMS' CHECK (preferred_channel IN ('SMS','WHATSAPP','EMAIL','NONE')),
    previous_member_id uuid,                 -- readmission links to the earlier record
    merged_into_member_id uuid,              -- duplicate merge
    is_anonymised      boolean NOT NULL DEFAULT false,
    anonymised_at      timestamptz,
    notes              text,
    workflow_instance_id uuid,
    is_deleted         boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, member_no),
    FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch (tenant_id, id),
    FOREIGN KEY (tenant_id, previous_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, merged_into_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, workflow_instance_id) REFERENCES wf.workflow_instance (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS member_mobile_idx   ON mbr.member (tenant_id, mobile);
CREATE INDEX IF NOT EXISTS member_name_dob_idx ON mbr.member (tenant_id, lower(full_name), date_of_birth);
CREATE INDEX IF NOT EXISTS member_status_idx   ON mbr.member (tenant_id, status);

-- Identity documents: stored encrypted; a keyed hash supports duplicate detection.
CREATE TABLE IF NOT EXISTS mbr.member_identity (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id        uuid NOT NULL,
    id_type          text NOT NULL,            -- AADHAAR, PAN, VOTER_ID, PASSPORT, RATION_CARD, DL
    id_number_enc    text,                     -- encrypted by the API
    id_number_masked text,                     -- e.g. XXXX-XXXX-1234
    id_number_hash   text,                     -- HMAC for duplicate checks
    document_id      uuid,
    is_primary       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES core.document (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS member_identity_hash_uq
    ON mbr.member_identity (tenant_id, id_type, id_number_hash) WHERE id_number_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS mbr.member_family (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id      uuid NOT NULL,
    full_name      text NOT NULL,
    relationship   text NOT NULL,             -- SPOUSE, SON, DAUGHTER, FATHER, MOTHER ...
    date_of_birth  date,
    gender         text,
    is_child       boolean NOT NULL DEFAULT false,
    mobile         text,
    occupation     text,
    is_deceased    boolean NOT NULL DEFAULT false,
    linked_member_id uuid,                    -- if the relative is also a member
    is_deleted     boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, linked_member_id) REFERENCES mbr.member (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS mbr.member_status_history (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id       uuid NOT NULL,
    event_type      text NOT NULL CHECK (event_type IN ('JOINING','SUSPENSION','REINSTATEMENT','EXIT','READMISSION','DEATH','STATUS_CHANGE')),
    from_status     text,
    to_status       text NOT NULL,
    effective_date  date NOT NULL,
    reason          text,
    approval_request_id uuid,
    approved_by     uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS mbr.member_consent (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id       uuid NOT NULL,
    channel         text NOT NULL CHECK (channel IN ('SMS','WHATSAPP','EMAIL')),
    purpose         text NOT NULL DEFAULT 'NON_ESSENTIAL' CHECK (purpose IN ('ESSENTIAL','NON_ESSENTIAL')),
    opted_in        boolean NOT NULL,
    consent_at      timestamptz NOT NULL DEFAULT now(),
    source          text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    UNIQUE (tenant_id, member_id, channel, purpose)
);

CREATE TABLE IF NOT EXISTS mbr.member_duplicate_check (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id         uuid NOT NULL,
    matched_member_id uuid NOT NULL,
    match_basis       text NOT NULL CHECK (match_basis IN ('MOBILE','NAME_DOB','IDENTITY')),
    decision          text NOT NULL DEFAULT 'PENDING' CHECK (decision IN ('PENDING','CONTINUED','MERGED','DISMISSED')),
    reason            text,
    approval_request_id uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, matched_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, approval_request_id) REFERENCES wf.approval_request (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS mbr.member_merge (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    survivor_member_id uuid NOT NULL,
    merged_member_id   uuid NOT NULL,
    reason             text NOT NULL,
    approved_by        uuid NOT NULL,
    merged_at          timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, survivor_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, merged_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, approved_by) REFERENCES iam.app_user (tenant_id, id),
    CHECK (survivor_member_id <> merged_member_id)
);

-- Nominees (separate from guarantors and legal successors) -------------------------
CREATE TABLE IF NOT EXISTS mbr.nominee (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id        uuid NOT NULL,
    full_name        text NOT NULL,
    relationship     text NOT NULL,
    date_of_birth    date,
    mobile           text,
    address          text,
    id_type          text,
    id_number_masked text,
    id_number_enc    text,
    consent_document_id uuid,
    status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE','DECEASED')),
    is_deleted       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, consent_document_id) REFERENCES core.document (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS nominee_member_idx ON mbr.nominee (tenant_id, member_id);

-- Deceased member management (Section 12) -------------------------------------------
CREATE TABLE IF NOT EXISTS mbr.death_record (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id         uuid NOT NULL,
    date_of_death     date NOT NULL,
    reported_by       uuid NOT NULL,
    reported_on       date NOT NULL DEFAULT current_date,
    informant_name    text,
    certificate_document_id uuid,
    status            text NOT NULL DEFAULT 'REPORTED' CHECK (status IN ('REPORTED','VERIFIED','REJECTED')),
    verified_by       uuid,
    verified_at       timestamptz,
    interest_stops_from date,                 -- default: date of death
    remarks           text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, member_id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, reported_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, verified_by) REFERENCES iam.app_user (tenant_id, id),
    FOREIGN KEY (tenant_id, certificate_document_id) REFERENCES core.document (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS mbr.legal_successor (
    id           uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id    uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    member_id        uuid NOT NULL,
    full_name        text NOT NULL,
    relationship     text NOT NULL,
    mobile           text,
    address          text,
    linked_member_id uuid,
    id_type          text,
    id_number_masked text,
    verification_status text NOT NULL DEFAULT 'PENDING' CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED')),
    document_id      uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT app.user_id(),
    updated_at   timestamptz,
    updated_by   uuid,
    row_version  integer NOT NULL DEFAULT 1,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, linked_member_id) REFERENCES mbr.member (tenant_id, id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES core.document (tenant_id, id)
);
