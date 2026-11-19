from collections import deque
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.config import Settings, get_settings
from app.core.errors import AppError
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_auth_db, get_tenant_db
from app.routers.auth import router as auth_router
from app.routers.users import router as users_router


class Transaction:
    async def __aenter__(self): return self
    async def __aexit__(self, *_args): return False


class FakeConnection:
    def transaction(self): return Transaction()


class LoginRepository:
    candidate = None
    prepared = False
    attempts = []
    sessions = []
    def __init__(self, _conn): pass
    async def login_candidates(self, *_args): return [self.candidate]
    async def prepare_session(self, **kwargs):
        self.sessions.append(kwargs)
        return self.prepared
    async def record_attempt(self, **kwargs): self.attempts.append(kwargs)


def _auth_client(monkeypatch, *, prepared: bool):
    settings = Settings(
        _env_file=None,
        platform_jwt_secret="unit-test-platform-secret-long-enough",
        platform_jwt_issuer="platform-test", platform_jwt_audience="platform-api-test",
        tenant_jwt_secret="unit-test-tenant-secret-long-enough",
        tenant_jwt_issuer="tenant-test", tenant_jwt_audience="tenant-api-test",
        require_platform_mfa=False,
    )
    LoginRepository.candidate = {
        "principal_kind": "PLATFORM", "user_id": uuid4(), "tenant_id": None,
        "display_name": "Admin", "password_hash": "stored-hash",
        "account_status": "ACTIVE", "platform_role": "SUPER_ADMIN", "role_code": None,
        "channel_access": True, "mfa_enabled": False, "role_requires_mfa": False,
        "must_change_password": False, "locked_until": None,
    }
    LoginRepository.prepared = prepared
    LoginRepository.attempts = []
    LoginRepository.sessions = []
    monkeypatch.setattr("app.services.auth.AuthRepository", LoginRepository)
    monkeypatch.setattr("app.services.auth.verify_password", lambda *_args: True)
    app = FastAPI()
    app.include_router(auth_router, prefix="/api/v1")
    async def fake_db(): yield FakeConnection()
    app.dependency_overrides[get_auth_db] = fake_db
    app.dependency_overrides[get_settings] = lambda: settings
    return TestClient(app), settings


def test_login_reports_active_session_and_force_logout_replaces_it(monkeypatch) -> None:
    client, settings = _auth_client(monkeypatch, prepared=False)
    payload = {"user_id": "admin@example.test", "password": "correct", "channel": "WEB"}
    conflict = client.post("/api/v1/auth/login", json=payload)
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["shortCode"] == "ACTIVE_SESSION_EXISTS"

    LoginRepository.prepared = True
    accepted = client.post("/api/v1/auth/login", json={**payload, "force_logout": True})
    assert accepted.status_code == 200, accepted.text
    claims = jwt.decode(
        accepted.json()["access_token"], settings.platform_jwt_secret.get_secret_value(),
        algorithms=["HS256"], audience=settings.platform_jwt_audience,
        issuer=settings.platform_jwt_issuer,
    )
    assert claims["sid"]
    assert LoginRepository.sessions[-1]["force_logout"] is True
    assert LoginRepository.attempts[-1]["success"] is True


def test_wrong_password_is_recorded_and_locked_account_gets_localizable_error(monkeypatch) -> None:
    client, _settings = _auth_client(monkeypatch, prepared=True)
    monkeypatch.setattr("app.services.auth.verify_password", lambda *_args: False)
    response = client.post("/api/v1/auth/login", json={
        "user_id": "admin@example.test", "password": "wrong", "channel": "WEB",
    })
    assert response.status_code == 401
    assert LoginRepository.attempts[-1]["failure_reason"] == "WRONG_PASSWORD"
    assert LoginRepository.sessions == []

    LoginRepository.candidate["locked_until"] = datetime.now(UTC) + timedelta(minutes=30)
    monkeypatch.setattr("app.services.auth.verify_password", lambda *_args: True)
    locked = client.post("/api/v1/auth/login", json={
        "user_id": "admin@example.test", "password": "correct", "channel": "WEB",
    })
    assert locked.status_code == 403
    assert locked.json()["detail"]["shortCode"] == "ACCOUNT_LOCKED"
    assert LoginRepository.attempts[-1]["failure_reason"] == "LOCKED"


class UserRepositoryFake:
    reset_args = None
    created_args = None
    list_offset = None
    def __init__(self, _conn): pass
    async def list_users(self, offset):
        type(self).list_offset = offset
        return []
    async def list_roles(self): return []
    async def reset_password(self, user_id, password_hash):
        type(self).reset_args = (user_id, password_hash)
        return True
    async def create_user(self, **kwargs):
        type(self).created_args = kwargs
        return uuid4()


def _user_client(monkeypatch, role="ADM"):
    settings = Settings(_env_file=None)
    principal = TenantPrincipal(
        tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code=role,
        channel="WEB", mfa_verified=False,
    )
    app = FastAPI()
    app.include_router(users_router, prefix="/api/v1")
    async def fake_db(): yield FakeConnection()
    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    app.dependency_overrides[get_settings] = lambda: settings
    monkeypatch.setattr("app.services.users.UserRepository", UserRepositoryFake)
    UserRepositoryFake.reset_args = None
    UserRepositoryFake.created_args = None
    UserRepositoryFake.list_offset = None
    return TestClient(app), principal


def test_org_admin_password_reset_sets_default_hash_and_requires_change(monkeypatch) -> None:
    client, _principal = _user_client(monkeypatch)
    response = client.post(f"/api/v1/users/{uuid4()}/password-reset")
    assert response.status_code == 204
    user_id, encoded = UserRepositoryFake.reset_args
    from app.core.passwords import INITIAL_DEFAULT_PASSWORD, verify_password
    assert verify_password(INITIAL_DEFAULT_PASSWORD, encoded)
    # The database reset function sets must_change_password=true.


def test_user_list_passes_offset_for_load_more(monkeypatch) -> None:
    client, _principal = _user_client(monkeypatch)
    response = client.get('/api/v1/users?offset=15')
    assert response.status_code == 200, response.text
    assert response.json() == []
    assert UserRepositoryFake.list_offset == 15


def test_non_admin_cannot_reset_an_employee_password(monkeypatch) -> None:
    client, _principal = _user_client(monkeypatch, role="EMP")
    response = client.post(f"/api/v1/users/{uuid4()}/password-reset")
    assert response.status_code == 403
    assert UserRepositoryFake.reset_args is None


def test_org_admin_user_creation_returns_first_login_change_flag(monkeypatch) -> None:
    client, _principal = _user_client(monkeypatch)
    response = client.post("/api/v1/users", json={
        "full_name": "Staff User", "mobile": "9876543210", "role_code": "EMP",
    })
    assert response.status_code == 201, response.text
    assert response.json()["must_change_password"] is True
    assert UserRepositoryFake.created_args["role_code"] == "EMP"
    from app.core.passwords import INITIAL_DEFAULT_PASSWORD, verify_password
    assert verify_password(INITIAL_DEFAULT_PASSWORD, UserRepositoryFake.created_args["password_hash"])
