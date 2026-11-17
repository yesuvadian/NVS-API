from __future__ import annotations

from typing import Any
from uuid import UUID

from psycopg import AsyncConnection


class OrganisationRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def list(
        self, *, query: str | None, status: str | None, limit: int, offset: int
    ) -> list[dict[str, Any]]:
        result = await self.conn.execute(
            "SELECT * FROM platform.search_tenants(%s,%s,%s,%s)",
            (query, status, limit, offset),
        )
        return await result.fetchall()

    async def get(self, tenant_id: UUID) -> dict[str, Any] | None:
        result = await self.conn.execute(
            "SELECT * FROM platform.get_tenant(%s)",
            (tenant_id,),
        )
        return await result.fetchone()

    async def provision(
        self,
        *,
        code: str,
        name: str,
        admin_name: str,
        admin_mobile: str,
        admin_email: str,
        optional_modules: list[str],
        features: list[str],
        platform_user_id: UUID,
        is_sandbox: bool,
        time_zone: str,
    ) -> UUID:
        result = await self.conn.execute(
            """
            SELECT platform.provision_tenant(
                %s, %s, %s, %s, %s, %s::text[], %s::text[], %s, %s, %s
            ) AS tenant_id
            """,
            (
                code,
                name,
                admin_name,
                admin_mobile,
                admin_email,
                optional_modules,
                features,
                platform_user_id,
                is_sandbox,
                time_zone,
            ),
        )
        row = await result.fetchone()
        return row["tenant_id"]

