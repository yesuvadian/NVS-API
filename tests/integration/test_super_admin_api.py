from collections import deque
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.config import Settings, get_settings
from app.db.dependencies import get_platform_db
from app.routers.super_admin import router


class FakeResult:
    def __init__(self, *, one=None, many=None) -> None:
        self.one = one
        self.many = many if many is not None else ([] if one is None else [one])

    async def fetchone(self):
        return self.one

    async def fetchall(self):
        return self.many


class FakeConnection:
    def __init__(self, *results: FakeResult) -> None:
        self.results = deque(results)
        self.calls: list[tuple[str, tuple | None]] = []

    async def execute(self, query: str, params=None):
        self.calls.append((query, params))
        if not self.results:
            raise AssertionError("Unexpected database query with no scripted result.")
        return self.results.popleft()


@pytest.fixture
def api_setup():
    settings = Settings(
        _env_file=None,
        platform_jwt_secret="integration-test-secret-that-is-long-enough",
        platform_jwt_issuer="test-issuer",
        platform_jwt_audience="test-audience",
        require_platform_mfa=True,
    )
    connection = FakeConnection()
    app = FastAPI()
    app.include_router(router, prefix="/api/v1")

    async def fake_database():
        yield connection

    app.dependency_overrides[get_platform_db] = fake_database
    app.dependency_overrides[get_settings] = lambda: settings
    return TestClient(app), connection, settings


def token(settings: Settings, *, role="SUPER_ADMIN", mfa=True) -> str:
    now = datetime.now(UTC)
    return jwt.encode(
        {
            "sub": str(uuid4()),
            "iss": settings.platform_jwt_issuer,
            "aud": settings.platform_jwt_audience,
            "iat": now,
            "exp": now + timedelta(days=1),
            "platform_role": role,
            "mfa_verified": mfa,
        },
        settings.platform_jwt_secret.get_secret_value(),
        algorithm="HS256",
    )


def auth_headers(settings: Settings, **claims) -> dict[str, str]:
    return {"Authorization": f"Bearer {token(settings, **claims)}"}


def test_organisation_list_routes_through_service_and_repository(api_setup) -> None:
    client, connection, settings = api_setup
    tenant_id = uuid4()
    connection.results.append(
        FakeResult(
            many=[
                {
                    "id": tenant_id,
                    "code": "demo",
                    "name": "Demo Trust",
                    "legal_name": None,
                    "status": "ACTIVE",
                    "is_sandbox": True,
                    "time_zone": "Asia/Kolkata",
                    "contact_email": "admin@example.test",
                    "contact_mobile": "+919000000000",
                    "created_at": datetime(2026, 1, 1, tzinfo=UTC),
                    "activated_at": None,
                }
            ]
        )
    )

    response = client.get(
        "/api/v1/super-admin/organisations?q=demo&status=ACTIVE&limit=25&offset=50",
        headers=auth_headers(settings),
    )

    assert response.status_code == 200
    assert response.json()[0]["id"] == str(tenant_id)
    assert response.json()[0]["code"] == "demo"
    assert len(connection.calls) == 1
    assert "platform.search_tenants" in connection.calls[0][0]
    assert connection.calls[0][1] == ("demo", "ACTIVE", 25, 50)


def test_create_organisation_calls_provisioning_repository_and_returns_record(api_setup) -> None:
    client, connection, settings = api_setup
    tenant_id = uuid4()
    created_at = datetime(2026, 1, 1, tzinfo=UTC)
    connection.results.extend(
        [
            FakeResult(one={"tenant_id": tenant_id}),
            FakeResult(
                one={
                    "id": tenant_id,
                    "code": "demo-org",
                    "name": "Demo Organisation",
                    "legal_name": None,
                    "status": "PROVISIONING",
                    "is_sandbox": True,
                    "time_zone": "Asia/Kolkata",
                    "contact_email": "admin@example.test",
                    "contact_mobile": "+919000000001",
                    "created_at": created_at,
                }
            ),
        ]
    )
    payload = {
        "code": "demo-org",
        "name": "Demo Organisation",
        "admin_name": "Admin User",
        "admin_mobile": "+919000000001",
        "admin_email": "admin@example.com",
        "optional_modules": [],
        "features": [],
        "is_sandbox": True,
    }

    response = client.post(
        "/api/v1/super-admin/organisations", json=payload, headers=auth_headers(settings)
    )

    assert response.status_code == 201, response.json()
    assert response.json()["id"] == str(tenant_id)
    assert response.json()["status"] == "PROVISIONING"
    assert len(connection.calls) == 2
    assert "platform.provision_tenant" in connection.calls[0][0]
    assert connection.calls[0][1][0:5] == (
        "demo-org",
        "Demo Organisation",
        "Admin User",
        "+919000000001",
        "admin@example.com",
    )


def test_draft_translation_endpoint_invokes_repository_transaction_steps(api_setup) -> None:
    client, connection, settings = api_setup
    connection.results.append(FakeResult(one={"active": True}))
    connection.results.append(FakeResult(one={"version_no": 4}))

    response = client.post(
        "/api/v1/super-admin/language-packs/ta/draft", headers=auth_headers(settings)
    )

    assert response.status_code == 201
    assert response.json() == {"language_code": "ta", "version_no": 4, "status": "DRAFT"}
    assert len(connection.calls) == 2
    assert "platform.is_active_language" in connection.calls[0][0]
    assert "platform.create_translation_draft" in connection.calls[1][0]


def test_translation_list_forwards_filters_and_pagination(api_setup) -> None:
    client, connection, settings = api_setup
    connection.results.append(FakeResult(one={"active": True}))
    connection.results.append(
        FakeResult(
            many=[
                {
                    "text_id": "HOME.TITLE",
                    "module_code": "CORE",
                    "text_type": "LABEL",
                    "english_text": "Home",
                    "translated_text": "முகப்பு",
                    "translation_status": "APPROVED",
                    "updated_at": datetime(2026, 1, 1, tzinfo=UTC),
                    "updated_by": uuid4(),
                }
            ]
        )
    )

    response = client.get(
        "/api/v1/super-admin/language-packs/ta/4/translations"
        "?q=HOME&module_code=CORE&text_type=LABEL&status=APPROVED&limit=20&offset=40",
        headers=auth_headers(settings),
    )

    assert response.status_code == 200
    assert response.json()[0]["text_id"] == "HOME.TITLE"
    assert "platform.search_translation_entries" in connection.calls[1][0]
    assert connection.calls[1][1] == (
        "ta",
        4,
        "HOME",
        "CORE",
        "LABEL",
        "APPROVED",
        False,
        20,
        40,
    )


def test_translation_not_found_maps_to_http_404(api_setup) -> None:
    client, connection, settings = api_setup
    connection.results.append(FakeResult(one={"active": True}))
    connection.results.append(FakeResult(one=None))

    response = client.put(
        "/api/v1/super-admin/language-packs/ta/4/translations/UNKNOWN.TEXT",
        headers=auth_headers(settings),
        json={"translated_text": "மொழிபெயர்ப்பு", "status": "DRAFT"},
    )

    assert response.status_code == 404
    assert response.json()["detail"]["shortCode"] == "TRANSLATION_TARGET_NOT_FOUND"


@pytest.mark.parametrize(
    ("headers", "expected_status"),
    [({}, 401), ("support", 403), ("no_mfa", 403)],
)
def test_protected_routes_enforce_bearer_role_and_mfa(api_setup, headers, expected_status) -> None:
    client, _, settings = api_setup
    if headers == "support":
        headers = auth_headers(settings, role="SUPPORT")
    elif headers == "no_mfa":
        headers = auth_headers(settings, mfa=False)

    response = client.get("/api/v1/super-admin/organisations", headers=headers)

    assert response.status_code == expected_status
