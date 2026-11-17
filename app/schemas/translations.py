from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

TranslationStatus = Literal["DRAFT", "APPROVED"]


class TranslationEntryUpdate(BaseModel):
    translated_text: str = Field(min_length=1, max_length=10000)
    status: TranslationStatus = "DRAFT"


class TranslationPackOut(BaseModel):
    language_code: str
    version_no: int
    status: str
    created_at: datetime
    published_at: datetime | None
    approved_count: int

