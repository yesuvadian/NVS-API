"""Defaulted-loan servicing: recovery cases, waivers, cooling-off overrides and write-offs.

Privileges gate who can reach each endpoint; PostgreSQL enforces the business
rules, maker-checker and the approver role (for example the write-off approver
role from setting loans.write_off_approver_role, Leadership by default).
"""

from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from fastapi.responses import HTMLResponse
from psycopg import AsyncConnection

from app.core.idempotency import IDEMPOTENCY_HEADER, run_idempotent, validate_key
from app.core.permissions import require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.schemas.loan_servicing import (
    CashDisbursementApproval,
    CoolingOffOverrideDecision,
    CoolingOffOverrideRequest,
    DeceasedLoanDecision,
    Decision,
    GuarantorIn,
    GuarantorReplacementIn,
    LoanDocumentIn,
    LoanTransferProposal,
    MigrationReviewDecision,
    OfflineDecision,
    OfflineVerification,
    Reason,
    RecoveryAssign,
    RecoveryContact,
    RecoveryStatusChange,
    RestructureRequest,
    WaiverRequest,
    WriteOffProposal,
    WrittenOffRecovery,
)
from app.services.loan_servicing import LoanServicingService
from app.services.loans import LoanService
from app.services.sanction_letter import render_sanction_letter

router = APIRouter(tags=["loan servicing"])


def _service(conn: AsyncConnection) -> LoanServicingService:
    return LoanServicingService(conn)


# Recovery cases ---------------------------------------------------------------
@router.get("/recovery-cases")
async def list_recovery_cases(
    status: str | None = Query(default=None, max_length=30),
    assigned_to: UUID | None = None,
    follow_up_due: bool = False,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).list_recovery_cases(status, assigned_to, follow_up_due, limit, offset)


@router.get("/recovery-cases/{case_id}")
async def get_recovery_case(
    case_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).recovery_case(case_id)


@router.post("/recovery-cases/{case_id}/assign")
async def assign_recovery_case(
    case_id: UUID, payload: RecoveryAssign,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.edit")),
):
    return await _service(conn).assign_recovery_case(case_id, payload.user_id)


@router.post("/recovery-cases/{case_id}/contacts", status_code=201)
async def log_recovery_contact(
    case_id: UUID, payload: RecoveryContact,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.create")),
):
    return await _service(conn).log_contact(case_id, payload.model_dump(mode="json", exclude_none=True))


@router.post("/recovery-cases/{case_id}/status")
async def set_recovery_status(
    case_id: UUID, payload: RecoveryStatusChange,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.create")),
):
    return await _service(conn).set_recovery_status(case_id, payload.status, payload.remarks)


# Waivers ----------------------------------------------------------------------
@router.get("/loans/{loan_id}/waivers")
async def list_waivers(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).waivers(loan_id)


@router.post("/loans/{loan_id}/waivers", status_code=201)
async def request_waiver(
    loan_id: UUID, payload: WaiverRequest,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.create")),
):
    return await _service(conn).request_waiver(loan_id, payload.component, payload.charge_id,
                                               payload.amount, payload.reason)


@router.get("/loan-waivers/{waiver_id}")
async def get_waiver(
    waiver_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).waiver(waiver_id)


@router.post("/loan-waivers/{waiver_id}/decision")
async def decide_waiver(
    waiver_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.approve")),
):
    return await _service(conn).decide_waiver(waiver_id, payload.approve, payload.remarks)


# Cooling-off override ---------------------------------------------------------
@router.post("/members/{member_id}/cooling-off-overrides", status_code=201)
async def request_cooling_off_override(
    member_id: UUID, payload: CoolingOffOverrideRequest,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.create")),
):
    return await _service(conn).request_cooling_off_override(member_id, payload.reason,
                                                             payload.evidence_document_id)


@router.get("/cooling-off-overrides/{override_id}")
async def get_cooling_off_override(
    override_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).cooling_off_override(override_id)


@router.post("/cooling-off-overrides/{override_id}/decision")
async def decide_cooling_off_override(
    override_id: UUID, payload: CoolingOffOverrideDecision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.approve")),
):
    return await _service(conn).decide_cooling_off_override(override_id, payload.approve,
                                                            payload.valid_until, payload.remarks)


# Write-off --------------------------------------------------------------------
@router.post("/loans/{loan_id}/write-off", status_code=201)
async def propose_write_off(
    loan_id: UUID, payload: WriteOffProposal,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.create")),
):
    return await _service(conn).propose_write_off(loan_id, payload.reason)


@router.get("/loan-write-offs/{write_off_id}")
async def get_write_off(
    write_off_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).write_off(write_off_id)


@router.post("/loan-write-offs/{write_off_id}/decision")
async def decide_write_off(
    write_off_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    # Leadership holds only loan_default.view; the database checks the approver role.
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).decide_write_off(write_off_id, payload.approve, payload.remarks)


@router.post("/loans/{loan_id}/written-off-recoveries", status_code=201)
async def collect_written_off_recovery(
    loan_id: UUID, payload: WrittenOffRecovery, response: Response,
    idempotency_key: str | None = Header(default=None, alias=IDEMPOTENCY_HEADER, max_length=200),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.create")),
):
    """Bad debt recovery receipt. Needs an Idempotency-Key, so a retry cannot post it twice."""
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=True), operation="loan.collect_written_off_recovery",
        payload={"loan_id": loan_id, **payload.model_dump()}, response=response,
        action=lambda: _service(conn).collect_written_off_recovery(loan_id, payload.amount, payload.payment_mode,
                                                                   payload.payment_reference))


# Application withdrawal and cancellation ----------------------------------------
@router.post("/loan-applications/{loan_id}/withdraw")
async def withdraw_application(
    loan_id: UUID, payload: Reason,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).withdraw_application(loan_id, payload.reason)


@router.post("/loans/{loan_id}/cancellation", status_code=201)
async def request_loan_cancellation(
    loan_id: UUID, payload: Reason,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).request_cancellation(loan_id, payload.reason)


@router.get("/loan-cancellations/{cancellation_id}")
async def get_loan_cancellation(
    cancellation_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).cancellation(cancellation_id)


@router.post("/loan-cancellations/{cancellation_id}/decision")
async def decide_loan_cancellation(
    cancellation_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).decide_cancellation(cancellation_id, payload.approve, payload.remarks)


# Offline approvals (scope 28.1) ------------------------------------------------
@router.post("/loan-approvals/{request_id}/offline-decision", status_code=201)
async def record_offline_decision(
    request_id: UUID, payload: OfflineDecision,
    conn: AsyncConnection = Depends(get_tenant_db),
    # Recorded by an employee on the approver's behalf; the database checks the
    # recorder role and that requester, approver and recorder are different people.
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.create")),
):
    # Runs the APPROVE/REJECT/RETURN transition (rule checks, log) like an online decision.
    return await LoanService(conn).record_offline_decision(
        request_id, payload.model_dump(mode="json", exclude_none=True))


@router.post("/loan-approvals/{request_id}/verification")
async def verify_offline_decision(
    request_id: UUID, payload: OfflineVerification,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).verify_offline_decision(request_id, payload.result, payload.remarks)


# Receipt reversal -----------------------------------------------------------------
@router.post("/loan-repayments/{repayment_id}/reversal", status_code=201)
async def request_repayment_reversal(
    repayment_id: UUID, payload: Reason,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.create")),
):
    return await _service(conn).request_reversal(repayment_id, payload.reason)


@router.get("/loans/{loan_id}/repayment-reversals")
async def list_repayment_reversals(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.view")),
):
    return await _service(conn).reversals(loan_id)


@router.get("/repayment-reversals/{reversal_id}")
async def get_repayment_reversal(
    reversal_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.view")),
):
    return await _service(conn).reversal(reversal_id)


@router.post("/repayment-reversals/{reversal_id}/decision")
async def decide_repayment_reversal(
    reversal_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    # Manager and Accountant both approve after day-end; the Accountant holds only
    # loan_repay.view, so the database checks the approver roles from the settings.
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.view")),
):
    return await _service(conn).decide_reversal(reversal_id, payload.approve, payload.remarks)


# Guarantors (scope 6.9) -------------------------------------------------------------
@router.get("/loans/{loan_id}/guarantors")
async def list_guarantors(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).guarantors(loan_id)


@router.post("/loans/{loan_id}/guarantors", status_code=201)
async def add_guarantor(
    loan_id: UUID, payload: GuarantorIn,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).add_guarantor(loan_id, payload.model_dump(mode="json", exclude_none=True))


@router.delete("/loan-guarantors/{guarantor_id}")
async def remove_guarantor(
    guarantor_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).remove_guarantor(guarantor_id)


@router.post("/loan-guarantors/{guarantor_id}/replacement", status_code=201)
async def request_guarantor_replacement(
    guarantor_id: UUID, payload: GuarantorReplacementIn,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).request_guarantor_replacement(
        guarantor_id, payload.new_guarantor.model_dump(mode="json", exclude_none=True), payload.reason)


@router.get("/guarantor-replacements/{replacement_id}")
async def get_guarantor_replacement(
    replacement_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).guarantor_replacement(replacement_id)


@router.post("/guarantor-replacements/{replacement_id}/decision")
async def decide_guarantor_replacement(
    replacement_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).decide_guarantor_replacement(replacement_id, payload.approve, payload.remarks)


# Cash disbursement above the limit (scope 21.6) ----------------------------------------
@router.post("/loan-disbursements/{disbursement_id}/cash-approval")
async def approve_cash_disbursement(
    disbursement_id: UUID, payload: CashDisbursementApproval,
    conn: AsyncConnection = Depends(get_tenant_db),
    # the approver role comes from setting cash.disbursement_limit and is checked in the database
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).approve_cash_disbursement(disbursement_id, payload.remarks)


# Restructuring (scope 6.10) ------------------------------------------------------------
@router.post("/loans/{loan_id}/restructures", status_code=201)
async def request_restructure(
    loan_id: UUID, payload: RestructureRequest,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).request_restructure(loan_id, payload.model_dump(mode="json", exclude_none=True))


@router.get("/loans/{loan_id}/restructures")
async def list_restructures(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).restructures(loan_id)


@router.get("/loan-restructures/{restructure_id}")
async def get_restructure(
    restructure_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).restructure(restructure_id)


@router.post("/loan-restructures/{restructure_id}/decision")
async def decide_restructure(
    restructure_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).decide_restructure(restructure_id, payload.approve, payload.remarks)


# Deceased member's loan (scope 12.1, 12.2) ----------------------------------------------
@router.post("/loans/{loan_id}/deceased-decision", status_code=201)
async def record_deceased_decision(
    loan_id: UUID, payload: DeceasedLoanDecision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).record_deceased_decision(loan_id, payload.decision, payload.remarks)


@router.get("/loans/{loan_id}/transfers")
async def list_transfers(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).transfers(loan_id)


@router.post("/loans/{loan_id}/transfers", status_code=201)
async def propose_transfer(
    loan_id: UUID, payload: LoanTransferProposal,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    shares = [s.model_dump(mode="json", exclude_none=True) for s in payload.shares]
    return await _service(conn).propose_transfer(loan_id, shares)


@router.post("/loans/{loan_id}/transfers/decision")
async def decide_transfer(
    loan_id: UUID, payload: Decision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).decide_transfer(loan_id, payload.approve, payload.remarks)


# Migrated loans overdue before go-live (scope 39.3) ---------------------------------
@router.get("/migration-reviews")
async def list_migration_reviews(
    status: str | None = Query(default="OPEN", max_length=30),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_default.view")),
):
    return await _service(conn).migration_reviews(status)


@router.post("/migration-reviews/{review_id}/decision")
async def decide_migration_review(
    review_id: UUID, payload: MigrationReviewDecision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).decide_migration_review(review_id, payload.apply_default, payload.remarks)


# Supporting documents and the sanction letter (gap L8) --------------------------------
@router.get("/loans/{loan_id}/documents")
async def list_loan_documents(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    service = _service(conn)
    return {"items": await service.documents(loan_id), "missing": await service.missing_documents(loan_id)}


@router.post("/loans/{loan_id}/documents", status_code=201)
async def add_loan_document(
    loan_id: UUID, payload: LoanDocumentIn,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).add_document(loan_id, payload.model_dump(mode="json", exclude_none=True))


@router.delete("/loan-documents/{document_id}")
async def remove_loan_document(
    document_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await _service(conn).remove_document(document_id)


@router.get("/loans/{loan_id}/sanction-letter")
async def sanction_letter(
    loan_id: UUID,
    format: str = Query(default="json", pattern="^(json|html)$"),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    data = await _service(conn).sanction_letter(loan_id)
    if format == "html":
        return HTMLResponse(render_sanction_letter(data))
    return data
