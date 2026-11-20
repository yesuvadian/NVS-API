"""Workflow engine persistence: the execution log, the outbox of deferred
actions, approval routing, statuses and the action registry."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from psycopg import AsyncConnection


def _now() -> datetime:
    return datetime.now(timezone.utc)


class WorkflowRepository:
    def __init__(self, conn: AsyncConnection):
        self.conn = conn

    def savepoint(self):
        """A savepoint (nested transaction) for a CONTINUE action."""
        return self.conn.transaction()

    async def record_executions(self, workflow_instance_id: UUID, rows: list[dict[str, Any]]) -> None:
        for row in rows:
            pending = row.get("status") == "PENDING"
            error = row.get("error") or {}
            stamp = _now()
            await self.conn.execute(
                """INSERT INTO wf.action_execution (workflow_instance_id, stage_code, action_code, seq,
                       execution_type, status, idempotency_key, executed_by, scheduled_for, started_at,
                       completed_at, result, error_code, error_message, params, on_error, entity_type, entity_id)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, app.user_id(), %s, %s, %s, %s::jsonb, %s, %s, %s::jsonb,
                           %s, %s, %s)""",
                (workflow_instance_id, row["stage_code"], row["action_code"], row["seq"],
                 "async" if pending else "sync", row.get("status") or "SUCCESS", row["idempotency_key"],
                 stamp if pending else None, stamp, None if pending else stamp,
                 json.dumps(row.get("result")), error.get("code"), error.get("message"),
                 json.dumps(row.get("params") or {}), row.get("on_error"), row.get("entity_type"),
                 row.get("entity_id")),
            )

    async def due_deferred(self, limit: int) -> list[dict[str, Any]]:
        rows = await (await self.conn.execute(
            """SELECT id, workflow_instance_id, stage_code, action_code, params, attempt, entity_type, entity_id
                 FROM wf.action_execution
                WHERE tenant_id = app.tenant_id() AND status IN ('PENDING','RETRYING')
                  AND (scheduled_for IS NULL OR scheduled_for <= now())
                ORDER BY scheduled_for NULLS FIRST, created_at
                LIMIT %s FOR UPDATE SKIP LOCKED""", (limit,))).fetchall()
        return [dict(r) for r in rows]

    async def finish_deferred(self, execution_id: UUID, status: str, result: Any = None,
                              error: dict[str, Any] | None = None, retry: bool = False) -> None:
        stamp = _now()
        await self.conn.execute(
            """UPDATE wf.action_execution
                  SET status = %s, result = %s::jsonb, error_code = %s, error_message = %s,
                      attempt = attempt + CASE WHEN %s THEN 1 ELSE 0 END,
                      completed_at = CASE WHEN %s IN ('SUCCESS','FAILED','SKIPPED') THEN %s END
                WHERE tenant_id = app.tenant_id() AND id = %s""",
            (status, json.dumps(result, default=str), (error or {}).get("code"), (error or {}).get("message"),
             retry, status, stamp, execution_id))

    async def route_approval_request(self, request_id: UUID, roles: list[str], check: str) -> None:
        await self.conn.execute("SELECT wf.route_approval_request(%s, %s::text[], %s)", (request_id, roles, check))

    async def loan_state(self, loan_id: UUID) -> dict[str, Any]:
        row = await (await self.conn.execute(
            """SELECT l.status, l.workflow_instance_id, l.approval_request_id, l.row_version,
                      i.current_stage_code AS stage, i.current_stage_status AS stage_status,
                      i.status AS instance_status
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

    async def has_privilege(self, privilege: str) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.has_privilege(app.user_id(), %s) AS allowed", (privilege,))).fetchone()
        return bool(row and row["allowed"])

    async def actor(self) -> dict[str, Any]:
        row = await (await self.conn.execute(
            "SELECT app.user_id() AS user_id, app.role_code() AS role_code")).fetchone()
        return dict(row) if row else {}

    async def sync_actions(self, actions: list[dict[str, Any]]) -> dict[str, Any]:
        row = await (await self.conn.execute(
            "SELECT platform.sync_action_definitions(%s::jsonb) AS result", (json.dumps(actions),))).fetchone()
        return row["result"]

    async def list_actions(self, entity: str | None, event: str | None) -> list[dict[str, Any]]:
        row = await (await self.conn.execute(
            "SELECT platform.list_workflow_actions(%s, %s) AS items", (entity, event))).fetchone()
        return row["items"] if row else []
