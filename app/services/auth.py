from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
from fastapi import Request
from starlette.concurrency import run_in_threadpool
from uuid import UUID, uuid4

from app.core.config import Settings
from app.core.errors import AppError
from app.core.passwords import INITIAL_DEFAULT_PASSWORD, hash_password, verify_password
from app.core.tenant_security import TenantPrincipal
from app.db.context import set_signed_tenant_context
from app.repositories.auth import AuthRepository


class AuthService:
    def __init__(self, conn, settings: Settings) -> None:
        self.conn = conn
        self.settings = settings
        self.repo = AuthRepository(conn)

    async def login(
        self, *, identifier: str, password: str, channel: str,
        request: Request, device: str | None, force_logout: bool = False,
    ) -> dict[str, Any]:
        identifier = identifier.strip()
        ip_address = request.client.host if request.client else None
        user_agent = request.headers.get("user-agent")
        failure: AppError | None = None
        response: dict[str, Any] | None = None

        async with self.conn.transaction():
            candidates = await self.repo.login_candidates(identifier, channel)
            if len(candidates) != 1:
                await run_in_threadpool(verify_password, password, None)
                await self.repo.record_attempt(
                    kind="UNKNOWN", user_id=None, tenant_id=None, identifier=identifier,
                    channel=channel, success=False, failure_reason="INVALID_CREDENTIALS",
                    ip_address=ip_address, device=device, user_agent=user_agent,
                )
                failure = AppError("INVALID_CREDENTIALS")
            else:
                user = candidates[0]
                password_ok = await run_in_threadpool(
                    verify_password, password, user["password_hash"]
                )
                if user["locked_until"] is not None and user["locked_until"] > datetime.now(UTC):
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=user["tenant_id"], identifier=identifier,
                        channel=channel, success=False, failure_reason="LOCKED",
                        ip_address=ip_address, device=device, user_agent=user_agent,
                    )
                    failure = AppError("ACCOUNT_LOCKED")
                elif not password_ok:
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=user["tenant_id"], identifier=identifier,
                        channel=channel, success=False, failure_reason="WRONG_PASSWORD",
                        ip_address=ip_address, device=device, user_agent=user_agent,
                    )
                    failure = AppError("INVALID_CREDENTIALS")
                elif user["principal_kind"] == "TENANT" and user.get("tenant_status", "ACTIVE") != "ACTIVE":
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=user["tenant_id"], identifier=identifier,
                        channel=channel, success=False, failure_reason="NO_ACCESS",
                        ip_address=ip_address, device=device, user_agent=user_agent,
                    )
                    failure = AppError("ORGANISATION_DISABLED")
                elif user["account_status"] != "ACTIVE" or not user["channel_access"]:
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=user["tenant_id"], identifier=identifier,
                        channel=channel, success=False, failure_reason="NO_ACCESS",
                        ip_address=ip_address, device=device, user_agent=user_agent,
                    )
                    failure = AppError("INVALID_CREDENTIALS")
                elif user["principal_kind"] == "PLATFORM" and user["platform_role"] != "SUPER_ADMIN":
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=None, identifier=identifier, channel=channel,
                        success=False, failure_reason="NO_ACCESS", ip_address=ip_address,
                        device=device, user_agent=user_agent,
                    )
                    failure = AppError("INVALID_CREDENTIALS")
                elif user["principal_kind"] == "PLATFORM" and self.settings.require_platform_mfa and user["mfa_enabled"]:
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=None, identifier=identifier, channel=channel,
                        success=False, failure_reason="MFA_REQUIRED", ip_address=ip_address,
                        device=device, user_agent=user_agent,
                    )
                    failure = AppError("MFA_NOT_VERIFIED")
                elif user["principal_kind"] == "TENANT" and (
                    user["role_code"] is None
                    or (self.settings.require_tenant_mfa and user["role_requires_mfa"])
                ):
                    await self.repo.record_attempt(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=user["tenant_id"], identifier=identifier,
                        channel=channel, success=False, failure_reason="NO_ACCESS",
                        ip_address=ip_address, device=device, user_agent=user_agent,
                    )
                    failure = AppError(
                        "MFA_NOT_VERIFIED" if user["role_code"] is not None else "INVALID_CREDENTIALS"
                    )
                else:
                    session_id = uuid4()
                    now = datetime.now(UTC)
                    expires = now + timedelta(minutes=self.settings.auth_access_token_minutes)
                    prepared = await self.repo.prepare_session(
                        kind=user["principal_kind"], user_id=user["user_id"],
                        tenant_id=user["tenant_id"], session_id=session_id,
                        expires_at=expires, force_logout=force_logout,
                        ip_address=ip_address, device=device,
                    )
                    if not prepared:
                        await self.repo.record_attempt(
                            kind=user["principal_kind"], user_id=user["user_id"],
                            tenant_id=user["tenant_id"], identifier=identifier,
                            channel=channel, success=False, failure_reason="ACTIVE_SESSION",
                            ip_address=ip_address, device=device, user_agent=user_agent,
                        )
                        failure = AppError("ACTIVE_SESSION_EXISTS", details={"forceLogoutAllowed": True})
                    else:
                        await self.repo.record_attempt(
                            kind=user["principal_kind"], user_id=user["user_id"],
                            tenant_id=user["tenant_id"], identifier=identifier,
                            channel=channel, success=True, failure_reason=None,
                            ip_address=ip_address, device=device, user_agent=user_agent,
                        )
                        response = self._issue_token(user, channel, session_id)

        if failure is not None:
            raise failure
        assert response is not None
        return response

    def _issue_token(self, user: dict[str, Any], channel: str, session_id: UUID) -> dict[str, Any]:
        now = datetime.now(UTC)
        expires = now + timedelta(minutes=self.settings.auth_access_token_minutes)
        kind = user["principal_kind"]
        if kind == "PLATFORM":
            if self.settings.platform_jwt_secret is None:
                raise AppError("AUTH_NOT_CONFIGURED")
            claims = {
                "sub": str(user["user_id"]),
                "sid": str(session_id),
                "iss": self.settings.platform_jwt_issuer,
                "aud": self.settings.platform_jwt_audience,
                "platform_role": user["platform_role"],
                "mfa_verified": False,
                "must_change_password": user["must_change_password"],
                "iat": now,
                "exp": expires,
            }
            secret = self.settings.platform_jwt_secret.get_secret_value()
            workspace = "SUPER_ADMIN"
        else:
            if self.settings.tenant_jwt_secret is None:
                raise AppError("AUTH_NOT_CONFIGURED")
            claims = {
                "sub": str(user["user_id"]),
                "sid": str(session_id),
                "tenant_id": str(user["tenant_id"]),
                "role_code": user["role_code"],
                "channel": channel,
                "mfa_verified": False,
                "must_change_password": user["must_change_password"],
                "iss": self.settings.tenant_jwt_issuer,
                "aud": self.settings.tenant_jwt_audience,
                "iat": now,
                "exp": expires,
            }
            secret = self.settings.tenant_jwt_secret.get_secret_value()
            workspace = "TENANT"
        return {
            "access_token": jwt.encode(claims, secret, algorithm="HS256"),
            "token_type": "bearer",
            "expires_in": int((expires - now).total_seconds()),
            "workspace": workspace,
            "must_change_password": user["must_change_password"],
            "user": {
                "id": str(user["user_id"]),
                "display_name": user["display_name"],
                "tenant_id": str(user["tenant_id"]) if user["tenant_id"] else None,
                "role": user["platform_role"] if workspace == "SUPER_ADMIN" else user["role_code"],
            },
        }

    async def change_initial_password(
        self, *, token: str, current_password: str, new_password: str, request: Request,
    ) -> dict[str, Any]:
        claims = self._decode_password_change_token(token)
        if claims.get("must_change_password") is not True:
            raise AppError("PASSWORD_CHANGE_NOT_REQUIRED")
        try:
            user_id = UUID(claims["sub"])
            kind = "PLATFORM" if "platform_role" in claims else "TENANT"
            tenant_id = UUID(claims["tenant_id"]) if kind == "TENANT" else None
            channel = str(claims.get("channel", "WEB")).upper()
            session_id = UUID(claims["sid"])
        except (KeyError, TypeError, ValueError):
            raise AppError("NOT_SIGNED_IN") from None

        async with self.conn.transaction():
            if not await self.repo.session_is_active(
                kind=kind, user_id=user_id, tenant_id=tenant_id, session_id=session_id
            ):
                raise AppError("NOT_SIGNED_IN")
            candidates = await self.repo.login_candidates(str(user_id), channel)
            if len(candidates) != 1:
                raise AppError("NOT_SIGNED_IN")
            user = candidates[0]
            if (user["principal_kind"] != kind or user["user_id"] != user_id
                    or user["tenant_id"] != tenant_id or not user["must_change_password"]):
                raise AppError("NOT_SIGNED_IN")
            if not await run_in_threadpool(verify_password, current_password, user["password_hash"]):
                raise AppError("INVALID_CREDENTIALS")
            if current_password == new_password:
                raise AppError("PASSWORD_REUSE")
            if kind == "TENANT":
                principal = TenantPrincipal(
                    tenant_id=tenant_id, user_id=user_id, session_id=session_id,
                    role_code=user["role_code"], channel=channel, mfa_verified=False,
                    must_change_password=True,
                )
                await set_signed_tenant_context(self.conn, principal, request, self.settings)
                hashes = await self.repo.password_hashes()
                for previous_hash in hashes:
                    if await run_in_threadpool(verify_password, new_password, previous_hash):
                        raise AppError("PASSWORD_REUSE")
            new_hash = await run_in_threadpool(hash_password, new_password, minimum_length=10)
            if kind == "TENANT":
                changed = await self.repo.change_own_password(user["password_hash"], new_hash)
            else:
                result = await (await self.conn.execute(
                    "SELECT iam.complete_initial_password_change(%s,%s,%s,%s,%s) AS changed",
                    (kind, user_id, tenant_id, user["password_hash"], new_hash),
                )).fetchone()
                changed = bool(result["changed"])
            if not changed:
                raise AppError("PASSWORD_CHANGE_NOT_REQUIRED")
            user["password_hash"] = new_hash
            user["must_change_password"] = False
            response = self._issue_token(user, channel, session_id)
        return response

    async def logout(self, token: str) -> None:
        claims = self._decode_password_change_token(token)
        try:
            user_id = UUID(claims["sub"])
            session_id = UUID(claims["sid"])
            kind = "PLATFORM" if "platform_role" in claims else "TENANT"
            tenant_id = UUID(claims["tenant_id"]) if kind == "TENANT" else None
        except (KeyError, TypeError, ValueError):
            raise AppError("NOT_SIGNED_IN") from None
        async with self.conn.transaction():
            await self.repo.revoke_session(
                kind=kind, user_id=user_id, tenant_id=tenant_id, session_id=session_id
            )

    async def change_password(
        self, *, tenant_id: UUID, user_id: UUID, channel: str,
        current_password: str, new_password: str,
    ) -> None:
        async with self.conn.transaction():
            candidates = await self.repo.login_candidates(str(user_id), channel)
            user = next((item for item in candidates if item["tenant_id"] == tenant_id), None)
            if user is None:
                raise AppError("NOT_SIGNED_IN")
            if not await run_in_threadpool(verify_password, current_password, user["password_hash"]):
                raise AppError("INVALID_CREDENTIALS")
            if current_password == new_password:
                raise AppError("PASSWORD_REUSE")
            hashes = await self.repo.password_hashes()
            for previous_hash in hashes:
                if await run_in_threadpool(verify_password, new_password, previous_hash):
                    raise AppError("PASSWORD_REUSE")
            new_hash = await run_in_threadpool(hash_password, new_password, minimum_length=10)
            if not await self.repo.change_own_password(user["password_hash"], new_hash):
                raise AppError("CONCURRENT_UPDATE")

    async def reset_tenant_user_password(self, *, user_id: UUID) -> None:
        default_hash = await run_in_threadpool(hash_password, INITIAL_DEFAULT_PASSWORD, minimum_length=1)
        if not await self.repo.reset_user_password(user_id, default_hash):
            raise AppError("USER_NOT_FOUND")

    def _decode_password_change_token(self, token: str) -> dict[str, Any]:
        candidates = (
            (self.settings.platform_jwt_secret, self.settings.platform_jwt_issuer,
             self.settings.platform_jwt_audience),
            (self.settings.tenant_jwt_secret, self.settings.tenant_jwt_issuer,
             self.settings.tenant_jwt_audience),
        )
        for secret, issuer, audience in candidates:
            if secret is None:
                continue
            try:
                return jwt.decode(
                    token, secret.get_secret_value(), algorithms=["HS256"],
                    issuer=issuer, audience=audience,
                    options={"require": ["sub", "sid", "iss", "aud", "exp"]},
                )
            except jwt.InvalidTokenError:
                continue
        raise AppError("NOT_SIGNED_IN")
