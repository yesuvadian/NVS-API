from __future__ import annotations

from typing import Any
from uuid import UUID

from psycopg import AsyncConnection


class AccessControlRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def list_tenant_modules(self, tenant_id: UUID) -> list[dict[str, Any]]:
        result = await self.conn.execute("SELECT * FROM platform.list_tenant_modules(%s)", (tenant_id,))
        return await result.fetchall()

    async def set_tenant_module(
        self, tenant_id: UUID, module_code: str, enabled: bool, reason: str,
        expected_version: int | None, legal_warning_ack: bool,
    ) -> None:
        await self.conn.execute(
            "SELECT platform.set_tenant_module(%s,%s,%s,%s,%s,%s)",
            (tenant_id, module_code, enabled, reason, expected_version, legal_warning_ack),
        )

    async def role_privilege_matrix(self) -> dict[str, Any]:
        result = await self.conn.execute("SELECT iam.get_role_privilege_matrix() AS matrix")
        row = await result.fetchone()
        return row["matrix"]

    async def set_role_privilege(
        self, role_id: UUID, privilege_code: str, granted: bool, reason: str | None
    ) -> dict[str, Any]:
        result = await self.conn.execute(
            "SELECT iam.set_role_privilege(%s,%s,%s,%s) AS result",
            (role_id, privilege_code, granted, reason),
        )
        row = await result.fetchone()
        return row["result"]
