"""Integration tests for the loan servicing additions (functional gap review).

Default settlement and cooling-off, allocation order, late fees, overpayment
with schedule regeneration, recovery cases, waivers, cooling-off override,
write-off and notifications. Same harness and amounts as
test_loan_module_db.py: 12,000 over 12 months at 12 % flat = 1,000 + 120 a month.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

import pytest

from tests.integration.loan_harness import LoanDb, add_months, run_db

pytestmark = pytest.mark.postgres

D = Decimal


async def _member(db: LoanDb, member_id):
    return await db.row("SELECT loan_eligibility, cooling_off_until FROM mbr.member WHERE id=%s", (member_id,))


# =============================================================================
# P1-1 Defaulted loans can be cleared
# =============================================================================
def test_default_settlement_quote_approve_collect():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        await db.act(t, "EMP", on)
        quote = await db.val("SELECT loan.quote_early_settlement(%s)", (loan_id,))
        assert quote["settlement_type"] == "DEFAULT" and quote["interest_policy"] == "A_ALL_SCHEDULED_INTEREST"
        assert quote["principal_outstanding"] == 12000 and quote["interest_component"] == 1440
        assert quote["penalty"] == 240 and quote["settlement_charge"] == 0
        assert quote["total_payable"] == 13680 and quote["approval_required"] is True
        await db.fails("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],), code="SETTLEMENT_NOT_APPROVED")
        await db.fails("SELECT loan.approve_early_settlement(%s)", (quote["id"],), code="SETTLEMENT_APPROVER_IS_CREATOR")
        await db.act(t, "MGR", on)
        await db.val("SELECT loan.approve_early_settlement(%s,'Agreed')", (quote["id"],))
        await db.act(t, "EMP", on)
        paid = await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        assert paid["loan_status"] == "SETTLED" and paid["cooling_off_until"] == str(add_months(on, 6))
        assert await db.status(loan_id) == "SETTLED"
        assert await db.val("SELECT status_reason FROM loan.loan WHERE id=%s", (loan_id,)) == "Default settlement"
        default = await db.row("SELECT status, settled_on, loan_settlement_id, cooling_off_until FROM loan.loan_default "
                               "WHERE loan_id=%s", (loan_id,))
        assert (default["status"], default["settled_on"], str(default["loan_settlement_id"])) == ("SETTLED", on, quote["id"])
        member = await _member(db, t.members["A"])
        assert member["loan_eligibility"] == "COOLING_OFF" and member["cooling_off_until"] == add_months(on, 6)
        rep = await db.row("SELECT repayment_type, amount, penalty_amount FROM loan.loan_repayment WHERE loan_id=%s", (loan_id,))
        assert (rep["repayment_type"], rep["amount"], rep["penalty_amount"]) == ("DEFAULT_SETTLEMENT", D("13680.00"), D("240.00"))
        assert await db.val("SELECT purpose FROM acct.cash_receipt WHERE id=%s", (paid["cash_receipt_id"],)) == "LOAN_DEFAULT_SETTLEMENT"
        case = await db.row("SELECT status, closed_on FROM loan.recovery_case WHERE loan_id=%s", (loan_id,))
        assert case["status"] == "SETTLEMENT_RECEIVED" and case["closed_on"] == on
        assert await db.val("SELECT status FROM loan.loan_charge WHERE loan_id=%s AND charge_type='DEFAULT_PENALTY'", (loan_id,)) == "PAID"
        assert any("fully settled" in m["body"] for m in await db.messages(loan_id))
    run_db(scenario)


def test_default_settlement_rules_and_no_cooling_off():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        # Policy B and no approval for this loan; tenant without a cooling-off period
        await db.set_rule(loan_id, "DEFAULT_SETTLEMENT", {"value": {"interestPolicy": "B_INTEREST_TO_DATE", "approvalRequired": False}})
        await db.set_setting(t, "loans.cooling_off", {"months": 0})
        await db.act(t, "EMP", on)
        quote = await db.val("SELECT loan.quote_early_settlement(%s)", (loan_id,))
        assert quote["interest_policy"] == "B_INTEREST_TO_DATE" and quote["interest_component"] < 1440
        assert quote["approval_required"] is False
        paid = await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        assert paid["cooling_off_until"] is None
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "REINSTATED"
    run_db(scenario)


def test_default_settlement_with_interest_waiver():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.quote_early_settlement(%s, 1441, 'Hardship')", (loan_id,), code="INVALID_WAIVER_AMOUNT")
        await db.fails("SELECT loan.quote_early_settlement(%s, -1, 'Hardship')", (loan_id,), code="INVALID_WAIVER_AMOUNT")
        await db.fails("SELECT loan.quote_early_settlement(%s, 440)", (loan_id,), code="REASON_REQUIRED")
        quote = await db.val("SELECT loan.quote_early_settlement(%s, 440, 'Hardship')", (loan_id,))
        assert quote["waiver"] == 440 and quote["total_payable"] == 13240 and quote["approval_required"] is True
        await db.act(t, "MGR", on)
        await db.val("SELECT loan.approve_early_settlement(%s,'Agreed')", (quote["id"],))
        await db.act(t, "EMP", on)
        paid = await db.val("SELECT loan.collect_early_settlement(%s,'CASH')", (quote["id"],))
        assert paid["loan_status"] == "SETTLED"
        rep = await db.row("SELECT amount, interest_amount FROM loan.loan_repayment WHERE loan_id=%s", (loan_id,))
        assert (rep["amount"], rep["interest_amount"]) == (D("13240.00"), D("1000.00"))
    run_db(scenario)


def test_defaulted_loan_paid_off_by_repayments_is_settled():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        # the whole outstanding is payable on a defaulted loan; penalty first
        first = await db.repay(t, loan_id, "1240.00", on)
        assert first["penalty_amount"] == D("240.00") and first["loan_status"] == "DEFAULTED"
        await db.fails("SELECT loan.collect_repayment(%s,12440.01,'CASH')", (loan_id,), code="REPAYMENT_EXCEEDS_DUES")
        last = await db.repay(t, loan_id, "12440.00", on)
        assert last["loan_status"] == "SETTLED" and last["cooling_off_until"] == str(add_months(on, 6))
        assert await db.val("SELECT status FROM loan.loan_default WHERE loan_id=%s", (loan_id,)) == "SETTLED"
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "COOLING_OFF"
    run_db(scenario)


def test_member_with_two_defaults_stays_restricted_until_both_settled():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "loans.max_concurrent_loans", 3)
        first = await db.active_loan(t, "A")
        second = await db.active_loan(t, "A", amount="6000.00")
        on = add_months(t.d0, 3) + timedelta(days=1)
        await db.daily(t, on)
        assert await db.status(first) == "DEFAULTED" and await db.status(second) == "DEFAULTED"
        await db.repay(t, first, "13680.00", on)
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "RESTRICTED"
        outstanding = await db.val("SELECT 6000 + 720 + 120 ")  # principal + interest + 2 % penalty
        await db.repay(t, second, str(outstanding), on)
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "COOLING_OFF"
    run_db(scenario)


# =============================================================================
# P1-2 Cooling-off ends
# =============================================================================
def test_cooling_off_ends_and_member_can_borrow_again():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        await db.repay(t, loan_id, "13680.00", on)
        until = add_months(on, 6)
        await db.conn.execute(
            "UPDATE mbr.member SET loan_eligibility='COOLING_OFF', cooling_off_until=%s WHERE id=%s",
            (t.d0 + timedelta(days=20), t.members["B"]))
        result = await db.daily(t, until)
        assert result["cooling_off_ended"] == 1                      # B (no default history) only
        assert (await _member(db, t.members["B"]))["loan_eligibility"] == "ELIGIBLE"
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "COOLING_OFF"   # last day still cooling off
        result = await db.daily(t, until + timedelta(days=1))
        assert result["cooling_off_ended"] == 1
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "REINSTATED"
        assert await db.val("SELECT count(*) FROM notif.notification_message WHERE entity_id=%s AND body ILIKE '%%cooling-off%%'",
                            (t.members["A"],)) == 1
        runs = await db.val("SELECT details FROM platform.job_run WHERE tenant_id=%s AND job_code='COOLING_OFF_END' AND working_date=%s",
                            (t.id, until + timedelta(days=1)))
        assert runs["cooling_off_ended"] == 1
        await db.act(t, "EMP", until + timedelta(days=1))
        from app.services.loans import LoanService
        quote = await LoanService(db.conn).eligibility(member_id=t.members["A"], loan_type_id=t.loan_types["INTEREST_BEARING"],
                                                       requested_amount=D("12000"), requested_tenure_months=12)
        assert "MEMBER_IN_COOLING_OFF" not in quote["reasons"] and "MEMBER_COOLING_OFF" not in quote["reasons"]
    run_db(scenario)


def test_cooling_off_does_not_end_with_open_default():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        await db.conn.execute("UPDATE mbr.member SET loan_eligibility='COOLING_OFF', cooling_off_until=%s WHERE id=%s",
                              (on - timedelta(days=1), t.members["A"]))
        assert (await db.daily(t, on + timedelta(days=1)))["cooling_off_ended"] == 0
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "COOLING_OFF"
    run_db(scenario)


# =============================================================================
# P1-4 Allocation order and late fees
# =============================================================================
def test_late_fee_assessed_and_collected_first():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.set_rule(loan_id, "LATE_FEE", {"value": {"enabled": True, "graceDays": 2, "type": "fixed", "amount": 100}})
        due1 = add_months(t.d0, 1)
        assert (await db.daily(t, due1 + timedelta(days=2)))["late_fees_assessed"] == 0      # within grace
        result = await db.daily(t, due1 + timedelta(days=3))
        assert result["late_fees_assessed"] == 1 and result["marked_overdue"] == 1
        assert (await db.daily(t, due1 + timedelta(days=3)))["late_fees_assessed"] == 0       # once per instalment
        charge = await db.row("SELECT amount, loan_instalment_id FROM loan.loan_charge WHERE loan_id=%s AND charge_type='LATE_FEE'", (loan_id,))
        assert charge["amount"] == D("100.00")
        assert await db.val("SELECT late_fee_assessed FROM loan.loan_instalment WHERE id=%s", (charge["loan_instalment_id"],)) == D("100.00")
        paid = await db.repay(t, loan_id, "150.00", due1 + timedelta(days=3))
        assert (paid["late_fee_amount"], paid["interest_amount"], paid["principal_amount"]) == (D("100.00"), D("50.00"), D("0.00"))
        assert paid["repayment_type"] == "PARTIAL"
        lines = await db.rows("SELECT l.component, a.code FROM acct.cash_receipt_line l JOIN acct.account a ON a.id=l.account_id "
                              "WHERE l.cash_receipt_id=%s ORDER BY l.line_no", (paid["cash_receipt_id"],))
        assert [(r["component"], r["code"]) for r in lines] == [("INTEREST", "4110"), ("LATE_FEE", "4130")]
        assert await db.val("SELECT status FROM loan.loan_charge WHERE loan_id=%s AND charge_type='LATE_FEE'", (loan_id,)) == "PAID"
        assert await db.val("SELECT late_fee_paid FROM loan.loan_instalment WHERE id=%s", (charge["loan_instalment_id"],)) == D("100.00")
    run_db(scenario)


def test_late_fee_percent_monthly_with_cap():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.set_rule(loan_id, "DEFAULT_AFTER_MONTHS", {"value": 6})
        await db.set_rule(loan_id, "LATE_FEE", {"value": {"enabled": True, "graceDays": 0, "type": "percent", "value": 10,
                                                          "frequency": "MONTHLY", "cap": 150}})
        due1 = add_months(t.d0, 1)
        await db.daily(t, due1 + timedelta(days=1))
        assert await db.val("SELECT sum(amount) FROM loan.loan_charge WHERE loan_id=%s", (loan_id,)) == D("112.00")  # 10 % of 1,120
        await db.daily(t, due1 + timedelta(days=20))
        assert await db.val("SELECT count(*) FROM loan.loan_charge WHERE loan_id=%s", (loan_id,)) == 1   # not a month yet
        await db.daily(t, add_months(due1, 1) + timedelta(days=1))
        fees = await db.rows("SELECT i.instalment_no, c.amount FROM loan.loan_charge c JOIN loan.loan_instalment i ON i.id=c.loan_instalment_id "
                             "WHERE c.loan_id=%s ORDER BY i.instalment_no, c.assessed_on", (loan_id,))
        assert [(r["instalment_no"], r["amount"]) for r in fees] == [(1, D("112.00")), (1, D("38.00")), (2, D("112.00"))]
    run_db(scenario)


def test_late_fee_disabled_or_deceased_member_gets_none():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        plain = await db.active_loan(t, "A")
        deceased = await db.active_loan(t, "B")
        await db.set_rule(deceased, "LATE_FEE", {"value": {"enabled": True, "graceDays": 0, "type": "fixed", "amount": 50}})
        await db.conn.execute("UPDATE mbr.member SET status='DECEASED' WHERE id=%s", (t.members["B"],))
        result = await db.daily(t, add_months(t.d0, 3) + timedelta(days=1))
        assert result["late_fees_assessed"] == 0 and result["skipped_deceased"] == 1
        assert await db.status(deceased) == "ACTIVE" and await db.status(plain) == "DEFAULTED"
    run_db(scenario)


def test_configured_allocation_order_principal_first():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        await db.set_rule(loan_id, "PAYMENT_ALLOCATION", {"value": {"order": ["overdue_principal", "OVERDUE_INTEREST", "bogus"]}})
        paid = await db.repay(t, loan_id, "1050.00", add_months(t.d0, 1) + timedelta(days=1))
        assert (paid["principal_amount"], paid["interest_amount"]) == (D("1000.00"), D("50.00"))
        order = await db.val("SELECT loan.allocation_order(rule_snapshot) FROM loan.loan WHERE id=%s", (loan_id,))
        assert order == ["OVERDUE_PRINCIPAL", "OVERDUE_INTEREST", "LATE_FEE", "PENALTY", "CURRENT_INTEREST", "CURRENT_PRINCIPAL"]
    run_db(scenario)


def test_advance_payment_of_next_instalment():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        paid = await db.repay(t, loan_id, "1120.00", t.d0 + timedelta(days=10))
        assert paid["repayment_type"] == "REGULAR" and paid["excess_to_principal"] == 0
        first = await db.row("SELECT status, paid_on FROM loan.loan_instalment WHERE loan_id=%s AND instalment_no=1", (loan_id,))
        assert first["status"] == "PAID"
        assert (await db.daily(t, add_months(t.d0, 1) + timedelta(days=1)))["marked_overdue"] == 0
    run_db(scenario)


# =============================================================================
# P1-3 Overpayment reduces principal and regenerates the schedule
# =============================================================================
def test_overpayment_reduces_instalment_and_recalculates_interest():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        paid = await db.repay(t, loan_id, "2220.00", due1)
        assert paid["repayment_type"] == "LUMP_SUM" and paid["excess_to_principal"] == D("1100.00")
        assert paid["principal_amount"] == D("2100.00") and paid["outstanding_principal"] == D("9900.00")
        assert paid["new_schedule_id"]
        schedules = await db.rows("SELECT schedule_version, reason, is_current, principal_basis, total_interest FROM loan.loan_schedule "
                                  "WHERE loan_id=%s ORDER BY schedule_version", (loan_id,))
        assert [(s["schedule_version"], s["reason"], s["is_current"]) for s in schedules] == [(1, "ORIGINAL", False), (2, "PREPAYMENT", True)]
        assert schedules[1]["principal_basis"] == D("9900.00") and schedules[1]["total_interest"] == D("120.00") + D("1089.00")
        rows = await db.rows("SELECT instalment_no, due_date, principal_due, interest_due, status FROM loan.loan_instalment "
                             "WHERE loan_schedule_id=%s ORDER BY instalment_no", (paid["new_schedule_id"],))
        assert len(rows) == 12 and rows[0]["status"] == "PAID"
        assert {(r["principal_due"], r["interest_due"]) for r in rows[1:]} == {(D("900.00"), D("99.00"))}
        assert [r["due_date"] for r in rows] == [add_months(t.d0, n) for n in range(1, 13)]
        alloc = await db.rows("SELECT component, amount FROM loan.loan_repayment_allocation WHERE loan_repayment_id=%s ORDER BY seq",
                              (paid["repayment_id"],))
        assert alloc[-1]["component"] == "EXCESS_PRINCIPAL" and alloc[-1]["amount"] == D("1100.00")
        assert await db.val("SELECT instalment_amount FROM loan.loan WHERE id=%s", (loan_id,)) == D("999.00")
        # the next instalment is paid against the new schedule
        nxt = await db.repay(t, loan_id, "999.00", add_months(t.d0, 2))
        assert (nxt["principal_amount"], nxt["interest_amount"]) == (D("900.00"), D("99.00"))
        sched = await db.val("SELECT loan.get_schedule(%s)", (loan_id,))
        assert sched is not None
    run_db(scenario)


def test_overpayment_reduce_tenure_and_keep_interest_rules():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        tenure = await db.active_loan(t, "A")
        await db.set_rule(tenure, "OVERPAYMENT", {"value": {"excessReducesPrincipal": True, "regenerate": "REDUCE_TENURE",
                                                            "interestOnReducedPrincipal": True}})
        keep = await db.active_loan(t, "B")
        await db.set_rule(keep, "OVERPAYMENT", {"value": {"regenerate": "REDUCE_INSTALMENT", "interestOnReducedPrincipal": False}})
        due1 = add_months(t.d0, 1)
        paid = await db.repay(t, tenure, "2220.00", due1)
        rows = await db.rows("SELECT principal_due, interest_due FROM loan.loan_instalment WHERE loan_schedule_id=%s AND status='DUE' "
                             "ORDER BY instalment_no", (paid["new_schedule_id"],))
        assert len(rows) == 10 and sum(r["principal_due"] for r in rows) == D("9900.00")
        assert sum(r["interest_due"] for r in rows) == D("990.00")          # 9,900 x 12 % x 10/12
        assert await db.val("SELECT maturity_date FROM loan.loan WHERE id=%s", (tenure,)) == add_months(t.d0, 11)
        paid = await db.repay(t, keep, "2220.00", due1)
        rows = await db.rows("SELECT interest_due FROM loan.loan_instalment WHERE loan_schedule_id=%s AND status='DUE'", (paid["new_schedule_id"],))
        assert len(rows) == 11 and sum(r["interest_due"] for r in rows) == D("1320.00")
    run_db(scenario)


def test_overpayment_on_interest_free_loan():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t, loan_type="INTEREST_FREE")
        paid = await db.repay(t, loan_id, "1500.00", add_months(t.d0, 1))
        rows = await db.rows("SELECT principal_due, interest_due FROM loan.loan_instalment WHERE loan_schedule_id=%s AND status='DUE'",
                             (paid["new_schedule_id"],))
        assert len(rows) == 11 and sum(r["principal_due"] for r in rows) == D("10500.00")
        assert {r["interest_due"] for r in rows} == {D("0.00")}
    run_db(scenario)


# =============================================================================
# P2-8 Recovery cases
# =============================================================================
def test_recovery_case_opened_contacts_and_escalation():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        case = await db.row("SELECT id, case_no, status, assigned_to, escalation_level FROM loan.recovery_case WHERE loan_id=%s", (loan_id,))
        assert case["status"] == "PENDING" and case["assigned_to"] == t.users["EMP"] and case["case_no"].startswith("REC")
        assert any(m["recipient_type"] == "MEMBER" and "default" in m["body"] for m in await db.messages(loan_id))
        await db.act(t, "EMP", on)
        details = {"method": "CALL", "person_type": "MEMBER", "outcome": "Will pay next week",
                   "promise_date": str(on + timedelta(days=7)), "promise_amount": "5000"}
        got = await db.val("SELECT loan.log_recovery_contact(%s,%s::jsonb)", (case["id"], __import__("json").dumps(details)))
        assert got["status"] == "PROMISE_TO_PAY" and got["next_follow_up"] == str(on + timedelta(days=7))
        assert len(got["contacts"]) == 1
        await db.fails("SELECT loan.log_recovery_contact(%s,'{\"method\":\"CALL\"}'::jsonb)", (case["id"],), code="RECOVERY_OUTCOME_REQUIRED")
        await db.fails("SELECT loan.log_recovery_contact(%s,%s::jsonb)",
                       (case["id"], '{"method":"CALL","outcome":"x","promise_date":"2000-01-01"}'), code="PROMISE_DATE_PAST")
        await db.fails("SELECT loan.log_recovery_contact(%s,'{\"outcome\":\"x\"}'::jsonb)", (uuid4(),), code="RECOVERY_CASE_NOT_FOUND")
        await db.fails("SELECT loan.set_recovery_status(%s,'WRITTEN_OFF','x')", (case["id"],), code="INVALID_RECOVERY_STATUS")
        await db.fails("SELECT loan.set_recovery_status(%s,'LEGAL_NOTICE','')", (case["id"],), code="REASON_REQUIRED")
        await db.fails("SELECT loan.set_recovery_status(%s,'EXCEPTION_APPROVED','x')", (case["id"],), code="APPROVER_ROLE_REQUIRED")
        got = await db.val("SELECT loan.set_recovery_status(%s,'LEGAL_NOTICE','Notice sent by post')", (case["id"],))
        assert got["status"] == "LEGAL_NOTICE" and "LEGAL_NOTICE" in {c["method"] for c in got["contacts"]}
        # escalation: promise not yet due holds it back; 30 days after opening -> Manager; 30 more -> Leadership
        assert (await db.daily(t, on + timedelta(days=29)))["recovery_cases_escalated"] == 0
        assert (await db.daily(t, on + timedelta(days=30)))["recovery_cases_escalated"] == 1
        case = await db.row("SELECT escalation_level, assigned_to, escalated_at FROM loan.recovery_case WHERE loan_id=%s", (loan_id,))
        assert case["escalation_level"] == "MANAGER" and case["assigned_to"] == t.users["MGR"]
        assert (await db.daily(t, on + timedelta(days=59)))["recovery_cases_escalated"] == 0
        assert (await db.daily(t, on + timedelta(days=60)))["recovery_cases_escalated"] == 1
        case = await db.row("SELECT escalation_level, assigned_to FROM loan.recovery_case WHERE loan_id=%s", (loan_id,))
        assert case["escalation_level"] == "LEADERSHIP" and case["assigned_to"] == t.users["LDR"]
        await db.act(t, "MGR", on + timedelta(days=60))
        listed = await db.val("SELECT loan.list_recovery_cases()")
        assert [c["loan_id"] for c in listed] == [str(loan_id)]
        assert await db.val("SELECT loan.list_recovery_cases('SETTLEMENT_RECEIVED')") == []
        got = await db.val("SELECT loan.assign_recovery_case(%s,%s)",
                           ((await db.val("SELECT id FROM loan.recovery_case WHERE loan_id=%s", (loan_id,))), t.users["EMP2"]))
        assert got["assigned_to"] == str(t.users["EMP2"])
        await db.fails("SELECT loan.assign_recovery_case(%s,%s)", (uuid4(), t.users["EMP2"]), code="RECOVERY_CASE_NOT_FOUND")
        await db.fails("SELECT loan.assign_recovery_case(%s,%s)", (uuid4(), uuid4()), code="USER_NOT_FOUND")
    run_db(scenario)


# =============================================================================
# P2-9 Waivers
# =============================================================================
def test_late_fee_and_penalty_waivers():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        charge = await db.val("SELECT id FROM loan.loan_charge WHERE loan_id=%s AND charge_type='DEFAULT_PENALTY'", (loan_id,))
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.request_waiver(%s,'PENALTY',%s,300,'Hardship')", (loan_id, charge), code="INVALID_WAIVER_AMOUNT")
        await db.fails("SELECT loan.request_waiver(%s,'PENALTY',%s,100,'')", (loan_id, charge), code="REASON_REQUIRED")
        await db.fails("SELECT loan.request_waiver(%s,'PRINCIPAL',NULL,100,'x')", (loan_id,), code="WAIVER_NOT_ALLOWED")
        await db.fails("SELECT loan.request_waiver(%s,'LATE_FEE',%s,100,'x')", (loan_id, charge), code="WAIVER_TARGET_NOT_OPEN")
        waiver = await db.val("SELECT loan.request_waiver(%s,'PENALTY',%s,240,'Hardship')", (loan_id, charge))
        await db.fails("SELECT loan.request_waiver(%s,'PENALTY',%s,100,'again')", (loan_id, charge), code="WAIVER_ALREADY_PENDING")
        await db.fails("SELECT loan.decide_waiver(%s,true)", (waiver["id"],), code="SOD_SELF_APPROVAL")
        await db.act(t, "EMP2", on)
        await db.fails("SELECT loan.decide_waiver(%s,true)", (waiver["id"],), code="APPROVER_ROLE_REQUIRED")
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.decide_waiver(%s,false,'')", (waiver["id"],), code="APPROVAL_REASON_REQUIRED")
        got = await db.val("SELECT loan.decide_waiver(%s,true,'ok')", (waiver["id"],))
        assert got["status"] == "APPROVED"
        await db.fails("SELECT loan.decide_waiver(%s,true)", (waiver["id"],), code="REQUEST_CLOSED")
        await db.fails("SELECT loan.decide_waiver(%s,true)", (uuid4(),), code="WAIVER_NOT_FOUND")
        assert await db.val("SELECT status FROM loan.loan_charge WHERE id=%s", (charge,)) == "WAIVED"
        # the waived penalty is no longer payable
        await db.act(t, "EMP", on)
        quote = await db.val("SELECT loan.quote_early_settlement(%s)", (loan_id,))
        assert quote["penalty"] == 0 and quote["total_payable"] == 13440
        assert len(await db.val("SELECT loan.list_waivers(%s)", (loan_id,))) == 1
    run_db(scenario)


def test_application_fee_waiver():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.conn.execute(
            """INSERT INTO loan.loan_application_fee (tenant_id, loan_id, fee_basis, fee_amount, collect_timing, status)
               VALUES (%s,%s,'FIXED',200,'BEFORE_SUBMISSION','PENDING')""", (t.id, loan["id"]))
        fee = await db.row("SELECT status, fee_amount FROM loan.loan_application_fee WHERE loan_id=%s", (loan["id"],))
        assert fee["status"] == "PENDING"
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.request_waiver(%s,'APPLICATION_FEE',NULL,1,'x')", (loan["id"],), code="INVALID_WAIVER_AMOUNT")
        waiver = await db.val("SELECT loan.request_waiver(%s,'APPLICATION_FEE',NULL,%s,'Widow, fee waived')", (loan["id"], fee["fee_amount"]))
        await db.act(t, "MGR", t.d0)
        await db.val("SELECT loan.decide_waiver(%s,true)", (waiver["id"],))
        assert await db.val("SELECT status FROM loan.loan_application_fee WHERE loan_id=%s", (loan["id"],)) == "WAIVED"
        submitted = await db.submit(t, loan["id"])
        assert submitted["status"] in ("UNDER_APPROVAL", "SUBMITTED")
    run_db(scenario)


# =============================================================================
# P2-10 Cooling-off override
# =============================================================================
def test_cooling_off_override():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        await db.act(t, "EMP", on)
        await db.fails("SELECT loan.request_cooling_off_override(%s,'x')", (t.members["B"],), code="OVERRIDE_NOT_NEEDED")
        await db.fails("SELECT loan.request_cooling_off_override(%s,'x')", (uuid4(),), code="MEMBER_NOT_FOUND")
        req = await db.val("SELECT loan.request_cooling_off_override(%s,'Medical emergency')", (t.members["A"],))
        assert req["previous_eligibility"] == "RESTRICTED"
        await db.fails("SELECT loan.request_cooling_off_override(%s,'again')", (t.members["A"],), code="OVERRIDE_ALREADY_PENDING")
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.decide_cooling_off_override(%s,true)", (req["id"],), code="OPEN_DEFAULT_EXISTS")
        await db.repay(t, loan_id, "13680.00", on)
        await db.act(t, "MGR", on)
        got = await db.val("SELECT loan.decide_cooling_off_override(%s,true,NULL,'Approved in meeting')", (req["id"],))
        assert got["status"] == "APPROVED" and got["valid_until"] == str(on + timedelta(days=30))
        member = await _member(db, t.members["A"])
        assert member["loan_eligibility"] == "REINSTATED" and member["cooling_off_until"] is None
        assert await db.val("SELECT count(*) FROM loan.loan_default WHERE loan_id=%s", (loan_id,)) == 1    # history kept
        await db.fails("SELECT loan.decide_cooling_off_override(%s,true)", (uuid4(),), code="OVERRIDE_NOT_FOUND")
    run_db(scenario)


# =============================================================================
# P2-11 Write-off and later recovery
# =============================================================================
def test_write_off_and_bad_debt_recovery():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.propose_write_off(%s,'')", (loan_id,), code="REASON_REQUIRED")
        proposal = await db.val("SELECT loan.propose_write_off(%s,'Member untraceable')", (loan_id,))
        assert proposal["principal_amount"] == 12000 and proposal["status"] == "PROPOSED"
        await db.fails("SELECT loan.propose_write_off(%s,'again')", (loan_id,), code="WRITE_OFF_ALREADY_PROPOSED")
        await db.fails("SELECT loan.decide_write_off(%s,true)", (proposal["id"],), code="SOD_SELF_APPROVAL")
        await db.act(t, "ACC", on)
        await db.fails("SELECT loan.decide_write_off(%s,true)", (proposal["id"],), code="APPROVER_ROLE_REQUIRED")
        await db.act(t, "LDR", on)
        got = await db.val("SELECT loan.decide_write_off(%s,true,'Approved')", (proposal["id"],))
        assert got["status"] == "POSTED" and got["loan_status"] == "WRITTEN_OFF"
        lines = await db.rows("SELECT a.code, l.debit, l.credit FROM acct.journal_line l JOIN acct.account a ON a.id=l.account_id "
                              "WHERE l.journal_id=%s ORDER BY l.line_no", (got["journal_id"],))
        assert (lines[0]["code"], lines[0]["debit"]) == ("5510", D("12000.00")) and lines[1]["credit"] == D("12000.00")
        assert await db.val("SELECT status FROM loan.recovery_case WHERE loan_id=%s", (loan_id,)) == "WRITTEN_OFF"
        assert await db.val("SELECT status FROM loan.loan_default WHERE loan_id=%s", (loan_id,)) == "WRITTEN_OFF"
        assert (await _member(db, t.members["A"]))["loan_eligibility"] == "RESTRICTED"
        await db.fails("SELECT loan.collect_repayment(%s,100,'CASH')", (loan_id,), code="LOAN_NOT_OPEN")
        await db.act(t, "EMP", on)
        rec = await db.val("SELECT loan.collect_written_off_recovery(%s,2000,'CASH')", (loan_id,))
        assert rec["recovered_total"] == 2000
        code = await db.val("SELECT a.code FROM acct.cash_receipt_line l JOIN acct.account a ON a.id=l.account_id WHERE l.cash_receipt_id=%s",
                            (rec["cash_receipt_id"],))
        assert code == "4150"
        await db.fails("SELECT loan.collect_written_off_recovery(%s,10000.01,'CASH')", (loan_id,), code="REPAYMENT_EXCEEDS_DUES")
        other = await db.active_loan(t, "B")
        await db.fails("SELECT loan.collect_written_off_recovery(%s,10,'CASH')", (other,), code="LOAN_NOT_WRITTEN_OFF")
    run_db(scenario)


def test_write_off_reject_and_stale():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id, on = await db.defaulted_loan(t)
        approved = await db.approved_loan(t, "B")
        await db.act(t, "MGR", on)
        await db.fails("SELECT loan.propose_write_off(%s,'x')", (approved,), code="WRITE_OFF_NOT_ALLOWED")
        first = await db.val("SELECT loan.propose_write_off(%s,'x')", (loan_id,))
        await db.act(t, "LDR", on)
        await db.fails("SELECT loan.decide_write_off(%s,false)", (first["id"],), code="APPROVAL_REASON_REQUIRED")
        assert (await db.val("SELECT loan.decide_write_off(%s,false,'Keep trying')", (first["id"],)))["status"] == "REJECTED"
        await db.act(t, "MGR", on)
        second = await db.val("SELECT loan.propose_write_off(%s,'y')", (loan_id,))
        await db.repay(t, loan_id, "2000.00", on)          # penalty, all interest, then 320 principal
        await db.act(t, "LDR", on)
        await db.fails("SELECT loan.decide_write_off(%s,true)", (second["id"],), code="WRITE_OFF_STALE")
        await db.fails("SELECT loan.decide_write_off(%s,true)", (uuid4(),), code="WRITE_OFF_NOT_FOUND")
    run_db(scenario)


# =============================================================================
# Notifications
# =============================================================================
def test_notifications_suppressed_and_quiet_hours():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t, "A")
        await db.conn.execute("INSERT INTO mbr.member_consent (tenant_id, member_id, channel, purpose, opted_in) VALUES (%s,%s,'SMS','NON_ESSENTIAL',false)",
                              (t.id, t.members["A"]))
        await db.act(t, None, add_months(t.d0, 1) - timedelta(days=7))
        msg = await db.val("SELECT loan.notify('LOAN_DUE_REMINDER','MEMBER',%s,NULL,'loan.loan',%s,'{\"amount\":1120}'::jsonb)",
                           (t.members["A"], loan_id))
        row = await db.row("SELECT status, suppress_reason, body FROM notif.notification_message WHERE id=%s", (msg,))
        assert (row["status"], row["suppress_reason"]) == ("SUPPRESSED", "OPTED_OUT") and "1120" in row["body"]
        essential = await db.val("SELECT loan.notify('REPAYMENT_RECEIPT','MEMBER',%s,NULL,'loan.loan',%s,'{}'::jsonb)", (t.members["A"], loan_id))
        assert await db.val("SELECT status FROM notif.notification_message WHERE id=%s", (essential,)) == "QUEUED"
        await db.conn.execute("UPDATE mbr.member SET status='DECEASED' WHERE id=%s", (t.members["A"],))
        dead = await db.val("SELECT loan.notify('REPAYMENT_RECEIPT','MEMBER',%s,NULL,'loan.loan',%s,'{}'::jsonb)", (t.members["A"], loan_id))
        assert await db.val("SELECT suppress_reason FROM notif.notification_message WHERE id=%s", (dead,)) == "DECEASED"
        assert await db.val("SELECT loan.notify('NO_SUCH_TEMPLATE','MEMBER',%s,NULL,NULL,NULL,'{}'::jsonb)", (t.members["B"],)) is None
        # quiet hours covering the whole day push non-essential messages to the end of the window
        await db.set_setting(t, "notifications.quiet_hours", {"from": "00:00", "to": "23:59"})
        later = await db.val("SELECT loan.notify('LOAN_DUE_REMINDER','MEMBER',%s,NULL,NULL,NULL,'{}'::jsonb)", (t.members["B"],))
        assert await db.val("SELECT scheduled_at > now() FROM notif.notification_message WHERE id=%s", (later,))
    run_db(scenario)


def test_due_and_overdue_reminders():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        due1 = add_months(t.d0, 1)
        counts = {}
        for offset in (-8, -7, -3, -1, 0, 1, 2, 8):
            counts[offset] = (await db.daily(t, due1 + timedelta(days=offset)))["reminders_queued"]
        assert counts == {-8: 0, -7: 1, -3: 1, -1: 1, 0: 1, 1: 1, 2: 0, 8: 1}
        bodies = [r["body"] for r in await db.rows(
            "SELECT body FROM notif.notification_message WHERE entity_type='loan.loan_instalment' ORDER BY created_at")]
        assert sum("overdue" in b for b in bodies) == 2
    run_db(scenario)
