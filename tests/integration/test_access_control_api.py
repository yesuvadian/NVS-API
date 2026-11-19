"""API tests for module switches and role privileges (dependency overrides, fake DB)."""

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
from app.routers import roles, super_admin


class FakeResult:
    def __init__(self, one=None, many=None) -> None:
        self.one = one
        self.many = many if many is not None else ([] if one is None else [one])

    async def fetchone(self):
        return self.one

    async def fetchall(self):
        return self.many


class FakeConnection:
    def __init__(self) -> None:
        self.results: deque[FakeResult] = deque()
        self.calls: list[tuple[str, tuple | None]] = []

    def script(self, *results: FakeResult) -> None:
        self.results.extend(results)

    async def execute(self, query: str, params=None):
        self.calls.append((query, params))
        if not self.results:
            raise AssertionError(f"Unexpected query: {query}")
        return self.results.popleft()


SETTINGS = Settings(
    _env_file=None,
    platform_jwt_secret="integration-test-secret-that-is-long-enough",
    platform_jwt_issuer="test-issuer",
    platform_jwt_audience="test-audience",
    require_platform_mfa=True,
)


def platform_headers(role="SUPER_ADMIN") -> dict[str, str]:
    now = datetime.now(UTC)
    token = jwt.encode(
        {"sub": str(uuid4()), "sid": str(uuid4()), "iss": SETTINGS.platform_jwt_issuer,
         "aud": SETTINGS.platform_jwt_audience, "iat": now, "exp": now + timedelta(hours=1),
         "platform_role": role, "mfa_verified": True},
        SETTINGS.platform_jwt_secret.get_secret_value(), algorithm="HS256")
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def api():
    connection = FakeConnection()
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="ADM",
                                channel="WEB", mfa_verified=False, working_date=date(2026, 11, 19))
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(super_admin.router, prefix="/api/v1")
    app.include_router(roles.router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_platform_db] = fake_db
    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[get_settings] = lambda: SETTINGS
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app), connection


def module(code="LOAN", enabled=True, version=1):
    return {"module_code": code, "module_name": code.title(), "module_type": "MODULE",
            "parent_module_code": None, "menu_order": 10, "is_core": False, "is_optional_legal": False,
            "is_enabled": enabled, "reason": None, "row_version": version, "updated_at": None}


ALLOWED = FakeResult({"allowed": True})
DENIED = FakeResult({"allowed": False})


# -- Super Admin: modules ------------------------------------------------------
def test_list_organisation_modules(api) -> None:
    client, connection = api
    tenant = uuid4()
    connection.script(FakeResult(many=[module("MEMBER"), module("LOAN", enabled=False)]))

    response = client.get(f"/api/v1/super-admin/organisations/{tenant}/modules", headers=platform_headers())

    assert response.status_code == 200
    assert [m["is_enabled"] for m in response.json()] == [True, False]
    assert connection.calls[0][1] == (tenant,)


def test_disable_module_passes_expected_version_and_returns_row(api) -> None:
    client, connection = api
    tenant = uuid4()
    connection.script(FakeResult(), FakeResult(many=[module("LOAN", enabled=False, version=4)]))

    response = client.put(f"/api/v1/super-admin/organisations/{tenant}/modules/loan",
                          json={"enabled": False, "reason": "Pause loans"},
                          headers={**platform_headers(), "X-Expected-Row-Version": "3"})

    assert response.status_code == 200, response.text
    assert response.json()["is_enabled"] is False and response.json()["row_version"] == 4
    assert connection.calls[0] == ("SELECT platform.set_tenant_module(%s,%s,%s,%s,%s,%s)",
                                   (tenant, "LOAN", False, "Pause loans", 3, False))


def test_module_toggle_needs_reason_and_super_admin(api) -> None:
    client, connection = api
    url = f"/api/v1/super-admin/organisations/{uuid4()}/modules/LOAN"
    assert client.put(url, json={"enabled": False, "reason": ""}, headers=platform_headers()).status_code == 422
    assert client.put(url, json={"enabled": False, "reason": "Pause"},
                      headers=platform_headers(role="SUPPORT")).status_code == 403
    assert client.put(url, json={"enabled": False, "reason": "Pause"}).status_code == 401
    assert connection.calls == []


# -- Tenant: role privileges ---------------------------------------------------
MATRIX = {
    "can_edit": True,
    "roles": [{"id": str(uuid4()), "role_code": "EMP", "role_name": "Community Employee", "role_type": "STANDARD",
               "status": "ACTIVE", "is_read_only": False, "is_my_role": False, "privileges": ["member.view"]}],
    "modules": [{"module_code": "MEMBER", "module_name": "Members", "actions": [
        {"privilege_code": "member.view", "type_code": "V", "name": "Members - View", "protected": False}]}],
}


def test_role_matrix_for_role_viewer(api) -> None:
    client, connection = api
    connection.script(ALLOWED, FakeResult({"matrix": MATRIX}))

    response = client.get("/api/v1/roles/privileges")

    assert response.status_code == 200
    assert response.json()["roles"][0]["privileges"] == ["member.view"]
    assert connection.calls[0][1][1] == "user_role.view"


def test_holder_of_role_edit_changes_privilege_immediately(api) -> None:
    client, connection = api
    role = uuid4()
    connection.script(ALLOWED, FakeResult({"result": {
        "role_id": str(role), "role_code": "EMP", "privilege_code": "member.view", "granted": False,
        "changed": True}}))

    response = client.put(f"/api/v1/roles/{role}/privileges/member.view",
                          json={"granted": False, "reason": "Front desk only"})

    assert response.status_code == 200, response.text
    assert response.json()["changed"] is True
    assert connection.calls[0][1][1] == "user_role.edit"
    assert connection.calls[1][1] == (role, "member.view", False, "Front desk only")


def test_user_without_role_edit_gets_403(api) -> None:
    client, connection = api
    connection.script(DENIED)

    response = client.put(f"/api/v1/roles/{uuid4()}/privileges/member.view", json={"granted": True})

    assert response.status_code == 403
    assert response.json()["detail"]["shortCode"] == "NO_PRIVILEGE"
    assert len(connection.calls) == 1


def test_invalid_privilege_code_is_rejected_without_a_change(api) -> None:
    client, connection = api
    connection.script(ALLOWED)
    response = client.put(f"/api/v1/roles/{uuid4()}/privileges/DROP TABLE", json={"granted": True})
    assert response.status_code == 422
    assert not any("set_role_privilege" in query for query, _ in connection.calls)
