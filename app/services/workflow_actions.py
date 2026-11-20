"""Workflow buttons: the transitions of a record's current stage that the
current user can use now, and running one by its code.

Everything about a button comes from the workflow JSON of the record's
workflow version: label, style, confirm text, actor (privilege, roles,
approvers of the open request), the stage statuses it is offered in, its
input form, rule checks, ordered actions and the statuses it sets. A new
workflow version that adds, renames or removes a transition changes the
buttons with no code or API change.

v1 supports loan applications (entity type "loan").
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.services.loans import DECISION_EVENTS, LoanService
from app.workflow.engine import stage_of
from app.workflow.forms import validate_input

EVENT_DECISIONS = {event: decision for decision, event in DECISION_EVENTS.items()}


def current_stage(definition: dict[str, Any] | None, entity_status: str, state: dict[str, Any]) -> tuple[str | None, str | None]:
    """The record's stage and stage status: the workflow instance's stage when
    its declared entity status matches the record (or no stage declares the
    record's status, e.g. RETURNED is the DRAFT stage), else the stage that
    declares the record's status, else the start stage."""
    stages = (definition or {}).get("stages") or []
    declaring = [s["code"] for s in stages if (s.get("statuses") or {}).get("entityStatus") == entity_status]
    instance_stage = state.get("stage")
    if instance_stage and (instance_stage in declaring or not declaring):
        stage = instance_stage
    elif declaring:
        stage = declaring[0]
    else:
        stage = (definition or {}).get("startStage")
    if stage == instance_stage and state.get("stage_status"):
        return stage, state["stage_status"]
    return stage, (stage_of(definition, stage).get("statuses") or {}).get("initial")


class WorkflowActionService:
    def __init__(self, conn: AsyncConnection, failure_log=None) -> None:
        self.loans = LoanService(conn)
        self.loans.failure_log = failure_log
        self.workflow = self.loans.workflow

    def _adapter(self, entity_type: str) -> None:
        if entity_type.lower() != "loan":
            raise AppError("WORKFLOW_ENTITY_NOT_SUPPORTED", params={"entity": entity_type})

    async def _record(self, loan_id: UUID, *, lock: bool = False) -> dict[str, Any]:
        loan = await self.loans.repository.get_application(loan_id, lock=lock)
        if loan is None:
            raise AppError("LOAN_NOT_FOUND")
        state = await self.workflow.loan_state(loan_id)
        workflow = await self.loans.repository.workflow_version(loan["workflow_version_id"])
        definition = (workflow or {}).get("definition")
        stage, stage_status = current_stage(definition, loan["status"], state)
        return {"loan": loan, "state": state, "workflow": workflow, "definition": definition,
                "stage": stage, "stage_status": stage_status}

    async def list_actions(self, entity_type: str, entity_id: UUID) -> dict[str, Any]:
        self._adapter(entity_type)
        record = await self._record(entity_id)
        return {"entity_type": "loan", "entity_id": entity_id, "status": record["loan"]["status"],
                "stage": record["stage"], "stage_status": record["stage_status"],
                "stage_label": self._stage_label(record), "row_version": record["loan"]["row_version"],
                "actions": await self._buttons(record)}

    @staticmethod
    def _stage_label(record: dict[str, Any]) -> dict[str, Any] | None:
        statuses = (stage_of(record["definition"], record["stage"]).get("statuses") or {}).get("stageStatuses") or []
        return next((s.get("label") for s in statuses if s.get("code") == record["stage_status"]), None)

    async def _buttons(self, record: dict[str, Any]) -> list[dict[str, Any]]:
        actor = await self.workflow.actor()
        request: dict[str, Any] | None = None
        if record["state"].get("approval_request_id"):
            request = await self.workflow.approval_request_state(record["state"]["approval_request_id"])
        buttons: list[dict[str, Any]] = []
        seen: set[str] = set()
        for transition in (record["definition"] or {}).get("transitions") or []:
            if transition.get("from") != record["stage"] or "label" not in transition:
                continue
            code = transition.get("code") or transition["on"]
            if code in seen:
                continue
            seen.add(code)
            from_statuses = transition.get("fromStatuses")
            if from_statuses and record["stage_status"] not in from_statuses:
                continue
            spec = transition.get("actor") or {}
            if spec.get("privilege") and not await self.workflow.has_privilege(spec["privilege"]):
                continue
            if spec.get("roles") and actor.get("role_code") not in spec["roles"]:
                continue
            reasons: list[dict[str, Any]] = []
            if spec.get("approvers"):
                if not request or request.get("status") != "PENDING":
                    continue
                if request.get("approver_roles") and actor.get("role_code") not in request["approver_roles"]:
                    continue
                if str(request.get("requested_by")) == str(actor.get("user_id")):
                    reasons.append({"code": "SOD_SELF_APPROVAL"})
                elif any(str(a.get("user_id")) == str(actor.get("user_id")) for a in request.get("approvals") or []):
                    reasons.append({"code": "APPROVAL_ALREADY_GIVEN"})
            preview = await self.loans.preview_rule_checks(record["loan"], transition["on"], record["workflow"]) \
                if not reasons else {"blocked": [], "needs_override": False, "routes": [], "warnings": []}
            reasons.extend(preview["blocked"])
            buttons.append({
                "code": code, "event": transition["on"], "to_stage": transition.get("to"),
                "label": transition["label"], "style": transition.get("style", "secondary"),
                "confirm": transition.get("confirm"), "input": transition.get("input"),
                "enabled": not reasons, "reasons": reasons, "warnings": preview["warnings"],
                "needs_override": preview["needs_override"], "routes": preview["routes"],
            })
        return buttons

    async def perform(self, entity_type: str, entity_id: UUID, code: str, input: dict[str, Any] | None,
                      expected_version: int | None) -> dict[str, Any]:
        self._adapter(entity_type)
        if expected_version is None:
            raise AppError("ROW_VERSION_REQUIRED")
        record = await self._record(entity_id, lock=True)
        loan = record["loan"]
        if loan["row_version"] != expected_version:
            raise AppError("STALE_RECORD")
        button = next((b for b in await self._buttons(record) if b["code"] == code), None)
        if button is None:
            raise AppError("WORKFLOW_ACTION_NOT_AVAILABLE", params={"action": code})
        if not button["enabled"]:
            raise AppError("WORKFLOW_ACTION_NOT_AVAILABLE", params={"action": code},
                           details={"reasons": button["reasons"]})
        values = validate_input(button["input"], input, loan)
        event = button["event"]
        if event == "SUBMIT":
            result = await self.loans.submit_application(entity_id, code=code)
        elif event in EVENT_DECISIONS:
            decision = {"decision": EVENT_DECISIONS[event], **values}
            result = await self.loans.decide(record["state"]["approval_request_id"], decision, code=code)
        else:
            result = await self.loans.run_transition_by_code(loan, record["workflow"], code=code, event=event,
                                                             from_stage=record["stage"], input=values)
        refreshed = await self.list_actions(entity_type, entity_id)
        return {"result": result, "record": await self.loans.get_application(entity_id), "actions": refreshed}

    # -- Super Admin: the action registry -------------------------------------
    async def registry(self, entity: str | None, event: str | None) -> list[dict[str, Any]]:
        return await self.workflow.list_actions(entity, event)
