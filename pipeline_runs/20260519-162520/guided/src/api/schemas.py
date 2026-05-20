"""
Pydantic request/response schemas for the Banking Transfer API.

PATTERN: NoInformationLeakage — response schemas exclude internal fields
that should not be exposed to clients (e.g., internal IDs, version numbers
beyond what the API contract specifies).
"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Transfer schemas
# ---------------------------------------------------------------------------

class TransferRequest(BaseModel):
    source_account_id: uuid.UUID = Field(..., description="Account ID to debit")
    destination_account_id: uuid.UUID = Field(..., description="Account ID to credit")
    amount: int = Field(..., gt=0, description="Transfer amount in minor units (cents)")
    currency: str = Field(..., min_length=3, max_length=3, description="ISO 4217 currency code")


class TransferResponse(BaseModel):
    """Implements FR-003: UniqueTransactionRef — returns unique transaction reference ID."""

    transaction_id: uuid.UUID
    source_account_id: uuid.UUID
    destination_account_id: uuid.UUID
    amount: int
    currency: str
    status: str
    failure_reason_code: str | None = None
    original_transaction_id: uuid.UUID | None = None
    initiated_by: uuid.UUID
    created_at: datetime
    completed_at: datetime | None = None

    model_config = {"from_attributes": True}

    @classmethod
    def from_transfer(cls, transfer) -> TransferResponse:
        return cls(
            transaction_id=transfer.id,
            source_account_id=transfer.source_account_id,
            destination_account_id=transfer.destination_account_id,
            amount=transfer.amount,
            currency=transfer.currency,
            status=transfer.status,
            failure_reason_code=transfer.failure_reason_code,
            original_transaction_id=transfer.original_transaction_id,
            initiated_by=transfer.initiated_by,
            created_at=transfer.created_at,
            completed_at=transfer.completed_at,
        )


# ---------------------------------------------------------------------------
# Balance schemas
# ---------------------------------------------------------------------------

class BalanceResponse(BaseModel):
    """Implements FR-008: BalanceConsistency — returns both ledger and available balances."""

    account_id: uuid.UUID
    account_number: str
    ledger_balance: int
    available_balance: int
    currency: str


# ---------------------------------------------------------------------------
# Transaction history schemas
# ---------------------------------------------------------------------------

class TransactionHistoryItem(BaseModel):
    transaction_id: uuid.UUID
    source_account_id: uuid.UUID
    destination_account_id: uuid.UUID
    amount: int
    currency: str
    status: str
    created_at: datetime
    completed_at: datetime | None = None

    model_config = {"from_attributes": True}


class TransactionHistoryResponse(BaseModel):
    transactions: list[TransactionHistoryItem]
    total: int


# ---------------------------------------------------------------------------
# Audit schemas
# ---------------------------------------------------------------------------

class AuditEntryResponse(BaseModel):
    id: uuid.UUID
    transaction_id: uuid.UUID
    event_type: str
    actor_id: uuid.UUID
    timestamp: datetime
    before_state: str
    after_state: str
    reason_code: str | None = None
    fraud_signal: bool
    prev_hash: str | None = None
    current_hash: str
    sequence_number: int

    model_config = {"from_attributes": True}


class AuditVerifyResponse(BaseModel):
    is_valid: bool
    entries_checked: int
    discrepancies: list[dict]


# ---------------------------------------------------------------------------
# Step-up schemas
# ---------------------------------------------------------------------------

class StepUpRequest(BaseModel):
    challenge_response: str = Field(..., description="Step-up authentication challenge response")


# ---------------------------------------------------------------------------
# Error schemas
# ---------------------------------------------------------------------------

class ErrorResponse(BaseModel):
    detail: str
    error_code: str | None = None
