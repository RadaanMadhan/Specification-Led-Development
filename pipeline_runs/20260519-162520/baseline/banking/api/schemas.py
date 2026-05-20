from __future__ import annotations

from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, Field


class CreateAccountRequest(BaseModel):
    owner: str
    initial_balance: Decimal = Decimal("0.00")
    currency: str = "USD"


class TransferRequest(BaseModel):
    source_account_id: str
    destination_account_id: str
    amount: Decimal = Field(gt=0)
    initiated_by: str
    reason: Optional[str] = None


class AccountResponse(BaseModel):
    id: str
    owner: str
    balance: Decimal
    currency: str
    is_frozen: bool


class TransactionResponse(BaseModel):
    id: str
    source_account_id: str
    destination_account_id: str
    amount: Decimal
    currency: str
    status: str
    initiated_by: str
    reason: Optional[str]
    failure_reason: Optional[str]
    created_at: str
    completed_at: Optional[str]


class AuditEntryResponse(BaseModel):
    id: str
    timestamp: str
    action: str
    actor: str
    resource_type: str
    resource_id: str
    details: dict


class FreezeRequest(BaseModel):
    actor: str


class ErrorResponse(BaseModel):
    error: str
    detail: str
