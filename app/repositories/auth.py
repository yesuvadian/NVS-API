from typing import Any

from psycopg import AsyncConnection


class AuthRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def login_candidates(self, identifier: str, channel: str) -> list[dict[str, Any]]:
        result = await self.conn.execute(
            "SELECT * FROM iam.login_candidates(%s,%s)", (identifier, channel)
        )
        return await result.fetchall()

    async def record_attempt(
        self, *, kind: str, user_id, tenant_id, identifier: str, channel: str,
        success: bool, failure_reason: str | None, ip_address: str | None,
        device: str | None, user_agent: str | None,
    ) -> None:
        await self.conn.execute(
            "SELECT iam.record_login_attempt(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (kind, user_id, tenant_id, identifier, channel, success, failure_reason,
             ip_address, device, user_agent),
        )

    async def password_hashes(self) -> list[str]:
        result = await self.conn.execute(
            "SELECT password_hash FROM iam.get_password_hashes_for_policy()",
        )
        return [row["password_hash"] for row in await result.fetchall()]

    async def change_own_password(self, expected_hash: str, new_hash: str) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.change_own_password(%s,%s) AS changed", (expected_hash, new_hash)
        )).fetchone()
        return bool(row["changed"])

    async def reset_user_password(self, target_user_id, default_hash: str) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.reset_user_password(%s,%s) AS changed",
            (target_user_id, default_hash),
        )).fetchone()
        return bool(row["changed"])

    async def prepare_session(self, *, kind, user_id, tenant_id, session_id,
                              expires_at, force_logout, ip_address, device) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.prepare_auth_session(%s,%s,%s,%s,%s,%s,%s,%s) AS prepared",
            (kind, user_id, tenant_id, session_id, expires_at, force_logout, ip_address, device),
        )).fetchone()
        return bool(row["prepared"])

    async def session_is_active(self, *, kind, user_id, tenant_id, session_id) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.is_auth_session_active(%s,%s,%s,%s) AS active",
            (kind, user_id, tenant_id, session_id),
        )).fetchone()
        return bool(row["active"])

    async def revoke_session(self, *, kind, user_id, tenant_id, session_id) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.revoke_auth_session(%s,%s,%s,%s) AS revoked",
            (kind, user_id, tenant_id, session_id),
        )).fetchone()
        return bool(row["revoked"])
