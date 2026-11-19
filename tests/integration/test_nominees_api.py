"""API tests for member nominees (dependency overrides, fake DB)."""

from collections import deque
from datetime import date
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.errors import install_error_handlers
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers.nominees import router


class FakeResult:
    def __init__(self, one=None) -> None:
        self.one = one

    async def fetchone(self):
        return self.one


class FakeConnection:
    def __init__(self) -> None:
        self.results: deque[FakeResult] = deque()
        self.calls: list[tuple[str, tuple | None]] = []

    def script(self, *rows) -> None:
        self.results.extend(FakeResult(r) for r in rows)

    async def execute(self, query: str, params=None):
        self.calls.append((query, params))
        if not self.results:
            raise AssertionError(f"Unexpected query: {query}")
        return self.results.popleft()


ALLOWED = {"allowed": True}
DENIED = {"allowed": False}
MEMBER, NOMINEE_MEMBER, NOMINEE = uuid4(), uuid4(), uuid4()


def nominee_row(**overrides):
    return {"id": str(NOMINEE), "member_id": str(MEMBER), "nominee_member_id": str(NOMINEE_MEMBER),
            "nominee_member_no": "MEM-0002", "full_name": "Kavitha R", "relationship": "SISTER",
            "date_of_birth": None, "mobile": "9000000002", "status": "ACTIVE",
            "created_at": "2026-11-19T10:00:00+00:00", "updated_at": None, "row_version": 1, **overrides}


@pytest.fixture
def api():
    connection = FakeConnection()
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="EMP",
                                channel="WEB", mfa_verified=False, working_date=date(2026, 11, 19))
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app), connection


def test_list_nominees_with_inactive(api):
    client, connection = api
    connection.script(ALLOWED, {"result": [nominee_row(), nominee_row(status="INACTIVE")]})

    response = client.get(f"/api/v1/members/{MEMBER}/nominees?include_inactive=true")

    assert response.status_code == 200
    assert [n["status"] for n in response.json()] == ["ACTIVE", "INACTIVE"]
    assert connection.calls[0][1][1] == "member.view"
    assert connection.calls[1][1] == (MEMBER, True)


def test_add_nominee_links_an_existing_member(api):
    client, connection = api
    connection.script(ALLOWED, {"result": nominee_row()})

    response = client.post(f"/api/v1/members/{MEMBER}/nominees",
                           json={"nominee_member_id": str(NOMINEE_MEMBER), "relationship": "SISTER"})

    assert response.status_code == 201, response.text
    assert response.json()["nominee_member_no"] == "MEM-0002"
    assert connection.calls[0][1][1] == "member.edit"
    assert connection.calls[1] == ("SELECT mbr.add_nominee(%s,%s,%s,%s) AS result",
                                   (MEMBER, NOMINEE_MEMBER, "SISTER", None))


def test_add_nominee_validation(api):
    client, connection = api
    connection.script(ALLOWED, ALLOWED, ALLOWED)
    url = f"/api/v1/members/{MEMBER}/nominees"
    # Request validation renders INVALID_DATA; its HTTP status comes from the error
    # catalogue once loaded (400) or the 422 fallback, so check the code.
    for body in ({"nominee_member_id": str(NOMINEE_MEMBER), "relationship": "FRIEND"}, {"relationship": "SON"}):
        invalid = client.post(url, json=body)
        assert invalid.status_code in (400, 422)
        assert invalid.json()["detail"]["shortCode"] == "INVALID_DATA"
    self_nomination = client.post(url, json={"nominee_member_id": str(MEMBER), "relationship": "SON"})
    assert self_nomination.status_code == 422
    assert self_nomination.json()["detail"]["shortCode"] == "NOMINEE_IS_SELF"
    assert not any("add_nominee" in q for q, _ in connection.calls)


def test_invalid_idempotency_key_is_refused(api):
    client, connection = api
    connection.script(ALLOWED)
    response = client.post(f"/api/v1/members/{MEMBER}/nominees",
                           json={"nominee_member_id": str(NOMINEE_MEMBER), "relationship": "SON"},
                           headers={"Idempotency-Key": "bad key!"})
    assert response.status_code == 400
    assert response.json()["detail"]["shortCode"] == "IDEMPOTENCY_KEY_INVALID"


def test_update_and_status_need_row_version(api):
    client, connection = api
    connection.script(ALLOWED, ALLOWED)
    no_version = client.patch(f"/api/v1/member-nominees/{NOMINEE}", json={"relationship": "SON"})
    assert no_version.status_code == 428
    assert no_version.json()["detail"]["shortCode"] == "ROW_VERSION_REQUIRED"
    no_version = client.post(f"/api/v1/member-nominees/{NOMINEE}/status", json={"status": "INACTIVE", "reason": "Moved"})
    assert no_version.status_code == 428


def test_update_and_deactivate_pass_row_version(api):
    client, connection = api
    connection.script(ALLOWED, {"result": nominee_row(relationship="BROTHER", row_version=2)},
                      ALLOWED, {"result": nominee_row(status="INACTIVE", row_version=3)})

    updated = client.patch(f"/api/v1/member-nominees/{NOMINEE}", json={"relationship": "BROTHER"},
                           headers={"X-Expected-Row-Version": "1"})
    status = client.post(f"/api/v1/member-nominees/{NOMINEE}/status", json={"status": "INACTIVE", "reason": " Moved away "},
                         headers={"X-Expected-Row-Version": "2"})

    assert updated.status_code == 200 and updated.json()["relationship"] == "BROTHER"
    assert status.status_code == 200 and status.json()["status"] == "INACTIVE"
    assert connection.calls[1][1] == (NOMINEE, "BROTHER", 1)
    assert connection.calls[3][1] == (NOMINEE, "INACTIVE", 2, "Moved away", False)


def test_changes_need_member_edit(api):
    client, connection = api
    connection.script(DENIED)
    response = client.post(f"/api/v1/members/{MEMBER}/nominees",
                           json={"nominee_member_id": str(NOMINEE_MEMBER), "relationship": "SON"})
    assert response.status_code == 403
    assert connection.calls[0][1][1] == "member.edit"


def test_add_nominee_passes_override_reason_and_reactivation_override(api):
    client, connection = api
    connection.script(ALLOWED, {"result": nominee_row(limit_override=True, limit_override_reason="Only relative")},
                      ALLOWED, {"result": nominee_row(row_version=2)})

    added = client.post(f"/api/v1/members/{MEMBER}/nominees",
                        json={"nominee_member_id": str(NOMINEE_MEMBER), "relationship": "SON",
                              "override_reason": "  Only relative  "})
    reactivated = client.post(f"/api/v1/member-nominees/{NOMINEE}/status",
                              json={"status": "ACTIVE", "reason": "Back home", "limit_override": True},
                              headers={"X-Expected-Row-Version": "1"})

    assert added.status_code == 201 and added.json()["limit_override"] is True
    assert connection.calls[1][1] == (MEMBER, NOMINEE_MEMBER, "SON", "Only relative")
    assert reactivated.status_code == 200
    assert connection.calls[3][1] == (NOMINEE, "ACTIVE", 1, "Back home", True)
