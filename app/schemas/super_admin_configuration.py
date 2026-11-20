from datetime import date
from typing import Any, Literal

from pydantic import BaseModel, Field


class ConfigurationValidationRequest(BaseModel):
    kind: Literal["WORKFLOW", "RULESET"]
    code: str = Field(min_length=1, max_length=80)
    definition: dict[str, Any]


class ConfigurationPublishRequest(ConfigurationValidationRequest):
    reason: str = Field(min_length=3, max_length=500)
    effective_from: date
