from __future__ import annotations

from typing import Any
from uuid import UUID

from psycopg import AsyncConnection


class NomineeRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def _value(self, sql: str, params: tuple) -> Any:
        row = await (await self.conn.execute(sql, params)).fetchone()
        return row["result"]

    async def list(self, member_id: UUID, include_inactive: bool) -> list[dict[str, Any]]:
        return await self._value("SELECT mbr.list_nominees(%s,%s) AS result", (member_id, include_inactive))

    async def add(
        self, member_id: UUID, nominee_member_id: UUID, relationship: str, override_reason: str | None = None
    ) -> dict[str, Any]:
        return await self._value(
            "SELECT mbr.add_nominee(%s,%s,%s,%s) AS result",
            (member_id, nominee_member_id, relationship, override_reason),
        )

    async def update(self, nominee_id: UUID, relationship: str, expected_version: int | None) -> dict[str, Any]:
        return await self._value(
            "SELECT mbr.update_nominee(%s,%s,%s) AS result", (nominee_id, relationship, expected_version)
        )

    async def set_status(
        self, nominee_id: UUID, status: str, expected_version: int | None, reason: str,
        limit_override: bool = False,
    ) -> dict[str, Any]:
        return await self._value(
            "SELECT mbr.set_nominee_status(%s,%s,%s,%s,%s) AS result",
            (nominee_id, status, expected_version, reason, limit_override),
        )
