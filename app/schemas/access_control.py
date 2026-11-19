import datetime as dt
from uuid import UUID

from pydantic import BaseModel, Field


class TenantModuleOut(BaseModel):
    module_code: str
    module_name: str
    module_type: str
    parent_module_code: str | None = None
    menu_order: int | None = None
    is_core: bool
    is_optional_legal: bool
    is_enabled: bool
    reason: str | None = None
    row_version: int | None = None
    updated_at: dt.datetime | None = None


class ModuleToggle(BaseModel):
    enabled: bool
    reason: str = Field(min_length=3, max_length=500)
    legal_warning_ack: bool = False


class PrivilegeAction(BaseModel):
    privilege_code: str
    type_code: str
    name: str
    protected: bool = False


class MatrixModule(BaseModel):
    module_code: str
    module_name: str
    actions: list[PrivilegeAction] = []


class MatrixRole(BaseModel):
    id: UUID
    role_code: str
    role_name: str
    role_type: str
    status: str
    is_read_only: bool = False
    is_my_role: bool = False
    privileges: list[str] = []


class RolePrivilegeMatrixOut(BaseModel):
    can_edit: bool
    roles: list[MatrixRole] = []
    modules: list[MatrixModule] = []


class RolePrivilegeChange(BaseModel):
    granted: bool
    reason: str | None = Field(default=None, max_length=500)


class RolePrivilegeChangeOut(BaseModel):
    role_id: UUID
    role_code: str
    privilege_code: str
    granted: bool
    changed: bool
