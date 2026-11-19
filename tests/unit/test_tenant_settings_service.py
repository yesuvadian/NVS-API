"""Unit tests for TenantSettingsService.page_size (no database)."""

import asyncio
from uuid import uuid4

from app.services.tenant_settings import TenantSettingsService


class FakeRepository:
    def __init__(self, row) -> None:
        self.row = row

    async def page_size(self):
        return self.row


def _service(row) -> TenantSettingsService:
    service = TenantSettingsService.__new__(TenantSettingsService)
    service.repo = FakeRepository(row)
    return service


ROW = {"page_size": 25, "pending_setting_id": uuid4(), "pending_page_size": 50}


def test_page_size_includes_pending_change_for_approvers() -> None:
    assert asyncio.run(_service(ROW).page_size(include_pending=True)) == ROW


def test_page_size_hides_pending_change_from_other_users() -> None:
    result = asyncio.run(_service(ROW).page_size(include_pending=False))
    assert result == {"page_size": 25, "pending_setting_id": None, "pending_page_size": None}
    assert ROW["pending_page_size"] == 50  # repository row not mutated
