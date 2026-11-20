"""Database function wrappers for Super Admin governed configuration."""

from uuid import UUID

from psycopg import AsyncConnection
from psycopg.types.json import Jsonb


class SuperAdminConfigurationRepository:
    def __init__(self, conn: AsyncConnection):
        self.conn = conn

    async def list_for_organisation(self, tenant_id: UUID) -> dict:
        row = await (await self.conn.execute(
            "SELECT platform.get_super_admin_configurations(%s) AS result", (tenant_id,)
        )).fetchone()
        return row["result"]

    async def validate(self, tenant_id: UUID, kind: str, code: str, definition: dict) -> dict:
        row = await (await self.conn.execute(
            "SELECT platform.validate_super_admin_configuration(%s,%s,%s,%s) AS result",
            (tenant_id, kind, code, Jsonb(definition)),
        )).fetchone()
        return row["result"]

    async def publish(self, tenant_id: UUID, kind: str, code: str, definition: dict,
                      reason: str, effective_from) -> dict:
        row = await (await self.conn.execute(
            "SELECT platform.publish_super_admin_configuration(%s,%s,%s,%s,%s,%s) AS result",
            (tenant_id, kind, code, Jsonb(definition), reason, effective_from),
        )).fetchone()
        return row["result"]
