"""Coded, localised API errors.

Messages are never written in the API. Code raises ``AppError("SHORT_CODE")`` and
the handlers below look the short code up in the error catalogue
(platform.error_code, seeded by db/44_seed_error_codes.sql), pick the message in
the caller's language (Accept-Language, validated against platform.language)
and fall back to English. Errors PostgreSQL raises through app.fail() carry
their short code in the HINT and are rendered the same way.

Response body: {"detail": {"code", "shortCode", "message", "language",
"retryable", "reference"?, "params"?, "details"?}}.
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from typing import Any

import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

logger = logging.getLogger("cfms.errors")

DEFAULT_LANGUAGE = "en"
REFRESH_SECONDS = 300
_PLACEHOLDER = re.compile(r"\{(\w+)\}")
_KEY_DETAIL = re.compile(r"Key \(([^)]+)\)")

# HTTP status used only when the catalogue could not be loaded (for example in
# unit tests without a database). The catalogue's http_status always wins.
FALLBACK_STATUS: dict[str, int] = {
    "INVALID_CREDENTIALS": 401,
    "ACCOUNT_LOCKED": 403,
    "AUTH_NOT_CONFIGURED": 503,
    "PASSWORD_CHANGE_REQUIRED": 403,
    "PASSWORD_CHANGE_NOT_REQUIRED": 409,
    "PASSWORD_REUSE": 422,
    "ACTIVE_SESSION_EXISTS": 409,
    "NOT_SIGNED_IN": 401,
    "SESSION_EXPIRED": 401,
    "TENANT_ACCESS_INACTIVE": 401,
    "ORGANISATION_DISABLED": 403,
    "NO_PRIVILEGE": 403,
    "SUPER_ADMIN_REQUIRED": 403,
    "MFA_NOT_VERIFIED": 403,
    "MEMBER_NOT_FOUND": 404,
    "LOAN_TYPE_NOT_FOUND": 404,
    "LOAN_APPLICATION_NOT_FOUND": 404,
    "LOAN_NOT_FOUND": 404,
    "DISBURSEMENT_NOT_FOUND": 404,
    "APPROVAL_REQUEST_NOT_FOUND": 404,
    "ORGANISATION_NOT_FOUND": 404,
    "TRANSLATION_TARGET_NOT_FOUND": 404,
    "SETTLEMENT_NOT_FOUND": 404,
    "SETTLEMENT_APPROVER_IS_CREATOR": 403,
    "SETTLEMENT_QUOTE_STALE": 409,
    "SETTLEMENT_NOT_APPROVED": 409,
    "SETTLEMENT_NOT_PENDING": 409,
    "STALE_RECORD": 409,
    "ROW_VERSION_REQUIRED": 428,
    "IDEMPOTENCY_KEY_REQUIRED": 428,
    "IDEMPOTENCY_KEY_INVALID": 400,
    "IDEMPOTENCY_KEY_REUSED": 409,
    "IDEMPOTENCY_REQUEST_IN_PROGRESS": 409,
    "DUPLICATE_MEMBER": 409,
    "LOAN_APPLICATION_ALREADY_OPEN": 409,
    "JOB_ALREADY_RUNNING": 409,
    "CONCURRENT_UPDATE": 409,
    "LOAN_NOT_SUBMITTABLE": 409,
    "ORGANISATION_CODE_EXISTS": 409,
    "LANGUAGE_PACK_NOT_DRAFT": 409,
    "RECOVERY_CASE_NOT_FOUND": 404,
    "WAIVER_NOT_FOUND": 404,
    "OVERRIDE_NOT_FOUND": 404,
    "WRITE_OFF_NOT_FOUND": 404,
    "USER_NOT_FOUND": 404,
    "SOD_SELF_APPROVAL": 403,
    "APPROVER_ROLE_REQUIRED": 403,
    "WAIVER_ALREADY_PENDING": 409,
    "OVERRIDE_ALREADY_PENDING": 409,
    "WRITE_OFF_ALREADY_PROPOSED": 409,
    "WRITE_OFF_STALE": 409,
    "CANCELLATION_NOT_FOUND": 404,
    "REVERSAL_NOT_FOUND": 404,
    "REPAYMENT_NOT_FOUND": 404,
    "CANCELLATION_ALREADY_PENDING": 409,
    "REVERSAL_ALREADY_PENDING": 409,
    "SOD_RECORDER": 403,
    "GUARANTOR_NOT_FOUND": 404,
    "REPLACEMENT_NOT_FOUND": 404,
    "RESTRUCTURE_NOT_FOUND": 404,
    "DOCUMENT_NOT_FOUND": 404,
    "TRANSFER_NOT_FOUND": 404,
    "MIGRATION_REVIEW_NOT_FOUND": 404,
    "RESTRUCTURE_ALREADY_PENDING": 409,
    "TRANSFER_ALREADY_PROPOSED": 409,
    "DECEASED_DECISION_EXISTS": 409,
    "GUARANTOR_ALREADY_ADDED": 409,
    "REPLACEMENT_ALREADY_PENDING": 409,
    "INVALID_DATA": 422,
    "UNEXPECTED_ERROR": 500,
    "CONTEXT_SIGNING_NOT_CONFIGURED": 503,
    "LOAN_WORKFLOW_NOT_CONFIGURED": 503,
    "DATABASE_UNAVAILABLE": 503,
}


class AppError(HTTPException):
    """An error identified by its catalogue short code."""

    def __init__(
        self,
        short_code: str,
        *,
        params: dict[str, Any] | None = None,
        details: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.short_code = short_code
        self.params = params or {}
        self.details = details or {}
        detail: dict[str, Any] = {"shortCode": short_code}
        if self.params:
            detail["params"] = self.params
        if self.details:
            detail["details"] = self.details
        super().__init__(FALLBACK_STATUS.get(short_code, 422), detail=detail, headers=headers)


class Localisation:
    """Per-worker cache of active languages and the error catalogue."""

    def __init__(self) -> None:
        self.languages: set[str] = {DEFAULT_LANGUAGE}
        self.default_language = DEFAULT_LANGUAGE
        self.codes: dict[str, dict[str, Any]] = {}
        self.sqlstates: dict[str, str] = {}
        self.constraints: dict[str, str] = {}
        self.loaded_at = 0.0

    @property
    def is_stale(self) -> bool:
        return time.monotonic() - self.loaded_at > REFRESH_SECONDS

    async def load(self, pool) -> None:
        async with pool.connection() as conn:
            catalogue = (
                await (await conn.execute("SELECT platform.get_error_catalogue() AS c")).fetchone()
            )["c"]
            languages = await (await conn.execute("SELECT * FROM platform.list_languages()")).fetchall()
        self.codes = catalogue.get("codes", {})
        self.sqlstates = catalogue.get("sqlstates", {})
        self.constraints = catalogue.get("constraints", {})
        if languages:
            self.languages = {row["language_code"] for row in languages}
            self.default_language = next(
                (row["language_code"] for row in languages if row["is_default"]), DEFAULT_LANGUAGE
            )
        self.loaded_at = time.monotonic()

    async def refresh_if_stale(self, request: Request) -> None:
        database = getattr(request.app.state, "database", None)
        if database is None or not self.is_stale:
            return
        try:
            await self.load(database.pool)
        except Exception:  # keep serving with the last good catalogue
            self.loaded_at = time.monotonic() - REFRESH_SECONDS + 30
            logger.warning("Error catalogue refresh failed", exc_info=True)

    def language_for(self, request: Request) -> str:
        """First active language in Accept-Language (by q-value), else the default."""
        header = request.headers.get("accept-language", "")
        choices: list[tuple[float, str]] = []
        for part in header.split(","):
            tag, _, params = part.strip().partition(";")
            quality = 1.0
            if params.strip().startswith("q="):
                try:
                    quality = float(params.strip()[2:])
                except ValueError:
                    quality = 0.0
            code = tag.strip().lower().split("-")[0]
            if code:
                choices.append((quality, code))
        for _quality, code in sorted(choices, key=lambda item: -item[0]):
            if code in self.languages:
                return code
        return self.default_language

    def render(
        self,
        short_code: str,
        language: str,
        *,
        params: dict[str, Any] | None = None,
        fallback_status: int = 500,
        english_override: str | None = None,
    ) -> tuple[int, dict[str, Any]]:
        entry = self.codes.get(short_code)
        params = params or {}
        if entry is None:
            body = {"code": None, "shortCode": short_code, "message": short_code,
                    "language": DEFAULT_LANGUAGE, "retryable": False}
            return fallback_status, body
        template = (entry.get("translations") or {}).get(language)
        used_language = language
        if not template or (english_override and _PLACEHOLDER.search(template)):
            # No translation, or the database already filled the English text
            # with values the translated template cannot show.
            template, used_language = english_override or entry["message"], DEFAULT_LANGUAGE
        message = _PLACEHOLDER.sub(lambda m: str(params.get(m.group(1), m.group(0))), template)
        body = {
            "code": entry["code"],
            "shortCode": short_code,
            "message": message,
            "language": used_language,
            "retryable": entry.get("retryable", False),
        }
        return int(entry["http"]), body


localisation = Localisation()


def _response(status: int, body: dict[str, Any], headers: dict[str, str] | None = None) -> JSONResponse:
    return JSONResponse(status_code=status, content={"detail": body}, headers=headers)


async def app_error_handler(request: Request, exc: AppError) -> JSONResponse:
    await localisation.refresh_if_stale(request)
    status, body = localisation.render(
        exc.short_code,
        localisation.language_for(request),
        params=exc.params,
        fallback_status=exc.status_code,
    )
    if exc.params:
        body["params"] = exc.params
    if exc.details:
        body["details"] = exc.details
    return _response(status, body, exc.headers)


def _database_short_code(exc: psycopg.Error) -> tuple[str, dict[str, Any], str | None]:
    diag = exc.diag
    hint, sqlstate, constraint = diag.message_hint, diag.sqlstate, diag.constraint_name
    params: dict[str, Any] = {}
    key = _KEY_DETAIL.search(diag.message_detail or "")
    if key:
        params["field"] = key.group(1)
    elif diag.column_name:
        params["field"] = diag.column_name
    if hint and hint in localisation.codes:  # raised by app.fail(short_code, message)
        return hint, params, diag.message_primary
    if constraint and constraint in localisation.constraints:
        return localisation.constraints[constraint], params, None
    if sqlstate:
        for state in (sqlstate, sqlstate[:2]):
            if state in localisation.sqlstates:
                return localisation.sqlstates[state], params, None
    if sqlstate is None and isinstance(exc, psycopg.OperationalError):
        return "DATABASE_UNAVAILABLE", params, None
    return "UNEXPECTED_ERROR", params, None


async def database_error_handler(request: Request, exc: psycopg.Error) -> JSONResponse:
    await localisation.refresh_if_stale(request)
    short_code, params, english = _database_short_code(exc)
    status, body = localisation.render(
        short_code, localisation.language_for(request), params=params, english_override=english
    )
    if status >= 500:
        body["reference"] = str(uuid.uuid4())
        logger.error("Database error %s (reference %s)", short_code, body["reference"], exc_info=exc)
    return _response(status, body)


async def unexpected_error_handler(request: Request, exc: Exception) -> JSONResponse:
    status, body = localisation.render("UNEXPECTED_ERROR", localisation.language_for(request))
    body["reference"] = str(uuid.uuid4())
    logger.error("Unexpected error (reference %s)", body["reference"], exc_info=exc)
    return _response(status, body)


async def validation_error_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    """Render request-body/query validation failures in the standard error shape.

    FastAPI's default is ``{"detail": [...]}``; clients expect ``detail.shortCode``
    and ``detail.message``. The first failing field fills ``{field}`` and every
    failure is listed in ``details.errors`` so a form can mark each field.
    """
    await localisation.refresh_if_stale(request)
    errors = []
    for item in exc.errors():
        location = [str(part) for part in item.get("loc", ()) if part not in ("body", "query", "path", "header")]
        errors.append({"field": ".".join(location) or None, "type": item.get("type"), "message": item.get("msg")})
    field = next((error["field"] for error in errors if error["field"]), "value")
    status, body = localisation.render(
        "INVALID_DATA", localisation.language_for(request), params={"field": field}, fallback_status=422
    )
    body["params"] = {"field": field}
    body["details"] = {"errors": errors}
    return _response(status, body)


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AppError, app_error_handler)
    app.add_exception_handler(RequestValidationError, validation_error_handler)
    app.add_exception_handler(psycopg.Error, database_error_handler)
    app.add_exception_handler(Exception, unexpected_error_handler)
