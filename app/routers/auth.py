from fastapi import APIRouter, Depends, Request
from psycopg import AsyncConnection
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import Settings, get_settings
from app.db.dependencies import get_auth_db
from app.db.dependencies import get_tenant_db, get_platform_db
from app.core.security import PlatformPrincipal, require_super_admin
from app.core.permissions import ROLE_PERMISSIONS
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.core.errors import AppError
from app.schemas.auth import InitialPasswordChangeRequest, LoginRequest, LoginResponse, PasswordChangeRequest
from app.services.auth import AuthService

router = APIRouter(prefix="/auth", tags=["authentication"])
bearer_scheme = HTTPBearer(auto_error=False)


@router.post("/login", response_model=LoginResponse)
async def login(
    payload: LoginRequest,
    request: Request,
    conn: AsyncConnection = Depends(get_auth_db),
    settings: Settings = Depends(get_settings),
) -> dict:
    return await AuthService(conn, settings).login(
        identifier=payload.user_id,
        password=payload.password,
        channel=payload.channel,
        request=request,
        device=request.headers.get("X-Device-Id"),
        force_logout=payload.force_logout,
    )


@router.post("/change-initial-password", response_model=LoginResponse)
async def change_initial_password(
    payload: InitialPasswordChangeRequest,
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    conn: AsyncConnection = Depends(get_auth_db),
    settings: Settings = Depends(get_settings),
) -> dict:
    if credentials is None:
        raise AppError("NOT_SIGNED_IN")
    return await AuthService(conn, settings).change_initial_password(
        token=credentials.credentials,
        current_password=payload.current_password,
        new_password=payload.new_password,
        request=request,
    )


@router.post("/logout", status_code=204)
async def logout(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    conn: AsyncConnection = Depends(get_auth_db),
    settings: Settings = Depends(get_settings),
) -> None:
    if credentials is None:
        raise AppError("NOT_SIGNED_IN")
    await AuthService(conn, settings).logout(credentials.credentials)


@router.post("/change-password", status_code=204)
async def change_password(
    payload: PasswordChangeRequest,
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
    settings: Settings = Depends(get_settings),
) -> None:
    await AuthService(conn, settings).change_password(
        tenant_id=principal.tenant_id, user_id=principal.user_id,
        channel=principal.channel, current_password=payload.current_password,
        new_password=payload.new_password,
    )


@router.get("/tenant-capabilities")
async def tenant_capabilities(
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    row = await (await conn.execute(
        "SELECT iam.get_user_capabilities(%s) AS capabilities", (principal.role_code,)
    )).fetchone()
    return row["capabilities"]


@router.get("/platform-capabilities")
async def platform_capabilities(
    principal: PlatformPrincipal = Depends(require_super_admin),
    conn: AsyncConnection = Depends(get_platform_db),
):
    return {
        "workspace": "SUPER_ADMIN",
        "permissions": sorted(ROLE_PERMISSIONS.get(principal.role, frozenset())),
    }
