from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from psycopg import AsyncConnection

from app.core.config import Settings, get_settings
from app.core.errors import AppError
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.schemas.users import TenantRoleOut, TenantUserCreate, TenantUserOut
from app.services.users import UserService

router = APIRouter(prefix="/users", tags=["users"])


def _require_org_admin(principal: TenantPrincipal) -> None:
    if principal.role_code != "ADM":
        raise AppError("NO_PRIVILEGE", params={"privilege": "users.manage"})


@router.get("", response_model=list[TenantUserOut])
async def list_users(
    offset: int = Query(default=0, ge=0),
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    _require_org_admin(principal)
    return await UserService(conn, get_settings()).list_users(offset)


@router.get("/roles", response_model=list[TenantRoleOut])
async def list_assignable_roles(
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    _require_org_admin(principal)
    return await UserService(conn, get_settings()).list_roles()


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: TenantUserCreate,
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
    settings: Settings = Depends(get_settings),
):
    _require_org_admin(principal)
    user_id = await UserService(conn, settings).create_user(payload)
    return {"id": str(user_id), "must_change_password": True}


@router.post("/{user_id}/password-reset", status_code=status.HTTP_204_NO_CONTENT)
async def reset_user_password(
    user_id: UUID,
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
    settings: Settings = Depends(get_settings),
) -> Response:
    _require_org_admin(principal)
    await UserService(conn, settings).reset_password(user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
