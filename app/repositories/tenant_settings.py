from uuid import UUID

from psycopg import AsyncConnection


class TenantSettingsRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def page_size(self) -> dict:
        row = await (await self.conn.execute(
            'SELECT * FROM cfg.get_ui_page_size()'
        )).fetchone()
        return dict(row) if row else {'page_size': 15, 'pending_setting_id': None, 'pending_page_size': None}

    async def request_page_size(self, page_size: int) -> dict:
        row = await (await self.conn.execute(
            'SELECT * FROM cfg.request_ui_page_size(%s)', (page_size,)
        )).fetchone()
        return dict(row)

    async def decide_page_size(self, setting_id: UUID, approve: bool, reason: str | None) -> None:
        await self.conn.execute(
            'SELECT cfg.decide_ui_page_size(%s,%s,%s)', (setting_id, approve, reason)
        )
