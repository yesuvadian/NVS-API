"""Integration tests for guarantors and the extra eligibility limits (scope 6.2, 6.9)."""

from __future__ import annotations

from datetime import date, timedelta
from decimal import Decimal

import pytest
from psycopg.types.json import Jsonb

from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, add_months, run_db

pytestmark = pytest.mark.postgres

D = Decimal


def _g(member_id, consent="SIGNATURE", **extra):
    return Jsonb({"guarantor_member_id": str(member_id), "consent_type": consent, **extra})


async def _eligibility(db: LoanDb, t, member="A", amount="12000", tenure=12):
    return await LoanService(db.conn).eligibility(member_id=t.members[member], loan_type_id=t.loan_types["INTEREST_BEARING"],
                                                  requested_amount=D(amount), requested_tenure_months=tenure)


def test_guarantors_required_added_with_consent_and_checked_on_submit():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "loans.guarantors_required", {"count": 1, "aboveAmount": 10000})
        assert (await _eligibility(db, t, amount="9000"))["guarantors_required"] == 0
        assert (await _eligibility(db, t))["guarantors_required"] == 1
        loan = await db.create_loan(t)
        await db.act(t, "EMP", t.d0)
        await db.app_fails("GUARANTORS_REQUIRED", lambda: LoanService(db.conn).submit_application(loan["id"]))
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["A"])), code="GUARANTOR_IS_BORROWER")
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["B"], consent="")),
                       code="GUARANTOR_CONSENT_REQUIRED")
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (loan["id"], Jsonb({"non_member_name": "Ravi", "consent_type": "SIGNATURE"})),
                       code="GUARANTOR_DETAILS_REQUIRED")
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["APPLIED"])), code="GUARANTOR_NOT_ELIGIBLE")
        listed = await db.val("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["B"])))
        assert len(listed) == 1 and listed[0]["guaranteed_amount"] == 12000 and listed[0]["guarantor_name"] == "Member B"
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["B"])), code="GUARANTOR_ALREADY_ADDED")
        both = await db.val("SELECT loan.add_guarantor(%s,%s)", (loan["id"], Jsonb({
            "non_member_name": "Ravi", "non_member_mobile": "9000000099", "consent_type": "THUMB_IMPRESSION",
            "guaranteed_amount": "4000"})))
        assert {g["guarantor_name"] for g in both} == {"Member B", "Ravi"}
        removed = await db.val("SELECT loan.remove_guarantor(%s)", (both[1]["id"],))
        assert len(removed) == 1
        await db.submit(t, loan["id"])
        assert await db.status(loan["id"]) == "UNDER_APPROVAL"
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["C"])), code="APPLICATION_NOT_EDITABLE")
    run_db(scenario)


def test_guarantor_limit_and_release_when_loan_ends():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "loans.guarantor_limits", {"maxActiveGuarantees": 1})
        first = await db.create_loan(t, "A")
        await db.act(t, "EMP", t.d0)
        await db.val("SELECT loan.add_guarantor(%s,%s)", (first["id"], _g(t.members["C"])))
        second = await db.create_loan(t, "B")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.add_guarantor(%s,%s)", (second["id"], _g(t.members["C"])), code="GUARANTOR_LIMIT_REACHED")
        await db.val("SELECT loan.withdraw_application(%s,'Not needed')", (first["id"],))
        assert await db.val("SELECT status FROM loan.loan_guarantor WHERE loan_id=%s", (first["id"],)) == "RELEASED"
        await db.val("SELECT loan.add_guarantor(%s,%s)", (second["id"], _g(t.members["C"])))
    run_db(scenario)


def test_guarantor_replacement_on_running_loan():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.act(t, "EMP", t.d0)
        guarantor = (await db.val("SELECT loan.add_guarantor(%s,%s)", (loan["id"], _g(t.members["B"]))))[0]
        await db.submit(t, loan["id"])
        await db.approve(t, loan["id"])
        disbursement = await db.prepare(t, loan["id"], "12000.00")
        await db.release(t, loan["id"], disbursement["disbursement_id"])
        await db.act(t, "EMP", t.d0 + timedelta(days=3))
        await db.fails("SELECT loan.request_guarantor_replacement(%s,%s,'Moved')", (guarantor["id"], _g(t.members["C"], consent="")),
                       code="GUARANTOR_CONSENT_REQUIRED")
        request = await db.val("SELECT loan.request_guarantor_replacement(%s,%s,'Moved away')", (guarantor["id"], _g(t.members["C"])))
        assert request["status"] == "PENDING"
        await db.fails("SELECT loan.request_guarantor_replacement(%s,%s,'Again')", (guarantor["id"], _g(t.members["C"])),
                       code="REPLACEMENT_ALREADY_PENDING")
        await db.fails("SELECT loan.decide_guarantor_replacement(%s,true)", (request["id"],), code="SOD_SELF_APPROVAL")
        await db.act(t, "MGR", t.d0 + timedelta(days=3))
        done = await db.val("SELECT loan.decide_guarantor_replacement(%s,true,'OK')", (request["id"],))
        assert done["status"] == "APPROVED"
        rows = {r["guarantor_member_id"]: r for r in await db.rows(
            "SELECT guarantor_member_id, status, replaced_by_id, id, guaranteed_amount FROM loan.loan_guarantor WHERE loan_id=%s", (loan["id"],))}
        assert rows[t.members["B"]]["status"] == "REPLACED" and rows[t.members["B"]]["replaced_by_id"] == rows[t.members["C"]]["id"]
        assert rows[t.members["C"]]["status"] == "ACTIVE" and rows[t.members["C"]]["guaranteed_amount"] == D("12000.00")
    run_db(scenario)


def test_age_household_and_member_exposure_limits():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.active_loan(t, "B")
        await db.act(t, None, t.d0)
        await db.conn.execute("UPDATE mbr.member SET date_of_birth=%s WHERE id=%s", (t.d0 - timedelta(days=17 * 366), t.members["A"]))
        await db.conn.execute("""INSERT INTO mbr.member_family (tenant_id, member_id, full_name, relationship, linked_member_id)
                                 VALUES (%s,%s,'Member B','SPOUSE',%s)""", (t.id, t.members["A"], t.members["B"]))
        await db.act(t, "EMP", t.d0)
        result = await _eligibility(db, t)
        assert "AGE_BELOW_MINIMUM" in result["reasons"]
        await db.act(t, None, t.d0)
        await db.conn.execute("UPDATE mbr.member SET date_of_birth=%s WHERE id=%s", (date(t.d0.year - 59, 1, 1), t.members["A"]))
        await db.set_setting(t, "loans.age_limits", {"minAtApplication": 18, "maxAtMaturity": 59})
        await db.set_setting(t, "loans.exposure_limits", {"perMember": 11000, "perHousehold": 20000})
        await db.act(t, "EMP", t.d0)
        result = await _eligibility(db, t)
        assert {"AGE_AT_MATURITY_ABOVE_MAXIMUM", "MEMBER_EXPOSURE_LIMIT_EXCEEDED",
                "HOUSEHOLD_EXPOSURE_LIMIT_EXCEEDED"} <= set(result["reasons"])
        exposure = await db.val("SELECT loan.get_member_exposure(%s,%s)", (t.members["A"], t.loan_types["INTEREST_BEARING"]))
        assert exposure["household_outstanding"] == 12000 and exposure["member_outstanding"] == 0
        assert exposure["overdue_chit_dues"] is False and exposure["overdue_contribution_dues"] is False
        assert (await _eligibility(db, t, "C", amount="10000"))["eligible"] is True
        assert add_months(t.d0, 1)
    run_db(scenario)
