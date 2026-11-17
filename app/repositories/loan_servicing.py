"""Thin calls into the loan recovery, waiver, override and write-off routines
(db/35_functions_loan_recovery.sql). All rules and approvals live in PostgreSQL."""

from typing import Any

from psycopg import AsyncConnection
from psycopg.types.json import Jsonb


class LoanServicingRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def call(self, function: str, *args: Any) -> Any:
        params = tuple(Jsonb(a) if isinstance(a, (dict, list)) else a for a in args)
        placeholders = ",".join(["%s"] * len(params))
        row = await (await self.conn.execute(
            f"SELECT loan.{function}({placeholders}) AS result", params
        )).fetchone()
        return row["result"] if row else None
