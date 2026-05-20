from __future__ import annotations

import enum
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, Field, field_validator


class TransactionStatus(str, enum.Enum):
    PENDING = "pending"
    COMPLETED = "completed"
    FAILED = "failed"


class AuditAction(str, enum.Enum):
    ACCOUNT_CREATED = "account_created"
    TRANSFER_INITIATED = "transfer_initiated"
    TRANSFER_COMPLETED = "transfer_completed"
    TRANSFER_FAILED = "transfer_failed"
    ACCOUNT_FROZEN = "account_frozen"
    ACCOUNT_UNFROZEN = "account_unfrozen"


class Account(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    owner: str
    balance: Decimal = Decimal("0.00")
    currency: str = "USD"
    is_frozen: bool = False
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    @field_validator("balance")
    @classmethod
    def balance_not_negative(cls, v: Decimal) -> Decimal:
        if v < 0:
            raise ValueError("Balance cannot be negative")
        return v

    @field_validator("owner")
    @classmethod
    def owner_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Owner cannot be empty")
        return v.strip()


class Transaction(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    source_account_id: str
    destination_account_id: str
    amount: Decimal
    currency: str = "USD"
    status: TransactionStatus = TransactionStatus.PENDING
    initiated_by: str
    reason: Optional[str] = None
    failure_reason: Optional[str] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    completed_at: Optional[datetime] = None

    @field_validator("amount")
    @classmethod
    def amount_positive(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("Transfer amount must be positive")
        return v


class AuditEntry(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    action: AuditAction
    actor: str
    resource_type: str
    resource_id: str
    details: dict = Field(default_factory=dict)
