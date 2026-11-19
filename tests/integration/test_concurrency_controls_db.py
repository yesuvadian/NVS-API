"""Integration tests for the double-save and concurrent-save controls
(db/17_concurrency_controls.sql and the fixes in scripts 30-38).

Each scenario runs in one rolled-back transaction (see loan_harness). The race
conditions themselves, with two real sessions, are in test_concurrency_races_db.py.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

import psycopg
import pytest
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from app.core.errors import localisation
from app.core.idempotency import run_idempotent
from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, owner_dsn, run_db
from tests.integration.test_loan_module_db import Api, _Pool

pytestmark = pytest.mark.postgres

D = Decimal


async def _receipts(db: LoanDb, loan_id) -> list[dict]:
    return await db.rows(
        "SELECT id, receipt_no, amount, idempotency_key, journal_id FROM acct.cash_receipt "
        "WHERE source_entity_id=%s AND purpose='LOAN_REPAYMENT' ORDER BY created_at", (loan_id,))


# =============================================================================
# #1  Idempotent money postings
# =============================================================================
def test_idempotency_begin_finish_replay_and_reuse():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        assert await db.val("SELECT core.idempotency_begin('key-00000001','op.a','h1')") is None
        assert await db.val("SELECT core.current_idempotency_key()") == "key-00000001"
        # Not finished yet: a second begin in the same transaction sees it in progress.
        await db.fails("SELECT core.idempotency_begin('key-00000001','op.a','h1')",
                       code="IDEMPOTENCY_REQUEST_IN_PROGRESS")
        await db.val("SELECT core.idempotency_finish('key-00000001', %s)", (Jsonb({"receipt_no": "R1"}),))
        assert await db.val("SELECT core.current_idempotency_key()") is None
        replay = await db.val("SELECT core.idempotency_begin('key-00000001','op.a','h1')")
        assert replay == {"response": {"receipt_no": "R1"}}
        await db.fails("SELECT core.idempotency_begin('key-00000001','op.a','other')", code="IDEMPOTENCY_KEY_REUSED")
        await db.fails("SELECT core.idempotency_begin('key-00000001','op.b','h1')", code="IDEMPOTENCY_KEY_REUSED")
        await db.fails("SELECT core.idempotency_begin('short','op.a','h1')", code="IDEMPOTENCY_KEY_INVALID")
        await db.fails("SELECT core.idempotency_begin('has space 123','op.a','h1')", code="IDEMPOTENCY_KEY_INVALID")
        await db.fails("SELECT core.idempotency_finish('never-started-1', '{}'::jsonb)", code="IDEMPOTENCY_KEY_INVALID")

        # Keys are per organisation: another tenant may use the same value.
        other = await db.new_tenant()
        await db.act(other, "EMP", other.d0)
        assert await db.val("SELECT core.idempotency_begin('key-00000001','op.a','h1')") is None
        await db.act(t, "EMP", t.d0)
        assert await db.val("SELECT count(*) FROM core.idempotency_request") == 1   # RLS: own rows only

        # Housekeeping removes only old completed keys.
        assert await db.val("SELECT core.purge_idempotency_requests(interval '1 day')") == 0
        await db.conn.execute("UPDATE core.idempotency_request SET created_at = now() - interval '40 days'")
        assert await db.val("SELECT core.purge_idempotency_requests()") == 1
    run_db(scenario)


def test_repayment_with_same_key_posts_once_and_receipt_carries_the_key():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        on = t.d0 + timedelta(days=31)
        await db.act(t, "EMP", on)
        service = LoanService(db.conn)
        calls = 0

        async def pay():
            nonlocal calls
            calls += 1
            return await service.collect_repayment(loan_id, amount=D("1000.00"), payment_mode="CASH",
                                                   payment_reference=None)

        body = {"loan_id": loan_id, "amount": D("1000.00"), "payment_mode": "CASH", "payment_reference": None}
        first = await run_idempotent(db.conn, key="pay-key-00001", operation="loan.collect_repayment",
                                     payload=body, action=pay)
        second = await run_idempotent(db.conn, key="pay-key-00001", operation="loan.collect_repayment",
                                      payload=body, action=pay)
        assert calls == 1 and second == first
        receipts = await _receipts(db, loan_id)
        assert len(receipts) == 1 and receipts[0]["idempotency_key"] == "pay-key-00001"
        assert await db.val("SELECT idempotency_key FROM acct.journal WHERE id=%s",
                            (receipts[0]["journal_id"],)) == "pay-key-00001"
        assert await db.val("SELECT outstanding_principal FROM loan.loan WHERE id=%s", (loan_id,)) < D("12000")

        # A different amount with the same key is refused, not posted.
        await db.app_fails("IDEMPOTENCY_KEY_REUSED", lambda: run_idempotent(
            db.conn, key="pay-key-00001", operation="loan.collect_repayment",
            payload={**body, "amount": D("2000.00")}, action=pay))
        # A new key is a new payment.
        await run_idempotent(db.conn, key="pay-key-00002", operation="loan.collect_repayment",
                             payload=body, action=pay)
        assert len(await _receipts(db, loan_id)) == 2
        # Postings without a key (direct database callers) leave the column empty.
        await db.repay(t, loan_id, "100.00", on)
        assert (await _receipts(db, loan_id))[-1]["idempotency_key"] is None
    run_db(scenario)


def test_disbursement_voucher_carries_the_key():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.approved_loan(t)
        await db.act(t, "EMP", t.d0)
        result = await run_idempotent(
            db.conn, key="disb-key-0001", operation="loan.prepare_disbursement",
            payload={"loan_id": loan_id, "gross_amount": D("12000.00")},
            action=lambda: LoanService(db.conn).prepare_disbursement(loan_id, D("12000.00")))
        assert await db.val("SELECT idempotency_key FROM acct.payment_voucher WHERE id=%s",
                            (result["voucher_id"],)) == "disb-key-0001"
    run_db(scenario)


def test_http_double_submitted_repayment_returns_the_first_receipt():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await localisation.load(_Pool(db.conn))
        api = Api(db, t)
        loan_id = await db.active_loan(t)
        on = t.d0 + timedelta(days=31)
        body = {"amount": "1000.00", "payment_mode": "CASH"}
        missing = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on, json=body)
        assert missing.status_code == 428 and missing.json()["detail"]["shortCode"] == "IDEMPOTENCY_KEY_REQUIRED"
        assert missing.json()["detail"]["code"] == "CFMS-SYS-1006"
        bad = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on, json=body,
                             headers={"Idempotency-Key": "bad key"})
        assert bad.status_code == 400 and bad.json()["detail"]["shortCode"] == "IDEMPOTENCY_KEY_INVALID"

        key = {"Idempotency-Key": str(uuid4())}
        first = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on, json=body, headers=key)
        again = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on, json=body, headers=key)
        assert first.status_code == 201 and again.status_code == 201
        assert again.json() == first.json()
        assert "idempotent-replayed" not in first.headers
        assert again.headers["Idempotent-Replayed"] == "true"
        assert len(await _receipts(db, loan_id)) == 1

        reused = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on,
                                json={**body, "amount": "500.00"}, headers=key)
        assert reused.status_code == 409 and reused.json()["detail"]["shortCode"] == "IDEMPOTENCY_KEY_REUSED"
        assert len(await _receipts(db, loan_id)) == 1

        # A failed request does not use up its key: fix the input and retry with it.
        retry_key = {"Idempotency-Key": "retry-key-0001"}
        too_much = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on,
                                  json={**body, "amount": "999999.00"}, headers=retry_key)
        assert too_much.status_code == 422
        fixed = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", on=on, json=body,
                               headers={"Idempotency-Key": "retry-key-0001"})
        assert fixed.status_code == 201 and "idempotent-replayed" not in fixed.headers
        assert len(await _receipts(db, loan_id)) == 2
    run_db(scenario)


def test_http_loan_application_create_with_key_is_replayed_and_update_needs_version():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await localisation.load(_Pool(db.conn))
        api = Api(db, t)
        body = {"member_id": str(t.members["C"]), "loan_type_id": str(t.loan_types["INTEREST_BEARING"]),
                "requested_amount": "12000.00", "requested_tenure_months": 12, "purpose": "Home repairs",
                "nominee_ids": [str(t.nominees["C"])]}
        key = {"Idempotency-Key": "loan-create-01"}
        first = await api.call("EMP", "POST", "/loans", json=body, headers=key)
        again = await api.call("EMP", "POST", "/loans", json=body, headers=key)
        assert first.status_code == 201 and again.json()["id"] == first.json()["id"]
        assert again.headers["Idempotent-Replayed"] == "true"
        # A new click (new key) for the same member and type hits the open-application rule.
        dup = await api.call("EMP", "POST", "/loans", json=body, headers={"Idempotency-Key": "loan-create-02"})
        assert dup.status_code == 409 and dup.json()["detail"]["shortCode"] == "LOAN_APPLICATION_ALREADY_OPEN"

        loan_id = first.json()["id"]
        no_version = await api.call("EMP", "PATCH", f"/loan-applications/{loan_id}", json={"purpose": "Roof work"})
        assert no_version.status_code == 428 and no_version.json()["detail"]["shortCode"] == "ROW_VERSION_REQUIRED"
        version = first.json()["row_version"]
        ok = await api.call("EMP", "PATCH", f"/loan-applications/{loan_id}",
                            json={"purpose": "Roof work", "expected_version": version})
        assert ok.status_code == 200 and ok.json()["row_version"] == version + 1
        stale = await api.call("EMP", "PATCH", f"/loan-applications/{loan_id}", json={"purpose": "Walls"},
                               headers={"X-Expected-Row-Version": str(version)})
        assert stale.status_code == 409 and stale.json()["detail"]["shortCode"] == "STALE_RECORD"
    run_db(scenario)


# =============================================================================
# #2  Member edit needs the row version; #3 duplicate members
# =============================================================================
def test_member_update_bumps_row_version_and_rejects_a_stale_save():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        member = t.members["A"]
        version = await db.val("SELECT row_version FROM mbr.member WHERE id=%s", (member,))
        first = await db.val("SELECT mbr.update_member(%s,%s,%s)", (member, Jsonb({"city": "Madurai"}), version))
        assert first["row_version"] == version + 1
        # The second clerk opened the same version: the save is refused, nothing changes.
        stale = await db.val("SELECT mbr.update_member(%s,%s,%s)", (member, Jsonb({"city": "Salem"}), version))
        assert stale is None
        assert await db.val("SELECT city FROM mbr.member WHERE id=%s", (member,)) == "Madurai"
    run_db(scenario)


def test_duplicate_member_is_refused_unless_confirmed_with_a_reason():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        existing_mobile = await db.val("SELECT mobile FROM mbr.member WHERE id=%s", (t.members["A"],))
        new = {"full_name": "Lakshmi R", "mobile": "9876543210", "date_of_birth": "1985-04-01"}
        created = await db.val("SELECT mbr.create_member(%s)", (Jsonb(new),))
        assert created["member_no"]

        err = await db.fails("SELECT mbr.create_member(%s)", (Jsonb(new),), code="DUPLICATE_MEMBER")
        assert created["member_no"] in err.diag.message_primary
        # Same mobile written differently (country code, spaces) is still the same number.
        await db.fails("SELECT mbr.create_member(%s)", (Jsonb({"full_name": "Other", "mobile": "+91 98765 43210"}),),
                       code="DUPLICATE_MEMBER")
        # Same name (any case) and date of birth with a different mobile.
        await db.fails("SELECT mbr.create_member(%s)",
                       (Jsonb({"full_name": " lakshmi r ", "mobile": "9000099999", "date_of_birth": "1985-04-01"}),),
                       code="DUPLICATE_MEMBER")
        await db.fails("SELECT mbr.create_member(%s)", (Jsonb({"full_name": "Someone", "mobile": existing_mobile}),),
                       code="DUPLICATE_MEMBER")
        # Same name without a date of birth, or a different date of birth, is not a duplicate.
        await db.val("SELECT mbr.create_member(%s)", (Jsonb({"full_name": "Lakshmi R", "mobile": "9000011111"}),))
        await db.val("SELECT mbr.create_member(%s)",
                     (Jsonb({"full_name": "Lakshmi R", "mobile": "9000022222", "date_of_birth": "1990-01-01"}),))
        # Confirmed with a reason (for example a shared family mobile).
        twin = await db.val("SELECT mbr.create_member(%s)", (Jsonb({
            "full_name": "Kumar R", "mobile": "9876543210", "duplicate_override_reason": "Husband shares the mobile"}),))
        assert twin["mobile"] == "9876543210"
        # An exited member's details may be reused.
        await db.conn.execute("UPDATE mbr.member SET status='EXITED' WHERE id=%s", (t.members["B"],))
        mobile_b = await db.val("SELECT mobile FROM mbr.member WHERE id=%s", (t.members["B"],))
        await db.val("SELECT mbr.create_member(%s)", (Jsonb({"full_name": "New B", "mobile": mobile_b}),))

        # Changing a member's mobile to another member's number is checked too.
        version = await db.val("SELECT row_version FROM mbr.member WHERE id=%s", (t.members["C"],))
        await db.fails("SELECT mbr.update_member(%s,%s,%s)", (t.members["C"], Jsonb({"mobile": existing_mobile}), version),
                       code="DUPLICATE_MEMBER")
        same = await db.val("SELECT mbr.update_member(%s,%s,%s)", (t.members["C"], Jsonb({"city": "Trichy"}), version))
        assert same["city"] == "Trichy"           # other fields: no duplicate check against itself
        changed = await db.val("SELECT mbr.update_member(%s,%s,%s)", (t.members["C"], Jsonb(
            {"mobile": existing_mobile, "duplicate_override_reason": "Joint family phone"}), version + 1))
        assert changed["mobile"] == existing_mobile
    run_db(scenario)


# =============================================================================
# #3  One open application per member and loan type; #4 concurrent loan limit
# =============================================================================
def test_second_open_application_for_same_member_and_type_is_refused():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        first = await db.create_loan(t, "A")
        await db.app_fails("LOAN_APPLICATION_ALREADY_OPEN", lambda: db.create_loan(t, "A"))
        await db.submit(t, first["id"])
        await db.app_fails("LOAN_APPLICATION_ALREADY_OPEN", lambda: db.create_loan(t, "A"))   # under approval
        other_type = await db.create_loan(t, "A", loan_type="INTEREST_FREE", amount="10000.00", tenure=10)
        assert other_type["status"] == "DRAFT"
        await db.create_loan(t, "B")                                                         # other member
        await db.act(t, "EMP", t.d0)
        await db.val("SELECT loan.withdraw_application(%s,'Applied twice')", (first["id"],))
        assert (await db.create_loan(t, "A"))["status"] == "DRAFT"
    run_db(scenario)


def test_max_concurrent_loans_enforced_at_approval_and_disbursement():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        assert await db.val("SELECT max_concurrent_loans FROM loan.get_loan_settings()") == 1
        first = await db.approved_loan(t, "A")
        # The first loan is approved but not disbursed: a second application can
        # still be made and submitted (eligibility counts running loans) ...
        second = await db.create_loan(t, "A", loan_type="INTEREST_FREE", amount="10000.00", tenure=10)
        await db.submit(t, second["id"])
        # ... but it cannot be approved while the first approval stands.
        await db.act(t, "MGR", t.d0)
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (second["id"],))
        err = await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED',NULL,NULL,NULL)", (request,),
                             code="MAX_CONCURRENT_LOANS_REACHED")
        assert "limit is 1" in err.diag.message_primary
        # Rejecting or returning is still possible.
        await db.val("SELECT loan.record_approval_decision(%s,'RETURNED','Wait for the first loan',NULL,NULL)", (request,))

        # Two approvals that slipped through under a higher limit: only one can be paid out.
        await db.set_setting(t, "loans.max_concurrent_loans", 2)
        await db.submit(t, second["id"])
        await db.approve(t, second["id"])
        await db.set_setting(t, "loans.max_concurrent_loans", 1)
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,%s)", (first, D("12000.00")),
                       code="MAX_CONCURRENT_LOANS_REACHED")      # the other approved loan counts
        await db.conn.execute("UPDATE loan.loan SET status='CANCELLED' WHERE id=%s", (second["id"],))
        prepared = await db.prepare(t, first, "12000.00")
        assert prepared["status"] == "PREPARED"
    run_db(scenario)


# =============================================================================
# #7  One pending request per item; #8 daily job runs once at a time
# =============================================================================
def test_pending_request_and_late_fee_unique_indexes():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.act(t, "EMP", t.d0)
        member = t.members["A"]
        sql = "INSERT INTO loan.cooling_off_override (member_id, reason) VALUES (%s,'Medical')"
        await db.conn.execute(sql, (member,))
        await db.fails(sql, (member,), constraint="cooling_off_override_pending_uq")
        await db.conn.execute("UPDATE loan.cooling_off_override SET status='REJECTED' WHERE member_id=%s", (member,))
        await db.conn.execute(sql, (member,))                     # a new request after the decision

        sql = ("INSERT INTO loan.loan_waiver (loan_id, component, amount, reason) "
               "VALUES (%s,'SETTLEMENT_CHARGE',10,'Goodwill')")
        await db.conn.execute(sql, (loan_id,))
        await db.fails(sql, (loan_id,), constraint="loan_waiver_pending_uq")

        instalment = await db.val("SELECT id FROM loan.loan_instalment WHERE loan_id=%s ORDER BY instalment_no LIMIT 1",
                                  (loan_id,))
        sql = ("INSERT INTO loan.loan_charge (loan_id, loan_instalment_id, charge_type, assessed_on, amount) "
               "VALUES (%s,%s,'LATE_FEE',%s,100)")
        await db.conn.execute(sql, (loan_id, instalment, t.d0))
        await db.fails(sql, (loan_id, instalment, t.d0), constraint="loan_charge_late_fee_once_uq")
        await db.conn.execute(sql, (loan_id, instalment, t.d0 + timedelta(days=31)))   # monthly fee: next month
    run_db(scenario)


def test_request_cooling_off_override_twice_is_refused():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.conn.execute("UPDATE mbr.member SET loan_eligibility='RESTRICTED' WHERE id=%s", (t.members["A"],))
        await db.act(t, "MGR", t.d0)
        await db.val("SELECT loan.request_cooling_off_override(%s,'Hospital bills')", (t.members["A"],))
        await db.fails("SELECT loan.request_cooling_off_override(%s,'Again')", (t.members["A"],),
                       code="OVERRIDE_ALREADY_PENDING")
    run_db(scenario)


def test_daily_job_refuses_to_run_twice_at_the_same_time():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.active_loan(t)
        other = await psycopg.AsyncConnection.connect(owner_dsn(), autocommit=True, row_factory=dict_row)
        try:
            await other.execute("SELECT pg_advisory_lock(hashtextextended('loan.run_daily_status:' || %s::text, 0))",
                                (str(t.id),))
            await db.act(t, None, t.d0 + timedelta(days=1))
            await db.fails("SELECT loan.run_daily_status()", code="JOB_ALREADY_RUNNING")
            await other.execute("SELECT pg_advisory_unlock_all()")
        finally:
            await other.close()
        result = await db.daily(t, t.d0 + timedelta(days=1))
        assert result["loans_checked"] == 1
    run_db(scenario)
