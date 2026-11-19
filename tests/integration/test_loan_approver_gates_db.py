"""PostgreSQL integration tests for the loan decision gates and loan error texts.

The write-off and repayment-reversal decision endpoints are gated by a *view*
privilege on purpose: the approvers (Leadership for write-offs, Accountant and
Manager for reversals) hold only view on those modules, and the database
enforces the approver role and self-approval (loan.assert_approver,
loan.decide_repayment_reversal). Gating on .approve would lock them out.
"""

from __future__ import annotations

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


def test_decision_approvers_hold_the_view_privilege_the_endpoint_checks():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, None, t.today)

        async def has(role: str, privilege: str) -> bool:
            return await db.val("SELECT iam.has_privilege(%s,%s)", (t.users[role], privilege))

        # Write-off decision: endpoint checks loan_default.view; LDR approves.
        assert await has("LDR", "loan_default.view")
        assert not await has("LDR", "loan_default.approve")
        # Reversal decision: endpoint checks loan_repay.view; ACC approves.
        assert await has("ACC", "loan_repay.view")
        assert not await has("ACC", "loan_repay.approve")

    run_db(scenario)


def test_every_loan_and_repayment_error_has_tamil_text():
    async def scenario(db: LoanDb):
        missing = await db.rows(
            """SELECT short_code FROM platform.error_code
                WHERE module IN ('LOAN','REPAY') AND NOT coalesce(translations ? 'ta', false)
                ORDER BY short_code""")
        assert [r["short_code"] for r in missing] == []

    run_db(scenario)
