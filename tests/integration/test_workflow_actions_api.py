from collections import deque
from datetime import date
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.config import Settings, get_settings
from app.core.errors import install_error_handlers
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers.workflow_actions import router
from app.services.workflow_actions import WorkflowActionService


class FakeResult:
    def __init__(self, one=None):
        self.one = one

    async def fetchone(self):
        return self.one


class FakeConnection:
    def __init__(self):
        self.calls = deque()

    async def execute(self, sql, params=None):
        self.calls.append((sql, params))
        if "idempotency_begin" in sql:
            return FakeResult({"stored": None})
        if "idempotency_finish" in sql:
            return FakeResult({"idempotency_finish": None})
        raise AssertionError(f"Unexpected SQL: {sql}")


class FakeWorkflowActionService:
    performed = []

    def __init__(self, _conn):
        pass

    async def list_actions(self, entity_type, entity_id):
        return {
            "entity_type": entity_type,
            "entity_id": entity_id,
            "row_version": 4,
            "actions": [{"code": "SUBMIT", "label": {"en": "Submit", "ta": "சமர்ப்பி"},
                         "input": {"type": "object", "properties": {"reason": {
                             "type": "string", "x-field": "multiline",
                             "title": {"en": "Reason", "ta": "காரணம்", "hi": "कारण"}}},
                                   "x-sections": [{"code": "DETAILS", "title": {
                                       "en": "Details", "ta": "விவரங்கள்", "hi": "विवरण"},
                                       "fields": ["reason"]}]}}],
        }

    async def perform(self, *args):
        self.performed.append(args)
        return {"result": {"decision": "SUBMITTED"}, "actions": []}


@pytest.fixture
def api_setup(monkeypatch):
    connection = FakeConnection()
    settings = Settings(
        _env_file=None,
        tenant_jwt_secret="integration-test-secret-that-is-long-enough",
        tenant_jwt_issuer="test-issuer",
        tenant_jwt_audience="test-audience",
    )
    principal = TenantPrincipal(
        tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="ADM",
        channel="WEB", mfa_verified=False, working_date=date(2026, 11, 20),
    )
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    app.dependency_overrides[get_settings] = lambda: settings
    monkeypatch.setattr("app.routers.workflow_actions.WorkflowActionService", FakeWorkflowActionService)
    FakeWorkflowActionService.performed = []
    return TestClient(app), connection


def test_get_actions_returns_json_driven_buttons(api_setup):
    client, _ = api_setup
    loan_id = uuid4()

    response = client.get(f"/api/v1/loans/{loan_id}/actions")

    assert response.status_code == 200
    assert response.json()["row_version"] == 4
    assert response.json()["actions"][0]["label"]["ta"] == "சமர்ப்பி"
    assert response.json()["actions"][0]["input"]["x-sections"][0]["title"]["hi"] == "विवरण"
    assert response.json()["actions"][0]["input"]["properties"]["reason"]["title"]["hi"] == "कारण"


def test_post_transition_passes_order_version_and_input_through_idempotency(api_setup):
    client, connection = api_setup
    loan_id = uuid4()

    response = client.post(
        f"/api/v1/loans/{loan_id}/transitions/SUBMIT",
        headers={"X-Expected-Row-Version": "4", "Idempotency-Key": "wf-step-0001"},
        json={"input": {"reason": "ready"}},
    )

    assert response.status_code == 200, response.text
    assert response.json()["result"]["decision"] == "SUBMITTED"
    assert FakeWorkflowActionService.performed == [
        ("loan", loan_id, "SUBMIT", {"reason": "ready"}, 4)
    ]
    assert len(connection.calls) == 2
    assert "core.idempotency_begin" in connection.calls[0][0]
    assert "core.idempotency_finish" in connection.calls[1][0]


@pytest.mark.parametrize(
    ("headers", "short_code"),
    [
        ({"Idempotency-Key": "wf-step-0002"}, "ROW_VERSION_REQUIRED"),
        ({"X-Expected-Row-Version": "4"}, "IDEMPOTENCY_KEY_REQUIRED"),
    ],
)
def test_transition_requires_row_version_and_idempotency_key(api_setup, headers, short_code):
    client, connection = api_setup
    response = client.post(
        f"/api/v1/loans/{uuid4()}/transitions/SUBMIT",
        headers=headers,
        json={"input": {}},
    )

    assert response.status_code == 428
    assert response.json()["detail"]["shortCode"] == short_code
    assert not connection.calls
