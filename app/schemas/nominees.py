from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

Relationship = Literal["SPOUSE", "SON", "DAUGHTER", "FATHER", "MOTHER", "BROTHER", "SISTER", "OTHER"]


class NomineeCreate(BaseModel):
    """The nominee is an existing member of the same organisation."""

    nominee_member_id: UUID
    relationship: Relationship
    # Holders of loan.nominee_override: reason to exceed NOMINATIONS.maxPerPerson.
    override_reason: str | None = Field(default=None, max_length=500)


class NomineeUpdate(BaseModel):
    relationship: Relationship


class NomineeStatusChange(BaseModel):
    status: Literal["ACTIVE", "INACTIVE", "DECEASED"]
    reason: str = Field(min_length=3, max_length=500)
    # Reactivate beyond the nomination limit (loan.nominee_override; reason is recorded).
    limit_override: bool = False


class NomineeOut(BaseModel):
    id: UUID
    member_id: UUID
    nominee_member_id: UUID | None = None
    nominee_member_no: str | None = None
    full_name: str
    relationship: str
    date_of_birth: date | None = None
    mobile: str | None = None
    status: str
    limit_override: bool = False
    limit_override_reason: str | None = None
    created_at: datetime
    updated_at: datetime | None = None
    row_version: int
