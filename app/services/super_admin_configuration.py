from uuid import UUID

from psycopg import AsyncConnection

from app.repositories.super_admin_configuration import SuperAdminConfigurationRepository


class SuperAdminConfigurationService:
    def __init__(self, conn: AsyncConnection):
        self.repository = SuperAdminConfigurationRepository(conn)

    async def list_for_organisation(self, tenant_id: UUID) -> dict:
        return await self.repository.list_for_organisation(tenant_id)

    async def validate(self, tenant_id: UUID, kind: str, code: str, definition: dict) -> dict:
        return await self.repository.validate(tenant_id, kind, code, definition)

    async def publish(self, tenant_id: UUID, kind: str, code: str, definition: dict,
                      reason: str, effective_from) -> dict:
        return await self.repository.publish(tenant_id, kind, code, definition, reason, effective_from)
