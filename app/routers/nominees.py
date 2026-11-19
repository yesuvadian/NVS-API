"""Member nominees. A nominee is an existing member of the same organisation.

Every new loan application needs an ACTIVE nominee (loan-type NOMINEE rule),
and a person can be an active nominee for at most MEMBER_RULES / NOMINATIONS
maxPerPerson members (default 2).
"""

from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from psycopg import AsyncConnection

from app.core.idempotency import IDEMPOTENCY_HEADER, run_idempotent, validate_key
from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.schemas.nominees import NomineeCreate, NomineeOut, NomineeStatusChange, NomineeUpdate
from app.services.nominees import NomineeService

router = APIRouter(tags=["member nominees"])

ROW_VERSION_HEADER = "X-Expected-Row-Version"


@router.get("/members/{member_id}/nominees", response_model=list[NomineeOut])
async def list_nominees(
    member_id: UUID,
    include_inactive: bool = Query(default=False),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.view")),
):
    return await NomineeService(conn).list(member_id, include_inactive=include_inactive)


@router.post("/members/{member_id}/nominees", response_model=NomineeOut, status_code=201)
async def add_nominee(
    member_id: UUID,
    payload: NomineeCreate,
    response: Response,
    idempotency_key: str | None = Header(default=None, alias=IDEMPOTENCY_HEADER, max_length=200),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.edit")),
):
    """Nominate an existing member. An optional Idempotency-Key makes a retry
    return the first nomination instead of failing as a duplicate."""
    values = {"member_id": str(member_id), **payload.model_dump(mode="json")}
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=False), operation="mbr.add_nominee",
        payload=values, response=response,
        action=lambda: NomineeService(conn).add(
            member_id, payload.nominee_member_id, payload.relationship, payload.override_reason),
    )


@router.patch("/member-nominees/{nominee_id}", response_model=NomineeOut)
async def update_nominee(
    nominee_id: UUID,
    payload: NomineeUpdate,
    expected_version: int | None = Header(default=None, alias=ROW_VERSION_HEADER, ge=1),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.edit")),
):
    """Change the relationship. X-Expected-Row-Version is required."""
    return await NomineeService(conn).update(nominee_id, payload.relationship, expected_version)


@router.post("/member-nominees/{nominee_id}/status", response_model=NomineeOut)
async def set_nominee_status(
    nominee_id: UUID,
    payload: NomineeStatusChange,
    expected_version: int | None = Header(default=None, alias=ROW_VERSION_HEADER, ge=1),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.edit")),
):
    """Deactivate, mark deceased or reactivate (limits apply on reactivation)."""
    return await NomineeService(conn).set_status(
        nominee_id, payload.status, expected_version, payload.reason, payload.limit_override)
