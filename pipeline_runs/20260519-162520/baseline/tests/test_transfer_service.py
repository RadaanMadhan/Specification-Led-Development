from __future__ import annotations

from decimal import Decimal

import pytest

from banking.domain.exceptions import (
    AccountFrozenError,
    AccountNotFoundError,
    CurrencyMismatchError,
    InsufficientFundsError,
    SelfTransferError,
    UnauthorizedError,
)
from banking.domain.models import Account, TransactionStatus
from banking.repositories.account_repository import InMemoryAccountRepository
from banking.services.audit_service import AuditService
from banking.services.transfer_service import TransferService


class TestTransferService:
    def test_successful_transfer(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
        audit_service: AuditService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("1000.00"))
        dst = Account(owner="Bob", balance=Decimal("500.00"))
        account_repo.save(src)
        account_repo.save(dst)

        txn = transfer_service.transfer(
            source_account_id=src.id,
            destination_account_id=dst.id,
            amount=Decimal("200.00"),
            initiated_by="Alice",
        )

        assert txn.status == TransactionStatus.COMPLETED
        assert txn.amount == Decimal("200.00")

        updated_src = account_repo.find_by_id(src.id)
        updated_dst = account_repo.find_by_id(dst.id)
        assert updated_src is not None
        assert updated_dst is not None
        assert updated_src.balance == Decimal("800.00")
        assert updated_dst.balance == Decimal("700.00")

    def test_transfer_creates_audit_entries(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
        audit_service: AuditService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("1000.00"))
        dst = Account(owner="Bob", balance=Decimal("0.00"))
        account_repo.save(src)
        account_repo.save(dst)

        txn = transfer_service.transfer(
            source_account_id=src.id,
            destination_account_id=dst.id,
            amount=Decimal("100.00"),
            initiated_by="Alice",
        )

        trail = audit_service.get_audit_trail("transaction", txn.id)
        actions = [e.action.value for e in trail]
        assert "transfer_initiated" in actions
        assert "transfer_completed" in actions
        # All entries attributed to the initiator
        assert all(e.actor == "Alice" for e in trail)

    def test_insufficient_funds(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
        audit_service: AuditService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("50.00"))
        dst = Account(owner="Bob", balance=Decimal("0.00"))
        account_repo.save(src)
        account_repo.save(dst)

        with pytest.raises(InsufficientFundsError):
            transfer_service.transfer(
                source_account_id=src.id,
                destination_account_id=dst.id,
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

        # Balance unchanged
        assert account_repo.find_by_id(src.id).balance == Decimal("50.00")

        # Failure recorded in audit
        full_log = audit_service.get_full_log()
        failed_entries = [e for e in full_log if e.action.value == "transfer_failed"]
        assert len(failed_entries) == 1

    def test_self_transfer_rejected(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        acct = Account(owner="Alice", balance=Decimal("1000.00"))
        account_repo.save(acct)

        with pytest.raises(SelfTransferError):
            transfer_service.transfer(
                source_account_id=acct.id,
                destination_account_id=acct.id,
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

    def test_source_account_not_found(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        dst = Account(owner="Bob", balance=Decimal("0.00"))
        account_repo.save(dst)

        with pytest.raises(AccountNotFoundError):
            transfer_service.transfer(
                source_account_id="nonexistent",
                destination_account_id=dst.id,
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

    def test_destination_account_not_found(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("1000.00"))
        account_repo.save(src)

        with pytest.raises(AccountNotFoundError):
            transfer_service.transfer(
                source_account_id=src.id,
                destination_account_id="nonexistent",
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

    def test_frozen_source_account_rejected(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("1000.00"), is_frozen=True)
        dst = Account(owner="Bob", balance=Decimal("0.00"))
        account_repo.save(src)
        account_repo.save(dst)

        with pytest.raises(AccountFrozenError):
            transfer_service.transfer(
                source_account_id=src.id,
                destination_account_id=dst.id,
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

    def test_frozen_destination_account_rejected(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("1000.00"))
        dst = Account(owner="Bob", balance=Decimal("0.00"), is_frozen=True)
        account_repo.save(src)
        account_repo.save(dst)

        with pytest.raises(AccountFrozenError):
            transfer_service.transfer(
                source_account_id=src.id,
                destination_account_id=dst.id,
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

    def test_currency_mismatch_rejected(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("1000.00"), currency="USD")
        dst = Account(owner="Bob", balance=Decimal("0.00"), currency="EUR")
        account_repo.save(src)
        account_repo.save(dst)

        with pytest.raises(CurrencyMismatchError):
            transfer_service.transfer(
                source_account_id=src.id,
                destination_account_id=dst.id,
                amount=Decimal("100.00"),
                initiated_by="Alice",
            )

    def test_unauthorized_transfer_rejected(
        self,
        transfer_service: TransferService,
    ) -> None:
        with pytest.raises(UnauthorizedError):
            transfer_service.transfer(
                source_account_id="src",
                destination_account_id="dst",
                amount=Decimal("100.00"),
                initiated_by="",
            )

    def test_transfer_exact_balance(
        self,
        account_repo: InMemoryAccountRepository,
        transfer_service: TransferService,
    ) -> None:
        src = Account(owner="Alice", balance=Decimal("100.00"))
        dst = Account(owner="Bob", balance=Decimal("0.00"))
        account_repo.save(src)
        account_repo.save(dst)

        txn = transfer_service.transfer(
            source_account_id=src.id,
            destination_account_id=dst.id,
            amount=Decimal("100.00"),
            initiated_by="Alice",
        )

        assert txn.status == TransactionStatus.COMPLETED
        assert account_repo.find_by_id(src.id).balance == Decimal("0.00")
        assert account_repo.find_by_id(dst.id).balance == Decimal("100.00")
