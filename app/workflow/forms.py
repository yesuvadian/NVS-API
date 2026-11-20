"""Button input forms: a JSON Schema object whose properties carry an
``x-field`` (the v1 field types). The same document drives the generated
form in the app and the validation here. ``x-sections`` groups fields for the
UI. Section and field titles are locale maps with English and Tamil required;
additional language keys are supported and passed through to clients.

Field types: text, multiline, number, amount, date, enum, boolean, member,
nominee. Supported keywords: type, required, minLength, maxLength, minimum,
maximum, exclusiveMinimum, enum, title {en, ta}; extensions x-maxFrom (the
value may not exceed this field of the record, e.g. requested_amount) and
x-showWhen (shown only when the button reports that flag, e.g.
needs_override).
"""

from __future__ import annotations

import re
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any
from uuid import UUID

from app.core.errors import AppError

FIELD_TYPES = ("text", "multiline", "number", "amount", "date", "enum", "boolean", "member", "nominee")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _number(value: Any) -> Decimal | None:
    if isinstance(value, bool):
        return None
    try:
        number = Decimal(str(value))
        return number if number.is_finite() else None
    except (InvalidOperation, ValueError):
        return None


def validate_input(schema: dict[str, Any] | None, data: dict[str, Any] | None,
                   record: dict[str, Any] | None = None) -> dict[str, Any]:
    """Validated, cleaned input (unknown fields rejected, text trimmed);
    raises WORKFLOW_INPUT_INVALID with one error per field."""
    schema = schema or {"type": "object", "properties": {}}
    if data is not None and not isinstance(data, dict):
        raise AppError("WORKFLOW_INPUT_INVALID", details={"errors": [{"field": "input", "code": "OBJECT"}]})
    data = dict(data or {})
    record = record or {}
    properties: dict[str, Any] = schema.get("properties") or {}
    errors: list[dict[str, Any]] = []
    clean: dict[str, Any] = {}

    for name in schema.get("required") or []:
        value = data.get(name)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append({"field": name, "code": "REQUIRED"})

    for name, value in data.items():
        spec = properties.get(name)
        if spec is None:
            errors.append({"field": name, "code": "UNKNOWN_FIELD"})
            continue
        if value is None or (isinstance(value, str) and not value.strip()):
            continue
        field = spec.get("x-field")
        if field not in FIELD_TYPES:
            errors.append({"field": name, "code": "UNSUPPORTED_FIELD"})
            continue
        if field in ("text", "multiline"):
            if not isinstance(value, str):
                errors.append({"field": name, "code": "TEXT"})
                continue
            value = value.strip()
            if "minLength" in spec and len(value) < spec["minLength"]:
                errors.append({"field": name, "code": "TOO_SHORT", "min": spec["minLength"]})
            if "maxLength" in spec and len(value) > spec["maxLength"]:
                errors.append({"field": name, "code": "TOO_LONG", "max": spec["maxLength"]})
        elif field in ("number", "amount"):
            number = _number(value)
            if number is None or (spec.get("type") == "integer" and number != number.to_integral_value()):
                errors.append({"field": name, "code": "NUMBER"})
                continue
            if "minimum" in spec and number < Decimal(str(spec["minimum"])):
                errors.append({"field": name, "code": "TOO_SMALL", "min": spec["minimum"]})
            if "exclusiveMinimum" in spec and number <= Decimal(str(spec["exclusiveMinimum"])):
                errors.append({"field": name, "code": "TOO_SMALL", "min": spec["exclusiveMinimum"]})
            if "maximum" in spec and number > Decimal(str(spec["maximum"])):
                errors.append({"field": name, "code": "TOO_LARGE", "max": spec["maximum"]})
            limit_field = spec.get("x-maxFrom")
            if limit_field and record.get(limit_field) is not None and number > Decimal(str(record[limit_field])):
                errors.append({"field": name, "code": "TOO_LARGE", "max": str(record[limit_field])})
            value = int(number) if spec.get("type") == "integer" else number
        elif field == "date":
            if not isinstance(value, str) or not _DATE.match(value):
                errors.append({"field": name, "code": "DATE"})
                continue
            try:
                date.fromisoformat(value)
            except ValueError:
                errors.append({"field": name, "code": "DATE"})
                continue
        elif field == "enum":
            if value not in (spec.get("enum") or []):
                errors.append({"field": name, "code": "NOT_ALLOWED"})
        elif field == "boolean":
            if not isinstance(value, bool):
                errors.append({"field": name, "code": "BOOLEAN"})
        elif field in ("member", "nominee"):
            values = value if isinstance(value, list) and spec.get("type") == "array" else [value]
            try:
                parsed = [str(UUID(str(v))) for v in values]
            except ValueError:
                errors.append({"field": name, "code": "ID"})
                continue
            value = parsed if spec.get("type") == "array" else parsed[0]
        clean[name] = value

    if errors:
        raise AppError("WORKFLOW_INPUT_INVALID", details={"errors": errors})
    return clean
