from collections.abc import AsyncIterator

from fastapi import Depends, Request
from psycopg import AsyncConnection

from app.core.config import Settings, get_settings
from app.core.errors import AppError
from app.core.security import PlatformPrincipal, require_super_admin
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.context import set_signed_platform_context, set_signed_tenant_context


async def get_platform_db(
    request: Request,
    principal: PlatformPrincipal = Depends(require_super_admin),
    settings: Settings = Depends(get_settings),
) -> AsyncIterator[AsyncConnection]:
    database = request.app.state.database
    async with database.pool.connection() as conn:
        async with conn.transaction():
            await set_signed_platform_context(conn, principal, request, settings)
            yield conn


async def get_tenant_db(
    request: Request,
    principal: TenantPrincipal = Depends(require_tenant_user),
    settings: Settings = Depends(get_settings),
) -> AsyncIterator[AsyncConnection]:
    database = request.app.state.database
    async with database.pool.connection() as conn:
        async with conn.transaction():
            await set_signed_tenant_context(conn, principal, request, settings)
            access = await (
                await conn.execute(
                    "SELECT * FROM iam.get_tenant_access(%s,%s,%s,%s,%s)",
                    (
                        principal.tenant_id,
                        principal.user_id,
                        principal.role_code,
                        principal.working_date,
                        principal.channel,
                    ),
                )
            ).fetchone()
            if access is None:
                raise AppError("TENANT_ACCESS_INACTIVE")
            if access["requires_mfa"] and not principal.mfa_verified:
                raise AppError("MFA_NOT_VERIFIED")
            yield conn

