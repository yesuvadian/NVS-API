"""Workflow engine persistence: the execution log and approval routing."""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

from psycopg import AsyncConnection


class WorkflowRepository:
    def __init__(self, conn: AsyncConnection):
        self.conn = conn

    async def record_executions(self, workflow_instance_id: UUID, rows: list[dict[str, Any]]) -> None:
        for row in rows:
            await self.conn.execute(
                """INSERT INTO wf.action_execution (workflow_instance_id, stage_code, action_code, seq,
                       execution_type, status, idempotency_key, executed_by, started_at, completed_at, result)
                   VALUES (%s, %s, %s, %s, 'sync', 'SUCCESS', %s, app.user_id(), clock_timestamp(), clock_timestamp(), %s::jsonb)""",
                (workflow_instance_id, row["stage_code"], row["action_code"], row["seq"],
                 row["idempotency_key"], json.dumps(row.get("result"))),
            )

    async def route_approval_request(self, request_id: UUID, roles: list[str], check: str) -> None:
        await self.conn.execute("SELECT wf.route_approval_request(%s, %s::text[], %s)", (request_id, roles, check))

    async def loan_state(self, loan_id: UUID) -> dict[str, Any]:
        row = await (await self.conn.execute(
            """SELECT l.status, l.workflow_instance_id, l.approval_request_id, i.current_stage_code AS stage
                 FROM loan.loan l
                 LEFT JOIN wf.workflow_instance i ON i.tenant_id = l.tenant_id AND i.id = l.workflow_instance_id
                WHERE l.tenant_id = app.tenant_id() AND l.id = %s""", (loan_id,))).fetchone()
        return dict(row) if row else {}

    async def apply_loan_status(self, loan_id: UUID, change: dict[str, Any], instance_id: UUID | None) -> dict[str, Any]:
        row = await (await self.conn.execute(
            "SELECT loan.apply_workflow_status(%s, %s, %s, %s, %s) AS result",
            (loan_id, change.get("entity_status"), instance_id, change.get("stage"), change.get("stage_status")),
        )).fetchone()
        return row["result"] if row else {}

    async def approval_request_state(self, request_id: UUID) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT wf.approval_request_state(%s) AS state", (request_id,))).fetchone()
        return row["state"] if row else None
