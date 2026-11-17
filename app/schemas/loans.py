from datetime import date, datetime
from decimal import Decimal
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class LoanApplicationCreate(BaseModel):
    member_id: UUID
    loan_type_id: UUID
    requested_amount: Decimal = Field(gt=0, decimal_places=2, max_digits=18)
    requested_tenure_months: int = Field(gt=0, le=600)
    purpose: str = Field(min_length=3, max_length=1000)
    nominee_ids: list[UUID] = Field(default_factory=list, max_length=10)


class LoanApplicationUpdate(BaseModel):
    requested_amount: Decimal | None = Field(default=None, gt=0, decimal_places=2, max_digits=18)
    requested_tenure_months: int | None = Field(default=None, gt=0, le=600)
    purpose: str | None = Field(default=None, min_length=3, max_length=1000)
    nominee_ids: list[UUID] | None = Field(default=None, max_length=10)
    expected_version: int | None = Field(default=None, ge=1)


class LoanEligibilityRequest(BaseModel):
    member_id: UUID
    loan_type_id: UUID
    requested_amount: Decimal = Field(gt=0, decimal_places=2, max_digits=18)
    requested_tenure_months: int = Field(gt=0, le=600)


class LoanFeePayment(BaseModel):
    payment_mode: str = Field(default="CASH", min_length=2, max_length=30)
    payment_reference: str | None = Field(default=None, max_length=120)


class LoanDecision(BaseModel):
    decision: Literal["APPROVED", "REJECTED", "RETURNED"]
    reason: str | None = Field(default=None, max_length=1000)
    approved_amount: Decimal | None = Field(default=None, gt=0, decimal_places=2, max_digits=18)
    tenure_months: int | None = Field(default=None, gt=0, le=600)


class LoanDisbursementCreate(BaseModel):
    gross_amount: Decimal = Field(gt=0, decimal_places=2, max_digits=18)
    payment_mode: str = Field(default="CASH", min_length=2, max_length=30)
    payment_reference: str | None = Field(default=None, max_length=100)


class LoanDisbursementRelease(BaseModel):
    payee_ack_type: Literal["SIGNATURE", "THUMB_IMPRESSION"]


class LoanRepaymentCreate(BaseModel):
    amount: Decimal = Field(gt=0, decimal_places=2, max_digits=18)
    payment_mode: str = Field(default="CASH", min_length=2, max_length=30)
    payment_reference: str | None = Field(default=None, max_length=120)


class SettlementQuoteRequest(BaseModel):
    interest_waiver: Decimal = Field(default=Decimal(0), ge=0, decimal_places=2, max_digits=18)
    waiver_reason: str | None = Field(default=None, max_length=1000)


class SettlementApproval(BaseModel):
    remarks: str | None = Field(default=None, max_length=1000)


class SettlementCollection(BaseModel):
    payment_mode: str = Field(default="CASH", min_length=2, max_length=30)
    payment_reference: str | None = Field(default=None, max_length=120)


class LoanTypeOut(BaseModel):
    id: UUID
    code: str
    name: str
    description: str | None = None
    interest_method: str
    is_interest_free: bool
    allows_tranches: bool
    rule_set_code: str
    rule_set_version_id: UUID
    rule_set_version_no: int
    effective_from: date
    terms: dict[str, Any]


class LoanEligibilityOut(BaseModel):
    eligible: bool
    reasons: list[str]
    first_loan: bool
    nominee_required: bool
    guarantors_required: int = 0
    application_fee: Decimal
    fee_timing: str | None = None
    interest_rate_annual: Decimal
    interest_method: Literal["FLAT", "NONE"]
    estimated_total_interest: Decimal
    estimated_instalment_amount: Decimal
    total_repayable: Decimal
    rule_set_version_id: UUID


class LoanOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    loan_no: str
    member_id: UUID
    member_no: str | None = None
    member_name: str | None = None
    loan_type_id: UUID
    loan_type_code: str | None = None
    loan_type_name: str | None = None
    purpose: str | None = None
    requested_amount: Decimal
    requested_tenure_months: int
    application_date: date
    status: str
    status_date: date | None = None
    is_first_loan: bool
    approved_amount: Decimal | None = None
    tenure_months: int | None = None
    interest_rate_annual: Decimal | None = None
    interest_method: str | None = None
    total_interest: Decimal | None = None
    instalment_amount: Decimal | None = None
    rule_set_version_id: UUID
    workflow_version_id: UUID
    created_at: datetime
    updated_at: datetime | None = None
    row_version: int
