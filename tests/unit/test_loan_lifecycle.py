from decimal import Decimal
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.repositories.loan_lifecycle import allocate_due_repayment


def test_repayment_allocation_pays_oldest_due_interest_then_principal():
    first, second = uuid4(), uuid4()
    rows = [
        {"id": first, "interest_open": Decimal("10.00"), "principal_open": Decimal("90.00")},
        {"id": second, "interest_open": Decimal("8.00"), "principal_open": Decimal("92.00")},
    ]

    allocations, principal, interest = allocate_due_repayment(
        Decimal("115.00"), rows
    )

    assert allocations == [
        (first, "INTEREST", Decimal("10.00")),
        (first, "PRINCIPAL", Decimal("90.00")),
        (second, "INTEREST", Decimal("8.00")),
        (second, "PRINCIPAL", Decimal("7.00")),
    ]
    assert principal == Decimal("97.00")
    assert interest == Decimal("18.00")


def test_repayment_rejects_amount_above_due_instalments():
    with pytest.raises(HTTPException) as exc_info:
        allocate_due_repayment(
            Decimal("101.00"),
            [{"id": uuid4(), "interest_open": Decimal("10"), "principal_open": Decimal("90")}],
        )

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {"shortCode": "REPAYMENT_EXCEEDS_DUES"}


def test_allocation_order_mirror_matches_database_rule():
    from app.repositories.loan_lifecycle import allocation_order

    assert allocation_order() == ["LATE_FEE", "PENALTY", "OVERDUE_INTEREST", "OVERDUE_PRINCIPAL",
                                  "CURRENT_INTEREST", "CURRENT_PRINCIPAL"]
    assert allocation_order(["overdue_principal", "bogus", "OVERDUE_PRINCIPAL"])[:2] == ["OVERDUE_PRINCIPAL", "LATE_FEE"]
    # The organisation's default list does not name the penalty: it stays with the late fees
    assert allocation_order(["LATE_FEE", "OVERDUE_INTEREST", "OVERDUE_PRINCIPAL", "CURRENT_INTEREST",
                             "CURRENT_PRINCIPAL"])[:3] == ["LATE_FEE", "PENALTY", "OVERDUE_INTEREST"]


def test_overdue_instalments_pay_fees_then_all_interest_then_principal():
    first, second, current = uuid4(), uuid4(), uuid4()
    rows = [
        {"id": first, "overdue": True, "late_fee_open": "50", "interest_open": "120", "principal_open": "1000"},
        {"id": second, "overdue": True, "interest_open": "120", "principal_open": "1000"},
        {"id": current, "interest_open": "120", "principal_open": "1000"},
    ]
    allocations, principal, interest = allocate_due_repayment(Decimal("1340"), rows)
    assert allocations == [
        (first, "LATE_FEE", Decimal("50")),
        (first, "INTEREST", Decimal("120")),
        (second, "INTEREST", Decimal("120")),
        (first, "PRINCIPAL", Decimal("1000")),
        (second, "PRINCIPAL", Decimal("50")),
    ]
    assert (principal, interest) == (Decimal("1050"), Decimal("240"))
    # Principal first when configured
    allocations, _, _ = allocate_due_repayment(Decimal("1000"), rows[1:2], ["OVERDUE_PRINCIPAL"])
    assert allocations == [(second, "PRINCIPAL", Decimal("1000"))]
