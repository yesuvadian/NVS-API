from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query
from psycopg import AsyncConnection

from app.core.errors import AppError
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
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("member.create")),
):
    return await _service(conn).create(payload.model_dump())


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
    changes = payload.model_dump(exclude_unset=True)
    if not changes:
        raise AppError("MEMBER_CHANGES_REQUIRED")
    return await _service(conn).update(
        member_id, values=changes, expected_version=expected_version
    )
