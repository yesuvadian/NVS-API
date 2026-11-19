from fastapi import APIRouter, Depends
from psycopg import AsyncConnection

from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.schemas.dashboard import TenantSummaryOut
from app.services.dashboard import DashboardService

router = APIRouter(prefix="/tenant", tags=["dashboard"])


@router.get("/summary", response_model=TenantSummaryOut, response_model_exclude_none=True)
async def tenant_summary(
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    """Live Overview counts; only sections the user's privileges allow.
    Never 403 for a signed-in user: no matching privilege gives no sections."""
    return await DashboardService(conn).tenant_summary(principal.role_code)
