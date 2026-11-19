"""Read-only/rollback database integration checks for the auth seed functions."""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import psycopg
import pytest

from app.core.config import DatabaseNotConfigured, get_settings


def _connect():
    try:
        return psycopg.connect(get_settings().seed_database_url)
    except (DatabaseNotConfigured, psycopg.OperationalError) as exc:
        pytest.skip(f"Local PostgreSQL is unavailable: {type(exc).__name__}")


def test_auth_seed_installs_password_settings_and_translations() -> None:
    with _connect() as conn:
        history_owner, history_depth = conn.execute("""
            SELECT d.editable_by, i.value #>> '{}'
              FROM platform.setting_definition d
              JOIN platform.settings_template_item i USING (setting_key)
             WHERE d.setting_key='users.password_history' AND i.version_no=1
        """).fetchone()
        single_owner, single_default = conn.execute("""
            SELECT d.editable_by, i.value #>> '{}'
              FROM platform.setting_definition d
              JOIN platform.settings_template_item i USING (setting_key)
             WHERE d.setting_key='users.single_session' AND i.version_no=1
        """).fetchone()
        translated = conn.execute("""
            SELECT translations ? 'ta' FROM platform.error_code
             WHERE short_code IN ('PASSWORD_REUSE','ACTIVE_SESSION_EXISTS','ACCOUNT_LOCKED')
        """).fetchall()
        assert history_owner == "SUPER_ADMIN" and history_depth == "5"
        assert single_owner == "SUPER_ADMIN" and single_default == "false"
        assert translated and all(row[0] for row in translated)


def test_ui_page_size_is_an_org_setting_with_default_fifteen() -> None:
    with _connect() as conn:
        conn.execute("SET app.scope TO 'platform'")
        result = conn.execute("""
            SELECT d.editable_by, i.value #>> '{}'
              FROM platform.setting_definition d
              JOIN platform.settings_template_item i USING (setting_key)
             WHERE d.setting_key='ui.page_size' AND i.version_no=1
        """).fetchone()
        assert result == ('ORG_ADMIN', '15')
        missing = conn.execute("""
            SELECT count(*) FROM platform.tenant t
             WHERE NOT EXISTS (
                 SELECT 1 FROM cfg.tenant_setting s
                  WHERE s.tenant_id=t.id AND s.setting_key='ui.page_size'
                    AND s.status='ACTIVE'
             )
        """).fetchone()[0]
        assert missing == 0
        function = conn.execute("""
            SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE (n.nspname='cfg' AND p.proname IN
                    ('get_ui_page_size','request_ui_page_size','decide_ui_page_size'))
                OR (n.nspname='iam' AND p.proname='list_tenant_users'
                    AND pg_get_function_identity_arguments(p.oid)='p_offset integer')
        """).fetchone()[0]
        assert function == 4


def test_password_history_lookup_is_bound_to_signed_context() -> None:
    with _connect() as conn:
        signatures = conn.execute("""
            SELECT pg_get_function_identity_arguments(p.oid)
              FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='iam' AND p.proname='get_password_hashes_for_policy'
        """).fetchall()
        assert signatures == [('',)]
        # A runtime DB connection without a signed user context cannot fetch
        # password hashes for a caller-selected tenant/user.
        assert conn.execute(
            "SELECT count(*) FROM iam.get_password_hashes_for_policy()"
        ).fetchone()[0] == 0


def test_database_session_record_can_be_revoked_and_rolled_back() -> None:
    session_id, user_id = uuid4(), uuid4()
    with _connect() as conn:
        try:
            with conn.transaction():
                prepared = conn.execute("""
                    SELECT iam.prepare_auth_session('PLATFORM',%s,NULL,%s,%s,false,'127.0.0.1','integration-test')
                """, (user_id, session_id, datetime.now(UTC) + timedelta(minutes=5))).fetchone()[0]
                assert prepared is True
                assert conn.execute("SELECT iam.is_auth_session_active('PLATFORM',%s,NULL,%s)",
                                    (user_id, session_id)).fetchone()[0] is True
                assert conn.execute("SELECT iam.revoke_auth_session('PLATFORM',%s,NULL,%s)",
                                    (user_id, session_id)).fetchone()[0] is True
                assert conn.execute("SELECT iam.is_auth_session_active('PLATFORM',%s,NULL,%s)",
                                    (user_id, session_id)).fetchone()[0] is False
                raise _Rollback()
        except _Rollback:
            pass


class _Rollback(Exception):
    pass
