from typing import Literal

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=1024)
    channel: Literal["WEB", "MOBILE"] = "WEB"
    force_logout: bool = False


class AuthenticatedUser(BaseModel):
    id: str
    display_name: str
    tenant_id: str | None
    role: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: Literal["bearer"]
    expires_in: int
    workspace: Literal["SUPER_ADMIN", "TENANT"]
    must_change_password: bool
    user: AuthenticatedUser


class InitialPasswordChangeRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=1024)
    new_password: str = Field(min_length=10, max_length=1024)


class PasswordChangeRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=1024)
    new_password: str = Field(min_length=10, max_length=1024)
