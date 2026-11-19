from dataclasses import dataclass
from datetime import date
from uuid import UUID

import jwt
from fastapi import Depends, Header
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import Settings, get_settings
from app.core.errors import AppError

tenant_bearer_scheme = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class TenantPrincipal:
    tenant_id: UUID
    user_id: UUID
    session_id: UUID
    role_code: str
    channel: str
    mfa_verified: bool
    must_change_password: bool = False
    working_date: date | None = None
    device: str | None = None


async def require_tenant_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(tenant_bearer_scheme),
    settings: Settings = Depends(get_settings),
    working_date: date | None = Header(default=None, alias="X-Working-Date"),
    device: str | None = Header(default=None, alias="X-Device-Id", max_length=200),
) -> TenantPrincipal:
    unauthorized = AppError("NOT_SIGNED_IN", headers={"WWW-Authenticate": "Bearer"})
    if credentials is None or settings.tenant_jwt_secret is None:
        raise unauthorized

    try:
        claims = jwt.decode(
            credentials.credentials,
            settings.tenant_jwt_secret.get_secret_value(),
            algorithms=["HS256"],
            issuer=settings.tenant_jwt_issuer,
            audience=settings.tenant_jwt_audience,
            options={"require": ["sub", "sid", "iss", "aud", "exp", "tenant_id", "role_code", "channel"]},
        )
        channel = str(claims["channel"]).upper()
        if channel not in {"WEB", "MOBILE"}:
            raise ValueError("Invalid channel")
        principal = TenantPrincipal(
            tenant_id=UUID(claims["tenant_id"]),
            user_id=UUID(claims["sub"]),
            session_id=UUID(claims["sid"]),
            role_code=str(claims["role_code"]).upper(),
            channel=channel,
            mfa_verified=claims.get("mfa_verified") is True,
            must_change_password=claims.get("must_change_password") is True,
            working_date=working_date or (
                date.fromisoformat(claims["working_date"]) if claims.get("working_date") else None
            ),
            device=device or claims.get("device"),
        )
        if principal.must_change_password:
            raise AppError("PASSWORD_CHANGE_REQUIRED")
        return principal
    except (jwt.InvalidTokenError, KeyError, TypeError, ValueError):
        raise unauthorized from None
