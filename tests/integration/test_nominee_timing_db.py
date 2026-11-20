"""PostgreSQL integration tests: the NOMINEE rule (conditions: first loan,
amount threshold, past default) evaluated at the workflow transitions of the
loan's workflow version (v2: APPROVE with override, DISBURSE re-check), the
nominee override at approval, linking nominees after submission, and moving a
rule check between transitions in a new workflow version."""

from __future__ import annotations

import json
from datetime import timedelta
from decimal import Decimal

import pytest

from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, add_months, run_db

pytestmark = pytest.mark.postgres

OVERRIDE = "loan.nominee_override"


async def status(db: LoanDb, loan_id):
    return await db.val("SELECT loan.nominee_status(%s)", (loan_id,))


async def request_of(db: LoanDb, loan_id):
    return await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan_id,))


async def submit(db: LoanDb, t, loan_id, on=None):
    await db.act(t, "EMP", on or t.d0)
    return await LoanService(db.conn).submit_application(loan_id)


async def grant(db: LoanDb, t, role: str) -> None:
    await db.act(t, None, t.d0)
    await db.conn.execute(
        """INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
           SELECT %s, id, %s FROM iam.role WHERE tenant_id=%s AND role_code=%s
           ON CONFLICT (tenant_id, role_id, privilege_code) DO NOTHING""", (t.id, OVERRIDE, t.id, role))


async def publish_nominee_rule(db: LoanDb, t, value: dict) -> None:
    rs = await db.val("SELECT rule_set_id FROM loan.loan_type WHERE id=%s", (t.loan_types["INTEREST_BEARING"],))
    current = await db.row("SELECT definition, json_schema_id, version_no FROM cfg.rule_set_version "
                           "WHERE id = cfg.rule_set_version_at(%s,%s)", (rs, t.d0))
    rules = [dict(r, value=value) if r["code"] == "NOMINEE" else r for r in current["definition"]["rules"]]
    await db.act(t, None, t.d0)
    await db.conn.execute("UPDATE cfg.rule_set_version SET status='RETIRED' WHERE rule_set_id=%s "
                          "AND status='PUBLISHED' AND effective_from=%s", (rs, t.d0))
    await db.conn.execute(
        """INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                             effective_from, reason, source)
           VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Test','DESIGNER')""",
        (t.id, rs, current["version_no"] + 1, json.dumps(dict(current["definition"], rules=rules)),
         current["json_schema_id"], t.d0))


def test_default_rule_and_workflow_for_new_organisations():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, None, t.d0)
        rule = await db.val(
            """SELECT r->'value' FROM loan.loan_type lt
                 JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(lt.rule_set_id, %s)
                 CROSS JOIN LATERAL jsonb_array_elements(v.definition->'rules') r
                WHERE lt.id=%s AND r->>'code'='NOMINEE'""", (t.d0, t.loan_types["INTEREST_BEARING"]))
        assert rule == {"conditions": {"firstLoan": True, "thresholdAmount": 100000,
                                       "defaulter": {"enabled": True, "lookbackMonths": 24}},
                        "allowOverride": True}
        transitions = await db.val(
            """SELECT v.definition->'transitions' FROM cfg.workflow_version v
                WHERE v.id = cfg.workflow_version_at('LOAN_APPLICATION', %s, %s)""", (t.d0, t.id))
        checks = {tr["on"]: tr.get("ruleChecks") for tr in transitions}
        assert "NOMINEE" not in checks["SUBMIT"]
        assert checks["APPROVE"] == ["NOMINEE", "GUARANTORS"] and checks["DISBURSE"] == ["NOMINEE"]

    run_db(scenario)


def test_conditions_first_loan_threshold_and_none():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "loans.max_concurrent_loans", 3)
        first = await db.create_loan(t, "A", nominee=False)
        await db.act(t, "EMP", t.d0)
        assert (await status(db, first["id"]))["required_because"] == ["FIRST_LOAN"]

        # Member A now has a loan, so the next application is not a first loan
        # (another loan type: one open application per type and member).
        later = await db.create_loan(t, "A", amount="12000.00", nominee=False, loan_type="INTEREST_FREE")
        await db.act(t, "EMP", t.d0)
        none_met = await status(db, later["id"])
        assert none_met["required"] is False and none_met["satisfied"] is True

        big = await db.create_loan(t, "A", amount="150000.00", nominee=False, loan_type="NORMAL")
        await db.act(t, "EMP", t.d0)
        assert (await status(db, big["id"]))["required_because"] == ["THRESHOLD"]

        # Threshold off: the big second loan needs no nominee.
        await publish_nominee_rule(db, t, {"conditions": {"firstLoan": True, "thresholdAmount": None,
                                                          "defaulter": {"enabled": False}}})
        await db.conn.execute("UPDATE loan.loan SET status='WITHDRAWN' WHERE id=%s", (first["id"],))
        off = await db.create_loan(t, "A", amount="150000.00", nominee=False)
        await db.act(t, "EMP", t.d0)
        assert (await status(db, off["id"]))["required"] is False

    run_db(scenario)


def test_past_default_condition_and_lookback_boundary():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "loans.max_concurrent_loans", 3)
        old = await db.create_loan(t, "C", nominee=False)
        await db.act(t, None, t.d0)
        await db.conn.execute("UPDATE loan.loan SET status='WITHDRAWN' WHERE id=%s", (old["id"],))
        on_boundary = (t.d0 - timedelta(days=0)).replace(day=10)
        boundary = add_months(on_boundary, -24)
        await db.conn.execute(
            """INSERT INTO loan.loan_default (tenant_id, loan_id, defaulted_on, oldest_unpaid_due_date,
                                              unpaid_months_rule, outstanding_principal, status)
               VALUES (%s,%s,%s,%s,2,1000,'SETTLED')""", (t.id, old["id"], boundary, boundary))
        new = await db.create_loan(t, "C", amount="12000.00", nominee=False)

        await db.act(t, "EMP", on_boundary)                 # exactly 24 months back: counts
        within = await status(db, new["id"])
        # C's only other loan was withdrawn, so this is also a first loan.
        assert "PAST_DEFAULT" in within["required_because"]
        assert within["default_loan_no"] == old["loan_no"]

        await db.act(t, "EMP", on_boundary + timedelta(days=1))   # one day later: outside the lookback
        assert "PAST_DEFAULT" not in (await status(db, new["id"]))["required_because"]

        # Lookback null = any past default.
        await publish_nominee_rule(db, t, {"conditions": {"firstLoan": True, "thresholdAmount": None,
                                                          "defaulter": {"enabled": True, "lookbackMonths": None}}})
        await db.conn.execute("UPDATE loan.loan SET status='WITHDRAWN' WHERE id=%s", (new["id"],))
        ever = await db.create_loan(t, "C", amount="12000.00", nominee=False)   # the type whose rule changed
        await db.act(t, "EMP", on_boundary + timedelta(days=1))
        assert "PAST_DEFAULT" in (await status(db, ever["id"]))["required_because"]

    run_db(scenario)


def test_submit_without_nominee_then_approve_needs_nominee_or_override():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        service = LoanService(db.conn)
        loan = await db.create_loan(t, "A", nominee=False)                 # first loan: nominee required
        submitted = await submit(db, t, loan["id"])
        assert submitted["status"] in {"UNDER_APPROVAL", "SUBMITTED"}
        request = await request_of(db, loan["id"])

        await db.act(t, "MGR", t.d0)                                      # MGR holds the override by default
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.decide(request, {"decision": "APPROVED"}))
        await db.app_fails("NOMINEE_OVERRIDE_REASON_REQUIRED",
                           lambda: service.decide(request, {"decision": "APPROVED", "nominee_override_reason": "x"}))
        # Reject / return need no nominee.
        detail = await service.get_application(loan["id"])
        criterion = next(c for c in detail["criteria"] if c["code"] == "NOMINEE")
        assert criterion["required"] is True and criterion["met"] is False and criterion["stage"] == "APPROVE"

        approved = await service.decide(request, {"decision": "APPROVED",
                                                  "nominee_override_reason": "Member has no living relatives"})
        assert approved is not None
        detail = await service.get_application(loan["id"])
        assert detail["status"] == "APPROVED" and detail["nominee_override"] is True
        assert detail["nominee_override_by"] == t.users["MGR"]
        audit = await db.row("""SELECT reason FROM audit.audit_event WHERE tenant_id=%s AND entity_table='loan'
                                 AND reference_type='NOMINEE_OVERRIDE' ORDER BY id DESC LIMIT 1""", (t.id,))
        assert audit["reason"] == "Nominee rule overridden: Member has no living relatives"

    run_db(scenario)


def test_reject_and_return_need_no_nominee_and_maker_override_before_approval():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        service = LoanService(db.conn)
        returned = await db.create_loan(t, "A", nominee=False)
        await submit(db, t, returned["id"])
        await db.act(t, "MGR", t.d0)
        await service.decide(await request_of(db, returned["id"]), {"decision": "RETURNED", "reason": "Fix details"})

        loan = await db.create_loan(t, "B", nominee=False)
        await submit(db, t, loan["id"])
        await db.act(t, "EMP", t.d0)
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.record_nominee_override(loan["id"], "No relatives"))
        await grant(db, t, "EMP")
        await db.act(t, "EMP", t.d0)
        await service.record_nominee_override(loan["id"], "No relatives")
        await db.act(t, "MGR", t.d0)
        await service.decide(await request_of(db, loan["id"]), {"decision": "APPROVED"})
        assert (await service.get_application(loan["id"]))["status"] == "APPROVED"

    run_db(scenario)


def test_allow_override_false_refuses_even_with_privilege():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await publish_nominee_rule(db, t, {"conditions": {"firstLoan": True, "thresholdAmount": None,
                                                          "defaulter": {"enabled": False}},
                                           "allowOverride": False})
        loan = await db.create_loan(t, "A", nominee=False)
        await submit(db, t, loan["id"])
        request = await request_of(db, loan["id"])
        await db.act(t, "MGR", t.d0)                                  # holds loan.nominee_override
        await db.app_fails("NOMINEE_OVERRIDE_NOT_ALLOWED", lambda: LoanService(db.conn).decide(
            request, {"decision": "APPROVED", "nominee_override_reason": "Member has no relatives"}))

    run_db(scenario)


def test_link_nominees_after_submit_and_recheck_at_disbursement():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        service = LoanService(db.conn)
        loan = await db.create_loan(t, "A", nominee=False)
        await submit(db, t, loan["id"])

        await db.act(t, "EMP", t.d0)
        current = await service.get_application(loan["id"])
        await db.app_fails("STALE_RECORD", lambda: service.set_nominees(loan["id"], [t.nominees["A"]],
                                                                         current["row_version"] + 5))
        linked = await service.set_nominees(loan["id"], [t.nominees["A"]], current["row_version"])
        assert linked["linked"] is True and linked["satisfied"] is True

        await db.act(t, "MGR", t.d0)
        await service.decide(await request_of(db, loan["id"]), {"decision": "APPROVED"})
        disbursement = await db.prepare(t, loan["id"], "12000.00")

        # The nominee becomes inactive before the money is released: blocked,
        # even for an override holder.
        await db.act(t, None, t.d0)
        await db.conn.execute("UPDATE mbr.nominee SET status='INACTIVE' WHERE id=%s", (t.nominees["A"],))
        await db.act(t, "MGR", t.d0)
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.release_disbursement(
            loan["id"], disbursement["disbursement_id"], "SIGNATURE"))

        # Link another active nominee (allowed while APPROVED and not disbursed), then release.
        await db.act(t, None, t.d0)
        fresh = await db.val("INSERT INTO mbr.nominee (tenant_id, member_id, full_name, relationship) "
                             "VALUES (%s,%s,'New Nominee','SPOUSE') RETURNING id", (t.id, t.members["A"]))
        await db.act(t, "EMP", t.d0)
        version = (await service.get_application(loan["id"]))["row_version"]
        await service.set_nominees(loan["id"], [fresh], version)
        await db.act(t, "MGR", t.d0)
        released = await service.release_disbursement(loan["id"], disbursement["disbursement_id"], "SIGNATURE")
        assert released["status"] == "PAID"

    run_db(scenario)


def test_moving_a_rule_check_in_a_new_workflow_version_moves_enforcement():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        service = LoanService(db.conn)
        before = await db.create_loan(t, "A", nominee=False)        # created on workflow v2

        # Publish v3: NOMINEE checked at SUBMIT instead.
        await db.act(t, None, t.d0)
        wf = await db.row("""SELECT v.workflow_definition_id, v.definition, v.json_schema_id, v.version_no
                               FROM cfg.workflow_version v
                              WHERE v.id = cfg.workflow_version_at('LOAN_APPLICATION', %s, %s)""", (t.d0, t.id))
        transitions = [dict(tr, ruleChecks=[*tr["ruleChecks"], "NOMINEE"]) if tr["on"] == "SUBMIT" else tr
                       for tr in wf["definition"]["transitions"]]
        await db.conn.execute("UPDATE cfg.workflow_version SET status='RETIRED' WHERE workflow_definition_id=%s "
                              "AND status='PUBLISHED' AND effective_from=%s", (wf["workflow_definition_id"], t.d0))
        await db.conn.execute(
            """INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                                 json_schema_id, effective_from, reason, source)
               VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Nominee at submit','DESIGNER')""",
            (t.id, wf["workflow_definition_id"], wf["version_no"] + 1,
             json.dumps(dict(wf["definition"], transitions=transitions)), wf["json_schema_id"], t.d0))

        after = await db.create_loan(t, "B", nominee=False)          # created on v3
        await db.act(t, "EMP", t.d0)
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.submit_application(after["id"]))
        submitted = await service.submit_application(before["id"])  # keeps v2: nominee not needed at submit
        assert submitted["status"] in {"UNDER_APPROVAL", "SUBMITTED"}

    run_db(scenario)
