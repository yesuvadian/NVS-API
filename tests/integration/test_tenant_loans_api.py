from collections import deque
from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers.loans import router


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
def loan_api():
    connection = FakeConnection()
    principal = TenantPrincipal(
        tenant_id=uuid4(),
        user_id=uuid4(),
        session_id=uuid4(),
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
    return TestClient(app), connection


def product_row():
    return {
        "id": uuid4(),
        "code": "INTEREST_BEARING",
        "name": "Interest Bearing",
        "description": "Flat interest loan",
        "interest_method": "FLAT",
        "is_interest_free": False,
        "allows_tranches": False,
        "rule_set_code": "LOAN_TYPE_INTEREST_BEARING",
        "rule_set_version_id": uuid4(),
        "rule_set_version_no": 1,
        "effective_from": date(2026, 1, 1),
        "definition": {
            "rules": [
                {"code": "INTEREST", "value": {"method": "FLAT", "annualRatePercent": 12}},
                {"code": "AMOUNT_LIMITS", "value": {"min": 5000, "max": 200000}},
                {"code": "TENURE_LIMITS", "value": {"minMonths": 6, "maxMonths": 60}},
                {"code": "APPLICATION_FEE", "value": {"enabled": False}},
                {"code": "NOMINEE", "value": {"firstLoan": True}},
            ]
        },
    }


def member_context(*, overdue=False):
    return {
        "id": uuid4(),
        "member_no": "MEM-00001",
        "full_name": "Test Member",
        "status": "ACTIVE",
        "loan_eligibility": "ELIGIBLE",
        "membership_date": date(2020, 1, 1),
        "cooling_off_until": None,
        "working_date": date(2026, 11, 15),
        "is_first_loan": True,
        "concurrent_loan_count": 0,
        "outstanding_principal": Decimal("0.00"),
        "has_overdue_instalment": overdue,
    }


def default_settings():
    return {
        "min_membership_months": 6,
        "max_concurrent_loans": 1,
        "block_if_overdue_dues": True,
    }


def loan_row(*, status="DRAFT", member_id=None, loan_type_id=None):
    return {
        "id": uuid4(),
        "loan_no": "LN/2026-27/00001",
        "member_id": member_id or uuid4(),
        "member_no": "MEM-00001",
        "member_name": "Test Member",
        "loan_type_id": loan_type_id or uuid4(),
        "loan_type_code": "INTEREST_BEARING",
        "loan_type_name": "Interest Bearing",
        "purpose": "Home repairs",
        "requested_amount": Decimal("120000.00"),
        "requested_tenure_months": 12,
        "application_date": date(2026, 11, 15),
        "status": status,
        "status_date": date(2026, 11, 15),
        "is_first_loan": False,
        "approved_amount": None,
        "tenure_months": None,
        "interest_rate_annual": None,
        "interest_method": None,
        "total_interest": None,
        "instalment_amount": None,
        "rule_set_version_id": uuid4(),
        "workflow_version_id": uuid4(),
        "created_at": datetime(2026, 11, 15, tzinfo=UTC),
        "updated_at": None,
        "row_version": 1,
    }


def test_tenant_loan_types_show_read_only_published_rule_version(loan_api):
    client, connection = loan_api
    product = product_row()
    connection.results.extend(
        [FakeResult(one={"allowed": True}), FakeResult(many=[product])]
    )

    response = client.get("/api/v1/loan-types")

    assert response.status_code == 200
    result = response.json()[0]
    assert result["code"] == "INTEREST_BEARING"
    assert result["rule_set_version_no"] == 1
    assert result["terms"]["rules"][0]["code"] == "INTEREST"
    assert "INSERT" not in connection.calls[1][0].upper()


@pytest.mark.parametrize(("overdue", "eligible"), [(False, True), (True, False)])
def test_eligibility_quotes_flat_interest_and_checks_overdue_loans(loan_api, overdue, eligible):
    client, connection = loan_api
    product = product_row()
    member = member_context(overdue=overdue)
    connection.results.extend(
        [
            FakeResult(one={"allowed": True}),
            FakeResult(one=product),
            FakeResult(one=member),
            FakeResult(one=default_settings()),
            FakeResult(one={"exposure": None}),
            FakeResult(one=None),                                   # loan.get_current_workflow
        ]
    )

    response = client.post(
        "/api/v1/loans/eligibility",
        json={
            "member_id": str(member["id"]),
            "loan_type_id": str(product["id"]),
            "requested_amount": "120000.00",
            "requested_tenure_months": 12,
        },
    )

    assert response.status_code == 200
    result = response.json()
    assert result["eligible"] is eligible
    assert Decimal(result["estimated_total_interest"]) == Decimal("14400.00")
    assert Decimal(result["estimated_instalment_amount"]) == Decimal("11200.00")
    assert result["nominee_required"] is True
    # Criteria list for the UI (legacy workflow: everything checked at SUBMIT).
    codes = {c["code"]: c for c in result["criteria"]}
    assert codes["OVERDUE_DUES"]["met"] is (not overdue)
    assert codes["NOMINEE"]["required"] is True and codes["NOMINEE"]["met"] is None
    assert codes["AMOUNT_LIMITS"]["stage"] == "SUBMIT"


def test_submit_creates_manager_approval_request_and_task(loan_api):
    client, connection = loan_api
    loan = loan_row()
    product = product_row()
    product["id"] = loan["loan_type_id"]
    product["rule_set_version_id"] = loan["rule_set_version_id"]
    member = member_context()
    member["id"] = loan["member_id"]
    member["is_first_loan"] = False
    workflow = {"workflow_definition_id": uuid4(), "workflow_version_id": loan["workflow_version_id"],
                "definition": {"startStage": "DRAFT", "stages": [
                    {"code": "DRAFT", "statuses": {"initial": "DRAFT", "entityStatus": "DRAFT",
                     "stageStatuses": [{"code": "DRAFT"}]}},
                    {"code": "MANAGER_APPROVAL", "approval": {"roles": ["MGR"], "minApprovals": 1},
                     "statuses": {"initial": "PENDING", "entityStatus": "UNDER_APPROVAL",
                      "stageStatuses": [{"code": "PENDING"}]}}],
                    "transitions": [{"from": "DRAFT", "to": "MANAGER_APPROVAL", "on": "SUBMIT",
                                     "ruleChecks": ["MEMBER_STATUS", "AMOUNT_LIMITS", "NOMINEE"]}]}}
    workflow_instance_id = uuid4()
    approval_request_id = uuid4()

    connection.results.extend(
        [
            FakeResult(one={"allowed": True}),
            FakeResult(one=loan),
            FakeResult(many=[]),                                    # loan.get_nominee_overrides
            FakeResult(one=workflow),                               # loan's workflow version (legacy)
            FakeResult(one={"status": "DRAFT", "workflow_instance_id": workflow_instance_id,
                            "approval_request_id": None, "row_version": 1, "stage": "DRAFT",
                            "stage_status": "DRAFT", "instance_status": "RUNNING"}),  # workflow init state
            FakeResult(one=None),                                   # loan.get_application_fee
            FakeResult(one=product),
            FakeResult(one=member),
            FakeResult(one=default_settings()),
            FakeResult(one={"exposure": None}),
            FakeResult(one={"result": {"satisfied": True}}),        # loan.nominee_status
            FakeResult(one={"result": []}),
            FakeResult(one=None),
            FakeResult(one={"approval_request_id": approval_request_id}),
            FakeResult(one=loan_row(status="UNDER_APPROVAL", member_id=loan["member_id"], loan_type_id=loan["loan_type_id"])),
            FakeResult(many=[]),                                    # loan.get_nominee_overrides
            FakeResult(one={"status": "UNDER_APPROVAL", "workflow_instance_id": None,   # engine: state after actions
                            "approval_request_id": approval_request_id, "stage": None}),
            FakeResult(one={"result": {"status": "UNDER_APPROVAL"}}), # workflow.apply_loan_status
            FakeResult(), FakeResult(), FakeResult(),                 # execution log: rule, action, status
        ]
    )

    response = client.post(f"/api/v1/loans/{loan['id']}/submit")

    assert response.status_code == 200
    assert response.json()["status"] == "UNDER_APPROVAL"
    sql = [query for query, _params in connection.calls]
    assert any("loan.submit_application" in query for query in sql)
    assert not any("INSERT INTO wf.approval_request" in query for query in sql)


def test_application_fee_payment_posts_receipt_and_journal(loan_api):
    client, connection = loan_api
    loan_id = uuid4()
    connection.results.extend(
        [
            FakeResult(one={"allowed": True}),
            FakeResult(one={"stored": None}),                       # core.idempotency_begin
            FakeResult(one={"result": {"loan_id": str(loan_id), "fee_amount": "250.00",
                                        "status": "PAID", "cash_receipt_id": str(uuid4()),
                                        "journal_id": str(uuid4())}}),
            FakeResult(),                                           # core.idempotency_finish
        ]
    )

    response = client.post(
        f"/api/v1/loans/{loan_id}/application-fee",
        json={"payment_mode": "CASH"},
        headers={"Idempotency-Key": "fee-key-0001"},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "PAID"
    sql = [query for query, _params in connection.calls]
    assert any("loan.collect_application_fee" in query for query in sql)
    assert not any("INSERT INTO acct.cash_receipt" in query for query in sql)


LOAN_ID = "11111111-1111-1111-1111-111111111111"
OTHER_ID = "22222222-2222-2222-2222-222222222222"


@pytest.mark.parametrize(
    ("method", "path", "body", "privilege"),
    [
        ("post", "/api/v1/loans", {"member_id": LOAN_ID, "loan_type_id": OTHER_ID, "requested_amount": "10000.00",
                                   "requested_tenure_months": 12, "purpose": "Home repairs"}, "loan.create"),
        ("post", f"/api/v1/loans/{LOAN_ID}/application-fee", {}, "loan_fee.create"),
        ("post", f"/api/v1/loans/{LOAN_ID}/submit", None, "loan.create"),
        ("post", f"/api/v1/loan-approvals/{LOAN_ID}/decision", {"decision": "APPROVED"}, "loan.approve"),
        ("post", f"/api/v1/loans/{LOAN_ID}/disbursements", {"gross_amount": "100.00"}, "loan.edit"),
        ("post", f"/api/v1/loans/{LOAN_ID}/disbursements/{OTHER_ID}/release", {"payee_ack_type": "SIGNATURE"}, "loan.approve"),
        ("post", f"/api/v1/loans/{LOAN_ID}/repayments", {"amount": "100.00"}, "loan_repay.create"),
        ("get", f"/api/v1/loans/{LOAN_ID}/schedule", None, "loan.view"),
        ("get", f"/api/v1/loans/{LOAN_ID}/repayments", None, "loan_repay.view"),
        ("get", f"/api/v1/members/{LOAN_ID}/loan-statement", None, "loan.view"),
        ("post", f"/api/v1/loans/{LOAN_ID}/settlement-quote", None, "loan_settle.create"),
        ("patch", f"/api/v1/loan-applications/{LOAN_ID}", {"purpose": "School fees"}, ["loan.edit", "loan.create"]),
        ("get", f"/api/v1/loans/{LOAN_ID}/settlements", None, "loan_settle.view"),
        ("get", f"/api/v1/loan-settlements/{LOAN_ID}", None, "loan_settle.view"),
        ("post", f"/api/v1/loan-settlements/{LOAN_ID}/approve", {}, "loan_settle.approve"),
        ("post", f"/api/v1/loan-settlements/{LOAN_ID}/collect", {}, "loan_settle.create"),
    ],
)
def test_loan_endpoints_require_the_matching_privilege(loan_api, method, path, body, privilege):
    client, connection = loan_api
    connection.results.append(FakeResult(one={"allowed": False}))

    response = getattr(client, method)(path, json=body) if body is not None else getattr(client, method)(path)

    assert response.status_code == 403
    assert response.json()["detail"]["shortCode"] == "NO_PRIVILEGE"
    assert connection.calls[0][1][1] == privilege


def test_schedule_of_unknown_loan_is_not_found(loan_api):
    client, connection = loan_api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": None})])

    response = client.get(f"/api/v1/loans/{LOAN_ID}/schedule")

    assert response.status_code == 404
    assert response.json()["detail"]["shortCode"] == "LOAN_NOT_FOUND"
    assert "loan.get_schedule" in connection.calls[1][0]


def test_member_statement_of_unknown_member_is_not_found(loan_api):
    client, connection = loan_api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": None})])

    response = client.get(f"/api/v1/members/{LOAN_ID}/loan-statement")

    assert response.status_code == 404
    assert response.json()["detail"]["shortCode"] == "MEMBER_NOT_FOUND"


def test_settlement_quote_and_collection_call_database_routines(loan_api):
    client, connection = loan_api
    quote = {"id": OTHER_ID, "loan_id": LOAN_ID, "status": "QUOTED", "total_payable": 10060.0}
    collected = {"settlement_id": OTHER_ID, "status": "PAID", "loan_status": "SETTLED"}
    connection.results.extend([
        FakeResult(one={"allowed": True}), FakeResult(one={"result": quote}),
        FakeResult(one={"allowed": True}), FakeResult(one={"stored": None}),
        FakeResult(one={"result": collected}), FakeResult(),
    ])

    quoted = client.post(f"/api/v1/loans/{LOAN_ID}/settlement-quote")
    paid = client.post(f"/api/v1/loan-settlements/{OTHER_ID}/collect",
                       json={"payment_mode": "CASH", "payment_reference": "R-1"},
                       headers={"Idempotency-Key": "settle-key-01"})

    assert quoted.status_code == 201 and quoted.json()["total_payable"] == 10060.0
    assert paid.status_code == 201 and paid.json()["loan_status"] == "SETTLED"
    assert "loan.quote_early_settlement" in connection.calls[1][0]
    assert "core.idempotency_begin" in connection.calls[3][0]
    assert "loan.collect_early_settlement" in connection.calls[4][0]
    assert connection.calls[4][1][1:] == ("CASH", "R-1")
    assert "core.idempotency_finish" in connection.calls[5][0]


def test_unknown_settlement_is_not_found(loan_api):
    client, connection = loan_api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": None})])

    response = client.get(f"/api/v1/loan-settlements/{OTHER_ID}")

    assert response.status_code == 404
    assert response.json()["detail"]["shortCode"] == "SETTLEMENT_NOT_FOUND"


def test_settlement_quote_passes_interest_waiver(loan_api):
    client, connection = loan_api
    connection.results.extend([FakeResult(one={"allowed": True}), FakeResult(one={"result": {"id": OTHER_ID}})])

    response = client.post(f"/api/v1/loans/{LOAN_ID}/settlement-quote",
                           json={"interest_waiver": "440.00", "waiver_reason": "Hardship"})

    assert response.status_code == 201
    assert connection.calls[1][1][1:] == (Decimal("440.00"), "Hardship")


def test_settlement_quote_rejects_negative_waiver(loan_api):
    client, connection = loan_api
    connection.results.append(FakeResult(one={"allowed": True}))
    response = client.post(f"/api/v1/loans/{LOAN_ID}/settlement-quote", json={"interest_waiver": -1})
    assert response.status_code == 422
    assert not any("quote_early_settlement" in sql for sql, _ in connection.calls)


def test_disbursement_passes_payment_mode_and_reference(loan_api):
    client, connection = loan_api
    connection.results.extend([
        FakeResult(one={"allowed": True}), FakeResult(one={"stored": None}),
        FakeResult(one={"result": {"disbursement_id": OTHER_ID, "tranche_no": 1, "cash_limit_approval_required": False}}),
        FakeResult(),
    ])
    response = client.post(f"/api/v1/loans/{LOAN_ID}/disbursements",
                           json={"gross_amount": "5000.00", "payment_mode": "bank_transfer", "payment_reference": "NEFT-9"},
                           headers={"Idempotency-Key": "disb-key-0001"})
    assert response.status_code == 201 and response.json()["tranche_no"] == 1
    sql, params = connection.calls[2]
    assert "loan.prepare_disbursement(%s,%s,%s,%s)" in sql
    assert params[2:] == ("BANK_TRANSFER", "NEFT-9")
