from typing import Any
from uuid import UUID

from psycopg import AsyncConnection
from psycopg.types.json import Jsonb


def _override_fields(override: dict[str, Any] | None) -> dict[str, Any]:
    return {
        "nominee_override": override is not None,
        "nominee_override_reason": override["nominee_override_reason"] if override else None,
        "nominee_override_by": override["nominee_override_by"] if override else None,
        "nominee_override_by_name": override["nominee_override_by_name"] if override else None,
        "nominee_override_at": override["nominee_override_at"] if override else None,
    }


class LoanRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def list_types(self) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_active_loan_types()"
        )
        return await cursor.fetchall()

    async def get_type(self, loan_type_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_active_loan_types(%s)",
            (loan_type_id,),
        )
        return await cursor.fetchone()

    async def member_eligibility_context(self, member_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_member_eligibility_context(%s)",
            (member_id,),
        )
        return await cursor.fetchone()

    async def member_exposure(self, member_id: UUID, loan_type_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT loan.get_member_exposure(%s,%s) AS exposure", (member_id, loan_type_id)
        )
        row = await cursor.fetchone()
        return row["exposure"] if row else None

    async def loan_settings(self) -> dict[str, Any]:
        cursor = await self.conn.execute("SELECT * FROM loan.get_loan_settings()")
        return await cursor.fetchone()

    async def list_applications(
        self,
        *,
        query: str | None,
        status: str | None,
        member_id: UUID | None,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.search_applications(%s,%s,%s,%s,%s)",
            (query, status, member_id, limit, offset),
        )
        return await cursor.fetchall()

    async def get_application(self, loan_id: UUID, *, lock: bool = False) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_application(%s,%s)",
            (loan_id, lock),
        )
        row = await cursor.fetchone()
        if row is None:
            return None
        overrides = await self.nominee_overrides([loan_id])
        return {**row, **_override_fields(overrides.get(loan_id))}

    async def nominee_overrides(self, loan_ids: list[UUID]) -> dict[UUID, dict[str, Any]]:
        """Nominee overrides recorded at submission (db/31f), by loan id."""
        if not loan_ids:
            return {}
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_nominee_overrides(%s::uuid[])", (list(loan_ids),)
        )
        return {row["loan_id"]: row for row in await cursor.fetchall()}

    async def has_privilege(self, privilege_code: str) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.has_privilege(app.user_id(), %s) AS allowed", (privilege_code,)
        )).fetchone()
        return bool(row and row["allowed"])

    async def record_nominee_override(self, loan_id: UUID, reason: str) -> dict[str, Any]:
        row = await (await self.conn.execute(
            "SELECT loan.record_nominee_override(%s,%s) AS result", (loan_id, reason)
        )).fetchone()
        return row["result"]

    async def nominee_status(self, loan_id: UUID) -> dict[str, Any]:
        row = await (await self.conn.execute(
            "SELECT loan.nominee_status(%s) AS result", (loan_id,)
        )).fetchone()
        return row["result"]

    async def set_application_nominees(
        self, loan_id: UUID, nominee_ids: list[UUID], expected_version: int
    ) -> dict[str, Any]:
        row = await (await self.conn.execute(
            "SELECT loan.set_application_nominees(%s,%s::uuid[],%s) AS result",
            (loan_id, list(nominee_ids), expected_version),
        )).fetchone()
        return row["result"]

    async def member_past_default(self, member_id: UUID, lookback_months: int | None) -> str | None:
        """Loan number of the member's current or recent default (db/31g)."""
        row = await (await self.conn.execute(
            "SELECT loan.member_past_default(%s,%s) AS loan_no", (member_id, lookback_months)
        )).fetchone()
        return row["loan_no"] if row else None

    async def loan_for_approval_request(self, request_id: UUID) -> UUID | None:
        row = await (await self.conn.execute(
            "SELECT loan.loan_for_approval_request(%s) AS loan_id", (request_id,)
        )).fetchone()
        return row["loan_id"] if row else None

    async def application_nominee_count(self, loan_id: UUID) -> int:
        cursor = await self.conn.execute(
            # Only nominees still ACTIVE count towards the nominee rule (db/31d).
            "SELECT loan.count_active_application_nominees(%s) AS nominee_count",
            (loan_id,),
        )
        row = await cursor.fetchone()
        return row["nominee_count"]

    async def current_workflow(self) -> dict[str, Any] | None:
        cursor = await self.conn.execute("SELECT * FROM loan.get_current_workflow()")
        return await cursor.fetchone()

    async def workflow_version(self, version_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_workflow_version(%s)",
            (version_id,),
        )
        return await cursor.fetchone()

    async def validate_nominees(self, member_id: UUID, nominee_ids: list[UUID]) -> bool:
        if not nominee_ids:
            return True
        cursor = await self.conn.execute(
            "SELECT loan.validate_nominees(%s,%s::uuid[]) AS valid",
            (member_id, nominee_ids),
        )
        row = await cursor.fetchone()
        return bool(row["valid"])

    async def create_application(
        self,
        *,
        values: dict[str, Any],
        product: dict[str, Any],
        workflow: dict[str, Any],
        member_context: dict[str, Any],
        fee: dict[str, Any] | None,
    ) -> dict[str, Any]:
        cursor = await self.conn.execute(
            """
            SELECT loan.create_application(%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s,%s::jsonb,%s) AS id
            """,
            (
                values["member_id"],
                values["loan_type_id"],
                values["purpose"],
                values["requested_amount"],
                values["requested_tenure_months"],
                member_context["is_first_loan"],
                product["rule_set_version_id"],
                Jsonb(product["definition"]),
                workflow["workflow_version_id"],
                Jsonb(fee) if fee is not None else None,
                values.get("nominee_ids", []),
            ),
        )
        loan_id = (await cursor.fetchone())["id"]
        return await self.get_application(loan_id)

    async def application_fee(self, loan_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_application_fee(%s)",
            (loan_id,),
        )
        return await cursor.fetchone()

    async def submit_application(
        self, loan: dict[str, Any], workflow: dict[str, Any]
    ) -> dict[str, Any] | None:
        submitted = await (await self.conn.execute(
            "SELECT loan.submit_application(%s) AS approval_request_id",(loan["id"],)
        )).fetchone()
        if submitted is None or submitted["approval_request_id"] is None:
            return None
        return await self.get_application(loan["id"])

    async def approval_inbox(self, *, limit: int, offset: int) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM loan.get_approval_inbox(%s,%s)",
            (limit + 1, offset),
        )
        rows = await cursor.fetchall()
        overrides = await self.nominee_overrides([row["loan_id"] for row in rows])
        # The approver sees when the nominee rule was overridden, and why.
        return [{**row, **_override_fields(overrides.get(row["loan_id"]))} for row in rows]
