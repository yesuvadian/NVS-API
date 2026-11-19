"""Unit tests for the double-save and concurrent-save controls in the API layer
(no database: routers run on a scripted fake connection)."""

from __future__ import annotations

import asyncio
from collections import deque
from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
from fastapi import FastAPI, Response
from fastapi.testclient import TestClient

from app.core.errors import AppError
from app.core.idempotency import REPLAYED_HEADER, request_hash, run_idempotent, validate_key
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers import loan_servicing as servicing_router
from app.routers import loans as loans_router
from app.routers import members as members_router

LOAN_ID = "11111111-1111-1111-1111-111111111111"


class FakeResult:
    def __init__(self, *, one=None) -> None:
        self.one = one

    async def fetchone(self):
        return self.one

    async def fetchall(self):
        return [] if self.one is None else [self.one]


class FakeConnection:
    def __init__(self, *results: FakeResult) -> None:
        self.results = deque(results)
        self.calls: list[tuple[str, tuple | None]] = []

    async def execute(self, query: str, params=None):
        self.calls.append((query, params))
        if not self.results:
            raise AssertionError(f"Unexpected query: {query}")
        return self.results.popleft()

    def sql(self) -> list[str]:
        return [query for query, _ in self.calls]


# -----------------------------------------------------------------------------
# validate_key / request_hash
# -----------------------------------------------------------------------------
def test_validate_key_required_optional_and_format():
    with pytest.raises(AppError) as exc:
        validate_key(None, required=True)
    assert exc.value.short_code == "IDEMPOTENCY_KEY_REQUIRED" and exc.value.status_code == 428
    with pytest.raises(AppError) as exc:
        validate_key("   ", required=True)
    assert exc.value.short_code == "IDEMPOTENCY_KEY_REQUIRED"
    assert validate_key(None, required=False) is None
    assert validate_key("", required=False) is None
    assert validate_key("  6f1c2b9e-1d2a-4c55-9a77-0e6c3f2b8d10 ", required=True) == "6f1c2b9e-1d2a-4c55-9a77-0e6c3f2b8d10"
    assert validate_key("form:123.abc_x", required=True) == "form:123.abc_x"
    for bad in ("short", "has space in it", "x" * 101, "semi;colon-key", "naïve-key-01"):
        with pytest.raises(AppError) as exc:
            validate_key(bad, required=False)
        assert exc.value.short_code == "IDEMPOTENCY_KEY_INVALID" and exc.value.status_code == 400


def test_request_hash_is_stable_and_sensitive_to_the_request():
    loan = uuid4()
    one = request_hash("loan.collect_repayment", {"loan_id": loan, "amount": Decimal("100.00"), "mode": "CASH"})
    same = request_hash("loan.collect_repayment", {"mode": "CASH", "amount": Decimal("100.00"), "loan_id": str(loan)})
    assert one == same and len(one) == 64
    assert one != request_hash("loan.collect_repayment", {"loan_id": loan, "amount": Decimal("100.01"), "mode": "CASH"})
    assert one != request_hash("loan.collect_application_fee",
                               {"loan_id": loan, "amount": Decimal("100.00"), "mode": "CASH"})
    assert request_hash("op", {"d": date(2026, 1, 1)}) == request_hash("op", {"d": "2026-01-01"})


# -----------------------------------------------------------------------------
# run_idempotent
# -----------------------------------------------------------------------------
def test_run_idempotent_without_key_just_runs_the_action():
    conn = FakeConnection()
    calls = []

    async def action():
        calls.append(1)
        return {"ok": True}

    assert asyncio.run(run_idempotent(conn, key=None, operation="op", payload={}, action=action)) == {"ok": True}
    assert calls == [1] and conn.calls == []


def test_run_idempotent_first_request_reserves_runs_and_stores_the_response():
    conn = FakeConnection(FakeResult(one={"stored": None}), FakeResult())
    receipt_id = uuid4()

    async def action():
        return {"cash_receipt_id": receipt_id, "amount": Decimal("100.00")}

    response = Response()
    result = asyncio.run(run_idempotent(conn, key="key-0000001", operation="op", payload={"a": 1},
                                        action=action, response=response))
    assert result["cash_receipt_id"] == receipt_id
    assert REPLAYED_HEADER.lower() not in response.headers
    begin_sql, begin_params = conn.calls[0]
    assert "core.idempotency_begin" in begin_sql
    assert begin_params == ("key-0000001", "op", request_hash("op", {"a": 1}))
    finish_sql, finish_params = conn.calls[1]
    assert "core.idempotency_finish" in finish_sql
    assert finish_params[0] == "key-0000001"
    assert finish_params[1].obj == {"cash_receipt_id": str(receipt_id), "amount": 100.0}   # JSON-safe


def test_run_idempotent_replay_returns_the_stored_response_without_running():
    conn = FakeConnection(FakeResult(one={"stored": {"response": {"receipt_no": "RCP/1"}}}))

    async def action():
        raise AssertionError("must not run on a replay")

    response = Response()
    result = asyncio.run(run_idempotent(conn, key="key-0000001", operation="op", payload={},
                                        action=action, response=response))
    assert result == {"receipt_no": "RCP/1"}
    assert response.headers[REPLAYED_HEADER] == "true"
    assert len(conn.calls) == 1


def test_run_idempotent_failure_does_not_store_a_response():
    conn = FakeConnection(FakeResult(one={"stored": None}))

    async def action():
        raise AppError("REPAYMENT_EXCEEDS_DUES")

    with pytest.raises(AppError):
        asyncio.run(run_idempotent(conn, key="key-0000001", operation="op", payload={}, action=action))
    assert not any("idempotency_finish" in sql for sql in conn.sql())   # the transaction rolls back


# -----------------------------------------------------------------------------
# Routers
# -----------------------------------------------------------------------------
def _client(router, connection: FakeConnection) -> TestClient:
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="EMP", channel="WEB",
                                mfa_verified=False, working_date=date(2026, 11, 15))
    app = FastAPI()
    app.include_router(router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app)


ALLOWED = FakeResult(one={"allowed": True})

MONEY_ENDPOINTS = [
    (loans_router.router, f"/api/v1/loans/{LOAN_ID}/repayments", {"amount": "100.00"}, "loan.collect_repayment"),
    (loans_router.router, f"/api/v1/loans/{LOAN_ID}/application-fee", {}, "loan.collect_application_fee"),
    (loans_router.router, f"/api/v1/loans/{LOAN_ID}/disbursements", {"gross_amount": "100.00"},
     "loan.prepare_disbursement"),
    (loans_router.router, f"/api/v1/loan-settlements/{LOAN_ID}/collect", {}, "loan.collect_early_settlement"),
    (servicing_router.router, f"/api/v1/loans/{LOAN_ID}/written-off-recoveries", {"amount": "100.00"},
     "loan.collect_written_off_recovery"),
]


@pytest.mark.parametrize(("router", "path", "body", "routine"), MONEY_ENDPOINTS)
def test_money_endpoints_require_an_idempotency_key(router, path, body, routine):
    connection = FakeConnection(ALLOWED)
    response = _client(router, connection).post(path, json=body)
    assert response.status_code == 428
    assert response.json()["detail"]["shortCode"] == "IDEMPOTENCY_KEY_REQUIRED"
    assert not any(routine in sql for sql in connection.sql())


@pytest.mark.parametrize(("router", "path", "body", "routine"), MONEY_ENDPOINTS)
def test_money_endpoints_check_the_privilege_before_the_key(router, path, body, routine):
    connection = FakeConnection(FakeResult(one={"allowed": False}))
    response = _client(router, connection).post(path, json=body)
    assert response.status_code == 403                     # no key, but the privilege check comes first


@pytest.mark.parametrize(("router", "path", "body", "routine"), MONEY_ENDPOINTS)
def test_money_endpoints_replay_a_repeated_key(router, path, body, routine):
    stored = {"receipt_no": "RCP/2026-27/00001", "status": "PAID"}
    connection = FakeConnection(ALLOWED, FakeResult(one={"stored": {"response": stored}}))
    response = _client(router, connection).post(path, json=body, headers={"Idempotency-Key": "abc-123-def-456"})
    assert response.status_code in (200, 201)
    assert response.json() == stored
    assert response.headers["Idempotent-Replayed"] == "true"
    assert not any(routine in sql for sql in connection.sql())
    assert connection.calls[1][1][:2] == ("abc-123-def-456", routine)


def test_repayment_with_a_new_key_posts_and_stores_the_receipt():
    result = {"cash_receipt_id": str(uuid4()), "receipt_no": "RCP/1", "amount": 100.0}
    connection = FakeConnection(ALLOWED, FakeResult(one={"stored": None}), FakeResult(one={"result": result}),
                                FakeResult())
    response = _client(loans_router.router, connection).post(
        f"/api/v1/loans/{LOAN_ID}/repayments", json={"amount": "100.00", "payment_mode": "UPI"},
        headers={"Idempotency-Key": "abc-123-def-456"})
    assert response.status_code == 201 and response.json() == result
    assert "Idempotent-Replayed" not in response.headers
    assert ["core.idempotency_begin" in connection.sql()[1], "loan.collect_repayment" in connection.sql()[2],
            "core.idempotency_finish" in connection.sql()[3]] == [True, True, True]
    assert connection.calls[2][1] == (UUID(LOAN_ID), Decimal("100.00"), "UPI", None)


def test_repayment_rejects_a_malformed_key():
    connection = FakeConnection(ALLOWED)
    response = _client(loans_router.router, connection).post(
        f"/api/v1/loans/{LOAN_ID}/repayments", json={"amount": "100.00"}, headers={"Idempotency-Key": "bad key"})
    assert response.status_code == 400 and response.json()["detail"]["shortCode"] == "IDEMPOTENCY_KEY_INVALID"


def test_loan_application_update_requires_the_row_version():
    connection = FakeConnection(ALLOWED)
    response = _client(loans_router.router, connection).patch(
        f"/api/v1/loan-applications/{LOAN_ID}", json={"purpose": "New roof"})
    assert response.status_code == 428 and response.json()["detail"]["shortCode"] == "ROW_VERSION_REQUIRED"
    assert len(connection.calls) == 1


def test_create_loan_without_key_still_works_and_with_key_is_replayed():
    stored = {"id": LOAN_ID, "loan_no": "LN/1", "member_id": str(uuid4()), "loan_type_id": str(uuid4()),
              "requested_amount": "12000.00", "requested_tenure_months": 12, "application_date": "2026-11-15",
              "status": "DRAFT", "is_first_loan": True, "rule_set_version_id": str(uuid4()),
              "workflow_version_id": str(uuid4()), "created_at": datetime(2026, 11, 15, tzinfo=UTC).isoformat(),
              "row_version": 1}
    body = {"member_id": str(uuid4()), "loan_type_id": str(uuid4()), "requested_amount": "12000.00",
            "requested_tenure_months": 12, "purpose": "Home repairs"}
    connection = FakeConnection(ALLOWED, FakeResult(one={"stored": {"response": stored}}))
    response = _client(loans_router.router, connection).post("/api/v1/loans", json=body,
                                                              headers={"Idempotency-Key": "new-loan-form-1"})
    assert response.status_code == 201 and response.json()["loan_no"] == "LN/1"
    assert response.headers["Idempotent-Replayed"] == "true"


def _member_row():
    return {"id": str(uuid4()), "member_no": "MEM-00001", "full_name": "Test Member", "status": "APPLIED",
            "loan_eligibility": "ELIGIBLE", "preferred_language": "en", "preferred_channel": "SMS",
            "created_at": datetime(2026, 11, 15, tzinfo=UTC).isoformat(), "row_version": 1}


def test_member_update_requires_the_row_version():
    connection = FakeConnection(ALLOWED)
    response = _client(members_router.router, connection).patch(f"/api/v1/members/{LOAN_ID}", json={"city": "Salem"})
    assert response.status_code == 428 and response.json()["detail"]["shortCode"] == "ROW_VERSION_REQUIRED"
    assert len(connection.calls) == 1


def test_member_update_with_stale_version_is_a_conflict():
    connection = FakeConnection(ALLOWED, FakeResult(one={"member": None}), FakeResult(one=_member_row()))
    response = _client(members_router.router, connection).patch(
        f"/api/v1/members/{LOAN_ID}", json={"city": "Salem"}, headers={"X-Expected-Row-Version": "3"})
    assert response.status_code == 409 and response.json()["detail"]["shortCode"] == "STALE_RECORD"
    assert connection.calls[1][1][2] == 3


def test_member_update_with_only_an_override_reason_is_not_a_change():
    connection = FakeConnection(ALLOWED)
    response = _client(members_router.router, connection).patch(
        f"/api/v1/members/{LOAN_ID}", json={"duplicate_override_reason": "Shared phone"},
        headers={"X-Expected-Row-Version": "1"})
    assert response.json()["detail"]["shortCode"] == "MEMBER_CHANGES_REQUIRED"


def test_member_create_passes_the_duplicate_override_and_replays_with_a_key():
    member = _member_row()
    connection = FakeConnection(ALLOWED, FakeResult(one={"stored": None}), FakeResult(one={"member": member}),
                                FakeResult())
    client = _client(members_router.router, connection)
    response = client.post("/api/v1/members", headers={"Idempotency-Key": "member-form-01"},
                           json={"full_name": "Kumar R", "mobile": "9876543210",
                                 "duplicate_override_reason": "Husband shares the mobile"})
    assert response.status_code == 201
    assert connection.calls[2][1][0].obj["duplicate_override_reason"] == "Husband shares the mobile"

    connection.results.extend([ALLOWED, FakeResult(one={"stored": {"response": member}})])
    again = client.post("/api/v1/members", headers={"Idempotency-Key": "member-form-01"},
                        json={"full_name": "Kumar R", "mobile": "9876543210",
                              "duplicate_override_reason": "Husband shares the mobile"})
    assert again.status_code == 201 and again.json()["id"] == member["id"]
    assert again.headers["Idempotent-Replayed"] == "true"
