import datetime as dt
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel


class OrganisationStatusCounts(BaseModel):
    ACTIVE: int = 0
    PROVISIONING: int = 0
    SUSPENDED: int = 0
    CLOSED: int = 0


class OrganisationCounts(BaseModel):
    total: int = 0
    by_status: OrganisationStatusCounts = OrganisationStatusCounts()


class NewestOrganisation(BaseModel):
    id: UUID
    code: str
    name: str
    status: str
    created_at: dt.datetime


class PlatformSummaryOut(BaseModel):
    organisations: OrganisationCounts
    newest_organisations: list[NewestOrganisation] = []


class MemberSummary(BaseModel):
    total: int = 0
    active: int = 0


class LoanSummary(BaseModel):
    open_applications: int = 0


class ApprovalSummary(BaseModel):
    pending: int = 0


class CollectionSummary(BaseModel):
    date: dt.date | None = None
    count: int = 0
    amount: Decimal = Decimal("0")


class AdministrationSummary(BaseModel):
    active_users: int = 0
    locked_users: int = 0
    must_change_password: int = 0
    pending_setting_approvals: int = 0


class TenantSummaryOut(BaseModel):
    working_date: dt.date | None = None
    sections: list[str]
    members: MemberSummary | None = None
    loans: LoanSummary | None = None
    approvals: ApprovalSummary | None = None
    collections: CollectionSummary | None = None
    administration: AdministrationSummary | None = None
