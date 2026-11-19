from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from typing import Any
from uuid import UUID

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.repositories.loans import LoanRepository
from app.repositories.loan_lifecycle import LoanLifecycleRepository

CENT = Decimal("0.01")


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


def nominee_requirement(
    rule: dict[str, Any], *, first_loan: bool, first_loan_setting: bool, requested_amount: Decimal
) -> bool:
    """NOMINEE rule of the loan type: a nominee is needed for every loan
    (everyLoan), for a member's first loan (firstLoan and the organisation
    setting), or when the amount reaches thresholdAmount."""
    if rule.get("everyLoan"):
        return True
    if first_loan and first_loan_setting and rule.get("firstLoan", True):
        return True
    threshold = rule.get("thresholdAmount")
    return threshold is not None and requested_amount >= _decimal(threshold)


class LoanService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = LoanRepository(conn)
        self.lifecycle = LoanLifecycleRepository(conn)

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
        amount_limits = _rule(definition, "AMOUNT_LIMITS")
        tenure_limits = _rule(definition, "TENURE_LIMITS")
        interest = _rule(definition, "INTEREST")
        fee_rule = _rule(definition, "APPLICATION_FEE")
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

        min_amount = _decimal(amount_limits.get("min"))
        max_amount = _decimal(amount_limits.get("max"), "999999999999")
        min_tenure = int(tenure_limits.get("minMonths", 1))
        max_tenure = int(tenure_limits.get("maxMonths", 600))
        if requested_amount < min_amount or requested_amount > max_amount:
            reasons.append("AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS")
        if requested_tenure_months < min_tenure or requested_tenure_months > max_tenure:
            reasons.append("TENURE_OUTSIDE_LOAN_TYPE_LIMITS")

        first_loan = bool(member["is_first_loan"] if first_loan is None else first_loan)
        nominee_required = nominee_requirement(
            nominee_rule,
            first_loan=first_loan,
            first_loan_setting=bool(settings["nominee_mandatory_first_loan"]),
            requested_amount=requested_amount,
        )
        fee_enabled = bool(fee_rule.get("enabled", False))
        fee_amount = Decimal("0")
        fee_timing = None
        if fee_enabled:
            fee_type = str(fee_rule.get("type", "fixed")).lower()
            fee_rate = _decimal(fee_rule.get("amount"))
            fee_amount = _money(
                requested_amount * fee_rate / Decimal("100")
                if fee_type == "percent"
                else fee_rate
            )
            fee_timing = str(fee_rule.get("timing", "BEFORE_SUBMISSION")).upper()

        method = str(interest.get("method", product["interest_method"])).upper()
        annual_rate = _decimal(interest.get("annualRatePercent")) if method == "FLAT" else Decimal("0")
        total_interest = _money(
            requested_amount * annual_rate * Decimal(requested_tenure_months) / Decimal("1200")
        )
        total_repayable = requested_amount + total_interest
        instalment_amount = _money(total_repayable / requested_tenure_months)

        return {
            "eligible": not reasons,
            "reasons": reasons,
            "first_loan": first_loan,
            "nominee_required": nominee_required,
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
        return await self.repository.create_application(
            values=values,
            product=product,
            workflow=workflow,
            member_context=member,
            fee=fee,
        )

    async def collect_application_fee(self, loan_id: UUID, **values):
        result = await self.lifecycle.collect_fee(loan_id, **values)
        if result is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        return result

    async def decide(self, request_id: UUID, values: dict[str, Any]):
        result = await self.lifecycle.decide(request_id, values)
        if result is None:
            raise AppError("APPROVAL_REQUEST_NOT_FOUND")
        return result

    async def prepare_disbursement(self, loan_id: UUID, amount: Decimal, payment_mode: str = "CASH",
                                   payment_reference: str | None = None):
        result = await self.lifecycle.prepare_disbursement(loan_id, amount, payment_mode, payment_reference)
        if result is None:
            raise AppError("LOAN_NOT_FOUND")
        return result

    async def release_disbursement(self, loan_id: UUID, disbursement_id: UUID, ack_type: str):
        result = await self.lifecycle.release_disbursement(loan_id, disbursement_id, ack_type)
        if result is None:
            raise AppError("DISBURSEMENT_NOT_FOUND")
        return result

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
        return loan

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

    async def submit_application(self, loan_id: UUID):
        loan = await self.repository.get_application(loan_id, lock=True)
        if loan is None:
            raise AppError("LOAN_APPLICATION_NOT_FOUND")
        if loan["status"] not in {"DRAFT", "RETURNED"}:
            raise AppError("LOAN_NOT_SUBMITTABLE")

        eligibility = await self.eligibility(
            member_id=loan["member_id"],
            loan_type_id=loan["loan_type_id"],
            requested_amount=loan["requested_amount"],
            requested_tenure_months=loan["requested_tenure_months"],
            first_loan=loan["is_first_loan"],
        )
        if not eligibility["eligible"]:
            raise AppError("LOAN_INELIGIBLE", details={"reasons": eligibility["reasons"]})
        if eligibility["nominee_required"] and await self.repository.application_nominee_count(loan_id) == 0:
            raise AppError("NOMINEE_REQUIRED")
        if eligibility["guarantors_required"]:
            guarantors = [g for g in await self.lifecycle.guarantors(loan_id) or [] if g["status"] == "ACTIVE"]
            if len(guarantors) < eligibility["guarantors_required"]:
                raise AppError("GUARANTORS_REQUIRED",
                               params={"required": eligibility["guarantors_required"], "added": len(guarantors)})
        missing = await self.lifecycle.missing_documents(loan_id)
        if missing:
            raise AppError("DOCUMENTS_REQUIRED", params={"missing": ", ".join(missing)}, details={"missing": missing})
        fee = await self.repository.application_fee(loan_id)
        if fee and fee["collect_timing"] != "DEDUCT_FROM_DISBURSEMENT" and fee["status"] not in {"PAID", "WAIVED"}:
            raise AppError("FEE_UNPAID")
        workflow = await self.repository.workflow_version(loan["workflow_version_id"])
        if workflow is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        submitted = await self.repository.submit_application(loan, workflow)
        if submitted is None:
            raise AppError("LOAN_WORKFLOW_NOT_CONFIGURED")
        return submitted

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
