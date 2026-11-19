"""Loan module integration tests against the real PostgreSQL schema.

The database comes from .env (schema owner CFMS_SEED_DB_USER, or
CFMS_TEST_DATABASE_URL) and must have been seeded with seed.py. Every test runs
in one rolled-back transaction with its own throw-away organisation, so local
data is never touched. Tests are skipped when the database is not reachable.

Amounts used throughout: 12,000 over 12 months at 12 % flat on the
INTEREST_BEARING loan type = 1,440 interest, instalments of 1,000 + 120.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import date, timedelta
from decimal import Decimal
from uuid import uuid4

import httpx
import pytest
from fastapi import FastAPI

from app.core.errors import install_error_handlers, localisation
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers import loans as loans_router
from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, Tenant, add_months, run_db

pytestmark = pytest.mark.postgres

D = Decimal


# =============================================================================
# Origination: eligibility, create, submit
# =============================================================================
def test_eligibility_positive_quote():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        result = await LoanService(db.conn).eligibility(
            member_id=t.members["A"], loan_type_id=t.loan_types["INTEREST_BEARING"],
            requested_amount=D("12000.00"), requested_tenure_months=12)
        assert result["eligible"] is True and result["reasons"] == []
        assert result["estimated_total_interest"] == D("1440.00")
        assert result["estimated_instalment_amount"] == D("1120.00")
        assert result["first_loan"] is True and result["nominee_required"] is True
    run_db(scenario)


@pytest.mark.parametrize(
    ("member", "amount", "tenure", "setup", "reason"),
    [
        ("A", "4999.99", 12, None, "AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS"),
        ("A", "200000.01", 12, None, "AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS"),
        ("A", "12000.00", 5, None, "TENURE_OUTSIDE_LOAN_TYPE_LIMITS"),
        ("A", "12000.00", 61, None, "TENURE_OUTSIDE_LOAN_TYPE_LIMITS"),
        ("APPLIED", "12000.00", 12, None, "MEMBER_NOT_ACTIVE"),
        ("APPLIED", "12000.00", 12, None, "MEMBERSHIP_DATE_REQUIRED"),
        ("NEW", "12000.00", 12, None, "MIN_MEMBERSHIP_PERIOD_NOT_MET"),
        ("A", "12000.00", 12, "restricted", "MEMBER_RESTRICTED"),
        ("A", "12000.00", 12, "cooling", "MEMBER_IN_COOLING_OFF"),
        ("A", "12000.00", 12, "open_loan", "MAX_CONCURRENT_LOANS_REACHED"),
        ("A", "12000.00", 12, "overdue", "OVERDUE_LOAN_INSTALMENT"),
    ],
)
def test_eligibility_negative_reasons(member, amount, tenure, setup, reason):
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        on = t.d0
        if setup == "restricted":
            await db.conn.execute("UPDATE mbr.member SET loan_eligibility='RESTRICTED' WHERE id=%s", (t.members[member],))
        elif setup == "cooling":
            await db.conn.execute("UPDATE mbr.member SET loan_eligibility='COOLING_OFF', cooling_off_until=%s WHERE id=%s",
                                  (on + timedelta(days=30), t.members[member]))
        elif setup in ("open_loan", "overdue"):
            await db.active_loan(t, member)
            if setup == "overdue":
                on = add_months(t.d0, 1) + timedelta(days=1)
        await db.act(t, "EMP", on)
        result = await LoanService(db.conn).eligibility(
            member_id=t.members[member], loan_type_id=t.loan_types["INTEREST_BEARING"],
            requested_amount=D(amount), requested_tenure_months=tenure)
        assert result["eligible"] is False
        assert reason in result["reasons"], result["reasons"]
    run_db(scenario)


def test_create_application_positive():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        assert loan["status"] == "DRAFT" and loan["loan_no"]
        assert loan["requested_amount"] == D("12000.00") and loan["is_first_loan"] is True
        nominees = await db.val("SELECT count(*) FROM loan.loan_nominee WHERE loan_id=%s", (loan["id"],))
        assert nominees == 1
        history = await db.val("SELECT to_status FROM loan.loan_status_history WHERE loan_id=%s", (loan["id"],))
        assert history == "DRAFT"
    run_db(scenario)


def test_create_application_negative():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        base = {"member_id": t.members["A"], "loan_type_id": t.loan_types["INTEREST_BEARING"],
                "requested_amount": D("12000.00"), "requested_tenure_months": 12, "purpose": "Test",
                "nominee_ids": [t.nominees["A"]]}
        await db.app_fails("LOAN_TYPE_NOT_FOUND", lambda: service.create_application({**base, "loan_type_id": uuid4()}))
        await db.app_fails("MEMBER_NOT_FOUND", lambda: service.create_application({**base, "member_id": uuid4()}))
        await db.app_fails("LOAN_TERMS_OUT_OF_RANGE",
                           lambda: service.create_application({**base, "requested_amount": D("1000.00")}))
        await db.app_fails("LOAN_TERMS_OUT_OF_RANGE",
                           lambda: service.create_application({**base, "requested_tenure_months": 120}))
        await db.app_fails("NOMINEE_NOT_ACTIVE",
                           lambda: service.create_application({**base, "nominee_ids": [t.nominees["B"]]}))
        await db.conn.execute("UPDATE mbr.nominee SET status='INACTIVE' WHERE id=%s", (t.nominees["A"],))
        await db.app_fails("NOMINEE_NOT_ACTIVE", lambda: service.create_application(base))
        assert await db.val("SELECT count(*) FROM loan.loan WHERE tenant_id=%s", (t.id,)) == 0
    run_db(scenario)


def test_submit_positive_creates_manager_approval():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        submitted = await db.submit(t, loan["id"])
        assert submitted["status"] == "UNDER_APPROVAL"
        await db.act(t, "MGR", t.d0)
        inbox = await LoanService(db.conn).approval_inbox(limit=10, offset=0)
        assert [item["loan_id"] for item in inbox["items"]] == [loan["id"]]
        await db.act(t, "EMP", t.d0)
        assert (await LoanService(db.conn).approval_inbox(limit=10, offset=0))["items"] == []
    run_db(scenario)


def test_submit_negative():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        await db.app_fails("LOAN_APPLICATION_NOT_FOUND", lambda: service.submit_application(uuid4()))
        no_nominee = await db.create_loan(t, "A", nominee=False)
        await db.act(t, "EMP", t.d0)
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.submit_application(no_nominee["id"]))
        loan = await db.create_loan(t, "B")
        await db.conn.execute("UPDATE mbr.member SET loan_eligibility='RESTRICTED' WHERE id=%s", (t.members["B"],))
        await db.act(t, "EMP", t.d0)
        error = await db.app_fails("LOAN_INELIGIBLE", lambda: service.submit_application(loan["id"]))
        assert "MEMBER_RESTRICTED" in error.details["reasons"]
        await db.conn.execute("UPDATE mbr.member SET loan_eligibility='ELIGIBLE' WHERE id=%s", (t.members["B"],))
        await db.submit(t, loan["id"])
        await db.act(t, "EMP", t.d0)
        await db.app_fails("LOAN_NOT_SUBMITTABLE", lambda: service.submit_application(loan["id"]))
    run_db(scenario)


# =============================================================================
# Application fee
# =============================================================================
def test_application_fee_gate_and_collection():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.conn.execute(
            """INSERT INTO loan.loan_application_fee (tenant_id, loan_id, fee_basis, fee_amount, collect_timing, status)
               VALUES (%s,%s,'FIXED',200,'BEFORE_SUBMISSION','PENDING')""", (t.id, loan["id"]))
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        await db.app_fails("FEE_UNPAID", lambda: service.submit_application(loan["id"]))
        await db.fails("SELECT loan.collect_application_fee(%s,'NOT_A_MODE')", (loan["id"],), code="PAYMENT_MODE_DISABLED")
        await db.fails("SELECT loan.collect_application_fee(%s,'CASH')", (uuid4(),), code="LOAN_FEE_NOT_FOUND")
        paid = await service.collect_application_fee(loan["id"], payment_mode="CASH", payment_reference="F-1")
        assert paid["status"] == "PAID" and D(str(paid["fee_amount"])) == D("200")
        receipt = await db.row("SELECT amount, purpose FROM acct.cash_receipt WHERE id=%s", (paid["cash_receipt_id"],))
        assert receipt["amount"] == D("200.00") and receipt["purpose"] == "APPLICATION_FEE"
        await db.fails("SELECT loan.collect_application_fee(%s,'CASH')", (loan["id"],), code="LOAN_FEE_STATE")
        assert (await db.submit(t, loan["id"]))["status"] == "UNDER_APPROVAL"
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.collect_application_fee(%s,'CASH')", (loan["id"],), code="LOAN_FEE_STATE")
    run_db(scenario)


# =============================================================================
# Approval decision
# =============================================================================
def test_approval_positive_fixes_terms():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.submit(t, loan["id"])
        result = await db.approve(t, loan["id"])
        assert result["decision"] == "APPROVED"
        row = await db.row("SELECT * FROM loan.loan WHERE id=%s", (loan["id"],))
        assert row["status"] == "APPROVED" and row["approved_amount"] == D("12000.00")
        assert row["total_interest"] == D("1440.00") and row["instalment_amount"] == D("1120.00")
        assert row["approval_expires_on"] == t.d0 + timedelta(days=30)
        reduced = await db.create_loan(t, "B")
        await db.submit(t, reduced["id"])
        await db.approve(t, reduced["id"], amount=D("6000.00"), tenure=6)
        row = await db.row("SELECT approved_amount, tenure_months, total_interest FROM loan.loan WHERE id=%s", (reduced["id"],))
        assert (row["approved_amount"], row["tenure_months"], row["total_interest"]) == (D("6000.00"), 6, D("360.00"))
    run_db(scenario)


def test_approval_negative_and_return_reject():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.submit(t, loan["id"])
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED')", (request,), code="SOD_SELF_APPROVAL")
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.record_approval_decision(%s,'MAYBE')", (request,), code="INVALID_APPROVAL_DECISION")
        await db.fails("SELECT loan.record_approval_decision(%s,'REJECTED')", (request,), code="APPROVAL_REASON_REQUIRED")
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED',NULL,12000.01)", (request,),
                       code="APPROVED_TERMS_OUT_OF_RANGE")
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED',NULL,NULL,13)", (request,),
                       code="APPROVED_TERMS_OUT_OF_RANGE")
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED')", (uuid4(),), code="APPROVAL_REQUEST_NOT_FOUND")
        await db.val("SELECT loan.record_approval_decision(%s,'RETURNED','Add documents')", (request,))
        assert await db.status(loan["id"]) == "RETURNED"
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED')", (request,), code="REQUEST_CLOSED")
        await db.submit(t, loan["id"])
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        await db.act(t, "MGR", t.d0)
        await db.val("SELECT loan.record_approval_decision(%s,'REJECTED','Insufficient income')", (request,))
        assert await db.status(loan["id"]) == "REJECTED"
        await db.act(t, "EMP", t.d0)
        await db.app_fails("LOAN_NOT_SUBMITTABLE", lambda: LoanService(db.conn).submit_application(loan["id"]))
    run_db(scenario)


# =============================================================================
# Disbursement (maker-checker)
# =============================================================================
def test_disbursement_positive_creates_schedule():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.approved_loan(t)
        prepared = await db.prepare(t, loan_id, "12000.00")
        assert prepared["status"] == "PREPARED" and D(str(prepared["net_amount"])) == D("12000.00")
        released = await db.release(t, loan_id, prepared["disbursement_id"])
        assert released["status"] == "PAID"
        loan = await db.row("SELECT * FROM loan.loan WHERE id=%s", (loan_id,))
        assert loan["status"] == "ACTIVE" and loan["outstanding_principal"] == D("12000.00")
        assert loan["first_due_date"] == add_months(t.d0, 1) and loan["maturity_date"] == add_months(t.d0, 12)
        voucher = await db.row("SELECT status, released_by, prepared_by FROM acct.payment_voucher WHERE id=%s",
                               (prepared["voucher_id"],))
        assert voucher["status"] == "PAID" and voucher["released_by"] == t.users["MGR"]
        assert voucher["prepared_by"] == t.users["EMP"]
        await db.act(t, "EMP", t.d0)
        schedule = await db.val("SELECT loan.get_schedule(%s)", (loan_id,))
        assert len(schedule["instalments"]) == 12
        assert schedule["totals"]["principal_due"] == 12000 and schedule["totals"]["interest_due"] == 1440
    run_db(scenario)


def test_disbursement_negative_maker_checker_and_states():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        draft = await db.create_loan(t, "B")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,1000)", (draft["id"],), code="LOAN_NOT_APPROVED")
        await db.fails("SELECT loan.prepare_disbursement(%s,1000)", (uuid4(),), code="LOAN_NOT_FOUND")
        loan_id = await db.approved_loan(t)
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,12000.01)", (loan_id,), code="OVER_DISBURSEMENT")
        await db.fails("SELECT loan.prepare_disbursement(%s,0)", (loan_id,), code="OVER_DISBURSEMENT")
        prepared = await db.prepare(t, loan_id, "12000.00")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,1)", (loan_id,), code="OVER_DISBURSEMENT")
        # the maker cannot also release the cash
        await db.fails("SELECT loan.release_disbursement(%s,%s,'SIGNATURE')", (loan_id, prepared["disbursement_id"]),
                       constraint="payment_voucher_maker_checker")
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.release_disbursement(%s,%s,'NONE')", (loan_id, prepared["disbursement_id"]),
                       code="PAYEE_ACK_REQUIRED")
        await db.fails("SELECT loan.release_disbursement(%s,%s,'SIGNATURE')", (loan_id, uuid4()),
                       code="DISBURSEMENT_NOT_FOUND")
        await db.release(t, loan_id, prepared["disbursement_id"])
        await db.fails("SELECT loan.release_disbursement(%s,%s,'SIGNATURE')", (loan_id, prepared["disbursement_id"]),
                       code="DISBURSEMENT_STATE")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,1)", (loan_id,), code="OVER_DISBURSEMENT")
    run_db(scenario)


def test_disbursement_after_approval_expiry_is_refused():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.approved_loan(t)
        await db.act(t, "EMP", t.d0 + timedelta(days=31))
        await db.fails("SELECT loan.prepare_disbursement(%s,12000)", (loan_id,), code="APPROVAL_EXPIRED")
        await db.conn.execute("UPDATE mbr.member SET status='SUSPENDED' WHERE id=%s", (t.members["A"],))
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.prepare_disbursement(%s,12000)", (loan_id,), code="MEMBER_NOT_ACTIVE")
    run_db(scenario)


# =============================================================================
# Repayment
# =============================================================================
def test_repayment_positive_partial_regular_and_closure():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t, amount="6000.00", tenure=6)   # 1000 + 60 a month
        due1 = add_months(t.d0, 1)
        partial = await db.repay(t, loan_id, "50.00", due1)
        assert partial["interest_amount"] == 50 and partial["principal_amount"] == 0
        assert await db.val("SELECT repayment_type FROM loan.loan_repayment WHERE id=%s", (partial["repayment_id"],)) == "PARTIAL"
        assert await db.val("SELECT status FROM loan.loan_instalment WHERE loan_id=%s AND instalment_no=1", (loan_id,)) == "PARTLY_PAID"
        rest = await db.repay(t, loan_id, "1010.00", due1)
        assert rest["interest_amount"] == 10 and rest["principal_amount"] == 1000 and rest["loan_status"] == "ACTIVE"
        assert await db.val("SELECT status FROM loan.loan_instalment WHERE loan_id=%s AND instalment_no=1", (loan_id,)) == "PAID"
        for n in range(2, 7):
            result = await db.repay(t, loan_id, "1060.00", add_months(t.d0, n))
        assert result["loan_status"] == "CLOSED" and result["outstanding_principal"] == 0
        loan = await db.row("SELECT status, closed_on, status_reason FROM loan.loan WHERE id=%s", (loan_id,))
        assert loan["status"] == "CLOSED" and loan["closed_on"] == add_months(t.d0, 6)
        assert loan["status_reason"] == "Repaid in full"
        await db.act(t, "EMP", add_months(t.d0, 6))
        await db.fails("SELECT loan.collect_repayment(%s,10,'CASH')", (loan_id,), code="LOAN_NOT_OPEN")
    run_db(scenario)


def test_repayment_negative():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        approved = await db.approved_loan(t, "B")
        loan_id = await db.active_loan(t)
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.collect_repayment(%s,0,'CASH')", (loan_id,), code="INVALID_REPAYMENT_AMOUNT")
        await db.fails("SELECT loan.collect_repayment(%s,-5,'CASH')", (loan_id,), code="INVALID_REPAYMENT_AMOUNT")
        # more than the next instalment plus the rest of the principal: use early settlement
        await db.fails("SELECT loan.collect_repayment(%s,13000,'CASH')", (loan_id,), code="REPAYMENT_CLEARS_LOAN")
        await db.fails("SELECT loan.collect_repayment(%s,10,'CASH')", (uuid4(),), code="LOAN_NOT_FOUND")
        await db.fails("SELECT loan.collect_repayment(%s,10,'CASH')", (approved,), code="LOAN_NOT_OPEN")
        await db.set_rule(loan_id, "OVERPAYMENT", {"value": {"excessReducesPrincipal": False}})
        await db.act(t, "EMP", add_months(t.d0, 1))
        await db.fails("SELECT loan.collect_repayment(%s,1120.01,'CASH')", (loan_id,), code="REPAYMENT_EXCEEDS_DUES")
        await db.fails("SELECT loan.collect_repayment(%s,100,'NOT_A_MODE')", (loan_id,), code="PAYMENT_MODE_DISABLED")
        assert await db.val("SELECT count(*) FROM loan.loan_repayment WHERE loan_id=%s", (loan_id,)) == 0
    run_db(scenario)


def test_repayment_brings_overdue_loan_back_to_active():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        late = add_months(t.d0, 1) + timedelta(days=3)
        await db.act(t, "EMP", late)
        await db.val("SELECT loan.run_daily_status()")
        assert await db.status(loan_id) == "OVERDUE"
        result = await db.repay(t, loan_id, "1000.00", late)
        assert result["loan_status"] == "OVERDUE"          # still 120 open on the overdue instalment
        result = await db.repay(t, loan_id, "120.00", late)
        assert result["loan_status"] == "ACTIVE"
        assert await db.val("SELECT status_reason FROM loan.loan WHERE id=%s", (loan_id,)) == "Overdue instalments cleared"
    run_db(scenario)


# =============================================================================
# Views: schedule, repayments, member statement
# =============================================================================
def test_views_positive():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.repay(t, loan_id, "1120.00", add_months(t.d0, 1))
        on = add_months(t.d0, 2) + timedelta(days=5)        # instalment 2 is 5 days overdue
        await db.act(t, "EMP", on)
        service = LoanService(db.conn)
        schedule = await service.schedule(loan_id)
        first, second, third = schedule["instalments"][:3]
        assert first["status"] == "PAID" and first["amount_open"] == 0 and first["is_overdue"] is False
        assert second["is_overdue"] is True and second["days_overdue"] == 5 and second["amount_open"] == 1120
        assert third["is_overdue"] is False
        assert schedule["totals"]["overdue_amount"] == 1120 and schedule["totals"]["overdue_instalments"] == 1
        assert schedule["schedule"]["schedule_version"] == 1 and schedule["outstanding_principal"] == 11000

        repayments = await service.repayments(loan_id)
        assert len(repayments) == 1 and repayments[0]["receipt_no"]
        assert [a["component"] for a in repayments[0]["allocations"]] == ["INTEREST", "PRINCIPAL"]
        assert repayments[0]["allocations"][0]["instalment_no"] == 1

        statement = await service.member_statement(t.members["A"])
        assert statement["totals"]["open_loans"] == 1
        assert statement["totals"]["outstanding_principal"] == 11000
        assert statement["totals"]["overdue_amount"] == 1120
        loan = statement["loans"][0]
        assert loan["next_due_date"] == add_months(t.d0, 3).isoformat() and loan["next_due_amount"] == 1120
        assert loan["days_overdue"] == 5 and loan["principal_repaid"] == 1000
    run_db(scenario)


def test_views_negative_and_empty():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        draft = await db.create_loan(t, "B")
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        await db.app_fails("LOAN_NOT_FOUND", lambda: service.schedule(uuid4()))
        await db.app_fails("LOAN_NOT_FOUND", lambda: service.repayments(uuid4()))
        await db.app_fails("MEMBER_NOT_FOUND", lambda: service.member_statement(uuid4()))
        schedule = await service.schedule(draft["id"])
        assert schedule["schedule"] is None and schedule["instalments"] == []
        assert await service.repayments(draft["id"]) == []
        statement = await service.member_statement(t.members["B"])
        assert statement["loans"] == [] and statement["totals"]["open_loans"] == 0
    run_db(scenario)


# =============================================================================
# Daily status job
# =============================================================================
def test_daily_job_overdue_grace_and_idempotent_runs():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        await db.act(t, None, due1)
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["marked_overdue"] == 0 and await db.status(loan_id) == "ACTIVE"   # due today, not late
        await db.set_rule(loan_id, "LATE_FEE", {"value": {"enabled": False, "graceDays": 5}})
        await db.act(t, None, due1 + timedelta(days=5))
        await db.val("SELECT loan.run_daily_status()")
        assert await db.status(loan_id) == "ACTIVE"                                     # within grace
        await db.act(t, None, due1 + timedelta(days=6))
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["marked_overdue"] == 1 and await db.status(loan_id) == "OVERDUE"
        again = await db.val("SELECT loan.run_daily_status()")
        assert again["marked_overdue"] == 0
        runs = await db.rows("SELECT job_code, status FROM platform.job_run WHERE tenant_id=%s AND working_date=%s",
                             (t.id, due1 + timedelta(days=6)))
        assert sorted(r["job_code"] for r in runs) == ["APPROVAL_EXPIRY", "COOLING_OFF_END", "LOAN_REMINDERS",
                                                       "LOAN_STATUS_DAILY", "RECOVERY_ESCALATION"]
        assert {r["status"] for r in runs} == {"SUCCEEDED"}
        # paid up outside the job: the next run moves the loan back to ACTIVE
        await db.conn.execute(
            "UPDATE loan.loan_instalment SET principal_paid=principal_due, interest_paid=interest_due, status='PAID' "
            "WHERE loan_id=%s AND instalment_no=1", (loan_id,))
        await db.act(t, None, due1 + timedelta(days=7))
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["back_to_current"] == 1 and await db.status(loan_id) == "ACTIVE"
    run_db(scenario)


def test_daily_job_default_with_penalty_and_rules():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        percent = await db.active_loan(t, "A")
        fixed = await db.active_loan(t, "B")
        await db.set_rule(fixed, "DEFAULT_AFTER_MONTHS", {"value": 3})
        await db.set_rule(fixed, "DEFAULT_PENALTY", {"then": {"type": "fixed", "value": 500}})
        due1 = add_months(t.d0, 1)
        await db.act(t, None, add_months(due1, 2))
        await db.val("SELECT loan.run_daily_status()")
        assert await db.status(percent) == "OVERDUE"            # exactly 2 months: not yet
        await db.act(t, None, add_months(due1, 2) + timedelta(days=1))
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["defaulted"] == 1
        assert await db.status(percent) == "DEFAULTED" and await db.status(fixed) == "OVERDUE"
        default = await db.row("SELECT * FROM loan.loan_default WHERE loan_id=%s", (percent,))
        assert default["oldest_unpaid_due_date"] == due1 and default["unpaid_months_rule"] == 2
        assert default["outstanding_principal"] == D("12000.00") and default["outstanding_interest"] == D("1440.00")
        assert default["penalty_amount"] == D("240.00")        # 2 % of 12,000
        charge = await db.row("SELECT charge_type, amount, status FROM loan.loan_charge WHERE loan_id=%s", (percent,))
        assert (charge["charge_type"], charge["amount"], charge["status"]) == ("DEFAULT_PENALTY", D("240.00"), "OPEN")
        assert await db.val("SELECT loan_eligibility FROM mbr.member WHERE id=%s", (t.members["A"],)) == "RESTRICTED"
        await db.act(t, None, add_months(due1, 3) + timedelta(days=1))
        await db.val("SELECT loan.run_daily_status()")
        assert await db.status(fixed) == "DEFAULTED"
        assert await db.val("SELECT penalty_amount FROM loan.loan_default WHERE loan_id=%s", (fixed,)) == D("500.00")
        # a defaulted loan is not processed again and still accepts repayments
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["defaulted"] == 0
        await db.repay(t, percent, "120.00", add_months(due1, 3) + timedelta(days=1))
        assert await db.status(percent) == "DEFAULTED"
    run_db(scenario)


def test_daily_job_approval_expiry_cancels_prepared_voucher():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.approved_loan(t)
        prepared = await db.prepare(t, loan_id, "12000.00")
        untouched = await db.approved_loan(t, "B", on=t.d0 + timedelta(days=5))
        expires = t.d0 + timedelta(days=30)
        await db.act(t, None, expires)
        assert (await db.val("SELECT loan.run_daily_status()"))["approvals_expired"] == 0
        await db.act(t, None, expires + timedelta(days=1))
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["approvals_expired"] == 1 and result["disbursements_cancelled"] == 1
        assert await db.status(loan_id) == "CANCELLED" and await db.status(untouched) == "APPROVED"
        voucher = await db.row("SELECT status, cancel_reason FROM acct.payment_voucher WHERE id=%s", (prepared["voucher_id"],))
        assert voucher["status"] == "CANCELLED" and voucher["cancel_reason"]
        assert await db.val("SELECT status FROM loan.loan_disbursement WHERE id=%s", (prepared["disbursement_id"],)) == "CANCELLED"
        reason = await db.val("SELECT reason FROM loan.loan_status_history WHERE loan_id=%s AND to_status='CANCELLED'", (loan_id,))
        assert reason.startswith("Approval expired on")
    run_db(scenario)


def test_daily_job_without_tenant_context_and_failure_log():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(None, None, None)
        await db.fails("SELECT loan.run_daily_status()", code="TENANT_CONTEXT_REQUIRED")
        await db.act(t, None, t.d0)
        run_id = await db.val("SELECT loan.record_job_failure('LOAN_STATUS_DAILY', %s, 'SCHEDULE', 'boom')", (t.d0,))
        row = await db.row("SELECT status, error_message, records_failed FROM platform.job_run WHERE id=%s", (run_id,))
        assert (row["status"], row["error_message"], row["records_failed"]) == ("FAILED", "boom", 1)
        result = await db.val("SELECT loan.run_daily_status(%s, 'USER')", (t.d0,))   # a failure does not block a rerun
        assert result["working_date"] == t.d0.isoformat()
    run_db(scenario)


# =============================================================================
# Early settlement
# =============================================================================
async def _quote(db: LoanDb, t: Tenant, loan_id, on, role="EMP"):
    await db.act(t, role, on)
    return await db.val("SELECT loan.quote_early_settlement(%s)", (loan_id,))


def test_settlement_policy_b_positive_full_flow():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        for n in (1, 2):
            await db.repay(t, loan_id, "1120.00", add_months(t.d0, n))
        on = add_months(t.d0, 2) + timedelta(days=15)
        period = (add_months(t.d0, 3) - add_months(t.d0, 2)).days
        accrued = (D(120) * 15 / period).quantize(D("0.01"))
        quote = await _quote(db, t, loan_id, on)
        assert quote["status"] == "QUOTED" and quote["interest_policy"] == "B_INTEREST_TO_DATE"
        assert quote["principal_outstanding"] == 10000 and D(str(quote["interest_component"])) == accrued
        assert D(str(quote["rebate"])) == D(1200) - accrued
        assert quote["approval_required"] is True and quote["valid_until"] == on.isoformat()
        total = D(str(quote["total_payable"]))
        assert total == (D(10000) + accrued).quantize(D("1"))     # rounding.settlement: nearest 1
        await db.act(t, "MGR", on)
        approved = await db.val("SELECT loan.approve_early_settlement(%s,'ok')", (quote["id"],))
        assert approved["status"] == "APPROVED" and approved["approval"]["approved_by"] == str(t.users["MGR"])
        await db.act(t, "EMP", on)
        paid = await db.val("SELECT loan.collect_early_settlement(%s,'CASH','R-1')", (quote["id"],))
        assert paid["status"] == "PAID" and paid["loan_status"] == "SETTLED" and D(str(paid["amount"])) == total
        loan = await db.row("SELECT status, outstanding_principal, closed_on FROM loan.loan WHERE id=%s", (loan_id,))
        assert (loan["status"], loan["outstanding_principal"], loan["closed_on"]) == ("SETTLED", D(0), on)
        repayment = await db.row("SELECT * FROM loan.loan_repayment WHERE id=%s", (paid["repayment_id"],))
        assert repayment["repayment_type"] == "EARLY_SETTLEMENT" and repayment["principal_amount"] == D(10000)
        journal = await db.row("SELECT sum(debit) dr, sum(credit) cr FROM acct.journal_line WHERE journal_id=%s",
                               (paid["journal_id"],))
        assert journal["dr"] == journal["cr"] == total
        statuses = await db.rows("SELECT status FROM loan.loan_instalment WHERE loan_id=%s ORDER BY instalment_no", (loan_id,))
        assert [r["status"] for r in statuses] == ["PAID"] * 2 + ["CANCELLED"] * 10
        assert await db.val("SELECT outstanding_principal FROM loan.v_loan_balance WHERE loan_id=%s", (loan_id,)) == 0
        settlement = await LoanService(db.conn).settlement(quote["id"])
        assert settlement["status"] == "PAID" and settlement["receipt_no"]
        assert settlement["collection"]["repayment_id"] == str(paid["repayment_id"])
        assert await db.val("SELECT loan_eligibility FROM mbr.member WHERE id=%s", (t.members["A"],)) == "ELIGIBLE"
    run_db(scenario)


def test_settlement_approval_and_collection_negative():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        on = t.d0 + timedelta(days=10)
        quote = await _quote(db, t, loan_id, on)
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],), code="SETTLEMENT_NOT_APPROVED")
        await db.fails("SELECT loan.approve_early_settlement(%s)", (quote["id"],), code="SETTLEMENT_APPROVER_IS_CREATOR")
        await db.fails("SELECT loan.approve_early_settlement(%s)", (uuid4(),), code="SETTLEMENT_NOT_FOUND")
        await db.fails("SELECT loan.collect_early_settlement(%s,'CASH')", (uuid4(),), code="SETTLEMENT_NOT_FOUND")
        await db.act(t, "MGR", on)
        await db.val("SELECT loan.approve_early_settlement(%s)", (quote["id"],))
        await db.fails("SELECT loan.approve_early_settlement(%s)", (quote["id"],), code="SETTLEMENT_NOT_PENDING")
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.collect_early_settlement(%s,'NOT_A_MODE')", (quote["id"],), code="PAYMENT_MODE_DISABLED")
        await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        await db.fails("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],), code="SETTLEMENT_NOT_PENDING")
        await db.fails("SELECT loan.quote_early_settlement(%s)", (loan_id,), code="EARLY_SETTLEMENT_NOT_ALLOWED")
        await db.fails("SELECT loan.collect_repayment(%s,10,'CASH')", (loan_id,), code="LOAN_NOT_OPEN")
    run_db(scenario)


def test_settlement_expired_superseded_and_stale_quotes():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        day1 = add_months(t.d0, 1)
        old = await _quote(db, t, loan_id, day1 - timedelta(days=1))
        # expired: valid only on its statement date
        await db.act(t, "MGR", day1)
        await db.fails("SELECT loan.approve_early_settlement(%s)", (old["id"],), code="SETTLEMENT_QUOTE_EXPIRED")
        await db.conn.execute("UPDATE loan.loan_settlement SET status='APPROVED' WHERE id=%s", (old["id"],))
        await db.act(t, "EMP", day1)
        await db.fails("SELECT loan.collect_early_settlement(%s,'CASH')", (old["id"],), code="SETTLEMENT_QUOTE_EXPIRED")
        # superseded: a new quote expires the open one
        new = await _quote(db, t, loan_id, day1)
        assert await db.val("SELECT status FROM loan.loan_settlement WHERE id=%s", (old["id"],)) == "EXPIRED"
        await db.act(t, "MGR", day1)
        await db.fails("SELECT loan.approve_early_settlement(%s)", (old["id"],), code="SETTLEMENT_NOT_PENDING")
        await db.val("SELECT loan.approve_early_settlement(%s)", (new["id"],))
        # stale: a repayment after the quote changes the loan
        await db.repay(t, loan_id, "1120.00", day1)
        await db.act(t, "EMP", day1)
        await db.fails("SELECT loan.collect_early_settlement(%s,'CASH')", (new["id"],), code="SETTLEMENT_QUOTE_STALE")
        listed = await LoanService(db.conn).settlements(loan_id)
        assert sorted(s["status"] for s in listed) == ["APPROVED", "EXPIRED"]
    run_db(scenario)


def test_settlement_rule_variants():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        # disabled
        disabled = await db.active_loan(t, "A")
        await db.set_rule(disabled, "EARLY_SETTLEMENT", {"value": {"enabled": False}})
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.quote_early_settlement(%s)", (disabled,), code="EARLY_SETTLEMENT_DISABLED")
        # policy A + percent charge, no approval, quote valid 3 days, cooling-off 3 months
        loan_id = await db.active_loan(t, "B", amount="10000.00", tenure=10)   # 1000 + 100 a month
        await db.set_rule(loan_id, "EARLY_SETTLEMENT", {"value": {
            "enabled": True, "interestPolicy": "A_ALL_SCHEDULED_INTEREST",
            "charge": {"type": "percent", "value": 1.5}, "approvalRequired": False, "quoteValidDays": 3}})
        await db.set_rule(loan_id, "COOLING_OFF_AFTER_EARLY_SETTLEMENT", {"value": {"enabled": True, "months": 3}})
        on = t.d0 + timedelta(days=5)
        quote = await _quote(db, t, loan_id, on)
        assert quote["interest_component"] == 1000 and quote["rebate"] == 0
        assert quote["settlement_charge"] == 150 and quote["total_payable"] == 11150
        assert quote["approval_required"] is False and quote["valid_until"] == (on + timedelta(days=3)).isoformat()
        await db.act(t, "EMP", on + timedelta(days=3))
        paid = await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        assert paid["cooling_off_until"] == add_months(on + timedelta(days=3), 3).isoformat()
        lines = await db.rows("SELECT component, amount FROM acct.cash_receipt_line WHERE cash_receipt_id=%s ORDER BY line_no",
                              (paid["cash_receipt_id"],))
        assert [(r["component"], r["amount"]) for r in lines] == [
            ("PRINCIPAL", D("10000.00")), ("INTEREST", D("1000.00")), ("SETTLEMENT_CHARGE", D("150.00"))]
        member = await db.row("SELECT loan_eligibility, cooling_off_until FROM mbr.member WHERE id=%s", (t.members["B"],))
        assert member["loan_eligibility"] == "COOLING_OFF"
        assert await db.val("SELECT charge_type FROM loan.loan_charge WHERE loan_id=%s", (loan_id,)) == "SETTLEMENT_CHARGE"
        # downward rounding is taken off interest: 0.40 fixed charge, total rounds to the rupee below
        rounded = await db.active_loan(t, "C", amount="10000.00", tenure=10)
        await db.set_rule(rounded, "EARLY_SETTLEMENT", {"value": {
            "enabled": True, "interestPolicy": "A_ALL_SCHEDULED_INTEREST",
            "charge": {"type": "fixed", "value": 0.40}, "approvalRequired": False}})
        quote = await _quote(db, t, rounded, on)
        assert quote["rounding_adjustment"] == -0.4 and quote["total_payable"] == 11000
        await db.act(t, "EMP", on)
        paid = await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        repayment = await db.row("SELECT amount, interest_amount, charge_amount FROM loan.loan_repayment WHERE id=%s",
                                 (paid["repayment_id"],))
        assert (repayment["amount"], repayment["interest_amount"], repayment["charge_amount"]) == (
            D("11000.00"), D("999.60"), D("0.40"))
    run_db(scenario)


def test_settlement_not_allowed_states():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        approved = await db.approved_loan(t, "A")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.quote_early_settlement(%s)", (approved,), code="EARLY_SETTLEMENT_NOT_ALLOWED")
        await db.fails("SELECT loan.quote_early_settlement(%s)", (uuid4(),), code="LOAN_NOT_FOUND")
        defaulted = await db.active_loan(t, "B")
        await db.act(t, None, add_months(t.d0, 3) + timedelta(days=1))
        await db.val("SELECT loan.run_daily_status()")
        assert await db.status(defaulted) == "DEFAULTED"
        await db.act(t, "EMP", add_months(t.d0, 3) + timedelta(days=1))
        # a defaulted loan gets a default settlement quote instead (full outstanding plus penalty)
        quote = await db.val("SELECT loan.quote_early_settlement(%s)", (defaulted,))
        assert quote["settlement_type"] == "DEFAULT"
        await db.app_fails("SETTLEMENT_NOT_FOUND", lambda: LoanService(db.conn).settlement(uuid4()))
        await db.app_fails("LOAN_NOT_FOUND", lambda: LoanService(db.conn).settlements(uuid4()))
    run_db(scenario)


# =============================================================================
# Tenant isolation
# =============================================================================
def test_other_tenant_cannot_see_or_change_loans():
    async def scenario(db: LoanDb):
        a = await db.new_tenant()
        b = await db.new_tenant()
        loan_id = await db.active_loan(a)
        approved = await db.approved_loan(a, "B")
        prepared = await db.prepare(a, approved, "12000.00")
        quote = await _quote(db, a, loan_id, a.d0)
        await db.act(b, "EMP", b.d0)
        service = LoanService(db.conn)
        assert await db.val("SELECT count(*) FROM loan.loan WHERE id IN (%s,%s)", (loan_id, approved)) == 0
        await db.app_fails("LOAN_APPLICATION_NOT_FOUND", lambda: service.get_application(loan_id))
        await db.app_fails("LOAN_NOT_FOUND", lambda: service.schedule(loan_id))
        await db.app_fails("LOAN_NOT_FOUND", lambda: service.repayments(loan_id))
        await db.app_fails("MEMBER_NOT_FOUND", lambda: service.member_statement(a.members["A"]))
        await db.app_fails("SETTLEMENT_NOT_FOUND", lambda: service.settlement(quote["id"]))
        await db.fails("SELECT loan.collect_repayment(%s,10,'CASH')", (loan_id,), code="LOAN_NOT_FOUND")
        await db.fails("SELECT loan.quote_early_settlement(%s)", (loan_id,), code="LOAN_NOT_FOUND")
        await db.act(b, "MGR", b.d0)
        await db.fails("SELECT loan.approve_early_settlement(%s)", (quote["id"],), code="SETTLEMENT_NOT_FOUND")
        await db.fails("SELECT loan.release_disbursement(%s,%s,'SIGNATURE')", (approved, prepared["disbursement_id"]),
                       code="DISBURSEMENT_NOT_FOUND")
        await db.app_fails("MEMBER_NOT_FOUND", lambda: service.create_application({
            "member_id": a.members["A"], "loan_type_id": b.loan_types["INTEREST_BEARING"],
            "requested_amount": D("12000.00"), "requested_tenure_months": 12, "purpose": "x", "nominee_ids": []}))
        await db.act(b, None, add_months(b.d0, 3) + timedelta(days=1))
        result = await db.val("SELECT loan.run_daily_status()")
        assert result["loans_checked"] == 0
        assert await db.status(loan_id) is None                      # still invisible to tenant B
        await db.act(a, "EMP", a.d0)
        assert await db.status(loan_id) == "ACTIVE"
    run_db(scenario)


def test_runtime_role_can_execute_every_loan_function():
    async def scenario(db: LoanDb):
        missing = await db.rows(
            """SELECT p.oid::regprocedure::text AS fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'loan' AND p.prokind = 'f' AND p.prorettype <> 'trigger'::regtype
                  AND NOT has_function_privilege('nvs_app', p.oid, 'EXECUTE')""")
        assert missing == []
        codes = await db.val(
            """SELECT count(*) FROM platform.error_code
                WHERE short_code IN ('EARLY_SETTLEMENT_DISABLED','EARLY_SETTLEMENT_NOT_ALLOWED','SETTLEMENT_QUOTE_EXPIRED',
                      'SETTLEMENT_APPROVER_IS_CREATOR','SETTLEMENT_NOT_FOUND','SETTLEMENT_QUOTE_STALE',
                      'SETTLEMENT_NOT_APPROVED','SETTLEMENT_NOT_PENDING','TENANT_CONTEXT_REQUIRED')
                  AND translations ? 'ta'""")
        assert codes == 9
    run_db(scenario)


# =============================================================================
# HTTP: real privilege checks and localised error messages
# =============================================================================
class _Pool:
    def __init__(self, conn) -> None:
        self.conn = conn

    @asynccontextmanager
    async def connection(self):
        yield self.conn


class Api:
    """Calls the real loan router on the test transaction as a given user."""

    def __init__(self, db: LoanDb, tenant: Tenant) -> None:
        self.db, self.tenant = db, tenant
        self.principal: TenantPrincipal | None = None
        app = FastAPI()
        install_error_handlers(app)
        app.include_router(loans_router.router, prefix="/api/v1")

        async def tenant_db():
            yield db.conn

        app.dependency_overrides[get_tenant_db] = tenant_db
        app.dependency_overrides[require_tenant_user] = lambda: self.principal
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")

    async def call(self, role: str, method: str, path: str, *, on: date | None = None, lang: str = "en",
                   json=None, headers: dict[str, str] | None = None) -> httpx.Response:
        on = on or self.tenant.d0
        self.principal = TenantPrincipal(tenant_id=self.tenant.id, user_id=self.tenant.users[role],
                                         role_code=role.rstrip("2"), channel="WEB", mfa_verified=False,
                                         working_date=on)
        await self.db.act(self.tenant, role, on)
        async with self.db.savepoint():
            return await self.client.request(method, f"/api/v1{path}", json=json,
                                             headers={"Accept-Language": lang, **(headers or {})})


def test_http_privileges_by_role():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await localisation.load(_Pool(db.conn))
        api = Api(db, t)
        loan_id = await db.active_loan(t)
        approved = await db.approved_loan(t, "B")
        prepared = await db.prepare(t, approved, "12000.00")
        body = {"member_id": str(t.members["C"]), "loan_type_id": str(t.loan_types["INTEREST_BEARING"]),
                "requested_amount": "12000.00", "requested_tenure_months": 12, "purpose": "Home repairs",
                "nominee_ids": [str(t.nominees["C"])]}
        denied = [
            ("MGR", "POST", "/loans", body),                                             # no loan.create
            ("ACC", "POST", "/loans", body),
            ("EMP", "POST", f"/loans/{approved}/disbursements/{prepared['disbursement_id']}/release",
             {"payee_ack_type": "SIGNATURE"}),                                          # needs loan.approve
            ("MGR", "POST", f"/loans/{loan_id}/disbursements", {"gross_amount": "1.00"}),  # needs loan.edit
            ("ACC", "POST", f"/loans/{loan_id}/repayments", {"amount": "10.00"}),
            ("ACC", "POST", f"/loans/{loan_id}/settlement-quote", None),
            ("EMP", "POST", f"/loan-settlements/{uuid4()}/approve", {}),                  # needs loan_settle.approve
            ("MGR", "POST", f"/loan-settlements/{uuid4()}/collect", {}),                  # needs loan_settle.create
            ("EMP", "GET", "/loan-approvals/inbox", None),
        ]
        for role, method, path, payload in denied:
            response = await api.call(role, method, path, json=payload)
            assert response.status_code == 403, (role, path, response.text)
            assert response.json()["detail"]["shortCode"] == "NO_PRIVILEGE"
        allowed = [
            ("ACC", "GET", f"/loans/{loan_id}/schedule"),
            ("ACC", "GET", f"/loans/{loan_id}/repayments"),
            ("ACC", "GET", f"/members/{t.members['A']}/loan-statement"),
            ("ACC", "GET", f"/loans/{loan_id}/settlements"),
            ("MGR", "GET", "/loan-approvals/inbox"),
        ]
        for role, method, path in allowed:
            response = await api.call(role, method, path)
            assert response.status_code == 200, (role, path, response.text)
        created = await api.call("EMP", "POST", "/loans", json=body)
        assert created.status_code == 201 and created.json()["status"] == "DRAFT"
        released = await api.call("MGR", "POST", f"/loans/{approved}/disbursements/{prepared['disbursement_id']}/release",
                                  json={"payee_ack_type": "SIGNATURE"})
        assert released.status_code == 200 and released.json()["status"] == "PAID"
    run_db(scenario)


def test_http_settlement_flow_and_localised_errors():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await localisation.load(_Pool(db.conn))
        api = Api(db, t)
        loan_id = await db.active_loan(t)
        on = t.d0 + timedelta(days=10)
        quote = await api.call("EMP", "POST", f"/loans/{loan_id}/settlement-quote", on=on)
        assert quote.status_code == 201
        settlement_id = quote.json()["id"]
        not_approved = await api.call("EMP", "POST", f"/loan-settlements/{settlement_id}/collect", on=on, lang="ta", json={},
                                    headers={"Idempotency-Key": "settle-r9-0001"})   # a failed try keeps the key free
        detail = not_approved.json()["detail"]
        assert not_approved.status_code == 409 and detail["shortCode"] == "SETTLEMENT_NOT_APPROVED"
        assert detail["code"] == "CFMS-LOAN-5005" and detail["language"] == "ta" and "அங்கீகரிக்கப்பட" in detail["message"]
        own = await api.call("EMP2", "POST", f"/loan-settlements/{settlement_id}/approve", on=on, json={})
        assert own.status_code == 403                                   # EMP2 has no loan_settle.approve
        approved = await api.call("MGR", "POST", f"/loan-settlements/{settlement_id}/approve", on=on,
                                  json={"remarks": "verified"})
        assert approved.status_code == 200 and approved.json()["status"] == "APPROVED"
        again = await api.call("MGR", "POST", f"/loan-settlements/{settlement_id}/approve", on=on, json={})
        assert again.status_code == 409 and again.json()["detail"]["shortCode"] == "SETTLEMENT_NOT_PENDING"
        paid = await api.call("EMP", "POST", f"/loan-settlements/{settlement_id}/collect", on=on,
                              json={"payment_mode": "CASH", "payment_reference": "R-9"},
                              headers={"Idempotency-Key": "settle-r9-0001"})
        assert paid.status_code == 201 and paid.json()["loan_status"] == "SETTLED"
        got = await api.call("ACC", "GET", f"/loan-settlements/{settlement_id}", on=on)
        assert got.status_code == 200 and got.json()["status"] == "PAID"

        missing = await api.call("EMP", "GET", f"/loans/{uuid4()}/schedule", lang="ta")
        detail = missing.json()["detail"]
        assert missing.status_code == 404 and detail["code"] == "CFMS-LOAN-4001" and detail["language"] == "ta"
        english = await api.call("EMP", "GET", f"/loans/{uuid4()}/schedule", lang="fr, en;q=0.5")
        assert english.json()["detail"]["language"] == "en" and english.json()["detail"]["message"] == "The loan was not found."
        denied = await api.call("ACC", "POST", f"/loans/{loan_id}/settlement-quote", lang="ta")
        assert denied.json()["detail"]["params"] == {"privilege": "loan_settle.create"}
        assert denied.json()["detail"]["language"] == "ta"
        invalid = await api.call("EMP", "POST", f"/loans/{loan_id}/repayments", json={"amount": "0"})
        assert invalid.status_code == 422                               # request validation
        invalid = await api.call("MGR", "POST", f"/loan-approvals/{uuid4()}/decision", json={"decision": "MAYBE"})
        assert invalid.status_code == 422
        bad_id = await api.call("EMP", "GET", "/loans/not-a-uuid/schedule")
        assert bad_id.status_code == 422
    run_db(scenario)
