from app.repositories.tenant_settings import TenantSettingsRepository


class TenantSettingsService:
    def __init__(self, conn) -> None:
        self.repo = TenantSettingsRepository(conn)

    async def page_size(self) -> dict:
        return await self.repo.page_size()

    async def request_page_size(self, page_size: int) -> dict:
        return await self.repo.request_page_size(page_size)

    async def decide_page_size(self, setting_id, approve: bool, reason: str | None) -> None:
        await self.repo.decide_page_size(setting_id, approve, reason)
