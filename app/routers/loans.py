from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from psycopg import AsyncConnection

from app.core.errors import AppError
from app.core.idempotency import IDEMPOTENCY_HEADER, run_idempotent, validate_key
from app.core.permissions import require_any_tenant_permission, require_tenant_permission
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db
from app.schemas.loans import (
    LoanApplicationCreate,
    LoanApplicationUpdate,
    LoanEligibilityOut,
    LoanEligibilityRequest,
    LoanNomineeOverride,
    LoanNomineesUpdate,
    LoanOut,
    LoanTypeOut,
    LoanFeePayment,
    LoanDecision,
    LoanDisbursementCreate,
    LoanDisbursementRelease,
    LoanRepaymentCreate,
    SettlementApproval,
    SettlementQuoteRequest,
    SettlementCollection,
)
from app.services.loans import LoanService

router = APIRouter(tags=["loans"])

# Money postings need an Idempotency-Key, so a double-click or a retry after a
# timeout returns the first receipt instead of posting a second one. Creating
# an application accepts one too. The key is read here and checked inside the
# endpoint, after the privilege check.
IdempotencyKey = Header(default=None, alias=IDEMPOTENCY_HEADER, max_length=200)


def _service(conn: AsyncConnection) -> LoanService:
    return LoanService(conn)


@router.get("/loan-types", response_model=list[LoanTypeOut])
async def list_loan_types(
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).list_types()


@router.post("/loans/eligibility", response_model=LoanEligibilityOut)
async def check_loan_eligibility(
    payload: LoanEligibilityRequest,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).eligibility_view(**payload.model_dump())


@router.get("/loans")
async def list_loan_applications(
    q: str | None = Query(default=None, max_length=120),
    status_filter: str | None = Query(default=None, alias="status", min_length=1, max_length=40),
    member_id: UUID | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    rows = await _service(conn).list_applications(
        query=q,
        status=status_filter,
        member_id=member_id,
        limit=limit + 1,
        offset=offset,
    )
    has_more = len(rows) > limit
    return {
        "items": rows[:limit],
        "limit": limit,
        "offset": offset,
        "has_more": has_more,
        "next_offset": offset + limit if has_more else None,
    }


@router.post("/loans", response_model=LoanOut, status_code=201)
async def create_loan_application(
    payload: LoanApplicationCreate,
    response: Response,
    idempotency_key: str | None = IdempotencyKey,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.create")),
):
    values = payload.model_dump()
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=False), operation="loan.create_application",
        payload=values, response=response, action=lambda: _service(conn).create_application(values))


@router.get("/loans/{loan_id}", response_model=LoanOut)
async def get_loan_application(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).get_application(loan_id)


@router.post("/loans/{loan_id}/submit", response_model=LoanOut)
async def submit_loan_application(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.create")),
):
    """Submit for approval; runs the SUBMIT rule checks of the loan's workflow."""
    return await _service(conn).submit_application(loan_id)


@router.put("/loans/{loan_id}/nominees")
async def set_loan_nominees(
    loan_id: UUID,
    payload: LoanNomineesUpdate,
    expected_version: int | None = Header(default=None, alias="X-Expected-Row-Version", ge=1),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_any_tenant_permission("loan.edit", "loan.create")),
):
    """Link (or unlink) nominees on an application before approval, or after
    approval until the first disbursement. Returns the nominee rule state.

    Draft or returned: loan.create or loan.edit. After submission: loan.edit."""
    return await _service(conn).set_nominees(loan_id, payload.nominee_ids, expected_version)


@router.post("/loans/{loan_id}/nominee-override")
async def record_loan_nominee_override(
    loan_id: UUID,
    payload: LoanNomineeOverride,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.nominee_override")),
):
    """Record that the NOMINEE rule is overridden for this loan (reason 3-500),
    before approval; the approver sees it. The rule must allow overrides."""
    return await _service(conn).record_nominee_override(loan_id, payload.reason)


@router.get("/loan-approvals/inbox")
async def loan_approval_inbox(
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).approval_inbox(limit=limit, offset=offset)


@router.post("/loans/{loan_id}/application-fee")
async def collect_application_fee(
    loan_id: UUID, payload: LoanFeePayment, response: Response,
    idempotency_key: str | None = IdempotencyKey,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_fee.create")),
):
    values = payload.model_dump()
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=True), operation="loan.collect_application_fee",
        payload={"loan_id": loan_id, **values}, response=response,
        action=lambda: _service(conn).collect_application_fee(loan_id, **values))


@router.post("/loan-approvals/{approval_request_id}/decision")
async def decide_loan_approval(
    approval_request_id: UUID, payload: LoanDecision,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).decide(approval_request_id, payload.model_dump())


@router.post("/loans/{loan_id}/disbursements", status_code=201)
async def prepare_loan_disbursement(
    loan_id: UUID, payload: LoanDisbursementCreate, response: Response,
    idempotency_key: str | None = IdempotencyKey,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.edit")),
):
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=True), operation="loan.prepare_disbursement",
        payload={"loan_id": loan_id, **payload.model_dump()}, response=response,
        action=lambda: _service(conn).prepare_disbursement(loan_id, payload.gross_amount, payload.payment_mode,
                                                           payload.payment_reference))


@router.post("/loans/{loan_id}/disbursements/{disbursement_id}/release")
async def release_loan_disbursement(
    loan_id: UUID, disbursement_id: UUID, payload: LoanDisbursementRelease,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.approve")),
):
    return await _service(conn).release_disbursement(loan_id, disbursement_id, payload.payee_ack_type)


@router.post("/loans/{loan_id}/repayments", status_code=201)
async def collect_loan_repayment(
    loan_id: UUID, payload: LoanRepaymentCreate, response: Response,
    idempotency_key: str | None = IdempotencyKey,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.create")),
):
    values = payload.model_dump()
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=True), operation="loan.collect_repayment",
        payload={"loan_id": loan_id, **values}, response=response,
        action=lambda: _service(conn).collect_repayment(loan_id, **values))


@router.get("/loans/{loan_id}/schedule")
async def get_loan_schedule(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).schedule(loan_id)


@router.get("/loans/{loan_id}/repayments")
async def list_loan_repayments(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_repay.view")),
):
    return await _service(conn).repayments(loan_id)


@router.get("/members/{member_id}/loan-statement")
async def get_member_loan_statement(
    member_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan.view")),
):
    return await _service(conn).member_statement(member_id)


@router.patch("/loan-applications/{loan_id}")
async def update_loan_application(
    loan_id: UUID, payload: LoanApplicationUpdate,
    header_version: int | None = Header(default=None, alias="X-Expected-Row-Version", ge=1),
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_any_tenant_permission("loan.edit", "loan.create")),
):
    """Change the amount, tenure, purpose or nominees of a draft or returned application.

    Holders of loan.edit or loan.create may edit (the maker who can create an
    application can correct it after a return); the database checks the same.

    The row version of the application as the user opened it is required (body
    ``expected_version`` or the X-Expected-Row-Version header), so a save never
    silently overwrites someone else's change."""
    expected_version = payload.expected_version or header_version
    if expected_version is None:
        raise AppError("ROW_VERSION_REQUIRED")
    values = payload.model_dump(exclude={"expected_version"}, exclude_none=True)
    return await _service(conn).update_application(loan_id, values, expected_version)


@router.post("/loans/{loan_id}/settlement-quote", status_code=201)
async def quote_early_settlement(
    loan_id: UUID,
    payload: SettlementQuoteRequest | None = None,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_settle.create")),
):
    """Quote early or default settlement. An optional interest waiver (with a reason)
    reduces the amount payable and always needs Manager approval."""
    payload = payload or SettlementQuoteRequest()
    return await _service(conn).quote_settlement(loan_id, payload.interest_waiver, payload.waiver_reason)


@router.get("/loans/{loan_id}/settlements")
async def list_loan_settlements(
    loan_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_settle.view")),
):
    return await _service(conn).settlements(loan_id)


@router.get("/loan-settlements/{settlement_id}")
async def get_loan_settlement(
    settlement_id: UUID,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_settle.view")),
):
    return await _service(conn).settlement(settlement_id)


@router.post("/loan-settlements/{settlement_id}/approve")
async def approve_loan_settlement(
    settlement_id: UUID, payload: SettlementApproval,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_settle.approve")),
):
    return await _service(conn).approve_settlement(settlement_id, payload.remarks)


@router.post("/loan-settlements/{settlement_id}/collect", status_code=201)
async def collect_loan_settlement(
    settlement_id: UUID, payload: SettlementCollection, response: Response,
    idempotency_key: str | None = IdempotencyKey,
    conn: AsyncConnection = Depends(get_tenant_db),
    _principal: TenantPrincipal = Depends(require_tenant_permission("loan_settle.create")),
):
    values = payload.model_dump()
    return await run_idempotent(
        conn, key=validate_key(idempotency_key, required=True), operation="loan.collect_early_settlement",
        payload={"settlement_id": settlement_id, **values}, response=response,
        action=lambda: _service(conn).collect_settlement(settlement_id, **values))
