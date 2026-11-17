"""Integration tests for receipt reversal, application changes and offline approvals.

Same harness and amounts as test_loan_module_db.py: 12,000 over 12 months at
12 % flat = 1,000 + 120 a month.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import pytest
from psycopg.types.json import Jsonb

from tests.integration.loan_harness import LoanDb, add_months, run_db

pytestmark = pytest.mark.postgres

D = Decimal


async def _reverse(db: LoanDb, t, repayment_id, on, reason="Wrong loan"):
    await db.act(t, "EMP", on)
    return await db.val("SELECT loan.request_repayment_reversal(%s,%s)", (repayment_id, reason))


async def _decide(db: LoanDb, t, role, reversal_id, on, approve=True, remarks=None):
    await db.act(t, role, on)
    return await db.val("SELECT loan.decide_repayment_reversal(%s,%s,%s)", (reversal_id, approve, remarks))


# =============================================================================
# P1-5 Receipt reversal
# =============================================================================
def test_same_day_reversal_needs_manager_and_restores_the_loan():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        paid = await db.repay(t, loan_id, "1120.00", due1)
        request = await _reverse(db, t, paid["repayment_id"], due1)
        assert request["status"] == "PENDING" and request["required_roles"] == ["MGR"] and request["after_day_close"] is False
        await db.fails("SELECT loan.request_repayment_reversal(%s,'Again')", (paid["repayment_id"],), code="REVERSAL_ALREADY_PENDING")
        await db.fails("SELECT loan.decide_repayment_reversal(%s,true,NULL)", (request["id"],), code="SOD_SELF_APPROVAL")
        await db.act(t, "EMP2", due1)
        await db.fails("SELECT loan.decide_repayment_reversal(%s,true,NULL)", (request["id"],), code="APPROVER_ROLE_REQUIRED")
        done = await _decide(db, t, "MGR", request["id"], due1)
        assert done["status"] == "APPROVED" and done["repayment_status"] == "REVERSED"

        loan = await db.row("SELECT status, outstanding_principal FROM loan.loan WHERE id=%s", (loan_id,))
        assert (loan["status"], loan["outstanding_principal"]) == ("ACTIVE", D("12000.00"))
        inst = await db.row("SELECT status, principal_paid, interest_paid, paid_on FROM loan.loan_instalment i "
                            "JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id AND s.is_current "
                            "WHERE i.loan_id=%s AND i.instalment_no=1", (loan_id,))
        assert (inst["status"], inst["principal_paid"], inst["interest_paid"], inst["paid_on"]) == ("DUE", 0, 0, None)
        receipt = await db.row("SELECT status, cancel_reason, cancelled_by, journal_id, reversal_journal_id FROM acct.cash_receipt "
                               "WHERE id=%s", (paid["cash_receipt_id"],))
        assert receipt["status"] == "CANCELLED" and receipt["cancel_reason"] == "Wrong loan"
        assert receipt["cancelled_by"] == t.users["MGR"]
        original = await db.row("SELECT status, reversed_by_journal_id FROM acct.journal WHERE id=%s", (receipt["journal_id"],))
        assert original["status"] == "REVERSED" and original["reversed_by_journal_id"] == receipt["reversal_journal_id"]
        lines = await db.rows("""SELECT o.account_id, o.debit AS od, o.credit AS oc, r.debit AS rd, r.credit AS rc
                                   FROM acct.journal_line o JOIN acct.journal_line r ON r.journal_id=%s AND r.line_no=o.line_no
                                  WHERE o.journal_id=%s""", (receipt["reversal_journal_id"], receipt["journal_id"]))
        assert lines and all(x["od"] == x["rc"] and x["oc"] == x["rd"] for x in lines)
        assert await db.val("SELECT voucher_type FROM acct.journal WHERE id=%s", (receipt["reversal_journal_id"],)) == "REVERSAL"
        assert any("has been cancelled" in m["body"] for m in await db.messages(loan_id))
        # the instalment can be paid again
        again = await db.repay(t, loan_id, "1120.00", due1)
        assert again["repayment_type"] == "REGULAR"
    run_db(scenario)


def test_reversal_after_day_end_needs_manager_and_accountant():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        paid = await db.repay(t, loan_id, "1120.00", due1)
        later = due1 + timedelta(days=1)
        request = await _reverse(db, t, paid["repayment_id"], later)
        assert request["after_day_close"] is True and request["required_roles"] == ["MGR", "ACC"]
        first = await _decide(db, t, "MGR", request["id"], later, remarks="Checked")
        assert first["status"] == "PENDING" and len(first["approvals"]) == 1
        await db.fails("SELECT loan.decide_repayment_reversal(%s,true,NULL)", (request["id"],), code="APPROVER_ROLE_REQUIRED")
        done = await _decide(db, t, "ACC", request["id"], later)
        assert done["status"] == "APPROVED"
        assert await db.val("SELECT status FROM loan.loan_repayment WHERE id=%s", (paid["repayment_id"],)) == "REVERSED"
    run_db(scenario)


def test_only_latest_receipt_and_rejection():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        first = await db.repay(t, loan_id, "500.00", due1)
        second = await db.repay(t, loan_id, "620.00", due1)
        await db.act(t, "EMP", due1)
        await db.fails("SELECT loan.request_repayment_reversal(%s,'x')", (first["repayment_id"],), code="REVERSAL_NOT_LATEST")
        await db.fails("SELECT loan.request_repayment_reversal(%s,'')", (second["repayment_id"],), code="REASON_REQUIRED")
        request = await _reverse(db, t, second["repayment_id"], due1)
        await db.act(t, "MGR", due1)
        await db.fails("SELECT loan.decide_repayment_reversal(%s,false,NULL)", (request["id"],), code="APPROVAL_REASON_REQUIRED")
        rejected = await _decide(db, t, "MGR", request["id"], due1, approve=False, remarks="Receipt is correct")
        assert rejected["status"] == "REJECTED" and rejected["repayment_status"] == "POSTED"
        assert await db.val("SELECT status FROM acct.cash_receipt WHERE id=%s", (second["cash_receipt_id"],)) == "ACTIVE"
    run_db(scenario)


def test_reversal_of_overpayment_restores_previous_schedule():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        paid = await db.repay(t, loan_id, "2220.00", due1)
        assert paid["new_schedule_id"]
        request = await _reverse(db, t, paid["repayment_id"], due1)
        await _decide(db, t, "MGR", request["id"], due1)
        schedules = await db.rows("SELECT schedule_version, is_current FROM loan.loan_schedule WHERE loan_id=%s ORDER BY 1", (loan_id,))
        assert [(s["schedule_version"], s["is_current"]) for s in schedules] == [(1, True), (2, False)]
        loan = await db.row("SELECT outstanding_principal, instalment_amount, maturity_date FROM loan.loan WHERE id=%s", (loan_id,))
        assert loan["outstanding_principal"] == D("12000.00") and loan["instalment_amount"] == D("1120.00")
        assert loan["maturity_date"] == add_months(t.d0, 12)
        open_rows = await db.val("""SELECT count(*) FROM loan.loan_instalment i JOIN loan.loan_schedule s
                                      ON s.id=i.loan_schedule_id AND s.is_current WHERE i.loan_id=%s AND i.status='DUE'""", (loan_id,))
        assert open_rows == 12
    run_db(scenario)


def test_reversal_reopens_late_fee():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        on = due1 + timedelta(days=1)
        await db.set_rule(loan_id, "LATE_FEE", {"value": {"enabled": True, "graceDays": 0, "type": "fixed", "amount": 50}})
        await db.daily(t, on)
        assert await db.status(loan_id) == "OVERDUE"
        paid = await db.repay(t, loan_id, "1170.00", on)
        assert paid["loan_status"] == "ACTIVE" and paid["late_fee_amount"] == D("50.00")
        request = await _reverse(db, t, paid["repayment_id"], on)
        await _decide(db, t, "MGR", request["id"], on)
        assert await db.status(loan_id) == "OVERDUE"
        charge = await db.row("SELECT status, paid_amount FROM loan.loan_charge WHERE loan_id=%s AND charge_type='LATE_FEE'", (loan_id,))
        assert (charge["status"], charge["paid_amount"]) == ("OPEN", 0)
        assert await db.val("SELECT late_fee_paid FROM loan.loan_instalment WHERE id=(SELECT loan_instalment_id FROM loan.loan_charge "
                            "WHERE loan_id=%s AND charge_type='LATE_FEE')", (loan_id,)) == 0
    run_db(scenario)


def test_settlement_receipts_are_not_reversed_here():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.act(t, "EMP", t.d0 + timedelta(days=5))
        quote = await db.val("SELECT loan.quote_early_settlement(%s)", (loan_id,))
        if quote["approval_required"]:
            await db.act(t, "MGR", t.d0 + timedelta(days=5))
            await db.val("SELECT loan.approve_early_settlement(%s,'ok')", (quote["id"],))
            await db.act(t, "EMP", t.d0 + timedelta(days=5))
        await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        rep = await db.val("SELECT id FROM loan.loan_repayment WHERE loan_id=%s", (loan_id,))
        await db.fails("SELECT loan.request_repayment_reversal(%s,'x')", (rep,), code="REVERSAL_NOT_ALLOWED")
    run_db(scenario)


# =============================================================================
# P1-6 Application changes
# =============================================================================
def test_edit_draft_and_returned_application():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.update_application(%s,%s,%s)",
                       (loan["id"], Jsonb({"requested_amount": "10000"}), loan["row_version"] + 5), code="STALE_RECORD")
        changed = await db.val("SELECT loan.update_application(%s,%s,%s)",
                               (loan["id"], Jsonb({"requested_amount": "10000", "requested_tenure_months": 10,
                                                   "purpose": "School fees"}), loan["row_version"]))
        assert (changed["requested_amount"], changed["requested_tenure_months"], changed["purpose"]) == (10000, 10, "School fees")
        await db.submit(t, loan["id"])
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.update_application(%s,%s)", (loan["id"], Jsonb({"purpose": "x"})), code="APPLICATION_NOT_EDITABLE")
        await db.act(t, "MGR", t.d0)
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        await db.val("SELECT loan.record_approval_decision(%s,'RETURNED','Reduce the amount')", (request,))
        await db.act(t, "EMP", t.d0)
        changed = await db.val("SELECT loan.update_application(%s,%s)", (loan["id"], Jsonb({"requested_amount": "8000"})))
        assert changed["status"] == "RETURNED" and changed["requested_amount"] == 8000
        await db.submit(t, loan["id"])
        assert await db.status(loan["id"]) == "UNDER_APPROVAL"
    run_db(scenario)


def test_update_application_through_the_service_rechecks_limits():
    async def scenario(db: LoanDb):
        from app.core.errors import AppError
        from app.services.loans import LoanService

        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        await db.app_fails("LOAN_TERMS_OUT_OF_RANGE",
                           lambda: service.update_application(loan["id"], {"requested_amount": D("100")}))
        changed = await service.update_application(loan["id"], {"requested_amount": D("9000.00"),
                                                                "nominee_ids": [t.nominees["A"]]}, loan["row_version"])
        assert changed["requested_amount"] == 9000 and changed["row_version"] == loan["row_version"] + 1
        await db.submit(t, loan["id"])
        await db.act(t, "EMP", t.d0)
        await db.app_fails("APPLICATION_NOT_EDITABLE", lambda: service.update_application(loan["id"], {"purpose": "Other"}))
        assert AppError
    run_db(scenario)


def test_withdraw_application_closes_the_approval():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        request = await db.submit(t, loan["id"])
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.withdraw_application(%s,'')", (loan["id"],), code="REASON_REQUIRED")
        result = await db.val("SELECT loan.withdraw_application(%s,'Member changed mind')", (loan["id"],))
        assert result["status"] == "WITHDRAWN" and result["previous_status"] == "UNDER_APPROVAL" and result["fee_paid"] is False
        request_id = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        assert await db.val("SELECT status FROM wf.approval_request WHERE id=%s", (request_id,)) == "WITHDRAWN"
        assert await db.val("SELECT status FROM wf.task WHERE approval_request_id=%s", (request_id,)) == "CANCELLED"
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED')", (request_id,), code="REQUEST_CLOSED")
        approved = await db.approved_loan(t, "B")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.withdraw_application(%s,'x')", (approved,), code="APPLICATION_NOT_WITHDRAWABLE")
        assert request is not None
    run_db(scenario)


def test_cancel_approved_loan_with_manager_approval():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.approved_loan(t)
        prepared = await db.prepare(t, loan_id, "12000.00")
        await db.act(t, "EMP", t.d0)
        request = await db.val("SELECT loan.request_loan_cancellation(%s,'Member no longer needs it')", (loan_id,))
        assert request["status"] == "PENDING"
        await db.fails("SELECT loan.request_loan_cancellation(%s,'Again')", (loan_id,), code="CANCELLATION_ALREADY_PENDING")
        await db.fails("SELECT loan.decide_loan_cancellation(%s,true)", (request["id"],), code="SOD_SELF_APPROVAL")
        await db.act(t, "MGR", t.d0)
        done = await db.val("SELECT loan.decide_loan_cancellation(%s,true,'OK')", (request["id"],))
        assert done["status"] == "APPROVED" and done["loan_status"] == "CANCELLED"
        assert await db.val("SELECT status FROM loan.loan_disbursement WHERE id=%s", (prepared["disbursement_id"],)) == "CANCELLED"
        active = await db.active_loan(t, "B")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.request_loan_cancellation(%s,'x')", (active,), code="LOAN_NOT_CANCELLABLE")
    run_db(scenario)


# =============================================================================
# P1-6 Offline approval (scope 28.1)
# =============================================================================
def test_offline_approval_records_three_identities():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.submit(t, loan["id"])
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        good = {"decision": "APPROVED", "approved_by": str(t.users["MGR"]), "evidence_type": "MEETING",
                "decision_date": str(t.d0), "approved_amount": "10000", "remarks": "Committee meeting"}
        await db.act(t, "EMP2", t.d0)
        await db.fails("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb({**good, "approved_by": str(t.users["EMP"])})),
                       code="APPROVER_ROLE_REQUIRED")
        await db.fails("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb({**good, "evidence_type": "TELEPATHY"})),
                       code="EVIDENCE_TYPE_INVALID")
        await db.fails("SELECT loan.record_offline_approval(%s,%s)",
                       (request, Jsonb({**good, "decision_date": str(t.d0 + timedelta(days=1))})), code="OFFLINE_DATE_INVALID")
        await db.fails("SELECT loan.record_offline_approval(%s,%s)",
                       (request, Jsonb({k: v for k, v in good.items() if k != "approved_by"})), code="OFFLINE_APPROVER_REQUIRED")
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb(good)), code="SOD_RECORDER")
        await db.act(t, "EMP2", t.d0)
        result = await db.val("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb(good)))
        assert result["approval_channel"] == "OFFLINE" and result["approved_amount"] == 10000
        decision = await db.row("SELECT approval_channel, approval_method, approved_by, recorded_by, remarks "
                                "FROM wf.approval_decision WHERE approval_request_id=%s", (request,))
        assert (decision["approval_channel"], decision["approval_method"]) == ("OFFLINE", "MEETING")
        assert (decision["approved_by"], decision["recorded_by"]) == (t.users["MGR"], t.users["EMP2"])
        loan_row = await db.row("SELECT status, approved_by, approved_amount FROM loan.loan WHERE id=%s", (loan["id"],))
        assert (loan_row["status"], loan_row["approved_by"], loan_row["approved_amount"]) == ("APPROVED", t.users["MGR"], D("10000.00"))
        # only the approver verifies
        await db.fails("SELECT loan.verify_offline_approval(%s,'VERIFIED')", (request,), code="APPROVER_ROLE_REQUIRED")
        await db.act(t, "MGR", t.d0)
        assert (await db.val("SELECT loan.verify_offline_approval(%s,'VERIFIED')", (request,)))["result"] == "VERIFIED"
        assert any("is approved" in m["body"] for m in await db.messages(loan["id"]))
    run_db(scenario)


def test_offline_rejection_needs_reason_and_required_evidence():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.submit(t, loan["id"])
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        await db.conn.execute("UPDATE wf.offline_evidence_type SET upload_optional=false WHERE tenant_id=%s AND code='SIGNED_PAPER'",
                              (t.id,))
        details = {"decision": "REJECTED", "approved_by": str(t.users["MGR"]), "evidence_type": "SIGNED_PAPER"}
        await db.act(t, "EMP2", t.d0)
        await db.fails("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb(details)), code="EVIDENCE_REQUIRED")
        details["evidence_type"] = "PHONE"
        await db.fails("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb(details)), code="APPROVAL_REASON_REQUIRED")
        details["reason"] = "Income too low"
        result = await db.val("SELECT loan.record_offline_approval(%s,%s)", (request, Jsonb(details)))
        assert result["decision"] == "REJECTED" and await db.status(loan["id"]) == "REJECTED"
    run_db(scenario)
