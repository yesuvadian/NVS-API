"""Integration tests for tranches, the cash disbursement limit, restructuring,
deceased members' loans and migrated-loan review (scope 6.6, 6.10, 12, 21.6, 39.3)."""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import pytest
from psycopg.types.json import Jsonb

from tests.integration.loan_harness import LoanDb, add_months, run_db

pytestmark = pytest.mark.postgres

D = Decimal


async def _open_principal(db: LoanDb, loan_id) -> Decimal:
    return await db.val(
        """SELECT coalesce(sum(i.principal_due - i.principal_paid), 0) FROM loan.loan_instalment i
             JOIN loan.loan_schedule s ON s.id = i.loan_schedule_id AND s.is_current
            WHERE i.loan_id = %s AND i.status IN ('DUE','PARTLY_PAID')""", (loan_id,))


def test_tranches_need_the_loan_type_and_rule_and_extend_the_schedule():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.approved_loan(t)
        first = await db.prepare(t, loan_id, "6000.00")
        await db.release(t, loan_id, first["disbursement_id"])
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,6000)", (loan_id,), code="TRANCHE_NOT_SUPPORTED")

        await db.conn.execute("UPDATE loan.loan_type SET allows_tranches = true WHERE id=%s",
                              (t.loan_types["INTEREST_BEARING"],))
        await db.set_rule(loan_id, "TRANCHES", {"value": {"allowed": True}})
        on = t.d0 + timedelta(days=10)
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.prepare_disbursement(%s,6000.01)", (loan_id,), code="OVER_DISBURSEMENT")
        await db.fails("SELECT loan.prepare_disbursement(%s,1000,'UPI')", (loan_id,), code="PAYMENT_MODE_DISABLED")
        second = await db.prepare(t, loan_id, "6000.00", on)
        assert second["tranche_no"] == 2
        before = await db.row("SELECT total_interest, instalment_amount FROM loan.loan WHERE id=%s", (loan_id,))
        released = await db.release(t, loan_id, second["disbursement_id"], on)
        assert released["tranche_no"] == 2
        loan = await db.row("SELECT status, disbursed_amount, outstanding_principal, total_interest, instalment_amount "
                            "FROM loan.loan WHERE id=%s", (loan_id,))
        assert loan["status"] == "ACTIVE" and loan["disbursed_amount"] == 12000 and loan["outstanding_principal"] == 12000
        assert loan["total_interest"] > before["total_interest"] and loan["instalment_amount"] > before["instalment_amount"]
        assert await db.val("SELECT reason FROM loan.loan_schedule WHERE loan_id=%s AND is_current", (loan_id,)) == "TRANCHE"
        assert await _open_principal(db, loan_id) == 12000
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.prepare_disbursement(%s,1)", (loan_id,), code="OVER_DISBURSEMENT")
    run_db(scenario)


def test_cash_above_the_limit_needs_approval_before_release():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "cash.disbursement_limit", {"amount": 11000, "approverRole": "LDR"})
        loan_id = await db.approved_loan(t)
        prepared = await db.prepare(t, loan_id, "12000.00")
        assert prepared["cash_limit_approval_required"] is True
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.release_disbursement(%s,%s,'SIGNATURE')", (loan_id, prepared["disbursement_id"]),
                       code="CASH_LIMIT_APPROVAL_REQUIRED")
        await db.fails("SELECT loan.approve_cash_disbursement(%s,'ok')", (prepared["disbursement_id"],),
                       code="APPROVER_ROLE_REQUIRED")
        await db.act(t, "LDR", t.d0)
        approved = await db.val("SELECT loan.approve_cash_disbursement(%s,'Member collects in person')",
                                (prepared["disbursement_id"],))
        assert approved["cash_limit_approved_by"] == str(t.users["LDR"])
        await db.release(t, loan_id, prepared["disbursement_id"])
        assert await db.status(loan_id) == "ACTIVE"

        small = await db.approved_loan(t, "B", "10000.00")
        within = await db.prepare(t, small, "10000.00")
        assert within["cash_limit_approval_required"] is False
        await db.act(t, "LDR", t.d0)
        await db.fails("SELECT loan.approve_cash_disbursement(%s,NULL)", (within["disbursement_id"],),
                       code="CASH_LIMIT_APPROVAL_NOT_NEEDED")
    run_db(scenario)


def test_restructure_extends_the_tenure_after_manager_approval():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        on = add_months(t.d0, 2) + timedelta(days=3)
        await db.repay(t, loan_id, "1000.00", on)
        await db.act(t, "EMP", on)
        details = {"option": "EXTEND_TENURE", "reason": "Crop failure", "new_tenure_months": 18}
        await db.fails("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb({**details, "reason": ""})),
                       code="REASON_REQUIRED")
        await db.fails("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb({**details, "option": "X"})),
                       code="INVALID_RESTRUCTURE_TERMS")
        await db.fails("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb({**details, "new_tenure_months": 5})),
                       code="INVALID_RESTRUCTURE_TERMS")
        await db.fails("SELECT loan.request_restructure(%s,%s)",
                       (loan_id, Jsonb({**details, "option": "MORATORIUM", "moratorium_months": 4})),
                       code="INVALID_RESTRUCTURE_TERMS")
        request = await db.val("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb(details)))
        assert request["status"] == "REQUESTED"
        await db.fails("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb(details)),
                       code="RESTRUCTURE_ALREADY_PENDING")
        await db.fails("SELECT loan.decide_restructure(%s,true,NULL)", (request["id"],), code="SOD_SELF_APPROVAL")
        outstanding = await db.val("SELECT outstanding_principal FROM loan.loan WHERE id=%s", (loan_id,))
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.decide_restructure(gen_random_uuid(),true,NULL)", code="RESTRUCTURE_NOT_FOUND")
        decided = await db.val("SELECT loan.decide_restructure(%s,true,'Approved in meeting')", (request["id"],))
        assert decided["status"] == "APPLIED" and decided["loan_status"] == "RESTRUCTURED"
        loan = await db.row("SELECT restructure_count, outstanding_principal FROM loan.loan WHERE id=%s", (loan_id,))
        assert loan["restructure_count"] == 1 and loan["outstanding_principal"] == outstanding
        assert await _open_principal(db, loan_id) == outstanding
        assert await db.val(
            """SELECT count(*) FROM loan.loan_instalment i JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id
                WHERE s.loan_id=%s AND s.is_current AND s.reason='RESTRUCTURE' AND i.status='DUE'""", (loan_id,)) == 18
        assert await db.val(
            """SELECT count(*) FROM loan.loan_instalment i JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id
                WHERE s.loan_id=%s AND s.is_current AND i.status='PAID'""", (loan_id,)) >= 1
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb({**details, "new_tenure_months": 24})),
                       code="RESTRUCTURE_LIMIT_REACHED")
        listed = await db.val("SELECT loan.list_restructures(%s)", (loan_id,))
        assert len(listed) == 1
    run_db(scenario)


def test_restructure_capitalises_overdue_interest_with_a_moratorium_and_rejection_needs_a_reason():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        on = add_months(t.d0, 2) + timedelta(days=3)
        await db.act(t, "EMP", on)
        request = await db.val("SELECT loan.request_restructure(%s,%s)", (loan_id, Jsonb({
            "option": "COMBINATION", "reason": "Illness", "new_tenure_months": 12, "moratorium_months": 2})))
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.decide_restructure(%s,false,NULL)", (request["id"],), code="APPROVAL_REASON_REQUIRED")
        decided = await db.val("SELECT loan.decide_restructure(%s,true,NULL)", (request["id"],))
        assert decided["capitalised_amount"] > 0
        loan = await db.row("SELECT outstanding_principal FROM loan.loan WHERE id=%s", (loan_id,))
        assert loan["outstanding_principal"] == D("12000.00") + D(str(decided["capitalised_amount"]))
        first_due = await db.val(
            """SELECT min(i.due_date) FROM loan.loan_instalment i JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id
                WHERE s.loan_id=%s AND s.is_current AND i.status='DUE'""", (loan_id,))
        assert first_due == add_months(on, 3)

        other = await db.active_loan(t, "B")
        await db.act(t, "EMP", on)
        rejected_req = await db.val("SELECT loan.request_restructure(%s,%s)", (other, Jsonb({
            "option": "MORATORIUM", "reason": "Flood", "moratorium_months": 1})))
        await db.act(t, "LDR", on)
        rejected = await db.val("SELECT loan.decide_restructure(%s,false,'Can pay')", (rejected_req["id"],))
        assert rejected["status"] == "REJECTED" and await db.status(other) == "ACTIVE"
    run_db(scenario)


async def _verified_death(db: LoanDb, t, member: str, on):
    await db.act(t, None, on)
    await db.conn.execute(
        """INSERT INTO mbr.death_record (tenant_id, member_id, date_of_death, reported_by, status, verified_by, verified_at)
           VALUES (%s,%s,%s,%s,'VERIFIED',%s,now())""",
        (t.id, t.members[member], on - timedelta(days=5), t.users["EMP"], t.users["MGR"]))


def test_deceased_member_loan_stops_interest_and_is_transferred_to_children():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        on = add_months(t.d0, 1) + timedelta(days=12)
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.record_deceased_loan_decision(%s,'TRANSFER',NULL)", (loan_id,), code="DEATH_NOT_VERIFIED")
        await _verified_death(db, t, "A", on)
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.record_deceased_loan_decision(%s,'TRANSFER',NULL)", (loan_id,), code="APPROVER_ROLE_REQUIRED")
        await db.fails("SELECT loan.propose_loan_transfer(%s,%s)",
                       (loan_id, Jsonb([{"successor_member_id": str(t.members["B"]), "share_percent": 100}])),
                       code="TRANSFER_NOT_DECIDED")
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.record_deceased_loan_decision(%s,'FORGET',NULL)", (loan_id,), code="INVALID_DECEASED_DECISION")
        decision = await db.val("SELECT loan.record_deceased_loan_decision(%s,'TRANSFER','Children agree')", (loan_id,))
        assert decision["interest_stops_from"] == str(on - timedelta(days=5))
        await db.fails("SELECT loan.record_deceased_loan_decision(%s,'TRANSFER',NULL)", (loan_id,), code="DECEASED_DECISION_EXISTS")
        assert await db.val(
            """SELECT sum(i.interest_due) FROM loan.loan_instalment i JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id
                WHERE s.loan_id=%s AND s.is_current AND i.due_date > %s""", (loan_id, on)) == 0
        assert await db.val("SELECT reason FROM loan.loan_schedule WHERE loan_id=%s AND is_current", (loan_id,)) == "DECEASED"

        await db.act(t, "EMP", on)
        share = lambda m, p: {"successor_member_id": str(t.members[m]), "share_percent": p}  # noqa: E731
        await db.fails("SELECT loan.propose_loan_transfer(%s,%s)", (loan_id, Jsonb([share("B", 50)])),
                       code="INVALID_TRANSFER_SHARES")
        await db.fails("SELECT loan.propose_loan_transfer(%s,%s)", (loan_id, Jsonb([share("B", 50), share("APPLIED", 50)])),
                       code="SUCCESSOR_NOT_MEMBER")
        proposed = await db.val("SELECT loan.propose_loan_transfer(%s,%s)", (loan_id, Jsonb([share("B", 60), share("C", 40)])))
        assert [p["status"] for p in proposed] == ["PROPOSED", "PROPOSED"]
        await db.fails("SELECT loan.propose_loan_transfer(%s,%s)", (loan_id, Jsonb([share("B", 100)])),
                       code="TRANSFER_ALREADY_PROPOSED")
        await db.fails("SELECT loan.decide_loan_transfer(%s,true,NULL)", (loan_id,), code="SOD_SELF_APPROVAL")
        outstanding = await db.val("SELECT outstanding_principal FROM loan.loan WHERE id=%s", (loan_id,))
        await db.act(t, "MGR", on)
        done = await db.val("SELECT loan.decide_loan_transfer(%s,true,'Legal heirs verified')", (loan_id,))
        assert {d["status"] for d in done} == {"COMPLETED"}
        assert sum(D(str(d["transferred_principal"])) for d in done) == outstanding
        assert await db.status(loan_id) == "TRANSFERRED"
        successors = await db.rows("SELECT member_id, status, outstanding_principal FROM loan.loan WHERE parent_loan_id=%s",
                                   (loan_id,))
        assert {s["status"] for s in successors} == {"ACTIVE"} and len(successors) == 2
        for s in successors:
            assert await db.val("SELECT sum(principal_due) FROM loan.loan_instalment WHERE loan_id=(SELECT id FROM loan.loan "
                                "WHERE parent_loan_id=%s AND member_id=%s)", (loan_id, s["member_id"])) == s["outstanding_principal"]
        await db.fails("SELECT loan.decide_loan_transfer(%s,true,NULL)", (loan_id,), code="TRANSFER_NOT_FOUND")
    run_db(scenario)


def test_deceased_member_loan_recovered_from_guarantor():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.act(t, "EMP", t.d0)
        await db.val("SELECT loan.add_guarantor(%s,%s)", (loan["id"], Jsonb({
            "guarantor_member_id": str(t.members["B"]), "consent_type": "SIGNATURE"})))
        await db.submit(t, loan["id"])
        await db.approve(t, loan["id"])
        prepared = await db.prepare(t, loan["id"], "12000.00")
        await db.release(t, loan["id"], prepared["disbursement_id"])
        on = add_months(t.d0, 1) + timedelta(days=12)
        await _verified_death(db, t, "A", on)
        await db.act(t, "LDR", on)
        await db.val("SELECT loan.record_deceased_loan_decision(%s,'RECOVER_FROM_GUARANTOR',NULL)", (loan["id"],))
        assert await db.val("SELECT status FROM loan.loan_guarantor WHERE loan_id=%s", (loan["id"],)) == "INVOKED"
    run_db(scenario)


def test_migrated_loan_overdue_before_go_live_is_reviewed_then_defaulted_on_decision():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.conn.execute("UPDATE loan.loan SET is_migrated = true, legacy_ref = 'OLD-1' WHERE id=%s", (loan_id,))
        await db.set_setting(t, "migration.go_live_date", str(add_months(t.d0, 4)))
        on = add_months(t.d0, 3) + timedelta(days=1)
        await db.daily(t, on)
        assert await db.status(loan_id) != "DEFAULTED"
        await db.act(t, "MGR", on)
        reviews = await db.val("SELECT loan.list_migration_reviews('OPEN')")
        assert len(reviews) == 1 and reviews[0]["loan_id"] == str(loan_id)
        await db.fails("SELECT loan.decide_migration_review(%s,true,'')", (reviews[0]["id"],), code="REASON_REQUIRED")
        await db.fails("SELECT loan.decide_migration_review(gen_random_uuid(),true,'x')", code="MIGRATION_REVIEW_NOT_FOUND")
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.decide_migration_review(%s,true,'x')", (reviews[0]["id"],), code="APPROVER_ROLE_REQUIRED")
        await db.act(t, "MGR", on)
        decided = await db.val("SELECT loan.decide_migration_review(%s,true,'Old arrears confirmed')", (reviews[0]["id"],))
        assert decided["status"] == "DEFAULT_APPLIED"
        await db.fails("SELECT loan.decide_migration_review(%s,false,'x')", (reviews[0]["id"],), code="REQUEST_CLOSED")
        await db.daily(t, on + timedelta(days=1))
        assert await db.status(loan_id) == "DEFAULTED"
    run_db(scenario)
