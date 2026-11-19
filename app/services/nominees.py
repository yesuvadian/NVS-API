from __future__ import annotations

from typing import Any
from uuid import UUID

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.repositories.nominees import NomineeRepository


class NomineeService:
    """Member nominees. The rules (same organisation, not self, nominee status,
    no duplicate, MEMBER_RULES / NOMINATIONS limits, row versions) are enforced
    by the SQL functions in db/31d; failures arrive as catalogue short codes."""

    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = NomineeRepository(conn)

    async def list(self, member_id: UUID, *, include_inactive: bool = False) -> list[dict[str, Any]]:
        return await self.repository.list(member_id, include_inactive)

    async def add(self, member_id: UUID, nominee_member_id: UUID, relationship: str) -> dict[str, Any]:
        if nominee_member_id == member_id:
            raise AppError("NOMINEE_IS_SELF")
        return await self.repository.add(member_id, nominee_member_id, relationship)

    async def update(self, nominee_id: UUID, relationship: str, expected_version: int | None) -> dict[str, Any]:
        if expected_version is None:
            raise AppError("ROW_VERSION_REQUIRED")
        return await self.repository.update(nominee_id, relationship, expected_version)

    async def set_status(
        self, nominee_id: UUID, status: str, expected_version: int | None, reason: str
    ) -> dict[str, Any]:
        if expected_version is None:
            raise AppError("ROW_VERSION_REQUIRED")
        return await self.repository.set_status(nominee_id, status, expected_version, reason.strip())
