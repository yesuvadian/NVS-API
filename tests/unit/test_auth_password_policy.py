import asyncio
from uuid import uuid4

import pytest

from app.core.errors import AppError
from app.core.passwords import INITIAL_DEFAULT_PASSWORD, hash_password, verify_password
from app.core.config import Settings
from app.services.auth import AuthService
from app.services.users import UserService


def test_default_password_hashes_and_verifies() -> None:
    encoded = hash_password(INITIAL_DEFAULT_PASSWORD, minimum_length=1)
    assert verify_password(INITIAL_DEFAULT_PASSWORD, encoded)
    assert not verify_password("wrong-password", encoded)


def test_self_service_change_rejects_password_from_history(monkeypatch) -> None:
    user_id, tenant_id = uuid4(), uuid4()
    old_hash = "current-hash"
    recent_hash = "previous-hash"

    class Repo:
        def __init__(self, _conn): pass
        async def login_candidates(self, _identifier, _channel):
            return [{"tenant_id": tenant_id, "password_hash": old_hash}]
        async def password_hashes(self):
            return [old_hash, recent_hash]
        async def change_own_password(self, *_args):
            pytest.fail("A reused password must not be written")

    class Transaction:
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
    class Connection:
        def transaction(self): return Transaction()

    monkeypatch.setattr("app.services.auth.AuthRepository", Repo)
    monkeypatch.setattr("app.services.auth.verify_password",
                        lambda candidate, encoded: candidate == {
                            "current-hash": "Current password 10",
                            "previous-hash": "Previously used 10",
                        }.get(encoded))
    monkeypatch.setattr("app.services.auth.hash_password", lambda *_args, **_kwargs: "new-hash")
    async def run_inline(function, *args, **kwargs):
        return function(*args, **kwargs)
    monkeypatch.setattr("app.services.auth.run_in_threadpool", run_inline)
    service = AuthService(Connection(), Settings(_env_file=None))
    with pytest.raises(AppError) as error:
        if hasattr(asyncio, "WindowsSelectorEventLoopPolicy"):
            asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
        asyncio.run(service.change_password(
            tenant_id=tenant_id, user_id=user_id, channel="WEB",
            current_password="Current password 10", new_password="Previously used 10",
        ))
    assert error.value.short_code == "PASSWORD_REUSE"


def test_org_admin_created_user_uses_forced_default_password(monkeypatch) -> None:
    class Repo:
        saved = None
        def __init__(self, _conn): pass
        async def create_user(self, **kwargs):
            self.saved = kwargs
            return uuid4()

    monkeypatch.setattr("app.services.users.UserRepository", Repo)
    monkeypatch.setattr("app.services.users.hash_password", lambda *_args, **_kwargs: "default-hash")
    from types import SimpleNamespace
    service = UserService(object(), Settings(_env_file=None))
    if hasattr(asyncio, "WindowsSelectorEventLoopPolicy"):
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(service.create_user(SimpleNamespace(
        full_name="Staff Member", mobile="9876543210", email=None, role_code="EMP",
    )))
    # The database function marks this hash must-change; the service sends the
    # agreed default as a scrypt hash and never stores plaintext.
    repo = service.repo
    assert repo.saved["role_code"] == "EMP"
    assert repo.saved["password_hash"] == "default-hash"
