"""Unit tests for AccessControlService (no database)."""

import asyncio
from uuid import uuid4

import pytest

from app.core.errors import AppError
from app.services.access_control import AccessControlService


class FakeRepository:
    def __init__(self, modules=None) -> None:
        self.modules = modules or []
        self.calls: list[tuple] = []

    async def list_tenant_modules(self, tenant_id):
        self.calls.append(("list", tenant_id))
        return self.modules

    async def set_tenant_module(self, *args):
        self.calls.append(("set", *args))

    async def role_privilege_matrix(self):
        return {"can_edit": True, "roles": [], "modules": []}

    async def set_role_privilege(self, *args):
        self.calls.append(("privilege", *args))
        return {"changed": True}


def _service(repository) -> AccessControlService:
    service = AccessControlService.__new__(AccessControlService)
    service.repository = repository
    return service


def test_set_module_normalises_code_and_returns_updated_row() -> None:
    tenant = uuid4()
    loan = {"module_code": "LOAN", "is_enabled": False, "row_version": 3}
    repository = FakeRepository([{"module_code": "MEMBER"}, loan])

    result = asyncio.run(_service(repository).set_module(
        tenant, " loan ", enabled=False, reason=" Pause loans ", expected_version=2))

    assert result is loan
    assert repository.calls[0] == ("set", tenant, "LOAN", False, "Pause loans", 2, False)


def test_set_module_unknown_after_change_raises() -> None:
    repository = FakeRepository([])
    with pytest.raises(AppError) as error:
        asyncio.run(_service(repository).set_module(uuid4(), "LOAN", enabled=True, reason="Resume"))
    assert error.value.short_code == "UNKNOWN_MODULE"


def test_set_role_privilege_normalises_code_and_blank_reason() -> None:
    role = uuid4()
    repository = FakeRepository()

    asyncio.run(_service(repository).set_role_privilege(role, " Member.View ", granted=False, reason="  "))

    assert repository.calls == [("privilege", role, "member.view", False, None)]


def test_role_matrix_passes_through() -> None:
    assert asyncio.run(_service(FakeRepository()).role_matrix())["can_edit"] is True
