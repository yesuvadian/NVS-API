-- =============================================================================
-- CFMS / NVS  -  17  Concurrency controls: idempotent requests and one-pending
--                   request indexes (double-save / concurrent-save review)
-- -----------------------------------------------------------------------------
-- Run as nvs, before 20_security_rls_audit.sql (which secures every tenant
-- table). Safe to re-run.
--
-- Idempotent requests
--   The API sends the client's Idempotency-Key with every money posting. The
--   first request with a key records it here in the same transaction as the
--   posting and stores the response; a repeat (double-click, client or proxy
--   retry after a timeout) gets the stored response instead of a second
--   receipt. Two requests with the same key at the same moment are serialised
--   by the unique index: the second waits for the first to commit, then
--   replays its response. If the first fails, its row rolls back with it and
--   the second request runs normally.
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.idempotency_request (
    id              uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id       uuid NOT NULL DEFAULT app.tenant_id() REFERENCES platform.tenant (id),
    idempotency_key text NOT NULL CHECK (idempotency_key ~ '^[A-Za-z0-9_.:-]{8,100}$'),
    operation       text NOT NULL,
    request_hash    text NOT NULL,
    status          text NOT NULL DEFAULT 'IN_PROGRESS' CHECK (status IN ('IN_PROGRESS','COMPLETED')),
    response        jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT app.user_id(),
    completed_at    timestamptz,
    UNIQUE (tenant_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS idempotency_request_key_uq
    ON core.idempotency_request (tenant_id, idempotency_key);
CREATE INDEX IF NOT EXISTS idempotency_request_created_idx
    ON core.idempotency_request (created_at);

-- Start an idempotent request. Returns NULL when the caller should go ahead
-- (the key is now reserved by this transaction), or {"response": <stored>}
-- with the response of the earlier request that used the same key. A key reused for a different request
-- fails with IDEMPOTENCY_KEY_REUSED.
CREATE OR REPLACE FUNCTION core.idempotency_begin(p_key text, p_operation text, p_request_hash text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_id uuid;
    v_row core.idempotency_request%ROWTYPE;
BEGIN
    IF app.tenant_id() IS NULL THEN
        PERFORM app.fail('TENANT_CONTEXT_REQUIRED', 'A tenant context is required');
    END IF;
    IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
        PERFORM app.fail('IDEMPOTENCY_KEY_INVALID',
            'The Idempotency-Key must be 8 to 100 letters, digits or the characters _ . : -');
    END IF;
    IF coalesce(p_operation, '') = '' OR coalesce(p_request_hash, '') = '' THEN
        PERFORM app.fail('IDEMPOTENCY_KEY_INVALID', 'The idempotent operation and request hash are required');
    END IF;

    -- Waits for a concurrent transaction holding the same key, then either
    -- inserts (that transaction rolled back) or does nothing (it committed).
    INSERT INTO core.idempotency_request (idempotency_key, operation, request_hash)
    VALUES (p_key, p_operation, p_request_hash)
    ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
        PERFORM set_config('app.idempotency_key', p_key, true);
        RETURN NULL;
    END IF;

    SELECT * INTO v_row FROM core.idempotency_request
     WHERE tenant_id = app.tenant_id() AND idempotency_key = p_key;
    IF v_row.operation <> p_operation OR v_row.request_hash <> p_request_hash THEN
        PERFORM app.fail('IDEMPOTENCY_KEY_REUSED',
            'This Idempotency-Key was already used for a different request.');
    END IF;
    IF v_row.status <> 'COMPLETED' THEN
        PERFORM app.fail('IDEMPOTENCY_REQUEST_IN_PROGRESS',
            'The same request is still being processed. Try again in a moment.');
    END IF;
    RETURN jsonb_build_object('response', v_row.response);
END
$$;

-- Store the response of the request that reserved p_key in this transaction.
CREATE OR REPLACE FUNCTION core.idempotency_finish(p_key text, p_response jsonb)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE core.idempotency_request
       SET status = 'COMPLETED', response = coalesce(p_response, 'null'::jsonb), completed_at = now()
     WHERE tenant_id = app.tenant_id() AND idempotency_key = p_key AND status = 'IN_PROGRESS';
    IF NOT FOUND THEN
        PERFORM app.fail('IDEMPOTENCY_KEY_INVALID', 'No idempotent request is in progress for this key');
    END IF;
    PERFORM set_config('app.idempotency_key', '', true);
END
$$;

-- The key of the idempotent request running in this transaction, if any.
-- Receipts, journals and payment vouchers created by the request carry it.
CREATE OR REPLACE FUNCTION core.current_idempotency_key()
RETURNS text LANGUAGE sql STABLE AS
$$
    SELECT nullif(current_setting('app.idempotency_key', true), '')
$$;

-- Housekeeping: completed keys older than the retention period can go.
-- Clients must not retry a request with a key older than this.
CREATE OR REPLACE FUNCTION core.purge_idempotency_requests(p_older_than interval DEFAULT interval '30 days')
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE v_count integer;
BEGIN
    DELETE FROM core.idempotency_request
     WHERE tenant_id = app.tenant_id() AND status = 'COMPLETED' AND created_at < now() - p_older_than;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END
$$;

-- -----------------------------------------------------------------------------
-- One pending request per item. The functions already check for a pending
-- request under a row lock; these indexes make the rule hold for any caller.
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS cooling_off_override_pending_uq
    ON loan.cooling_off_override (tenant_id, member_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX IF NOT EXISTS loan_waiver_pending_uq
    ON loan.loan_waiver (tenant_id, loan_id, component,
                         coalesce(loan_charge_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE status = 'PENDING';
CREATE UNIQUE INDEX IF NOT EXISTS loan_restructure_pending_uq
    ON loan.loan_restructure (tenant_id, loan_id) WHERE status = 'REQUESTED';
CREATE UNIQUE INDEX IF NOT EXISTS loan_write_off_open_uq
    ON loan.loan_write_off (tenant_id, loan_id) WHERE status IN ('PROPOSED','APPROVED');

-- A late fee is assessed at most once per instalment per day, even if two
-- daily runs overlap.
CREATE UNIQUE INDEX IF NOT EXISTS loan_charge_late_fee_once_uq
    ON loan.loan_charge (tenant_id, loan_instalment_id, assessed_on)
    WHERE charge_type = 'LATE_FEE' AND status <> 'CANCELLED';
