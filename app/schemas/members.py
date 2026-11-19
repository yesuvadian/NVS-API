from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class MemberCreate(BaseModel):
    full_name: str = Field(min_length=2, max_length=200)
    date_of_birth: date | None = None
    gender: Literal["MALE", "FEMALE", "OTHER", "UNDISCLOSED"] | None = None
    mobile: str | None = Field(default=None, min_length=7, max_length=20)
    alt_mobile: str | None = Field(default=None, min_length=7, max_length=20)
    email: EmailStr | None = None
    address_line1: str | None = Field(default=None, max_length=250)
    address_line2: str | None = Field(default=None, max_length=250)
    city: str | None = Field(default=None, max_length=120)
    district: str | None = Field(default=None, max_length=120)
    state: str | None = Field(default=None, max_length=120)
    pincode: str | None = Field(default=None, max_length=20)
    # Validated against platform.language; omitted means the platform default.
    preferred_language: str | None = Field(default=None, pattern=r"^[a-z]{2,3}$")
    preferred_channel: Literal["SMS", "WHATSAPP", "EMAIL", "NONE"] = "SMS"
    notes: str | None = Field(default=None, max_length=2000)
    # Confirms that a possible duplicate (same mobile, or same name and date of
    # birth) is a different person; recorded in the audit trail.
    duplicate_override_reason: str | None = Field(default=None, min_length=3, max_length=500)


class MemberUpdate(BaseModel):
    full_name: str | None = Field(default=None, min_length=2, max_length=200)
    date_of_birth: date | None = None
    gender: Literal["MALE", "FEMALE", "OTHER", "UNDISCLOSED"] | None = None
    mobile: str | None = Field(default=None, min_length=7, max_length=20)
    alt_mobile: str | None = Field(default=None, min_length=7, max_length=20)
    email: EmailStr | None = None
    address_line1: str | None = Field(default=None, max_length=250)
    address_line2: str | None = Field(default=None, max_length=250)
    city: str | None = Field(default=None, max_length=120)
    district: str | None = Field(default=None, max_length=120)
    state: str | None = Field(default=None, max_length=120)
    pincode: str | None = Field(default=None, max_length=20)
    preferred_language: str | None = Field(default=None, pattern=r"^[a-z]{2,3}$")
    preferred_channel: Literal["SMS", "WHATSAPP", "EMAIL", "NONE"] | None = None
    notes: str | None = Field(default=None, max_length=2000)
    duplicate_override_reason: str | None = Field(default=None, min_length=3, max_length=500)


class MemberOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    member_no: str
    full_name: str
    date_of_birth: date | None = None
    gender: str | None = None
    mobile: str | None = None
    alt_mobile: str | None = None
    email: str | None = None
    address_line1: str | None = None
    address_line2: str | None = None
    city: str | None = None
    district: str | None = None
    state: str | None = None
    pincode: str | None = None
    membership_date: date | None = None
    status: str
    loan_eligibility: str
    preferred_language: str
    preferred_channel: str
    previous_member_id: UUID | None = None
    created_at: datetime
    updated_at: datetime | None = None
    row_version: int
