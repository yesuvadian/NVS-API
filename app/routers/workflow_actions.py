from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from psycopg import AsyncConnection

from app.core.errors import AppError
from app.core.idempotency import IDEMPOTENCY_HEADER, run_idempotent, validate_key
from app.core.security import PlatformPrincipal
from app.core.permissions import require_platform_permission
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_platform_db, get_tenant_db
from app.schemas.workflow import WorkflowTransitionInput
from app.services.workflow_actions import WorkflowActionService

router = APIRouter(tags=["workflow-actions"])


@router.get("/super-admin/workflow-actions")
async def list_workflow_action_registry(
    entity: str | None = Query(default=None, max_length=40),
    event: str | None = Query(default=None, max_length=40),
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("config:can_view")),
) -> list[dict[str, Any]]:
    """Approved action definitions available to the Super Admin workflow editor."""
    return await WorkflowActionService(conn).registry(entity, event)


@router.get("/loans/{loan_id}/actions")
async def list_loan_workflow_actions(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_user),
) -> dict[str, Any]:
    """Current workflow buttons, filtered by the record, rules, and actor."""
    return await WorkflowActionService(conn).list_actions("loan", loan_id)


@router.post("/loans/{loan_id}/transitions/{code}")
async def perform_loan_workflow_transition(
    loan_id: UUID,
    code: str,
    payload: WorkflowTransitionInput,
    response: Response,
    expected_version: int | None = Header(default=None, alias="X-Expected-Row-Version", ge=1),
    idempotency_key: str | None = Header(default=None, alias=IDEMPOTENCY_HEADER, max_length=200),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_user),
) -> dict[str, Any]:
    if expected_version is None:
        raise AppError("ROW_VERSION_REQUIRED")
    key = validate_key(idempotency_key, required=True)
    values = payload.model_dump(mode="json")["input"]
    return await run_idempotent(
        conn,
        key=key,
        operation="workflow.transition",
        payload={"loan_id": loan_id, "code": code, "row_version": expected_version, "input": values},
        response=response,
        action=lambda: WorkflowActionService(conn).perform(
            "loan", loan_id, code, values, expected_version
        ),
    )
