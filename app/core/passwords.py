"""Password hashing shared by login and the operator-only initial setup CLI."""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets

_N = 1 << 15
_R = 8
_P = 1
_KEY_BYTES = 32
_MAXMEM = 64 * 1024 * 1024
_DUMMY_SALT = b"CFMS-login-dummy-salt"
INITIAL_DEFAULT_PASSWORD = "Welcome@123"


def _derive(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=_N, r=_R, p=_P,
        dklen=_KEY_BYTES, maxmem=_MAXMEM,
    )


def hash_password(password: str, *, minimum_length: int = 12) -> str:
    if len(password.encode("utf-8")) < minimum_length:
        raise ValueError(f"Passwords must be at least {minimum_length} bytes long.")
    if len(password.encode("utf-8")) > 1024:
        raise ValueError("Password is too long.")
    salt = secrets.token_bytes(16)
    digest = _derive(password, salt)
    encode = lambda value: base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")
    return f"scrypt$1${_N}${_R}${_P}${encode(salt)}${encode(digest)}"


def verify_password(password: str, encoded: str | None) -> bool:
    """Verify a CFMS scrypt hash, doing equivalent work for absent/invalid hashes."""
    if len(password.encode("utf-8")) > 1024:
        password = password[:1024]
    try:
        algorithm, version, n, r, p, salt_text, digest_text = (encoded or "").split("$")
        if (algorithm, version, int(n), int(r), int(p)) != ("scrypt", "1", _N, _R, _P):
            raise ValueError("Unsupported hash")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        salt, expected = decode(salt_text), decode(digest_text)
        if len(salt) != 16 or len(expected) != _KEY_BYTES:
            raise ValueError("Invalid hash length")
    except (AttributeError, TypeError, ValueError):
        hmac.compare_digest(_derive(password, _DUMMY_SALT), bytes(_KEY_BYTES))
        return False
    return hmac.compare_digest(_derive(password, salt), expected)
