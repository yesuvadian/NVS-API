"""Loan workflow actions. Each delegates to LoanService (ctx.services["loan"]),
which wraps the SQL functions, so journals, receipts and SMS stay exactly as
the database performs them."""

from __future__ import annotations

from typing import Any

from app.workflow.actions.base import ActionResult, IStageAction, WorkflowAction, stage_action


class _LoanAction(WorkflowAction):
    supported_entities = ("LOAN",)
    category = "Loan"

    @staticmethod
    def service(ctx: Any):
        return ctx.services["loan"]


class CreateApprovalRequest(_LoanAction):
    code = "CREATE_APPROVAL_REQUEST"
    name = {"en": "Create approval request", "ta": "ஒப்புதல் கோரிக்கையை உருவாக்கு"}
    description = ("Submit the application and open an approval request for the next stage "
                   "(roles from the stage approval settings)")
    category = "Approval"
    kind = "APPROVAL"

    async def execute(self, ctx, params):
        return ActionResult(data=await self.service(ctx).action_create_approval_request(ctx))


class RecordApprovalDecision(_LoanAction):
    code = "RECORD_APPROVAL_DECISION"
    name = {"en": "Record approval decision", "ta": "ஒப்புதல் முடிவைப் பதிவு செய்"}
    description = ("Record an approve / reject / return decision (online or offline); approve completes "
                   "when minApprovals distinct approvers agreed")
    category = "Approval"
    kind = "APPROVAL"

    async def execute(self, ctx, params):
        return ActionResult(data=await self.service(ctx).action_record_decision(ctx))


class ReleaseDisbursement(_LoanAction):
    code = "RELEASE_DISBURSEMENT"
    name = {"en": "Release disbursement", "ta": "கடன் தொகையை வழங்கு"}
    description = "Release a prepared disbursement (cash receipt, journal, schedule, SMS)"

    async def execute(self, ctx, params):
        return ActionResult(data=await self.service(ctx).action_release_disbursement(ctx))


class WithdrawApplication(_LoanAction):
    code = "WITHDRAW_APPLICATION"
    name = {"en": "Withdraw application", "ta": "விண்ணப்பத்தைத் திரும்பப் பெறு"}
    description = "Withdraw before approval: closes the approval request, its task and the workflow"

    async def execute(self, ctx, params):
        return ActionResult(data=await self.service(ctx).action_withdraw(ctx))


@stage_action
class SendNotification(_LoanAction, IStageAction):
    code = "SEND_NOTIFICATION"
    name = {"en": "Send notification", "ta": "அறிவிப்பு அனுப்பு"}
    description = "Queue a notification to the member from a template (can be deferred and retried)"
    category = "Notification"
    kind = "NOTIFICATION"
    supported_events = ("onEnter", "onExit", "onTransition")
    deferrable = True
    params_schema = {
        "type": "object",
        "properties": {"template": {"type": "string", "minLength": 1},
                       "channel": {"enum": ["SMS", "WHATSAPP", "EMAIL", "INAPP"]},
                       "recipientType": {"type": "string"}, "delayMinutes": {"type": "integer"},
                       "retryCount": {"type": "integer"}},
        "required": ["template"],
        "additionalProperties": False,
    }

    async def execute(self, ctx, params):
        return ActionResult(data=await self.service(ctx).action_notify(ctx, params["template"]))


class RuleChecks(WorkflowAction):
    """Engine step: the transition's rule checks (logged first)."""

    code = "RULE_CHECKS"
    name = {"en": "Rule checks", "ta": "விதி சரிபார்ப்புகள்"}
    description = "Evaluate the rule checks of a transition (logged for audit and statistics)"
    category = "Validation"
    kind = "VALIDATION"
    supported_entities = ("LOAN",)
    supported_events = ()
    selectable = False

    async def execute(self, ctx, params):
        return ActionResult("SKIPPED", message="Run by the engine before the actions")


class SetStatus(WorkflowAction):
    """Engine step: stage and entity statuses from the workflow JSON."""

    code = "SET_STATUS"
    name = {"en": "Set statuses", "ta": "நிலைகளை அமை"}
    description = "Record the stage status and set the entity status declared by the workflow"
    supported_entities = ("LOAN",)
    supported_events = ()
    selectable = False

    async def execute(self, ctx, params):
        return ActionResult("SKIPPED", message="Run by the engine after the actions")
