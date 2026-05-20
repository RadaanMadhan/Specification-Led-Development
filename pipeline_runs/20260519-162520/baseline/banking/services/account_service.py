from __future__ import annotations

from decimal import Decimal

from banking.domain.exceptions import AccountFrozenError, AccountNotFoundError
from banking.domain.models import Account, AuditAction
from banking.repositories.account_repository import AccountRepository
from banking.services.audit_service import AuditService


class AccountService:
    def __init__(
        self,
        account_repo: AccountRepository,
        audit_service: AuditService,
    ) -> None:
        self._account_repo = account_repo
        self._audit_service = audit_service

    def create_account(
        self, owner: str, initial_balance: Decimal = Decimal("0.00"), currency: str = "USD"
    ) -> Account:
        account = Account(owner=owner, balance=initial_balance, currency=currency)
        self._account_repo.save(account)
        self._audit_service.log(
            action=AuditAction.ACCOUNT_CREATED,
            actor=owner,
            resource_type="account",
            resource_id=account.id,
            details={"initial_balance": str(initial_balance), "currency": currency},
        )
        return account

    def get_account(self, account_id: str) -> Account:
        account = self._account_repo.find_by_id(account_id)
        if account is None:
            raise AccountNotFoundError(account_id)
        return account

    def freeze_account(self, account_id: str, actor: str) -> Account:
        account = self.get_account(account_id)
        account.is_frozen = True
        self._account_repo.save(account)
        self._audit_service.log(
            action=AuditAction.ACCOUNT_FROZEN,
            actor=actor,
            resource_type="account",
            resource_id=account_id,
        )
        return account

    def unfreeze_account(self, account_id: str, actor: str) -> Account:
        account = self.get_account(account_id)
        account.is_frozen = False
        self._account_repo.save(account)
        self._audit_service.log(
            action=AuditAction.ACCOUNT_UNFROZEN,
            actor=actor,
            resource_type="account",
            resource_id=account_id,
        )
        return account

    def list_accounts(self) -> list[Account]:
        return self._account_repo.list_all()
