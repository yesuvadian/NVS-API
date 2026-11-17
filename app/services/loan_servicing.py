"""Recovery cases, waivers, cooling-off overrides and write-offs."""

from datetime import date
from decimal import Decimal
from typing import Any
from uuid import UUID

from psycopg import AsyncConnection

from app.core.errors import AppError
from app.repositories.loan_servicing import LoanServicingRepository


def _found(result: Any, code: str) -> Any:
    if result is None:
        raise AppError(code)
    return result


class LoanServicingService:
    def __init__(self, conn: AsyncConnection) -> None:
        self.repo = LoanServicingRepository(conn)

    # Recovery ---------------------------------------------------------------
    async def list_recovery_cases(self, status: str | None, assigned_to: UUID | None,
                                  follow_up_due: bool, limit: int, offset: int):
        return await self.repo.call("list_recovery_cases", status, assigned_to, follow_up_due, limit, offset)

    async def recovery_case(self, case_id: UUID):
        return _found(await self.repo.call("get_recovery_case", case_id), "RECOVERY_CASE_NOT_FOUND")

    async def assign_recovery_case(self, case_id: UUID, user_id: UUID):
        return await self.repo.call("assign_recovery_case", case_id, user_id)

    async def log_contact(self, case_id: UUID, details: dict[str, Any]):
        return await self.repo.call("log_recovery_contact", case_id, details)

    async def set_recovery_status(self, case_id: UUID, status: str, remarks: str):
        return await self.repo.call("set_recovery_status", case_id, status, remarks)

    # Waivers ----------------------------------------------------------------
    async def waivers(self, loan_id: UUID):
        return await self.repo.call("list_waivers", loan_id)

    async def waiver(self, waiver_id: UUID):
        return _found(await self.repo.call("get_waiver", waiver_id), "WAIVER_NOT_FOUND")

    async def request_waiver(self, loan_id: UUID, component: str, charge_id: UUID | None,
                             amount: Decimal, reason: str):
        return await self.repo.call("request_waiver", loan_id, component, charge_id, amount, reason)

    async def decide_waiver(self, waiver_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_waiver", waiver_id, approve, remarks)

    # Cooling-off override ---------------------------------------------------
    async def cooling_off_override(self, override_id: UUID):
        return _found(await self.repo.call("get_cooling_off_override", override_id), "OVERRIDE_NOT_FOUND")

    async def request_cooling_off_override(self, member_id: UUID, reason: str, evidence_document_id: UUID | None):
        return await self.repo.call("request_cooling_off_override", member_id, reason, evidence_document_id)

    async def decide_cooling_off_override(self, override_id: UUID, approve: bool,
                                          valid_until: date | None, remarks: str | None):
        return await self.repo.call("decide_cooling_off_override", override_id, approve, valid_until, remarks)

    # Write-off --------------------------------------------------------------
    async def write_off(self, write_off_id: UUID):
        return _found(await self.repo.call("get_write_off", write_off_id), "WRITE_OFF_NOT_FOUND")

    async def propose_write_off(self, loan_id: UUID, reason: str):
        return await self.repo.call("propose_write_off", loan_id, reason)

    async def decide_write_off(self, write_off_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_write_off", write_off_id, approve, remarks)

    async def collect_written_off_recovery(self, loan_id: UUID, amount: Decimal, payment_mode: str,
                                           payment_reference: str | None):
        return await self.repo.call("collect_written_off_recovery", loan_id, amount, payment_mode, payment_reference)

    # Application withdrawal and cancellation ----------------------------------
    async def withdraw_application(self, loan_id: UUID, reason: str):
        return await self.repo.call("withdraw_application", loan_id, reason)

    async def request_cancellation(self, loan_id: UUID, reason: str):
        return await self.repo.call("request_loan_cancellation", loan_id, reason)

    async def cancellation(self, cancellation_id: UUID):
        return _found(await self.repo.call("get_loan_cancellation", cancellation_id), "CANCELLATION_NOT_FOUND")

    async def decide_cancellation(self, cancellation_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_loan_cancellation", cancellation_id, approve, remarks)

    # Offline approvals --------------------------------------------------------
    async def record_offline_decision(self, request_id: UUID, details: dict[str, Any]):
        return await self.repo.call("record_offline_approval", request_id, details)

    async def verify_offline_decision(self, request_id: UUID, result: str, remarks: str | None):
        return await self.repo.call("verify_offline_approval", request_id, result, remarks)

    # Receipt reversal -----------------------------------------------------------
    async def request_reversal(self, repayment_id: UUID, reason: str):
        return await self.repo.call("request_repayment_reversal", repayment_id, reason)

    async def reversals(self, loan_id: UUID):
        return await self.repo.call("list_repayment_reversals", loan_id)

    async def reversal(self, reversal_id: UUID):
        return _found(await self.repo.call("get_repayment_reversal", reversal_id), "REVERSAL_NOT_FOUND")

    async def decide_reversal(self, reversal_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_repayment_reversal", reversal_id, approve, remarks)

    # Guarantors -------------------------------------------------------------------
    async def guarantors(self, loan_id: UUID):
        return await self.repo.call("list_guarantors", loan_id)

    async def add_guarantor(self, loan_id: UUID, details: dict[str, Any]):
        return await self.repo.call("add_guarantor", loan_id, details)

    async def remove_guarantor(self, guarantor_id: UUID):
        return await self.repo.call("remove_guarantor", guarantor_id)

    async def request_guarantor_replacement(self, guarantor_id: UUID, new: dict[str, Any], reason: str):
        return await self.repo.call("request_guarantor_replacement", guarantor_id, new, reason)

    async def guarantor_replacement(self, replacement_id: UUID):
        return _found(await self.repo.call("get_guarantor_replacement", replacement_id), "REPLACEMENT_NOT_FOUND")

    async def decide_guarantor_replacement(self, replacement_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_guarantor_replacement", replacement_id, approve, remarks)

    # Cash disbursement limit ------------------------------------------------------
    async def approve_cash_disbursement(self, disbursement_id: UUID, remarks: str | None):
        return await self.repo.call("approve_cash_disbursement", disbursement_id, remarks)

    # Restructuring ---------------------------------------------------------------
    async def request_restructure(self, loan_id: UUID, details: dict[str, Any]):
        return await self.repo.call("request_restructure", loan_id, details)

    async def restructures(self, loan_id: UUID):
        return await self.repo.call("list_restructures", loan_id)

    async def restructure(self, restructure_id: UUID):
        return _found(await self.repo.call("get_restructure", restructure_id), "RESTRUCTURE_NOT_FOUND")

    async def decide_restructure(self, restructure_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_restructure", restructure_id, approve, remarks)

    # Deceased member's loan ------------------------------------------------------
    async def record_deceased_decision(self, loan_id: UUID, decision: str, remarks: str | None):
        return await self.repo.call("record_deceased_loan_decision", loan_id, decision, remarks)

    async def transfers(self, loan_id: UUID):
        return await self.repo.call("list_loan_transfers", loan_id)

    async def propose_transfer(self, loan_id: UUID, shares: list[dict[str, Any]]):
        return await self.repo.call("propose_loan_transfer", loan_id, shares)

    async def decide_transfer(self, loan_id: UUID, approve: bool, remarks: str | None):
        return await self.repo.call("decide_loan_transfer", loan_id, approve, remarks)

    # Migrated loans ----------------------------------------------------------------
    async def migration_reviews(self, status: str | None):
        return await self.repo.call("list_migration_reviews", status)

    async def decide_migration_review(self, review_id: UUID, apply_default: bool, remarks: str):
        return await self.repo.call("decide_migration_review", review_id, apply_default, remarks)

    # Documents and sanction letter ----------------------------------------------------
    async def documents(self, loan_id: UUID):
        return await self.repo.call("list_loan_documents", loan_id)

    async def add_document(self, loan_id: UUID, details: dict[str, Any]):
        return await self.repo.call("add_loan_document", loan_id, details)

    async def remove_document(self, document_id: UUID):
        return await self.repo.call("remove_loan_document", document_id)

    async def missing_documents(self, loan_id: UUID):
        return await self.repo.call("missing_documents", loan_id)

    async def sanction_letter(self, loan_id: UUID):
        return _found(await self.repo.call("sanction_letter", loan_id), "LOAN_NOT_FOUND")

    # Reports (scope 23.3) ----------------------------------------------------------------
    async def report(self, name: str, *args: Any):
        return await self.repo.call(f"report_{name}", *args)
