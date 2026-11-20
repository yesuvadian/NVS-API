import json
from decimal import Decimal
from typing import Any
from uuid import UUID

from psycopg import AsyncConnection
from psycopg.types.json import Jsonb


DEFAULT_ALLOCATION_ORDER = ("LATE_FEE", "PENALTY", "OVERDUE_INTEREST", "OVERDUE_PRINCIPAL",
                            "CURRENT_INTEREST", "CURRENT_PRINCIPAL")


def allocation_order(configured: list[str] | None = None) -> list[str]:
    """Mirror of loan.allocation_order: configured buckets first, unknown ones ignored,
    the penalty kept next to late fees when not named, the rest appended in the default order."""
    order: list[str] = []
    for item in configured or []:
        bucket = str(item).upper()
        if bucket in DEFAULT_ALLOCATION_ORDER and bucket not in order:
            order.append(bucket)
    if "LATE_FEE" in order and "PENALTY" not in order:
        order.insert(order.index("LATE_FEE") + 1, "PENALTY")
    return order + [b for b in DEFAULT_ALLOCATION_ORDER if b not in order]


def allocate_due_repayment(amount: Decimal, instalments: list[dict[str, Any]],
                           order: list[str] | None = None,
                           ) -> tuple[list[tuple[UUID, str, Decimal]], Decimal, Decimal]:
    """Mirror the database allocation (loan.collect_repayment) for fast unit tests.

    Rows flagged ``overdue`` are paid bucket by bucket in the allocation order
    (late fees, penalty, overdue interest, overdue principal by default); the
    remaining rows are current or advance instalments, paid interest then
    principal each, oldest first. Returns (allocations, principal, interest).
    """
    remaining = Decimal(amount)
    totals = {"PRINCIPAL": Decimal(0), "INTEREST": Decimal(0)}
    allocations: list[tuple[UUID, str, Decimal]] = []
    overdue = [r for r in instalments if r.get("overdue")]
    current = [r for r in instalments if not r.get("overdue")]
    fields = {"LATE_FEE": "late_fee_open", "PENALTY": "penalty_open",
              "INTEREST": "interest_open", "PRINCIPAL": "principal_open"}

    def take(row: dict[str, Any], component: str) -> None:
        nonlocal remaining
        part = min(remaining, Decimal(str(row.get(fields[component]) or 0)))
        if part > 0:
            allocations.append((row["id"], component, part))
            totals[component] = totals.get(component, Decimal(0)) + part
            remaining -= part

    for bucket in allocation_order(order):
        if remaining == 0:
            break
        if bucket in ("LATE_FEE", "PENALTY"):
            for row in instalments:
                take(row, bucket)
        elif bucket.startswith("OVERDUE_"):
            for row in overdue:
                take(row, bucket.removeprefix("OVERDUE_"))
        elif bucket == "CURRENT_INTEREST":
            for row in current:
                take(row, "INTEREST")
                take(row, "PRINCIPAL")
    if remaining > 0:
        from app.core.errors import AppError

        raise AppError("REPAYMENT_EXCEEDS_DUES")
    return allocations, totals["PRINCIPAL"], totals["INTEREST"]


class LoanLifecycleRepository:
    """Thin calls into transactional PostgreSQL routines; no business DML lives here."""

    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def collect_fee(self, loan_id: UUID, payment_mode: str,
                          payment_reference: str | None) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT loan.collect_application_fee(%s,%s,%s) AS result",
            (loan_id,payment_mode,payment_reference),
        )).fetchone()
        return row["result"] if row else None

    async def decide(self, request_id: UUID, values: dict[str, Any]) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            """SELECT loan.record_approval_decision(%s,%s,%s,%s,%s) AS result""",
            (request_id,values["decision"],values.get("reason"),
             values.get("approved_amount"),values.get("tenure_months")),
        )).fetchone()
        return row["result"] if row else None

    async def record_offline_approval(self, request_id: UUID, details: dict[str, Any]) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT loan.record_offline_approval(%s,%s::jsonb) AS result",
            (request_id, json.dumps(details, default=str)),
        )).fetchone()
        return row["result"] if row else None

    async def prepare_disbursement(self, loan_id: UUID, amount: Decimal, payment_mode: str = "CASH",
                                   payment_reference: str | None = None) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT loan.prepare_disbursement(%s,%s,%s,%s) AS result",
            (loan_id, amount, payment_mode.upper(), payment_reference)
        )).fetchone()
        return row["result"] if row else None

    async def release_disbursement(self, loan_id: UUID, disbursement_id: UUID,
                                   ack_type: str) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT loan.release_disbursement(%s,%s,%s) AS result",
            (loan_id,disbursement_id,ack_type),
        )).fetchone()
        return row["result"] if row else None

    async def collect_repayment(self, loan_id: UUID, amount: Decimal, payment_mode: str,
                               payment_reference: str | None) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT loan.collect_repayment(%s,%s,%s,%s) AS result",
            (loan_id,amount,payment_mode,payment_reference),
        )).fetchone()
        return row["result"] if row else None

    async def update_application(self, loan_id: UUID, values: dict[str, Any],
                                 expected_version: int | None) -> dict[str, Any] | None:
        payload = {k: (str(v) if isinstance(v, (Decimal, UUID)) else
                       [str(x) for x in v] if isinstance(v, list) else v) for k, v in values.items()}
        return await self._scalar(
            "SELECT loan.update_application(%s,%s,%s) AS result", (loan_id, Jsonb(payload), expected_version)
        )

    async def missing_documents(self, loan_id: UUID) -> list[str] | None:
        return await self._scalar("SELECT loan.missing_documents(%s) AS result", (loan_id,))

    async def guarantors(self, loan_id: UUID) -> list[dict[str, Any]] | None:
        return await self._scalar("SELECT loan.list_guarantors(%s) AS result", (loan_id,))

    async def _scalar(self, sql: str, params: tuple) -> Any:
        row = await (await self.conn.execute(sql, params)).fetchone()
        return row["result"] if row else None

    async def schedule(self, loan_id: UUID) -> dict[str, Any] | None:
        return await self._scalar("SELECT loan.get_schedule(%s) AS result", (loan_id,))

    async def repayments(self, loan_id: UUID) -> list[dict[str, Any]] | None:
        return await self._scalar("SELECT loan.get_repayments(%s) AS result", (loan_id,))

    async def member_statement(self, member_id: UUID) -> dict[str, Any] | None:
        return await self._scalar("SELECT loan.get_member_loan_statement(%s) AS result", (member_id,))

    async def quote_settlement(self, loan_id: UUID, interest_waiver: Decimal = Decimal(0),
                               waiver_reason: str | None = None) -> dict[str, Any] | None:
        return await self._scalar(
            "SELECT loan.quote_early_settlement(%s,%s,%s) AS result", (loan_id, interest_waiver, waiver_reason)
        )

    async def approve_settlement(self, settlement_id: UUID, remarks: str | None) -> dict[str, Any] | None:
        return await self._scalar(
            "SELECT loan.approve_early_settlement(%s,%s) AS result", (settlement_id, remarks)
        )

    async def collect_settlement(self, settlement_id: UUID, payment_mode: str,
                                 payment_reference: str | None) -> dict[str, Any] | None:
        return await self._scalar(
            "SELECT loan.collect_early_settlement(%s,%s,%s) AS result",
            (settlement_id, payment_mode, payment_reference),
        )

    async def settlement(self, settlement_id: UUID) -> dict[str, Any] | None:
        return await self._scalar("SELECT loan.get_settlement(%s) AS result", (settlement_id,))

    async def settlements(self, loan_id: UUID) -> list[dict[str, Any]] | None:
        return await self._scalar("SELECT loan.list_settlements(%s) AS result", (loan_id,))
