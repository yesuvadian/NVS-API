"""The workflow and rule-set JSON Schemas kept in the repository (draft 2020-12)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

SCHEMAS = Path(__file__).resolve().parents[2] / "schemas"


@pytest.mark.parametrize("name", ["workflow.schema.json", "rule_set.schema.json"])
def test_schema_files_are_draft_2020_12(name):
    schema = json.loads((SCHEMAS / name).read_text(encoding="utf-8"))
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["type"] == "object" and schema["required"]


def _refs(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref":
                yield value
            else:
                yield from _refs(value)
    elif isinstance(node, list):
        for item in node:
            yield from _refs(item)


@pytest.mark.parametrize("name", ["workflow.schema.json", "rule_set.schema.json"])
def test_every_ref_resolves(name):
    schema = json.loads((SCHEMAS / name).read_text(encoding="utf-8"))
    for ref in _refs(schema):
        assert ref.startswith("#/$defs/") and ref.split("/")[-1] in schema["$defs"], ref


def test_workflow_schema_covers_engine_keys():
    defs = json.loads((SCHEMAS / "workflow.schema.json").read_text(encoding="utf-8"))["$defs"]
    assert {"actorPrivilege", "approval", "statuses"} <= set(defs["stage"]["properties"])
    assert {"ruleChecks", "actions", "stageStatus", "entityStatus"} <= set(defs["transition"]["properties"])
    assert defs["approval"]["required"] == ["roles", "minApprovals"]
    assert set(defs["ruleCheck"]["oneOf"][1]["properties"]["onFail"]["enum"]) == {
        "BLOCK", "REQUIRE_OVERRIDE", "ROUTE_TO_ROLE", "WARN"}
