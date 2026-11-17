from collections.abc import AsyncIterator

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from app.core.config import Settings


class Database:
    def __init__(self, settings: Settings) -> None:
        self.pool = AsyncConnectionPool(
            conninfo=settings.database_url,
            min_size=settings.database_pool_min,
            max_size=settings.database_pool_max,
            kwargs={"row_factory": dict_row},
            open=False,
        )

    async def open(self) -> None:
        await self.pool.open()

    async def close(self) -> None:
        await self.pool.close()

    async def connection(self) -> AsyncIterator:
        async with self.pool.connection() as conn:
            async with conn.transaction():
                yield conn

