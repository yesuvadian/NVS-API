import asyncio

import pytest
from psycopg import AsyncConnection, OperationalError
from psycopg.rows import dict_row

from app.repositories.loans import LoanRepository
from app.repositories.members import MemberRepository
from app.repositories.organisations import OrganisationRepository
from tests.integration.loan_harness import owner_dsn


@pytest.mark.postgres
def test_postgres_schema_and_organisation_repository() -> None:
    dsn = owner_dsn()   # CFMS_TEST_DATABASE_URL, else the schema owner settings in .env

    async def exercise_repository() -> None:
        try:
            conn = await AsyncConnection.connect(dsn, row_factory=dict_row, connect_timeout=5)
        except OperationalError as exc:
            pytest.skip(f"PostgreSQL not reachable: {exc}")
        try:
            async with conn.transaction():
                await conn.execute("SET TRANSACTION READ ONLY")
                result = await conn.execute(
                    "SELECT to_regclass('platform.tenant') AS tenant, "
                    "to_regclass('platform.platform_user') AS platform_user"
                )
                schema = await result.fetchone()
                assert schema["tenant"] is not None
                assert schema["platform_user"] is not None
                routines = await (await conn.execute(
                    """SELECT
                         to_regprocedure('acct.post_cash_receipt(uuid,numeric,text,text,text,text,uuid,jsonb)') AS cash_receipt,
                         to_regprocedure('loan.collect_application_fee(uuid,text,text)') AS loan_fee,
                         to_regprocedure('loan.record_approval_decision(uuid,text,text,numeric,integer)') AS loan_decision,
                         to_regprocedure('loan.prepare_disbursement(uuid,numeric,text,text)') AS disbursement_prepare,
                         to_regprocedure('loan.release_disbursement(uuid,uuid,text)') AS disbursement_release,
                         to_regprocedure('loan.collect_repayment(uuid,numeric,text,text)') AS repayment,
                         to_regprocedure('mbr.create_member(jsonb)') AS member_create,
                         to_regprocedure('mbr.update_member(uuid,jsonb,integer)') AS member_update,
                         to_regprocedure('loan.create_application(uuid,uuid,text,numeric,integer,boolean,uuid,jsonb,uuid,jsonb,uuid[])') AS loan_create,
                         to_regprocedure('loan.submit_application(uuid)') AS loan_submit,
                         to_regprocedure('loan.get_active_loan_types(uuid)') AS loan_types,
                         to_regprocedure('mbr.search_members(text,text,integer,integer)') AS member_search,
                         to_regprocedure('loan.search_applications(text,text,uuid,integer,integer)') AS loan_search,
                         to_regprocedure('platform.get_tenant(uuid)') AS tenant_get,
                         to_regprocedure('platform.create_translation_draft(text,uuid)') AS translation_draft,
                         to_regprocedure('platform.save_translation_entry(text,integer,text,text,text,uuid)') AS translation_save,
                         to_regprocedure('platform.publish_translation_pack(text,integer,uuid)') AS translation_publish,
                         to_regprocedure('iam.get_tenant_access(uuid,uuid,text,date,text)') AS tenant_access,
                         to_regprocedure('mbr.get_member(uuid)') AS member_get,
                         to_regprocedure('loan.get_member_eligibility_context(uuid)') AS loan_member_context,
                         to_regprocedure('loan.get_loan_settings()') AS loan_settings,
                         to_regprocedure('loan.get_application(uuid,boolean)') AS loan_get,
                         to_regprocedure('loan.count_application_nominees(uuid)') AS loan_nominee_count,
                         to_regprocedure('loan.get_current_workflow()') AS loan_workflow,
                         to_regprocedure('loan.get_workflow_version(uuid)') AS loan_workflow_version,
                         to_regprocedure('loan.validate_nominees(uuid,uuid[])') AS loan_nominees_valid,
                         to_regprocedure('loan.get_application_fee(uuid)') AS loan_fee_get,
                         to_regprocedure('loan.get_approval_inbox(integer,integer)') AS loan_inbox,
                         to_regprocedure('platform.search_tenants(text,text,integer,integer)') AS tenant_search,
                         to_regprocedure('platform.list_language_packs(text)') AS language_packs,
                         to_regprocedure('platform.search_translation_entries(text,integer,text,text,text,text,boolean,integer,integer)') AS translation_search,
                         to_regprocedure('platform.list_languages()') AS languages,
                         to_regprocedure('platform.is_active_language(text)') AS language_active,
                         to_regprocedure('platform.get_error_catalogue()') AS error_catalogue,
                         to_regprocedure('loan.get_schedule(uuid)') AS loan_schedule,
                         to_regprocedure('loan.get_repayments(uuid)') AS loan_repayments,
                         to_regprocedure('loan.get_member_loan_statement(uuid)') AS loan_statement,
                         to_regprocedure('loan.run_daily_status(date,text)') AS loan_daily_status,
                         to_regprocedure('loan.record_job_failure(text,date,text,text)') AS job_failure,
                         to_regprocedure('loan.calculate_early_settlement(uuid,date)') AS settlement_calc,
                         to_regprocedure('loan.quote_early_settlement(uuid,numeric,text)') AS settlement_quote,
                         to_regprocedure('loan.approve_early_settlement(uuid,text)') AS settlement_approve,
                         to_regprocedure('loan.collect_early_settlement(uuid,text,text)') AS settlement_collect,
                         to_regprocedure('loan.get_settlement(uuid)') AS settlement_get,
                         to_regprocedure('loan.list_settlements(uuid)') AS settlement_list"""
                )).fetchone()
                assert all(routines.values())
                missing_error_codes = await (await conn.execute(
                    """SELECT count(*) AS missing FROM (
                         SELECT DISTINCT m[1] AS short_code
                           FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace,
                                regexp_matches(p.prosrc,'app\\.fail\\(''([A-Z][A-Z0-9_]*)''','g') AS m
                          WHERE n.nspname IN ('app','platform','core','iam','cfg','wf','audit','mbr','acct','loan','ops','dep','chit','notif')
                            AND NOT EXISTS (SELECT 1 FROM platform.error_code e WHERE e.short_code=m[1])
                    ) missing_codes"""
                )).fetchone()
                assert missing_error_codes["missing"] == 0
                error = await (await conn.execute(
                    """SELECT app.error_info('CF200',NULL,'REPAYMENT_EXCEEDS_DUES') AS info"""
                )).fetchone()
                assert error["info"]["code"] == "CFMS-REPAY-2001"
                assert error["info"]["translations"]["ta"]

                rows = await OrganisationRepository(conn).list(
                    query=None, status=None, limit=5, offset=0
                )
                assert isinstance(rows, list)
                assert len(rows) <= 5
                if rows:
                    assert {"id", "code", "name", "status"}.issubset(rows[0])
                    detail = await OrganisationRepository(conn).get(rows[0]["id"])
                    assert detail is not None
                    assert detail["id"] == rows[0]["id"]

                session = await (await conn.execute("SELECT session_user AS role_name")).fetchone()
                if session["role_name"] == "nvs":
                    tenant_cursor = await conn.execute(
                        "SELECT id FROM platform.tenant WHERE code = 'demo'"
                    )
                    tenant = await tenant_cursor.fetchone()
                    if tenant:
                        await conn.execute(
                            "SELECT app.set_context(%s, NULL, 'DB', 'DB', NULL, NULL, NULL, true, NULL)",
                            (tenant["id"],),
                        )
                        loans = LoanRepository(conn)
                        loan_types = await loans.list_types()
                        assert loan_types
                        applications = await loans.list_applications(
                            query=None, status=None, member_id=None, limit=5, offset=0
                        )
                        assert isinstance(applications, list)
                        members = await MemberRepository(conn).list(
                            query=None, status=None, limit=5, offset=0
                        )
                        assert isinstance(members, list)
                        member_cursor = await conn.execute(
                            "SELECT id FROM mbr.member WHERE status = 'ACTIVE' LIMIT 1"
                        )
                        member = await member_cursor.fetchone()
                        if member:
                            eligibility_context = await loans.member_eligibility_context(member["id"])
                            assert eligibility_context is not None
                            assert "has_overdue_instalment" in eligibility_context
                        settings = await loans.loan_settings()
                        assert settings["max_concurrent_loans"] >= 1
        finally:
            await conn.close()

    with asyncio.Runner(loop_factory=asyncio.SelectorEventLoop) as runner:
        runner.run(exercise_repository())
