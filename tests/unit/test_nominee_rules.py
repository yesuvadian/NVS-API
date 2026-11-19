"""Unit tests for the nominee rule evaluation and NomineeService checks (no database)."""

import asyncio
from decimal import Decimal
from uuid import uuid4

import pytest

from app.core.errors import AppError
from app.services.loans import nominee_requirement
from app.services.nominees import NomineeService


def required(rule, *, first=False, setting=True, amount="12000"):
    return nominee_requirement(rule, first_loan=first, first_loan_setting=setting, requested_amount=Decimal(amount))


def test_every_loan_needs_a_nominee_when_every_loan_is_set():
    assert required({"everyLoan": True, "firstLoan": True}) is True
    assert required({"everyLoan": True}, first=False, setting=False) is True


def test_first_loan_rule_needs_first_loan_and_setting():
    assert required({"firstLoan": True}, first=True) is True
    assert required({"firstLoan": True}, first=False) is False
    assert required({"firstLoan": True}, first=True, setting=False) is False
    assert required({}, first=True) is True                       # firstLoan defaults to true
    assert required({"firstLoan": False}, first=True) is False


def test_threshold_amount_is_evaluated():
    rule = {"firstLoan": False, "thresholdAmount": 10000}
    assert required(rule, amount="10000") is True
    assert required(rule, amount="9999.99") is False
    assert required({"firstLoan": False, "thresholdAmount": None}, amount="999999") is False


class FakeRepository:
    def __init__(self):
        self.calls = []

    async def add(self, *args):
        self.calls.append(("add", *args))
        return {"id": "n1"}

    async def update(self, *args):
        self.calls.append(("update", *args))
        return {"id": "n1"}

    async def set_status(self, *args):
        self.calls.append(("status", *args))
        return {"id": "n1"}

    async def list(self, *args):
        self.calls.append(("list", *args))
        return []


def _service(repository) -> NomineeService:
    service = NomineeService.__new__(NomineeService)
    service.repository = repository
    return service


def test_service_refuses_self_nomination_before_the_database():
    repository = FakeRepository()
    member = uuid4()
    with pytest.raises(AppError) as error:
        asyncio.run(_service(repository).add(member, member, "SPOUSE"))
    assert error.value.short_code == "NOMINEE_IS_SELF"
    assert repository.calls == []


def test_service_requires_row_version_for_changes():
    repository = FakeRepository()
    for call in (lambda s: s.update(uuid4(), "SON", None), lambda s: s.set_status(uuid4(), "INACTIVE", None, "Moved")):
        with pytest.raises(AppError) as error:
            asyncio.run(call(_service(repository)))
        assert error.value.short_code == "ROW_VERSION_REQUIRED"
    assert repository.calls == []


def test_service_passes_values_through():
    repository = FakeRepository()
    member, nominee, nominee_row = uuid4(), uuid4(), uuid4()
    asyncio.run(_service(repository).add(member, nominee, "SPOUSE"))
    asyncio.run(_service(repository).set_status(nominee_row, "INACTIVE", 3, "  Moved away  "))
    asyncio.run(_service(repository).add(member, nominee, "SON", "  Only relative  "))
    assert repository.calls == [
        ("add", member, nominee, "SPOUSE", None),
        ("status", nominee_row, "INACTIVE", 3, "Moved away", False),
        ("add", member, nominee, "SON", "Only relative"),              # override reason trimmed
    ]
