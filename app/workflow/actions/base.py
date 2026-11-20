"""The workflow action interface.

Every action a workflow can run is a subclass of ``WorkflowAction`` in a
module of the ``app.workflow.actions`` package. Subclasses register
themselves (``__init_subclass__``) and ``discover()`` imports every module of
the package, so adding an action is adding a class: no list to maintain.
At start-up the registry is synchronised into platform.action_definition,
which is what the Super Admin dropdowns and cfg.validate_workflow read.
"""

from __future__ import annotations

import importlib
import pkgutil
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, ClassVar

EVENTS = ("onEnter", "onExit", "onTransition", "afterRule")
KINDS = ("VALIDATION", "DATA", "NOTIFICATION", "APPROVAL", "MANUAL")


@dataclass
class ActionResult:
    """What an action did. ``status`` SUCCESS, SKIPPED (nothing to do here,
    e.g. a step the composite SQL function performs) or PENDING."""

    status: str = "SUCCESS"
    data: Any = None
    message: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {"status": self.status, "data": self.data, "message": self.message}


class WorkflowAction(ABC):
    """One action. Class attributes describe it for the registry:

    code               UPPER_SNAKE code used in the workflow JSON
    name               {"en": ..., "ta": ...}
    description        one line for the Super Admin dropdown
    category, kind     grouping (kind one of KINDS)
    supported_entities entity codes it can act on (e.g. ("LOAN",))
    supported_events   where it may be attached (subset of EVENTS)
    params_schema      JSON Schema of its params (validated on publish)
    deferrable         may run later from the outbox (onError DEFER)
    core               shipped with the platform: approved on discovery;
                       other new actions wait for Super Admin approval
    composite_step     performed inside an existing SQL function (journal,
                       receipt, schedule...): listed, but standalone execution
                       reports SKIPPED
    """

    code: ClassVar[str]
    name: ClassVar[dict[str, str]]
    description: ClassVar[str] = ""
    category: ClassVar[str] = "Workflow"
    kind: ClassVar[str] = "DATA"
    supported_entities: ClassVar[tuple[str, ...]] = ()
    supported_events: ClassVar[tuple[str, ...]] = ("onTransition",)
    params_schema: ClassVar[dict[str, Any]] = {"type": "object", "additionalProperties": False}
    deferrable: ClassVar[bool] = False
    core: ClassVar[bool] = True
    composite_step: ClassVar[bool] = False
    selectable: ClassVar[bool] = True          # False: engine steps (rule checks, statuses)
    version: ClassVar[str] = "1"

    registry: ClassVar[dict[str, type["WorkflowAction"]]] = {}

    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        if getattr(cls, "__abstractmethods__", None) or not getattr(cls, "code", None):
            return
        assert cls.kind in KINDS, (cls.code, cls.kind)
        assert set(cls.supported_events) <= set(EVENTS), (cls.code, cls.supported_events)
        WorkflowAction.registry[cls.code] = cls

    @abstractmethod
    async def execute(self, ctx: Any, params: dict[str, Any]) -> ActionResult:
        """Run the action for the transition context ``ctx``."""

    @classmethod
    def describe(cls) -> dict[str, Any]:
        return {
            "code": cls.code, "name": cls.name, "description": cls.description, "category": cls.category,
            "kind": cls.kind, "supported_entities": list(cls.supported_entities),
            "supported_events": list(cls.supported_events), "params_schema": cls.params_schema,
            "deferrable": cls.deferrable, "core": cls.core, "composite_step": cls.composite_step,
            "selectable": cls.selectable,
            "implementation": f"{cls.__module__}.{cls.__qualname__}", "version": cls.version,
        }


class IStageAction:
    """Marker/registry for implementations that may run on a stage enter/exit.

    Stage actions share the execution contract and database registry with event
    actions, but the workflow engine schedules them from a stage declaration.
    """

    stage_registry: ClassVar[dict[str, type]] = {}

    pass


def stage_action(cls):
    """Register one action implementation as a stage hook."""
    IStageAction.stage_registry[cls.code] = cls
    return cls


class CompositeStep(WorkflowAction):
    """A step an existing SQL function performs as part of a larger action
    (for example the journal of a disbursement). Listed so it can be chosen
    and audited; running it on its own reports SKIPPED."""

    composite_step = True

    async def execute(self, ctx: Any, params: dict[str, Any]) -> ActionResult:
        return ActionResult("SKIPPED", message="Performed by the composite database step")


@dataclass
class Registry:
    actions: dict[str, type[WorkflowAction]] = field(default_factory=dict)

    def get(self, code: str) -> type[WorkflowAction] | None:
        return self.actions.get(code)


def discover(package: str = "app.workflow.actions") -> dict[str, type[WorkflowAction]]:
    """Import every module of the package (and sub-packages); returns the
    registry of all WorkflowAction subclasses known so far."""
    module = importlib.import_module(package)
    for info in pkgutil.walk_packages(module.__path__, prefix=f"{package}."):
        importlib.import_module(info.name)
    return dict(WorkflowAction.registry)
