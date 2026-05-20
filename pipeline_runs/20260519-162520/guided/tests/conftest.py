"""
Shared fixtures for specification-led tests.

Provides lightweight, in-memory stand-ins for the ORM models so that the
invariant / permission / audit / fraud logic can be exercised without an
actual database or async event loop.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

import pytest

from src.domain.enums import (
    AccountStatus,
    AuthenticationStatus,
    FraudAction,
    Role,
    TransferStatus,
)


# ---------------------------------------------------------------------------
# Lightweight model stubs (no DB required)
# ---------------------------------------------------------------------------


@dataclass
class StubUser:
    """Mimics the User ORM model for unit-level invariant tests."""

    id: uuid.UUID = field(default_factory=uuid.uuid4)
    email: str = "user@example.com"
    full_name: str = "Test User"
    roles: list[str] = field(default_factory=lambda: [Role.CUSTOMER.value])
    authentication_status: str = AuthenticationStatus.AUTHENTICATED.value
    daily_transfer_total: int = 0
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class StubAccount:
    """Mimics the Account ORM model for unit-level invariant tests."""

    id: uuid.UUID = field(default_factory=uuid.uuid4)
    owner_id: uuid.UUID = field(default_factory=uuid.uuid4)
    account_number: str = "ACC-001"
    ledger_balance: int = 100_000
    available_balance: int = 100_000
    currency: str = "USD"
    daily_limit: int = 500_000
    account_status: str = AccountStatus.ACTIVE.value
    version: int = 1
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class StubTransfer:
    """Mimics the Transfer ORM model."""

    id: uuid.UUID = field(default_factory=uuid.uuid4)
    source_account_id: uuid.UUID = field(default_factory=uuid.uuid4)
    destination_account_id: uuid.UUID = field(default_factory=uuid.uuid4)
    amount: int = 1_000
    currency: str = "USD"
    status: str = TransferStatus.COMPLETED.value
    failure_reason_code: str | None = None
    original_transaction_id: uuid.UUID | None = None
    initiated_by: uuid.UUID = field(default_factory=uuid.uuid4)
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    completed_at: datetime | None = field(default_factory=lambda: datetime.now(timezone.utc))
    audit_entries: list[Any] = field(default_factory=list)
    fraud_signal: Any | None = None


@dataclass
class StubFraudSignal:
    """Mimics the FraudSignal ORM model."""

    id: uuid.UUID = field(default_factory=uuid.uuid4)
    transaction_id: uuid.UUID = field(default_factory=uuid.uuid4)
    account_id: uuid.UUID = field(default_factory=uuid.uuid4)
    risk_score: int = 0
    trigger_rules: list[str] = field(default_factory=lambda: ["VELOCITY"])
    action: str = FraudAction.ALLOW.value
    step_up_completed: bool | None = None
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


# ---------------------------------------------------------------------------
# Common fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def customer_user() -> StubUser:
    """Return an authenticated CUSTOMER user."""
    return StubUser(roles=[Role.CUSTOMER.value])


@pytest.fixture
def admin_user() -> StubUser:
    """Return an authenticated ADMIN user."""
    return StubUser(
        roles=[Role.ADMIN.value],
        email="admin@example.com",
        full_name="Admin User",
    )


@pytest.fixture
def unauthenticated_user() -> StubUser:
    """Return an unauthenticated user."""
    return StubUser(
        authentication_status=AuthenticationStatus.UNAUTHENTICATED.value,
    )


@pytest.fixture
def locked_user() -> StubUser:
    """Return a locked user."""
    return StubUser(
        authentication_status=AuthenticationStatus.LOCKED.value,
    )


@pytest.fixture
def active_account(customer_user: StubUser) -> StubAccount:
    """Return an active account owned by the customer_user."""
    return StubAccount(
        owner_id=customer_user.id,
        ledger_balance=100_000,
        available_balance=100_000,
        daily_limit=500_000,
    )


@pytest.fixture
def destination_account() -> StubAccount:
    """Return a second active account for transfers."""
    return StubAccount(
        account_number="ACC-002",
        ledger_balance=50_000,
        available_balance=50_000,
        daily_limit=500_000,
    )


@pytest.fixture
def frozen_account() -> StubAccount:
    """Return a frozen account."""
    return StubAccount(
        account_status=AccountStatus.FROZEN.value,
        account_number="ACC-FROZEN",
    )


@pytest.fixture
def closed_account() -> StubAccount:
    """Return a closed account."""
    return StubAccount(
        account_status=AccountStatus.CLOSED.value,
        account_number="ACC-CLOSED",
    )
