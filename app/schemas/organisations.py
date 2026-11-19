from typing import Annotated, Any
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, StringConstraints

OrgCode = Annotated[str, StringConstraints(pattern=r"^[a-z0-9][a-z0-9-]{1,62}$", to_lower=True)]
Mobile = Annotated[str, StringConstraints(min_length=7, max_length=20)]


class OrganisationCreate(BaseModel):
    code: OrgCode
    name: str = Field(min_length=2, max_length=200)
    admin_name: str = Field(min_length=2, max_length=160)
    admin_mobile: Mobile
    admin_email: EmailStr
    legal_name: str | None = Field(default=None, max_length=250)
    registration_no: str | None = Field(default=None, max_length=100)
    address: dict[str, Any] = Field(default_factory=dict)
    optional_modules: list[str] = Field(default_factory=list, max_length=40)
    features: list[str] = Field(default_factory=list, max_length=40)
    is_sandbox: bool = False
    time_zone: str = "Asia/Kolkata"
    currency_code: str = Field(default="INR", min_length=3, max_length=3, pattern=r"^[A-Z]{3}$")
    data_region: str = Field(default="IN", min_length=2, max_length=8, pattern=r"^[A-Z]{2,8}$")
    settings: dict[str, Any] = Field(default_factory=dict)
    password_history_count: int = Field(default=5, ge=1, le=24)
    single_session_enabled: bool = False


class OrganisationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    code: str
    name: str
    legal_name: str | None = None
    status: str
    is_sandbox: bool
    time_zone: str
    contact_email: str | None = None
    contact_mobile: str | None = None
    created_at: datetime


class OrganisationStatusChange(BaseModel):
    enabled: bool
    reason: str = Field(min_length=3, max_length=500)

