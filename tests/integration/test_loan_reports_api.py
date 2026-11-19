"""HTTP tests for the loan reports, loan documents and the sanction letter.

The database is a scripted fake connection: each request first checks the
privilege, then calls loan.* routines.
"""

from datetime import date
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.tenant_security import require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers import loan_reports, loan_servicing
from tests.integration.test_tenant_loans_api import FakeConnection, FakeResult, TenantPrincipal

ID = uuid4()


@pytest.fixture
def api():
    connection = FakeConnection()
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code="MGR", channel="WEB",
                                mfa_verified=False, working_date=date(2026, 11, 15))
    app = FastAPI()
    app.include_router(loan_reports.router, prefix="/api/v1")
    app.include_router(loan_servicing.router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app), connection


@pytest.mark.parametrize(
    ("path", "privilege"),
    [
        ("/api/v1/loan-reports/outstanding", "mgmt_report.view"),
        ("/api/v1/loan-reports/interest?from=2026-10-01&to=2026-10-31", "mgmt_report.view"),
        ("/api/v1/loan-reports/ageing", "mgmt_report.view"),
        ("/api/v1/loan-reports/demand-collection?from=2026-10-01&to=2026-10-31", "mgmt_report.view"),
        ("/api/v1/loan-reports/due-list", "mgmt_report.view"),
        ("/api/v1/loan-reports/overdue-list", "mgmt_report.view"),
        ("/api/v1/loan-reports/restructured-written-off", "mgmt_report.view"),
        ("/api/v1/loan-reports/guarantor-exposure", "mgmt_report.view"),
        (f"/api/v1/loans/{ID}/documents", "loan.view"),
        (f"/api/v1/loans/{ID}/sanction-letter", "loan.view"),
    ],
)
def test_report_and_document_endpoints_require_privilege(api, path, privilege):
    client, connection = api
    connection.results.append(FakeResult(one={"allowed": False}))
    assert client.get(path).status_code == 403
    assert connection.calls[0][1][1] == privilege


@pytest.mark.parametrize(
    ("path", "function", "params"),
    [
        ("/api/v1/loan-reports/outstanding?status=OVERDUE", "loan.report_outstanding", (None, "OVERDUE")),
        ("/api/v1/loan-reports/interest?from=2026-10-01&to=2026-10-31", "loan.report_interest",
         (date(2026, 10, 1), date(2026, 10, 31))),
        ("/api/v1/loan-reports/ageing", "loan.report_ageing", ()),
        ("/api/v1/loan-reports/demand-collection?from=2026-10-01&to=2026-10-31", "loan.report_demand_collection",
         (date(2026, 10, 1), date(2026, 10, 31))),
        ("/api/v1/loan-reports/due-list?from=2026-11-15", "loan.report_due_list", (date(2026, 11, 15), None)),
        ("/api/v1/loan-reports/overdue-list?min_days=30", "loan.report_overdue_list", (30,)),
        ("/api/v1/loan-reports/restructured-written-off", "loan.report_restructured_written_off", ()),
        ("/api/v1/loan-reports/guarantor-exposure", "loan.report_guarantor_exposure", ()),
    ],
)
def test_reports_call_the_matching_routine(api, path, function, params):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": {"items": []}})])
    response = client.get(path)
    assert response.status_code == 200 and response.json() == {"items": []}
    sql, sent = connection.calls[1]
    assert function in sql and tuple(sent) == params


def test_report_period_must_be_in_order(api):
    client, connection = api
    connection.results.append(FakeResult(one={"allowed": True}))
    response = client.get("/api/v1/loan-reports/interest?from=2026-10-31&to=2026-10-01")
    assert response.status_code == 422
    assert response.json()["detail"]["shortCode"] == "INVALID_DATE_RANGE"


def test_documents_list_includes_missing_types(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": []}),
                               FakeResult(one={"result": ["ID_PROOF"]})])
    assert client.get(f"/api/v1/loans/{ID}/documents").json() == {"items": [], "missing": ["ID_PROOF"]}


def test_add_document_sends_metadata_and_checks_hash(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": [{"id": str(ID)}]}),
                               FakeResult(one={"allowed": True})])
    body = {"document_type": "ID_PROOF", "file_name": "id.pdf", "storage_key": "t/l/id.pdf", "size_bytes": 10}
    assert client.post(f"/api/v1/loans/{ID}/documents", json=body).status_code == 201
    assert connection.calls[1][1][1].obj == body
    bad = client.post(f"/api/v1/loans/{ID}/documents", json={**body, "sha256": "xyz"})
    assert bad.status_code == 422


def test_sanction_letter_as_json_and_html(api):
    client, connection = api
    letter = {"generated_on": "2026-11-15", "organisation": {"name": "Org"}, "member": {"full_name": "Asha"},
              "loan": {"loan_no": "LN-1", "approved_amount": 12000}, "schedule": [], "guarantors": [], "nominees": []}
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": letter}),
                               FakeResult(one={"allowed": True}), FakeResult(one={"result": letter}),
                               FakeResult(one={"allowed": True}), FakeResult(one={"result": None})])
    assert client.get(f"/api/v1/loans/{ID}/sanction-letter").json()["loan"]["loan_no"] == "LN-1"
    html = client.get(f"/api/v1/loans/{ID}/sanction-letter?format=html")
    assert html.headers["content-type"].startswith("text/html") and "LN-1" in html.text and "12,000.00" in html.text
    missing = client.get(f"/api/v1/loans/{ID}/sanction-letter")
    assert missing.status_code == 404 and missing.json()["detail"]["shortCode"] == "LOAN_NOT_FOUND"
