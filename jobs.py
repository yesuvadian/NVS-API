"""Run CFMS background jobs for every active organisation.

    python jobs.py loan-status                       # today's working date per tenant
    python jobs.py loan-status --date 2026-07-11     # a specific working date
    python jobs.py loan-status --tenant demo         # one organisation (code or id)

loan-status calls loan.run_daily_status() (db/32_functions_loan_servicing.sql):
approval expiry, overdue, back to current and default. Each tenant runs in its
own transaction, so one failing organisation does not stop the others; the
failure is written to platform.job_run.

It connects as the runtime role (CFMS_DB_HOST/PORT/NAME/USER/PASSWORD in .env,
the same as the API) and
signs the database context with CFMS_DB_CONTEXT_SIGNING_KEY, exactly as the API
does. Schedule it once a day (cron or Windows Task Scheduler), after midnight in
the tenants' time zone; job_definition suggests 00:15 for LOAN_STATUS_DAILY.
Exit code: 0 when every tenant succeeded, 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import sys
from datetime import date

import psycopg
from psycopg.rows import dict_row

from app.core.config import DatabaseNotConfigured, get_settings

JOBS = {"loan-status": ("LOAN_STATUS_DAILY", "SELECT loan.run_daily_status(%s, 'SCHEDULE') AS result")}


def set_system_context(conn: psycopg.Connection, tenant_id, working_date: date | None, key: bytes) -> None:
    conn.execute(
        "SELECT app.set_context(%s, NULL, 'SYSTEM', 'SYSTEM', %s, NULL, 'jobs.py', true, NULL)",
        (tenant_id, working_date),
    )
    payload = conn.execute("SELECT app.context_payload() AS payload").fetchone()["payload"]
    signature = hmac.new(key, payload.encode("utf-8"), hashlib.sha256).hexdigest()
    conn.execute("SELECT set_config('app.context_signature', %s, true)", (signature,))


def tenants(conn: psycopg.Connection, only: str | None) -> list[dict]:
    rows = conn.execute(
        "SELECT id, code FROM platform.tenant WHERE status = 'ACTIVE' ORDER BY code"
    ).fetchall()
    if only:
        rows = [r for r in rows if only in (r["code"], str(r["id"]))]
    return rows


def run(job: str, working_date: date | None, only: str | None) -> int:
    settings = get_settings()
    if settings.db_context_signing_key is None:
        print("CFMS_DB_CONTEXT_SIGNING_KEY is not set", file=sys.stderr)
        return 1
    try:
        dsn = settings.database_url
    except DatabaseNotConfigured as exc:
        print(exc, file=sys.stderr)
        return 1
    key = bytes.fromhex(settings.db_context_signing_key.get_secret_value())
    job_code, sql = JOBS[job]
    failures = 0
    with psycopg.connect(dsn, row_factory=dict_row) as conn:
        targets = tenants(conn, only)
        conn.commit()
        if not targets:
            print("No active organisation matched")
            return 1
        for tenant in targets:
            try:
                with conn.transaction():
                    set_system_context(conn, tenant["id"], working_date, key)
                    result = conn.execute(sql, (working_date,)).fetchone()["result"]
                print(f"[ OK ] {tenant['code']}: {json.dumps(result)}")
            except psycopg.Error as exc:
                message = exc.diag.message_primary or str(exc)
                if exc.diag.message_hint == "JOB_ALREADY_RUNNING":
                    # Another run (cron or manual) holds this organisation; it is not a failure.
                    print(f"[SKIP] {tenant['code']}: {message}")
                    continue
                failures += 1
                print(f"[FAIL] {tenant['code']}: {message}")
                try:
                    with conn.transaction():
                        set_system_context(conn, tenant["id"], working_date, key)
                        conn.execute(
                            "SELECT loan.record_job_failure(%s, coalesce(%s, app.working_date()), 'SCHEDULE', %s)",
                            (job_code, working_date, message),
                        )
                except psycopg.Error as log_exc:
                    print(f"       could not record the failure: {log_exc}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("job", choices=sorted(JOBS))
    parser.add_argument("--date", type=date.fromisoformat, help="working date (default: tenant today)")
    parser.add_argument("--tenant", help="organisation code or id (default: all active)")
    args = parser.parse_args()
    return run(args.job, args.date, args.tenant)


if __name__ == "__main__":
    sys.exit(main())
