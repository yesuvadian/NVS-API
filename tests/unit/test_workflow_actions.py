from contextlib import asynccontextmanager
from uuid import uuid4

import pytest

from app.core.errors import AppError
from app.workflow.actions import ActionResult
from app.workflow.engine import TransitionContext, WorkflowEngine, stage_actions, transition_actions
from app.workflow.forms import validate_input


def test_transition_actions_execute_in_seq_order_and_preserve_repeated_codes():
    definition = {
        "transitions": [
            {
                "from": "DRAFT",
                "on": "SUBMIT",
                "code": "SUBMIT",
                "actions": [
                    {"seq": 20, "code": "TEST_SEQUENCE_A"},
                    {"seq": 10, "code": "TEST_SEQUENCE_B"},
                    {"seq": 30, "code": "TEST_SEQUENCE_A"},
                ],
            }
        ]
    }
    assert [row["code"] for row in transition_actions(definition, "SUBMIT", "DRAFT", "SUBMIT")] == [
        "TEST_SEQUENCE_B",
        "TEST_SEQUENCE_A",
        "TEST_SEQUENCE_A",
    ]

    order = []

    class StepA:
        code = "TEST_SEQUENCE_A"

        async def execute(self, ctx, params):
            order.append(self.code)
            return ActionResult(data={"step": self.code})

    class StepB:
        code = "TEST_SEQUENCE_B"

        async def execute(self, ctx, params):
            order.append(self.code)
            return ActionResult(data={"step": self.code})

    class Log:
        rows = None

        async def record_executions(self, _instance_id, rows):
            self.rows = rows

        async def route_approval_request(self, *_args):
            raise AssertionError("No rules should route in this test")

        @asynccontextmanager
        async def savepoint(self):
            yield

    instance_id = uuid4()
    log = Log()
    engine = WorkflowEngine(log, {StepA.code: StepA, StepB.code: StepB})

    async def evaluate(_ctx):
        return {"routes": []}

    async def state(_ctx):
        return {"workflow_instance_id": instance_id}

    import asyncio

    asyncio.run(
        engine.run_transition(
            TransitionContext("SUBMIT", {"id": uuid4(), "workflow_instance_id": instance_id}, definition,
                              code="SUBMIT"),
            evaluate_rules=evaluate,
            default_actions=[],
            from_stage="DRAFT",
            entity_state=state,
        )
    )

    assert order == ["TEST_SEQUENCE_B", "TEST_SEQUENCE_A", "TEST_SEQUENCE_A"]
    assert [(row["seq"], row["action_code"]) for row in log.rows] == [
        (1, "RULE_CHECKS"),
        (2, "TEST_SEQUENCE_B"),
        (3, "TEST_SEQUENCE_A"),
        (4, "TEST_SEQUENCE_A"),
    ]


def test_initial_stage_hooks_run_in_sequence_and_ignore_legacy_composite_steps():
    definition = {"stages": [{"code": "INIT", "actions": [
        {"seq": 2, "code": "STAGE_B", "event": "onEnter"},
        {"seq": 1, "code": "STAGE_A"},
        {"seq": 3, "action": "GENERATE_REFERENCE", "type": "sync"},
        {"seq": 4, "code": "STAGE_EXIT", "event": "onExit"},
    ]}]}
    assert [row["code"] for row in stage_actions(definition, "INIT", "onEnter")] == ["STAGE_A", "STAGE_B"]
    assert [row["code"] for row in stage_actions(definition, "INIT", "onExit")] == ["STAGE_EXIT"]

    order = []
    class StageA:
        code = "STAGE_A"
        async def execute(self, ctx, params):
            order.append(self.code)
            return ActionResult(data=self.code)
    class StageB:
        code = "STAGE_B"
        async def execute(self, ctx, params):
            order.append(self.code)
            return ActionResult(data=self.code)
    class Log:
        rows = None
        async def record_executions(self, _id, rows): self.rows = rows
        async def route_approval_request(self, *_args): raise AssertionError("No routing")
        @asynccontextmanager
        async def savepoint(self): yield

    import asyncio
    instance = uuid4()
    log = Log()
    engine = WorkflowEngine(log, {"STAGE_A": StageA, "STAGE_B": StageB})
    context = TransitionContext("INIT", {"id": uuid4()}, definition, workflow_instance_id=instance)
    asyncio.run(engine.run_stage_event(context, "INIT", "onEnter"))
    assert order == ["STAGE_A", "STAGE_B"]
    assert [(row["seq"], row["action_code"], row["stage_code"]) for row in log.rows] == [
        (1, "STAGE_A", "INIT"), (2, "STAGE_B", "INIT")]


def test_transition_action_sequence_uses_only_the_matching_conditional_branch():
    definition = {"transitions": [
        {"from": "DRAFT", "to": "FEE_COLLECTION", "on": "SUBMIT", "code": "SUBMIT",
         "when": {"all": [{"field": "fee.required", "op": "eq", "value": True}]},
         "actions": [{"seq": 1, "code": "COLLECT_FEE"}]},
        {"from": "DRAFT", "to": "MANAGER_APPROVAL", "on": "SUBMIT", "code": "SUBMIT",
         "when": {"all": [{"field": "fee.required", "op": "eq", "value": False}]},
         "actions": [{"seq": 1, "code": "CREATE_APPROVAL_REQUEST"}]},
    ]}

    selected = transition_actions(definition, "SUBMIT", "DRAFT", "SUBMIT",
                                  {"fee": {"required": False}})
    assert [action["code"] for action in selected] == ["CREATE_APPROVAL_REQUEST"]

    with pytest.raises(AppError):
        transition_actions(definition, "SUBMIT", "DRAFT", "SUBMIT", {})


def test_form_input_cleans_values_and_enforces_v1_types():
    schema = {
        "type": "object",
        "required": ["reason", "approved_amount", "approved"],
        "properties": {
            "reason": {"type": "string", "x-field": "multiline", "minLength": 3},
            "approved_amount": {"type": "number", "x-field": "amount", "exclusiveMinimum": 0,
                                "x-maxFrom": "requested_amount"},
            "approved": {"type": "boolean", "x-field": "boolean"},
            "decision_date": {"type": "string", "x-field": "date"},
        },
    }

    values = validate_input(
        schema,
        {"reason": "  looks good  ", "approved_amount": "12.50", "approved": True,
         "decision_date": "2026-11-20"},
        {"requested_amount": "20.00"},
    )

    assert values["reason"] == "looks good"
    assert str(values["approved_amount"]) == "12.50"
    assert values["approved"] is True
    assert values["decision_date"] == "2026-11-20"


@pytest.mark.parametrize(
    ("value", "record", "code"),
    [
        ({"reason": "x", "approved_amount": 21, "approved": True}, {"requested_amount": 20}, "TOO_SHORT"),
        ({"reason": "ok", "approved_amount": 21, "approved": True}, {"requested_amount": 20}, "TOO_LARGE"),
        ({"reason": "ok", "approved_amount": "NaN", "approved": True}, {"requested_amount": 20}, "NUMBER"),
        ({"reason": "ok", "approved_amount": 10, "approved": "true"}, {"requested_amount": 20}, "BOOLEAN"),
        ({"reason": "ok", "approved_amount": 10, "approved": True, "extra": 1}, {"requested_amount": 20},
         "UNKNOWN_FIELD"),
    ],
)
def test_form_input_rejects_invalid_or_unknown_values(value, record, code):
    schema = {
        "type": "object",
        "required": ["reason", "approved_amount", "approved"],
        "properties": {
            "reason": {"type": "string", "x-field": "text", "minLength": 3},
            "approved_amount": {"type": "number", "x-field": "amount", "exclusiveMinimum": 0,
                                "x-maxFrom": "requested_amount"},
            "approved": {"type": "boolean", "x-field": "boolean"},
        },
    }
    with pytest.raises(AppError) as exc:
        validate_input(schema, value, record)
    assert any(error["code"] == code for error in exc.value.details["errors"])
