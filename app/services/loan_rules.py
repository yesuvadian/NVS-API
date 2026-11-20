"""Rule checks linked to workflow transitions.

The loan's own workflow version (snapshot taken at creation) lists, per
transition, the rule checks to evaluate ("ruleChecks"). This module maps
those codes to the eligibility results and the nominee state, raises the
established error codes, and builds the criteria list the UI shows.

Older workflow versions without "ruleChecks" keep the original check points
(LEGACY_RULE_CHECKS), so loans already in progress behave as before.
"""

from __future__ import annotations

from typing import Any

from app.core.errors import AppError

# Eligibility reason codes per rule check (see LoanService.eligibility).
ELIGIBILITY_CHECKS: dict[str, tuple[str, ...]] = {
    "MEMBER_STATUS": ("MEMBER_NOT_ACTIVE", "MEMBER_RESTRICTED", "MEMBER_COOLING_OFF", "MEMBER_IN_COOLING_OFF"),
    "MEMBERSHIP_PERIOD": ("MEMBERSHIP_DATE_REQUIRED", "MIN_MEMBERSHIP_PERIOD_NOT_MET"),
    "CONCURRENT_LOANS": ("MAX_CONCURRENT_LOANS_REACHED", "MAX_LOANS_OF_TYPE_REACHED"),
    "OVERDUE_DUES": ("OVERDUE_LOAN_INSTALMENT", "OVERDUE_CHIT_DUES", "OVERDUE_CONTRIBUTION_DUES"),
    "AGE_LIMITS": ("DATE_OF_BIRTH_REQUIRED", "AGE_BELOW_MINIMUM", "AGE_ABOVE_MAXIMUM", "AGE_AT_MATURITY_ABOVE_MAXIMUM"),
    "EXPOSURE_LIMITS": ("MEMBER_EXPOSURE_LIMIT_EXCEEDED", "HOUSEHOLD_EXPOSURE_LIMIT_EXCEEDED"),
    "AMOUNT_LIMITS": ("AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS",),
    "TENURE_LIMITS": ("TENURE_OUTSIDE_LOAN_TYPE_LIMITS",),
}
RULE_CHECK_CODES: tuple[str, ...] = (*ELIGIBILITY_CHECKS, "GUARANTORS", "NOMINEE")

# What happens when a rule check fails. ROUTE_TO_ROLE comes with the workflow
# engine; until then it blocks like BLOCK.
ON_FAIL = ("BLOCK", "REQUIRE_OVERRIDE", "ROUTE_TO_ROLE", "WARN")


def default_on_fail(code: str, event: str) -> str:
    """NOMINEE at approval can be overridden (privilege + reason); otherwise block."""
    return "REQUIRE_OVERRIDE" if code == "NOMINEE" and event == "APPROVE" else "BLOCK"

# Before rule checks were configurable: everything at SUBMIT.
LEGACY_RULE_CHECKS: dict[str, tuple[str, ...]] = {
    "SUBMIT": RULE_CHECK_CODES,
    "APPROVE": (),
    "DISBURSE": (),
}


def _reason_check(reason: str) -> str | None:
    for check, reasons in ELIGIBILITY_CHECKS.items():
        if reason in reasons or (check == "MEMBER_STATUS" and reason.startswith("MEMBER_")
                                 and reason not in ELIGIBILITY_CHECKS["MEMBERSHIP_PERIOD"]
                                 and "EXPOSURE" not in reason):
            return check
    return None


def transition_rule_outcomes(definition: dict[str, Any] | None, event: str) -> dict[str, str]:
    """Rule checks of a transition event, in order, with their onFail outcome.
    An entry is a code ("NOMINEE") or {"code": "NOMINEE", "onFail": "BLOCK"}."""
    transitions = (definition or {}).get("transitions") or []
    if not any("ruleChecks" in t for t in transitions):
        legacy = LEGACY_RULE_CHECKS.get(event, ())
        # Before configurable checks, an unmet nominee rule simply blocked.
        return {code: "BLOCK" for code in legacy}
    outcomes: dict[str, str] = {}
    for transition in transitions:
        if transition.get("on") != event:
            continue
        for entry in transition.get("ruleChecks") or []:
            code = entry.get("code") if isinstance(entry, dict) else entry
            on_fail = (entry.get("onFail") if isinstance(entry, dict) else None) or default_on_fail(code, event)
            outcomes.setdefault(code, on_fail)
    return outcomes


def transition_rule_checks(definition: dict[str, Any] | None, event: str) -> tuple[str, ...]:
    """Rule checks the workflow document attaches to a transition event."""
    return tuple(transition_rule_outcomes(definition, event))


def stage_of_checks(definition: dict[str, Any] | None) -> dict[str, str]:
    """Rule check -> first transition event where it is evaluated."""
    where: dict[str, str] = {}
    for event in ("SUBMIT", "APPROVE", "DISBURSE"):
        for code in transition_rule_checks(definition, event):
            where.setdefault(code, event)
    return where


def failed_eligibility(eligibility: dict[str, Any], checks: tuple[str, ...]) -> list[str]:
    """Eligibility reasons that belong to the given checks."""
    return [r for r in eligibility.get("reasons", []) if _reason_check(r) in checks]


def assert_rule_checks(
    checks: tuple[str, ...] | dict[str, str], *, eligibility: dict[str, Any] | None,
    active_guarantors: int | None, nominee_status: dict[str, Any] | None,
) -> str | None:
    """Raise the established error for the first failing check group.
    Checks whose onFail is WARN never block. Returns "NOMINEE_OVERRIDE_NEEDED"
    when the nominee rule is unmet and its onFail is REQUIRE_OVERRIDE (the
    caller records the override or refuses)."""
    outcomes = checks if isinstance(checks, dict) else {code: "BLOCK" for code in checks}
    checks = tuple(code for code, on_fail in outcomes.items() if on_fail != "WARN")
    if eligibility is not None:
        failed = failed_eligibility(eligibility, checks)
        if failed:
            raise AppError("LOAN_INELIGIBLE", details={"reasons": failed})
    if "GUARANTORS" in checks and eligibility is not None:
        required = int(eligibility.get("guarantors_required") or 0)
        if required and (active_guarantors or 0) < required:
            raise AppError("GUARANTORS_REQUIRED", params={"required": required, "added": active_guarantors or 0})
    if "NOMINEE" in checks and nominee_status is not None and not nominee_status.get("satisfied", True):
        if outcomes["NOMINEE"] == "REQUIRE_OVERRIDE":
            return "NOMINEE_OVERRIDE_NEEDED"
        raise AppError("NOMINEE_REQUIRED")
    return None


def build_criteria(
    eligibility: dict[str, Any], *, stages: dict[str, str],
    nominee_status: dict[str, Any] | None = None, active_guarantors: int | None = None,
) -> list[dict[str, Any]]:
    """Criteria list for the UI: code, label key, required, met (True/False,
    or None when it can only be judged later), detail, and the transition
    where the workflow checks it."""
    reasons = set(eligibility.get("reasons", []))
    criteria: list[dict[str, Any]] = []
    for code, codes in ELIGIBILITY_CHECKS.items():
        failed = sorted(r for r in reasons if _reason_check(r) == code)
        criteria.append({
            "code": code, "label_key": f"criterion_{code.lower()}", "required": code in stages,
            "met": not failed, "detail": {"reasons": failed}, "stage": stages.get(code),
        })
    required_guarantors = int(eligibility.get("guarantors_required") or 0)
    criteria.append({
        "code": "GUARANTORS", "label_key": "criterion_guarantors",
        "required": required_guarantors > 0 and "GUARANTORS" in stages,
        "met": (True if not required_guarantors
                else None if active_guarantors is None else active_guarantors >= required_guarantors),
        "detail": {"required": required_guarantors, "added": active_guarantors},
        "stage": stages.get("GUARANTORS"),
    })
    if nominee_status is not None:
        nominee_required = bool(nominee_status.get("required"))
        nominee_met: bool | None = bool(nominee_status.get("satisfied"))
        detail = {key: nominee_status.get(key) for key in
                  ("required_because", "active_nominees", "linked", "overridden", "override_reason",
                   "override_allowed", "threshold_amount", "default_loan_no")}
    else:
        nominee_required = bool(eligibility.get("nominee_required"))
        nominee_met = None if nominee_required else True       # judged when the loan exists
        detail = {"required_because": eligibility.get("nominee_required_because", []),
                  "threshold_amount": eligibility.get("nominee_threshold_amount"),
                  "default_loan_no": eligibility.get("nominee_default_loan_no"),
                  "override_allowed": eligibility.get("nominee_override_allowed", True)}
    criteria.append({
        "code": "NOMINEE", "label_key": "criterion_nominee",
        "required": nominee_required and "NOMINEE" in stages, "met": nominee_met,
        "detail": detail, "stage": stages.get("NOMINEE"),
    })
    return criteria
