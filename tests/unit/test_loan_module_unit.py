"""Unit tests for the loan module: services, error localisation, configuration,
seed script order and the job runner. No database is needed."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
from datetime import date
from decimal import Decimal
from pathlib import Path
from uuid import uuid4

import pytest
from pydantic import SecretStr

import jobs
import seed
from app.core import config as config_module
from app.core.config import DatabaseNotConfigured, Settings
from app.core.errors import FALLBACK_STATUS, AppError, Localisation
from app.repositories.loan_lifecycle import allocate_due_repayment
from app.services.loans import LoanService

run = asyncio.run


# -----------------------------------------------------------------------------
# Fakes
# -----------------------------------------------------------------------------
class FakeLifecycle:
    """Returns the scripted value for every call and records the arguments."""

    def __init__(self, value=None) -> None:
        self.value = value
        self.calls: list[tuple[str, tuple, dict]] = []

    def __getattr__(self, name):
        async def method(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            return self.value
        return method


class FakeRepository:
    def __init__(self, *, product=None, member=None, settings=None, loan=None, nominees=0, fee=None,
                 workflow=None, submitted=None) -> None:
        self.product, self.member, self.settings = product, member, settings
        self.loan, self.nominees, self.fee = loan, nominees, fee
        self.workflow, self.submitted = workflow, submitted

    async def get_type(self, _id):
        return self.product

    async def member_eligibility_context(self, _id):
        return self.member

    async def loan_settings(self):
        return self.settings

    async def member_exposure(self, _member, _type):
        return None

    async def get_application(self, _id, lock=False):
        return self.loan

    async def loan_for_approval_request(self, _request_id):
        return self.loan["id"] if self.loan else None

    async def application_nominee_count(self, _id):
        return self.nominees

    # Nominee override (loan.nominee_override); no privilege unless a test sets it.
    privileged = False
    overrides: list = []

    async def has_privilege(self, code):
        return self.privileged and code == "loan.nominee_override"

    async def nominee_status(self, _loan_id):
        """Mimics loan.nominee_status from the product NOMINEE rule (db/31g)."""
        rule = next((r["value"] for r in self.product["definition"]["rules"] if r["code"] == "NOMINEE"), {})
        from app.services.loans import nominee_reasons
        why = nominee_reasons(rule, first_loan=bool(self.loan and self.loan["is_first_loan"]), first_loan_setting=True,
                              requested_amount=self.loan["requested_amount"] if self.loan else Decimal("0"))
        return {"required": bool(why), "required_because": why, "active_nominees": self.nominees,
                "override_allowed": rule.get("allowOverride", True), "overridden": bool(self.overrides),
                "satisfied": not why or self.nominees > 0 or bool(self.overrides)}

    async def record_nominee_override(self, loan_id, reason):
        """Mimics loan.record_nominee_override's checks (privilege, allowOverride, reason)."""
        status = await self.nominee_status(loan_id)
        if not self.privileged:
            raise AppError("NOMINEE_REQUIRED")
        if not status["override_allowed"]:
            raise AppError("NOMINEE_OVERRIDE_NOT_ALLOWED")
        if not 3 <= len(reason.strip()) <= 500:
            raise AppError("NOMINEE_OVERRIDE_REASON_REQUIRED")
        self.overrides = [*self.overrides, (loan_id, reason)]
        return status

    async def application_fee(self, _id):
        return self.fee

    async def workflow_version(self, _id):
        return self.workflow

    async def submit_application(self, loan, workflow):
        return self.submitted


class FakeWorkflow:
    """Engine persistence fake: records log rows, routes and status changes."""

    def __init__(self, state=None):
        self.executions, self.routes, self.statuses = [], [], []
        self.state = state or {}

    async def record_executions(self, instance, rows):
        self.executions.append((instance, rows))

    async def route_approval_request(self, request_id, roles, check):
        self.routes.append((request_id, roles, check))

    async def loan_state(self, _loan_id):
        return self.state

    async def apply_loan_status(self, _loan_id, change, instance):
        self.statuses.append((change, instance))
        return change

    async def approval_request_state(self, _request_id):
        return {"routed_checks": []}


def service_with(repository=None, lifecycle=None, workflow=None) -> LoanService:
    service = LoanService(conn=None)
    service.workflow = workflow or FakeWorkflow()
    if repository is not None:
        service.repository = repository
    if lifecycle is not None:
        service.lifecycle = lifecycle
    return service


def product(**rules) -> dict:
    base = {
        "INTEREST": {"method": "FLAT", "annualRatePercent": 12},
        "AMOUNT_LIMITS": {"min": 5000, "max": 200000},
        "TENURE_LIMITS": {"minMonths": 6, "maxMonths": 60},
        "APPLICATION_FEE": {"enabled": False},
        "NOMINEE": {"firstLoan": True},
    }
    base.update(rules)
    return {"id": uuid4(), "interest_method": "FLAT", "rule_set_version_id": uuid4(),
            "definition": {"rules": [{"code": k, "value": v} for k, v in base.items()]}}


def member(**overrides) -> dict:
    value = {"id": uuid4(), "status": "ACTIVE", "loan_eligibility": "ELIGIBLE", "cooling_off_until": None,
             "membership_date": date(2020, 1, 1), "working_date": date(2026, 11, 15), "is_first_loan": True,
             "concurrent_loan_count": 0, "has_overdue_instalment": False}
    value.update(overrides)
    return value


SETTINGS = {"min_membership_months": 6, "max_concurrent_loans": 1,
            "nominee_mandatory_first_loan": True, "block_if_overdue_dues": True}


def eligibility(service: LoanService, amount="12000.00", tenure=12, **kwargs):
    return run(service.eligibility(member_id=uuid4(), loan_type_id=uuid4(),
                                   requested_amount=Decimal(amount), requested_tenure_months=tenure, **kwargs))


# -----------------------------------------------------------------------------
# Eligibility and quote
# -----------------------------------------------------------------------------
def test_eligibility_flat_interest_quote():
    result = eligibility(service_with(FakeRepository(product=product(), member=member(), settings=SETTINGS)))
    assert result["eligible"] is True
    assert result["estimated_total_interest"] == Decimal("1440.00")
    assert result["estimated_instalment_amount"] == Decimal("1120.00")
    assert result["total_repayable"] == Decimal("13440.00")


def test_eligibility_interest_free_and_fees():
    free = product(INTEREST={"method": "NONE", "annualRatePercent": 12},
                   APPLICATION_FEE={"enabled": True, "type": "percent", "amount": 1.5, "timing": "after_submission"})
    result = eligibility(service_with(FakeRepository(product=free, member=member(), settings=SETTINGS)))
    assert result["estimated_total_interest"] == Decimal("0.00") and result["interest_rate_annual"] == 0
    assert result["application_fee"] == Decimal("180.00") and result["fee_timing"] == "AFTER_SUBMISSION"
    fixed = product(APPLICATION_FEE={"enabled": True, "type": "fixed", "amount": 200, "timing": "BEFORE_SUBMISSION"})
    result = eligibility(service_with(FakeRepository(product=fixed, member=member(), settings=SETTINGS)))
    assert result["application_fee"] == Decimal("200.00") and result["fee_timing"] == "BEFORE_SUBMISSION"


@pytest.mark.parametrize(("rule", "value", "missing"), [
    ("APPLICATION_FEE", {"enabled": True, "type": "fixed", "amount": 200}, "APPLICATION_FEE.timing"),
    ("APPLICATION_FEE", {"type": "fixed", "amount": 200}, "APPLICATION_FEE.enabled"),
    ("AMOUNT_LIMITS", {"min": 5000}, "AMOUNT_LIMITS.max"),
    ("TENURE_LIMITS", {"minMonths": 6}, "TENURE_LIMITS.maxMonths"),
    ("INTEREST", {"annualRatePercent": 12}, "INTEREST.method"),
    ("INTEREST", {"method": "FLAT"}, "INTEREST.annualRatePercent"),
])
def test_eligibility_refuses_missing_rule_fields(rule, value, missing):
    """No business defaults in code: a missing rule field refuses clearly."""
    from app.core.errors import AppError

    with pytest.raises(AppError) as error:
        eligibility(service_with(FakeRepository(product=product(**{rule: value}), member=member(), settings=SETTINGS)))
    assert error.value.short_code == "LOAN_RULE_MISSING" and error.value.params["rule"] == missing


def test_eligibility_refuses_missing_rule_and_unknown_interest_method():
    from app.core.errors import AppError

    no_limits = product()
    no_limits["definition"]["rules"] = [r for r in no_limits["definition"]["rules"] if r["code"] != "AMOUNT_LIMITS"]
    with pytest.raises(AppError) as error:
        eligibility(service_with(FakeRepository(product=no_limits, member=member(), settings=SETTINGS)))
    assert error.value.short_code == "LOAN_RULE_MISSING" and error.value.params["rule"] == "AMOUNT_LIMITS"
    reducing = product(INTEREST={"method": "REDUCING", "annualRatePercent": 12})
    with pytest.raises(AppError) as error:
        eligibility(service_with(FakeRepository(product=reducing, member=member(), settings=SETTINGS)))
    assert error.value.short_code == "INTEREST_METHOD_UNSUPPORTED"


@pytest.mark.parametrize(
    ("overrides", "amount", "tenure", "reason"),
    [
        ({"status": "SUSPENDED"}, "12000.00", 12, "MEMBER_NOT_ACTIVE"),
        ({"loan_eligibility": "RESTRICTED"}, "12000.00", 12, "MEMBER_RESTRICTED"),
        ({"loan_eligibility": "COOLING_OFF"}, "12000.00", 12, "MEMBER_COOLING_OFF"),
        ({"cooling_off_until": date(2026, 11, 15)}, "12000.00", 12, "MEMBER_IN_COOLING_OFF"),
        ({"membership_date": None}, "12000.00", 12, "MEMBERSHIP_DATE_REQUIRED"),
        ({"membership_date": date(2026, 5, 16)}, "12000.00", 12, "MIN_MEMBERSHIP_PERIOD_NOT_MET"),
        ({"concurrent_loan_count": 1}, "12000.00", 12, "MAX_CONCURRENT_LOANS_REACHED"),
        ({"has_overdue_instalment": True}, "12000.00", 12, "OVERDUE_LOAN_INSTALMENT"),
        ({}, "4999.99", 12, "AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS"),
        ({}, "200000.01", 12, "AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS"),
        ({}, "12000.00", 5, "TENURE_OUTSIDE_LOAN_TYPE_LIMITS"),
        ({}, "12000.00", 61, "TENURE_OUTSIDE_LOAN_TYPE_LIMITS"),
    ],
)
def test_eligibility_reasons(overrides, amount, tenure, reason):
    result = eligibility(service_with(FakeRepository(product=product(), member=member(**overrides), settings=SETTINGS)),
                         amount, tenure)
    assert result["eligible"] is False and reason in result["reasons"]


def test_eligibility_boundaries_are_inclusive():
    service = service_with(FakeRepository(product=product(), member=member(membership_date=date(2026, 5, 15)),
                                          settings=SETTINGS))
    assert eligibility(service, "5000.00", 6)["eligible"] is True
    assert eligibility(service, "200000.00", 60)["eligible"] is True


def test_eligibility_overdue_check_can_be_switched_off():
    settings = {**SETTINGS, "block_if_overdue_dues": False}
    result = eligibility(service_with(FakeRepository(product=product(), member=member(has_overdue_instalment=True),
                                                     settings=settings)))
    assert result["eligible"] is True


def test_eligibility_unknown_type_and_member():
    with pytest.raises(AppError) as error:
        eligibility(service_with(FakeRepository(product=None)))
    assert error.value.short_code == "LOAN_TYPE_NOT_FOUND" and error.value.status_code == 404
    with pytest.raises(AppError) as error:
        eligibility(service_with(FakeRepository(product=product(), member=None)))
    assert error.value.short_code == "MEMBER_NOT_FOUND"


def test_first_loan_override_controls_nominee_requirement():
    service = service_with(FakeRepository(product=product(), member=member(is_first_loan=False), settings=SETTINGS))
    assert eligibility(service)["nominee_required"] is False
    assert eligibility(service, first_loan=True)["nominee_required"] is True
    no_rule = service_with(FakeRepository(product=product(NOMINEE={"firstLoan": False}), member=member(),
                                          settings=SETTINGS))
    assert eligibility(no_rule)["nominee_required"] is False


# -----------------------------------------------------------------------------
# Submit
# -----------------------------------------------------------------------------
def loan(**overrides) -> dict:
    value = {"id": uuid4(), "status": "DRAFT", "member_id": uuid4(), "loan_type_id": uuid4(),
             "requested_amount": Decimal("12000.00"), "requested_tenure_months": 12, "is_first_loan": True,
             "workflow_version_id": uuid4()}
    value.update(overrides)
    return value


def submit(repository: FakeRepository):
    return run(service_with(repository, FakeLifecycle([])).submit_application(uuid4()))


def submit_repo(**overrides) -> FakeRepository:
    # the member already has this draft, so the history says "not first loan"
    values = {"product": product(), "member": member(is_first_loan=False), "settings": SETTINGS, "loan": loan(),
              "nominees": 1, "fee": None, "workflow": {"id": uuid4()}, "submitted": {"status": "UNDER_APPROVAL"}}
    values.update(overrides)
    return FakeRepository(**values)


def test_submit_positive():
    assert submit(submit_repo())["status"] == "UNDER_APPROVAL"
    assert submit(submit_repo(loan=loan(status="RETURNED")))["status"] == "UNDER_APPROVAL"
    paid = {"collect_timing": "BEFORE_SUBMISSION", "status": "PAID"}
    assert submit(submit_repo(fee=paid))["status"] == "UNDER_APPROVAL"
    deducted = {"collect_timing": "DEDUCT_FROM_DISBURSEMENT", "status": "PENDING"}
    assert submit(submit_repo(fee=deducted))["status"] == "UNDER_APPROVAL"


@pytest.mark.parametrize(
    ("overrides", "code"),
    [
        ({"loan": None}, "LOAN_APPLICATION_NOT_FOUND"),
        ({"loan": loan(status="UNDER_APPROVAL")}, "LOAN_NOT_SUBMITTABLE"),
        ({"loan": loan(status="APPROVED")}, "LOAN_NOT_SUBMITTABLE"),
        ({"member": member(status="SUSPENDED", is_first_loan=False)}, "LOAN_INELIGIBLE"),
        ({"nominees": 0}, "NOMINEE_REQUIRED"),       # first-loan application without nominee
        ({"fee": {"collect_timing": "BEFORE_SUBMISSION", "status": "PENDING"}}, "FEE_UNPAID"),
        ({"workflow": None}, "LOAN_WORKFLOW_NOT_CONFIGURED"),
        ({"submitted": None}, "LOAN_WORKFLOW_NOT_CONFIGURED"),
    ],
)
def test_submit_negative(overrides, code):
    with pytest.raises(AppError) as error:
        submit(submit_repo(**overrides))
    assert error.value.short_code == code


def test_submit_ineligible_lists_reasons():
    with pytest.raises(AppError) as error:
        submit(submit_repo(member=member(loan_eligibility="RESTRICTED", is_first_loan=False)))
    assert error.value.details == {"reasons": ["MEMBER_RESTRICTED"]}


# Rules linked to workflow transitions (app/services/loan_rules.py) ------------
V2_WORKFLOW = {"definition": {"transitions": [
    {"from": "DRAFT", "to": "MANAGER_APPROVAL", "on": "SUBMIT",
     "ruleChecks": ["MEMBER_STATUS", "MEMBERSHIP_PERIOD", "CONCURRENT_LOANS", "OVERDUE_DUES", "AGE_LIMITS",
                    "EXPOSURE_LIMITS", "AMOUNT_LIMITS", "TENURE_LIMITS", "GUARANTORS"]},
    {"from": "MANAGER_APPROVAL", "to": "APPROVED", "on": "APPROVE", "ruleChecks": ["NOMINEE", "GUARANTORS"]},
    {"from": "APPROVED", "to": "DISBURSED", "on": "DISBURSE", "ruleChecks": ["NOMINEE"]},
]}}


def every_loan_repo(**overrides) -> FakeRepository:
    return submit_repo(product=product(NOMINEE={"everyLoan": True, **overrides.pop("rule", {})}),
                       nominees=0, **overrides)


def enforce(repository, event, workflow=V2_WORKFLOW, reason=None):
    service = service_with(repository, FakeLifecycle([]))
    return run(service.enforce_transition(repository.loan, event, workflow=workflow, nominee_override_reason=reason))


def test_legacy_workflow_still_needs_the_nominee_at_submit():
    with pytest.raises(AppError) as error:
        submit(every_loan_repo())                    # workflow without ruleChecks
    assert error.value.short_code == "NOMINEE_REQUIRED"


def test_v2_workflow_submits_without_a_nominee():
    repository = every_loan_repo(workflow=V2_WORKFLOW)
    assert submit(repository)["status"] == "UNDER_APPROVAL"


def test_approve_needs_nominee_or_privileged_override_with_reason():
    repository = every_loan_repo()
    with pytest.raises(AppError) as error:
        enforce(repository, "APPROVE")
    assert error.value.short_code == "NOMINEE_REQUIRED"
    with pytest.raises(AppError) as error:
        enforce(repository, "APPROVE", reason="Member has no family")      # no privilege
    assert error.value.short_code == "NOMINEE_REQUIRED"
    repository.privileged = True
    with pytest.raises(AppError) as error:
        enforce(repository, "APPROVE", reason="ab")
    assert error.value.short_code == "NOMINEE_OVERRIDE_REASON_REQUIRED"
    enforce(repository, "APPROVE", reason="  Member has no family  ")
    assert repository.overrides[0][1] == "Member has no family"


def test_approve_override_switched_off_by_the_rule():
    repository = every_loan_repo(rule={"allowOverride": False})
    repository.privileged = True
    with pytest.raises(AppError) as error:
        enforce(repository, "APPROVE", reason="Member has no family")
    assert error.value.short_code == "NOMINEE_OVERRIDE_NOT_ALLOWED"


def test_disburse_blocks_without_active_nominee_even_for_privileged_users():
    repository = every_loan_repo()
    repository.privileged = True
    with pytest.raises(AppError) as error:
        enforce(repository, "DISBURSE", reason="Member has no family")
    assert error.value.short_code == "NOMINEE_REQUIRED"
    assert repository.overrides == []
    repository.nominees = 1
    enforce(repository, "DISBURSE")


def test_warn_outcome_never_blocks():
    workflow = {"definition": {"transitions": [
        {"from": "A", "to": "B", "on": "APPROVE", "ruleChecks": [{"code": "NOMINEE", "onFail": "WARN"}]}]}}
    enforce(every_loan_repo(), "APPROVE", workflow=workflow)


def test_submit_without_nominee_allowed_when_not_first_loan():
    assert submit(submit_repo(loan=loan(is_first_loan=False), nominees=0))["status"] == "UNDER_APPROVAL"


# -----------------------------------------------------------------------------
# Lifecycle, views and settlement: not-found mapping and pass-through
# -----------------------------------------------------------------------------
@pytest.mark.parametrize(
    ("method", "args", "code"),
    [
        ("collect_application_fee", (uuid4(),), "LOAN_APPLICATION_NOT_FOUND"),
        ("decide", (uuid4(), {"decision": "APPROVED"}), "APPROVAL_REQUEST_NOT_FOUND"),
        ("prepare_disbursement", (uuid4(), Decimal("1")), "LOAN_NOT_FOUND"),
        ("release_disbursement", (uuid4(), uuid4(), "SIGNATURE"), "DISBURSEMENT_NOT_FOUND"),
        ("collect_repayment", (uuid4(),), "LOAN_NOT_FOUND"),
        ("schedule", (uuid4(),), "LOAN_NOT_FOUND"),
        ("repayments", (uuid4(),), "LOAN_NOT_FOUND"),
        ("member_statement", (uuid4(),), "MEMBER_NOT_FOUND"),
        ("settlement", (uuid4(),), "SETTLEMENT_NOT_FOUND"),
        ("settlements", (uuid4(),), "LOAN_NOT_FOUND"),
    ],
)
def test_service_maps_missing_rows_to_not_found(method, args, code):
    with pytest.raises(AppError) as error:
        run(getattr(service_with(FakeRepository(), lifecycle=FakeLifecycle(None)), method)(*args))
    assert error.value.short_code == code


@pytest.mark.parametrize(
    ("method", "args", "kwargs", "repo_method"),
    [
        ("schedule", (uuid4(),), {}, "schedule"),
        ("repayments", (uuid4(),), {}, "repayments"),
        ("member_statement", (uuid4(),), {}, "member_statement"),
        ("quote_settlement", (uuid4(),), {}, "quote_settlement"),
        ("approve_settlement", (uuid4(), "ok"), {}, "approve_settlement"),
        ("collect_settlement", (uuid4(),), {"payment_mode": "CASH", "payment_reference": None}, "collect_settlement"),
        ("settlement", (uuid4(),), {}, "settlement"),
        ("settlements", (uuid4(),), {}, "settlements"),
    ],
)
def test_service_passes_results_through(method, args, kwargs, repo_method):
    lifecycle = FakeLifecycle({"ok": True})
    assert run(getattr(service_with(lifecycle=lifecycle), method)(*args, **kwargs)) == {"ok": True}
    assert lifecycle.calls[0][0] == repo_method


def test_empty_lists_are_not_treated_as_missing():
    assert run(service_with(lifecycle=FakeLifecycle([])).repayments(uuid4())) == []
    assert run(service_with(lifecycle=FakeLifecycle([])).settlements(uuid4())) == []


def test_repayment_allocation_mirror_partial_and_excess():
    first, second = uuid4(), uuid4()
    rows = [{"id": first, "interest_open": "120", "principal_open": "1000"},
            {"id": second, "interest_open": "120", "principal_open": "1000"}]
    allocations, principal, interest = allocate_due_repayment(Decimal("1200"), rows)
    assert allocations == [(first, "INTEREST", Decimal("120")), (first, "PRINCIPAL", Decimal("1000")),
                           (second, "INTEREST", Decimal("80"))]
    assert (principal, interest) == (Decimal("1000"), Decimal("200"))
    with pytest.raises(AppError) as error:
        allocate_due_repayment(Decimal("2240.01"), rows)
    assert error.value.short_code == "REPAYMENT_EXCEEDS_DUES"


# -----------------------------------------------------------------------------
# Error localisation of the loan codes
# -----------------------------------------------------------------------------
LOAN_CODES = {
    "SETTLEMENT_NOT_APPROVED": {"code": "CFMS-LOAN-5005", "http": 409, "retryable": False,
                                "message": "The settlement quote must be approved before collection.",
                                "translations": {"ta": "வசூலிப்பதற்கு முன் தீர்வு மதிப்பீடு அங்கீகரிக்கப்பட வேண்டும்."}},
    "LOAN_NOT_APPROVED": {"code": "CFMS-LOAN-2001", "http": 422, "retryable": False,
                          "message": "Loan status {status} cannot be disbursed.",
                          "translations": {"ta": "கடன் நிலை {status} வழங்க முடியாது."}},
    "LOAN_NOT_FOUND": {"code": "CFMS-LOAN-4001", "http": 404, "retryable": False,
                       "message": "The loan was not found.", "translations": {}},
}


def localiser() -> Localisation:
    value = Localisation()
    value.codes = LOAN_CODES
    value.languages = {"en", "ta"}
    return value


def test_loan_codes_render_in_tamil_and_english():
    status, body = localiser().render("SETTLEMENT_NOT_APPROVED", "ta")
    assert status == 409 and body["language"] == "ta" and body["code"] == "CFMS-LOAN-5005"
    status, body = localiser().render("SETTLEMENT_NOT_APPROVED", "en")
    assert body["message"].startswith("The settlement quote")


def test_missing_translation_falls_back_to_english():
    status, body = localiser().render("LOAN_NOT_FOUND", "ta")
    assert status == 404 and body["language"] == "en" and body["message"] == "The loan was not found."


def test_database_filled_message_wins_over_placeholder_translation():
    _status, body = localiser().render("LOAN_NOT_APPROVED", "ta",
                                       english_override="Loan status DRAFT cannot be disbursed")
    assert body["language"] == "en" and body["message"] == "Loan status DRAFT cannot be disbursed"
    _status, body = localiser().render("LOAN_NOT_APPROVED", "ta", params={"status": "DRAFT"})
    assert body["message"] == "கடன் நிலை DRAFT வழங்க முடியாது."


def test_unknown_code_keeps_fallback_status():
    status, body = localiser().render("SOMETHING_NEW", "ta", fallback_status=418)
    assert status == 418 and body["code"] is None and body["message"] == "SOMETHING_NEW"


@pytest.mark.parametrize(
    ("code", "status"),
    [("SETTLEMENT_NOT_FOUND", 404), ("SETTLEMENT_APPROVER_IS_CREATOR", 403), ("SETTLEMENT_QUOTE_STALE", 409),
     ("SETTLEMENT_NOT_APPROVED", 409), ("SETTLEMENT_NOT_PENDING", 409), ("LOAN_NOT_FOUND", 404),
     ("NOMINEE_REQUIRED", 422)],
)
def test_app_error_status_without_catalogue(code, status):
    assert AppError(code).status_code == status == FALLBACK_STATUS.get(code, 422)


# -----------------------------------------------------------------------------
# Configuration: database settings come only from .env
# -----------------------------------------------------------------------------
def db_settings(**values) -> Settings:
    base = {"db_host": "db.local", "db_port": 5433, "db_name": "nvs", "db_user": "nvs_api",
            "db_password": SecretStr("p@ss word"), "seed_db_user": "nvs", "seed_db_password": SecretStr("owner")}
    base.update(values)
    return Settings(_env_file=None, **base)


def test_dsn_is_built_from_env_parts():
    settings = db_settings()
    runtime, owner = settings.database_url, settings.seed_database_url
    assert "host=db.local" in runtime and "port=5433" in runtime and "dbname=nvs" in runtime
    assert "user=nvs_api" in runtime and "password='p@ss word'" in runtime
    assert "user=nvs" in owner and "password=owner" in owner and "nvs_api" not in owner


def test_dsn_without_password_omits_it():
    assert "password" not in db_settings(db_password=None).database_url
    assert "password" not in db_settings(db_password=SecretStr("")).database_url


@pytest.mark.parametrize(
    ("missing", "variable"),
    [("db_host", "CFMS_DB_HOST"), ("db_port", "CFMS_DB_PORT"), ("db_name", "CFMS_DB_NAME"), ("db_user", "CFMS_DB_USER")],
)
def test_missing_database_setting_is_reported(missing, variable):
    with pytest.raises(DatabaseNotConfigured, match=variable):
        _ = db_settings(**{missing: None}).database_url


def test_missing_seed_user_is_reported():
    with pytest.raises(DatabaseNotConfigured, match="CFMS_SEED_DB_USER"):
        _ = db_settings(seed_db_user=None).seed_database_url


def test_no_database_defaults_are_hard_coded():
    settings = Settings(_env_file=None)
    assert settings.db_host is None and settings.db_user is None and settings.seed_db_user is None
    assert config_module.ENV_FILE == Path(seed.ROOT) / ".env"


def test_settings_read_env_variables(monkeypatch):
    for key, value in {"CFMS_DB_HOST": "h", "CFMS_DB_PORT": "6000", "CFMS_DB_NAME": "n",
                       "CFMS_DB_USER": "u", "CFMS_DB_PASSWORD": "pw"}.items():
        monkeypatch.setenv(key, value)
    url = Settings(_env_file=None).database_url
    assert "host=h" in url and "port=6000" in url and "user=u" in url and "password=pw" in url


# -----------------------------------------------------------------------------
# seed.py: every SQL file is part of the seed
# -----------------------------------------------------------------------------
BOOTSTRAP = {"00a_bootstrap_role_and_database.sql", "00b_bootstrap_database_setup.sql"}


def test_seed_runs_every_sql_file_except_bootstrap_and_demo():
    all_sql = {p.name for p in seed.DB_DIR.glob("*.sql")}
    order = seed.script_order(include_demo=False)
    assert set(order) == all_sql - BOOTSTRAP - {seed.DEMO_SCRIPT}
    assert len(order) == len(set(order))
    assert order.index("30_functions_provisioning.sql") < order.index("31_functions_api_queries.sql") \
        < order.index("32_functions_loan_servicing.sql") < order.index("44_seed_error_codes.sql")
    assert order[-1] == "90_verify.sql"


def test_seed_demo_adds_demo_script():
    assert seed.DEMO_SCRIPT in seed.script_order(include_demo=True)


def test_seed_strips_psql_meta_commands(tmp_path):
    script = tmp_path / "x.sql"
    script.write_text("\\echo hello\nSELECT 1;\n  \\set x 1\nSELECT 2;\n", encoding="utf-8")
    assert seed.sql_text(script) == "SELECT 1;\nSELECT 2;"


def test_seed_without_database_settings_fails_cleanly(monkeypatch, capsys):
    monkeypatch.setattr(seed, "get_settings", lambda: Settings(_env_file=None))
    monkeypatch.setattr("sys.argv", ["seed.py"])
    assert seed.main() == 1
    assert "CFMS_DB_HOST" in capsys.readouterr().out


def test_seed_list_needs_no_database(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["seed.py", "--list"])
    assert seed.main() == 0
    assert "32_functions_loan_servicing.sql" in capsys.readouterr().out


# -----------------------------------------------------------------------------
# jobs.py
# -----------------------------------------------------------------------------
class FakeSyncConn:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple | None]] = []

    def execute(self, sql, params=None):
        self.calls.append((sql, params))
        conn = self

        class Result:
            def fetchone(self_inner):
                return {"payload": "tenant|||SYSTEM"} if "context_payload" in sql else None

            def fetchall(self_inner):
                return [{"id": 1, "code": "demo"}, {"id": 2, "code": "other"}]
        return Result()


def test_job_context_is_signed_with_the_api_key():
    conn, key = FakeSyncConn(), bytes.fromhex("00ff")
    jobs.set_system_context(conn, "tenant", date(2026, 7, 11), key)
    assert "'SYSTEM', 'SYSTEM'" in conn.calls[0][0] and conn.calls[0][1] == ("tenant", date(2026, 7, 11))
    expected = hmac.new(key, b"tenant|||SYSTEM", hashlib.sha256).hexdigest()
    assert conn.calls[-1][1] == (expected,)


def test_job_tenant_filter():
    assert [t["code"] for t in jobs.tenants(FakeSyncConn(), None)] == ["demo", "other"]
    assert [t["code"] for t in jobs.tenants(FakeSyncConn(), "other")] == ["other"]
    assert jobs.tenants(FakeSyncConn(), "missing") == []


def test_job_runner_needs_signing_key_and_database(monkeypatch, capsys):
    monkeypatch.setattr(jobs, "get_settings", lambda: Settings(_env_file=None))
    assert jobs.run("loan-status", None, None) == 1
    assert "CFMS_DB_CONTEXT_SIGNING_KEY" in capsys.readouterr().err
    monkeypatch.setattr(jobs, "get_settings",
                        lambda: Settings(_env_file=None, db_context_signing_key=SecretStr("00ff")))
    assert jobs.run("loan-status", None, None) == 1
    assert "CFMS_DB_HOST" in capsys.readouterr().err


# -----------------------------------------------------------------------------
# Eligibility limits (age, per type, exposure, other dues, guarantors)
# -----------------------------------------------------------------------------
def test_exposure_reasons_cover_every_limit():
    from datetime import date as _date

    from app.services.loans import exposure_reasons

    definition = {"rules": [{"code": "CONCURRENT_LOANS", "value": {"maxPerType": 1}},
                            {"code": "AGE_LIMITS", "value": {"minAtApplication": 21, "maxAtMaturity": 60}},
                            {"code": "GUARANTORS", "value": {"count": 2, "aboveAmount": 50000}}]}
    exposure = {"date_of_birth": "1966-06-01", "type_loan_count": 1, "member_outstanding": "40000",
                "household_outstanding": "90000", "overdue_chit_dues": True, "overdue_contribution_dues": True,
                "age_limits": {"minAtApplication": 18}, "exposure_limits": {"perMember": 50000, "perHousehold": 100000},
                "guarantors_required": {"count": 0}}
    reasons, guarantors = exposure_reasons(definition=definition, exposure=exposure, working_date=_date(2026, 11, 15),
                                           requested_amount=Decimal("60000"), requested_tenure_months=24,
                                           block_if_overdue_dues=True)
    assert set(reasons) == {"AGE_AT_MATURITY_ABOVE_MAXIMUM", "MAX_LOANS_OF_TYPE_REACHED", "MEMBER_EXPOSURE_LIMIT_EXCEEDED",
                            "HOUSEHOLD_EXPOSURE_LIMIT_EXCEEDED", "OVERDUE_CHIT_DUES", "OVERDUE_CONTRIBUTION_DUES"}
    assert guarantors == 2
    reasons, guarantors = exposure_reasons(definition={"rules": []}, exposure={**exposure, "date_of_birth": None,
                                           "age_limits": {"minAtApplication": 18, "requireDateOfBirth": True}},
                                           working_date=_date(2026, 11, 15), requested_amount=Decimal("1000"),
                                           requested_tenure_months=12, block_if_overdue_dues=False)
    assert reasons == ["DATE_OF_BIRTH_REQUIRED"] and guarantors == 0
    assert exposure_reasons(definition={}, exposure=None, working_date=_date(2026, 1, 1), requested_amount=Decimal(1),
                            requested_tenure_months=1, block_if_overdue_dues=True) == ([], 0)


def test_submit_refuses_missing_documents():
    with pytest.raises(AppError) as error:
        run(service_with(submit_repo(), FakeLifecycle(["ID_PROOF", "PHOTO"])).submit_application(uuid4()))
    assert error.value.short_code == "DOCUMENTS_REQUIRED"
    assert error.value.details == {"missing": ["ID_PROOF", "PHOTO"]}
