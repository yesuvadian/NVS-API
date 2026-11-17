from typing import Any
from uuid import UUID

from psycopg import AsyncConnection
from psycopg.types.json import Jsonb


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
        return await cursor.fetchone()

    async def application_nominee_count(self, loan_id: UUID) -> int:
        cursor = await self.conn.execute(
            "SELECT loan.count_application_nominees(%s) AS nominee_count",
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
        return await cursor.fetchall()
