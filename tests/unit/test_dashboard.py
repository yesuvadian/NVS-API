"""Unit tests for the Overview dashboard service and schemas (no database)."""

import asyncio
from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import uuid4

import pytest

from app.core.errors import AppError
from app.schemas.dashboard import PlatformSummaryOut, TenantSummaryOut
from app.services.dashboard import DashboardService, visible_sections


class FakeRepository:
    def __init__(self, *, privileges=None, summary=None, platform=None) -> None:
        self.privileges = privileges or []
        self.summary = summary or {}
        self.platform = platform or {}
        self.requested_sections: list[str] | None = None
        self.role_code: str | None = None

    async def tenant_privileges(self, role_code):
        self.role_code = role_code
        return self.privileges

    async def tenant_summary(self, sections):
        self.requested_sections = sections
        return self.summary

    async def platform_summary(self):
        return self.platform


def _service(repository: FakeRepository) -> DashboardService:
    service = DashboardService.__new__(DashboardService)
    service.repository = repository
    return service


def test_visible_sections_follow_privileges_in_display_order() -> None:
    assert visible_sections(["loan_repay.view", "member.view", "member.create"]) == ["members", "collections"]
    assert visible_sections(["loan.view", "loan.approve"]) == ["loans", "approvals"]
    assert visible_sections([]) == []


def test_tenant_summary_requests_and_returns_only_permitted_sections() -> None:
    repository = FakeRepository(
        privileges=["member.view", "loan.approve"],
        summary={
            "working_date": "2026-11-19",
            "members": {"total": 4, "active": 3},
            "approvals": {"pending": 2},
            # extra section the user may not see must be dropped
            "collections": {"date": "2026-11-19", "count": 1, "amount": 500},
        },
    )

    result = asyncio.run(_service(repository).tenant_summary("MGR"))

    assert repository.role_code == "MGR"
    assert repository.requested_sections == ["members", "approvals"]
    assert result == {
        "working_date": "2026-11-19",
        "sections": ["members", "approvals"],
        "members": {"total": 4, "active": 3},
        "approvals": {"pending": 2},
    }


def test_tenant_summary_without_any_view_privilege_is_refused() -> None:
    repository = FakeRepository(privileges=["member.create"])

    with pytest.raises(AppError) as error:
        asyncio.run(_service(repository).tenant_summary("EMP"))

    assert error.value.short_code == "NO_PRIVILEGE"
    assert error.value.status_code == 403
    assert repository.requested_sections is None


def test_platform_summary_passes_through_repository_result() -> None:
    payload = {"organisations": {"total": 1}, "newest_organisations": []}
    assert asyncio.run(_service(FakeRepository(platform=payload)).platform_summary()) == payload


def test_platform_summary_schema_fills_missing_status_counts() -> None:
    created = datetime(2026, 11, 1, tzinfo=UTC)
    summary = PlatformSummaryOut.model_validate({
        "organisations": {"total": 2, "by_status": {"ACTIVE": 2}},
        "newest_organisations": [
            {"id": str(uuid4()), "code": "demo", "name": "Demo", "status": "ACTIVE", "created_at": created},
        ],
    })
    assert summary.organisations.by_status.CLOSED == 0
    assert summary.newest_organisations[0].code == "demo"


def test_tenant_summary_schema_parses_amounts_and_omits_hidden_sections() -> None:
    summary = TenantSummaryOut.model_validate({
        "working_date": "2026-11-19",
        "sections": ["collections"],
        "collections": {"date": "2026-11-19", "count": 3, "amount": "1250.50"},
    })
    assert summary.collections.amount == Decimal("1250.50")
    assert summary.collections.date == date(2026, 11, 19)
    assert "members" not in summary.model_dump(exclude_none=True)
