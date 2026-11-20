from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class WorkflowTransitionInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    input: dict[str, Any] = Field(default_factory=dict)
