"""Request bodies for recovery, waivers, cooling-off overrides and write-offs."""

from datetime import date
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


class RecoveryAssign(BaseModel):
    user_id: UUID


class RecoveryContact(BaseModel):
    outcome: str = Field(min_length=2, max_length=1000)
    method: Literal["CALL", "VISIT", "SMS", "LETTER", "OTHER"] = "CALL"
    person_type: Literal["MEMBER", "GUARANTOR", "NOMINEE", "OTHER"] = "MEMBER"
    person_name: str | None = Field(default=None, max_length=200)
    contact_date: date | None = None
    promise_date: date | None = None
    promise_amount: Decimal | None = Field(default=None, gt=0, decimal_places=2, max_digits=18)
    next_follow_up: date | None = None


class RecoveryStatusChange(BaseModel):
    status: Literal["CONTACTED", "PROMISE_TO_PAY", "LEGAL_NOTICE", "SETTLEMENT_AGREED", "EXCEPTION_APPROVED"]
    remarks: str = Field(min_length=3, max_length=1000)


class WaiverRequest(BaseModel):
    component: Literal["LATE_FEE", "PENALTY", "APPLICATION_FEE"]
    charge_id: UUID | None = None
    amount: Decimal = Field(gt=0, decimal_places=2, max_digits=18)
    reason: str = Field(min_length=3, max_length=1000)


class Decision(BaseModel):
    approve: bool
    remarks: str | None = Field(default=None, max_length=1000)


class CoolingOffOverrideRequest(BaseModel):
    reason: str = Field(min_length=3, max_length=1000)
    evidence_document_id: UUID | None = None


class CoolingOffOverrideDecision(Decision):
    valid_until: date | None = None


class WriteOffProposal(BaseModel):
    reason: str = Field(min_length=3, max_length=1000)


class WrittenOffRecovery(BaseModel):
    amount: Decimal = Field(gt=0, decimal_places=2, max_digits=18)
    payment_mode: str = Field(default="CASH", min_length=2, max_length=30)
    payment_reference: str | None = Field(default=None, max_length=120)


class Reason(BaseModel):
    reason: str = Field(min_length=3, max_length=1000)


class OfflineDecision(BaseModel):
    decision: Literal["APPROVED", "REJECTED", "RETURNED"]
    approved_by: UUID
    evidence_type: str = Field(min_length=2, max_length=40)
    decision_date: date | None = None
    reason: str | None = Field(default=None, max_length=1000)
    approved_amount: Decimal | None = Field(default=None, gt=0, decimal_places=2, max_digits=18)
    tenure_months: int | None = Field(default=None, gt=0, le=600)
    document_id: UUID | None = None
    remarks: str | None = Field(default=None, max_length=1000)


class OfflineVerification(BaseModel):
    result: Literal["VERIFIED", "DISCREPANCY"]
    remarks: str | None = Field(default=None, max_length=1000)


class GuarantorIn(BaseModel):
    guarantor_member_id: UUID | None = None
    non_member_name: str | None = Field(default=None, min_length=2, max_length=200)
    non_member_mobile: str | None = Field(default=None, min_length=6, max_length=20)
    non_member_address: str | None = Field(default=None, max_length=500)
    guaranteed_amount: Decimal | None = Field(default=None, gt=0, decimal_places=2, max_digits=18)
    consent_type: Literal["SIGNATURE", "THUMB_IMPRESSION"]
    consent_document_id: UUID | None = None


class GuarantorReplacementIn(BaseModel):
    new_guarantor: GuarantorIn
    reason: str = Field(min_length=3, max_length=1000)


class CashDisbursementApproval(BaseModel):
    remarks: str | None = Field(default=None, max_length=1000)


class RestructureRequest(BaseModel):
    option: Literal["EXTEND_TENURE", "REDUCE_INSTALMENT", "MORATORIUM", "CAPITALISE_OVERDUE", "COMBINATION"]
    reason: str = Field(min_length=3, max_length=1000)
    new_tenure_months: int | None = Field(default=None, gt=0, le=600)
    moratorium_months: int | None = Field(default=None, ge=0, le=60)
    new_interest_rate: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=4, max_digits=7)


class DeceasedLoanDecision(BaseModel):
    decision: Literal["RECOVER_FROM_SUCCESSOR", "RECOVER_FROM_GUARANTOR", "SET_OFF_DEPOSITS_CHIT",
                      "WAIVE_WRITE_OFF", "TRANSFER"]
    remarks: str | None = Field(default=None, max_length=1000)


class TransferShare(BaseModel):
    successor_member_id: UUID
    share_percent: Decimal = Field(gt=0, le=100, decimal_places=2, max_digits=5)
    legal_successor_id: UUID | None = None
    consent_document_id: UUID | None = None
    legal_verification_document_id: UUID | None = None


class LoanTransferProposal(BaseModel):
    shares: list[TransferShare] = Field(min_length=1, max_length=20)


class MigrationReviewDecision(BaseModel):
    apply_default: bool
    remarks: str = Field(min_length=3, max_length=1000)


class LoanDocumentIn(BaseModel):
    document_type: str = Field(min_length=2, max_length=40)
    file_name: str = Field(min_length=1, max_length=255)
    storage_key: str = Field(min_length=1, max_length=500)
    content_type: str | None = Field(default=None, max_length=100)
    size_bytes: int | None = Field(default=None, ge=0)
    sha256: str | None = Field(default=None, pattern=r"^[0-9a-fA-F]{64}$")
    description: str | None = Field(default=None, max_length=500)
