"""PostgreSQL integration tests: every signed tenant user can read the
organisation's rows-per-page setting (cfg.get_ui_page_size)."""

from __future__ import annotations

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


def test_staff_user_reads_their_organisations_page_size():
    async def scenario(db: LoanDb):
        first = await db.new_tenant()
        second = await db.new_tenant()

        await db.act(first, "EMP", first.d0)
        assert await db.val("SELECT page_size FROM cfg.get_ui_page_size()") == 15

        await db.set_setting(first, "ui.page_size", 25)
        await db.act(first, "EMP", first.d0)
        assert await db.val("SELECT page_size FROM cfg.get_ui_page_size()") == 25

        await db.act(second, "EMP", second.d0)
        assert await db.val("SELECT page_size FROM cfg.get_ui_page_size()") == 15

    run_db(scenario)
