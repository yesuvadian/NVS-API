"""Real PostgreSQL coverage for published button metadata and action sequences."""

from __future__ import annotations

import copy
import json

import pytest

from app.repositories.workflow import WorkflowRepository
from app.services.loans import LoanService
from app.workflow.actions import discover
from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


async def _published_workflow(db: LoanDb, tenant) -> dict:
    await db.act(tenant, None, tenant.d0)
    return await db.row(
        """SELECT v.id, v.workflow_definition_id, v.version_no, v.definition, v.json_schema_id
             FROM cfg.workflow_version v
            WHERE v.id = cfg.workflow_version_at('LOAN_APPLICATION', %s, %s)""",
        (tenant.d0, tenant.id),
    )


async def _publish(db: LoanDb, tenant, definition: dict, current: dict) -> None:
    next_version = await db.val(
        "SELECT max(version_no) + 1 FROM cfg.workflow_version WHERE workflow_definition_id=%s",
        (current["workflow_definition_id"],),
    )
    definition["version"] = next_version
    await db.conn.execute(
        "UPDATE cfg.workflow_version SET status='RETIRED' "
        "WHERE workflow_definition_id=%s AND status='PUBLISHED' AND effective_from=%s",
        (current["workflow_definition_id"], tenant.d0),
    )
    await db.conn.execute(
        """INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                             json_schema_id, effective_from, reason, source)
           VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Button sequence integration test','DESIGNER')""",
        (tenant.id, current["workflow_definition_id"], next_version, json.dumps(definition),
         current["json_schema_id"], tenant.d0),
    )


def test_published_buttons_drive_localised_inputs_and_ordered_action_execution():
    async def scenario(db: LoanDb):
        seeded = await db.val(
            """SELECT platform.loan_workflow_buttons(v.definition)
                 FROM platform.config_template t
                 JOIN platform.config_template_version v ON v.template_id=t.id AND v.version_no=3
                WHERE t.code='LOAN_APPLICATION'"""
        )
        seeded_withdraw = next(row for row in seeded["transitions"] if row.get("code") == "WITHDRAW")
        section = seeded_withdraw["input"]["x-sections"][0]
        assert section["title"]["en"] and section["title"]["ta"]
        assert "reason" in section["fields"]

        tenant = await db.new_tenant()
        await WorkflowRepository(db.conn).sync_actions(
            [action.describe() for action in discover().values()]
        )
        current = await _published_workflow(db, tenant)
        definition = copy.deepcopy(current["definition"])
        # This scenario isolates one branch so the action sequence is exercised
        # once. The seeded workflow has two SUBMIT conditions, each with its
        # own sequence.
        submit = next(row for row in definition["transitions"]
                      if row["on"] == "SUBMIT" and row.get("to") == "MANAGER_APPROVAL")
        definition["transitions"] = [row for row in definition["transitions"]
                                      if (row["on"] != "SUBMIT" or row is submit)
                                      and row.get("from") != "FEE_COLLECTION"
                                      and row.get("to") != "FEE_COLLECTION"]
        definition["stages"] = [row for row in definition["stages"] if row["code"] != "FEE_COLLECTION"]
        submit["actions"] = [
            {"seq": 1, "code": "CREATE_APPROVAL_REQUEST", "onError": "ROLLBACK"},
            {"seq": 2, "code": "VALIDATE_APPLICATION_FEE", "onError": "ROLLBACK"},
        ]
        await _publish(db, tenant, definition, current)

        version = await _published_workflow(db, tenant)
        button = next(row for row in version["definition"]["transitions"] if row.get("code") == "SUBMIT")
        assert button["label"]["en"] == "Submit"
        assert button["label"]["ta"] == "சமர்ப்பி"
        assert [action["seq"] for action in button["actions"]] == [1, 2]

        withdraw = next(row for row in version["definition"]["transitions"] if row.get("code") == "WITHDRAW")
        withdraw["input"]["x-sections"] = [{
            "code": "WITHDRAWAL_DETAILS",
            "title": {"en": "Withdrawal details", "ta": "திரும்பப் பெறும் விவரங்கள்", "hi": "वापसी विवरण"},
            "fields": ["reason"],
        }]
        withdraw["input"]["properties"]["reason"]["title"]["hi"] = "कारण"
        validation = await db.val(
            "SELECT cfg.validate_workflow_buttons(%s::jsonb, %s)", (json.dumps(version["definition"]), tenant.id)
        )
        assert validation == []
        withdraw["input"]["x-sections"][0]["fields"] = ["missing_field"]
        validation = await db.val(
            "SELECT cfg.validate_workflow_buttons(%s::jsonb, %s)", (json.dumps(version["definition"]), tenant.id)
        )
        assert any("references undefined field missing_field" in message for message in validation)

        loan = await db.create_loan(tenant, member="A", amount="12000.00")
        if loan["status"] == "FEE_PENDING":
            await LoanService(db.conn).collect_application_fee(
                loan["id"], payment_mode="CASH", payment_reference="WF-BUTTON-TEST"
            )
        result = await LoanService(db.conn).submit_application(loan["id"], code="SUBMIT")
        assert result is not None
        instance_id = await db.val("SELECT workflow_instance_id FROM loan.loan WHERE id=%s", (loan["id"],))
        rows = await db.rows(
            """SELECT seq, action_code, status FROM wf.action_execution
                WHERE workflow_instance_id=%s ORDER BY seq""",
            (instance_id,),
        )
        assert [(row["seq"], row["action_code"]) for row in rows] == [
            (1, "RULE_CHECKS"),
            (2, "CREATE_APPROVAL_REQUEST"),
            (3, "VALIDATE_APPLICATION_FEE"),
            (4, "SET_STATUS"),
        ]
        assert rows[2]["status"] == "SKIPPED"  # executed in order as a composed DB check

    run_db(scenario)
