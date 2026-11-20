import json
from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from typing import Any
from uuid import UUID

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.repositories.loans import LoanRepository
from app.repositories.workflow import WorkflowRepository
from app.services.loan_rules import (assert_rule_checks, build_criteria, failed_eligibility, failing_checks,
                                     interest_terms, required_field,
                                     required_rule, stage_of_checks, transition_rule_outcomes)
from app.workflow.engine import (TransitionContext, WorkflowEngine, route_rules, transitions_for,
                                 transition_matches_when)
from app.repositories.loan_lifecycle import LoanLifecycleRepository

CENT = Decimal("0.01")

# Approval decisions and the workflow transition each one runs.
DECISION_EVENTS = {"APPROVED": "APPROVE", "REJECTED": "REJECT", "RETURNED": "RETURN"}


def _decimal(value: Any, default: str = "0") -> Decimal:
    return Decimal(str(value if value is not None else default))


def _rule(definition: dict[str, Any], code: str) -> dict[str, Any]:
    for item in definition.get("rules", []):
        if item.get("code") == code:
            value = item.get("value", {})
            return value if isinstance(value, dict) else {"value": value}
    return {}


def _money(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def _months_between(start: date, end: date) -> int:
    months = (end.year - start.year) * 12 + end.month - start.month
    if end.day < start.day:
        months -= 1
    return max(months, 0)


def _add_months(value: date, months: int) -> date:
    import calendar

    month = value.month - 1 + months
    year = value.year + month // 12
    month = month % 12 + 1
    return date(year, month, min(value.day, calendar.monthrange(year, month)[1]))


def _limit(rule: dict[str, Any], setting: dict[str, Any], key: str) -> Any:
    """A loan type rule value wins over the organisation setting; null in both means no limit."""
    if rule.get(key) is not None:
        return rule.get(key)
    return (setting or {}).get(key)


def exposure_reasons(*, definition: dict[str, Any], exposure: dict[str, Any] | None, working_date: date,
                     requested_amount: Decimal, requested_tenure_months: int,
                     block_if_overdue_dues: bool) -> tuple[list[str], int]:
    """Age, per-type, exposure and other-dues checks; returns (reasons, guarantors required)."""
    if not exposure:
        return [], 0
    reasons: list[str] = []
    age_rule, age_setting = _rule(definition, "AGE_LIMITS"), exposure.get("age_limits") or {}
    min_age = _limit(age_rule, age_setting, "minAtApplication")
    max_age = _limit(age_rule, age_setting, "maxAtApplication")
    max_end = _limit(age_rule, age_setting, "maxAtMaturity")
    dob = exposure.get("date_of_birth")
    if isinstance(dob, str):
        dob = date.fromisoformat(dob)
    if any(v is not None for v in (min_age, max_age, max_end)):
        if dob is None:
            # Legacy members may have no date of birth; block only when the rule asks for it.
            if _limit(age_rule, age_setting, "requireDateOfBirth"):
                reasons.append("DATE_OF_BIRTH_REQUIRED")
        else:
            age = _months_between(dob, working_date) // 12
            age_at_end = _months_between(dob, _add_months(working_date, requested_tenure_months)) // 12
            if min_age is not None and age < int(min_age):
                reasons.append("AGE_BELOW_MINIMUM")
            if max_age is not None and age > int(max_age):
                reasons.append("AGE_ABOVE_MAXIMUM")
            if max_end is not None and age_at_end > int(max_end):
                reasons.append("AGE_AT_MATURITY_ABOVE_MAXIMUM")
    max_per_type = _rule(definition, "CONCURRENT_LOANS").get("maxPerType")
    if max_per_type is not None and int(exposure.get("type_loan_count") or 0) >= int(max_per_type):
        reasons.append("MAX_LOANS_OF_TYPE_REACHED")
    limits_rule, limits_setting = _rule(definition, "EXPOSURE_LIMITS"), exposure.get("exposure_limits") or {}
    per_member = _limit(limits_rule, limits_setting, "perMember")
    per_household = _limit(limits_rule, limits_setting, "perHousehold")
    if per_member is not None and _decimal(exposure.get("member_outstanding")) + requested_amount > _decimal(per_member):
        reasons.append("MEMBER_EXPOSURE_LIMIT_EXCEEDED")
    if per_household is not None and _decimal(exposure.get("household_outstanding")) + requested_amount > _decimal(per_household):
        reasons.append("HOUSEHOLD_EXPOSURE_LIMIT_EXCEEDED")
    if block_if_overdue_dues and exposure.get("overdue_chit_dues"):
        reasons.append("OVERDUE_CHIT_DUES")
    if block_if_overdue_dues and exposure.get("overdue_contribution_dues"):
        reasons.append("OVERDUE_CONTRIBUTION_DUES")
    # Guarantors: the higher of what the loan type and the organisation require.
    required = 0
    for source in (_rule(definition, "GUARANTORS"), exposure.get("guarantors_required") or {}):
        count = int(source.get("count") or 0)
        above = source.get("aboveAmount")
        if count and (above is None or requested_amount > _decimal(above)):
            required = max(required, count)
    return reasons, required


def nominee_conditions(rule: dict[str, Any]) -> dict[str, Any]:
    """Conditions of the NOMINEE rule. Current shape:
    {"conditions": {"firstLoan", "thresholdAmount", "defaulter": {"enabled", "lookbackMonths"}},
     "allowOverride"}; older snapshots keep firstLoan/thresholdAmount at the top."""
    return rule.get("conditions") if isinstance(rule.get("conditions"), dict) else rule


def nominee_reasons(
    rule: dict[str, Any], *, first_loan: bool, requested_amount: Decimal,
    past_default_loan_no: str | None = None,
) -> list[str]:
    """Why the NOMINEE rule needs a nominee; ANY enabled condition is enough:
    FIRST_LOAN (firstLoan: true), THRESHOLD (amount at
    or above thresholdAmount; null = off), PAST_DEFAULT (defaulter.enabled and
    a current or recent default, found by the caller). EVERY_LOAN only for
    older snapshots that still carry everyLoan."""
    conditions = nominee_conditions(rule)
    why: list[str] = []
    if rule.get("everyLoan"):
        why.append("EVERY_LOAN")
    if first_loan and conditions.get("firstLoan") is True:
        why.append("FIRST_LOAN")
    threshold = conditions.get("thresholdAmount")
    if threshold is not None and requested_amount >= _decimal(threshold):
        why.append("THRESHOLD")
    if (conditions.get("defaulter") or {}).get("enabled") and past_default_loan_no:
        why.append("PAST_DEFAULT")
    return why


def nominee_requirement(
    rule: dict[str, Any], *, first_loan: bool, requested_amount: Decimal,
    past_default_loan_no: str | None = None,
) -> bool:
    return bool(nominee_reasons(rule, first_loan=first_loan, requested_amount=requested_amount,
                                past_default_loan_no=past_default_loan_no))


class LoanService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = LoanRepository(conn)
        self.lifecycle = LoanLifecycleRepository(conn)
        self.workflow = WorkflowRepository(conn)

    failure_log = None              # set by the generic workflow API (autonomous failure record)

    def _engine(self) -> WorkflowEngine:
        return WorkflowEngine(self.workflow, failure_log=self.failure_log)

    async def _run(self, ctx: TransitionContext, *, evaluate, default_actions, from_stage):
        """Run a loan transition through the engine; actions come from the
        registry (app/workflow/actions), statuses from the workflow JSON."""
        loan_id = ctx.entity["id"]
        ctx.services.setdefault("loan", self)

        async def entity_state(_ctx):
            return await self.workflow.loan_state(loan_id)

        async def apply_status(c, change):
            return await self.workflow.apply_loan_status(loan_id, change, c.workflow_instance_id)

        await self._engine().run_transition(
            ctx, evaluate_rules=evaluate, default_actions=default_actions, from_stage=from_stage,
            entity_state=entity_state, apply_status=apply_status)
        return ctx

    # -- registry actions (app/workflow/actions/loan.py call these) -----------
    async def action_create_approval_request(self, ctx: TransitionContext):
        loan = ctx.entity
        missing = await self.lifecycle.missing_documents(loan["id"])
        if missing:
            raise AppError("DOCUMENTS_REQUIRED", params={"missing": ", ".join(missing)}, details={"missing": missing})
        fee = await self.repository.application_fee(loan["id"])
        if fee and fee["collect_timing"] == "BEFORE_SUBMISSION" and fee["status"] not in {"PAID", "WAIVED"}:
            raise AppError("FEE_UNPAID")
        workflow = ctx.params.get("workflow")
        if workflow is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        approval_stage = ctx.params.get("approval_stage_code")
        if not approval_stage:
            ctx.workflow_instance_id = loan.get("workflow_instance_id")
            return {"target_stage": ctx.params.get("target_stage"), "approval_request_id": None,
                    "workflow_instance_id": ctx.workflow_instance_id}
        # SQL creates the request with the approval stage's roles, minimum
        # approvals, amount band and offline settings from the workflow.
        submitted = await self.repository.submit_application(
            loan, workflow, ctx.params["from_stage"], approval_stage)
        if submitted is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        ctx.results["approval_request_id"] = submitted.get("approval_request_id")
        ctx.workflow_instance_id = submitted.get("workflow_instance_id")
        return submitted

    async def action_record_decision(self, ctx: TransitionContext):
        request_id = ctx.entity["approval_request_id"]
        if ctx.routes:
            # A ROUTE_TO_ROLE check failed: the request moves to those roles
            # and their approver decides; nothing is decided now.
            return {"approval_request_id": request_id, "loan_id": ctx.entity["id"], "decision": "ROUTED",
                    "routed_to": sorted({r for route in ctx.routes for r in route["roles"]}),
                    "checks": [route["check"] for route in ctx.routes]}
        values = ctx.params["decision"]
        if ctx.params.get("offline"):
            result = await self.lifecycle.record_offline_approval(request_id, values)
        else:
            result = await self.lifecycle.decide(request_id, values)
        if result is None:
            raise AppError("APPROVAL_REQUEST_NOT_FOUND")
        return result

    async def action_release_disbursement(self, ctx: TransitionContext):
        values = ctx.params.get("input") or ctx.params
        result = await self.lifecycle.release_disbursement(
            ctx.entity["id"], values["disbursement_id"], values["ack_type"]
        )
        if result is None:
            raise AppError("DISBURSEMENT_NOT_FOUND")
        return result

    async def action_withdraw(self, ctx: TransitionContext):
        reason = (ctx.params.get("input") or {}).get("reason")
        row = await (await self.lifecycle.conn.execute(
            "SELECT loan.withdraw_application(%s,%s) AS result", (ctx.entity["id"], reason))).fetchone()
        return row["result"] if row else None

    async def action_notify(self, ctx: TransitionContext, template: str):
        row = await (await self.lifecycle.conn.execute(
            "SELECT loan.notify_member(%s,%s,%s::jsonb) AS id",
            (template, ctx.entity["id"], json.dumps({"loan_no": ctx.entity.get("loan_no")})))).fetchone()
        return {"notification_id": row["id"] if row else None}

    async def process_deferred(self, limit: int) -> dict[str, int]:
        """Run deferred actions (outbox) of the current organisation. A failure
        is retried while the action's params allow (retryCount), then FAILED."""
        engine = self._engine()
        done = failed = retried = 0
        for row in await self.workflow.due_deferred(limit):
            loan = await self.repository.get_application(row["entity_id"]) if row["entity_id"] else None
            ctx = TransitionContext("DEFERRED", {**(loan or {}), "id": row["entity_id"]}, None,
                                    services={"loan": self}, workflow_instance_id=row["workflow_instance_id"])
            params = row["params"] or {}
            try:
                async with self.workflow.savepoint():
                    result = await engine.action(row["action_code"]).execute(ctx, params)
                await self.workflow.finish_deferred(row["id"], "SUCCESS", result.as_dict())
                done += 1
            except Exception as exc:                                   # noqa: BLE001 - recorded on the row
                from app.workflow.engine import _error
                allowed = int(params.get("retryCount") or 0)
                if row["attempt"] <= allowed:
                    await self.workflow.finish_deferred(row["id"], "RETRYING", error=_error(exc), retry=True)
                    retried += 1
                else:
                    await self.workflow.finish_deferred(row["id"], "FAILED", error=_error(exc))
                    failed += 1
        return {"done": done, "retrying": retried, "failed": failed}

    @staticmethod
    def _type_out(row: dict[str, Any]) -> dict[str, Any]:
        definition = row["definition"]
        return {
            "id": row["id"],
            "code": row["code"],
            "name": row["name"],
            "description": row["description"],
            "interest_method": row["interest_method"],
            "is_interest_free": row["is_interest_free"],
            "allows_tranches": row["allows_tranches"],
            "rule_set_code": row["rule_set_code"],
            "rule_set_version_id": row["rule_set_version_id"],
            "rule_set_version_no": row["rule_set_version_no"],
            "effective_from": row["effective_from"],
            "terms": definition,
        }

    async def list_types(self) -> list[dict[str, Any]]:
        return [self._type_out(row) for row in await self.repository.list_types()]

    async def eligibility(
        self,
        *,
        member_id: UUID,
        loan_type_id: UUID,
        requested_amount: Decimal,
        requested_tenure_months: int,
        first_loan: bool | None = None,
    ) -> dict[str, Any]:
        """Eligibility and quote. ``first_loan`` overrides the member's history,
        which a submitted application needs: its own draft row already exists."""
        product = await self.repository.get_type(loan_type_id)
        if product is None:
            raise AppError("LOAN_TYPE_NOT_FOUND")
        member = await self.repository.member_eligibility_context(member_id)
        if member is None:
            raise AppError("MEMBER_NOT_FOUND")

        definition = product["definition"]
        # Limits, interest and fee come from the rules; a missing rule refuses.
        amount_limits = required_rule(definition, "AMOUNT_LIMITS")
        tenure_limits = required_rule(definition, "TENURE_LIMITS")
        interest = required_rule(definition, "INTEREST")
        fee_rule = required_rule(definition, "APPLICATION_FEE")
        nominee_rule = _rule(definition, "NOMINEE")
        settings = await self.repository.loan_settings()
        reasons: list[str] = []

        if member["status"] != "ACTIVE":
            reasons.append("MEMBER_NOT_ACTIVE")
        if member["loan_eligibility"] not in {"ELIGIBLE", "REINSTATED"}:
            reasons.append(f"MEMBER_{member['loan_eligibility']}")
        working_date = member["working_date"]
        if member["cooling_off_until"] and member["cooling_off_until"] >= working_date:
            reasons.append("MEMBER_IN_COOLING_OFF")
        if member["membership_date"] is None:
            reasons.append("MEMBERSHIP_DATE_REQUIRED")
        elif _months_between(member["membership_date"], working_date) < settings["min_membership_months"]:
            reasons.append("MIN_MEMBERSHIP_PERIOD_NOT_MET")
        if member["concurrent_loan_count"] >= settings["max_concurrent_loans"]:
            reasons.append("MAX_CONCURRENT_LOANS_REACHED")
        if settings["block_if_overdue_dues"] and member["has_overdue_instalment"]:
            reasons.append("OVERDUE_LOAN_INSTALMENT")

        extra, guarantors_required = exposure_reasons(
            definition=definition,
            exposure=await self.repository.member_exposure(member_id, loan_type_id),
            working_date=working_date, requested_amount=requested_amount,
            requested_tenure_months=requested_tenure_months,
            block_if_overdue_dues=bool(settings["block_if_overdue_dues"]),
        )
        reasons.extend(extra)

        min_amount = _decimal(required_field(amount_limits, "AMOUNT_LIMITS", "min"))
        max_amount = _decimal(required_field(amount_limits, "AMOUNT_LIMITS", "max"))
        min_tenure = int(required_field(tenure_limits, "TENURE_LIMITS", "minMonths"))
        max_tenure = int(required_field(tenure_limits, "TENURE_LIMITS", "maxMonths"))
        if requested_amount < min_amount or requested_amount > max_amount:
            reasons.append("AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS")
        if requested_tenure_months < min_tenure or requested_tenure_months > max_tenure:
            reasons.append("TENURE_OUTSIDE_LOAN_TYPE_LIMITS")

        first_loan = bool(member["is_first_loan"] if first_loan is None else first_loan)
        defaulter = nominee_conditions(nominee_rule).get("defaulter") or {}
        past_default = (await self.repository.member_past_default(member_id, defaulter.get("lookbackMonths"))
                        if defaulter.get("enabled") else None)
        nominee_why = nominee_reasons(
            nominee_rule,
            first_loan=first_loan,
            requested_amount=requested_amount,
            past_default_loan_no=past_default,
        )
        nominee_required = bool(nominee_why)
        fee_enabled = bool(required_field(fee_rule, "APPLICATION_FEE", "enabled"))
        fee_amount = Decimal("0")
        fee_timing = None
        if fee_enabled:
            fee_type = str(required_field(fee_rule, "APPLICATION_FEE", "type")).lower()
            fee_rate = _decimal(required_field(fee_rule, "APPLICATION_FEE", "amount"))
            fee_amount = _money(
                requested_amount * fee_rate / Decimal("100")
                if fee_type == "percent"
                else fee_rate
            )
            fee_timing = str(required_field(fee_rule, "APPLICATION_FEE", "timing")).upper()

        terms = interest_terms(interest, requested_amount, requested_tenure_months)
        method, annual_rate = terms["method"], terms["rate"]
        total_interest = _money(terms["total"])
        total_repayable = requested_amount + total_interest
        instalment_amount = _money(total_repayable / requested_tenure_months)

        return {
            "eligible": not reasons,
            "reasons": reasons,
            "first_loan": first_loan,
            "nominee_required": nominee_required,
            "nominee_required_because": nominee_why,
            "nominee_threshold_amount": nominee_conditions(nominee_rule).get("thresholdAmount"),
            "nominee_default_loan_no": past_default,
            # loan.nominee_override holders may approve without one, only when the rule sets allowOverride: true (absent = not allowed).
            "nominee_override_allowed": nominee_rule.get("allowOverride") is True,
            "guarantors_required": guarantors_required,
            "application_fee": fee_amount,
            "fee_timing": fee_timing,
            "interest_rate_annual": annual_rate,
            "interest_method": method,
            "estimated_total_interest": total_interest,
            "estimated_instalment_amount": instalment_amount,
            "total_repayable": total_repayable,
            "rule_set_version_id": product["rule_set_version_id"],
        }

    async def create_application(self, values: dict[str, Any]):
        product = await self.repository.get_type(values["loan_type_id"])
        if product is None:
            raise AppError("LOAN_TYPE_NOT_FOUND")
        member = await self.repository.member_eligibility_context(values["member_id"])
        if member is None:
            raise AppError("MEMBER_NOT_FOUND")
        eligibility = await self.eligibility(
            member_id=values["member_id"],
            loan_type_id=values["loan_type_id"],
            requested_amount=values["requested_amount"],
            requested_tenure_months=values["requested_tenure_months"],
        )
        if any(
            reason in eligibility["reasons"]
            for reason in ("AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS", "TENURE_OUTSIDE_LOAN_TYPE_LIMITS")
        ):
            raise AppError("LOAN_TERMS_OUT_OF_RANGE", details={"reasons": eligibility["reasons"]})
        if not await self.repository.validate_nominees(values["member_id"], values["nominee_ids"]):
            raise AppError("NOMINEE_NOT_ACTIVE")

        workflow = await self.repository.current_workflow()
        if workflow is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        fee = None
        if eligibility["fee_timing"]:
            fee_rule = _rule(product["definition"], "APPLICATION_FEE")
            fee_type = str(fee_rule.get("type", "fixed")).lower()
            fee = {
                "fee_basis": "PERCENT" if fee_type == "percent" else "FIXED",
                "fee_rate": fee_rule.get("amount") if fee_type == "percent" else None,
                "fee_amount": eligibility["application_fee"],
                "collect_timing": eligibility["fee_timing"],
            }
        created = await self.repository.create_application(
            values=values,
            product=product,
            workflow=workflow,
            member_context=member,
            fee=fee,
        )
        definition = (workflow or {}).get("definition") or {}
        start_stage = definition.get("startStage")
        if start_stage and created.get("workflow_instance_id"):
            context = TransitionContext(
                "INIT", created, definition, workflow_instance_id=created["workflow_instance_id"],
                services={"loan": self})
            await self._engine().run_stage_event(context, start_stage, "onEnter")
        return created

    async def collect_application_fee(self, loan_id: UUID, **values):
        result = await self.lifecycle.collect_fee(loan_id, **values)
        if result is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        return result

    async def decide(self, request_id: UUID, values: dict[str, Any], *, code: str | None = None):
        """Online approval decision through the workflow engine (APPROVE /
        REJECT / RETURN transition: rule checks, then RECORD_APPROVAL_DECISION)."""
        return await self._run_decision(request_id, values, offline=False, code=code)

    async def record_offline_decision(self, request_id: UUID, details: dict[str, Any]):
        """Offline decision recorded on the approver's behalf: the same
        transition, rule checks and log as an online decision."""
        values = {**details, "decision": str(details.get("decision", "")).upper()}
        return await self._run_decision(request_id, values, offline=True, raw=details)

    async def _run_decision(self, request_id: UUID, values: dict[str, Any], *, offline: bool,
                            raw: dict[str, Any] | None = None, code: str | None = None):
        event = DECISION_EVENTS.get(values.get("decision"))
        loan_id = await self.repository.loan_for_approval_request(request_id)
        loan = await self.repository.get_application(loan_id) if loan_id else None
        if loan is None and event == "APPROVE":
            raise AppError("APPROVAL_REQUEST_NOT_FOUND")
        sql_values = raw if offline else values
        if loan is None or event is None:
            # refused by SQL with the precise error
            result = (await self.lifecycle.record_offline_approval(request_id, sql_values) if offline
                      else await self.lifecycle.decide(request_id, sql_values))
            if result is None:
                raise AppError("APPROVAL_REQUEST_NOT_FOUND")
            return result
        workflow = await self.repository.workflow_version(loan["workflow_version_id"])
        workflow_state = await self.workflow.loan_state(loan["id"])

        async def evaluate(_ctx):
            if event != "APPROVE":
                return {"event": event, "checks": {}, "routes": []}
            approved = {**loan, "approved_amount": values.get("approved_amount") or loan.get("approved_amount"),
                        "tenure_months": values.get("tenure_months") or loan.get("tenure_months")}
            return await self.enforce_transition(approved, "APPROVE", workflow=workflow,
                                                 nominee_override_reason=values.get("nominee_override_reason"),
                                                 approval_request_id=request_id)

        ctx = TransitionContext(event, {**loan, "approval_request_id": request_id},
                                (workflow or {}).get("definition"), code=code,
                                params={"decision": sql_values, "offline": offline, "input": values})
        await self._run(ctx, evaluate=evaluate, default_actions=["RECORD_APPROVAL_DECISION"],
                        from_stage=workflow_state.get("stage")
                        or ((workflow or {}).get("definition") or {}).get("startStage"))
        return ctx.results.get("RECORD_APPROVAL_DECISION")

    async def prepare_disbursement(self, loan_id: UUID, amount: Decimal, payment_mode: str = "CASH",
                                   payment_reference: str | None = None):
        result = await self.lifecycle.prepare_disbursement(loan_id, amount, payment_mode, payment_reference)
        if result is None:
            raise AppError("LOAN_NOT_FOUND")
        return result

    async def release_disbursement(self, loan_id: UUID, disbursement_id: UUID, ack_type: str):
        """DISBURSE transition: rule checks, then RELEASE_DISBURSEMENT (the SQL
        release posts the journal, receipt and SMS exactly as before)."""
        loan = await self.repository.get_application(loan_id)
        if loan is None:
            result = await self.lifecycle.release_disbursement(loan_id, disbursement_id, ack_type)
            if result is None:
                raise AppError("DISBURSEMENT_NOT_FOUND")
            return result
        workflow = await self.repository.workflow_version(loan["workflow_version_id"])
        ctx = TransitionContext("DISBURSE", loan, (workflow or {}).get("definition"),
                                params={"disbursement_id": disbursement_id, "ack_type": ack_type})

        async def evaluate(_ctx):
            return await self.enforce_transition(loan, "DISBURSE", workflow=workflow)

        await self._run(ctx, evaluate=evaluate, default_actions=["RELEASE_DISBURSEMENT"], from_stage="APPROVED")
        return ctx.results.get("RELEASE_DISBURSEMENT")

    async def collect_repayment(self, loan_id: UUID, **values):
        result = await self.lifecycle.collect_repayment(loan_id, **values)
        if result is None:
            raise AppError("LOAN_NOT_FOUND")
        return result

    async def schedule(self, loan_id: UUID):
        result = await self.lifecycle.schedule(loan_id)
        if result is None:
            raise AppError("LOAN_NOT_FOUND")
        return result

    async def repayments(self, loan_id: UUID):
        result = await self.lifecycle.repayments(loan_id)
        if result is None:
            raise AppError("LOAN_NOT_FOUND")
        return result

    async def member_statement(self, member_id: UUID):
        result = await self.lifecycle.member_statement(member_id)
        if result is None:
            raise AppError("MEMBER_NOT_FOUND")
        return result

    async def quote_settlement(self, loan_id: UUID, interest_waiver: Decimal = Decimal(0),
                               waiver_reason: str | None = None):
        return await self.lifecycle.quote_settlement(loan_id, interest_waiver, waiver_reason)

    async def approve_settlement(self, settlement_id: UUID, remarks: str | None):
        return await self.lifecycle.approve_settlement(settlement_id, remarks)

    async def collect_settlement(self, settlement_id: UUID, **values):
        return await self.lifecycle.collect_settlement(settlement_id, **values)

    async def settlement(self, settlement_id: UUID):
        result = await self.lifecycle.settlement(settlement_id)
        if result is None:
            raise AppError("SETTLEMENT_NOT_FOUND")
        return result

    async def settlements(self, loan_id: UUID):
        result = await self.lifecycle.settlements(loan_id)
        if result is None:
            raise AppError("LOAN_NOT_FOUND")
        return result

    async def list_applications(self, **filters):
        return await self.repository.list_applications(**filters)

    async def get_application(self, loan_id: UUID):
        loan = await self.repository.get_application(loan_id)
        if loan is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        nominee_status = await self.repository.nominee_status(loan_id)
        workflow = await self.repository.workflow_version(loan["workflow_version_id"])
        try:
            eligibility = await self.eligibility(
                member_id=loan["member_id"], loan_type_id=loan["loan_type_id"],
                requested_amount=loan.get("approved_amount") or loan["requested_amount"],
                requested_tenure_months=loan.get("tenure_months") or loan["requested_tenure_months"],
                first_loan=loan["is_first_loan"])
        except AppError:
            eligibility = None
        guarantors = len([g for g in await self.lifecycle.guarantors(loan_id) or [] if g["status"] == "ACTIVE"])
        criteria = build_criteria(eligibility, stages=stage_of_checks((workflow or {}).get("definition")),
                                  nominee_status=nominee_status, active_guarantors=guarantors) if eligibility else []
        return {**loan, "nominee_status": nominee_status, "criteria": criteria}

    async def update_application(self, loan_id: UUID, values: dict[str, Any], expected_version: int | None = None):
        """Change a draft or returned application after re-running the eligibility checks."""
        loan = await self.repository.get_application(loan_id)
        if loan is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        if loan["status"] not in {"DRAFT", "RETURNED"}:
            raise AppError("APPLICATION_NOT_EDITABLE")
        changes = {k: v for k, v in values.items() if v is not None}
        if any(k in changes for k in ("requested_amount", "requested_tenure_months")):
            eligibility = await self.eligibility(
                member_id=loan["member_id"],
                loan_type_id=loan["loan_type_id"],
                requested_amount=changes.get("requested_amount", loan["requested_amount"]),
                requested_tenure_months=changes.get("requested_tenure_months", loan["requested_tenure_months"]),
            )
            if any(reason in eligibility["reasons"]
                   for reason in ("AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS", "TENURE_OUTSIDE_LOAN_TYPE_LIMITS")):
                raise AppError("LOAN_TERMS_OUT_OF_RANGE", details={"reasons": eligibility["reasons"]})
            if eligibility.get("application_fee") is not None:
                changes["fee_amount"] = eligibility["application_fee"]
        if "nominee_ids" in changes and not await self.repository.validate_nominees(loan["member_id"], changes["nominee_ids"]):
            raise AppError("NOMINEE_NOT_ACTIVE")
        return await self.lifecycle.update_application(loan_id, changes, expected_version)

    async def submit_application(self, loan_id: UUID, *, code: str | None = None):
        loan = await self.repository.get_application(loan_id, lock=True)
        if loan is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        workflow = await self.repository.workflow_version(loan["workflow_version_id"])
        if workflow is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        state = await self.workflow.loan_state(loan_id)
        from_stage = state.get("stage") or ((workflow or {}).get("definition") or {}).get("startStage")
        if not from_stage:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        fee = await self.repository.application_fee(loan_id)
        fee_required = bool(fee and fee.get("fee_amount") and fee.get("collect_timing") in {
            "BEFORE_SUBMISSION", "AFTER_SUBMISSION"
        } and fee.get("status") not in {"PAID", "WAIVED"})

        async def evaluate(_ctx):
            return await self.enforce_transition(loan, "SUBMIT", workflow=workflow)

        condition_context = {"loan": loan, "fee": {"required": fee_required}}
        definition = (workflow or {}).get("definition") or {}
        candidates = transitions_for(definition, "SUBMIT", from_stage, code)
        if len(candidates) > 1 and any("when" in transition for transition in candidates):
            candidates = [transition for transition in candidates
                          if transition_matches_when(transition.get("when"), condition_context)]
        if not candidates:
            raise AppError("LOAN_NOT_SUBMITTABLE")
        target_stage = candidates[0].get("to")
        target = next((stage for stage in definition.get("stages", []) if stage.get("code") == target_stage), {})
        approval_stage = target_stage if target.get("approval") else None
        ctx = TransitionContext("SUBMIT", {**loan, "approval_request_id": state.get("approval_request_id"),
                                            "workflow_instance_id": state.get("workflow_instance_id")},
                                definition, code=code,
                                params={"workflow": workflow, "from_stage": from_stage,
                                        "target_stage": target_stage, "approval_stage_code": approval_stage,
                                        "condition_context": condition_context})
        await self._run(ctx, evaluate=evaluate, default_actions=["CREATE_APPROVAL_REQUEST"], from_stage=from_stage)
        return ctx.results.get("CREATE_APPROVAL_REQUEST")

    async def enforce_transition(
        self, loan: dict[str, Any], event: str, *, workflow: dict[str, Any] | None = None,
        nominee_override_reason: str | None = None, approval_request_id: UUID | None = None,
    ) -> dict[str, Any]:
        """Evaluate the rule checks the loan's workflow version attaches to a
        transition (SUBMIT, APPROVE, DISBURSE). An unmet NOMINEE rule can be
        overridden at that point by a holder of loan.nominee_override with a
        reason (stored, audited, shown to the approver)."""
        if workflow is None:
            workflow = await self.repository.workflow_version(loan["workflow_version_id"])
        definition = (workflow or {}).get("definition")
        checks = transition_rule_outcomes(definition, event)
        outcome: dict[str, Any] = {"event": event, "checks": checks, "routes": [], "nominee_override": False}
        if not checks:
            return outcome
        needs_eligibility = any(c not in {"NOMINEE"} for c in checks)
        eligibility = await self.eligibility(
            member_id=loan["member_id"], loan_type_id=loan["loan_type_id"],
            requested_amount=loan.get("approved_amount") or loan["requested_amount"],
            requested_tenure_months=loan.get("tenure_months") or loan["requested_tenure_months"],
            first_loan=loan["is_first_loan"],
        ) if needs_eligibility else None
        active_guarantors = None
        if "GUARANTORS" in checks and eligibility and eligibility.get("guarantors_required"):
            active_guarantors = len([g for g in await self.lifecycle.guarantors(loan["id"]) or []
                                     if g["status"] == "ACTIVE"])
        nominee_status = await self.repository.nominee_status(loan["id"]) if "NOMINEE" in checks else None

        # ROUTE_TO_ROLE: a failing check hands the approval request to its
        # roles once (an already-routed check is satisfied by that routing).
        route_codes = [code for code, on_fail in checks.items() if on_fail == "ROUTE_TO_ROLE"]
        if route_codes:
            routed: set[str] = set()
            request_id = approval_request_id or loan.get("approval_request_id")
            if request_id and event != "SUBMIT":
                state = await self.workflow.approval_request_state(request_id)
                routed = set((state or {}).get("routed_checks") or [])
            roles = route_rules(definition, event)
            for code in failing_checks(route_codes, eligibility=eligibility, active_guarantors=active_guarantors,
                                       nominee_status=nominee_status):
                if code not in routed:
                    outcome["routes"].append({"check": code, "roles": roles.get(code) or []})
        blocking = {code: on_fail for code, on_fail in checks.items() if on_fail != "ROUTE_TO_ROLE"}
        if assert_rule_checks(blocking, eligibility=eligibility, active_guarantors=active_guarantors,
                              nominee_status=nominee_status):
            reason = (nominee_override_reason or "").strip()
            if not reason:
                raise AppError("NOMINEE_REQUIRED")
            # Privilege, allowOverride and reason length are checked in SQL.
            await self.repository.record_nominee_override(loan["id"], reason)
            outcome["nominee_override"] = True
        return outcome

    async def preview_rule_checks(self, loan: dict[str, Any], event: str,
                                  workflow: dict[str, Any] | None) -> dict[str, Any]:
        """Rule checks of a transition without acting: what blocks it (with the
        reasons), whether a nominee override is needed, which checks would
        route the request, and warnings. Used to enable or disable buttons."""
        definition = (workflow or {}).get("definition")
        checks = transition_rule_outcomes(definition, event)
        preview: dict[str, Any] = {"blocked": [], "needs_override": False, "routes": [], "warnings": []}
        if not checks:
            return preview
        try:
            eligibility = await self.eligibility(
                member_id=loan["member_id"], loan_type_id=loan["loan_type_id"],
                requested_amount=loan.get("approved_amount") or loan["requested_amount"],
                requested_tenure_months=loan.get("tenure_months") or loan["requested_tenure_months"],
                first_loan=loan["is_first_loan"],
            ) if any(c != "NOMINEE" for c in checks) else None
        except AppError as exc:
            preview["blocked"].append({"code": exc.short_code, "params": exc.params})
            return preview
        active_guarantors = None
        if "GUARANTORS" in checks and eligibility and eligibility.get("guarantors_required"):
            active_guarantors = len([g for g in await self.lifecycle.guarantors(loan["id"]) or []
                                     if g["status"] == "ACTIVE"])
        nominee_status = await self.repository.nominee_status(loan["id"]) if "NOMINEE" in checks else None
        failing = failing_checks(list(checks), eligibility=eligibility, active_guarantors=active_guarantors,
                                 nominee_status=nominee_status)
        roles = route_rules(definition, event)
        for code in failing:
            on_fail = checks[code]
            if on_fail == "WARN":
                preview["warnings"].append({"code": code})
            elif on_fail == "ROUTE_TO_ROLE":
                preview["routes"].append({"check": code, "roles": roles.get(code) or []})
            elif on_fail == "REQUIRE_OVERRIDE" and (nominee_status or {}).get("override_allowed") is True:
                preview["needs_override"] = True
            else:
                if code == "NOMINEE":
                    reasons = (nominee_status or {}).get("required_because") or []
                elif code == "GUARANTORS":
                    reasons = [{"required": (eligibility or {}).get("guarantors_required"), "added": active_guarantors or 0}]
                else:
                    reasons = failed_eligibility(eligibility or {}, (code,))
                preview["blocked"].append({"code": code, "reasons": reasons})
        return preview

    async def run_transition_by_code(self, loan: dict[str, Any], workflow: dict[str, Any] | None, *,
                                     code: str, event: str, from_stage: str, input: dict[str, Any]):
        """Any other button: its rule checks, its configured actions (from the
        registry) and its statuses; a transition with no actions only changes
        statuses, so new statuses need no code."""
        state = await self.workflow.loan_state(loan["id"])
        ctx = TransitionContext(event, {**loan, "approval_request_id": state.get("approval_request_id"),
                                        "workflow_instance_id": state.get("workflow_instance_id")},
                                (workflow or {}).get("definition"), code=code,
                                params={"input": input, "workflow": workflow})

        async def evaluate(_ctx):
            return await self.enforce_transition(loan, event, workflow=workflow,
                                                 nominee_override_reason=input.get("nominee_override_reason"))

        await self._run(ctx, evaluate=evaluate, default_actions=[], from_stage=from_stage)
        return {key: value for key, value in ctx.results.items() if key != "approval_request_id"}

    async def eligibility_view(self, **values) -> dict[str, Any]:
        """Eligibility plus the criteria list, grouped by the transition of the
        current workflow version where each is checked."""
        result = await self.eligibility(**values)
        workflow = await self.repository.current_workflow()
        stages = stage_of_checks((workflow or {}).get("definition"))
        return {**result, "criteria": build_criteria(result, stages=stages)}

    async def set_nominees(self, loan_id: UUID, nominee_ids: list[UUID], expected_version: int | None):
        if expected_version is None:
            raise AppError("ROW_VERSION_REQUIRED")
        loan = await self.repository.get_application(loan_id)
        if loan is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        # Draft/returned: the maker (loan.create) or loan.edit; afterwards loan.edit.
        if loan["status"] not in {"DRAFT", "RETURNED"} and not await self.repository.has_privilege("loan.edit"):
            raise AppError("NO_PRIVILEGE", params={"privilege": "loan.edit"})
        return await self.repository.set_application_nominees(loan_id, nominee_ids, expected_version)

    async def record_nominee_override(self, loan_id: UUID, reason: str):
        return await self.repository.record_nominee_override(loan_id, reason.strip())

    async def approval_inbox(self, *, limit: int, offset: int):
        rows = await self.repository.approval_inbox(limit=limit, offset=offset)
        has_more = len(rows) > limit
        return {
            "items": rows[:limit],
            "limit": limit,
            "offset": offset,
            "has_more": has_more,
            "next_offset": offset + limit if has_more else None,
        }
