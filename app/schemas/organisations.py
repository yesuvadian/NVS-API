from typing import Annotated
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
    optional_modules: list[str] = Field(default_factory=list, max_length=40)
    features: list[str] = Field(default_factory=list, max_length=40)
    is_sandbox: bool = False
    time_zone: str = "Asia/Kolkata"


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

