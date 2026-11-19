"""Race-condition tests with two real database sessions.

Each scenario commits a throw-away organisation (the race needs data both
sessions can see), then runs the same action in two sessions: session A does
it and keeps its transaction open, session B starts and is checked to be
waiting on A's lock, A commits, and B's outcome is asserted. Afterwards the
organisation is closed (status CLOSED) so jobs ignore it; its rows stay, as
audit data cannot be deleted.

Skip these with:  pytest -m "not concurrency"
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from collections.abc import Awaitable, Callable
from datetime import timedelta
from decimal import Decimal
from typing import Any

import psycopg
import pytest
from psycopg import AsyncConnection
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from app.core.idempotency import run_idempotent
from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, Tenant, owner_dsn, run_async

pytestmark = [pytest.mark.postgres, pytest.mark.concurrency]

D = Decimal


async def _connect() -> AsyncConnection:
    try:
        return await AsyncConnection.connect(owner_dsn(), row_factory=dict_row, connect_timeout=5)
    except psycopg.OperationalError as exc:
        pytest.skip(f"PostgreSQL not reachable: {exc}")


async def _wait_until_blocked(watcher: AsyncConnection, pid: int, timeout: float = 10.0) -> None:
    """Wait until backend ``pid`` is waiting for a lock held by another session."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        row = await (await watcher.execute(
            "SELECT wait_event_type FROM pg_stat_activity WHERE pid=%s", (pid,))).fetchone()
        if row and row["wait_event_type"] == "Lock":
            return
        await asyncio.sleep(0.05)
    raise AssertionError("session B never waited for session A's lock")


@asynccontextmanager
async def sessions(setup: Callable[[LoanDb], Awaitable[dict[str, Any]]]):
    """Commit ``setup`` and yield (data, session A, session B, autocommit watcher);
    close the throw-away organisation afterwards."""
    owner = await _connect()
    tenant: Tenant | None = None
    a = b = watcher = None
    try:
        async with owner.transaction():
            data = await setup(LoanDb(owner))
        tenant = data["tenant"]
        a, b, watcher = await _connect(), await _connect(), await _connect()
        await watcher.set_autocommit(True)
        yield data, a, b, watcher
    finally:
        for conn in (a, b, watcher):
            if conn is not None:
                await conn.close()
        if tenant is not None:
            async with owner.transaction():
                await owner.execute("SELECT app.clear_context()")
                await owner.execute("UPDATE platform.tenant SET status='CLOSED' WHERE id=%s", (tenant.id,))
        await owner.close()


async def _outcome(task: asyncio.Task, conn: AsyncConnection) -> Any:
    """B's result (committed), or the error it raised (rolled back)."""
    try:
        result = await asyncio.wait_for(task, timeout=20)
        await conn.commit()
        return result
    except psycopg.Error as exc:
        await conn.rollback()
        return exc


async def race(
    setup: Callable[[LoanDb], Awaitable[dict[str, Any]]],
    action: Callable[[LoanDb, dict[str, Any], str], Awaitable[Any]],
) -> tuple[dict[str, Any], Any, Any]:
    """Run ``action`` in session A (left open) and session B (must block on A),
    commit A and return (data, A's result, B's result or error)."""
    async with sessions(setup) as (data, a, b, watcher):
        result_a = await action(LoanDb(a), data, "A")            # A's transaction stays open
        task_b = asyncio.create_task(action(LoanDb(b), data, "B"))
        await _wait_until_blocked(watcher, b.info.backend_pid)
        await a.commit()
        return data, result_a, await _outcome(task_b, b)


def _hint(error: Any) -> str | None:
    assert isinstance(error, psycopg.Error), f"expected a database error, got {error!r}"
    return error.diag.message_hint


async def _count(sql: str, params: tuple, tenant: Tenant) -> int:
    conn = await _connect()
    try:
        await conn.execute("SELECT app.set_context(%s,NULL,'ADM','WEB',NULL,NULL,NULL,false,NULL)", (tenant.id,))
        return next(iter((await (await conn.execute(sql, params)).fetchone()).values()))
    finally:
        await conn.close()


# -----------------------------------------------------------------------------
def test_race_same_idempotency_key_posts_one_repayment():
    async def setup(db: LoanDb):
        t = await db.new_tenant()
        return {"tenant": t, "loan": await db.active_loan(t), "on": t.d0 + timedelta(days=31)}

    async def pay(db: LoanDb, data, _who):
        t = data["tenant"]
        await db.act(t, "EMP", data["on"])
        body = {"loan_id": data["loan"], "amount": D("1000.00"), "payment_mode": "CASH", "payment_reference": None}
        return await run_idempotent(
            db.conn, key="race-repay-key-1", operation="loan.collect_repayment", payload=body,
            action=lambda: LoanService(db.conn).collect_repayment(
                data["loan"], amount=D("1000.00"), payment_mode="CASH", payment_reference=None))

    async def main():
        data, first, second = await race(setup, pay)
        assert not isinstance(second, Exception), second
        assert second == first                                   # B got A's receipt back
        receipts = await _count("SELECT count(*) FROM acct.cash_receipt WHERE source_entity_id=%s "
                                "AND purpose='LOAN_REPAYMENT'", (data["loan"],), data["tenant"])
        assert receipts == 1
    run_async(main())


def test_race_two_approvals_for_one_member_respect_the_loan_limit():
    async def setup(db: LoanDb):
        t = await db.new_tenant()
        first = await db.create_loan(t, "A")
        await db.submit(t, first["id"])
        second = await db.create_loan(t, "A", loan_type="INTEREST_FREE", amount="10000.00", tenure=10)
        await db.submit(t, second["id"])
        return {"tenant": t, "loans": {"A": first["id"], "B": second["id"]}}

    async def approve(db: LoanDb, data, who):
        t = data["tenant"]
        await db.act(t, "MGR", t.d0)
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (data["loans"][who],))
        return await db.val("SELECT loan.record_approval_decision(%s,'APPROVED',NULL,NULL,NULL)", (request,))

    async def main():
        _data, first, second = await race(setup, approve)
        assert first["decision"] == "APPROVED"
        assert _hint(second) == "MAX_CONCURRENT_LOANS_REACHED"
    run_async(main())


def test_race_same_guarantor_on_two_loans_respects_the_guarantor_limit():
    async def setup(db: LoanDb):
        t = await db.new_tenant()
        await db.set_setting(t, "loans.guarantor_limits", {"maxActiveGuarantees": 1})
        return {"tenant": t, "loans": {"A": (await db.create_loan(t, "A"))["id"],
                                       "B": (await db.create_loan(t, "B"))["id"]}}

    async def add(db: LoanDb, data, who):
        t = data["tenant"]
        await db.act(t, "EMP", t.d0)
        return await db.val("SELECT loan.add_guarantor(%s,%s)", (data["loans"][who], Jsonb(
            {"guarantor_member_id": str(t.members["C"]), "consent_type": "SIGNATURE"})))

    async def main():
        _data, first, second = await race(setup, add)
        assert len(first) == 1
        assert _hint(second) == "GUARANTOR_LIMIT_REACHED"
    run_async(main())


def test_race_same_person_registered_twice_is_refused():
    async def setup(db: LoanDb):
        return {"tenant": await db.new_tenant()}

    async def register(db: LoanDb, data, _who):
        t = data["tenant"]
        await db.act(t, "EMP", t.d0)
        return await db.val("SELECT mbr.create_member(%s)", (Jsonb({"full_name": "Selvi K", "mobile": "9443322110"}),))

    async def main():
        _data, first, second = await race(setup, register)
        assert first["member_no"]
        assert _hint(second) == "DUPLICATE_MEMBER"
    run_async(main())


def test_race_double_click_on_create_application_makes_one_application():
    async def setup(db: LoanDb):
        return {"tenant": await db.new_tenant()}

    async def create(db: LoanDb, data, _who):
        return await db.create_loan(data["tenant"], "A")

    async def main():
        data, first, second = await race(setup, create)
        assert first["status"] == "DRAFT"
        assert _hint(second) == "LOAN_APPLICATION_ALREADY_OPEN"
        assert await _count("SELECT count(*) FROM loan.loan WHERE member_id=%s",
                            (data["tenant"].members["A"],), data["tenant"]) == 1
    run_async(main())


def test_settlement_collection_and_quote_lock_the_loan_in_the_same_order():
    """Before the fix, collection locked the quote and then the loan while quoting
    locks the loan and then the quotes: run side by side they deadlocked. Session A
    plays the quote step by step; session B collects."""
    async def setup(db: LoanDb):
        t = await db.new_tenant()
        loan_id = await db.active_loan(t)
        on = t.d0 + timedelta(days=10)
        await db.act(t, "EMP", on)
        quote = await db.val("SELECT loan.quote_early_settlement(%s)", (loan_id,))
        await db.act(t, "MGR", on)
        await db.val("SELECT loan.approve_early_settlement(%s)", (quote["id"],))
        return {"tenant": t, "loan": loan_id, "settlement": quote["id"], "on": on}

    async def main():
        async with sessions(setup) as (data, a, b, watcher):
            t = data["tenant"]
            quoting, collecting = LoanDb(a), LoanDb(b)
            await quoting.act(t, "EMP", data["on"])
            await quoting.val("SELECT id FROM loan.loan WHERE id=%s FOR UPDATE", (data["loan"],))   # quote, step 1

            async def collect():
                await collecting.act(t, "EMP", data["on"])
                return await collecting.val("SELECT loan.collect_early_settlement(%s,'CASH')", (data["settlement"],))

            task = asyncio.create_task(collect())
            await _wait_until_blocked(watcher, b.info.backend_pid)
            # Quote, step 2: expire the open quotes. With the old lock order the
            # collection already held the quote row here and this deadlocked.
            await a.execute("SET LOCAL lock_timeout = '5s'")
            await a.execute("UPDATE loan.loan_settlement SET status='EXPIRED' WHERE loan_id=%s "
                            "AND status IN ('QUOTED','APPROVED')", (data["loan"],))
            await a.commit()
            outcome = await _outcome(task, b)
            assert isinstance(outcome, psycopg.Error) and outcome.diag.sqlstate != "40P01"
            assert outcome.diag.message_hint == "SETTLEMENT_NOT_PENDING"   # the quote it held was replaced
    run_async(main())
