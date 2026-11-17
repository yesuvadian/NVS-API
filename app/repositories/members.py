from typing import Any
from uuid import UUID

from psycopg import AsyncConnection
from psycopg.types.json import Jsonb


EDITABLE_FIELDS = frozenset(
    {
        "full_name",
        "date_of_birth",
        "gender",
        "mobile",
        "alt_mobile",
        "email",
        "address_line1",
        "address_line2",
        "city",
        "district",
        "state",
        "pincode",
        "preferred_language",
        "preferred_channel",
        "notes",
    }
)


class MemberRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def list(
        self, *, query: str | None, status: str | None, limit: int, offset: int
    ) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM mbr.search_members(%s,%s,%s,%s)",
            (query, status, limit, offset),
        )
        return await cursor.fetchall()

    async def get(self, member_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM mbr.get_member(%s)",
            (member_id,),
        )
        return await cursor.fetchone()

    async def create(self, values: dict[str, Any]) -> dict[str, Any]:
        cursor = await self.conn.execute(
            "SELECT mbr.create_member(%s::jsonb) AS member",
            (Jsonb(values),),
        )
        return (await cursor.fetchone())["member"]

    async def update(
        self, member_id: UUID, *, values: dict[str, Any], expected_version: int | None
    ) -> dict[str, Any] | None:
        changes = {key: value for key, value in values.items() if key in EDITABLE_FIELDS}
        if not changes:
            return await self.get(member_id)

        cursor = await self.conn.execute(
            "SELECT mbr.update_member(%s,%s::jsonb,%s) AS member",
            (member_id,Jsonb(changes),expected_version),
        )
        row = await cursor.fetchone()
        return row["member"] if row else None
