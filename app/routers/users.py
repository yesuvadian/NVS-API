from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from psycopg import AsyncConnection

from app.core.config import Settings, get_settings
from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.schemas.users import TenantRoleOut, TenantUserCreate, TenantUserOut
from app.services.users import UserService

router = APIRouter(prefix="/users", tags=["users"])


# Gated by USER_ROLE privileges (not the role code), so an Org Admin can grant
# or revoke user management per role in Roles & privileges.
@router.get("", response_model=list[TenantUserOut])
async def list_users(
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("user_role.view")),
):
    return await UserService(conn, get_settings()).list_users(offset)


@router.get("/roles", response_model=list[TenantRoleOut])
async def list_assignable_roles(
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("user_role.view")),
):
    return await UserService(conn, get_settings()).list_roles()


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: TenantUserCreate,
    conn: AsyncConnection = Depends(get_tenant_db),
    settings: Settings = Depends(get_settings),
    _principal: TenantPrincipal = Depends(require_tenant_permission("user_role.create")),
):
    user_id = await UserService(conn, settings).create_user(payload)
    return {"id": str(user_id), "must_change_password": True}


@router.post("/{user_id}/password-reset", status_code=status.HTTP_204_NO_CONTENT)
async def reset_user_password(
    user_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    settings: Settings = Depends(get_settings),
    _principal: TenantPrincipal = Depends(require_tenant_permission("user_role.edit")),
) -> Response:
    await UserService(conn, settings).reset_password(user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
