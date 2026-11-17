import re
from uuid import UUID

from psycopg import AsyncConnection, errors

from app.core.errors import AppError
from app.repositories.translations import TranslationRepository

# Mirrors the CHECK constraints on platform.translation_text / translation_entry.
TEXT_TYPES = {"PAGE", "LABEL", "MESSAGE", "MASTER_DATA"}
ENTRY_STATUSES = {"DRAFT", "APPROVED"}
LANGUAGE_CODE = re.compile(r"^[a-z]{2,3}$")


class TranslationService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repository = TranslationRepository(conn)

    async def require_language(self, language_code: str) -> None:
        """Languages come from platform.language; reject bad codes before querying."""
        if not LANGUAGE_CODE.match(language_code or "") or not await self.repository.is_active_language(
            language_code
        ):
            raise AppError("UNSUPPORTED_LANGUAGE", params={"language": language_code})

    async def list_packs(self, language_code: str):
        await self.require_language(language_code)
        return await self.repository.list_packs(language_code)

    async def create_draft(self, language_code: str, user_id: UUID) -> int:
        await self.require_language(language_code)
        try:
            return await self.repository.create_draft(language_code, user_id)
        except errors.UniqueViolation:
            raise AppError("CONCURRENT_UPDATE") from None

    async def list_entries(self, **filters):
        if filters.get("status") not in (None, "APPROVED", "DRAFT", "MISSING"):
            raise AppError("INVALID_TRANSLATION_FILTER", params={"filter": "status"})
        if filters.get("text_type") not in (None, *TEXT_TYPES):
            raise AppError("INVALID_TRANSLATION_FILTER", params={"filter": "text_type"})
        await self.require_language(filters["language_code"])
        return await self.repository.list_entries(**filters)

    async def save_entry(self, **values):
        if values["status"] not in ENTRY_STATUSES:
            raise AppError("INVALID_TRANSLATION_STATUS")
        if not values["translated_text"].strip():
            raise AppError("TRANSLATION_TEXT_REQUIRED")
        await self.require_language(values["language_code"])
        saved = await self.repository.save_entry(**values)
        if saved is None:
            raise AppError("TRANSLATION_TARGET_NOT_FOUND")
        return saved

    async def publish(self, language_code: str, version_no: int, user_id: UUID):
        await self.require_language(language_code)
        published = await self.repository.publish(language_code, version_no, user_id)
        if published is None:
            raise AppError("LANGUAGE_PACK_NOT_DRAFT")
        return published
