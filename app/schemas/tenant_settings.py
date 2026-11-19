from uuid import UUID

from pydantic import BaseModel, Field


class PageSizeUpdate(BaseModel):
    page_size: int = Field(ge=1, le=100)


class PageSizeDecision(BaseModel):
    approve: bool
    reason: str | None = Field(default=None, max_length=500)


class PageSizeOut(BaseModel):
    page_size: int
    pending_setting_id: UUID | None = None
    pending_page_size: int | None = None
    status: str = 'ACTIVE'
