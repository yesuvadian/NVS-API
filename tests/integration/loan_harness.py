"""Shared harness for the loan module PostgreSQL integration tests.

Every scenario runs on one connection as the schema owner (CFMS_SEED_DB_USER in
.env, or CFMS_TEST_DATABASE_URL) inside a single transaction that is always
rolled back. Each scenario provisions its own throw-away organisation(s), so
the tests never depend on, or change, data already in the local database.
Row-level security still applies: the owner session only skips the context
signature, never the tenant filter.
"""

from __future__ import annotations

import asyncio
import json
import os
import secrets
import sys
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import Decimal
from typing import Any, Awaitable, Callable
from uuid import UUID

import psycopg
import pytest
from psycopg import AsyncConnection
from psycopg.pq import TransactionStatus
from psycopg.rows import dict_row

from app.core.config import DatabaseNotConfigured, get_settings
from app.core.errors import AppError
from app.services.loans import LoanService

LOAN_MODULES = ["LOAN", "LOAN_FEE", "LOAN_REPAY", "LOAN_SETTLE", "LOAN_DEFAULT", "NOMINEE"]
ROLES = {"EMP": "EMP", "EMP2": "EMP", "MGR": "MGR", "ACC": "ACC", "LDR": "LDR"}


class _Redacted(str):
    """Connection string that never shows its password in tracebacks or reports."""

    def __repr__(self) -> str:
        return "'<database connection from .env>'"


def owner_dsn() -> str:
    dsn = os.getenv("CFMS_TEST_DATABASE_URL")
    if dsn:
        return _Redacted(dsn)
    try:
        return _Redacted(get_settings().seed_database_url)
    except DatabaseNotConfigured as exc:
        pytest.skip(f"PostgreSQL not configured: {exc}")


def add_months(value: date, months: int) -> date:
    month = value.month - 1 + months
    year = value.year + month // 12
    month = month % 12 + 1
    return value.replace(year=year, month=month)


@dataclass
class Tenant:
    id: UUID
    code: str
    today: date
    d0: date
    users: dict[str, UUID] = field(default_factory=dict)
    members: dict[str, UUID] = field(default_factory=dict)
    nominees: dict[str, UUID] = field(default_factory=dict)
    loan_types: dict[str, UUID] = field(default_factory=dict)


class LoanDb:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn
        self._savepoint = 0

    # -- context and queries -------------------------------------------------
    async def act(self, tenant: Tenant | None, role: str | None, on: date | None) -> None:
        await self.conn.execute(
            "SELECT app.set_context(%s,%s,%s,'WEB',%s,NULL,NULL,true,NULL)",
            (tenant.id if tenant else None,
             tenant.users.get(role) if tenant and role else None,
             ROLES.get(role, role), on),
        )

    async def val(self, sql: str, params: tuple = ()) -> Any:
        row = await (await self.conn.execute(sql, params)).fetchone()
        return None if row is None else next(iter(row.values()))

    async def row(self, sql: str, params: tuple = ()) -> dict[str, Any] | None:
        return await (await self.conn.execute(sql, params)).fetchone()

    async def rows(self, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
        return await (await self.conn.execute(sql, params)).fetchall()

    @asynccontextmanager
    async def savepoint(self):
        """Manual savepoint that survives an aborted statement inside it."""
        self._savepoint += 1
        name = f"sp_{self._savepoint}"
        await self.conn.execute(f"SAVEPOINT {name}")
        try:
            yield
        finally:
            if self.conn.info.transaction_status == TransactionStatus.INERROR:
                await self.conn.execute(f"ROLLBACK TO SAVEPOINT {name}")
            else:
                await self.conn.execute(f"RELEASE SAVEPOINT {name}")

    async def fails(self, sql: str, params: tuple = (), *, code: str | None = None,
                    constraint: str | None = None) -> psycopg.Error:
        """Run SQL that must fail with the given app.fail short code or constraint."""
        error: psycopg.Error | None = None
        async with self.savepoint():
            try:
                await self.conn.execute(sql, params)
            except psycopg.Error as exc:
                error = exc
        assert error is not None, f"expected failure {code or constraint}: {sql}"
        if code:
            assert error.diag.message_hint == code, (code, error.diag.message_hint, error.diag.message_primary)
        if constraint:
            assert error.diag.constraint_name == constraint, (constraint, error.diag.constraint_name,
                                                              error.diag.message_primary)
        return error

    async def app_fails(self, code: str, action: Callable[[], Awaitable[Any]]) -> AppError | psycopg.Error:
        """Run a service call that must fail with an AppError or app.fail short code."""
        async with self.savepoint():
            try:
                await action()
            except AppError as exc:
                assert exc.short_code == code, (code, exc.short_code)
                return exc
            except psycopg.Error as exc:
                assert exc.diag.message_hint == code, (code, exc.diag.message_hint, exc.diag.message_primary)
                return exc
        raise AssertionError(f"expected {code}")

    # -- organisation set-up --------------------------------------------------
    async def new_tenant(self) -> Tenant:
        code = "zt" + secrets.token_hex(4)
        await self.conn.execute("SELECT app.clear_context()")   # provision as a platform caller
        tenant_id = await self.val(
            """SELECT platform.provision_tenant(p_code=>%s, p_name=>%s, p_admin_name=>'Test Admin',
                   p_admin_mobile=>'9000000001', p_admin_email=>%s, p_optional_modules=>%s)""",
            (code, f"Test Org {code}", f"admin@{code}.example.com", LOAN_MODULES),
        )
        today = await self.val("SELECT app.tenant_today(%s)", (tenant_id,))
        d0 = (today - timedelta(days=200)).replace(day=10)
        tenant = Tenant(id=tenant_id, code=code, today=today, d0=d0)
        admin = await self.val(
            "SELECT id FROM iam.app_user WHERE tenant_id=%s AND is_default_org_admin", (tenant_id,))
        await self.conn.execute(
            "SELECT app.set_context(%s,%s,'ADM','WEB',NULL,NULL,NULL,true,NULL)", (tenant_id, admin))
        first_fy = await self.val(
            "SELECT min(start_date) FROM acct.financial_year WHERE tenant_id=%s", (tenant_id,))
        if d0 < first_fy:
            await self.conn.execute("SELECT acct.create_financial_year(%s,%s)",
                                    (tenant_id, add_months(first_fy, -12)))
        for n, (key, role) in enumerate(ROLES.items()):
            user_id = await self.val(
                """INSERT INTO iam.app_user (tenant_id, full_name, mobile, email, web_access, mobile_access,
                                             username, primary_role_id)
                   VALUES (%s,%s,%s,%s,true,false,%s,
                           (SELECT id FROM iam.role WHERE tenant_id=%s AND role_code=%s)) RETURNING id""",
                (tenant_id, f"Test {key}", f"90000001{n:02d}", f"{key.lower()}@{code}.example.com",
                 f"{key.lower()}@{code}.example.com", tenant_id, role),
            )
            await self.conn.execute(
                """INSERT INTO iam.user_role (tenant_id, user_id, role_id, effective_from, reason)
                   VALUES (%s,%s,(SELECT id FROM iam.role WHERE tenant_id=%s AND role_code=%s),
                           current_date - 365, 'Test')""",
                (tenant_id, user_id, tenant_id, role),
            )
            tenant.users[key] = user_id
        members = {"A": ("ACTIVE", date(2019, 1, 1)), "B": ("ACTIVE", date(2019, 1, 1)),
                   "C": ("ACTIVE", date(2019, 1, 1)), "NEW": ("ACTIVE", d0 - timedelta(days=40)),
                   "APPLIED": ("APPLIED", None)}
        for n, (key, (status, joined)) in enumerate(members.items()):
            member_id = await self.val(
                """INSERT INTO mbr.member (tenant_id, member_no, full_name, mobile, membership_date, status,
                                           status_effective_date)
                   VALUES (%s, acct.next_number('MEMBER', NULL, %s), %s, %s, %s, %s, %s) RETURNING id""",
                (tenant_id, tenant_id, f"Member {key}", f"91000001{n:02d}", joined, status, joined),
            )
            tenant.members[key] = member_id
            tenant.nominees[key] = await self.val(
                """INSERT INTO mbr.nominee (tenant_id, member_id, full_name, relationship)
                   VALUES (%s,%s,%s,'SPOUSE') RETURNING id""",
                (tenant_id, member_id, f"Nominee {key}"),
            )
        for row in await self.rows("SELECT code, id FROM loan.loan_type WHERE tenant_id=%s", (tenant_id,)):
            tenant.loan_types[row["code"]] = row["id"]
        return tenant

    # -- loan lifecycle helpers ----------------------------------------------
    async def create_loan(self, t: Tenant, member: str = "A", amount: str = "12000.00", tenure: int = 12,
                          on: date | None = None, loan_type: str = "INTEREST_BEARING",
                          nominee: bool = True) -> dict[str, Any]:
        await self.act(t, "EMP", on or t.d0)
        return await LoanService(self.conn).create_application({
            "member_id": t.members[member], "loan_type_id": t.loan_types[loan_type],
            "requested_amount": Decimal(amount), "requested_tenure_months": tenure,
            "purpose": "Integration test", "nominee_ids": [t.nominees[member]] if nominee else []})

    async def submit(self, t: Tenant, loan_id: UUID, on: date | None = None) -> dict[str, Any]:
        await self.act(t, "EMP", on or t.d0)
        return await LoanService(self.conn).submit_application(loan_id)

    async def approve(self, t: Tenant, loan_id: UUID, on: date | None = None, **terms) -> dict[str, Any]:
        await self.act(t, "MGR", on or t.d0)
        request = await self.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan_id,))
        return await self.val("SELECT loan.record_approval_decision(%s,'APPROVED',NULL,%s,%s)",
                              (request, terms.get("amount"), terms.get("tenure")))

    async def prepare(self, t: Tenant, loan_id: UUID, amount: str, on: date | None = None) -> dict[str, Any]:
        await self.act(t, "EMP", on or t.d0)
        return await self.val("SELECT loan.prepare_disbursement(%s,%s)", (loan_id, Decimal(amount)))

    async def release(self, t: Tenant, loan_id: UUID, disbursement_id: UUID,
                      on: date | None = None) -> dict[str, Any]:
        await self.act(t, "MGR", on or t.d0)
        return await self.val("SELECT loan.release_disbursement(%s,%s,'SIGNATURE')", (loan_id, disbursement_id))

    async def approved_loan(self, t: Tenant, member: str = "A", amount: str = "12000.00", tenure: int = 12,
                            on: date | None = None, **kwargs) -> UUID:
        on = on or t.d0
        loan = await self.create_loan(t, member, amount, tenure, on, **kwargs)
        await self.submit(t, loan["id"], on)
        await self.approve(t, loan["id"], on)
        return loan["id"]

    async def active_loan(self, t: Tenant, member: str = "A", amount: str = "12000.00", tenure: int = 12,
                          on: date | None = None, **kwargs) -> UUID:
        on = on or t.d0
        loan_id = await self.approved_loan(t, member, amount, tenure, on, **kwargs)
        disbursement = await self.prepare(t, loan_id, amount, on)
        await self.release(t, loan_id, disbursement["disbursement_id"], on)
        return loan_id

    async def repay(self, t: Tenant, loan_id: UUID, amount: str, on: date) -> dict[str, Any]:
        await self.act(t, "EMP", on)
        return await self.val("SELECT loan.collect_repayment(%s,%s,'CASH')", (loan_id, Decimal(amount)))

    async def defaulted_loan(self, t: Tenant, member: str = "A", **kwargs) -> tuple[UUID, date]:
        """Active loan from d0 left unpaid until the daily job defaults it; returns (loan, default date)."""
        loan_id = await self.active_loan(t, member, **kwargs)
        on = add_months(t.d0, 3) + timedelta(days=1)
        await self.act(t, None, on)
        await self.val("SELECT loan.run_daily_status()")
        assert await self.status(loan_id) == "DEFAULTED"
        return loan_id, on

    async def set_setting(self, t: Tenant, key: str, value: Any) -> None:
        """Replace a tenant setting (owner session, test only)."""
        await self.act(t, None, t.d0)
        await self.conn.execute("DELETE FROM cfg.tenant_setting WHERE tenant_id=%s AND setting_key=%s", (t.id, key))
        await self.conn.execute(
            "INSERT INTO cfg.tenant_setting (tenant_id, setting_key, value, effective_from) VALUES (%s,%s,%s::jsonb,DATE '2000-01-01')",
            (t.id, key, json.dumps(value)))

    async def daily(self, t: Tenant, on: date) -> dict[str, Any]:
        await self.act(t, None, on)
        return await self.val("SELECT loan.run_daily_status()")

    async def messages(self, entity_id: UUID, code_text: str | None = None) -> list[dict[str, Any]]:
        return await self.rows(
            "SELECT recipient_type, status, suppress_reason, body FROM notif.notification_message "
            "WHERE entity_id=%s AND (%s::text IS NULL OR body ILIKE '%%' || %s || '%%') ORDER BY created_at",
            (entity_id, code_text, code_text))

    async def status(self, loan_id: UUID) -> str:
        return await self.val("SELECT status FROM loan.loan WHERE id=%s", (loan_id,))

    async def set_rule(self, loan_id: UUID, code: str, rule: dict[str, Any]) -> None:
        """Replace one rule in a loan's rule snapshot (owner session, test only)."""
        await self.conn.execute(
            """UPDATE loan.loan SET rule_snapshot = jsonb_set(rule_snapshot, '{rules}',
                   (SELECT jsonb_agg(r) FROM jsonb_array_elements(rule_snapshot->'rules') r
                     WHERE r->>'code' <> %s) || jsonb_build_array(%s::jsonb))
                WHERE id=%s""",
            (code, json.dumps({"code": code, **rule}), loan_id),
        )


def run_db(scenario: Callable[[LoanDb], Awaitable[None]]) -> None:
    """Run an async scenario in one rolled-back transaction."""
    dsn = owner_dsn()

    async def main() -> None:
        try:
            conn = await AsyncConnection.connect(dsn, row_factory=dict_row, connect_timeout=5)
        except psycopg.OperationalError as exc:
            pytest.skip(f"PostgreSQL not reachable: {exc}")
        try:
            async with conn.transaction(force_rollback=True):
                await scenario(LoanDb(conn))
        finally:
            await conn.close()

    run_async(main())


def run_async(coroutine) -> Any:
    """asyncio.run that also works on Windows: psycopg's async mode cannot use
    the default ProactorEventLoop there, so a SelectorEventLoop is used."""
    loop_factory = asyncio.SelectorEventLoop if sys.platform == "win32" else None
    with asyncio.Runner(loop_factory=loop_factory) as runner:
        return runner.run(coroutine)
