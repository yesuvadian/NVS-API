from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from psycopg import AsyncConnection

from app.repositories.dashboard import DashboardRepository

# Overview section -> privileges, any of which shows it. Order is display order.
TENANT_SECTION_PRIVILEGES: dict[str, frozenset[str]] = {
    "members": frozenset({"member.view"}),
    "loans": frozenset({"loan.view"}),
    "approvals": frozenset({"loan.approve"}),
    "collections": frozenset({"loan_repay.view"}),
    "administration": frozenset({"user_role.view", "org.view"}),
}


def visible_sections(privileges: Iterable[str]) -> list[str]:
    """Sections of the tenant Overview the holder of these privileges may see."""
    held = set(privileges)
    return [section for section, needed in TENANT_SECTION_PRIVILEGES.items() if held & needed]


class DashboardService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = DashboardRepository(conn)

    async def platform_summary(self) -> dict[str, Any]:
        return await self.repository.platform_summary()

    async def tenant_summary(self, role_code: str) -> dict[str, Any]:
        """The Overview never refuses a signed-in user: without any matching
        privilege it returns no sections."""
        sections = visible_sections(await self.repository.tenant_privileges(role_code))
        if not sections:
            return {"working_date": None, "sections": []}
        summary = await self.repository.tenant_summary(sections)
        # Only the sections the user may see, even if the database returns more.
        return {
            "working_date": summary.get("working_date"),
            "sections": sections,
            **{section: summary.get(section) for section in sections},
        }
