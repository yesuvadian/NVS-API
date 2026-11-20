from app.rules.base import IAppRule, RuleEvaluation


class _EligibilityRule(IAppRule):
    reason_codes: tuple[str, ...] = ()

    def evaluate(self, context):
        reasons = tuple(reason for reason in (context.get("eligibility") or {}).get("reasons", ())
                        if reason in self.reason_codes)
        return RuleEvaluation(not reasons, reasons)


class MemberStatusRule(_EligibilityRule):
    code = "MEMBER_STATUS"
    name = {"en": "Member status", "ta": "உறுப்பினர் நிலை"}
    description = {"en": "Member is active and eligible", "ta": "உறுப்பினர் செயலில் இருந்து தகுதியுடையவர்"}
    reason_codes = ("MEMBER_NOT_ACTIVE", "MEMBER_RESTRICTED", "MEMBER_COOLING_OFF", "MEMBER_IN_COOLING_OFF")


class MembershipPeriodRule(_EligibilityRule):
    code = "MEMBERSHIP_PERIOD"
    name = {"en": "Membership period", "ta": "உறுப்பினர் காலம்"}
    description = {"en": "Minimum membership period is met", "ta": "குறைந்தபட்ச உறுப்பினர் காலம் பூர்த்தி"}
    reason_codes = ("MEMBERSHIP_DATE_REQUIRED", "MIN_MEMBERSHIP_PERIOD_NOT_MET")


class ConcurrentLoansRule(_EligibilityRule):
    code = "CONCURRENT_LOANS"
    name = {"en": "Concurrent loans", "ta": "நடப்பு கடன்கள்"}
    description = {"en": "Loan count limits are not exceeded", "ta": "கடன் எண்ணிக்கை வரம்பு மீறப்படவில்லை"}
    reason_codes = ("MAX_CONCURRENT_LOANS_REACHED", "MAX_LOANS_OF_TYPE_REACHED")


class OverdueDuesRule(_EligibilityRule):
    code = "OVERDUE_DUES"
    name = {"en": "Overdue dues", "ta": "நிலுவைத் தொகைகள்"}
    description = {"en": "No overdue loan or membership dues", "ta": "கடன் அல்லது உறுப்பினர் நிலுவை இல்லை"}
    reason_codes = ("OVERDUE_LOAN_INSTALMENT", "OVERDUE_CHIT_DUES", "OVERDUE_CONTRIBUTION_DUES")


class AgeLimitsRule(_EligibilityRule):
    code = "AGE_LIMITS"
    name = {"en": "Age limits", "ta": "வயது வரம்புகள்"}
    reason_codes = ("DATE_OF_BIRTH_REQUIRED", "AGE_BELOW_MINIMUM", "AGE_ABOVE_MAXIMUM", "AGE_AT_MATURITY_ABOVE_MAXIMUM")


class ExposureLimitsRule(_EligibilityRule):
    code = "EXPOSURE_LIMITS"
    name = {"en": "Exposure limits", "ta": "கடன் வெளிப்பாடு வரம்புகள்"}
    reason_codes = ("MEMBER_EXPOSURE_LIMIT_EXCEEDED", "HOUSEHOLD_EXPOSURE_LIMIT_EXCEEDED")


class AmountLimitsRule(_EligibilityRule):
    code = "AMOUNT_LIMITS"
    name = {"en": "Amount limits", "ta": "தொகை வரம்புகள்"}
    reason_codes = ("AMOUNT_OUTSIDE_LOAN_TYPE_LIMITS",)


class TenureLimitsRule(_EligibilityRule):
    code = "TENURE_LIMITS"
    name = {"en": "Tenure limits", "ta": "கால வரம்புகள்"}
    reason_codes = ("TENURE_OUTSIDE_LOAN_TYPE_LIMITS",)


class GuarantorsRule(IAppRule):
    code = "GUARANTORS"
    name = {"en": "Guarantors", "ta": "உத்தரவாததாரர்கள்"}
    category = "Loan requirements"

    def evaluate(self, context):
        required = int((context.get("eligibility") or {}).get("guarantors_required") or 0)
        added = int(context.get("active_guarantors") or 0)
        return RuleEvaluation(added >= required, ("GUARANTORS_REQUIRED",), {"required": required, "added": added})


class NomineeRule(IAppRule):
    code = "NOMINEE"
    name = {"en": "Nominee", "ta": "நியமனதாரர்"}
    category = "Loan requirements"

    def evaluate(self, context):
        state = context.get("nominee_status") or {}
        passed = state.get("satisfied", True)
        return RuleEvaluation(passed, () if passed else ("NOMINEE_REQUIRED",))
