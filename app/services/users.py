from uuid import UUID

from starlette.concurrency import run_in_threadpool

from app.core.config import Settings
from app.core.errors import AppError
from app.core.passwords import INITIAL_DEFAULT_PASSWORD, hash_password
from app.repositories.users import UserRepository


class UserService:
    def __init__(self, conn, settings: Settings) -> None:
        self.repo = UserRepository(conn)
        self.settings = settings

    async def list_users(self, offset: int = 0):
        return await self.repo.list_users(offset)

    async def list_roles(self):
        return await self.repo.list_roles()

    async def create_user(self, payload) -> UUID:
        encoded = await run_in_threadpool(hash_password, INITIAL_DEFAULT_PASSWORD, minimum_length=1)
        return await self.repo.create_user(
            full_name=payload.full_name, mobile=payload.mobile,
            email=str(payload.email) if payload.email else None,
            role_code=payload.role_code.upper(), password_hash=encoded,
        )

    async def reset_password(self, user_id: UUID) -> None:
        encoded = await run_in_threadpool(hash_password, INITIAL_DEFAULT_PASSWORD, minimum_length=1)
        if not await self.repo.reset_password(user_id, encoded):
            raise AppError("USER_NOT_FOUND")
