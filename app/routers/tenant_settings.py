from uuid import UUID

from fastapi import APIRouter, Depends
from psycopg import AsyncConnection

from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.schemas.tenant_settings import PageSizeDecision, PageSizeOut, PageSizeUpdate
from app.services.tenant_settings import TenantSettingsService

router = APIRouter(prefix='/tenant-settings', tags=['tenant-settings'])


@router.get('/page-size', response_model=PageSizeOut)
async def get_page_size(
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    # Every signed-in user needs the rows-per-page setting for lists; only
    # Org Admin and Leadership see a pending change awaiting approval.
    return await TenantSettingsService(conn).page_size(
        include_pending=principal.role_code in {'ADM', 'LDR'}
    )


@router.put('/page-size', response_model=PageSizeOut)
async def request_page_size(
    payload: PageSizeUpdate,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission('org.edit')),
):
    result = await TenantSettingsService(conn).request_page_size(payload.page_size)
    return {
        'page_size': result['page_size'],
        'pending_setting_id': result['setting_id'],
        'pending_page_size': result['page_size'] if result['status'] == 'PENDING_APPROVAL' else None,
        'status': result['status'],
    }


@router.post('/page-size/{setting_id}/decision', status_code=204)
async def decide_page_size(
    setting_id: UUID,
    payload: PageSizeDecision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission('org.approve')),
):
    await TenantSettingsService(conn).decide_page_size(setting_id, payload.approve, payload.reason)
