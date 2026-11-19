import asyncio
from datetime import UTC, date, datetime, timedelta
from uuid import uuid4

import jwt
import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from app.core.config import Settings
from app.core.errors import AppError
from app.core.tenant_security import require_tenant_user


def make_settings() -> Settings:
    return Settings(
        _env_file=None,
        tenant_jwt_secret="tenant-test-secret-that-is-long-enough-for-hs256",
        tenant_jwt_issuer="tenant-test-issuer",
        tenant_jwt_audience="tenant-test-audience",
    )


def make_token(settings: Settings, *, channel: str = "WEB", must_change: bool = False) -> str:
    now = datetime.now(UTC)
    return jwt.encode(
        {
            "sub": str(uuid4()),
            "sid": str(uuid4()),
            "tenant_id": str(uuid4()),
            "role_code": "EMP",
            "must_change_password": must_change,
            "channel": channel,
            "working_date": "2026-11-15",
            "iss": settings.tenant_jwt_issuer,
            "aud": settings.tenant_jwt_audience,
            "iat": now,
            "exp": now + timedelta(minutes=10),
        },
        settings.tenant_jwt_secret.get_secret_value(),
        algorithm="HS256",
    )


def test_tenant_token_yields_tenant_scope_and_working_date() -> None:
    settings = make_settings()
    principal = asyncio.run(
        require_tenant_user(
            HTTPAuthorizationCredentials(scheme="Bearer", credentials=make_token(settings)),
            settings,
            None,
            "device-1",
        )
    )

    assert principal.role_code == "EMP"
    assert principal.channel == "WEB"
    assert principal.working_date == date(2026, 11, 15)
    assert principal.device == "device-1"


@pytest.mark.parametrize("channel", ["SUPER_ADMIN", "API", "DB"])
def test_tenant_token_rejects_non_client_channels(channel: str) -> None:
    settings = make_settings()
    credentials = HTTPAuthorizationCredentials(
        scheme="Bearer", credentials=make_token(settings, channel=channel)
    )

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(require_tenant_user(credentials, settings, None, None))

    assert exc_info.value.status_code == 401


def test_tenant_token_requires_configured_secret() -> None:
    settings = Settings(_env_file=None, tenant_jwt_secret=None)
    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(require_tenant_user(None, settings, None, None))
    assert exc_info.value.status_code == 401


def test_tenant_token_requires_initial_password_change_before_app_access() -> None:
    settings = make_settings()
    credentials = HTTPAuthorizationCredentials(
        scheme="Bearer", credentials=make_token(settings, must_change=True)
    )
    with pytest.raises(AppError) as exc_info:
        asyncio.run(require_tenant_user(credentials, settings, None, None))
    assert exc_info.value.short_code == "PASSWORD_CHANGE_REQUIRED"
