from __future__ import annotations

import importlib
import pkgutil
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, ClassVar


@dataclass(frozen=True)
class RuleEvaluation:
    passed: bool
    reasons: tuple[str, ...] = ()
    params: dict[str, Any] | None = None


class IAppRule(ABC):
    """Registered business rule with a stable workflow code and evaluator."""

    code: ClassVar[str]
    name: ClassVar[dict[str, str]]
    description: ClassVar[dict[str, str]] = {}
    category: ClassVar[str] = "Loan eligibility"
    rule_checks: ClassVar[dict[str, type["IAppRule"]]] = {}

    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        code = getattr(cls, "code", None)
        if code:
            if code in IAppRule.rule_checks:
                raise ValueError(f"Duplicate application rule code {code}")
            IAppRule.rule_checks[code] = cls

    @abstractmethod
    def evaluate(self, context: dict[str, Any]) -> RuleEvaluation:
        """Evaluate against precomputed loan context, without I/O."""

    @classmethod
    def describe(cls) -> dict[str, Any]:
        return {"code": cls.code, "name": cls.name, "description": cls.description,
                "category": cls.category, "on_fail": ["BLOCK", "WARN", "ROUTE_TO_ROLE", "REQUIRE_OVERRIDE"]}


def discover(package: str = "app.rules") -> dict[str, type[IAppRule]]:
    module = importlib.import_module(package)
    for info in pkgutil.walk_packages(module.__path__, prefix=f"{package}."):
        importlib.import_module(info.name)
    return dict(IAppRule.rule_checks)


def registry() -> list[dict[str, Any]]:
    return [rule.describe() for _, rule in sorted(discover().items())]
