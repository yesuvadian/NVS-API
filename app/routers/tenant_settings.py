from uuid import UUID

from fastapi import APIRouter, Depends
from psycopg import AsyncConnection

from app.core.errors import AppError
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
    if principal.role_code not in {'ADM', 'LDR'}:
        raise AppError('NO_PRIVILEGE', params={'privilege': 'org.view'})
    return await TenantSettingsService(conn).page_size()


@router.put('/page-size', response_model=PageSizeOut)
async def request_page_size(
    payload: PageSizeUpdate,
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    if principal.role_code != 'ADM':
        raise AppError('NO_PRIVILEGE', params={'privilege': 'org.edit'})
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
    principal: TenantPrincipal = Depends(require_tenant_user),
    conn: AsyncConnection = Depends(get_tenant_db),
):
    if principal.role_code != 'LDR':
        raise AppError('NO_PRIVILEGE', params={'privilege': 'org.approve'})
    await TenantSettingsService(conn).decide_page_size(setting_id, payload.approve, payload.reason)
