-- =============================================================================
-- CFMS / NVS  -  39  Loan reports, supporting documents and the sanction letter
--                   (functional gap review, Nov 2026)
-- -----------------------------------------------------------------------------
-- Reports (scope 23.3). All amounts are as of the working date unless a period
-- is given. Every report returns jsonb {as_of, ..., totals, items}.
--   loan.report_outstanding(loan_type_id, status)
--   loan.report_interest(from, to)              interest due vs collected
--   loan.report_ageing()                        ageing buckets and PAR 30/60/90
--   loan.report_demand_collection(from, to)     demand, collection, efficiency
--   loan.report_due_list(from, to)              instalments falling due
--   loan.report_overdue_list(min_days)          loans in arrears
--   loan.report_restructured_written_off()
--   loan.report_guarantor_exposure()
-- Documents (gap L8). Files are stored by the client / storage service; the
-- database keeps the metadata in core.document (entity_type 'LOAN').
--   loan.add_loan_document(loan, details jsonb)  document_type (lookup DOCUMENT_TYPE),
--       file_name, storage_key, content_type, size_bytes, sha256, description
--   loan.list_loan_documents(loan), loan.remove_loan_document(document)
--   loan.missing_documents(loan)    types required by loan_type.required_documents
--                                   or rule REQUIRED_DOCUMENTS {"types":[...]}
-- Sanction letter
--   loan.sanction_letter(loan)      everything the letter prints, as jsonb
-- Run as nvs. Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION loan.open_loan_statuses()
RETURNS text[] LANGUAGE sql IMMUTABLE AS
$$ SELECT ARRAY['ACTIVE','OVERDUE','DEFAULTED','RESTRUCTURED'] $$;

-- -----------------------------------------------------------------------------
-- Outstanding
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_outstanding(p_loan_type_id uuid DEFAULT NULL, p_status text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH b AS (
        SELECT b.*, m.member_no, m.full_name AS member_name, lt.code AS loan_type_code, lt.name AS loan_type_name
          FROM loan.v_loan_balance b
          JOIN mbr.member m ON m.tenant_id = b.tenant_id AND m.id = b.member_id
          JOIN loan.loan_type lt ON lt.tenant_id = b.tenant_id AND lt.id = b.loan_type_id
         WHERE b.tenant_id = app.tenant_id()
           AND b.status = ANY (CASE WHEN p_status IS NULL THEN loan.open_loan_statuses() ELSE ARRAY[upper(p_status)] END)
           AND (p_loan_type_id IS NULL OR b.loan_type_id = p_loan_type_id)
    )
    SELECT jsonb_build_object(
        'as_of', app.working_date(),
        'totals', jsonb_build_object(
            'loans', count(*),
            'principal_disbursed', coalesce(sum(principal_disbursed), 0),
            'outstanding_principal', coalesce(sum(outstanding_principal), 0),
            'interest_outstanding', coalesce(sum(interest_outstanding_scheduled), 0),
            'overdue_principal', coalesce(sum(overdue_principal), 0),
            'overdue_interest', coalesce(sum(overdue_interest), 0),
            'charges_open', coalesce(sum(charges_open), 0)),
        'by_loan_type', coalesce((SELECT jsonb_agg(jsonb_build_object('loan_type_code', t.loan_type_code,
                                         'loan_type_name', t.loan_type_name, 'loans', t.loans,
                                         'outstanding_principal', t.outstanding) ORDER BY t.loan_type_code)
                                    FROM (SELECT loan_type_code, loan_type_name, count(*) loans,
                                                 sum(outstanding_principal) outstanding
                                            FROM b GROUP BY loan_type_code, loan_type_name) t), '[]'::jsonb),
        'items', coalesce(jsonb_agg(jsonb_build_object(
            'loan_id', loan_id, 'loan_no', loan_no, 'member_no', member_no, 'member_name', member_name,
            'loan_type_code', loan_type_code, 'status', status, 'principal_disbursed', principal_disbursed,
            'outstanding_principal', outstanding_principal, 'interest_outstanding', interest_outstanding_scheduled,
            'overdue_principal', overdue_principal, 'overdue_interest', overdue_interest,
            'charges_open', charges_open, 'days_overdue', days_overdue, 'next_due_date', next_due_date)
            ORDER BY loan_no), '[]'::jsonb))
      FROM b
$$;

-- -----------------------------------------------------------------------------
-- Interest due vs collected in a period
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_interest(p_from date, p_to date)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH due AS (
        SELECT l.loan_type_id, sum(i.interest_due) AS interest_due
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
          JOIN loan.loan l ON l.tenant_id = i.tenant_id AND l.id = i.loan_id AND NOT l.is_deleted
         WHERE i.tenant_id = app.tenant_id() AND i.due_date BETWEEN p_from AND p_to AND i.status <> 'CANCELLED'
         GROUP BY l.loan_type_id
    ), got AS (
        SELECT l.loan_type_id, sum(r.interest_amount) AS interest_collected
          FROM loan.loan_repayment r
          JOIN loan.loan l ON l.tenant_id = r.tenant_id AND l.id = r.loan_id
         WHERE r.tenant_id = app.tenant_id() AND r.status = 'POSTED' AND r.value_date BETWEEN p_from AND p_to
         GROUP BY l.loan_type_id
    ), rows AS (
        SELECT lt.code, lt.name, coalesce(d.interest_due, 0) AS interest_due, coalesce(g.interest_collected, 0) AS interest_collected
          FROM loan.loan_type lt
          LEFT JOIN due d ON d.loan_type_id = lt.id
          LEFT JOIN got g ON g.loan_type_id = lt.id
         WHERE lt.tenant_id = app.tenant_id() AND (d.loan_type_id IS NOT NULL OR g.loan_type_id IS NOT NULL)
    )
    SELECT jsonb_build_object(
        'from', p_from, 'to', p_to,
        'totals', jsonb_build_object('interest_due', coalesce(sum(interest_due), 0),
                                     'interest_collected', coalesce(sum(interest_collected), 0),
                                     'shortfall', coalesce(sum(interest_due - interest_collected), 0)),
        'items', coalesce(jsonb_agg(jsonb_build_object('loan_type_code', code, 'loan_type_name', name,
                                                       'interest_due', interest_due, 'interest_collected', interest_collected)
                                    ORDER BY code), '[]'::jsonb))
      FROM rows
$$;

-- -----------------------------------------------------------------------------
-- Ageing and portfolio at risk
-- PAR n = outstanding principal of loans more than n days overdue / all
-- outstanding principal, in per cent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_ageing()
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH b AS (
        SELECT outstanding_principal, overdue_principal + overdue_interest AS overdue_amount, days_overdue,
               CASE WHEN days_overdue <= 0 THEN 'CURRENT' WHEN days_overdue <= 30 THEN '1-30'
                    WHEN days_overdue <= 60 THEN '31-60' WHEN days_overdue <= 90 THEN '61-90'
                    WHEN days_overdue <= 180 THEN '91-180' ELSE '180+' END AS bucket
          FROM loan.v_loan_balance
         WHERE tenant_id = app.tenant_id() AND status = ANY (loan.open_loan_statuses())
    ), buckets(bucket, ord) AS (
        VALUES ('CURRENT',1), ('1-30',2), ('31-60',3), ('61-90',4), ('91-180',5), ('180+',6)
    ), tot AS (
        SELECT coalesce(sum(outstanding_principal), 0) AS outstanding FROM b
    )
    SELECT jsonb_build_object(
        'as_of', app.working_date(),
        'totals', jsonb_build_object('loans', (SELECT count(*) FROM b), 'outstanding_principal', tot.outstanding),
        'par', jsonb_build_object(
            'par30', CASE WHEN tot.outstanding = 0 THEN 0 ELSE round(100 * (SELECT coalesce(sum(outstanding_principal), 0) FROM b WHERE days_overdue > 30) / tot.outstanding, 2) END,
            'par60', CASE WHEN tot.outstanding = 0 THEN 0 ELSE round(100 * (SELECT coalesce(sum(outstanding_principal), 0) FROM b WHERE days_overdue > 60) / tot.outstanding, 2) END,
            'par90', CASE WHEN tot.outstanding = 0 THEN 0 ELSE round(100 * (SELECT coalesce(sum(outstanding_principal), 0) FROM b WHERE days_overdue > 90) / tot.outstanding, 2) END),
        'items', (SELECT jsonb_agg(jsonb_build_object(
                         'bucket', k.bucket,
                         'loans', (SELECT count(*) FROM b WHERE b.bucket = k.bucket),
                         'outstanding_principal', (SELECT coalesce(sum(outstanding_principal), 0) FROM b WHERE b.bucket = k.bucket),
                         'overdue_amount', (SELECT coalesce(sum(overdue_amount), 0) FROM b WHERE b.bucket = k.bucket))
                         ORDER BY k.ord) FROM buckets k))
      FROM tot
$$;

-- -----------------------------------------------------------------------------
-- Demand vs collection in a period
--   demand            principal + interest of instalments due in the period
--   arrears_at_start  principal + interest due before the period and not paid
--                     by its start (from the current schedules)
--   collected_against_demand  payments in the period to instalments due in it
--   collection        everything collected in the period (incl. fees, arrears, advances)
--   efficiency        collected_against_demand / demand
--   overall_efficiency  principal+interest collected / (demand + arrears_at_start)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_demand_collection(p_from date, p_to date)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH inst AS (
        SELECT i.id, i.due_date, i.principal_due + i.interest_due AS due
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
          JOIN loan.loan l ON l.tenant_id = i.tenant_id AND l.id = i.loan_id AND NOT l.is_deleted
         WHERE i.tenant_id = app.tenant_id() AND i.status NOT IN ('CANCELLED','WAIVED') AND i.due_date <= p_to
    ), alloc AS (
        SELECT a.loan_instalment_id, r.value_date, a.amount
          FROM loan.loan_repayment_allocation a
          JOIN loan.loan_repayment r ON r.tenant_id = a.tenant_id AND r.id = a.loan_repayment_id AND r.status = 'POSTED'
         WHERE a.tenant_id = app.tenant_id() AND a.component IN ('PRINCIPAL','INTEREST') AND a.loan_instalment_id IS NOT NULL
    ), figures AS (
        SELECT
            (SELECT coalesce(sum(due), 0) FROM inst WHERE due_date BETWEEN p_from AND p_to) AS demand,
            (SELECT coalesce(sum(due), 0) FROM inst WHERE due_date < p_from)
              - (SELECT coalesce(sum(a.amount), 0) FROM alloc a JOIN inst i ON i.id = a.loan_instalment_id
                  WHERE i.due_date < p_from AND a.value_date < p_from) AS arrears_at_start,
            (SELECT coalesce(sum(a.amount), 0) FROM alloc a JOIN inst i ON i.id = a.loan_instalment_id
              WHERE i.due_date BETWEEN p_from AND p_to AND a.value_date BETWEEN p_from AND p_to) AS against_demand,
            (SELECT coalesce(sum(a.amount), 0) FROM alloc a JOIN inst i ON i.id = a.loan_instalment_id
              WHERE i.due_date < p_from AND a.value_date BETWEEN p_from AND p_to) AS against_arrears,
            (SELECT coalesce(sum(r.principal_amount + r.interest_amount), 0) FROM loan.loan_repayment r
              WHERE r.tenant_id = app.tenant_id() AND r.status = 'POSTED' AND r.value_date BETWEEN p_from AND p_to) AS pi_collected,
            (SELECT coalesce(sum(r.amount), 0) FROM loan.loan_repayment r
              WHERE r.tenant_id = app.tenant_id() AND r.status = 'POSTED' AND r.value_date BETWEEN p_from AND p_to) AS collection
    )
    SELECT jsonb_build_object(
        'from', p_from, 'to', p_to,
        'demand', demand, 'arrears_at_start', arrears_at_start,
        'collected_against_demand', against_demand, 'collected_against_arrears', against_arrears,
        'principal_interest_collected', pi_collected, 'collection', collection,
        'efficiency', CASE WHEN demand = 0 THEN NULL ELSE round(100 * against_demand / demand, 2) END,
        'overall_efficiency', CASE WHEN demand + arrears_at_start = 0 THEN NULL
                                   ELSE round(100 * least(pi_collected, demand + arrears_at_start) / (demand + arrears_at_start), 2) END)
      FROM figures
$$;

-- -----------------------------------------------------------------------------
-- Due list and overdue list
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_due_list(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH d AS (
        SELECT l.id AS loan_id, l.loan_no, m.member_no, m.full_name AS member_name, m.mobile, i.instalment_no, i.due_date,
               (i.principal_due - i.principal_paid) AS principal, (i.interest_due - i.interest_paid) AS interest,
               (i.principal_due - i.principal_paid) + (i.interest_due - i.interest_paid) AS amount_due
          FROM loan.loan_instalment i
          JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
          JOIN loan.loan l ON l.tenant_id = i.tenant_id AND l.id = i.loan_id AND NOT l.is_deleted
          JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
         WHERE i.tenant_id = app.tenant_id() AND i.status IN ('DUE','PARTLY_PAID')
           AND l.status = ANY (loan.open_loan_statuses())
           AND i.due_date BETWEEN coalesce(p_from, app.working_date()) AND coalesce(p_to, p_from, app.working_date())
    )
    SELECT jsonb_build_object(
        'from', coalesce(p_from, app.working_date()), 'to', coalesce(p_to, p_from, app.working_date()),
        'totals', jsonb_build_object('instalments', count(*), 'amount_due', coalesce(sum(amount_due), 0)),
        'items', coalesce(jsonb_agg(to_jsonb(d) ORDER BY due_date, loan_no, instalment_no), '[]'::jsonb))
      FROM d
$$;

CREATE OR REPLACE FUNCTION loan.report_overdue_list(p_min_days integer DEFAULT 1)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH o AS (
        SELECT b.loan_id, b.loan_no, m.member_no, m.full_name AS member_name, m.mobile, b.status,
               b.overdue_principal, b.overdue_interest, b.charges_open,
               b.overdue_principal + b.overdue_interest + b.charges_open AS overdue_amount,
               b.outstanding_principal, b.oldest_unpaid_due_date, b.days_overdue, b.last_payment_on,
               rc.assigned_to, u.full_name AS assigned_to_name
          FROM loan.v_loan_balance b
          JOIN mbr.member m ON m.tenant_id = b.tenant_id AND m.id = b.member_id
          LEFT JOIN loan.recovery_case rc ON rc.tenant_id = b.tenant_id AND rc.loan_id = b.loan_id AND rc.closed_on IS NULL
          LEFT JOIN iam.app_user u ON u.tenant_id = rc.tenant_id AND u.id = rc.assigned_to
         WHERE b.tenant_id = app.tenant_id() AND b.status = ANY (loan.open_loan_statuses())
           AND b.days_overdue >= greatest(coalesce(p_min_days, 1), 1)
    )
    SELECT jsonb_build_object(
        'as_of', app.working_date(), 'min_days', greatest(coalesce(p_min_days, 1), 1),
        'totals', jsonb_build_object('loans', count(*), 'overdue_amount', coalesce(sum(overdue_amount), 0),
                                     'outstanding_principal', coalesce(sum(outstanding_principal), 0)),
        'items', coalesce(jsonb_agg(to_jsonb(o) ORDER BY days_overdue DESC, loan_no), '[]'::jsonb))
      FROM o
$$;

-- -----------------------------------------------------------------------------
-- Restructured and written-off loans
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_restructured_written_off()
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object(
        'as_of', app.working_date(),
        'restructured', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'loan_id', b.loan_id, 'loan_no', b.loan_no, 'member_name', m.full_name, 'status', b.status,
                       'restructure_count', l.restructure_count, 'last_restructured_on', r.decided_on,
                       'last_option', r.restructure_option, 'capitalised_amount', r.capitalised_amount,
                       'outstanding_principal', b.outstanding_principal, 'days_overdue', b.days_overdue)
                       ORDER BY b.loan_no)
              FROM loan.v_loan_balance b
              JOIN loan.loan l ON l.tenant_id = b.tenant_id AND l.id = b.loan_id
              JOIN mbr.member m ON m.tenant_id = b.tenant_id AND m.id = b.member_id
              LEFT JOIN LATERAL (SELECT * FROM loan.loan_restructure x
                                  WHERE x.tenant_id = l.tenant_id AND x.loan_id = l.id AND x.status = 'APPLIED'
                                  ORDER BY x.created_at DESC LIMIT 1) r ON true
             WHERE b.tenant_id = app.tenant_id() AND l.is_restructured), '[]'::jsonb),
        'written_off', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'loan_id', l.id, 'loan_no', l.loan_no, 'member_name', m.full_name, 'status', l.status,
                       'written_off', w.amount, 'written_off_on', w.on_date,
                       'recovered', coalesce((SELECT sum(r.amount) FROM loan.loan_repayment r
                                               WHERE r.tenant_id = l.tenant_id AND r.loan_id = l.id
                                                 AND r.repayment_type = 'RECOVERY' AND r.status = 'POSTED'), 0))
                       ORDER BY l.loan_no)
              FROM loan.loan l
              JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
              JOIN (SELECT tenant_id, loan_id, sum(principal_amount) amount, max(proposed_on) on_date
                      FROM loan.loan_write_off WHERE status IN ('APPROVED','POSTED') GROUP BY tenant_id, loan_id) w
                ON w.tenant_id = l.tenant_id AND w.loan_id = l.id
             WHERE l.tenant_id = app.tenant_id()), '[]'::jsonb))
$$;

-- -----------------------------------------------------------------------------
-- Guarantor exposure: open guarantees per guarantor and how the loans stand
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.report_guarantor_exposure()
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    WITH g AS (
        SELECT coalesce(g.guarantor_member_id::text, 'NM:' || lower(g.non_member_name) || ':' || coalesce(g.non_member_mobile, '')) AS gkey,
               g.guarantor_member_id, coalesce(gm.full_name, g.non_member_name) AS guarantor_name,
               coalesce(gm.mobile, g.non_member_mobile) AS guarantor_mobile, g.status AS guarantee_status,
               g.guaranteed_amount, b.loan_id, b.loan_no, bm.full_name AS borrower_name, b.status AS loan_status,
               b.outstanding_principal, b.overdue_principal + b.overdue_interest AS overdue_amount, b.days_overdue
          FROM loan.loan_guarantor g
          JOIN loan.v_loan_balance b ON b.tenant_id = g.tenant_id AND b.loan_id = g.loan_id
          JOIN mbr.member bm ON bm.tenant_id = b.tenant_id AND bm.id = b.member_id
          LEFT JOIN mbr.member gm ON gm.tenant_id = g.tenant_id AND gm.id = g.guarantor_member_id
         WHERE g.tenant_id = app.tenant_id() AND g.status IN ('ACTIVE','INVOKED')
           AND b.status NOT IN ('CLOSED','SETTLED','REJECTED','WITHDRAWN','CANCELLED','TRANSFERRED')
    ), per AS (
        SELECT gkey, max(guarantor_member_id::text)::uuid AS guarantor_member_id, max(guarantor_name) AS guarantor_name,
               max(guarantor_mobile) AS guarantor_mobile, count(*) AS guarantees,
               count(*) FILTER (WHERE guarantee_status = 'INVOKED') AS invoked,
               sum(guaranteed_amount) AS guaranteed_total, sum(outstanding_principal) AS loans_outstanding,
               sum(overdue_amount) AS loans_overdue,
               jsonb_agg(jsonb_build_object('loan_id', loan_id, 'loan_no', loan_no, 'borrower_name', borrower_name,
                                            'loan_status', loan_status, 'guarantee_status', guarantee_status,
                                            'guaranteed_amount', guaranteed_amount, 'outstanding_principal', outstanding_principal,
                                            'days_overdue', days_overdue) ORDER BY loan_no) AS loans
          FROM g GROUP BY gkey
    )
    SELECT jsonb_build_object(
        'as_of', app.working_date(),
        'totals', jsonb_build_object('guarantors', count(*), 'guarantees', coalesce(sum(guarantees), 0),
                                     'guaranteed_total', coalesce(sum(guaranteed_total), 0)),
        'items', coalesce(jsonb_agg((to_jsonb(per) - 'gkey') ORDER BY guaranteed_total DESC NULLS LAST, guarantor_name), '[]'::jsonb))
      FROM per
$$;

-- -----------------------------------------------------------------------------
-- Supporting documents
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.list_loan_documents(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'document_type', d.document_type,
                                                 'document_type_name', lv.name, 'file_name', d.file_name,
                                                 'content_type', d.content_type, 'size_bytes', d.size_bytes,
                                                 'storage_key', d.storage_key, 'sha256', d.sha256,
                                                 'description', d.description, 'created_at', d.created_at,
                                                 'created_by', d.created_by) ORDER BY d.created_at, d.id), '[]'::jsonb)
      FROM core.document d
      LEFT JOIN core.lookup_value lv ON lv.tenant_id = d.tenant_id AND lv.lookup_type = 'DOCUMENT_TYPE' AND lv.code = d.document_type
     WHERE d.tenant_id = app.tenant_id() AND d.entity_type = 'LOAN' AND d.entity_id = p_loan_id AND NOT d.is_deleted
$$;

CREATE OR REPLACE FUNCTION loan.required_documents(p_loan_id uuid)
RETURNS text[] LANGUAGE sql STABLE AS
$$
    SELECT coalesce(array_agg(DISTINCT t ORDER BY t), ARRAY[]::text[])
      FROM loan.loan l
      JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
      CROSS JOIN LATERAL (
          SELECT jsonb_array_elements_text(coalesce(lt.required_documents, '[]'::jsonb))
          UNION
          SELECT jsonb_array_elements_text(coalesce(loan.rule(l.rule_snapshot, 'REQUIRED_DOCUMENTS')->'value'->'types', '[]'::jsonb))
      ) x(t)
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id
$$;

CREATE OR REPLACE FUNCTION loan.missing_documents(p_loan_id uuid)
RETURNS text[] LANGUAGE sql STABLE AS
$$
    SELECT coalesce(array_agg(t ORDER BY t), ARRAY[]::text[])
      FROM unnest(loan.required_documents(p_loan_id)) t
     WHERE NOT EXISTS (SELECT 1 FROM core.document d
                        WHERE d.tenant_id = app.tenant_id() AND d.entity_type = 'LOAN' AND d.entity_id = p_loan_id
                          AND d.document_type = t AND NOT d.is_deleted)
$$;

CREATE OR REPLACE FUNCTION loan.add_loan_document(p_loan_id uuid, p_details jsonb)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_type text := upper(btrim(coalesce(p_details->>'document_type', '')));
BEGIN
    IF NOT EXISTS (SELECT 1 FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted) THEN
        PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.lookup_value WHERE tenant_id = app.tenant_id() AND lookup_type = 'DOCUMENT_TYPE'
                      AND code = v_type AND is_active) THEN
        PERFORM app.fail('DOCUMENT_TYPE_INVALID', 'Choose a listed document type.');
    END IF;
    IF coalesce(btrim(p_details->>'file_name'), '') = '' OR coalesce(btrim(p_details->>'storage_key'), '') = '' THEN
        PERFORM app.fail('DOCUMENT_DETAILS_REQUIRED', 'Give the file name and where the file is stored.');
    END IF;
    INSERT INTO core.document (entity_type, entity_id, document_type, file_name, content_type, size_bytes, storage_key,
                               sha256, description)
    VALUES ('LOAN', p_loan_id, v_type, p_details->>'file_name', p_details->>'content_type',
            nullif(p_details->>'size_bytes', '')::bigint, p_details->>'storage_key', p_details->>'sha256',
            p_details->>'description');
    RETURN loan.list_loan_documents(p_loan_id);
END
$$;

-- A document can be removed while the application can still be edited.
CREATE OR REPLACE FUNCTION loan.remove_loan_document(p_document_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE v_loan record;
BEGIN
    SELECT l.id, l.status INTO v_loan FROM core.document d
      JOIN loan.loan l ON l.tenant_id = d.tenant_id AND l.id = d.entity_id
     WHERE d.tenant_id = app.tenant_id() AND d.id = p_document_id AND d.entity_type = 'LOAN' AND NOT d.is_deleted
       FOR UPDATE OF d;
    IF NOT FOUND THEN PERFORM app.fail('DOCUMENT_NOT_FOUND', 'The document was not found.'); END IF;
    IF v_loan.status NOT IN ('DRAFT','RETURNED','FEE_PENDING') THEN
        PERFORM app.fail('APPLICATION_NOT_EDITABLE', 'Documents can be removed only while the application can be edited.');
    END IF;
    UPDATE core.document SET is_deleted = true, updated_at = now(), updated_by = app.user_id(), row_version = row_version + 1
     WHERE tenant_id = app.tenant_id() AND id = p_document_id;
    RETURN loan.list_loan_documents(v_loan.id);
END
$$;

-- -----------------------------------------------------------------------------
-- Sanction letter: available once the loan is approved.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loan.sanction_letter(p_loan_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v jsonb;
    v_status text;
BEGIN
    SELECT status INTO v_status FROM loan.loan WHERE tenant_id = app.tenant_id() AND id = p_loan_id AND NOT is_deleted;
    IF NOT FOUND THEN PERFORM app.fail('LOAN_NOT_FOUND', 'Loan was not found'); END IF;
    IF v_status IN ('DRAFT','FEE_PENDING','SUBMITTED','UNDER_APPROVAL','RETURNED','REJECTED','WITHDRAWN','CANCELLED') THEN
        PERFORM app.fail('LOAN_NOT_APPROVED', 'The sanction letter is available once the loan is approved.');
    END IF;
    SELECT jsonb_build_object(
        'generated_on', app.working_date(),
        'organisation', jsonb_build_object('name', t.name, 'legal_name', t.legal_name, 'registration_no', t.registration_no,
                                           'address', t.address, 'contact_mobile', t.contact_mobile,
                                           'contact_email', t.contact_email, 'currency_code', t.currency_code),
        'member', jsonb_build_object('member_no', m.member_no, 'full_name', m.full_name, 'mobile', m.mobile,
                                     'address', concat_ws(', ', nullif(m.address_line1, ''), nullif(m.address_line2, ''),
                                                          nullif(m.city, ''), nullif(m.district, ''), nullif(m.state, ''),
                                                          nullif(m.pincode, ''))),
        'loan', jsonb_build_object('loan_id', l.id, 'loan_no', l.loan_no, 'status', l.status, 'purpose', l.purpose,
                                   'loan_type_code', lt.code, 'loan_type_name', lt.name,
                                   'application_date', l.application_date, 'requested_amount', l.requested_amount,
                                   'approved_amount', l.approved_amount, 'tenure_months', l.tenure_months,
                                   'interest_rate_annual', l.interest_rate_annual, 'interest_method', l.interest_method,
                                   'total_interest', l.total_interest, 'instalment_amount', l.instalment_amount,
                                   'approved_at', l.approved_at, 'approval_expires_on', l.approval_expires_on,
                                   'first_due_date', l.first_due_date, 'maturity_date', l.maturity_date,
                                   'early_settlement_policy', l.early_settlement_policy),
        'approved_by', (SELECT u.full_name FROM iam.app_user u WHERE u.tenant_id = l.tenant_id AND u.id = l.approved_by),
        'fee', (SELECT jsonb_build_object('fee_amount', f.fee_amount, 'collect_timing', f.collect_timing, 'status', f.status)
                  FROM loan.loan_application_fee f WHERE f.tenant_id = l.tenant_id AND f.loan_id = l.id
                 ORDER BY f.created_at DESC LIMIT 1),
        'guarantors', coalesce((SELECT jsonb_agg(jsonb_build_object('name', coalesce(gm.full_name, g.non_member_name),
                                                                    'member_no', gm.member_no,
                                                                    'guaranteed_amount', g.guaranteed_amount) ORDER BY g.created_at)
                                  FROM loan.loan_guarantor g
                                  LEFT JOIN mbr.member gm ON gm.tenant_id = g.tenant_id AND gm.id = g.guarantor_member_id
                                 WHERE g.tenant_id = l.tenant_id AND g.loan_id = l.id AND g.status IN ('ACTIVE','INVOKED')), '[]'::jsonb),
        'nominees', coalesce((SELECT jsonb_agg(jsonb_build_object('name', n.full_name, 'relationship', n.relationship))
                                FROM loan.loan_nominee ln
                                JOIN mbr.nominee n ON n.tenant_id = ln.tenant_id AND n.id = ln.nominee_id
                               WHERE ln.tenant_id = l.tenant_id AND ln.loan_id = l.id), '[]'::jsonb),
        'schedule', coalesce((SELECT jsonb_agg(jsonb_build_object('instalment_no', i.instalment_no, 'due_date', i.due_date,
                                                                  'principal', i.principal_due, 'interest', i.interest_due,
                                                                  'total', i.principal_due + i.interest_due)
                                               ORDER BY i.instalment_no)
                                FROM loan.loan_instalment i
                                JOIN loan.loan_schedule s ON s.tenant_id = i.tenant_id AND s.id = i.loan_schedule_id AND s.is_current
                               WHERE i.tenant_id = l.tenant_id AND i.loan_id = l.id AND i.status <> 'CANCELLED'), '[]'::jsonb))
      INTO v
      FROM loan.loan l
      JOIN loan.loan_type lt ON lt.tenant_id = l.tenant_id AND lt.id = l.loan_type_id
      JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
      JOIN platform.tenant t ON t.id = l.tenant_id
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id;
    RETURN v;
END
$$;
