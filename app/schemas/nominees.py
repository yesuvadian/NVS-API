from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

Relationship = Literal["SPOUSE", "SON", "DAUGHTER", "FATHER", "MOTHER", "BROTHER", "SISTER", "OTHER"]


class NomineeCreate(BaseModel):
    """The nominee is an existing member of the same organisation."""

    nominee_member_id: UUID
    relationship: Relationship


class NomineeUpdate(BaseModel):
    relationship: Relationship


class NomineeStatusChange(BaseModel):
    status: Literal["ACTIVE", "INACTIVE", "DECEASED"]
    reason: str = Field(min_length=3, max_length=500)


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
    created_at: datetime
    updated_at: datetime | None = None
    row_version: int
