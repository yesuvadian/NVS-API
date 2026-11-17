import hashlib
import hmac

from fastapi import Request
from psycopg import AsyncConnection

from app.core.config import Settings
from app.core.errors import AppError
from app.core.security import PlatformPrincipal
from app.core.tenant_security import TenantPrincipal


async def set_signed_platform_context(
    conn: AsyncConnection,
    principal: PlatformPrincipal,
    request: Request,
    settings: Settings,
) -> None:
    if settings.db_context_signing_key is None:
        raise AppError("CONTEXT_SIGNING_NOT_CONFIGURED")

    # Let PostgreSQL build the canonical payload so inet/date formatting matches
    # app.context_payload() exactly, then sign it with the deployment secret.
    client_ip = request.client.host if request.client else None
    await conn.execute(
        "SELECT app.set_platform_context(%s, NULL, %s, true, NULL)",
        (principal.user_id, client_ip),
    )
    row = await (await conn.execute("SELECT app.context_payload() AS payload")).fetchone()
    key = bytes.fromhex(settings.db_context_signing_key.get_secret_value())
    signature = hmac.new(key, row["payload"].encode("utf-8"), hashlib.sha256).hexdigest()
    await conn.execute("SELECT set_config('app.context_signature', %s, true)", (signature,))


async def set_signed_tenant_context(
    conn: AsyncConnection,
    principal: TenantPrincipal,
    request: Request,
    settings: Settings,
) -> None:
    if settings.db_context_signing_key is None:
        raise AppError("CONTEXT_SIGNING_NOT_CONFIGURED")

    client_ip = request.client.host if request.client else None
    await conn.execute(
        "SELECT app.set_context(%s, %s, %s, %s, %s, %s, %s, true, NULL)",
        (
            principal.tenant_id,
            principal.user_id,
            principal.role_code,
            principal.channel,
            principal.working_date,
            client_ip,
            principal.device,
        ),
    )
    row = await (await conn.execute("SELECT app.context_payload() AS payload")).fetchone()
    key = bytes.fromhex(settings.db_context_signing_key.get_secret_value())
    signature = hmac.new(key, row["payload"].encode("utf-8"), hashlib.sha256).hexdigest()
    await conn.execute("SELECT set_config('app.context_signature', %s, true)", (signature,))

