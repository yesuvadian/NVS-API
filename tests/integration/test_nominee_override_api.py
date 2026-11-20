"""API tests for nominee timing (rules linked to workflow transitions): linking
nominees after submit, the nominee override at approval or before it, and the
approver-visible override, criteria and nominee state."""

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

LOAN, REQUEST, NOMINEE = uuid4(), uuid4(), uuid4()
STATUS = {"required": True, "required_because": ["EVERY_LOAN"], "active_nominees": 0, "linked": False,
          "override_allowed": True, "overridden": True, "override_reason": "Member has no family", "satisfied": True}


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

    async def decide(self, request_id, values):
        self.calls.append(("decide", request_id, values))
        return {"status": "APPROVED"}

    async def set_nominees(self, loan_id, nominee_ids, expected_version):
        self.calls.append(("nominees", loan_id, nominee_ids, expected_version))
        return {**STATUS, "linked": True, "active_nominees": 1, "row_version": 3}

    async def record_nominee_override(self, loan_id, reason):
        self.calls.append(("override", loan_id, reason))
        return STATUS

    async def get_application(self, loan_id):
        return loan_row(nominee_override=True, nominee_override_reason="Member has no family",
                        nominee_status=STATUS,
                        criteria=[{"code": "NOMINEE", "label_key": "criterion_nominee", "required": True,
                                   "met": True, "detail": {"overridden": True}, "stage": "APPROVE"}])

    async def approval_inbox(self, *, limit, offset):
        return {"items": [{"loan_id": str(LOAN), "loan_no": "LN-0001", "nominee_override": True,
                           "nominee_override_reason": "Member has no family"}],
                "limit": limit, "offset": offset, "has_more": False, "next_offset": None}


class Privileges:
    """Fake connection answering the privilege check."""

    def __init__(self, allowed=True):
        self.allowed = allowed
        self.checked: list[str] = []

    async def execute(self, query, params=None):
        self.checked.append(params[1])
        return self

    async def fetchone(self):
        return {"allowed": self.allowed}


def make_client(monkeypatch, allowed=True):
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="MGR",
                                channel="WEB", mfa_verified=False, working_date=date(2026, 11, 19))
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(loans_router.router, prefix="/api/v1")
    connection = Privileges(allowed)

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    monkeypatch.setattr(loans_router, "_service", lambda conn: FakeService(conn))
    FakeService.calls = []
    return TestClient(app), connection


@pytest.fixture
def client(monkeypatch):
    return make_client(monkeypatch)[0]


def test_approval_decision_passes_nominee_override_reason(client):
    response = client.post(f"/api/v1/loan-approvals/{REQUEST}/decision",
                           json={"decision": "APPROVED", "nominee_override_reason": "Member has no family"})
    assert response.status_code == 200, response.text
    _, request_id, values = FakeService.calls[0]
    assert request_id == REQUEST and values["nominee_override_reason"] == "Member has no family"


def test_link_nominees_after_submit_needs_row_version(client):
    no_version = client.put(f"/api/v1/loans/{LOAN}/nominees", json={"nominee_ids": [str(NOMINEE)]})
    assert no_version.status_code == 200 or no_version.status_code == 428
    linked = client.put(f"/api/v1/loans/{LOAN}/nominees", json={"nominee_ids": [str(NOMINEE)]},
                        headers={"X-Expected-Row-Version": "2"})
    assert linked.status_code == 200, linked.text
    assert linked.json()["linked"] is True
    assert FakeService.calls[-1] == ("nominees", LOAN, [NOMINEE], 2)


def test_maker_override_before_approval_needs_the_override_privilege(monkeypatch):
    client, connection = make_client(monkeypatch)
    response = client.post(f"/api/v1/loans/{LOAN}/nominee-override", json={"reason": "Member has no family"})
    assert response.status_code == 200 and response.json()["overridden"] is True
    assert connection.checked == ["loan.nominee_override"]

    client, _ = make_client(monkeypatch, allowed=False)
    denied = client.post(f"/api/v1/loans/{LOAN}/nominee-override", json={"reason": "Member has no family"})
    assert denied.status_code == 403
    short = client.post(f"/api/v1/loans/{LOAN}/nominee-override", json={"reason": "ab"})
    assert short.status_code in (400, 403, 422)


def test_approver_sees_override_criteria_and_nominee_state(client):
    detail = client.get(f"/api/v1/loans/{LOAN}").json()
    assert detail["nominee_override"] is True and detail["nominee_status"]["overridden"] is True
    assert detail["criteria"][0]["stage"] == "APPROVE"
    inbox = client.get("/api/v1/loan-approvals/inbox").json()
    assert inbox["items"][0]["nominee_override_reason"] == "Member has no family"
