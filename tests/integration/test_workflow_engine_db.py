"""PostgreSQL integration tests for the workflow engine increment:

* maker steps decided by privilege (loan.create / loan.edit), not by role;
* approval roles, amount bands, minApprovals, offline settings and
  ROUTE_TO_ROLE taken from the workflow JSON (no role in code);
* stage statuses and entity statuses from the workflow JSON;
* the execution log (wf.action_execution);
* business values from settings and rules (missing values refuse).
"""

from __future__ import annotations

import copy
import json
from decimal import Decimal as D

import pytest

from app.services.loans import LoanService
from tests.integration.loan_harness import LoanDb, run_db

pytestmark = pytest.mark.postgres


# -- helpers ------------------------------------------------------------------
async def add_role_user(db: LoanDb, t, role_code: str, privileges: list[str], *, existing: bool = False) -> None:
    """A user holding a (custom or standard) role with the given privileges;
    available as t.users[role_code] and acting with role_code."""
    await db.act(t, None, t.d0)
    if not existing:
        await db.conn.execute(
            """INSERT INTO iam.role (tenant_id, role_code, role_name, role_type)
               VALUES (%s,%s,%s,'CUSTOM')""", (t.id, role_code, f"Custom {role_code}"))
    for privilege in privileges:
        await db.conn.execute(
            """INSERT INTO platform.tenant_privilege_ceiling (tenant_id, privilege_code)
               SELECT %s, %s WHERE NOT EXISTS (SELECT 1 FROM platform.tenant_privilege_ceiling
                                                WHERE tenant_id=%s AND privilege_code=%s)""",
            (t.id, privilege, t.id, privilege))
        await db.conn.execute(
            """INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
               SELECT %s, id, %s FROM iam.role WHERE tenant_id=%s AND role_code=%s
               ON CONFLICT (tenant_id, role_id, privilege_code) DO NOTHING""", (t.id, privilege, t.id, role_code))
    if role_code in t.users:
        return
    user_id = await db.val(
        """INSERT INTO iam.app_user (tenant_id, full_name, mobile, email, web_access, mobile_access, username,
                                     primary_role_id)
           VALUES (%s,%s,%s,%s,true,false,%s,(SELECT id FROM iam.role WHERE tenant_id=%s AND role_code=%s))
           RETURNING id""",
        (t.id, f"User {role_code}", "9" + str(abs(hash(role_code)))[:9].rjust(9, "1"),
         f"{role_code.lower()}@{t.code}.example.com", f"{role_code.lower()}@{t.code}.example.com", t.id, role_code))
    await db.conn.execute(
        """INSERT INTO iam.user_role (tenant_id, user_id, role_id, effective_from, reason)
           VALUES (%s,%s,(SELECT id FROM iam.role WHERE tenant_id=%s AND role_code=%s), current_date - 365, 'Test')""",
        (t.id, user_id, t.id, role_code))
    t.users[role_code] = user_id


async def current_workflow(db: LoanDb, t) -> dict:
    await db.act(t, None, t.d0)
    return await db.row(
        """SELECT v.id, v.workflow_definition_id, v.version_no, v.definition, v.json_schema_id, v.effective_from
             FROM cfg.workflow_version v
            WHERE v.id = cfg.workflow_version_at('LOAN_APPLICATION', %s, %s)""", (t.d0, t.id))


async def publish_workflow(db: LoanDb, t, change) -> dict:
    """Publish a new LOAN_APPLICATION version (effective for loans created at
    t.d0) with ``change(definition)`` applied."""
    current = await current_workflow(db, t)
    definition = copy.deepcopy(current["definition"])
    change(definition)
    next_no = await db.val("SELECT max(version_no) + 1 FROM cfg.workflow_version WHERE workflow_definition_id=%s",
                           (current["workflow_definition_id"],))
    definition["version"] = next_no
    await db.conn.execute(
        """UPDATE cfg.workflow_version SET status='RETIRED'
            WHERE workflow_definition_id=%s AND status='PUBLISHED' AND effective_from=%s""",
        (current["workflow_definition_id"], t.d0))
    await db.conn.execute(
        """INSERT INTO cfg.workflow_version (tenant_id, workflow_definition_id, version_no, status, definition,
                                             json_schema_id, effective_from, reason, source)
           VALUES (%s,%s,%s,'PUBLISHED',%s::jsonb,%s,%s,'Engine test','DESIGNER')""",
        (t.id, current["workflow_definition_id"], next_no, json.dumps(definition), current["json_schema_id"], t.d0))
    return definition


def stage(definition: dict, code: str) -> dict:
    return next(s for s in definition["stages"] if s["code"] == code)


def transition(definition: dict, event: str) -> dict:
    return next(x for x in definition["transitions"] if x["on"] == event)


def approval(**values):
    def change(definition):
        stage(definition, "MANAGER_APPROVAL")["approval"].update(values)
    return change


async def submitted_loan(db: LoanDb, t, member: str = "A", amount: str = "12000.00", **kwargs):
    loan = await db.create_loan(t, member=member, amount=amount, **kwargs)
    await db.submit(t, loan["id"])
    request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
    return loan, request


async def decide(db: LoanDb, t, role: str, request, decision: str = "APPROVED", **values):
    await db.act(t, role, t.d0)
    return await LoanService(db.conn).decide(request, {"decision": decision, **values})


# -- maker steps by privilege -------------------------------------------------
def test_custom_role_and_adm_with_loan_create_can_create_and_submit():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await add_role_user(db, t, "FIELD_OFFICER", ["loan.view", "loan.create"])
        await add_role_user(db, t, "ADM", ["loan.view", "loan.create"], existing=True)
        await db.act(t, None, t.d0)
        t.users["ADM"] = await db.val("SELECT id FROM iam.app_user WHERE tenant_id=%s AND is_default_org_admin", (t.id,))
        for role, member in (("FIELD_OFFICER", "A"), ("ADM", "B")):
            await db.act(t, role, t.d0)
            service = LoanService(db.conn)
            loan = await service.create_application({
                "member_id": t.members[member], "loan_type_id": t.loan_types["INTEREST_BEARING"],
                "requested_amount": D("12000.00"), "requested_tenure_months": 12, "purpose": "Privilege test",
                "nominee_ids": [t.nominees[member]]})
            submitted = await service.submit_application(loan["id"])
            assert submitted["status"] == "UNDER_APPROVAL", role

    run_db(scenario)


def test_role_without_loan_create_is_refused_in_the_database():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await add_role_user(db, t, "VIEWER", ["loan.view"])
        loan = await db.create_loan(t)
        await db.act(t, "VIEWER", t.d0)
        await db.fails("SELECT loan.submit_application(%s)", (loan["id"],), code="NO_PRIVILEGE")
        await db.fails(
            """INSERT INTO loan.loan (loan_no, member_id, loan_type_id, requested_amount, requested_tenure_months,
                                      purpose, status, rule_set_version_id, workflow_version_id, application_date)
               SELECT 'X-1', member_id, loan_type_id, 1000, 12, 'x', 'DRAFT', rule_set_version_id,
                      workflow_version_id, application_date FROM loan.loan WHERE id=%s""",
            (loan["id"],), code="NO_PRIVILEGE")

    run_db(scenario)


def test_draft_edit_and_nominees_by_create_or_edit_privilege():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await add_role_user(db, t, "MAKER", ["loan.view", "loan.create"])
        await add_role_user(db, t, "EDITOR", ["loan.view", "loan.edit"])
        await add_role_user(db, t, "VIEWER", ["loan.view"])
        loan = await db.create_loan(t)
        version = loan["row_version"]
        for role in ("MAKER", "EDITOR"):
            await db.act(t, role, t.d0)
            changed = await db.val("SELECT loan.update_application(%s,%s::jsonb,%s)",
                                   (loan["id"], json.dumps({"purpose": f"Edited by {role}",
                                                            "nominee_ids": [str(t.nominees["A"])]}), version))
            assert changed["purpose"] == f"Edited by {role}" and changed["row_version"] == version + 1
            version = changed["row_version"]
        await db.act(t, "VIEWER", t.d0)
        await db.fails("SELECT loan.update_application(%s,%s::jsonb,%s)",
                       (loan["id"], json.dumps({"purpose": "No"}), version), code="NO_PRIVILEGE")
        await db.fails("SELECT loan.set_application_nominees(%s,%s::uuid[],%s)",
                       (loan["id"], [t.nominees["A"]], version), code="NO_PRIVILEGE")

        # After submission only loan.edit links nominees.
        await db.submit(t, loan["id"])
        version = await db.val("SELECT row_version FROM loan.loan WHERE id=%s", (loan["id"],))
        await db.act(t, "MAKER", t.d0)
        await db.fails("SELECT loan.set_application_nominees(%s,%s::uuid[],%s)",
                       (loan["id"], [t.nominees["A"]], version), code="NO_PRIVILEGE")
        await db.act(t, "EDITOR", t.d0)
        linked = await db.val("SELECT loan.set_application_nominees(%s,%s::uuid[],%s)",
                              (loan["id"], [t.nominees["A"]], version))
        assert linked["row_version"] == version + 1

        # A returned loan is the maker's again.
        request = await db.val("SELECT approval_request_id FROM loan.loan WHERE id=%s", (loan["id"],))
        await decide(db, t, "MGR", request, "RETURNED", reason="Fix the purpose")
        version = await db.val("SELECT row_version FROM loan.loan WHERE id=%s", (loan["id"],))
        await db.act(t, "MAKER", t.d0)
        changed = await db.val("SELECT loan.update_application(%s,%s::jsonb,%s)",
                               (loan["id"], json.dumps({"purpose": "Fixed"}), version))
        assert changed["purpose"] == "Fixed" and changed["status"] == "RETURNED"

    run_db(scenario)


def test_patch_nominees_go_through_the_nominee_checks():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan = await db.create_loan(t)
        await db.act(t, None, t.d0)
        await db.set_setting(t, "loans.max_nominees_per_loan", 1)
        await db.act(t, "EMP", t.d0)
        await db.fails("SELECT loan.update_application(%s,%s::jsonb,%s)",
                       (loan["id"], json.dumps({"nominee_ids": [str(t.nominees["A"]), str(t.nominees["B"])]}),
                        loan["row_version"]), code="INVALID_DATA")
        await db.fails("SELECT loan.update_application(%s,%s::jsonb,%s)",       # another member's nominee
                       (loan["id"], json.dumps({"nominee_ids": [str(t.nominees["B"])]}), loan["row_version"]),
                       code="NOMINEE_NOT_ACTIVE")

    run_db(scenario)


# -- approvals from the workflow JSON ------------------------------------------
def test_approval_roles_and_amount_bands_come_from_the_stage():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await publish_workflow(db, t, approval(roles=["MGR"], amountBands=[{"minAmount": 10000, "roles": ["LDR"]}]))
        _small, small_request = await submitted_loan(db, t, member="A", amount="6000.00")
        _big, big_request = await submitted_loan(db, t, member="B", amount="12000.00")
        await db.act(t, None, t.d0)
        roles = {r["id"]: r["approver_roles"] for r in await db.rows(
            "SELECT id, approver_roles FROM wf.approval_request WHERE id = ANY(%s)", ([small_request, big_request],))}
        assert roles[small_request] == ["MGR"] and roles[big_request] == ["LDR"]
        await db.app_fails("APPROVER_ROLE_REQUIRED", lambda: decide(db, t, "MGR", big_request))

    run_db(scenario)


def test_published_workflow_can_add_remove_rule_checks_and_change_approver_role():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()

        def require_nominee_and_set_approver_role(definition):
            stage(definition, "MANAGER_APPROVAL")["approval"].update(roles=["MGR"])
            transition(definition, "APPROVE")["ruleChecks"] = [
                {"code": "NOMINEE", "onFail": "BLOCK"}
            ]

        await publish_workflow(db, t, require_nominee_and_set_approver_role)
        _loan, first_request = await submitted_loan(db, t, member="A", nominee=False)
        await db.app_fails("NOMINEE_REQUIRED", lambda: decide(db, t, "MGR", first_request))

        def remove_check_and_change_role(definition):
            stage(definition, "MANAGER_APPROVAL")["approval"].update(roles=["LDR"])
            transition(definition, "APPROVE")["ruleChecks"] = []

        await publish_workflow(db, t, remove_check_and_change_role)
        loan, request = await submitted_loan(db, t, member="B", nominee=False)
        await db.app_fails("APPROVER_ROLE_REQUIRED", lambda: decide(db, t, "MGR", request))
        result = await decide(db, t, "LDR", request)
        assert result["decision"] == "APPROVED"
        assert await db.status(loan["id"]) == "APPROVED"

    run_db(scenario)


def test_band_approver_decides():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await publish_workflow(db, t, approval(amountBands=[{"minAmount": 10000, "roles": ["LDR"]}]))
        loan, request = await submitted_loan(db, t)
        result = await decide(db, t, "LDR", request)
        assert result["decision"] == "APPROVED" and await db.status(loan["id"]) == "APPROVED"

    run_db(scenario)


def test_min_approvals_needs_distinct_approvers():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await add_role_user(db, t, "MGR", [], existing=True)
        await db.act(t, None, t.d0)
        second = await db.val(
            """INSERT INTO iam.app_user (tenant_id, full_name, mobile, email, web_access, mobile_access, username,
                                         primary_role_id)
               VALUES (%s,'Second Manager','9000000999',%s,true,false,%s,
                       (SELECT id FROM iam.role WHERE tenant_id=%s AND role_code='MGR')) RETURNING id""",
            (t.id, f"mgr2@{t.code}.example.com", f"mgr2@{t.code}.example.com", t.id))
        await db.conn.execute(
            """INSERT INTO iam.user_role (tenant_id, user_id, role_id, effective_from, reason)
               VALUES (%s,%s,(SELECT id FROM iam.role WHERE tenant_id=%s AND role_code='MGR'), current_date-365,'T')""",
            (t.id, second, t.id))
        await publish_workflow(db, t, approval(minApprovals=2))
        loan, request = await submitted_loan(db, t)

        first = await decide(db, t, "MGR", request)
        assert first["decision"] == "APPROVAL_RECORDED" and first["approvals_needed"] == 1
        assert await db.status(loan["id"]) == "UNDER_APPROVAL"
        await db.act(t, None, t.d0)
        assert await db.val("""SELECT i.current_stage_status FROM wf.workflow_instance i JOIN loan.loan l
                                 ON l.workflow_instance_id=i.id WHERE l.id=%s""", (loan["id"],)) == "PARTIALLY_APPROVED"
        await db.app_fails("APPROVAL_ALREADY_GIVEN", lambda: decide(db, t, "MGR", request))

        t.users["MGR2"] = second
        await db.conn.execute("SELECT app.set_context(%s,%s,'MGR','WEB',%s,NULL,NULL,true,NULL)",
                              (t.id, second, t.d0))
        done = await LoanService(db.conn).decide(request, {"decision": "APPROVED"})
        assert done["decision"] == "APPROVED" and await db.status(loan["id"]) == "APPROVED"

    run_db(scenario)


def test_offline_settings_come_from_the_stage():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await publish_workflow(db, t, approval(allowOfflineRecording=False))
        _loan, request = await submitted_loan(db, t, member="A")
        await db.act(t, "EMP2", t.d0)
        details = json.dumps({"decision": "APPROVED", "approved_by": str(t.users["MGR"]), "evidence_type": "VERBAL",
                              "reason": "Phoned in"})
        await db.fails("SELECT loan.record_offline_approval(%s,%s::jsonb)", (request, details),
                       code="OFFLINE_NOT_ALLOWED")

    run_db(scenario)


def test_offline_recorder_roles_come_from_the_stage():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await publish_workflow(db, t, approval(allowOfflineRecording=True, offlineRecorderRoles=["ACC"]))
        _loan, request = await submitted_loan(db, t, member="A")
        details = json.dumps({"decision": "APPROVED", "approved_by": str(t.users["MGR"]), "evidence_type": "VERBAL",
                              "reason": "Phoned in"})
        await db.act(t, "EMP2", t.d0)
        await db.fails("SELECT loan.record_offline_approval(%s,%s::jsonb)", (request, details),
                       code="OFFLINE_RECORDER_ROLE_REQUIRED")

    run_db(scenario)


def test_route_to_role_hands_the_request_over():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()

        def route(definition):
            transition(definition, "APPROVE")["ruleChecks"] = [
                {"code": "NOMINEE", "onFail": "ROUTE_TO_ROLE", "roles": ["LDR"]}, "GUARANTORS"]
        await publish_workflow(db, t, route)
        loan, request = await submitted_loan(db, t, member="A", nominee=False)

        routed = await decide(db, t, "MGR", request)
        assert routed["decision"] == "ROUTED" and routed["routed_to"] == ["LDR"] and routed["checks"] == ["NOMINEE"]
        await db.act(t, None, t.d0)
        state = await db.val("SELECT wf.approval_request_state(%s)", (request,))
        assert state["approver_roles"] == ["LDR"] and state["routed_checks"] == ["NOMINEE"]
        assert await db.status(loan["id"]) == "UNDER_APPROVAL"

        done = await decide(db, t, "LDR", request)
        assert done["decision"] == "APPROVED"

    run_db(scenario)


# -- statuses and the execution log ---------------------------------------------
def test_execution_log_and_statuses_follow_the_json():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan, request = await submitted_loan(db, t)
        await decide(db, t, "MGR", request)
        await db.act(t, None, t.d0)
        instance = await db.val("SELECT workflow_instance_id FROM loan.loan WHERE id=%s", (loan["id"],))
        steps = [(r["stage_code"], r["action_code"]) for r in await db.rows(
            "SELECT stage_code, action_code FROM wf.action_execution WHERE workflow_instance_id=%s "
            "ORDER BY started_at", (instance,))]
        assert steps == [("DRAFT", "RULE_CHECKS"), ("DRAFT", "CREATE_APPROVAL_REQUEST"), ("DRAFT", "SET_STATUS"),
                         ("MANAGER_APPROVAL", "RULE_CHECKS"), ("MANAGER_APPROVAL", "RECORD_APPROVAL_DECISION"),
                         ("MANAGER_APPROVAL", "SET_STATUS")]
        status = await db.row("SELECT current_stage_code, current_stage_status FROM wf.workflow_instance WHERE id=%s",
                              (instance,))
        assert status == {"current_stage_code": "APPROVED", "current_stage_status": "PENDING"}
        log = await db.val("""SELECT result FROM wf.action_execution WHERE workflow_instance_id=%s
                               AND action_code='SET_STATUS' ORDER BY started_at DESC LIMIT 1""", (instance,))
        assert log["recorded"] == "APPROVED" and log["entity_status"] == "APPROVED"

    run_db(scenario)


def test_every_workflow_initializes_in_its_first_configured_stage():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        workflow = await current_workflow(db, t)
        definition = copy.deepcopy(workflow["definition"])
        definition["stages"][0], definition["stages"][1] = definition["stages"][1], definition["stages"][0]
        errors = await db.val("SELECT cfg.validate_workflow(%s::jsonb,%s)", (json.dumps(definition), t.id))
        assert any("startStage must be the first workflow stage" in error for error in errors)

        loan = await db.create_loan(t)
        await db.act(t, None, t.d0)
        state = await db.row("""SELECT i.current_stage_code, i.current_stage_status, l.status
                                  FROM wf.workflow_instance i JOIN loan.loan l ON l.workflow_instance_id=i.id
                                 WHERE l.id=%s""", (loan["id"],))
        init = next(s for s in workflow["definition"]["stages"]
                    if s["code"] == workflow["definition"]["startStage"])
        assert state["current_stage_code"] == workflow["definition"]["startStage"]
        assert state["current_stage_status"] == init["statuses"]["initial"]
        assert state["status"] == init["statuses"]["entityStatus"]

        await db.submit(t, loan["id"])
        moved = await db.row("""SELECT i.current_stage_code, l.status FROM wf.workflow_instance i
                                  JOIN loan.loan l ON l.workflow_instance_id=i.id WHERE l.id=%s""", (loan["id"],))
        submit = next(x for x in workflow["definition"]["transitions"]
                      if x["on"] == "SUBMIT" and x["from"] == workflow["definition"]["startStage"]
                      and x.get("when", {}).get("all", [{}])[0].get("value") is False)
        next_stage = next(s for s in workflow["definition"]["stages"] if s["code"] == submit["to"])
        assert moved["current_stage_code"] == next_stage["code"]
        assert moved["status"] == next_stage["statuses"]["entityStatus"]
    run_db(scenario)


def test_new_version_renames_stage_statuses_and_sets_entity_status():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()

        def rename(definition):
            statuses = stage(definition, "MANAGER_APPROVAL")["statuses"]
            statuses["stageStatuses"].append({"code": "AWAITING_COMMITTEE", "label": {"en": "With committee"}})
            statuses["initial"] = "AWAITING_COMMITTEE"
            statuses["entityStatus"] = "SUBMITTED"          # this organisation calls it SUBMITTED
        await publish_workflow(db, t, rename)
        loan, _request = await submitted_loan(db, t)
        await db.act(t, None, t.d0)
        assert await db.status(loan["id"]) == "SUBMITTED"
        assert await db.val("""SELECT i.current_stage_status FROM wf.workflow_instance i JOIN loan.loan l
                                 ON l.workflow_instance_id=i.id WHERE l.id=%s""", (loan["id"],)) == "AWAITING_COMMITTEE"

    run_db(scenario)


@pytest.mark.parametrize(("change", "message"), [
    (lambda d: stage(d, "APPROVED")["statuses"].update(entityStatus="HALF_DONE"), "entityStatus HALF_DONE"),
    (lambda d: stage(d, "DRAFT")["statuses"]["stageStatuses"].append(
        {"code": stage(d, "DRAFT")["statuses"]["stageStatuses"][0]["code"]}), "unique"),
    (lambda d: stage(d, "DRAFT")["statuses"].update(initial="NOPE"), "initial NOPE"),
    (lambda d: transition(d, "APPROVE").update(stageStatus="FINISHED"), "stageStatus FINISHED"),
    (lambda d: transition(d, "RETURN").update(entityStatus="LOST"), "entityStatus LOST"),
    (lambda d: stage(d, "DRAFT").update(actorPrivilege="loan.nothing"), "actorPrivilege loan.nothing"),
])
def test_invalid_statuses_are_refused_on_publish(change, message):
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        error = await db.app_fails("INVALID_DOCUMENT", lambda: publish_workflow(db, t, change))
        assert message in error.diag.message_primary

    run_db(scenario)


# -- business values from settings and rules ------------------------------------
def test_disbursement_window_and_approver_roles_come_from_settings():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        await db.act(t, None, t.d0)
        await db.set_setting(t, "loans.disbursement_window_days", 10)
        loan, request = await submitted_loan(db, t)
        await decide(db, t, "MGR", request)
        await db.act(t, None, t.d0)
        expires = await db.val("SELECT approval_expires_on FROM loan.loan WHERE id=%s", (loan["id"],))
        assert (expires - t.d0).days == 10

    run_db(scenario)


def test_missing_setting_refuses_instead_of_defaulting():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        _loan, request = await submitted_loan(db, t)
        await db.act(t, None, t.d0)
        await db.conn.execute("DELETE FROM cfg.tenant_setting WHERE tenant_id=%s "
                              "AND setting_key='loans.disbursement_window_days'", (t.id,))
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED')", (request,), code="SETTING_MISSING")

    run_db(scenario)


def test_interest_rule_method_is_required():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan, request = await submitted_loan(db, t)
        await db.act(t, None, t.d0)
        await db.set_rule(loan["id"], "INTEREST", {"value": {"annualRatePercent": 12}})
        await db.act(t, "MGR", t.d0)
        await db.fails("SELECT loan.record_approval_decision(%s,'APPROVED')", (request,), code="LOAN_RULE_MISSING")

    run_db(scenario)


def test_offline_decision_runs_the_same_transition():
    async def scenario(db: LoanDb):
        t = await db.new_tenant()
        loan, request = await submitted_loan(db, t, member="A")
        await db.act(t, "EMP2", t.d0)
        result = await LoanService(db.conn).record_offline_decision(request, {
            "decision": "approved", "approved_by": str(t.users["MGR"]), "evidence_type": "VERBAL",
            "reason": "Phoned in"})
        assert result["decision"] == "APPROVED" and result["approval_channel"] == "OFFLINE"
        await db.act(t, None, t.d0)
        assert await db.status(loan["id"]) == "APPROVED"
        actions = [r["action_code"] for r in await db.rows(
            """SELECT action_code FROM wf.action_execution e JOIN loan.loan l ON l.workflow_instance_id = e.workflow_instance_id
                WHERE l.id=%s AND e.stage_code='MANAGER_APPROVAL' ORDER BY e.started_at""", (loan["id"],))]
        assert actions == ["RULE_CHECKS", "RECORD_APPROVAL_DECISION", "SET_STATUS"]

    run_db(scenario)
