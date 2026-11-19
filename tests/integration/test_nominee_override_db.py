"""PostgreSQL integration tests for the nominee override (db/31f):
privilege loan.nominee_override with a mandatory reason, for loan submission
without a nominee and for nominations beyond NOMINATIONS.maxPerPerson; the
rule switch allowOverride; audit; approver-visible override; default grants."""

from __future__ import annotations

import json

import pytest

from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres

OVERRIDE = "loan.nominee_override"


async def grant(db: LoanDb, t, role: str, privilege: str = OVERRIDE) -> None:
    """Give a role a privilege (system context, test only)."""
    await db.act(t, None, t.d0)
    await db.conn.execute(
        """INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
           SELECT %s, id, %s FROM iam.role WHERE tenant_id=%s AND role_code=%s
           ON CONFLICT (tenant_id, role_id, privilege_code) DO NOTHING""", (t.id, privilege, t.id, role))


async def publish_rule(db: LoanDb, t, rule_set_id, code: str, value: dict) -> None:
    current = await db.row("SELECT definition, json_schema_id, version_no FROM cfg.rule_set_version "
                           "WHERE id = cfg.rule_set_version_at(%s,%s)", (rule_set_id, t.d0))
    rules = [dict(r, value={**r["value"], **value}) if r["code"] == code else r for r in current["definition"]["rules"]]
    await db.conn.execute(
        """INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                             effective_from, reason, source)
           VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Override test','DESIGNER')""",
        (t.id, rule_set_id, current["version_no"] + 1, json.dumps(dict(current["definition"], rules=rules)),
         current["json_schema_id"], t.d0))


async def has(db: LoanDb, t, role: str, privilege: str) -> bool:
    await db.act(t, None, t.today)
    return await db.val("SELECT iam.has_privilege(%s,%s)", (t.users[role], privilege))


def test_default_grant_is_manager_only():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        assert await has(db, t, "MGR", OVERRIDE)
        assert not await has(db, t, "EMP", OVERRIDE)
        assert not await has(db, t, "LDR", OVERRIDE)
        await db.act(t, None, t.d0)
        in_ceiling = await db.val("SELECT count(*) FROM platform.tenant_privilege_ceiling WHERE tenant_id=%s "
                                  "AND privilege_code=%s", (t.id, OVERRIDE))
        assert in_ceiling == 1                     # grantable to any role through Roles & privileges

    run_db(scenario)


def test_loan_submission_override_paths():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        service = LoanService(db.conn)
        loan = await db.create_loan(t, "A", nominee=False)

        # No privilege: the nominee rule applies, a reason does not help.
        await db.act(t, "EMP", t.d0)
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.submit_application(loan["id"], "No family"))

        await grant(db, t, "EMP")
        await db.act(t, "EMP", t.d0)
        await db.app_fails("NOMINEE_OVERRIDE_REASON_REQUIRED", lambda: service.submit_application(loan["id"]))
        await db.app_fails("NOMINEE_OVERRIDE_REASON_REQUIRED", lambda: service.submit_application(loan["id"], " x "))

        submitted = await service.submit_application(loan["id"], "  Member has no living relatives  ")
        assert submitted["status"] in {"UNDER_APPROVAL", "FEE_PENDING", "SUBMITTED"}
        assert submitted["nominee_override"] is True
        assert submitted["nominee_override_reason"] == "Member has no living relatives"
        assert submitted["nominee_override_by"] == t.users["EMP"]

        audit = await db.row("""SELECT reason, reference_type, user_id FROM audit.audit_event
                                 WHERE tenant_id=%s AND entity_table='loan' AND reference_type='NOMINEE_OVERRIDE'
                                 ORDER BY id DESC LIMIT 1""", (t.id,))
        assert audit["reason"] == "Nominee rule overridden: Member has no living relatives"
        assert audit["user_id"] == t.users["EMP"]

        # The approver sees the override in the loan and in the inbox.
        await db.act(t, "MGR", t.d0)
        detail = await service.get_application(loan["id"])
        assert detail["nominee_override"] is True and detail["nominee_override_by_name"] == "Test EMP"
        inbox = await service.approval_inbox(limit=50, offset=0)
        mine = [i for i in inbox["items"] if i["loan_id"] == loan["id"]]
        assert mine and mine[0]["nominee_override"] is True
        assert mine[0]["nominee_override_reason"] == "Member has no living relatives"

    run_db(scenario)


def test_allow_override_false_refuses_even_with_privilege():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        rs = await db.val("SELECT rule_set_id FROM loan.loan_type WHERE id=%s", (t.loan_types["INTEREST_BEARING"],))
        await db.act(t, None, t.d0)
        await publish_rule(db, t, rs, "NOMINEE", {"allowOverride": False})
        loan = await db.create_loan(t, "A", nominee=False)
        await grant(db, t, "EMP")
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        await db.app_fails("NOMINEE_OVERRIDE_NOT_ALLOWED",
                           lambda: service.submit_application(loan["id"], "Member has no family"))
        detail = await service.get_application(loan["id"])
        assert detail["nominee_override"] is False and detail["status"] == "DRAFT"

    run_db(scenario)


def test_nomination_limit_override_paths():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        for member in ("A", "B"):
            await db.val("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members[member], t.members["C"]))

        sql = "SELECT mbr.add_nominee(%s,%s,'SON',%s)"
        args = (t.members["NEW"], t.members["C"])
        await db.fails(sql, (*args, None), code="NOMINATION_LIMIT_REACHED")
        await db.fails(sql, (*args, "Only relative nearby"), code="NOMINATION_LIMIT_REACHED")   # no privilege

        await grant(db, t, "EMP")
        await db.act(t, "EMP", t.d0)
        await db.fails(sql, (*args, None), code="NOMINEE_OVERRIDE_REASON_REQUIRED")
        added = await db.val(sql, (*args, "  Only relative nearby  "))
        assert added["limit_override"] is True and added["limit_override_reason"] == "Only relative nearby"
        audit = await db.row("""SELECT reason FROM audit.audit_event WHERE tenant_id=%s AND entity_table='nominee'
                                 AND reference_type='NOMINEE_OVERRIDE' ORDER BY id DESC LIMIT 1""", (t.id,))
        assert audit["reason"] == "Nomination limit overridden: Only relative nearby"

        # Reactivation beyond the limit needs the explicit override flag.
        row = await db.val("SELECT mbr.set_nominee_status(%s,'INACTIVE',%s,'Moved')", (added["id"], added["row_version"]))
        await db.val("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members["APPLIED"], t.members["B"]))   # unrelated
        await db.fails("SELECT mbr.set_nominee_status(%s,'ACTIVE',%s,'Back again')", (row["id"], row["row_version"]),
                       code="NOMINEE_OVERRIDE_REASON_REQUIRED")
        back = await db.val("SELECT mbr.set_nominee_status(%s,'ACTIVE',%s,'Back again',true)",
                            (row["id"], row["row_version"]))
        assert back["status"] == "ACTIVE" and back["limit_override_reason"] == "Back again"

        # The rule can switch nomination overrides off.
        rs = await db.val("SELECT id FROM cfg.rule_set WHERE tenant_id=%s AND code='MEMBER_RULES'", (t.id,))
        await db.act(t, None, t.d0)
        await publish_rule(db, t, rs, "NOMINATIONS", {"allowOverride": False})
        await db.act(t, "EMP", t.d0)
        await db.fails(sql, (t.members["APPLIED"], t.members["C"], "Only relative nearby"),
                       code="NOMINEE_OVERRIDE_NOT_ALLOWED")

    run_db(scenario)
