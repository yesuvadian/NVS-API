"""PostgreSQL integration tests for the nominee override (db/31f): default
grants, and nominations beyond NOMINATIONS.maxPerPerson with a reason. The
loan-side override (at approval) is tested in test_nominee_timing_db.py."""

from __future__ import annotations

import json

import pytest

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


def test_nominations_rule_without_allow_override_means_not_allowed():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        for member in ("A", "B"):
            await db.val("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members[member], t.members["C"]))
        rs = await db.val("SELECT id FROM cfg.rule_set WHERE tenant_id=%s AND code='MEMBER_RULES'", (t.id,))
        await db.act(t, None, t.d0)
        current = await db.row("SELECT definition, json_schema_id, version_no FROM cfg.rule_set_version "
                               "WHERE id = cfg.rule_set_version_at(%s,%s)", (rs, t.d0))
        rules = [dict(r, value={k: v for k, v in r["value"].items() if k != "allowOverride"})
                 if r["code"] == "NOMINATIONS" else r for r in current["definition"]["rules"]]
        await db.conn.execute(
            """INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                                 effective_from, reason, source)
               VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'No allowOverride','DESIGNER')""",
            (t.id, rs, current["version_no"] + 1, json.dumps(dict(current["definition"], rules=rules)),
             current["json_schema_id"], t.d0))
        await grant(db, t, "EMP")
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SON',%s)", (t.members["NEW"], t.members["C"], "Only relative"),
                       code="NOMINEE_OVERRIDE_NOT_ALLOWED")

    run_db(scenario)
