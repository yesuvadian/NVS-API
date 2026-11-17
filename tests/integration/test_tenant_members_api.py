from collections import deque
from datetime import UTC, date, datetime
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers.members import router


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
            raise AssertionError("Unexpected query with no scripted result.")
        return self.results.popleft()


@pytest.fixture
def tenant_api():
    connection = FakeConnection()
    principal = TenantPrincipal(
        tenant_id=uuid4(),
        user_id=uuid4(),
        role_code="EMP",
        channel="WEB",
        mfa_verified=False,
        working_date=date(2026, 11, 15),
    )
    app = FastAPI()
    app.include_router(router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app), connection, principal


def member_row(member_id=None):
    return {
        "id": member_id or uuid4(),
        "member_no": "MEM-00001",
        "full_name": "Test Member",
        "date_of_birth": date(1980, 1, 1),
        "gender": "UNDISCLOSED",
        "mobile": "919000000000",
        "alt_mobile": None,
        "email": None,
        "address_line1": None,
        "address_line2": None,
        "city": "Chennai",
        "district": None,
        "state": "Tamil Nadu",
        "pincode": None,
        "membership_date": None,
        "status": "APPLIED",
        "loan_eligibility": "ELIGIBLE",
        "preferred_language": "en",
        "preferred_channel": "SMS",
        "previous_member_id": None,
        "created_at": datetime(2026, 11, 15, tzinfo=UTC),
        "updated_at": None,
        "row_version": 1,
    }


def test_member_list_returns_load_more_pagination_and_applies_permission(tenant_api):
    client, connection, principal = tenant_api
    connection.results.extend(
        [
            FakeResult(one={"allowed": True}),
            FakeResult(many=[member_row(), member_row(), member_row()]),
        ]
    )

    response = client.get("/api/v1/members?q=Test&status=APPLIED&limit=2&offset=4")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 2
    assert response.json()["has_more"] is True
    assert response.json()["next_offset"] == 6
    assert connection.calls[0][1] == (principal.user_id, "member.view")
    assert "mbr.search_members" in connection.calls[1][0]
    assert connection.calls[1][1] == ("Test", "APPLIED", 3, 4)


def test_member_create_requires_permission_and_generates_member_number(tenant_api):
    client, connection, _principal = tenant_api
    member = member_row()
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"member": member})])

    response = client.post(
        "/api/v1/members",
        json={"full_name": "Test Member", "mobile": "919000000000", "city": "Chennai"},
    )

    assert response.status_code == 201
    assert response.json()["member_no"] == "MEM-00001"
    insert_sql, values = connection.calls[1]
    assert "mbr.create_member" in insert_sql
    assert values[0].obj["full_name"] == "Test Member"


def test_member_list_forbidden_when_permission_is_missing(tenant_api):
    client, connection, _principal = tenant_api
    connection.results.append(FakeResult(one={"allowed": False}))

    response = client.get("/api/v1/members")

    assert response.status_code == 403
    assert len(connection.calls) == 1
