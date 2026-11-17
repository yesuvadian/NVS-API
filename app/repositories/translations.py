from typing import Any
from uuid import UUID

from psycopg import AsyncConnection


class TranslationRepository:
    def __init__(self, conn: AsyncConnection) -> None:
        self.conn = conn

    async def is_active_language(self, language_code: str) -> bool:
        cursor = await self.conn.execute(
            "SELECT platform.is_active_language(%s) AS active",
            (language_code,),
        )
        row = await cursor.fetchone()
        return bool(row and row["active"])

    async def list_packs(self, language_code: str) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM platform.list_language_packs(%s)",
            (language_code,),
        )
        return await cursor.fetchall()

    async def create_draft(self, language_code: str, user_id: UUID) -> int:
        cursor = await self.conn.execute(
            "SELECT platform.create_translation_draft(%s,%s) AS version_no",
            (language_code,user_id),
        )
        row = await cursor.fetchone()
        return row["version_no"]

    async def list_entries(
        self,
        *,
        language_code: str,
        version_no: int,
        query: str | None,
        module_code: str | None,
        text_type: str | None,
        status: str | None,
        missing_only: bool,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM platform.search_translation_entries(%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (
                language_code,
                version_no,
                query,
                module_code,
                text_type,
                status,
                missing_only,
                limit,
                offset,
            ),
        )
        return await cursor.fetchall()

    async def save_entry(
        self,
        *,
        language_code: str,
        version_no: int,
        text_id: str,
        translated_text: str,
        status: str,
        user_id: UUID,
    ) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT platform.save_translation_entry(%s,%s,%s,%s,%s,%s) AS entry",
            (language_code,version_no,text_id,translated_text,status,user_id),
        )
        row = await cursor.fetchone()
        return row["entry"] if row else None

    async def publish(self, language_code: str, version_no: int, user_id: UUID) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT platform.publish_translation_pack(%s,%s,%s) AS pack",
            (language_code,version_no,user_id),
        )
        row = await cursor.fetchone()
        return row["pack"] if row else None

