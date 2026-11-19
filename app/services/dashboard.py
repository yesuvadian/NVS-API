from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.repositories.dashboard import DashboardRepository

# Overview section -> privilege needed to see it. Order is the display order.
TENANT_SECTION_PRIVILEGES: dict[str, str] = {
    "members": "member.view",
    "loans": "loan.view",
    "approvals": "loan.approve",
    "collections": "loan_repay.view",
}


def visible_sections(privileges: Iterable[str]) -> list[str]:
    """Sections of the tenant Overview the holder of these privileges may see."""
    held = set(privileges)
    return [section for section, privilege in TENANT_SECTION_PRIVILEGES.items() if privilege in held]


class DashboardService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = DashboardRepository(conn)

    async def platform_summary(self) -> dict[str, Any]:
        return await self.repository.platform_summary()

    async def tenant_summary(self, role_code: str) -> dict[str, Any]:
        sections = visible_sections(await self.repository.tenant_privileges(role_code))
        if not sections:
            raise AppError(
                "NO_PRIVILEGE",
                params={"privilege": " / ".join(TENANT_SECTION_PRIVILEGES.values())},
            )
        summary = await self.repository.tenant_summary(sections)
        # Only the sections the user may see, even if the database returns more.
        return {
            "working_date": summary.get("working_date"),
            "sections": sections,
            **{section: summary.get(section) for section in sections},
        }
