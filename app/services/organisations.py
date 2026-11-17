from uuid import UUID

from psycopg import AsyncConnection, errors

from app.core.errors import AppError
from app.repositories.organisations import OrganisationRepository


class OrganisationService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = OrganisationRepository(conn)

    async def list(self, *, query: str | None, status_filter: str | None, limit: int, offset: int):
        return await self.repository.list(query=query, status=status_filter, limit=limit, offset=offset)

    async def get(self, tenant_id: UUID):
        tenant = await self.repository.get(tenant_id)
        if tenant is None:
            raise AppError("ORGANISATION_NOT_FOUND")
        return tenant

    async def create(self, payload, platform_user_id: UUID):
        try:
            tenant_id = await self.repository.provision(
                code=payload.code,
                name=payload.name,
                admin_name=payload.admin_name,
                admin_mobile=payload.admin_mobile,
                admin_email=payload.admin_email,
                optional_modules=payload.optional_modules,
                features=payload.features,
                platform_user_id=platform_user_id,
                is_sandbox=payload.is_sandbox,
                time_zone=payload.time_zone,
            )
        except errors.UniqueViolation:
            raise AppError("ORGANISATION_CODE_EXISTS") from None
        # Rules raised by platform.provision_tenant (app.fail) reach the database
        # error handler, which returns their catalogue code and localised message.
        return await self.get(tenant_id)

