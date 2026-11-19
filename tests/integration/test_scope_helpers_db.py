"""PostgreSQL integration tests for the null-safe scope helpers (db/31e).

app.is_platform_scope() used to return NULL outside platform scope, which made
guards like `IF NOT app.is_platform_scope() THEN fail` silently pass. These
tests check the helper returns false, that a tenant user is refused by every
platform guard, and that a Super Admin in platform scope is still allowed.
"""

from __future__ import annotations

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres

PLATFORM_GUARDS = [
    ("SELECT platform.get_platform_summary()", "PLATFORM_CONTEXT_REQUIRED"),
    ("SELECT * FROM platform.list_tenant_modules(%(t)s)", "PLATFORM_CONTEXT_REQUIRED"),
    ("SELECT platform.set_tenant_module(%(t)s,'LOAN',false,'test')", "SUPER_ADMIN_REQUIRED"),
    ("SELECT platform.set_tenant_password_history(%(t)s,5)", "SUPER_ADMIN_REQUIRED"),
    ("SELECT platform.set_tenant_single_session(%(t)s,false)", "SUPER_ADMIN_REQUIRED"),
    ("SELECT * FROM platform.set_tenant_enabled(%(t)s,false,'test')", "SUPER_ADMIN_REQUIRED"),
    ("SELECT platform.get_organisation_setup_options()", "SUPER_ADMIN_REQUIRED"),
    ("SELECT platform.apply_tenant_onboarding_profile(%(t)s,'{}'::jsonb)", "SUPER_ADMIN_REQUIRED"),
    ("SELECT platform.apply_tenant_onboarding_settings(%(t)s,'{}'::jsonb)", "SUPER_ADMIN_REQUIRED"),
]


async def _admin(db: LoanDb, t) -> None:
    admin = await db.val("SELECT id FROM iam.app_user WHERE tenant_id=%s AND is_default_org_admin", (t.id,))
    await db.conn.execute("SELECT app.set_context(%s,%s,'ADM','WEB',%s,NULL,NULL,true,NULL)", (t.id, admin, t.today))


async def _super_admin(db: LoanDb, tenant_id=None) -> None:
    platform_user = await db.val("SELECT id FROM platform.platform_user ORDER BY created_at LIMIT 1")
    await db.conn.execute("SELECT app.set_platform_context(%s, %s, NULL, true, NULL)", (platform_user, tenant_id))


def test_is_platform_scope_is_false_not_null_outside_platform_scope():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await _admin(db, t)
        assert await db.val("SELECT app.is_platform_scope()") is False
        await db.conn.execute("SELECT app.clear_context()")
        assert await db.val("SELECT app.is_platform_scope()") is False
        await _super_admin(db)
        assert await db.val("SELECT app.is_platform_scope()") is True
        assert await db.val("SELECT app.context_is_valid()") is True

    run_db(scenario)


def test_every_platform_guard_refuses_a_tenant_user():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await _admin(db, t)
        for sql, code in PLATFORM_GUARDS:
            await db.fails(sql % {"t": f"'{t.id}'::uuid"}, code=code)

    run_db(scenario)


def test_super_admin_in_platform_scope_is_still_allowed():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await _super_admin(db)
        assert (await db.val("SELECT platform.get_platform_summary()"))["organisations"]["total"] >= 1
        assert (await db.val("SELECT platform.get_organisation_setup_options()"))["settings_template_version"] >= 1
        await db.conn.execute("SELECT platform.set_tenant_single_session(%s,true)", (t.id,))
        await db.conn.execute("SELECT platform.set_tenant_password_history(%s,6)", (t.id,))
        modules = await db.rows("SELECT * FROM platform.list_tenant_modules(%s)", (t.id,))
        assert any(m["module_code"] == "LOAN" for m in modules)

    run_db(scenario)
