from collections.abc import Awaitable, Callable

from fastapi import Depends
from psycopg import AsyncConnection

from app.core.errors import AppError
from app.core.security import PlatformPrincipal, require_super_admin
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db

# Keep this explicit and reviewable, like the method→action/module checks in
# Customer-API's auth_privilege middleware. Platform Support/Billing are future
# roles in CFMS and receive no permissions from this API slice.
ROLE_PERMISSIONS: dict[str, frozenset[str]] = {
    "SUPER_ADMIN": frozenset(
        {
            "tenants:can_view",
            "tenants:can_add",
            "language_packs:can_view",
            "language_packs:can_add",
            "language_packs:can_edit",
            "language_packs:can_approve",
        }
    ),
}


def require_platform_permission(permission: str) -> Callable[..., Awaitable[PlatformPrincipal]]:
    async def permission_checker(
        principal: PlatformPrincipal = Depends(require_super_admin),
    ) -> PlatformPrincipal:
        if permission not in ROLE_PERMISSIONS.get(principal.role, frozenset()):
            raise AppError("NO_PRIVILEGE", params={"privilege": permission})
        return principal

    return permission_checker


def require_tenant_permission(
    permission_code: str,
) -> Callable[..., Awaitable[TenantPrincipal]]:
    async def permission_checker(
        principal: TenantPrincipal = Depends(require_tenant_user),
        conn: AsyncConnection = Depends(get_tenant_db),
    ) -> TenantPrincipal:
        result = await conn.execute(
            "SELECT iam.has_privilege(%s, %s) AS allowed",
            (principal.user_id, permission_code),
        )
        row = await result.fetchone()
        if row is None or not row["allowed"]:
            raise AppError("NO_PRIVILEGE", params={"privilege": permission_code})
        return principal

    return permission_checker

