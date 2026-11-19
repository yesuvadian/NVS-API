from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from psycopg import AsyncConnection

from app.core.errors import AppError
from app.core.idempotency import IDEMPOTENCY_HEADER, run_idempotent, validate_key
from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.schemas.members import MemberCreate, MemberOut, MemberUpdate
from app.services.members import MemberService

router = APIRouter(prefix="/members", tags=["members"])


def _service(conn: AsyncConnection) -> MemberService:
    return MemberService(conn)


@router.get("")
async def list_members(
    q: str | None = Query(default=None, max_length=120),
    status_filter: Literal[
        "APPLIED", "ACTIVE", "INACTIVE", "SUSPENDED", "EXITED", "DECEASED"
    ]
    | None = Query(default=None, alias="status"),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.view")),
):
    rows = await _service(conn).list(
        query=q, status_filter=status_filter, limit=limit + 1, offset=offset
    )
    has_more = len(rows) > limit
    items = rows[:limit]
    return {
        "items": items,
        "limit": limit,
        "offset": offset,
        "has_more": has_more,
        "next_offset": offset + limit if has_more else None,
    }


@router.post("", response_model=MemberOut, status_code=201)
async def create_member(
    payload: MemberCreate,
    response: Response,
    idempotency_key: str | None = Header(default=None, alias=IDEMPOTENCY_HEADER, max_length=200),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.create")),
):
    """Register a member. A possible duplicate (same mobile, or same name and date of
    birth) is refused unless duplicate_override_reason is given. An optional
    Idempotency-Key makes a double-click return the first member."""
    values = payload.model_dump()
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=False), operation="mbr.create_member",
        payload=values, response=response, action=lambda: _service(conn).create(values))


@router.get("/{member_id}", response_model=MemberOut)
async def get_member(
    member_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.view")),
):
    return await _service(conn).get(member_id)


@router.patch("/{member_id}", response_model=MemberOut)
async def update_member(
    member_id: UUID,
    payload: MemberUpdate,
    expected_version: int | None = Header(default=None, alias="X-Expected-Row-Version", ge=1),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.edit")),
):
    """Change member details. X-Expected-Row-Version (the row_version the user
    opened) is required, so a save never silently overwrites another user's change."""
    if expected_version is None:
        raise AppError("ROW_VERSION_REQUIRED")
    changes = payload.model_dump(exclude_unset=True)
    if not set(changes) - {"duplicate_override_reason"}:
        raise AppError("MEMBER_CHANGES_REQUIRED")
    return await _service(conn).update(
        member_id, values=changes, expected_version=expected_version
    )
