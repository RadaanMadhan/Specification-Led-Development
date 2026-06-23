from __future__ import annotations

from decimal import Decimal

from banking.domain.models import Account, AuditAction
from banking.repositories.account_repository import InMemoryAccountRepository
from banking.repositories.audit_repository import InMemoryAuditRepository
from banking.services.account_service import AccountService
from banking.services.audit_service import AuditService
from banking.services.transfer_service import TransferService


class TestAuditService:
    def test_audit_log_is_append_only(self, audit_service: AuditService) -> None:
        audit_service.log(
            action=AuditAction.ACCOUNT_CREATED,
            actor="Alice",
            resource_type="account",
            resource_id="acc-1",
        )
        audit_service.log(
            action=AuditAction.ACCOUNT_FROZEN,
            actor="Admin",
            resource_type="account",
            resource_id="acc-1",
        )
        entries = audit_service.get_full_log()
        assert len(entries) == 2
        assert entries[0].action == AuditAction.ACCOUNT_CREATED
        assert entries[1].action == AuditAction.ACCOUNT_FROZEN

    def test_audit_entries_attributed_to_actor(self, audit_service: AuditService) -> None:
        audit_service.log(
            action=AuditAction.TRANSFER_INITIATED,
            actor="Alice",
            resource_type="transaction",
            resource_id="txn-1",
            details={"amount": "100.00"},
        )
        history = audit_service.get_actor_history("Alice")
        assert len(history) == 1
        assert history[0].actor == "Alice"
        assert history[0].details["amount"] == "100.00"

    def test_audit_trail_per_resource(self, audit_service: AuditService) -> None:
        audit_service.log(
            action=AuditAction.ACCOUNT_CREATED,
            actor="Alice",
            resource_type="account",
            resource_id="acc-1",
        )
        audit_service.log(
            action=AuditAction.ACCOUNT_CREATED,
            actor="Bob",
            resource_type="account",
            resource_id="acc-2",
        )
        trail = audit_service.get_audit_trail("account", "acc-1")
        assert len(trail) == 1
        assert trail[0].actor == "Alice"

    def test_account_creation_audited(
        self,
        account_service: AccountService,
        audit_service: AuditService,
    ) -> None:
        account = account_service.create_account("Alice", Decimal("500.00"))
        trail = audit_service.get_audit_trail("account", account.id)
        assert len(trail) == 1
        assert trail[0].action == AuditAction.ACCOUNT_CREATED
        assert trail[0].actor == "Alice"
        assert trail[0].details["initial_balance"] == "500.00"

    def test_freeze_unfreeze_audited(
        self,
        account_service: AccountService,
        audit_service: AuditService,
    ) -> None:
        account = account_service.create_account("Alice", Decimal("500.00"))
        account_service.freeze_account(account.id, actor="Admin")
        account_service.unfreeze_account(account.id, actor="Admin")

        trail = audit_service.get_audit_trail("account", account.id)
        actions = [e.action for e in trail]
        assert AuditAction.ACCOUNT_CREATED in actions
        assert AuditAction.ACCOUNT_FROZEN in actions
        assert AuditAction.ACCOUNT_UNFROZEN in actions

    def test_transfer_full_audit_trail(
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
            amount=Decimal("250.00"),
            initiated_by="Alice",
            reason="Payment for services",
        )

        trail = audit_service.get_audit_trail("transaction", txn.id)
        assert len(trail) == 2
        assert trail[0].action == AuditAction.TRANSFER_INITIATED
        assert trail[0].details["amount"] == "250.00"
        assert trail[1].action == AuditAction.TRANSFER_COMPLETED
        assert trail[1].details["source_balance_after"] == "750.00"
