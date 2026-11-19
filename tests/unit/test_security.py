from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from app.core.config import Settings
from app.core.permissions import ROLE_PERMISSIONS, require_platform_permission
from app.core.security import PlatformPrincipal, require_super_admin


def make_settings(*, require_mfa: bool = True) -> Settings:
    return Settings(
        _env_file=None,
        platform_jwt_secret="unit-test-secret-that-is-long-enough-for-hs256",
        platform_jwt_issuer="test-issuer",
        platform_jwt_audience="test-audience",
        require_platform_mfa=require_mfa,
    )


def make_token(settings: Settings, *, role: str = "SUPER_ADMIN", mfa_verified: bool = True) -> str:
    now = datetime.now(UTC)
    return jwt.encode(
        {
            "sub": str(uuid4()),
            "sid": str(uuid4()),
            "iss": settings.platform_jwt_issuer,
            "aud": settings.platform_jwt_audience,
            "iat": now,
            "exp": now + timedelta(minutes=5),
            "platform_role": role,
            "mfa_verified": mfa_verified,
        },
        settings.platform_jwt_secret.get_secret_value(),
        algorithm="HS256",
    )


@pytest.mark.parametrize(
    ("role", "mfa_verified", "require_mfa", "expected_status"),
    [
        ("SUPER_ADMIN", True, True, None),
        ("SUPER_ADMIN", False, True, 403),
        ("SUPER_ADMIN", False, False, None),
        ("SUPPORT", True, False, 403),
    ],
)
def test_platform_token_enforces_role_and_configured_mfa(
    role: str, mfa_verified: bool, require_mfa: bool, expected_status: int | None
) -> None:
    settings = make_settings(require_mfa=require_mfa)
    credentials = HTTPAuthorizationCredentials(
        scheme="Bearer", credentials=make_token(settings, role=role, mfa_verified=mfa_verified)
    )

    if expected_status:
        with pytest.raises(HTTPException) as exc_info:
            import asyncio

            asyncio.run(require_super_admin(credentials, settings))
        assert exc_info.value.status_code == expected_status
    else:
        import asyncio

        principal = asyncio.run(require_super_admin(credentials, settings))
        assert principal.role == "SUPER_ADMIN"
        assert principal.mfa_verified is mfa_verified


def test_invalid_or_missing_bearer_token_is_unauthorized() -> None:
    import asyncio

    settings = make_settings()
    with pytest.raises(HTTPException) as missing:
        asyncio.run(require_super_admin(None, settings))
    assert missing.value.status_code == 401

    invalid = HTTPAuthorizationCredentials(scheme="Bearer", credentials="not-a-jwt")
    with pytest.raises(HTTPException) as malformed:
        asyncio.run(require_super_admin(invalid, settings))
    assert malformed.value.status_code == 401


@pytest.mark.parametrize("permission", sorted(ROLE_PERMISSIONS["SUPER_ADMIN"]))
def test_super_admin_permission_catalog_includes_declared_permissions(permission: str) -> None:
    assert permission in ROLE_PERMISSIONS["SUPER_ADMIN"]


def test_platform_permission_rejects_roles_without_explicit_grant() -> None:
    import asyncio

    check = require_platform_permission("tenants:can_view")
    support = PlatformPrincipal(user_id=uuid4(), session_id=uuid4(), role="SUPPORT", mfa_verified=True)

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(check(principal=support))
    assert exc_info.value.status_code == 403
    assert exc_info.value.detail == {
        "shortCode": "NO_PRIVILEGE",
        "params": {"privilege": "tenants:can_view"},
    }
