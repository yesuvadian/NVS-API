"""PostgreSQL integration tests for the Overview summary functions (db/31b).

Each scenario provisions a throw-away organisation inside one transaction that
is always rolled back (see loan_harness)."""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres

ALL_SECTIONS = ["members", "loans", "approvals", "collections"]


def test_tenant_summary_counts_members_applications_approvals_and_collections():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        active = await db.active_loan(t, "A")
        first = await db.row("""SELECT i.due_date, i.principal_due + i.interest_due AS amount
                                  FROM loan.loan_instalment i
                                  JOIN loan.loan_schedule s ON s.id=i.loan_schedule_id AND s.is_current
                                 WHERE i.loan_id=%s ORDER BY i.instalment_no LIMIT 1""", (active,))
        on = first["due_date"]
        await db.repay(t, active, str(first["amount"]), on)

        pending = await db.create_loan(t, "B", on=on)
        await db.submit(t, pending["id"], on)
        await db.create_loan(t, "C", on=on)          # still a draft / fee pending

        await db.act(t, "MGR", on)
        summary = await db.val("SELECT core.get_tenant_summary(%s::text[])", (ALL_SECTIONS,))
        assert summary["working_date"] == on.isoformat()
        assert summary["members"] == {"total": 5, "active": 4}
        assert summary["loans"] == {"open_applications": 2}
        assert summary["approvals"] == {"pending": 1}
        assert summary["collections"]["count"] == 1
        assert Decimal(str(summary["collections"]["amount"])) == first["amount"]
        assert summary["collections"]["date"] == on.isoformat()

        # The requester does not approve their own request.
        await db.act(t, "EMP", on)
        mine = await db.val("SELECT core.get_tenant_summary(%s::text[])", (["approvals"],))
        assert mine["approvals"] == {"pending": 0}
        assert set(mine) == {"approvals", "working_date"}

        # Collections are for the working date only.
        await db.act(t, "MGR", on + timedelta(days=1))
        later = await db.val("SELECT core.get_tenant_summary(%s::text[])", (["collections"],))
        assert later["collections"]["count"] == 0
        assert Decimal(str(later["collections"]["amount"])) == 0

    run_db(scenario)


def test_tenant_summary_is_isolated_per_organisation_and_needs_context():
    async def scenario(db: LoanDb):
        first = await db.new_tenant()
        second = await db.new_tenant()
        await db.act(second, "MGR", second.d0)
        other = await db.val("SELECT core.get_tenant_summary(%s::text[])", (["members"],))
        assert other["members"] == {"total": 5, "active": 4}   # not 10: RLS keeps tenants apart
        assert first.id != second.id

        await db.conn.execute("SELECT app.clear_context()")
        await db.fails("SELECT core.get_tenant_summary(ARRAY['members'])", code="NO_PRIVILEGE")

    run_db(scenario)


def test_platform_summary_counts_organisations_and_lists_newest():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.conn.execute("SELECT app.clear_context()")
        await db.conn.execute("SET LOCAL app.scope TO 'platform'")
        summary = await db.val("SELECT platform.get_platform_summary()")
        counts = summary["organisations"]
        total = await db.val("SELECT count(*) FROM platform.tenant")
        assert counts["total"] == total
        assert sum(counts["by_status"].values()) == total
        assert set(counts["by_status"]) == {"ACTIVE", "PROVISIONING", "SUSPENDED", "CLOSED"}
        newest = summary["newest_organisations"]
        assert 1 <= len(newest) <= 5
        assert newest[0]["code"] == t.code
        assert set(newest[0]) == {"id", "code", "name", "status", "created_at"}

    run_db(scenario)


def test_platform_summary_refuses_tenant_scope():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, "ADM", t.d0)
        await db.fails("SELECT platform.get_platform_summary()", code="PLATFORM_CONTEXT_REQUIRED")
        await db.conn.execute("SELECT app.clear_context()")
        await db.fails("SELECT platform.get_platform_summary()", code="PLATFORM_CONTEXT_REQUIRED")

    run_db(scenario)
