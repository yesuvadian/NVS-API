"""API tests for the Overview summary endpoints (dependency overrides, fake DB)."""

from collections import deque
from datetime import UTC, date, datetime, timedelta
from uuid import uuid4

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.config import Settings, get_settings
from app.core.errors import install_error_handlers
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_platform_db, get_tenant_db
from app.routers import dashboard, super_admin


class FakeResult:
    def __init__(self, one=None) -> None:
        self.one = one

    async def fetchone(self):
        return self.one

    async def fetchall(self):
        return [] if self.one is None else [self.one]


class FakeConnection:
    def __init__(self) -> None:
        self.results: deque[FakeResult] = deque()
        self.calls: list[tuple[str, tuple | None]] = []

    def script(self, *rows) -> None:
        self.results.extend(FakeResult(row) for row in rows)

    async def execute(self, query: str, params=None):
        self.calls.append((query, params))
        if not self.results:
            raise AssertionError("Unexpected database query with no scripted result.")
        return self.results.popleft()


SETTINGS = Settings(
    _env_file=None,
    platform_jwt_secret="integration-test-secret-that-is-long-enough",
    platform_jwt_issuer="test-issuer",
    platform_jwt_audience="test-audience",
    require_platform_mfa=True,
)


def platform_headers(role="SUPER_ADMIN", mfa=True) -> dict[str, str]:
    now = datetime.now(UTC)
    token = jwt.encode(
        {"sub": str(uuid4()), "sid": str(uuid4()), "iss": SETTINGS.platform_jwt_issuer,
         "aud": SETTINGS.platform_jwt_audience, "iat": now, "exp": now + timedelta(hours=1),
         "platform_role": role, "mfa_verified": mfa},
        SETTINGS.platform_jwt_secret.get_secret_value(), algorithm="HS256")
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def api():
    connection = FakeConnection()
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="MGR",
                                channel="WEB", mfa_verified=False, working_date=date(2026, 11, 19))
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(super_admin.router, prefix="/api/v1")
    app.include_router(dashboard.router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_platform_db] = fake_db
    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[get_settings] = lambda: SETTINGS
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app), connection, principal


PLATFORM_SUMMARY = {
    "organisations": {"total": 3, "by_status": {"ACTIVE": 2, "PROVISIONING": 0, "SUSPENDED": 0, "CLOSED": 1}},
    "newest_organisations": [
        {"id": str(uuid4()), "code": "demo", "name": "Demo Society", "status": "ACTIVE",
         "created_at": "2026-11-18T10:00:00+00:00"},
    ],
}


def test_platform_summary_returns_counts_and_newest(api) -> None:
    client, connection, _ = api
    connection.script({"summary": PLATFORM_SUMMARY})

    response = client.get("/api/v1/super-admin/summary", headers=platform_headers())

    assert response.status_code == 200
    body = response.json()
    assert body["organisations"]["total"] == 3
    assert body["organisations"]["by_status"]["CLOSED"] == 1
    assert body["newest_organisations"][0]["code"] == "demo"
    assert connection.calls == [("SELECT platform.get_platform_summary() AS summary", None)]


@pytest.mark.parametrize(("headers", "expected"), [({}, 401), ("support", 403), ("no_mfa", 403)])
def test_platform_summary_requires_super_admin(api, headers, expected) -> None:
    client, connection, _ = api
    if headers == "support":
        headers = platform_headers(role="SUPPORT")
    elif headers == "no_mfa":
        headers = platform_headers(mfa=False)

    response = client.get("/api/v1/super-admin/summary", headers=headers)

    assert response.status_code == expected
    assert connection.calls == []


def test_tenant_summary_includes_only_permitted_sections(api) -> None:
    client, connection, principal = api
    connection.script(
        {"capabilities": {"role_code": "MGR", "privileges": ["loan.approve", "loan.view", "member.view"]}},
        {"summary": {"working_date": "2026-11-19", "members": {"total": 5, "active": 4},
                     "loans": {"open_applications": 2}, "approvals": {"pending": 1}}},
    )

    response = client.get("/api/v1/tenant/summary")

    assert response.status_code == 200
    assert response.json() == {
        "working_date": "2026-11-19",
        "sections": ["members", "loans", "approvals"],
        "members": {"total": 5, "active": 4},
        "loans": {"open_applications": 2},
        "approvals": {"pending": 1},
    }
    assert connection.calls[0][1] == (principal.role_code,)
    assert connection.calls[1][1] == (["members", "loans", "approvals"],)


def test_tenant_summary_collections_amount_is_returned(api) -> None:
    client, connection, _ = api
    connection.script(
        {"capabilities": {"privileges": ["loan_repay.view"]}},
        {"summary": {"working_date": "2026-11-19",
                     "collections": {"date": "2026-11-19", "count": 2, "amount": 1500.5}}},
    )

    body = client.get("/api/v1/tenant/summary").json()

    assert body["sections"] == ["collections"]
    assert body["collections"]["count"] == 2
    assert float(body["collections"]["amount"]) == 1500.5
    assert "members" not in body


def test_tenant_summary_without_privilege_is_403(api) -> None:
    client, connection, _ = api
    connection.script({"capabilities": {"privileges": ["member.create"]}})

    response = client.get("/api/v1/tenant/summary")

    assert response.status_code == 403
    assert response.json()["detail"]["shortCode"] == "NO_PRIVILEGE"
    assert len(connection.calls) == 1  # summary not computed
