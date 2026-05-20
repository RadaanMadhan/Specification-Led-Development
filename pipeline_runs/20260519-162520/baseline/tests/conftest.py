from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from banking.api.app import create_app
from banking.api.routes import _account_service, _audit_service, _transfer_service
from banking.repositories.account_repository import InMemoryAccountRepository
from banking.repositories.audit_repository import InMemoryAuditRepository
from banking.repositories.transaction_repository import InMemoryTransactionRepository
from banking.services.account_service import AccountService
from banking.services.audit_service import AuditService
from banking.services.transfer_service import TransferService


@pytest.fixture
def audit_repo() -> InMemoryAuditRepository:
    return InMemoryAuditRepository()


@pytest.fixture
def account_repo() -> InMemoryAccountRepository:
    return InMemoryAccountRepository()


@pytest.fixture
def transaction_repo() -> InMemoryTransactionRepository:
    return InMemoryTransactionRepository()


@pytest.fixture
def audit_service(audit_repo: InMemoryAuditRepository) -> AuditService:
    return AuditService(audit_repo)


@pytest.fixture
def account_service(
    account_repo: InMemoryAccountRepository,
    audit_service: AuditService,
) -> AccountService:
    return AccountService(account_repo, audit_service)


@pytest.fixture
def transfer_service(
    account_repo: InMemoryAccountRepository,
    transaction_repo: InMemoryTransactionRepository,
    audit_service: AuditService,
) -> TransferService:
    return TransferService(account_repo, transaction_repo, audit_service)


@pytest.fixture
def client() -> TestClient:
    app = create_app()
    return TestClient(app)
