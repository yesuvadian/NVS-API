"""PostgreSQL integration tests: the Org Admin (ADM) role views every tenant
menu module but cannot create, edit or approve there (db/40 matrix + db/48)."""

from __future__ import annotations

from pathlib import Path

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres

MENU_VIEWS = {"member.view", "loan.view", "loan_repay.view", "fin_report.view", "approval.view",
              "org.view", "user_role.view"}
BUSINESS_MODULES = ("MEMBER", "LOAN", "LOAN_REPAY", "FIN_REPORT")
SCRIPT_48 = Path(__file__).resolve().parents[2] / "db" / "48_seed_adm_menu_views.sql"


async def _adm_privileges(db: LoanDb, tenant) -> set[str]:
    await db.act(tenant, None, tenant.d0)
    rows = await db.rows(
        """SELECT rp.privilege_code FROM iam.role_privilege rp
             JOIN iam.role r ON r.tenant_id = rp.tenant_id AND r.id = rp.role_id
            WHERE rp.tenant_id = %s AND r.role_code = 'ADM'""", (tenant.id,))
    return {row["privilege_code"] for row in rows}


def test_new_organisation_admin_views_all_menu_modules_without_maker_rights():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        held = await _adm_privileges(db, t)
        assert MENU_VIEWS <= held
        makers = {p for p in held if p.split(".")[0].upper() in BUSINESS_MODULES and not p.endswith(".view")}
        assert makers == set(), makers
        assert "loan.approve" not in held and "member.create" not in held

        template = {row["privilege_code"] for row in await db.rows(
            "SELECT privilege_code FROM platform.role_template_privilege WHERE role_code='ADM'")}
        assert {"member.view", "loan.view", "loan_repay.view", "fin_report.view"} <= template

    run_db(scenario)


def test_admin_capabilities_list_the_menu_views():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        admin = await db.val(
            "SELECT id FROM iam.app_user WHERE tenant_id=%s AND is_default_org_admin", (t.id,))
        await db.conn.execute("SELECT app.set_context(%s,%s,'ADM','WEB',%s,NULL,NULL,true,NULL)",
                              (t.id, admin, t.today))   # role assignment starts today
        capabilities = await db.val("SELECT iam.get_user_capabilities('ADM')")
        assert MENU_VIEWS <= set(capabilities["privileges"])
        modules = {m["module_code"] for m in capabilities["modules"]}
        assert {"MEMBER", "LOAN", "LOAN_REPAY", "FIN_REPORT", "APPROVAL"} <= modules

    run_db(scenario)


def test_script_48_backfills_existing_organisations_and_is_rerunnable():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, None, t.d0)
        await db.conn.execute(
            """DELETE FROM iam.role_privilege rp USING iam.role r
                WHERE r.tenant_id = rp.tenant_id AND r.id = rp.role_id AND rp.tenant_id = %s
                  AND r.role_code = 'ADM' AND rp.privilege_code IN ('member.view','loan.view')""", (t.id,))
        assert not {"member.view", "loan.view"} & await _adm_privileges(db, t)

        script = SCRIPT_48.read_text(encoding="utf-8")
        await db.conn.execute(script)
        await db.conn.execute(script)      # second run changes nothing and does not fail

        assert {"member.view", "loan.view", "loan_repay.view"} <= await _adm_privileges(db, t)

    run_db(scenario)
