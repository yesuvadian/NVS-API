from dataclasses import dataclass
from uuid import UUID

import jwt
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import Settings, get_settings
from app.core.errors import AppError

bearer_scheme = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class PlatformPrincipal:
    user_id: UUID
    role: str
    mfa_verified: bool


async def require_super_admin(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> PlatformPrincipal:
    unauthorized = AppError("NOT_SIGNED_IN", headers={"WWW-Authenticate": "Bearer"})
    if credentials is None or settings.platform_jwt_secret is None:
        raise unauthorized

    try:
        claims = jwt.decode(
            credentials.credentials,
            settings.platform_jwt_secret.get_secret_value(),
            algorithms=["HS256"],
            issuer=settings.platform_jwt_issuer,
            audience=settings.platform_jwt_audience,
            options={"require": ["sub", "iss", "aud", "exp"]},
        )
        principal = PlatformPrincipal(
            user_id=UUID(claims["sub"]),
            role=str(claims.get("platform_role", "")),
            mfa_verified=claims.get("mfa_verified") is True,
        )
    except (jwt.InvalidTokenError, KeyError, TypeError, ValueError):
        raise unauthorized from None

    if principal.role != "SUPER_ADMIN":
        raise AppError("SUPER_ADMIN_REQUIRED")
    if settings.require_platform_mfa and not principal.mfa_verified:
        raise AppError("MFA_NOT_VERIFIED")
    return principal

