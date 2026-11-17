-- =============================================================================
-- CFMS 45 - Indexes for foreign keys and quick search (gap review item 1)
--   * one (tenant_id, column...) index for every foreign key that has no index
--     starting with its columns (joins, RLS-filtered lookups, parent updates)
--   * trigram indexes for partial, case-insensitive search on names, mobile
--     numbers (matches last digits too) and reference numbers (Section 36)
-- pg_trgm is a trusted extension: the database owner can install it. Idempotent.
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

DO $$
DECLARE
    r       record;
    v_name  text;
    v_n     integer := 0;
BEGIN
    FOR r IN
        SELECT k.conrelid, k.conname, n.nspname, c.relname,
               (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY x.ord)
                  FROM unnest(k.conkey) WITH ORDINALITY AS x(attnum, ord)
                  JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.attnum) AS cols
          FROM pg_constraint k
          JOIN pg_class c     ON c.oid = k.conrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE k.contype = 'f'
           AND n.nspname IN ('platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
           AND NOT EXISTS (
               SELECT 1 FROM pg_index i
                WHERE i.indrelid = k.conrelid
                  AND (i.indkey::int2[])[0:array_length(k.conkey,1)-1] @> k.conkey
                  AND (i.indkey::int2[])[0:array_length(k.conkey,1)-1] <@ k.conkey)
         ORDER BY n.nspname, c.relname, k.conname
    LOOP
        v_name := left(r.conname, 55) || '_fkix';
        IF EXISTS (SELECT 1 FROM pg_class pc JOIN pg_namespace pn ON pn.oid = pc.relnamespace
                    WHERE pn.nspname = r.nspname AND pc.relname = v_name) THEN
            v_name := left(r.conname, 46) || '_' || left(md5(r.relname || r.conname), 8) || '_fkix';
        END IF;
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I.%I (%s)', v_name, r.nspname, r.relname, r.cols);
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'Foreign-key indexes created: %', v_n;
END
$$;

-- Quick search (partial, case-insensitive; mobile numbers and IDs match on last digits)
CREATE INDEX IF NOT EXISTS member_name_trgm      ON mbr.member      USING gin (lower(full_name) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS member_mobile_trgm    ON mbr.member      USING gin (mobile public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS member_no_trgm        ON mbr.member      USING gin (lower(member_no) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS loan_no_trgm          ON loan.loan       USING gin (lower(loan_no) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS cash_receipt_no_trgm  ON acct.cash_receipt USING gin (lower(receipt_no) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS payment_voucher_no_trgm ON acct.payment_voucher USING gin (lower(voucher_no) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS hall_booking_no_trgm  ON ops.hall_booking USING gin (lower(booking_no) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS hall_customer_name_trgm ON ops.hall_customer USING gin (lower(full_name) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS hall_customer_mobile_trgm ON ops.hall_customer USING gin (mobile public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS nominee_name_trgm     ON mbr.nominee     USING gin (lower(full_name) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS vendor_name_trgm      ON ops.vendor      USING gin (lower(name) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS employee_name_trgm    ON ops.employee    USING gin (lower(full_name) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS app_user_name_trgm    ON iam.app_user    USING gin (lower(full_name) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS asset_no_trgm         ON ops.asset       USING gin (lower(asset_no) public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS deposit_account_no_trgm ON dep.deposit_account USING gin (lower(account_no) public.gin_trgm_ops);

