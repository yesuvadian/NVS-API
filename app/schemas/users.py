from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field


class TenantUserCreate(BaseModel):
    full_name: str = Field(min_length=2, max_length=200)
    mobile: str | None = Field(default=None, min_length=7, max_length=20)
    email: EmailStr | None = None
    role_code: str = Field(min_length=2, max_length=40)


class TenantUserOut(BaseModel):
    id: UUID
    full_name: str
    username: str | None
    email: str | None
    mobile: str | None
    status: str
    role_code: str | None
    locked_until: datetime | None
    must_change_password: bool


class TenantRoleOut(BaseModel):
    role_code: str
    role_name: str
