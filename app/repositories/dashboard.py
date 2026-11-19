from __future__ import annotations

from typing import Any

from psycopg import AsyncConnection


class DashboardRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def platform_summary(self) -> dict[str, Any]:
        result = await self.conn.execute("SELECT platform.get_platform_summary() AS summary")
        row = await result.fetchone()
        return row["summary"]

    async def tenant_privileges(self, role_code: str) -> list[str]:
        result = await self.conn.execute(
            "SELECT iam.get_user_capabilities(%s) AS capabilities", (role_code,)
        )
        row = await result.fetchone()
        capabilities = (row or {}).get("capabilities") or {}
        return list(capabilities.get("privileges") or [])

    async def tenant_summary(self, sections: list[str]) -> dict[str, Any]:
        result = await self.conn.execute(
            "SELECT core.get_tenant_summary(%s::text[]) AS summary", (sections,)
        )
        row = await result.fetchone()
        return row["summary"]
