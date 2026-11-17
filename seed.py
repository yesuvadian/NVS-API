"""Apply the CFMS database scripts in db/ to a PostgreSQL database.

The script order comes from db/99_run_all.psql, so a script registered there
(for example 31_functions_api_queries.sql) is always part of the seed. All
scripts are idempotent, so the seed can be re-run on an existing database.

Run it as the schema owner (nvs), never as the runtime role (nvs_api/nvs_app):

    python seed.py                      # every script listed in 99_run_all.psql
    python seed.py --demo               # also 50_seed_demo_tenant.sql (dev only)
    python seed.py --only 31_functions_api_queries.sql
    python seed.py --list               # show the order without running

Connection: --dsn, else the schema owner settings in .env (CFMS_DB_HOST,
CFMS_DB_PORT, CFMS_DB_NAME, CFMS_SEED_DB_USER, CFMS_SEED_DB_PASSWORD; see
.env.example). The bootstrap scripts 00a/00b must be run once as postgres first
(see db/README.md).
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

import psycopg

from app.core.config import DatabaseNotConfigured, get_settings

ROOT = Path(__file__).resolve().parent
DB_DIR = ROOT / "db"
RUN_ALL = DB_DIR / "99_run_all.psql"
DEMO_SCRIPT = "50_seed_demo_tenant.sql"
INCLUDE_RE = re.compile(r"^\s*(--\s*)?\\ir\s+(\S+\.sql)\s*$")


def script_order(include_demo: bool) -> list[str]:
    """Scripts in 99_run_all.psql order; commented-out lines are skipped."""
    scripts: list[str] = []
    for line in RUN_ALL.read_text(encoding="utf-8").splitlines():
        match = INCLUDE_RE.match(line)
        if not match:
            continue
        commented, name = match.groups()
        if commented and not (include_demo and name == DEMO_SCRIPT):
            continue
        scripts.append(name)
    if include_demo and DEMO_SCRIPT not in scripts:
        scripts.append(DEMO_SCRIPT)
    return scripts


def sql_text(path: Path) -> str:
    # psql meta-commands (\echo in 90_verify.sql) are not SQL; drop them.
    lines = path.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("\\"))


def run(dsn: str, scripts: list[str]) -> int:
    with psycopg.connect(dsn, autocommit=True) as conn:
        conn.add_notice_handler(lambda diag: None)  # IF NOT EXISTS notices are noise
        who = conn.execute("SELECT current_user, current_database()").fetchone()
        print(f"Connected as {who[0]} to database {who[1]}")
        for name in scripts:
            path = DB_DIR / name
            if not path.exists():
                print(f"[FAIL] {name}: file not found")
                return 1
            started = time.perf_counter()
            try:
                # No parameters: psycopg sends the whole file in one simple
                # query, which PostgreSQL runs as a single transaction.
                conn.execute(sql_text(path))
            except psycopg.Error as exc:
                diag = exc.diag
                print(f"[FAIL] {name}: {diag.message_primary or exc}")
                if diag.context:
                    print(f"       {diag.context.strip().splitlines()[-1]}")
                print("       The failed script was rolled back; earlier scripts are kept.")
                return 1
            print(f"[ OK ] {name} ({time.perf_counter() - started:.1f}s)")
    print(f"Done: {len(scripts)} script(s) applied.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dsn", help="PostgreSQL URL of the schema owner (nvs)")
    parser.add_argument("--demo", action="store_true", help=f"also run {DEMO_SCRIPT}")
    parser.add_argument("--only", nargs="+", metavar="FILE", help="run just these scripts")
    parser.add_argument("--list", action="store_true", help="print the script order and exit")
    args = parser.parse_args()

    scripts = args.only or script_order(args.demo)
    if args.list:
        print("\n".join(scripts))
        return 0
    if args.dsn:
        dsn = args.dsn
    else:
        try:
            dsn = get_settings().seed_database_url
        except DatabaseNotConfigured as exc:
            print(f"[FAIL] {exc}")
            return 1
    return run(dsn, scripts)


if __name__ == "__main__":
    sys.exit(main())
