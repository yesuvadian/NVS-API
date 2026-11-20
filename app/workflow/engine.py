"""Workflow engine: stage -> rule checks -> actions, run as one transition.

All configuration lives in the versioned workflow JSON (cfg.workflow_version
.definition). A transition ({"from", "to", "on", "ruleChecks", "actions"})
is run by ``WorkflowEngine.run_transition``:

1. the transition's rule checks are evaluated by the caller-supplied
   evaluator (BLOCK / REQUIRE_OVERRIDE raise or record inside it; WARN never
   blocks; ROUTE_TO_ROLE failures are returned as routes);
2. each configured action runs through its registered handler, in order;
3. ROUTE_TO_ROLE routes are applied to the open approval request;
4. statuses (SET_STATUS): the stage status the transition records, the
   target stage and its initial stage status, and the entity status the
   target stage (or the transition) declares; a partial approval or a
   routing records the stage's "onPartialApproval" / "onRouted" status and
   stays in the stage. Nothing about statuses is coded here: all of it is
   in the stage's "statuses" and the transition's "stageStatus" /
   "entityStatus";
5. one wf.action_execution row is written per step (RULE_CHECKS first),
   keyed on the workflow instance.

Everything happens on the caller's connection and transaction, so a failing
step rolls the whole transition back (and its log with it): either the
transition completed with all its actions or nothing changed.

Workflow versions written before actions were configurable carry no
"actions"; for them the caller passes ``default_actions`` that reproduce the
earlier behaviour exactly.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Protocol
from uuid import UUID, uuid4

from app.core.errors import AppError


@dataclass
class TransitionContext:
    """What a transition is acting on, and what its steps produced."""

    event: str
    entity: dict[str, Any]
    definition: dict[str, Any] | None
    params: dict[str, Any] = field(default_factory=dict)
    results: dict[str, Any] = field(default_factory=dict)
    routes: list[dict[str, Any]] = field(default_factory=list)
    workflow_instance_id: UUID | None = None


ActionHandler = Callable[[TransitionContext, dict[str, Any]], Awaitable[Any]]
RuleEvaluator = Callable[[TransitionContext], Awaitable[dict[str, Any]]]
# Reads the entity's current status and workflow instance after the actions.
EntityState = Callable[[TransitionContext], Awaitable[dict[str, Any]]]
# Applies {"entity_status", "stage", "stage_status"}; returns the change made.
StatusApplier = Callable[[TransitionContext, dict[str, Any]], Awaitable[dict[str, Any]]]

# Results of an action that leave the transition pending in its stage, and
# the stage "statuses" key naming the stage status each one records.
PENDING_RESULTS = {"APPROVAL_RECORDED": "onPartialApproval", "ROUTED": "onRouted"}


class ExecutionLog(Protocol):
    async def record_executions(self, workflow_instance_id: UUID, rows: list[dict[str, Any]]) -> None: ...

    async def route_approval_request(self, request_id: UUID, roles: list[str], check: str) -> None: ...


def transitions_for(definition: dict[str, Any] | None, event: str, from_stage: str | None = None) -> list[dict[str, Any]]:
    """Transitions of a workflow document for an event (and source stage)."""
    found = [t for t in (definition or {}).get("transitions") or [] if t.get("on") == event]
    if from_stage is not None:
        exact = [t for t in found if t.get("from") == from_stage]
        found = exact or found
    return found


def transition_actions(definition: dict[str, Any] | None, event: str, from_stage: str | None = None) -> list[dict[str, Any]] | None:
    """Configured actions of the event's transitions, in order, each once;
    None when the document predates configurable actions."""
    transitions = (definition or {}).get("transitions") or []
    if not any("actions" in t for t in transitions):
        return None
    actions: list[dict[str, Any]] = []
    seen: set[str] = set()
    for transition in transitions_for(definition, event, from_stage):
        for entry in transition.get("actions") or []:
            code = entry.get("action") if isinstance(entry, dict) else entry
            if code and code not in seen:
                seen.add(code)
                actions.append({"action": code, "params": (entry.get("params") if isinstance(entry, dict) else None) or {}})
    return actions


def stage_of(definition: dict[str, Any] | None, code: str | None) -> dict[str, Any]:
    for stage in (definition or {}).get("stages") or []:
        if stage.get("code") == code:
            return stage
    return {}


def has_statuses(definition: dict[str, Any] | None) -> bool:
    return any("statuses" in s for s in (definition or {}).get("stages") or [])


def status_change(
    definition: dict[str, Any] | None, event: str, from_stage: str | None,
    result: Any, entity_status: str | None, reached_stage: str | None = None,
) -> dict[str, Any] | None:
    """Statuses a completed (or pending) transition sets, from the JSON only.
    When several transitions share the event (e.g. SUBMIT to fee or approval),
    the one whose target is the stage the action reached wins, else the one
    whose target stage declares the entity's current status."""
    if not has_statuses(definition):
        return None
    pending = PENDING_RESULTS.get(result.get("decision")) if isinstance(result, dict) else None
    source = stage_of(definition, from_stage)
    if pending:
        status = (source.get("statuses") or {}).get(pending)
        return {"stage": from_stage, "stage_status": status, "entity_status": None,
                "recorded": status, "pending": result.get("decision")} if status else None
    candidates = transitions_for(definition, event, from_stage)
    if not candidates:
        return None
    chosen = (next((t for t in candidates if reached_stage and t.get("to") == reached_stage), None)
              or next((t for t in candidates
                       if (stage_of(definition, t.get("to")).get("statuses") or {}).get("entityStatus") == entity_status),
                      candidates[0]))
    target = stage_of(definition, chosen.get("to"))
    target_statuses = target.get("statuses") or {}
    return {"from_stage": from_stage, "recorded": chosen.get("stageStatus"),
            "stage": chosen.get("to"), "stage_status": target_statuses.get("initial"),
            "entity_status": chosen.get("entityStatus") or target_statuses.get("entityStatus")}


def route_rules(definition: dict[str, Any] | None, event: str) -> dict[str, list[str]]:
    """ROUTE_TO_ROLE rule checks of an event: code -> roles."""
    routes: dict[str, list[str]] = {}
    for transition in transitions_for(definition, event):
        for entry in transition.get("ruleChecks") or []:
            if isinstance(entry, dict) and entry.get("onFail") == "ROUTE_TO_ROLE":
                routes.setdefault(entry["code"], list(entry.get("roles") or []))
    return routes


class WorkflowEngine:
    def __init__(self, log: ExecutionLog, handlers: dict[str, ActionHandler]):
        self.log = log
        self.handlers = handlers

    async def run_transition(
        self, ctx: TransitionContext, *, evaluate_rules: RuleEvaluator,
        default_actions: list[str], from_stage: str | None = None,
        entity_state: EntityState | None = None, apply_status: StatusApplier | None = None,
    ) -> TransitionContext:
        steps: list[dict[str, Any]] = []

        outcome = await evaluate_rules(ctx)
        ctx.routes = list(outcome.get("routes") or [])
        steps.append({"action_code": "RULE_CHECKS", "result": _jsonable(outcome)})

        configured = transition_actions(ctx.definition, ctx.event, from_stage)
        actions = configured if configured is not None else [{"action": a, "params": {}} for a in default_actions]
        for entry in actions:
            handler = self.handlers.get(entry["action"])
            if handler is None:
                raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED",
                               details={"action": entry["action"], "event": ctx.event})
            result = await handler(ctx, entry["params"])
            ctx.results[entry["action"]] = result
            steps.append({"action_code": entry["action"], "result": _jsonable(result)})

        request_id = ctx.results.get("approval_request_id") or ctx.entity.get("approval_request_id")
        for route in ctx.routes:
            if request_id is None:
                raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED", details={"route": route, "event": ctx.event})
            await self.log.route_approval_request(request_id, route["roles"], route["check"])

        state = await entity_state(ctx) if entity_state else {}
        if state.get("workflow_instance_id") and ctx.workflow_instance_id is None:
            ctx.workflow_instance_id = state["workflow_instance_id"]
        last = ctx.results[actions[-1]["action"]] if actions else None
        change = status_change(ctx.definition, ctx.event, from_stage, last, state.get("status"), state.get("stage"))
        if change and apply_status:
            applied = await apply_status(ctx, change)
            ctx.results["SET_STATUS"] = {**change, "applied": applied}
            steps.append({"action_code": "SET_STATUS", "result": _jsonable(ctx.results["SET_STATUS"])})

        instance = ctx.workflow_instance_id or ctx.entity.get("workflow_instance_id")
        if instance is not None:
            await self.log.record_executions(instance, [
                {**step, "seq": seq, "stage_code": from_stage or ctx.entity.get("status") or ctx.event,
                 "idempotency_key": f"{instance}:{ctx.event}:{step['action_code']}:{uuid4()}"}
                for seq, step in enumerate(steps, start=1)])
        return ctx


def _jsonable(value: Any) -> Any:
    return json.loads(json.dumps(value, default=str)) if value is not None else None
