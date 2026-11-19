"""Set the first password for a provisioned account without passing it in argv."""

from __future__ import annotations

import argparse
import sys

import psycopg
from psycopg.rows import dict_row

from app.core.config import get_settings
from app.core.passwords import INITIAL_DEFAULT_PASSWORD, hash_password


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("user_id", help="email, username, mobile number, or account UUID")
    parser.add_argument("--channel", choices=("WEB", "MOBILE"), default="WEB")
    args = parser.parse_args()

    with psycopg.connect(get_settings().seed_database_url, row_factory=dict_row) as conn:
        candidates = conn.execute(
            "SELECT * FROM iam.login_candidates(%s,%s)", (args.user_id, args.channel)
        ).fetchall()
        if len(candidates) != 1:
            print("Account lookup must match exactly one active identity. Use its UUID if needed.", file=sys.stderr)
            return 2
        account = candidates[0]
        if account["password_hash"]:
            print("This account already has a password; initial setup is only allowed once.", file=sys.stderr)
            return 2

        try:
            encoded = hash_password(INITIAL_DEFAULT_PASSWORD, minimum_length=1)
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 2

        changed = conn.execute(
            "SELECT iam.set_initial_password(%s,%s,%s,%s) AS changed",
            (account["principal_kind"], account["user_id"], account["tenant_id"], encoded),
        ).fetchone()["changed"]
        if not changed:
            print("Password was not set; the account may have changed. Retry after reviewing it.", file=sys.stderr)
            return 2

    print(f"Initial password set for {account['principal_kind'].lower()} account {account['user_id']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
