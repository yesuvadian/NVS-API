"""API tests for the loan nominee override: submit body and approver-visible fields."""

from datetime import date, datetime, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.errors import install_error_handlers
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers import loans as loans_router

LOAN = uuid4()


def loan_row(**overrides):
    return {"id": LOAN, "loan_no": "LN-0001", "member_id": uuid4(), "loan_type_id": uuid4(),
            "requested_amount": Decimal("12000.00"), "requested_tenure_months": 12,
            "application_date": date(2026, 11, 19), "status": "UNDER_APPROVAL", "is_first_loan": False,
            "rule_set_version_id": uuid4(), "workflow_version_id": uuid4(),
            "created_at": datetime(2026, 11, 19, tzinfo=timezone.utc), "row_version": 2, **overrides}


class FakeService:
    calls: list = []

    def __init__(self, _conn):
        pass

    async def submit_application(self, loan_id, nominee_override_reason=None):
        self.calls.append(("submit", loan_id, nominee_override_reason))
        return loan_row(nominee_override=True, nominee_override_reason=nominee_override_reason,
                        nominee_override_by_name="Test MGR")

    async def get_application(self, loan_id):
        return loan_row(nominee_override=True, nominee_override_reason="Member has no family")

    async def approval_inbox(self, *, limit, offset):
        return {"items": [{"loan_id": str(LOAN), "loan_no": "LN-0001", "nominee_override": True,
                           "nominee_override_reason": "Member has no family"}],
                "limit": limit, "offset": offset, "has_more": False, "next_offset": None}


class AllowAll:
    async def execute(self, query, params=None):
        return self

    async def fetchone(self):
        return {"allowed": True}


@pytest.fixture
def client(monkeypatch):
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="MGR",
                                channel="WEB", mfa_verified=False, working_date=date(2026, 11, 19))
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(loans_router.router, prefix="/api/v1")

    async def fake_db():
        yield AllowAll()

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    monkeypatch.setattr(loans_router, "_service", lambda conn: FakeService(conn))
    FakeService.calls = []
    return TestClient(app)


def test_submit_without_body_still_works(client):
    response = client.post(f"/api/v1/loans/{LOAN}/submit")
    assert response.status_code == 200, response.text
    assert FakeService.calls == [("submit", LOAN, None)]


def test_submit_passes_override_reason_and_returns_override(client):
    response = client.post(f"/api/v1/loans/{LOAN}/submit", json={"nominee_override_reason": "Member has no family"})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["nominee_override"] is True
    assert body["nominee_override_reason"] == "Member has no family"
    assert body["nominee_override_by_name"] == "Test MGR"
    assert FakeService.calls == [("submit", LOAN, "Member has no family")]


def test_override_reason_longer_than_500_is_rejected(client):
    response = client.post(f"/api/v1/loans/{LOAN}/submit", json={"nominee_override_reason": "x" * 501})
    assert response.status_code in (400, 422)
    assert response.json()["detail"]["shortCode"] == "INVALID_DATA"
    assert FakeService.calls == []


def test_approver_sees_override_in_detail_and_inbox(client):
    detail = client.get(f"/api/v1/loans/{LOAN}").json()
    assert detail["nominee_override"] is True and detail["nominee_override_reason"] == "Member has no family"
    inbox = client.get("/api/v1/loan-approvals/inbox").json()
    assert inbox["items"][0]["nominee_override"] is True
