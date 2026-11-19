from typing import Literal
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Path, Query, status
from psycopg import AsyncConnection

from app.core.permissions import require_platform_permission
from app.core.security import PlatformPrincipal
from app.db.dependencies import get_platform_db
from app.schemas.access_control import ModuleToggle, TenantModuleOut
from app.schemas.dashboard import PlatformSummaryOut
from app.schemas.organisations import OrganisationCreate, OrganisationOut, OrganisationStatusChange
from app.schemas.translations import TranslationEntryUpdate, TranslationPackOut
from app.services.access_control import AccessControlService
from app.services.dashboard import DashboardService
from app.services.organisations import OrganisationService
from app.services.translations import TranslationService

router = APIRouter(prefix="/super-admin", tags=["super-admin"])


def _org_service(conn: AsyncConnection) -> OrganisationService:
    return OrganisationService(conn)


@router.get("/summary", response_model=PlatformSummaryOut)
async def platform_summary(
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_view")),
):
    """Organisation counts by status and the five newest organisations."""
    return await DashboardService(conn).platform_summary()


@router.get("/organisations", response_model=list[OrganisationOut])
async def list_organisations(
    q: str | None = Query(default=None, max_length=120),
    status_filter: Literal["PROVISIONING", "ACTIVE", "SUSPENDED", "CLOSED"] | None = Query(
        default=None, alias="status"
    ),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_view")),
):
    return await _org_service(conn).list(query=q, status_filter=status_filter, limit=limit, offset=offset)


@router.get("/organisations/setup-options")
async def organisation_setup_options(
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_add")),
) -> dict[str, Any]:
    """Published defaults, module catalogue, features, and editable settings for the create wizard."""
    return await _org_service(conn).setup_options()


@router.get("/organisations/{tenant_id}", response_model=OrganisationOut)
async def get_organisation(
    tenant_id: UUID,
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_view")),
):
    return await _org_service(conn).get(tenant_id)


@router.post("/organisations", response_model=OrganisationOut, status_code=status.HTTP_201_CREATED)
async def create_organisation(
    payload: OrganisationCreate,
    principal: PlatformPrincipal = Depends(require_platform_permission("tenants:can_add")),
    conn: AsyncConnection = Depends(get_platform_db),
):
    return await _org_service(conn).create(payload, principal.user_id)


@router.patch("/organisations/{tenant_id}/status")
async def set_organisation_status(
    tenant_id: UUID,
    payload: OrganisationStatusChange,
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_edit")),
):
    return await _org_service(conn).set_enabled(
        tenant_id, payload.enabled, payload.reason
    )


@router.get("/organisations/{tenant_id}/modules", response_model=list[TenantModuleOut])
async def list_organisation_modules(
    tenant_id: UUID,
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_view")),
):
    """Menu modules with the organisation's enabled flag."""
    return await AccessControlService(conn).list_modules(tenant_id)


@router.put("/organisations/{tenant_id}/modules/{module_code}", response_model=TenantModuleOut)
async def set_organisation_module(
    tenant_id: UUID,
    payload: ModuleToggle,
    module_code: str = Path(pattern=r"^[A-Za-z_]+$", max_length=40),
    expected_version: int | None = Header(default=None, alias="X-Expected-Row-Version", ge=1),
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("tenants:can_edit")),
):
    """Enable or disable one module. Send X-Expected-Row-Version (the module's
    row_version) to refuse the change with STALE_RECORD if someone else changed
    it first. Core modules cannot be disabled, nor modules with open items."""
    return await AccessControlService(conn).set_module(
        tenant_id, module_code, enabled=payload.enabled, reason=payload.reason,
        expected_version=expected_version, legal_warning_ack=payload.legal_warning_ack,
    )


@router.get("/language-packs/{language_code}", response_model=list[TranslationPackOut])
async def list_language_packs(
    language_code: str,
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("language_packs:can_view")),
):
    return await TranslationService(conn).list_packs(language_code)


@router.post("/language-packs/{language_code}/draft", status_code=status.HTTP_201_CREATED)
async def create_language_pack_draft(
    language_code: str,
    principal: PlatformPrincipal = Depends(require_platform_permission("language_packs:can_add")),
    conn: AsyncConnection = Depends(get_platform_db),
):
    version_no = await TranslationService(conn).create_draft(language_code, principal.user_id)
    return {"language_code": language_code, "version_no": version_no, "status": "DRAFT"}


@router.get("/language-packs/{language_code}/{version_no}/translations")
async def list_translations(
    language_code: str,
    version_no: int,
    q: str | None = Query(default=None, max_length=200),
    module_code: str | None = Query(default=None, max_length=80),
    text_type: Literal["PAGE", "LABEL", "MESSAGE", "MASTER_DATA"] | None = None,
    entry_status: Literal["DRAFT", "APPROVED", "MISSING"] | None = Query(default=None, alias="status"),
    missing_only: bool = False,
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_platform_db),
    _permission: PlatformPrincipal = Depends(require_platform_permission("language_packs:can_view")),
):
    return await TranslationService(conn).list_entries(
        language_code=language_code,
        version_no=version_no,
        query=q,
        module_code=module_code,
        text_type=text_type,
        status=entry_status,
        missing_only=missing_only,
        limit=limit,
        offset=offset,
    )


@router.put("/language-packs/{language_code}/{version_no}/translations/{text_id}")
async def update_translation(
    language_code: str,
    version_no: int,
    text_id: str,
    payload: TranslationEntryUpdate,
    principal: PlatformPrincipal = Depends(require_platform_permission("language_packs:can_edit")),
    conn: AsyncConnection = Depends(get_platform_db),
):
    return await TranslationService(conn).save_entry(
        language_code=language_code,
        version_no=version_no,
        text_id=text_id,
        translated_text=payload.translated_text,
        status=payload.status,
        user_id=principal.user_id,
    )


@router.post("/language-packs/{language_code}/{version_no}/publish")
async def publish_language_pack(
    language_code: str,
    version_no: int,
    principal: PlatformPrincipal = Depends(require_platform_permission("language_packs:can_approve")),
    conn: AsyncConnection = Depends(get_platform_db),
):
    return await TranslationService(conn).publish(language_code, version_no, principal.user_id)

