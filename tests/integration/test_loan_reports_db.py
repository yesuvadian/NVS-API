"""Integration tests for the loan reports (scope 23.3), supporting documents and
the sanction letter (gap L8)."""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import pytest
from psycopg.types.json import Jsonb

from app.services.loans import LoanService
from app.services.sanction_letter import render_sanction_letter
from tests.integration.loan_harness import LoanDb, add_months, run_db

pytestmark = pytest.mark.postgres

D = Decimal


def _num(value) -> Decimal:
    return D(str(value))


def test_portfolio_reports_ageing_par_demand_and_lists():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        good = await db.active_loan(t, "A")
        late = await db.active_loan(t, "B")
        due = await db.rows("""SELECT i.due_date, i.principal_due, i.interest_due FROM loan.loan_instalment i
                                 JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id AND s.is_current
                                WHERE i.loan_id=%s ORDER BY i.instalment_no""", (good,))
        for inst in due[:2]:
            await db.repay(t, good, str(inst["principal_due"] + inst["interest_due"]), inst["due_date"])
        on = due[1]["due_date"] + timedelta(days=10)
        await db.daily(t, on)
        assert await db.status(late) == "OVERDUE"
        await db.act(t, "MGR", on)

        outstanding = await db.val("SELECT loan.report_outstanding()")
        assert outstanding["totals"]["loans"] == 2
        assert _num(outstanding["totals"]["outstanding_principal"]) == 24000 - due[0]["principal_due"] - due[1]["principal_due"]
        assert {i["loan_no"] for i in outstanding["items"]} == {
            await db.val("SELECT loan_no FROM loan.loan WHERE id=%s", (good,)),
            await db.val("SELECT loan_no FROM loan.loan WHERE id=%s", (late,))}

        ageing = await db.val("SELECT loan.report_ageing()")
        buckets = {b["bucket"]: b for b in ageing["items"]}
        assert buckets["CURRENT"]["loans"] == 1 and buckets["31-60"]["loans"] == 1
        expected_par30 = round(D(1200000) / _num(outstanding["totals"]["outstanding_principal"]), 2)
        assert _num(ageing["par"]["par30"]) == expected_par30 and _num(ageing["par"]["par60"]) == 0

        overdue = await db.val("SELECT loan.report_overdue_list(1)")
        assert [o["loan_id"] for o in overdue["items"]] == [str(late)]
        assert overdue["items"][0]["days_overdue"] > 30

        due_list = await db.val("SELECT loan.report_due_list(%s,%s)", (due[0]["due_date"], on))
        assert {i["loan_id"] for i in due_list["items"]} == {str(late)} and due_list["totals"]["instalments"] == 2

        period = (due[0]["due_date"], on)
        demand = await db.val("SELECT loan.report_demand_collection(%s,%s)", period)
        two = sum(i["principal_due"] + i["interest_due"] for i in due[:2])
        assert _num(demand["demand"]) == 2 * two
        assert _num(demand["collected_against_demand"]) == two
        assert _num(demand["efficiency"]) == 50
        assert _num(demand["arrears_at_start"]) == 0

        interest = await db.val("SELECT loan.report_interest(%s,%s)", period)
        assert _num(interest["totals"]["interest_due"]) == 2 * (due[0]["interest_due"] + due[1]["interest_due"])
        assert _num(interest["totals"]["interest_collected"]) == due[0]["interest_due"] + due[1]["interest_due"]

        await db.act(t, "EMP", on)
        request = await db.val("SELECT loan.request_restructure(%s,%s)", (late, Jsonb({
            "option": "EXTEND_TENURE", "reason": "Illness", "new_tenure_months": 14})))
        await db.act(t, "MGR", on)
        await db.val("SELECT loan.decide_restructure(%s,true,NULL)", (request["id"],))
        listed = await db.val("SELECT loan.report_restructured_written_off()")
        assert [r["loan_id"] for r in listed["restructured"]] == [str(late)]
        assert listed["restructured"][0]["last_option"] == "EXTEND_TENURE" and listed["written_off"] == []
    run_db(scenario)


def test_guarantor_exposure_report():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        for borrower in ("A", "C"):
            loan = await db.create_loan(t, borrower, "10000.00")
            await db.act(t, "EMP", t.d0)
            await db.val("SELECT loan.add_guarantor(%s,%s)", (loan["id"], Jsonb({
                "guarantor_member_id": str(t.members["B"]), "consent_type": "SIGNATURE"})))
        report = await db.val("SELECT loan.report_guarantor_exposure()")
        assert report["totals"]["guarantors"] == 1 and report["totals"]["guarantees"] == 2
        item = report["items"][0]
        assert item["guarantor_name"] == "Member B" and _num(item["guaranteed_total"]) == 20000
        assert len(item["loans"]) == 2
    run_db(scenario)


def test_required_documents_are_checked_on_submit():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.conn.execute("UPDATE loan.loan_type SET required_documents='[\"ID_PROOF\"]' WHERE id=%s",
                              (t.loan_types["INTEREST_BEARING"],))
        loan = await db.create_loan(t)
        await db.act(t, "EMP", t.d0)
        assert await db.val("SELECT loan.missing_documents(%s)", (loan["id"],)) == ["ID_PROOF"]
        error = await db.app_fails("DOCUMENTS_REQUIRED", lambda: LoanService(db.conn).submit_application(loan["id"]))
        assert error.details == {"missing": ["ID_PROOF"]}
        doc = {"document_type": "id_proof", "file_name": "aadhaar.pdf", "storage_key": "tenant/loan/aadhaar.pdf",
               "content_type": "application/pdf", "size_bytes": 1024}
        await db.fails("SELECT loan.add_loan_document(%s,%s)", (loan["id"], Jsonb({**doc, "document_type": "PASSPORTX"})),
                       code="DOCUMENT_TYPE_INVALID")
        await db.fails("SELECT loan.add_loan_document(%s,%s)", (loan["id"], Jsonb({**doc, "storage_key": ""})),
                       code="DOCUMENT_DETAILS_REQUIRED")
        await db.fails("SELECT loan.add_loan_document(gen_random_uuid(),%s)", (Jsonb(doc),), code="LOAN_NOT_FOUND")
        listed = await db.val("SELECT loan.add_loan_document(%s,%s)", (loan["id"], Jsonb(doc)))
        assert listed[0]["document_type"] == "ID_PROOF" and listed[0]["document_type_name"] == "Identity proof"
        extra = await db.val("SELECT loan.add_loan_document(%s,%s)", (loan["id"], Jsonb({**doc, "document_type": "PHOTO"})))
        assert len(await db.val("SELECT loan.remove_loan_document(%s)", (extra[1]["id"],))) == 1
        await db.submit(t, loan["id"])
        assert await db.status(loan["id"]) == "UNDER_APPROVAL"
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.remove_loan_document(%s)", (listed[0]["id"],), code="APPLICATION_NOT_EDITABLE")
        await db.fails("SELECT loan.remove_loan_document(gen_random_uuid())", code="DOCUMENT_NOT_FOUND")
    run_db(scenario)


def test_sanction_letter_after_approval_and_schedule_after_disbursement():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        draft = await db.create_loan(t, "B")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.sanction_letter(%s)", (draft["id"],), code="LOAN_NOT_APPROVED")
        await db.fails("SELECT loan.sanction_letter(gen_random_uuid())", code="LOAN_NOT_FOUND")
        await db.conn.execute("UPDATE mbr.member SET full_name='Member <b>A</b>' WHERE id=%s", (t.members["A"],))
        loan_id = await db.approved_loan(t)
        await db.act(t, "EMP", t.d0)
        letter = await db.val("SELECT loan.sanction_letter(%s)", (loan_id,))
        assert _num(letter["loan"]["approved_amount"]) == 12000 and letter["schedule"] == []
        assert letter["nominees"] == [{"name": "Nominee A", "relationship": "SPOUSE"}]
        assert letter["approved_by"] == "Test MGR"
        html = render_sanction_letter(letter)
        assert letter["loan"]["loan_no"] in html and "Member &lt;b&gt;A&lt;/b&gt;" in html and "<b>A</b>" not in html
        assert "issued when the loan is disbursed" in html
        prepared = await db.prepare(t, loan_id, "12000.00")
        await db.release(t, loan_id, prepared["disbursement_id"])
        await db.act(t, "EMP", t.d0)
        letter = await db.val("SELECT loan.sanction_letter(%s)", (loan_id,))
        assert len(letter["schedule"]) == 12
        assert sum(_num(i["principal"]) for i in letter["schedule"]) == 12000
        assert "12,000.00" in render_sanction_letter(letter)
    run_db(scenario)
