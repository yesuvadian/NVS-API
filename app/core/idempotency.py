"""Idempotent POST requests (double-click and retry protection).

A client sends ``Idempotency-Key: <unique value>`` with a request that creates
money records (repayments, recoveries, fees, settlement collections and
disbursement vouchers) or new masters (members, loan applications). It
generates a new key each time the user opens the form and sends the same key
again when it retries, for example after a timeout.

The first request with a key reserves it in ``core.idempotency_request`` in the
same database transaction as the posting and stores the response. A repeat
gets the stored response (with the ``Idempotent-Replayed: true`` header)
instead of a second receipt. The same key sent for a different request fails
with IDEMPOTENCY_KEY_REUSED. Two requests with the same key at the same moment
are serialised by the database's unique index, so only one of them posts.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import Response
from fastapi.encoders import jsonable_encoder
from psycopg import AsyncConnection
from psycopg.types.json import Jsonb

from app.core.errors import AppError

IDEMPOTENCY_HEADER = "Idempotency-Key"
REPLAYED_HEADER = "Idempotent-Replayed"
_KEY = re.compile(r"^[A-Za-z0-9_.:-]{8,100}$")


def validate_key(key: str | None, *, required: bool) -> str | None:
    """Return the cleaned key, or raise IDEMPOTENCY_KEY_REQUIRED / IDEMPOTENCY_KEY_INVALID."""
    key = key.strip() if key is not None else None
    if not key:
        if required:
            raise AppError("IDEMPOTENCY_KEY_REQUIRED")
        return None
    if not _KEY.fullmatch(key):
        raise AppError("IDEMPOTENCY_KEY_INVALID")
    return key


def request_hash(operation: str, payload: Any) -> str:
    """Stable fingerprint of what the request asks for (operation, path ids and body)."""
    canonical = json.dumps(
        {"operation": operation, "payload": jsonable_encoder(payload)},
        sort_keys=True, separators=(",", ":"), default=str,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class IdempotencyRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def begin(self, key: str, operation: str, fingerprint: str) -> dict[str, Any] | None:
        row = await (await self.conn.execute(
            "SELECT core.idempotency_begin(%s,%s,%s) AS stored", (key, operation, fingerprint)
        )).fetchone()
        return row["stored"] if row else None

    async def finish(self, key: str, response: Any) -> None:
        await self.conn.execute(
            "SELECT core.idempotency_finish(%s,%s)", (key, Jsonb(jsonable_encoder(response)))
        )


async def run_idempotent(
    conn: AsyncConnection,
    *,
    key: str | None,
    operation: str,
    payload: Any,
    action: Callable[[], Awaitable[Any]],
    response: Response | None = None,
) -> Any:
    """Run ``action`` once per key. Without a key the action simply runs."""
    if key is None:
        return await action()
    repository = IdempotencyRepository(conn)
    stored = await repository.begin(key, operation, request_hash(operation, payload))
    if stored is not None:
        if response is not None:
            response.headers[REPLAYED_HEADER] = "true"
        return stored["response"]
    result = await action()
    await repository.finish(key, result)
    return result
