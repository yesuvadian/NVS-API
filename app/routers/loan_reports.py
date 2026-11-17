"""Loan reports (scope 23.3): outstanding, interest, ageing and PAR, demand vs
collection, due and overdue lists, restructured and written-off loans, and
guarantor exposure. Each report is one loan.report_* routine in PostgreSQL.
"""

from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from psycopg import AsyncConnection

from app.core.errors import AppError
from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.services.loan_servicing import LoanServicingService

router = APIRouter(prefix="/loan-reports", tags=["loan reports"])
REPORT_PRIVILEGE = "mgmt_report.view"


def _service(conn: AsyncConnection) -> LoanServicingService:
    return LoanServicingService(conn)


def _period(date_from: date, date_to: date) -> None:
    if date_to < date_from:
        raise AppError("INVALID_DATE_RANGE")


@router.get("/outstanding")
async def outstanding(
    loan_type_id: UUID | None = None,
    status: str | None = Query(default=None, max_length=30),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    return await _service(conn).report("outstanding", loan_type_id, status)


@router.get("/interest")
async def interest(
    date_from: date = Query(alias="from"), date_to: date = Query(alias="to"),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    _period(date_from, date_to)
    return await _service(conn).report("interest", date_from, date_to)


@router.get("/ageing")
async def ageing(
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    return await _service(conn).report("ageing")


@router.get("/demand-collection")
async def demand_collection(
    date_from: date = Query(alias="from"), date_to: date = Query(alias="to"),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    _period(date_from, date_to)
    return await _service(conn).report("demand_collection", date_from, date_to)


@router.get("/due-list")
async def due_list(
    date_from: date | None = Query(default=None, alias="from"), date_to: date | None = Query(default=None, alias="to"),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    if date_from and date_to:
        _period(date_from, date_to)
    return await _service(conn).report("due_list", date_from, date_to)


@router.get("/overdue-list")
async def overdue_list(
    min_days: int = Query(default=1, ge=1, le=10000),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    return await _service(conn).report("overdue_list", min_days)


@router.get("/restructured-written-off")
async def restructured_written_off(
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    return await _service(conn).report("restructured_written_off")


@router.get("/guarantor-exposure")
async def guarantor_exposure(
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission(REPORT_PRIVILEGE)),
):
    return await _service(conn).report("guarantor_exposure")
