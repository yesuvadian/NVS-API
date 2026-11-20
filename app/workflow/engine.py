"""Workflow engine: stage -> rule checks -> actions, run as one transition.

All configuration lives in the versioned workflow JSON (cfg.workflow_version
.definition). A transition ({"from", "to", "on", "code", "ruleChecks",
"actions"}) is run by ``WorkflowEngine.run_transition``:

1. the transition's rule checks are evaluated by the caller-supplied
   evaluator (BLOCK / REQUIRE_OVERRIDE raise or record inside it; WARN never
   blocks; ROUTE_TO_ROLE failures are returned as routes);
2. its actions run in ``seq`` order, each through the action registry
   (app/workflow/actions: code -> WorkflowAction subclass). ``onError`` per
   action:
     ROLLBACK (default)  the error ends the transition and the caller's
                         transaction undoes everything, earlier actions and
                         statuses included; the failure is reported to the
                         optional ``failure_log`` (written outside the
                         transaction, so failed attempts stay visible);
     CONTINUE            the action runs in a savepoint; its error is undone
                         and logged as a FAILED step and the rest goes on;
     DEFER               not run now: queued in the outbox (a PENDING
                         wf.action_execution with its params) and run later
                         by ``process_deferred``; only for deferrable actions;
3. ROUTE_TO_ROLE routes are applied to the open approval request;
4. statuses (SET_STATUS): the stage status the transition records, the
   target stage and its initial stage status, and the entity status the
   target stage (or the transition) declares; a partial approval or a
   routing records the stage's "onPartialApproval" / "onRouted" status and
   stays in the stage; a transition to its own stage records its
   "stageStatus". Nothing about statuses is coded here;
5. one wf.action_execution row is written per step, in order (RULE_CHECKS
   first), keyed on the workflow instance.

Workflow versions written before actions were configurable carry no
"actions"; for them the caller passes ``default_actions`` that reproduce the
earlier behaviour exactly.
"""

from __future__ import annotations

import json
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Protocol
from uuid import UUID, uuid4

from app.core.errors import AppError
from app.workflow.actions import ActionResult, WorkflowAction, discover

ON_ERROR = ("ROLLBACK", "CONTINUE", "DEFER")


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
    services: dict[str, Any] = field(default_factory=dict)
    code: str | None = None                      # button / transition code, when chosen by code
    entity_type: str = "LOAN"


RuleEvaluator = Callable[[TransitionContext], Awaitable[dict[str, Any]]]
# Reads the entity's current status and workflow instance after the actions.
EntityState = Callable[[TransitionContext], Awaitable[dict[str, Any]]]
# Applies {"entity_status", "stage", "stage_status"}; returns the change made.
StatusApplier = Callable[[TransitionContext, dict[str, Any]], Awaitable[dict[str, Any]]]
# Records a failed ROLLBACK action outside the transaction.
FailureLog = Callable[[dict[str, Any]], Awaitable[None]]

# Results of an action that leave the transition pending in its stage, and
# the stage "statuses" key naming the stage status each one records.
PENDING_RESULTS = {"APPROVAL_RECORDED": "onPartialApproval", "ROUTED": "onRouted"}


class ExecutionLog(Protocol):
    async def record_executions(self, workflow_instance_id: UUID, rows: list[dict[str, Any]]) -> None: ...

    async def route_approval_request(self, request_id: UUID, roles: list[str], check: str) -> None: ...

    def savepoint(self) -> AbstractAsyncContextManager: ...


def registry() -> dict[str, type[WorkflowAction]]:
    return discover()


def transitions_for(definition: dict[str, Any] | None, event: str, from_stage: str | None = None,
                    code: str | None = None) -> list[dict[str, Any]]:
    """Transitions of a workflow document for an event (or a button code) and
    source stage."""
    transitions = (definition or {}).get("transitions") or []
    if code is not None:
        found = [t for t in transitions if (t.get("code") or t.get("on")) == code]
    else:
        found = [t for t in transitions if t.get("on") == event]
    if from_stage is not None:
        exact = [t for t in found if t.get("from") == from_stage]
        # A configured stage is an authorization boundary. Falling back to a
        # same-event transition from a different stage would let users skip
        # workflow gates when the current stage has no such action.
        found = exact
    return found


def normalise_action(entry: Any, index: int) -> dict[str, Any]:
    if isinstance(entry, str):
        entry = {"code": entry}
    return {"seq": entry.get("seq", index), "code": entry.get("code") or entry.get("action"),
            "params": entry.get("params") or {}, "onError": entry.get("onError") or "ROLLBACK"}


def _condition_value(context: dict[str, Any], field: str) -> tuple[bool, Any]:
    if field in context:
        return True, context[field]
    value: Any = context
    for part in field.split("."):
        if not isinstance(value, dict) or part not in value:
            return False, None
        value = value[part]
    return True, value


def transition_matches_when(when: dict[str, Any] | None, context: dict[str, Any]) -> bool:
    """Evaluate the workflow condition subset used to select a transition.

    Conditions use ``all`` / ``any`` collections of field/operator/value
    expressions. Unknown fields or operators fail closed.
    """
    if not when:
        return True

    def matches(expression: dict[str, Any]) -> bool:
        if not isinstance(expression, dict) or not isinstance(expression.get("field"), str):
            return False
        present, actual = _condition_value(context, expression["field"])
        op, expected = expression.get("op"), expression.get("value")
        if op == "exists":
            return present and (actual is not None) == bool(expected)
        if not present:
            return False
        try:
            if op == "eq": return actual == expected
            if op == "ne": return actual != expected
            if op == "in": return actual in expected
            if op == "not_in": return actual not in expected
            if op == "gt": return actual > expected
            if op == "gte": return actual >= expected
            if op == "lt": return actual < expected
            if op == "lte": return actual <= expected
        except (TypeError, ValueError):
            return False
        return False

    groups = []
    for key, reducer in (("all", all), ("any", any)):
        if key in when:
            expressions = when[key]
            if not isinstance(expressions, list):
                return False
            groups.append(reducer(matches(item) for item in expressions))
    return all(groups) if groups else False


def transition_actions(definition: dict[str, Any] | None, event: str, from_stage: str | None = None,
                       code: str | None = None,
                       condition_context: dict[str, Any] | None = None) -> list[dict[str, Any]] | None:
    """Configured actions of the transition, in seq order, preserving repeats;
    None when the document predates configurable actions."""
    transitions = (definition or {}).get("transitions") or []
    if not any("actions" in t for t in transitions):
        return None
    actions: list[dict[str, Any]] = []
    position = 0
    candidates = transitions_for(definition, event, from_stage, code)
    if len(candidates) > 1 and any("when" in transition for transition in candidates):
        candidates = [transition for transition in candidates
                      if transition_matches_when(transition.get("when"), condition_context or {})]
        if not candidates:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED", details={
                "event": event, "code": code, "reason": "no transition condition matched"
            })
    for transition in candidates:
        for index, entry in enumerate(transition.get("actions") or [], start=1):
            action = normalise_action(entry, index)
            if action["code"]:
                position += 1
                actions.append({**action, "_position": position})
    return [
        {key: value for key, value in action.items() if key != "_position"}
        for action in sorted(actions, key=lambda a: (a["seq"], a["_position"]))
    ]


def stage_actions(definition: dict[str, Any] | None, stage_code: str | None, event: str) -> list[dict[str, Any]]:
    """Configured stage hooks, sorted by sequence; defaults to onEnter."""
    stage = stage_of(definition, stage_code)
    entries = []
    for index, raw in enumerate(stage.get("actions") or [], start=1):
        # Legacy stage actions (the ``action``/``type`` records in older
        # templates) are executed by their composite SQL operations. Only the
        # new stage-hook contract (``code`` with optional event) is dispatched
        # by IStageAction.
        if not isinstance(raw, dict) or "code" not in raw:
            continue
        action = normalise_action(raw, index)
        hook = raw.get("event", raw.get("on", "onEnter"))
        if hook == event and action["code"]:
            entries.append(action)
    return sorted(entries, key=lambda action: action["seq"])


def stage_of(definition: dict[str, Any] | None, code: str | None) -> dict[str, Any]:
    for stage in (definition or {}).get("stages") or []:
        if stage.get("code") == code:
            return stage
    return {}


def has_statuses(definition: dict[str, Any] | None) -> bool:
    return any("statuses" in s for s in (definition or {}).get("stages") or [])


def status_change(
    definition: dict[str, Any] | None, event: str, from_stage: str | None,
    result: Any, entity_status: str | None, reached_stage: str | None = None, code: str | None = None,
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
    candidates = transitions_for(definition, event, from_stage, code)
    if not candidates:
        return None
    chosen = (next((t for t in candidates if reached_stage and t.get("to") == reached_stage), None)
              or next((t for t in candidates
                       if (stage_of(definition, t.get("to")).get("statuses") or {}).get("entityStatus") == entity_status),
                      candidates[0]))
    if chosen.get("to") == from_stage:
        # stays in its stage: the transition's own stage status
        return {"from_stage": from_stage, "recorded": chosen.get("stageStatus"), "stage": from_stage,
                "stage_status": chosen.get("stageStatus"), "entity_status": chosen.get("entityStatus")}
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
    def __init__(self, log: ExecutionLog, actions: dict[str, type[WorkflowAction]] | None = None,
                 failure_log: FailureLog | None = None):
        self.log = log
        self.actions = actions if actions is not None else registry()
        self.failure_log = failure_log

    def action(self, code: str) -> WorkflowAction:
        cls = self.actions.get(code)
        if cls is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED", details={"action": code})
        return cls()

    async def _execute_entries(self, ctx: TransitionContext, actions: list[dict[str, Any]],
                               stage_code: str | None = None) -> list[dict[str, Any]]:
        steps: list[dict[str, Any]] = []
        for entry in actions:
            code, on_error = entry["code"], entry["onError"]
            action = self.action(code)
            if on_error == "DEFER":
                if not action.deferrable:
                    raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED", details={"action": code, "onError": on_error})
                steps.append({"action_code": code, "status": "PENDING", "params": entry["params"],
                              "on_error": on_error, "result": None, "stage_code": stage_code})
                continue
            try:
                if on_error == "CONTINUE":
                    async with self.log.savepoint():
                        result = await action.execute(ctx, entry["params"])
                else:
                    result = await action.execute(ctx, entry["params"])
            except Exception as exc:
                if on_error == "CONTINUE":
                    steps.append({"action_code": code, "status": "FAILED", "on_error": on_error,
                                  "params": entry["params"], "error": _error(exc), "result": None,
                                  "stage_code": stage_code})
                    continue
                if self.failure_log is not None:
                    await self.failure_log({"action_code": code, "event": ctx.event, "error": _error(exc),
                                            "entity_type": ctx.entity_type, "entity_id": ctx.entity.get("id"),
                                            "business_ref": ctx.entity.get("loan_no"),
                                            "workflow_instance_id": ctx.workflow_instance_id
                                            or ctx.entity.get("workflow_instance_id")})
                raise
            result = result if isinstance(result, ActionResult) else ActionResult(data=result)
            ctx.results[code] = result.data
            steps.append({"action_code": code, "status": result.status if result.status != "PENDING" else "SUCCESS",
                          "on_error": on_error, "params": entry["params"],
                          "result": _jsonable(result.as_dict()), "stage_code": stage_code})
        return steps

    async def run_stage_event(self, ctx: TransitionContext, stage_code: str, event: str) -> TransitionContext:
        """Run and audit a stage hook, including the workflow's initial stage."""
        steps = await self._execute_entries(ctx, stage_actions(ctx.definition, stage_code, event), stage_code)
        instance = ctx.workflow_instance_id or ctx.entity.get("workflow_instance_id")
        if steps and instance is not None:
            await self.log.record_executions(instance, [
                {**step, "seq": seq, "stage_code": stage_code, "entity_type": ctx.entity_type,
                 "entity_id": ctx.entity.get("id"),
                 "idempotency_key": f"{instance}:{event}:{step['action_code']}:{uuid4()}"}
                for seq, step in enumerate(steps, start=1)
            ])
        return ctx

    async def run_transition(
        self, ctx: TransitionContext, *, evaluate_rules: RuleEvaluator,
        default_actions: list[str], from_stage: str | None = None,
        entity_state: EntityState | None = None, apply_status: StatusApplier | None = None,
    ) -> TransitionContext:
        steps: list[dict[str, Any]] = []

        outcome = await evaluate_rules(ctx)
        ctx.routes = list(outcome.get("routes") or [])
        steps.append({"action_code": "RULE_CHECKS", "status": "SUCCESS", "result": _jsonable(outcome)})

        configured = transition_actions(ctx.definition, ctx.event, from_stage, ctx.code,
                                        ctx.params.get("condition_context") or ctx.entity)
        actions = configured if configured is not None else [
            normalise_action(code, index) for index, code in enumerate(default_actions, start=1)]
        steps.extend(await self._execute_entries(ctx, actions, from_stage))
        last = ctx.results.get(actions[-1]["code"]) if actions else None

        request_id = ctx.results.get("approval_request_id") or ctx.entity.get("approval_request_id")
        for route in ctx.routes:
            if request_id is None:
                raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED", details={"route": route, "event": ctx.event})
            await self.log.route_approval_request(request_id, route["roles"], route["check"])

        state = await entity_state(ctx) if entity_state else {}
        if state.get("workflow_instance_id") and ctx.workflow_instance_id is None:
            ctx.workflow_instance_id = state["workflow_instance_id"]
        reached_stage = ctx.params.get("target_stage") or state.get("stage")
        change = status_change(ctx.definition, ctx.event, from_stage, last, state.get("status"),
                               reached_stage, ctx.code)
        if change:
            target_stage = change.get("stage")
            if target_stage and target_stage != from_stage:
                steps.extend(await self._execute_entries(
                    ctx, stage_actions(ctx.definition, from_stage, "onExit"), from_stage))
            if apply_status:
                applied = await apply_status(ctx, change)
                ctx.results["SET_STATUS"] = {**change, "applied": applied}
                steps.append({"action_code": "SET_STATUS", "status": "SUCCESS",
                              "result": _jsonable(ctx.results["SET_STATUS"]),
                              # This execution belongs to the transition's
                              # source stage; the result records the target.
                              "stage_code": from_stage})
            if target_stage and target_stage != from_stage:
                steps.extend(await self._execute_entries(
                    ctx, stage_actions(ctx.definition, target_stage, "onEnter"), target_stage))

        instance = ctx.workflow_instance_id or ctx.entity.get("workflow_instance_id")
        if instance is not None:
            await self.log.record_executions(instance, [
                {**step, "seq": seq, "stage_code": step.get("stage_code") or from_stage or ctx.entity.get("status") or ctx.event,
                 "entity_type": ctx.entity_type, "entity_id": ctx.entity.get("id"),
                 "idempotency_key": f"{instance}:{ctx.event}:{step['action_code']}:{uuid4()}"}
                for seq, step in enumerate(steps, start=1)])
        elif any(step["status"] == "PENDING" for step in steps):
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED", details={"defer": "no workflow instance to queue on"})
        return ctx


def _error(exc: Exception) -> dict[str, Any]:
    if isinstance(exc, AppError):
        return {"code": exc.short_code, "params": exc.params}
    hint = getattr(getattr(exc, "diag", None), "message_hint", None)
    primary = getattr(getattr(exc, "diag", None), "message_primary", None)
    return {"code": hint or type(exc).__name__, "message": primary or str(exc)[:500]}


def _jsonable(value: Any) -> Any:
    return json.loads(json.dumps(value, default=str)) if value is not None else None
