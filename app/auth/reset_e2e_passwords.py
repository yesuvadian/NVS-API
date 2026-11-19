"""Rotate local Flutter E2E passwords and sync the two seeded accounts."""

from __future__ import annotations

import json
import argparse
import secrets
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

from app.core.config import get_settings
from app.core.passwords import hash_password


CONFIG_PATH = Path(__file__).resolve().parents[2] / "flutter" / "e2e_config.json"
PASSWORD_FIELDS = (
    ("E2E_SUPERADMIN_USER", "E2E_SUPERADMIN_PASSWORD", "PLATFORM"),
    ("E2E_ADMIN_USER", "E2E_ADMIN_PASSWORD", "TENANT"),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--platform-only", action="store_true",
        help="rotate only the Super Admin when the local demo tenant has no Org Admin account",
    )
    args = parser.parse_args()
    original = CONFIG_PATH.read_text(encoding="utf-8")
    config = json.loads(original)
    new_passwords: list[tuple[str, str, str]] = []
    fields = PASSWORD_FIELDS[:1] if args.platform_only else PASSWORD_FIELDS
    for user_key, password_key, kind in fields:
        identifier = config.get(user_key)
        if not isinstance(identifier, str) or not identifier.strip():
            raise ValueError(f"Missing {user_key} in local E2E config")
        password = secrets.token_urlsafe(24)
        config[password_key] = password
        new_passwords.append((identifier, password, kind))

    try:
        with psycopg.connect(get_settings().seed_database_url, row_factory=dict_row) as conn:
            for identifier, _password, kind in new_passwords:
                matches = conn.execute(
                    "SELECT count(*) AS count FROM iam.login_candidates(%s,'WEB') WHERE principal_kind=%s",
                    (identifier, kind),
                ).fetchone()["count"]
                if matches != 1:
                    raise RuntimeError(
                        f"{kind} account lookup must resolve to exactly one active identity; found {matches}"
                    )
            CONFIG_PATH.write_text(
                json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            for identifier, password, kind in new_passwords:
                encoded = hash_password(password)
                changed = conn.execute(
                    "SELECT iam.reset_e2e_account_password(%s,%s,%s) AS changed",
                    (identifier, kind, encoded),
                ).fetchone()["changed"]
                if not changed:
                    raise RuntimeError(f"{kind} E2E password reset did not update exactly one account")
    except Exception:
        CONFIG_PATH.write_text(original, encoding="utf-8")
        raise

    labels = "Super Admin" if args.platform_only else "Super Admin and Org Admin"
    print(f"Local Flutter E2E password rotated and synced for {labels}.")
    print("Updated accounts are active, unlocked, and set to sign in without a password-change prompt.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
