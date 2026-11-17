"""HTTP tests for the loan servicing router (recovery, waivers, overrides, write-off).

The database is replaced by a scripted fake connection: each request first
checks the privilege, then calls one loan.* routine.
"""

import json
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.tenant_security import require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers.loan_servicing import router
from tests.integration.test_tenant_loans_api import FakeConnection, FakeResult, TenantPrincipal

ID = uuid4()
OTHER = uuid4()


@pytest.fixture
def api():
    from datetime import date

    connection = FakeConnection()
    principal = TenantPrincipal(tenant_id=uuid4(), user_id=uuid4(), role_code="MGR", channel="WEB",
                                mfa_verified=False, working_date=date(2026, 11, 15))
    app = FastAPI()
    app.include_router(router, prefix="/api/v1")

    async def fake_db():
        yield connection

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    return TestClient(app), connection


@pytest.mark.parametrize(
    "method,path,body,privilege",
    [
        ("get", "/api/v1/recovery-cases", None, "loan_default.view"),
        ("get", f"/api/v1/recovery-cases/{ID}", None, "loan_default.view"),
        ("post", f"/api/v1/recovery-cases/{ID}/assign", {"user_id": str(OTHER)}, "loan_default.edit"),
        ("post", f"/api/v1/recovery-cases/{ID}/contacts", {"outcome": "Will pay"}, "loan_default.create"),
        ("post", f"/api/v1/recovery-cases/{ID}/status", {"status": "LEGAL_NOTICE", "remarks": "Sent"}, "loan_default.create"),
        ("get", f"/api/v1/loans/{ID}/waivers", None, "loan_default.view"),
        ("post", f"/api/v1/loans/{ID}/waivers", {"component": "PENALTY", "amount": 10, "reason": "Hardship"}, "loan_default.create"),
        ("get", f"/api/v1/loan-waivers/{ID}", None, "loan_default.view"),
        ("post", f"/api/v1/loan-waivers/{ID}/decision", {"approve": True}, "loan_default.approve"),
        ("post", f"/api/v1/members/{ID}/cooling-off-overrides", {"reason": "Medical"}, "loan_default.create"),
        ("get", f"/api/v1/cooling-off-overrides/{ID}", None, "loan_default.view"),
        ("post", f"/api/v1/cooling-off-overrides/{ID}/decision", {"approve": True}, "loan_default.approve"),
        ("post", f"/api/v1/loans/{ID}/write-off", {"reason": "Untraceable"}, "loan_default.create"),
        ("get", f"/api/v1/loan-write-offs/{ID}", None, "loan_default.view"),
        ("post", f"/api/v1/loan-write-offs/{ID}/decision", {"approve": True}, "loan_default.view"),
        ("post", f"/api/v1/loans/{ID}/written-off-recoveries", {"amount": 100}, "loan_repay.create"),
        ("post", f"/api/v1/loan-applications/{ID}/withdraw", {"reason": "Changed mind"}, "loan.edit"),
        ("post", f"/api/v1/loans/{ID}/cancellation", {"reason": "Not needed"}, "loan.edit"),
        ("get", f"/api/v1/loan-cancellations/{ID}", None, "loan.view"),
        ("post", f"/api/v1/loan-cancellations/{ID}/decision", {"approve": True}, "loan.approve"),
        ("post", f"/api/v1/loan-approvals/{ID}/offline-decision",
         {"decision": "APPROVED", "approved_by": str(OTHER), "evidence_type": "MEETING"}, "loan.create"),
        ("post", f"/api/v1/loan-approvals/{ID}/verification", {"result": "VERIFIED"}, "loan.approve"),
        ("post", f"/api/v1/loan-repayments/{ID}/reversal", {"reason": "Wrong loan"}, "loan_repay.create"),
        ("get", f"/api/v1/loans/{ID}/repayment-reversals", None, "loan_repay.view"),
        ("get", f"/api/v1/repayment-reversals/{ID}", None, "loan_repay.view"),
        ("post", f"/api/v1/repayment-reversals/{ID}/decision", {"approve": True}, "loan_repay.view"),
        ("get", f"/api/v1/loans/{ID}/guarantors", None, "loan.view"),
        ("post", f"/api/v1/loans/{ID}/guarantors", {"guarantor_member_id": str(OTHER), "consent_type": "SIGNATURE"}, "loan.edit"),
        ("delete", f"/api/v1/loan-guarantors/{ID}", None, "loan.edit"),
        ("post", f"/api/v1/loan-guarantors/{ID}/replacement",
         {"new_guarantor": {"guarantor_member_id": str(OTHER), "consent_type": "SIGNATURE"}, "reason": "Moved away"}, "loan.edit"),
        ("get", f"/api/v1/guarantor-replacements/{ID}", None, "loan.view"),
        ("post", f"/api/v1/guarantor-replacements/{ID}/decision", {"approve": True}, "loan.approve"),
        ("post", f"/api/v1/loan-disbursements/{ID}/cash-approval", {}, "loan.approve"),
        ("post", f"/api/v1/loans/{ID}/restructures", {"option": "EXTEND_TENURE", "reason": "Crop failure"}, "loan.edit"),
        ("get", f"/api/v1/loans/{ID}/restructures", None, "loan.view"),
        ("get", f"/api/v1/loan-restructures/{ID}", None, "loan.view"),
        ("post", f"/api/v1/loan-restructures/{ID}/decision", {"approve": True}, "loan.approve"),
        ("post", f"/api/v1/loans/{ID}/deceased-decision", {"decision": "TRANSFER"}, "loan.approve"),
        ("get", f"/api/v1/loans/{ID}/transfers", None, "loan.view"),
        ("post", f"/api/v1/loans/{ID}/transfers", {"shares": [{"successor_member_id": str(OTHER), "share_percent": 100}]},
         "loan.edit"),
        ("post", f"/api/v1/loans/{ID}/transfers/decision", {"approve": True}, "loan.approve"),
        ("get", "/api/v1/migration-reviews", None, "loan_default.view"),
        ("post", f"/api/v1/migration-reviews/{ID}/decision", {"apply_default": True, "remarks": "Old arrears"}, "loan.approve"),
    ],
)
def test_servicing_endpoints_require_the_matching_privilege(api, method, path, body, privilege):
    client, connection = api
    connection.results.append(FakeResult(one={"allowed": False}))
    response = getattr(client, method)(path, json=body) if body is not None else getattr(client, method)(path)
    assert response.status_code == 403
    assert connection.calls[0][1][1] == privilege


@pytest.mark.parametrize(
    "path,code",
    [
        (f"/api/v1/recovery-cases/{ID}", "RECOVERY_CASE_NOT_FOUND"),
        (f"/api/v1/loan-waivers/{ID}", "WAIVER_NOT_FOUND"),
        (f"/api/v1/cooling-off-overrides/{ID}", "OVERRIDE_NOT_FOUND"),
        (f"/api/v1/loan-write-offs/{ID}", "WRITE_OFF_NOT_FOUND"),
        (f"/api/v1/loan-cancellations/{ID}", "CANCELLATION_NOT_FOUND"),
        (f"/api/v1/repayment-reversals/{ID}", "REVERSAL_NOT_FOUND"),
        (f"/api/v1/guarantor-replacements/{ID}", "REPLACEMENT_NOT_FOUND"),
        (f"/api/v1/loan-restructures/{ID}", "RESTRUCTURE_NOT_FOUND"),
    ],
)
def test_unknown_records_are_not_found(api, path, code):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": None})])
    response = client.get(path)
    assert response.status_code == 404
    assert response.json()["detail"]["shortCode"] == code


def test_recovery_contact_is_sent_as_json(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(ID)}})])
    response = client.post(f"/api/v1/recovery-cases/{ID}/contacts",
                           json={"outcome": "Promised", "person_type": "GUARANTOR", "promise_date": "2026-11-20",
                                 "promise_amount": "500.00"})
    assert response.status_code == 201
    sql, params = connection.calls[1]
    assert "loan.log_recovery_contact(%s,%s)" in sql
    details = json.loads(json.dumps(params[1].obj))
    assert details == {"outcome": "Promised", "method": "CALL", "person_type": "GUARANTOR",
                       "promise_date": "2026-11-20", "promise_amount": "500.00"}


def test_recovery_list_filters(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": []})])
    response = client.get(f"/api/v1/recovery-cases?status=PENDING&follow_up_due=true&limit=10&offset=20")
    assert response.status_code == 200 and response.json() == []
    assert connection.calls[1][1] == ("PENDING", None, True, 10, 20)


def test_waiver_request_and_decision(api):
    client, connection = api
    connection.results.extend([
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(OTHER), "status": "PENDING"}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(OTHER), "status": "APPROVED"}}),
    ])
    requested = client.post(f"/api/v1/loans/{ID}/waivers",
                            json={"component": "LATE_FEE", "charge_id": str(OTHER), "amount": "50.00", "reason": "Bank holiday"})
    decided = client.post(f"/api/v1/loan-waivers/{OTHER}/decision", json={"approve": True, "remarks": "OK"})
    assert requested.status_code == 201 and decided.json()["status"] == "APPROVED"
    assert "loan.request_waiver" in connection.calls[1][0]
    assert connection.calls[1][1][1] == "LATE_FEE"
    assert connection.calls[3][1] == (OTHER, True, "OK")


def test_invalid_waiver_component_is_rejected(api):
    client, connection = api
    connection.results.append(FakeResult(one={"allowed": True}))
    response = client.post(f"/api/v1/loans/{ID}/waivers", json={"component": "INTEREST", "amount": 1, "reason": "No"})
    assert response.status_code == 422
    assert not any("request_waiver" in sql for sql, _ in connection.calls)


def test_write_off_flow_and_recovery(api):
    client, connection = api
    connection.results.extend([
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(OTHER), "status": "PENDING"}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(OTHER), "status": "APPROVED"}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"receipt_no": "R1"}}),
    ])
    assert client.post(f"/api/v1/loans/{ID}/write-off", json={"reason": "Untraceable"}).status_code == 201
    assert client.post(f"/api/v1/loan-write-offs/{OTHER}/decision", json={"approve": True}).status_code == 200
    paid = client.post(f"/api/v1/loans/{ID}/written-off-recoveries",
                       json={"amount": "100.00", "payment_mode": "UPI", "payment_reference": "U1"})
    assert paid.status_code == 201 and paid.json()["receipt_no"] == "R1"
    assert "loan.collect_written_off_recovery" in connection.calls[5][0]
    assert connection.calls[5][1][2:] == ("UPI", "U1")


def test_cooling_off_override_decision_passes_valid_until(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": {"status": "APPROVED"}})])
    response = client.post(f"/api/v1/cooling-off-overrides/{ID}/decision",
                           json={"approve": True, "valid_until": "2026-12-31", "remarks": "Medical"})
    assert response.status_code == 200
    from datetime import date
    assert connection.calls[1][1] == (ID, True, date(2026, 12, 31), "Medical")


def test_offline_decision_body_is_sent_as_json(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": {"decision": "APPROVED"}})])
    response = client.post(f"/api/v1/loan-approvals/{ID}/offline-decision",
                           json={"decision": "APPROVED", "approved_by": str(OTHER), "evidence_type": "MEETING",
                                 "decision_date": "2026-11-10", "approved_amount": "10000.00"})
    assert response.status_code == 201
    sql, params = connection.calls[1]
    assert "loan.record_offline_approval" in sql
    assert params[1].obj == {"decision": "APPROVED", "approved_by": str(OTHER), "evidence_type": "MEETING",
                             "decision_date": "2026-11-10", "approved_amount": "10000.00"}


def test_reversal_request_and_decision(api):
    client, connection = api
    connection.results.extend([
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(OTHER), "status": "PENDING"}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": str(OTHER), "status": "APPROVED"}}),
    ])
    assert client.post(f"/api/v1/loan-repayments/{ID}/reversal", json={"reason": "Wrong loan"}).status_code == 201
    decided = client.post(f"/api/v1/repayment-reversals/{OTHER}/decision", json={"approve": True})
    assert decided.json()["status"] == "APPROVED"
    assert connection.calls[1][1] == (ID, "Wrong loan")
    assert connection.calls[3][1] == (OTHER, True, None)


def test_add_guarantor_sends_details(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": []})])
    response = client.post(f"/api/v1/loans/{ID}/guarantors",
                           json={"non_member_name": "Ravi", "non_member_mobile": "9000000099", "consent_type": "THUMB_IMPRESSION",
                                 "guaranteed_amount": "5000.00"})
    assert response.status_code == 201
    assert connection.calls[1][1][1].obj == {"non_member_name": "Ravi", "non_member_mobile": "9000000099",
                                             "consent_type": "THUMB_IMPRESSION", "guaranteed_amount": "5000.00"}


def test_guarantor_without_consent_is_rejected(api):
    client, connection = api
    connection.results.append(FakeResult(one={"allowed": True}))
    response = client.post(f"/api/v1/loans/{ID}/guarantors", json={"guarantor_member_id": str(OTHER)})
    assert response.status_code == 422


def test_restructure_request_sends_only_given_terms(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": {"status": "REQUESTED"}})])
    response = client.post(f"/api/v1/loans/{ID}/restructures",
                           json={"option": "MORATORIUM", "reason": "Flood damage", "moratorium_months": 2})
    assert response.status_code == 201
    sql, params = connection.calls[1]
    assert "loan.request_restructure" in sql
    assert params[1].obj == {"option": "MORATORIUM", "reason": "Flood damage", "moratorium_months": 2}


def test_unknown_restructure_option_is_rejected(api):
    client, connection = api
    connection.results.append(FakeResult(one={"allowed": True}))
    response = client.post(f"/api/v1/loans/{ID}/restructures", json={"option": "FORGIVE", "reason": "Because"})
    assert response.status_code == 422


def test_transfer_shares_are_sent_as_a_json_list(api):
    client, connection = api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": []})])
    response = client.post(f"/api/v1/loans/{ID}/transfers", json={"shares": [
        {"successor_member_id": str(OTHER), "share_percent": "60"}, {"successor_member_id": str(ID), "share_percent": "40"}]})
    assert response.status_code == 201
    assert connection.calls[1][1][1].obj == [{"successor_member_id": str(OTHER), "share_percent": "60"},
                                             {"successor_member_id": str(ID), "share_percent": "40"}]


def test_deceased_decision_cash_approval_and_migration_review(api):
    client, connection = api
    connection.results.extend([
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"decision": "TRANSFER"}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"disbursement_id": str(ID)}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": {"status": "DISMISSED"}}),
        FakeResult(one={"allowed": True}), FakeResult(one={"result": []}),
    ])
    assert client.post(f"/api/v1/loans/{ID}/deceased-decision", json={"decision": "TRANSFER", "remarks": "Heirs agree"}
                       ).status_code == 201
    assert client.post(f"/api/v1/loan-disbursements/{ID}/cash-approval", json={"remarks": "In person"}).status_code == 200
    assert client.post(f"/api/v1/migration-reviews/{OTHER}/decision",
                       json={"apply_default": False, "remarks": "Old dues settled offline"}).json()["status"] == "DISMISSED"
    assert client.get("/api/v1/migration-reviews?status=DISMISSED").status_code == 200
    assert connection.calls[1][1] == (ID, "TRANSFER", "Heirs agree")
    assert connection.calls[3][1] == (ID, "In person")
    assert connection.calls[5][1] == (OTHER, False, "Old dues settled offline")
    assert connection.calls[7][1] == ("DISMISSED",)
