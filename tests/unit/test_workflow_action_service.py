"""Direct unit coverage for workflow button filtering and execution."""

from __future__ import annotations

import asyncio
from copy import deepcopy
from uuid import uuid4

import pytest

from app.core.errors import AppError
from app.services import workflow_actions as module
from app.services.workflow_actions import current_stage


def _definition(transitions=None):
    return {
        "startStage": "DRAFT",
        "stages": [
            {"code": "DRAFT", "statuses": {
                "initial": "READY", "entityStatus": "DRAFT",
                "stageStatuses": [{"code": "READY", "label": {"en": "Ready", "ta": "தயார்"}}],
            }},
            {"code": "MANAGER_APPROVAL", "statuses": {
                "initial": "PENDING", "entityStatus": "UNDER_APPROVAL",
                "stageStatuses": [{"code": "PENDING", "label": {"en": "Pending", "ta": "நிலுவை"}}],
            }},
        ],
        "transitions": transitions or [],
    }


def _button(code, *, stage="DRAFT", event="WITHDRAW", **values):
    return {"from": stage, "to": stage, "on": event, "code": code,
            "label": {"en": code.title(), "ta": "செயல்"}, **values}


def test_current_stage_falls_back_from_instance_to_status_then_start_stage():
    definition = _definition()
    assert current_stage(definition, "UNDER_APPROVAL", {"stage": "DRAFT", "stage_status": "READY"}) == (
        "MANAGER_APPROVAL", "PENDING"
    )
    assert current_stage(definition, "UNMAPPED", {}) == ("DRAFT", "READY")
    assert current_stage(None, "UNMAPPED", {}) == (None, None)


class FakeWorkflow:
    def __init__(self, *, actor=None, state=None, request=None, privileges=None, registry=None):
        self.actor_value = actor or {"user_id": uuid4(), "role_code": "EMP"}
        self.state = state or {"stage": "DRAFT", "stage_status": "READY"}
        self.request = request
        self.privileges = privileges or set()
        self.registry = registry or []
        self.request_calls = []

    async def actor(self):
        return self.actor_value

    async def has_privilege(self, code):
        return code in self.privileges

    async def loan_state(self, _loan_id):
        return self.state

    async def approval_request_state(self, request_id):
        self.request_calls.append(request_id)
        return self.request

    async def list_actions(self, entity, event):
        return self.registry


class FakeRepository:
    def __init__(self, loan, workflow_record):
        self.loan = loan
        self.workflow_record = workflow_record
        self.lock_calls = []

    async def get_application(self, _loan_id, *, lock=False):
        self.lock_calls.append(lock)
        return self.loan

    async def workflow_version(self, _version_id):
        return self.workflow_record


class FakeLoans:
    def __init__(self, repository, workflow, previews=None):
        self.repository = repository
        self.workflow = workflow
        self.failure_log = None
        self.previews = previews or {}
        self.calls = []

    async def preview_rule_checks(self, loan, event, workflow):
        self.calls.append(("preview", event))
        return deepcopy(self.previews.get(event, {
            "blocked": [], "needs_override": False, "routes": [], "warnings": []
        }))

    async def submit_application(self, loan_id, *, code=None):
        self.calls.append(("submit", loan_id, code))
        return {"decision": "SUBMITTED"}

    async def decide(self, request_id, values, *, code=None):
        self.calls.append(("decide", request_id, values, code))
        return {"decision": values["decision"]}

    async def run_transition_by_code(self, loan, workflow, *, code, event, from_stage, input):
        self.calls.append(("transition", loan["id"], code, event, from_stage, input))
        return {"decision": "DONE"}

    async def get_application(self, loan_id):
        self.calls.append(("get_application", loan_id))
        return {**self.repository.loan, "id": loan_id}


def make_service(monkeypatch, *, definition=None, state=None, actor=None, request=None,
                 privileges=None, previews=None, loan_status="DRAFT", row_version=7):
    loan_id, workflow_version_id = uuid4(), uuid4()
    loan = {"id": loan_id, "workflow_version_id": workflow_version_id, "status": loan_status,
            "row_version": row_version, "requested_amount": 1000, "requested_tenure_months": 12}
    workflow_record = {"id": workflow_version_id, "definition": definition or _definition()}
    workflow = FakeWorkflow(actor=actor, state=state, request=request, privileges=privileges)
    repository = FakeRepository(loan, workflow_record)
    loans = FakeLoans(repository, workflow, previews)

    class LoanServiceStub:
        def __init__(self, _conn):
            self.repository = repository
            self.workflow = workflow
            self.failure_log = None

            for name in ("preview_rule_checks", "submit_application", "decide", "run_transition_by_code",
                         "get_application"):
                setattr(self, name, getattr(loans, name))

    monkeypatch.setattr(module, "LoanService", LoanServiceStub)
    service = module.WorkflowActionService(object(), failure_log="failure-log")
    assert service.loans.failure_log == "failure-log"
    return service, loan_id, loans, workflow, repository


def test_list_actions_filters_stage_status_privilege_role_and_duplicates(monkeypatch):
    transitions = [
        _button("WRONG_STAGE", stage="MANAGER_APPROVAL"),
        {"from": "DRAFT", "on": "WITHDRAW"},  # not a button
        _button("WRONG_STATUS", fromStatuses=["OTHER"]),
        _button("NO_PRIVILEGE", actor={"privilege": "loan.create"}),
        _button("WRONG_ROLE", actor={"roles": ["MGR"]}),
        _button("VISIBLE", actor={"roles": ["EMP"]}, style="primary", confirm={"en": "Sure?"},
                input={"type": "object", "properties": {}}),
        _button("VISIBLE", actor={"roles": ["EMP"]}),  # same button is exposed once
    ]
    service, loan_id, loans, _workflow, _repository = make_service(
        monkeypatch, definition=_definition(transitions), privileges=set()
    )

    result = asyncio.run(service.list_actions("loan", loan_id))

    assert result["stage"] == "DRAFT" and result["stage_status"] == "READY"
    assert result["stage_label"]["en"] == "Ready"
    assert [button["code"] for button in result["actions"]] == ["VISIBLE"]
    assert result["actions"][0]["style"] == "primary"
    assert result["actions"][0]["confirm"] == {"en": "Sure?"}
    assert loans.calls == [("preview", "WITHDRAW")]


@pytest.mark.parametrize(
    ("request_data", "actor", "expected_reason"),
    [
        (None, {"user_id": uuid4(), "role_code": "MGR"}, None),
        ({"status": "CLOSED"}, {"user_id": uuid4(), "role_code": "MGR"}, None),
        ({"status": "PENDING", "approver_roles": ["ACC"]},
         {"user_id": uuid4(), "role_code": "MGR"}, None),
        ({"status": "PENDING", "requested_by": "self", "approver_roles": ["MGR"]},
         {"user_id": "self", "role_code": "MGR"}, "SOD_SELF_APPROVAL"),
        ({"status": "PENDING", "requested_by": "other", "approver_roles": ["MGR"],
          "approvals": [{"user_id": "already"}]},
         {"user_id": "already", "role_code": "MGR"}, "APPROVAL_ALREADY_GIVEN"),
    ],
)
def test_approver_button_visibility_and_separation_reasons(monkeypatch, request_data, actor, expected_reason):
    transitions = [_button("DECIDE", event="APPROVE", actor={"approvers": True})]
    state = {"stage": "DRAFT", "stage_status": "READY", "approval_request_id": uuid4()}
    service, loan_id, loans, workflow, _repository = make_service(
        monkeypatch, definition=_definition(transitions), state=state, request=request_data, actor=actor
    )

    result = asyncio.run(service.list_actions("loan", loan_id))

    if expected_reason is None:
        assert result["actions"] == []
    else:
        button = result["actions"][0]
        assert button["enabled"] is False
        assert button["reasons"] == [{"code": expected_reason}]
        assert loans.calls == []  # separation-of-duties blocks preview evaluation
    assert workflow.request_calls == [state["approval_request_id"]]


def test_list_actions_maps_blocking_checks_warnings_routes_and_override(monkeypatch):
    transitions = [_button("SUBMIT", event="SUBMIT")]
    preview = {"blocked": [{"code": "RULE_BLOCKED"}], "needs_override": True,
               "routes": [{"check": "ROUTE", "roles": ["MGR"]}], "warnings": [{"code": "WARN"}]}
    service, loan_id, _loans, _workflow, _repository = make_service(
        monkeypatch, definition=_definition(transitions), previews={"SUBMIT": preview}
    )

    button = asyncio.run(service.list_actions("LOAN", loan_id))["actions"][0]

    assert button["enabled"] is False
    assert button["reasons"] == [{"code": "RULE_BLOCKED"}]
    assert button["warnings"] == [{"code": "WARN"}]
    assert button["routes"] == [{"check": "ROUTE", "roles": ["MGR"]}]
    assert button["needs_override"] is True


def test_record_and_adapter_errors(monkeypatch):
    service, loan_id, _loans, _workflow, repository = make_service(monkeypatch)
    repository.loan = None
    with pytest.raises(AppError) as missing:
        asyncio.run(service.list_actions("loan", loan_id))
    assert missing.value.short_code == "LOAN_NOT_FOUND"
    with pytest.raises(AppError) as unsupported:
        asyncio.run(service.list_actions("member", loan_id))
    assert unsupported.value.short_code == "WORKFLOW_ENTITY_NOT_SUPPORTED"


def test_perform_guards_version_action_availability_and_enabled_state(monkeypatch):
    transition = _button("WITHDRAW", actor={"roles": ["EMP"]},
                         input={"type": "object", "required": ["reason"],
                                "properties": {"reason": {"type": "string", "x-field": "text"}}})
    service, loan_id, _loans, _workflow, repository = make_service(
        monkeypatch, definition=_definition([transition])
    )

    with pytest.raises(AppError) as required_version:
        asyncio.run(service.perform("loan", loan_id, "WITHDRAW", {}, None))
    assert required_version.value.short_code == "ROW_VERSION_REQUIRED"
    with pytest.raises(AppError) as stale:
        asyncio.run(service.perform("loan", loan_id, "WITHDRAW", {"reason": "ok"}, 6))
    assert stale.value.short_code == "STALE_RECORD"
    with pytest.raises(AppError) as unavailable:
        asyncio.run(service.perform("loan", loan_id, "UNKNOWN", {}, 7))
    assert unavailable.value.short_code == "WORKFLOW_ACTION_NOT_AVAILABLE"
    with pytest.raises(AppError) as invalid_input:
        asyncio.run(service.perform("loan", loan_id, "WITHDRAW", {}, 7))
    assert invalid_input.value.short_code == "WORKFLOW_INPUT_INVALID"
    assert repository.lock_calls == [True, True, True]

    blocked, _, _, _, _ = make_service(
        monkeypatch, definition=_definition([transition]),
        previews={"WITHDRAW": {"blocked": [{"code": "RULE_BLOCKED"}], "needs_override": False,
                               "routes": [], "warnings": []}},
    )
    with pytest.raises(AppError) as disabled:
        asyncio.run(blocked.perform("loan", loan_id, "WITHDRAW", {"reason": "ok"}, 7))
    assert disabled.value.short_code == "WORKFLOW_ACTION_NOT_AVAILABLE"
    assert disabled.value.details["reasons"] == [{"code": "RULE_BLOCKED"}]


@pytest.mark.parametrize("event, expected_decision", [("APPROVE", "APPROVED"), ("REJECT", "REJECTED"),
                                                        ("RETURN", "RETURNED")])
def test_perform_decision_events_map_and_forward_validated_form_input(monkeypatch, event, expected_decision):
    transition = _button(event, event=event, actor={"approvers": True},
                         input={"type": "object", "properties": {
                             "reason": {"type": "string", "x-field": "text"}}})
    state = {"stage": "DRAFT", "stage_status": "READY", "approval_request_id": uuid4()}
    request = {"status": "PENDING", "requested_by": "other", "approver_roles": ["EMP"]}
    service, loan_id, loans, _workflow, repository = make_service(
        monkeypatch, definition=_definition([transition]), state=state, request=request,
    )

    result = asyncio.run(service.perform("loan", loan_id, event, {"reason": " reviewed "}, 7))

    assert result["result"]["decision"] == expected_decision
    assert ("decide", state["approval_request_id"],
            {"decision": expected_decision, "reason": "reviewed"}, event) in loans.calls
    assert repository.lock_calls[0] is True
    assert loans.calls[-1] == ("get_application", loan_id)


@pytest.mark.parametrize("event", ["SUBMIT", "WITHDRAW"])
def test_perform_submit_and_generic_transition_paths(monkeypatch, event):
    transition = _button(event, event=event, actor={"roles": ["EMP"]},
                         input={"type": "object", "properties": {
                             "reason": {"type": "string", "x-field": "text"}}})
    service, loan_id, loans, _workflow, _repository = make_service(
        monkeypatch, definition=_definition([transition])
    )

    result = asyncio.run(service.perform("loan", loan_id, event, {"reason": " ok "}, 7))

    assert result["result"]["decision"] in {"SUBMITTED", "DONE"}
    if event == "SUBMIT":
        assert ("submit", loan_id, event) in loans.calls
    else:
        assert ("transition", loan_id, event, event, "DRAFT", {"reason": "ok"}) in loans.calls


def test_registry_passes_filters_to_repository(monkeypatch):
    service, _loan_id, _loans, workflow, _repository = make_service(monkeypatch)
    workflow.registry = [{"code": "SEND_NOTIFICATION"}]

    result = asyncio.run(service.registry("LOAN", "onTransition"))

    assert result == [{"code": "SEND_NOTIFICATION"}]
