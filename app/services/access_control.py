from __future__ import annotations

from typing import Any
from uuid import UUID

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.repositories.access_control import AccessControlRepository


class AccessControlService:
    """Organisation module switches (Super Admin) and role privileges (tenant).
    The rules live in the SQL functions of db/31c; failures arrive as their
    catalogue short codes through the database error handler."""

    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = AccessControlRepository(conn)

    async def list_modules(self, tenant_id: UUID) -> list[dict[str, Any]]:
        return await self.repository.list_tenant_modules(tenant_id)

    async def set_module(
        self, tenant_id: UUID, module_code: str, *, enabled: bool, reason: str,
        expected_version: int | None = None, legal_warning_ack: bool = False,
    ) -> dict[str, Any]:
        code = module_code.strip().upper()
        await self.repository.set_tenant_module(
            tenant_id, code, enabled, reason.strip(), expected_version, legal_warning_ack
        )
        module = next((m for m in await self.repository.list_tenant_modules(tenant_id)
                       if m["module_code"] == code), None)
        if module is None:
            raise AppError("UNKNOWN_MODULE")
        return module

    async def role_matrix(self) -> dict[str, Any]:
        return await self.repository.role_privilege_matrix()

    async def set_role_privilege(
        self, role_id: UUID, privilege_code: str, *, granted: bool, reason: str | None = None
    ) -> dict[str, Any]:
        return await self.repository.set_role_privilege(
            role_id, privilege_code.strip().lower(), granted, (reason or "").strip() or None
        )
