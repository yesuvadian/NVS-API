"""PostgreSQL integration tests for module and role-privilege administration
(db/31c): immediate privilege changes gated by user_role.edit, guardrails,
audit, and module enable/disable effects on privileges and menus."""

from __future__ import annotations

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


async def _admin(db: LoanDb, t) -> None:
    """Act as the organisation's default admin (ADM) on today's date."""
    admin = await db.val("SELECT id FROM iam.app_user WHERE tenant_id=%s AND is_default_org_admin", (t.id,))
    t.users.setdefault("ADM", admin)
    await db.conn.execute("SELECT app.set_context(%s,%s,'ADM','WEB',%s,NULL,NULL,true,NULL)",
                          (t.id, admin, t.today))


async def _role_id(db: LoanDb, t, role_code: str):
    return await db.val("SELECT id FROM iam.role WHERE tenant_id=%s AND role_code=%s", (t.id, role_code))


async def _as_super_admin(db: LoanDb) -> None:
    platform_user = await db.val("SELECT id FROM platform.platform_user ORDER BY created_at LIMIT 1")
    await db.conn.execute("SELECT app.set_platform_context(%s, NULL, NULL, true, NULL)", (platform_user,))


async def _has(db: LoanDb, t, role: str, privilege: str) -> bool:
    await db.act(t, None, t.today)
    return await db.val("SELECT iam.has_privilege(%s,%s)", (t.users[role], privilege))


def test_privilege_holder_changes_another_role_immediately_with_audit():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        assert await _has(db, t, "EMP", "member.view")
        emp_role = await _role_id(db, t, "EMP")

        await _admin(db, t)
        result = await db.val("SELECT iam.set_role_privilege(%s,'member.view',false,'Front desk only')",
                              (emp_role,))
        assert result["changed"] is True and result["role_code"] == "EMP"
        assert not await _has(db, t, "EMP", "member.view")

        audit = await db.row(
            """SELECT operation, user_id, role_code, reason, reference_type, reference_id
                 FROM audit.audit_event
                WHERE tenant_id=%s AND entity_table='role_privilege' ORDER BY id DESC LIMIT 1""", (t.id,))
        assert audit["operation"] in {"DELETE", "PURGE"}   # a hard delete is audited as PURGE
        assert audit["user_id"] == t.users["ADM"] and audit["role_code"] == "ADM"
        assert audit["reason"] == "Front desk only"
        assert audit["reference_type"] == "ROLE_PRIVILEGE" and audit["reference_id"] == str(emp_role)

        await _admin(db, t)
        again = await db.val("SELECT iam.set_role_privilege(%s,'member.view',true)", (emp_role,))
        assert again["changed"] is True
        assert await _has(db, t, "EMP", "member.view")
        await _admin(db, t)
        same = await db.val("SELECT iam.set_role_privilege(%s,'member.view',true)", (emp_role,))
        assert same["changed"] is False

    run_db(scenario)


def test_user_without_role_edit_privilege_is_refused():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        mgr_role = await _role_id(db, t, "MGR")
        await db.act(t, "EMP", t.today)
        await db.fails("SELECT iam.set_role_privilege(%s,'member.view',false)", (mgr_role,), code="NO_PRIVILEGE")
        await db.fails("SELECT iam.get_role_privilege_matrix()", code="NO_PRIVILEGE")
        # Direct table writes are refused too.
        await db.fails("DELETE FROM iam.role_privilege WHERE role_id=%s", (mgr_role,), code="NO_PRIVILEGE")

    run_db(scenario)


def test_guardrails_lockout_protected_and_read_only():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        adm_role = await _role_id(db, t, "ADM")
        aud_role = await _role_id(db, t, "AUD")
        await _admin(db, t)
        await db.fails("SELECT iam.set_role_privilege(%s,'user_role.edit',false)", (adm_role,),
                       code="ROLE_ADMIN_LOCKOUT")
        await db.fails("SELECT iam.set_role_privilege(%s,'user_role.view',false)", (adm_role,),
                       code="ROLE_ADMIN_LOCKOUT")
        await db.fails("SELECT iam.set_role_privilege(%s,'workflow.edit',true)", (adm_role,),
                       code="PRIVILEGE_PROTECTED")
        await db.fails("SELECT iam.set_role_privilege(%s,'member.create',true)", (aud_role,),
                       code="READ_ONLY_ROLE")

        matrix = await db.val("SELECT iam.get_role_privilege_matrix()")
        assert matrix["can_edit"] is True
        roles = {r["role_code"]: r for r in matrix["roles"]}
        assert roles["ADM"]["is_my_role"] is True and roles["EMP"]["is_my_role"] is False
        assert "member.view" in roles["EMP"]["privileges"]
        modules = {m["module_code"]: m for m in matrix["modules"]}
        assert "LOAN" in modules
        workflow_edit = [a for a in modules.get("WORKFLOW", {"actions": []})["actions"]
                         if a["privilege_code"] == "workflow.edit"]
        assert all(a["protected"] for a in workflow_edit)

    run_db(scenario)


def test_disabled_module_hides_privileges_refuses_grants_and_comes_back():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await _as_super_admin(db)
        modules = {m["module_code"]: m for m in await db.rows("SELECT * FROM platform.list_tenant_modules(%s)",
                                                              (t.id,))}
        assert modules["LOAN"]["is_enabled"] is True
        version = modules["LOAN"]["row_version"]

        await db.fails("SELECT platform.set_tenant_module(%s,'LOAN',false,'Pause loans',%s)", (t.id, version + 5),
                       code="STALE_RECORD")
        await db.conn.execute("SELECT platform.set_tenant_module(%s,'LOAN',false,'Pause loans',%s)", (t.id, version))
        disabled = await db.row("SELECT * FROM platform.list_tenant_modules(%s) WHERE module_code='LOAN'", (t.id,))
        assert disabled["is_enabled"] is False and disabled["row_version"] == version + 1
        assert await db.val("SELECT app.is_platform_scope()") is True   # caller context restored

        # Users lose the module's privileges and menu (endpoints check has_privilege -> 403).
        assert not await _has(db, t, "EMP", "loan.view")
        await db.act(t, "EMP", t.today)
        capabilities = await db.val("SELECT iam.get_user_capabilities('EMP')")
        assert not any(p.startswith("loan.") for p in capabilities["privileges"])
        assert "LOAN" not in {m["module_code"] for m in capabilities["modules"]}

        # No grants for a disabled module.
        await _admin(db, t)
        await db.fails("SELECT iam.set_role_privilege(%s,'loan.view',true)", (await _role_id(db, t, "AUD"),),
                       code="MODULE_NOT_ENABLED")

        # Re-enabling restores the role's existing privileges.
        await _as_super_admin(db)
        await db.conn.execute("SELECT platform.set_tenant_module(%s,'LOAN',true,'Resume loans')", (t.id,))
        assert await _has(db, t, "EMP", "loan.view")

        change = await db.row(
            """SELECT action, reason FROM cfg.config_change_log
                WHERE tenant_id=%s AND object_type='MODULE' ORDER BY id DESC LIMIT 1""", (t.id,))
        assert change == {"action": "ENABLE", "reason": "Resume loans"}

    run_db(scenario)


def test_module_functions_refuse_non_platform_callers():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await _admin(db, t)
        await db.fails("SELECT * FROM platform.list_tenant_modules(%s)", (t.id,), code="PLATFORM_CONTEXT_REQUIRED")
        await db.fails("SELECT platform.set_tenant_module(%s,'LOAN',false,'x')", (t.id,),
                       code="SUPER_ADMIN_REQUIRED")
        await _as_super_admin(db)
        await db.fails("SELECT platform.set_tenant_module(%s,'NOPE',false,'x')", (t.id,), code="UNKNOWN_MODULE")

    run_db(scenario)
