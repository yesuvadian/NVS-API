from uuid import UUID

from fastapi import APIRouter, Depends, Path
from psycopg import AsyncConnection

from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.schemas.access_control import RolePrivilegeChange, RolePrivilegeChangeOut, RolePrivilegeMatrixOut
from app.services.access_control import AccessControlService

router = APIRouter(prefix="/roles", tags=["roles and privileges"])


@router.get("/privileges", response_model=RolePrivilegeMatrixOut)
async def role_privilege_matrix(
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("user_role.view")),
):
    """Active roles with their privileges and the actions of each enabled module."""
    return await AccessControlService(conn).role_matrix()


@router.put("/{role_id}/privileges/{privilege_code}", response_model=RolePrivilegeChangeOut)
async def set_role_privilege(
    role_id: UUID,
    payload: RolePrivilegeChange,
    privilege_code: str = Path(pattern=r"^[a-z_]+\.[a-z]+$", max_length=80),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("user_role.edit")),
):
    """Grant or revoke one privilege on a role. Applies immediately and is
    audited. Refused: removing role management from your own role, granting
    for a disabled module, platform-protected privileges, read-only roles."""
    return await AccessControlService(conn).set_role_privilege(
        role_id, privilege_code, granted=payload.granted, reason=payload.reason
    )
