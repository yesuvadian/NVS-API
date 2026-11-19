from psycopg import AsyncConnection


class UserRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def list_users(self, offset: int):
        result = await self.conn.execute(
            "SELECT * FROM iam.list_tenant_users(%s)", (offset,)
        )
        return await result.fetchall()

    async def list_roles(self):
        result = await self.conn.execute("SELECT * FROM iam.list_assignable_roles()")
        return await result.fetchall()

    async def create_user(self, *, full_name, mobile, email, role_code, password_hash):
        row = await (await self.conn.execute(
            "SELECT iam.create_tenant_user(%s,%s,%s,%s,%s) AS user_id",
            (full_name, mobile, email, role_code, password_hash),
        )).fetchone()
        return row["user_id"]

    async def reset_password(self, user_id, password_hash) -> bool:
        row = await (await self.conn.execute(
            "SELECT iam.reset_user_password(%s,%s) AS changed", (user_id, password_hash)
        )).fetchone()
        return bool(row["changed"])
