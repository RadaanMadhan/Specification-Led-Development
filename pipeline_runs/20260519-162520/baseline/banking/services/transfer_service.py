from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal

from banking.domain.exceptions import (
    AccountFrozenError,
    AccountNotFoundError,
    CurrencyMismatchError,
    InsufficientFundsError,
    SelfTransferError,
    UnauthorizedError,
)
from banking.domain.models import AuditAction, Transaction, TransactionStatus
from banking.repositories.account_repository import AccountRepository
from banking.repositories.transaction_repository import TransactionRepository
from banking.services.audit_service import AuditService


class TransferService:
    def __init__(
        self,
        account_repo: AccountRepository,
        transaction_repo: TransactionRepository,
        audit_service: AuditService,
    ) -> None:
        self._account_repo = account_repo
        self._transaction_repo = transaction_repo
        self._audit_service = audit_service

    def transfer(
        self,
        source_account_id: str,
        destination_account_id: str,
        amount: Decimal,
        initiated_by: str,
        reason: str | None = None,
    ) -> Transaction:
        # Auth check
        if not initiated_by or not initiated_by.strip():
            raise UnauthorizedError("Transfer must have an identified initiator")

        # No self-transfer
        if source_account_id == destination_account_id:
            raise SelfTransferError(source_account_id)

        # Load accounts
        source = self._account_repo.find_by_id(source_account_id)
        if source is None:
            raise AccountNotFoundError(source_account_id)

        destination = self._account_repo.find_by_id(destination_account_id)
        if destination is None:
            raise AccountNotFoundError(destination_account_id)

        # Frozen check
        if source.is_frozen:
            raise AccountFrozenError(source_account_id)
        if destination.is_frozen:
            raise AccountFrozenError(destination_account_id)

        # Currency check
        if source.currency != destination.currency:
            raise CurrencyMismatchError(source.currency, destination.currency)

        # Create the transaction record
        transaction = Transaction(
            source_account_id=source_account_id,
            destination_account_id=destination_account_id,
            amount=amount,
            currency=source.currency,
            initiated_by=initiated_by,
            reason=reason,
        )
        self._transaction_repo.save(transaction)

        self._audit_service.log(
            action=AuditAction.TRANSFER_INITIATED,
            actor=initiated_by,
            resource_type="transaction",
            resource_id=transaction.id,
            details={
                "source_account_id": source_account_id,
                "destination_account_id": destination_account_id,
                "amount": str(amount),
                "currency": source.currency,
            },
        )

        # Balance check
        if source.balance < amount:
            transaction.status = TransactionStatus.FAILED
            transaction.failure_reason = (
                f"Insufficient funds: available={source.balance}, requested={amount}"
            )
            transaction.completed_at = datetime.now(timezone.utc)
            self._transaction_repo.save(transaction)

            self._audit_service.log(
                action=AuditAction.TRANSFER_FAILED,
                actor=initiated_by,
                resource_type="transaction",
                resource_id=transaction.id,
                details={"reason": transaction.failure_reason},
            )

            raise InsufficientFundsError(
                source_account_id,
                str(source.balance),
                str(amount),
            )

        # Execute the transfer
        source.balance -= amount
        destination.balance += amount

        self._account_repo.save(source)
        self._account_repo.save(destination)

        transaction.status = TransactionStatus.COMPLETED
        transaction.completed_at = datetime.now(timezone.utc)
        self._transaction_repo.save(transaction)

        self._audit_service.log(
            action=AuditAction.TRANSFER_COMPLETED,
            actor=initiated_by,
            resource_type="transaction",
            resource_id=transaction.id,
            details={
                "source_balance_after": str(source.balance),
                "destination_balance_after": str(destination.balance),
            },
        )

        return transaction

    def get_transaction(self, transaction_id: str) -> Transaction | None:
        return self._transaction_repo.find_by_id(transaction_id)

    def get_account_transactions(self, account_id: str) -> list[Transaction]:
        return self._transaction_repo.find_by_account(account_id)
