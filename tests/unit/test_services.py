import asyncio

import pytest
from fastapi import HTTPException

from app.services.translations import TranslationService


@pytest.mark.parametrize("language", ["ta-IN", "", "EN", "x1"])
def test_translation_service_rejects_malformed_language_before_database_access(language: str) -> None:
    service = TranslationService(conn=object())  # type: ignore[arg-type]

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(service.list_packs(language))

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["shortCode"] == "UNSUPPORTED_LANGUAGE"


class _LanguageLookup:
    """Answers platform.is_active_language like the platform.language table."""

    def __init__(self, active: set[str]) -> None:
        self.active = active
        self.calls: list[tuple] = []

    async def execute(self, query, params=None):
        self.calls.append((query, params))
        active = params[0] in self.active

        class Result:
            async def fetchone(self_inner):
                return {"active": active}

        return Result()


def test_translation_service_checks_language_against_language_table() -> None:
    conn = _LanguageLookup({"en", "ta"})
    service = TranslationService(conn=conn)  # type: ignore[arg-type]

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(service.list_packs("fr"))

    assert exc_info.value.detail == {"shortCode": "UNSUPPORTED_LANGUAGE", "params": {"language": "fr"}}
    assert "platform.is_active_language" in conn.calls[0][0]


def test_translation_service_rejects_blank_approved_translation_before_database_access() -> None:
    service = TranslationService(conn=object())  # type: ignore[arg-type]

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(
            service.save_entry(
                language_code="ta",
                version_no=1,
                text_id="HOME.TITLE",
                translated_text="  \n",
                status="APPROVED",
                user_id="00000000-0000-0000-0000-000000000001",
            )
        )

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["shortCode"] == "TRANSLATION_TEXT_REQUIRED"


def test_translation_service_rejects_invalid_entry_status_before_database_access() -> None:
    service = TranslationService(conn=object())  # type: ignore[arg-type]

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(
            service.save_entry(
                language_code="ta",
                version_no=1,
                text_id="HOME.TITLE",
                translated_text="முகப்பு",
                status="PUBLISHED",
                user_id="00000000-0000-0000-0000-000000000001",
            )
        )

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["shortCode"] == "INVALID_TRANSLATION_STATUS"
