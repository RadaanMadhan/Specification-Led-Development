from __future__ import annotations

from fastapi import FastAPI

from banking.api.routes import configure_routes, router
from banking.repositories.account_repository import InMemoryAccountRepository
from banking.repositories.audit_repository import InMemoryAuditRepository
from banking.repositories.transaction_repository import InMemoryTransactionRepository
from banking.services.account_service import AccountService
from banking.services.audit_service import AuditService
from banking.services.transfer_service import TransferService


def create_app() -> FastAPI:
    app = FastAPI(title="Banking Transfer System", version="1.0.0")

    # Wire up repositories
    audit_repo = InMemoryAuditRepository()
    account_repo = InMemoryAccountRepository()
    transaction_repo = InMemoryTransactionRepository()

    # Wire up services
    audit_service = AuditService(audit_repo)
    account_service = AccountService(account_repo, audit_service)
    transfer_service = TransferService(account_repo, transaction_repo, audit_service)

    # Configure route dependencies
    configure_routes(account_service, transfer_service, audit_service)
    app.include_router(router, prefix="/api/v1")

    return app


app = create_app()
