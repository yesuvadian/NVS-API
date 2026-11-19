"""PostgreSQL integration tests for member nominees (db/31d) and the nominee
rules (db/49a): nominee is a member of the same organisation, not self, ACTIVE
or APPLIED, no duplicate active nomination, MEMBER_RULES / NOMINATIONS limits,
row versions, and the loan-type NOMINEE rule (everyLoan, thresholdAmount)."""

from __future__ import annotations

import json
from decimal import Decimal

import pytest

from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


async def add(db: LoanDb, t, member: str, nominee: str, relationship: str = "SISTER"):
    return await db.val("SELECT mbr.add_nominee(%s,%s,%s)", (t.members[member], t.members[nominee], relationship))


async def set_rules(db: LoanDb, t, value: dict) -> None:
    """Publish a new MEMBER_RULES version (owner session, test only)."""
    rs = await db.val("SELECT id FROM cfg.rule_set WHERE tenant_id=%s AND code='MEMBER_RULES'", (t.id,))
    current = await db.row("SELECT definition, json_schema_id, version_no FROM cfg.rule_set_version "
                           "WHERE id = cfg.rule_set_version_at(%s, %s)", (rs, t.d0))
    definition = dict(current["definition"], rules=[{"code": "NOMINATIONS", "value": value}])
    await db.conn.execute(
        """INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                             effective_from, reason, source)
           VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Test limits','DESIGNER')""",
        (t.id, rs, current["version_no"] + 1, json.dumps(definition), current["json_schema_id"], t.d0))


def test_nominee_must_be_an_eligible_member_once():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        other = await db.new_tenant()
        await db.act(t, "EMP", t.d0)

        added = await add(db, t, "A", "B")
        assert added["nominee_member_id"] == str(t.members["B"]) and added["full_name"] == "Member B"
        assert added["nominee_member_no"] and added["status"] == "ACTIVE"
        assert await add(db, t, "A", "APPLIED", "SON")                  # APPLIED members can be nominees

        await db.fails("SELECT mbr.add_nominee(%s,%s,'SISTER')", (t.members["A"], t.members["B"]),
                       code="NOMINEE_DUPLICATE")
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SISTER')", (t.members["A"], t.members["A"]),
                       code="NOMINEE_IS_SELF")
        await db.fails("SELECT mbr.add_nominee(%s,%s,'FRIEND')", (t.members["A"], t.members["C"]),
                       code="INVALID_DATA")
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members["A"], other.members["B"]),
                       code="MEMBER_NOT_FOUND")                          # another organisation's member

        await db.conn.execute("UPDATE mbr.member SET status='EXITED' WHERE id=%s", (t.members["C"],))
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members["A"], t.members["C"]),
                       code="NOMINEE_MEMBER_NOT_ELIGIBLE")

        listed = await db.val("SELECT mbr.list_nominees(%s,false)", (t.members["A"],))
        linked = {n["full_name"] for n in listed if n["nominee_member_id"]}
        assert linked == {"Member B", "Member APPLIED"}          # plus the harness's free-text nominee

    run_db(scenario)


def test_person_can_be_nominee_for_at_most_max_per_person_members():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        assert (await db.val("SELECT mbr.nomination_rules()"))["maxPerPerson"] == 2

        first = await add(db, t, "A", "C")
        await add(db, t, "B", "C")
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members["NEW"], t.members["C"]),
                       code="NOMINATION_LIMIT_REACHED")

        # Deactivating one nomination frees a place; reactivating it is then refused.
        inactive = await db.val("SELECT mbr.set_nominee_status(%s,'INACTIVE',%s,'Moved away')",
                                (first["id"], first["row_version"]))
        assert inactive["status"] == "INACTIVE"
        await add(db, t, "NEW", "C")
        await db.fails("SELECT mbr.set_nominee_status(%s,'ACTIVE',%s,'Back again')",
                       (inactive["id"], inactive["row_version"]), code="NOMINATION_LIMIT_REACHED")

    run_db(scenario)


def test_changed_rule_limits_apply_to_new_nominations_only():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        await add(db, t, "A", "C")
        await add(db, t, "B", "C")

        # Every harness member already has one free-text nominee, so maxPerMember 2
        # means "one more" for them.
        await set_rules(db, t, {"maxPerPerson": 1, "maxPerMember": 2})
        await db.act(t, "EMP", t.d0)
        assert await db.val("SELECT mbr.nomination_rules()") == {"maxPerPerson": 1, "maxPerMember": 2}
        # Existing nominations stay; new ones are checked against the new limits.
        b_nominees = await db.val("SELECT mbr.list_nominees(%s,false)", (t.members["B"],))
        assert [n["full_name"] for n in b_nominees if n["nominee_member_id"]] == ["Member C"]
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members["NEW"], t.members["C"]),
                       code="NOMINATION_LIMIT_REACHED")
        await db.fails("SELECT mbr.add_nominee(%s,%s,'SON')", (t.members["A"], t.members["NEW"]),
                       code="NOMINEE_LIMIT_REACHED")      # A has its free-text nominee and C

    run_db(scenario)


def test_row_versions_and_status_rules():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        row = await add(db, t, "A", "B")

        await db.fails("SELECT mbr.update_nominee(%s,'BROTHER',NULL)", (row["id"],), code="ROW_VERSION_REQUIRED")
        await db.fails("SELECT mbr.update_nominee(%s,'BROTHER',%s)", (row["id"], row["row_version"] + 5),
                       code="STALE_RECORD")
        updated = await db.val("SELECT mbr.update_nominee(%s,'BROTHER',%s)", (row["id"], row["row_version"]))
        assert updated["relationship"] == "BROTHER" and updated["row_version"] == row["row_version"] + 1

        await db.fails("SELECT mbr.set_nominee_status(%s,'INACTIVE',%s,'')", (row["id"], updated["row_version"]),
                       code="REASON_REQUIRED")
        await db.fails("SELECT mbr.set_nominee_status(%s,'GONE',%s,'Moved')", (row["id"], updated["row_version"]),
                       code="INVALID_DATA")
        audit = await db.row("SELECT entity_table FROM audit.audit_event WHERE tenant_id=%s AND entity_table='nominee' "
                             "ORDER BY id DESC LIMIT 1", (t.id,))
        assert audit is not None

    run_db(scenario)


def test_every_new_loan_needs_an_active_nominee_and_threshold_is_evaluated():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "EMP", t.d0)
        service = LoanService(db.conn)
        later_loan = await service.eligibility(
            member_id=t.members["A"], loan_type_id=t.loan_types["INTEREST_BEARING"],
            requested_amount=Decimal("12000.00"), requested_tenure_months=12, first_loan=False)
        assert later_loan["nominee_required"] is True                     # NOMINEE.everyLoan from template v2

        # A nominee that became inactive no longer counts at submission.
        loan = await db.create_loan(t, "A")
        await db.conn.execute("UPDATE mbr.nominee SET status='INACTIVE' WHERE id=%s", (t.nominees["A"],))
        await db.act(t, "EMP", t.d0)
        await db.app_fails("NOMINEE_REQUIRED", lambda: service.submit_application(loan["id"]))

        # thresholdAmount: switch the loan type to "nominee from 10000" only.
        rs = await db.val("SELECT rule_set_id FROM loan.loan_type WHERE id=%s", (t.loan_types["INTEREST_BEARING"],))
        current = await db.row("SELECT definition, json_schema_id, version_no FROM cfg.rule_set_version "
                               "WHERE id = cfg.rule_set_version_at(%s,%s)", (rs, t.d0))
        rules = [dict(r, value={"everyLoan": False, "firstLoan": False, "thresholdAmount": 10000})
                 if r["code"] == "NOMINEE" else r for r in current["definition"]["rules"]]
        await db.conn.execute(
            """INSERT INTO cfg.rule_set_version (tenant_id, rule_set_id, version_no, status, definition, json_schema_id,
                                                 effective_from, reason, source)
               VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Threshold test','DESIGNER')""",
            (t.id, rs, current["version_no"] + 1, json.dumps(dict(current["definition"], rules=rules)),
             current["json_schema_id"], t.d0))
        await db.act(t, "EMP", t.d0)

        async def needs(amount: str) -> bool:
            result = await service.eligibility(
                member_id=t.members["B"], loan_type_id=t.loan_types["INTEREST_BEARING"],
                requested_amount=Decimal(amount), requested_tenure_months=12, first_loan=True)
            return result["nominee_required"]

        assert await needs("12000.00") is True
        assert await needs("6000.00") is False

    run_db(scenario)


def test_new_organisations_get_the_nominee_rules_from_templates():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, None, t.d0)
        rule = await db.val(
            """SELECT r->'value' FROM loan.loan_type lt
                 JOIN cfg.rule_set_version v ON v.id = cfg.rule_set_version_at(lt.rule_set_id, %s)
                 CROSS JOIN LATERAL jsonb_array_elements(v.definition->'rules') r
                WHERE lt.id=%s AND r->>'code'='NOMINEE'""", (t.d0, t.loan_types["INTEREST_BEARING"]))
        assert rule["everyLoan"] is True
        scope = await db.val("SELECT scope_type FROM cfg.rule_set WHERE tenant_id=%s AND code='MEMBER_RULES'", (t.id,))
        assert scope == "GENERAL"

    run_db(scenario)
