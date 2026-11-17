from uuid import UUID

from app.core.errors import AppError
from psycopg import AsyncConnection

from app.repositories.members import MemberRepository


class MemberService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = MemberRepository(conn)

    async def list(self, *, query: str | None, status_filter: str | None, limit: int, offset: int):
        return await self.repository.list(
            query=query, status=status_filter, limit=limit, offset=offset
        )

    async def get(self, member_id: UUID):
        member = await self.repository.get(member_id)
        if member is None:
            raise AppError("MEMBER_NOT_FOUND")
        return member

    async def create(self, values: dict):
        return await self.repository.create(values)

    async def update(self, member_id: UUID, *, values: dict, expected_version: int | None):
        member = await self.repository.update(
            member_id, values=values, expected_version=expected_version
        )
        if member is not None:
            return member
        if expected_version is not None and await self.repository.get(member_id) is not None:
            raise AppError("STALE_RECORD")
        raise AppError("MEMBER_NOT_FOUND")
