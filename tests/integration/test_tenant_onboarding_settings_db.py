"""Live database checks for Super Admin onboarding settings and template defaults."""

from __future__ import annotations

import json

import pytest

from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


def test_super_admin_can_read_defaults_and_apply_onboarding_overrides():
    async def scenario(db: LoanDb):
        tenant = await db.new_tenant()
        platform_user = await db.val(
            "SELECT id FROM platform.platform_user ORDER BY created_at LIMIT 1"
        )
        await db.conn.execute(
            "SELECT app.set_platform_context(%s,NULL,NULL,true,NULL)",
            (platform_user,),
        )

        options = await db.val("SELECT platform.get_organisation_setup_options()")
        assert options["settings_template_version"] is not None
        assert any(item["code"] == "MEMBER" and item["is_core"] for item in options["modules"])
        assert any(item["key"] == "users.password_history" for item in options["settings"])
        assert options["defaults"]["page_size"] == 15

        await db.conn.execute(
            "SELECT platform.apply_tenant_onboarding_profile(%s,%s::jsonb)",
            (
                tenant.id,
                json.dumps({
                    "legal_name": "Onboarding Test Trust",
                    "registration_no": "REG-E2E-01",
                    "address": {"formatted": "Test address"},
                    "time_zone": "Asia/Kolkata",
                    "currency_code": "INR",
                    "data_region": "IN",
                    "is_sandbox": True,
                }),
            ),
        )
        await db.conn.execute(
            "SELECT platform.apply_tenant_onboarding_settings(%s,%s::jsonb)",
            (
                tenant.id,
                json.dumps({
                    "users.password_history": 8,
                    "users.single_session": True,
                    "ui.page_size": 25,
                }),
            ),
        )

        profile = await db.row(
            "SELECT legal_name,registration_no,address,currency_code,data_region,is_sandbox "
            "FROM platform.tenant WHERE id=%s",
            (tenant.id,),
        )
        assert profile["legal_name"] == "Onboarding Test Trust"
        assert profile["registration_no"] == "REG-E2E-01"
        assert profile["address"]["formatted"] == "Test address"
        assert profile["currency_code"].strip() == "INR"
        assert profile["data_region"] == "IN" and profile["is_sandbox"] is True

        password_history = await db.val(
            "SELECT cfg.get_setting('users.password_history',current_date,%s)#>>'{}'",
            (tenant.id,),
        )
        page_size = await db.val(
            "SELECT cfg.get_setting('ui.page_size',current_date,%s)#>>'{}'",
            (tenant.id,),
        )
        lock_state = await db.val(
            "SELECT is_locked FROM cfg.tenant_setting "
            "WHERE tenant_id=%s AND setting_key='users.password_history' "
            "ORDER BY effective_from DESC LIMIT 1",
            (tenant.id,),
        )
        assert int(password_history) == 8
        assert int(page_size) == 25
        assert lock_state is True

    run_db(scenario)
