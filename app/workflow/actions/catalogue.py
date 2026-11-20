"""Catalogue steps performed inside existing SQL functions (validations,
journals, receipts, schedules, ...). They appear in the registry so stages can
name them and the Super Admin can see them; executed on their own they report
SKIPPED, because the composite database step does the work."""

from __future__ import annotations

from app.workflow.actions.base import CompositeStep


class ValidateMemberStatus(CompositeStep):
    code = "VALIDATE_MEMBER_STATUS"
    name = {"en": "Validate member status", "ta": "உறுப்பினர் நிலையைச் சரிபார்"}
    description = "Member must be Active and not restricted"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("LOAN", "MEMBER"), ("onEnter", "afterRule")


class ValidateLoanEligibility(CompositeStep):
    code = "VALIDATE_LOAN_ELIGIBILITY"
    name = {"en": "Validate loan eligibility", "ta": "கடன் தகுதியைச் சரிபார்"}
    description = "Default history, outstanding loans, cooling-off, membership period, limits"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "afterRule")
    params_schema = {"type": "object", "properties": {
        "checkDefaultHistory": {"type": "boolean"}, "checkOutstandingLoans": {"type": "boolean"},
        "checkCoolingOff": {"type": "boolean"}, "checkMemberStatus": {"type": "boolean"}},
        "additionalProperties": False}


class ValidateApplicationFee(CompositeStep):
    code = "VALIDATE_APPLICATION_FEE"
    name = {"en": "Validate application fee", "ta": "விண்ணப்பக் கட்டணத்தைச் சரிபார்"}
    description = "Fee must be paid or waived before submission"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "afterRule")


class ValidateNominee(CompositeStep):
    code = "VALIDATE_NOMINEE"
    name = {"en": "Validate nominee", "ta": "நியமனதாரரைச் சரிபார்"}
    description = "Nominee required by the organisation's NOMINEE rule"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "afterRule")


class ValidateGuarantors(CompositeStep):
    code = "VALIDATE_GUARANTORS"
    name = {"en": "Validate guarantors", "ta": "உத்தரவாததாரர்களைச் சரிபார்"}
    description = "Required guarantors present and within limits"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "afterRule")


class ValidateApprovalAuthority(CompositeStep):
    code = "VALIDATE_APPROVAL_AUTHORITY"
    name = {"en": "Validate approval authority", "ta": "ஒப்புதல் அதிகாரத்தைச் சரிபார்"}
    description = "Approver holds the stage role and is not the requester or beneficiary"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "afterRule")


class ValidateDuplicateMember(CompositeStep):
    code = "VALIDATE_DUPLICATE_MEMBER"
    name = {"en": "Validate duplicate member", "ta": "இரட்டை உறுப்பினரைச் சரிபார்"}
    description = "Duplicate check by mobile, name and date of birth, and identity"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("MEMBER",), ("onEnter", "afterRule")


class ValidateFundBalance(CompositeStep):
    code = "VALIDATE_FUND_BALANCE"
    name = {"en": "Validate fund balance", "ta": "நிதி இருப்பைச் சரிபார்"}
    description = "Restricted fund purpose and available balance"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("ASSISTANCE",), ("onEnter", "afterRule")


class CheckHallAvailability(CompositeStep):
    code = "CHECK_HALL_AVAILABILITY"
    name = {"en": "Check hall availability", "ta": "மண்டபம் கிடைப்பதைச் சரிபார்"}
    description = "One booking per hall per day"
    category, kind = "Validation", "VALIDATION"
    supported_entities, supported_events = ("HALL_BOOKING",), ("onEnter", "afterRule")


class GenerateReference(CompositeStep):
    code = "GENERATE_REFERENCE"
    name = {"en": "Generate reference number", "ta": "குறிப்பு எண்ணை உருவாக்கு"}
    description = "Assign the business reference number"
    category = "Utility"
    supported_entities, supported_events = ("LOAN", "MEMBER"), ("onEnter",)


class CalculateApplicationFee(CompositeStep):
    code = "CALCULATE_APPLICATION_FEE"
    name = {"en": "Calculate application fee", "ta": "விண்ணப்பக் கட்டணத்தைக் கணக்கிடு"}
    description = "Fee from the loan type's APPLICATION_FEE rule"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class GenerateReceipt(CompositeStep):
    code = "GENERATE_RECEIPT"
    name = {"en": "Generate receipt", "ta": "ரசீதை உருவாக்கு"}
    description = "Create a numbered cash receipt"
    category = "Finance"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "onTransition")


class GenerateJournalEntry(CompositeStep):
    code = "GENERATE_JOURNAL_ENTRY"
    name = {"en": "Generate journal entry", "ta": "பேரேட்டுப் பதிவை உருவாக்கு"}
    description = "Post a balanced journal from a journal template"
    category = "Accounting"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "onTransition")
    params_schema = {"type": "object", "properties": {
        "journalTemplate": {"type": "string"}, "debitMapping": {"type": "string"},
        "creditMapping": {"type": "string"}, "postingMode": {"enum": ["IMMEDIATE", "ON_APPROVAL"]}},
        "required": ["journalTemplate"], "additionalProperties": False}


class GenerateRepaymentSchedule(CompositeStep):
    code = "GENERATE_REPAYMENT_SCHEDULE"
    name = {"en": "Generate repayment schedule", "ta": "திருப்பிச் செலுத்தும் அட்டவணையை உருவாக்கு"}
    description = "Instalment schedule with the rounding rules"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class CreateDisbursementInstruction(CompositeStep):
    code = "CREATE_DISBURSEMENT_INSTRUCTION"
    name = {"en": "Create disbursement instruction", "ta": "வழங்கல் அறிவுறுத்தலை உருவாக்கு"}
    description = "Prepare the payment voucher for maker-checker release"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class UpdateLoanBalances(CompositeStep):
    code = "UPDATE_LOAN_BALANCES"
    name = {"en": "Update loan balances", "ta": "கடன் இருப்புகளைப் புதுப்பி"}
    description = "Recalculate outstanding balances and status"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter", "onTransition")


class CalculateSettlement(CompositeStep):
    code = "CALCULATE_SETTLEMENT"
    name = {"en": "Calculate settlement", "ta": "தீர்வுத் தொகையைக் கணக்கிடு"}
    description = "Early or default settlement statement"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class CloseLoan(CompositeStep):
    code = "CLOSE_LOAN"
    name = {"en": "Close loan", "ta": "கடனை முடி"}
    description = "Mark the loan settled or closed and cancel future instalments"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class CalculateDefault(CompositeStep):
    code = "CALCULATE_DEFAULT"
    name = {"en": "Calculate default amount", "ta": "நிலுவைத் தொகையைக் கணக்கிடு"}
    description = "Full outstanding plus default penalty"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class RestrictEligibility(CompositeStep):
    code = "RESTRICT_ELIGIBILITY"
    name = {"en": "Restrict eligibility", "ta": "தகுதியைக் கட்டுப்படுத்து"}
    description = "Set member loan eligibility to restricted or cooling-off"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class CreateRecoveryCase(CompositeStep):
    code = "CREATE_RECOVERY_CASE"
    name = {"en": "Create recovery case", "ta": "வசூல் வழக்கை உருவாக்கு"}
    description = "Open and assign a recovery case"
    category = "Loan"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class ActivateMember(CompositeStep):
    code = "ACTIVATE_MEMBER"
    name = {"en": "Activate member", "ta": "உறுப்பினரைச் செயல்படுத்து"}
    description = "Set member status Active with effective date"
    category = "Member"
    supported_entities, supported_events = ("MEMBER",), ("onEnter",)


class LockHallPrice(CompositeStep):
    code = "LOCK_HALL_PRICE"
    name = {"en": "Lock hall price", "ta": "மண்டப விலையை நிர்ணயி"}
    description = "Lock pricing on confirmation"
    category = "Hall"
    supported_entities, supported_events = ("HALL_BOOKING",), ("onEnter",)


class RegisterAsset(CompositeStep):
    code = "REGISTER_ASSET"
    name = {"en": "Register asset", "ta": "சொத்தைப் பதிவு செய்"}
    description = "Create the asset register entry"
    category = "Asset"
    supported_entities, supported_events = ("ASSET",), ("onEnter",)


class RecordOfflineApproval(CompositeStep):
    code = "RECORD_OFFLINE_APPROVAL"
    name = {"en": "Record offline approval", "ta": "நேரடியற்ற ஒப்புதலைப் பதிவு செய்"}
    description = "Record a verbal, meeting or document decision with evidence"
    category, kind = "Approval", "APPROVAL"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)


class CollectDecision(CompositeStep):
    code = "COLLECT_DECISION"
    name = {"en": "Collect decision", "ta": "முடிவைப் பெறு"}
    description = "Wait for the approver's decision"
    category, kind = "Approval", "MANUAL"
    supported_entities, supported_events = ("LOAN",), ("onEnter",)
