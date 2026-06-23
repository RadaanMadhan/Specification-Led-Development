from __future__ import annotations

from decimal import Decimal

import pytest
from pydantic import ValidationError

from banking.domain.models import Account, AuditAction, AuditEntry, Transaction


class TestAccount:
    def test_create_account_defaults(self) -> None:
        account = Account(owner="Alice")
        assert account.owner == "Alice"
        assert account.balance == Decimal("0.00")
        assert account.currency == "USD"
        assert account.is_frozen is False
        assert account.id is not None

    def test_create_account_with_balance(self) -> None:
        account = Account(owner="Bob", balance=Decimal("1000.00"))
        assert account.balance == Decimal("1000.00")

    def test_negative_balance_rejected(self) -> None:
        with pytest.raises(ValidationError, match="Balance cannot be negative"):
            Account(owner="Charlie", balance=Decimal("-1.00"))

    def test_empty_owner_rejected(self) -> None:
        with pytest.raises(ValidationError, match="Owner cannot be empty"):
            Account(owner="   ")

    def test_owner_whitespace_stripped(self) -> None:
        account = Account(owner="  Alice  ")
        assert account.owner == "Alice"


class TestTransaction:
    def test_create_transaction(self) -> None:
        txn = Transaction(
            source_account_id="src",
            destination_account_id="dst",
            amount=Decimal("50.00"),
            initiated_by="Alice",
        )
        assert txn.amount == Decimal("50.00")
        assert txn.status.value == "pending"

    def test_zero_amount_rejected(self) -> None:
        with pytest.raises(ValidationError, match="Transfer amount must be positive"):
            Transaction(
                source_account_id="src",
                destination_account_id="dst",
                amount=Decimal("0"),
                initiated_by="Alice",
            )

    def test_negative_amount_rejected(self) -> None:
        with pytest.raises(ValidationError, match="Transfer amount must be positive"):
            Transaction(
                source_account_id="src",
                destination_account_id="dst",
                amount=Decimal("-10.00"),
                initiated_by="Alice",
            )


class TestAuditEntry:
    def test_create_audit_entry(self) -> None:
        entry = AuditEntry(
            action=AuditAction.ACCOUNT_CREATED,
            actor="system",
            resource_type="account",
            resource_id="abc-123",
            details={"initial_balance": "100.00"},
        )
        assert entry.action == AuditAction.ACCOUNT_CREATED
        assert entry.actor == "system"
        assert entry.details["initial_balance"] == "100.00"
