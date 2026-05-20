from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

from banking.api.schemas import (
    AccountResponse,
    AuditEntryResponse,
    CreateAccountRequest,
    FreezeRequest,
    TransactionResponse,
    TransferRequest,
)
from banking.domain.exceptions import (
    AccountFrozenError,
    AccountNotFoundError,
    BankingError,
    CurrencyMismatchError,
    InsufficientFundsError,
    SelfTransferError,
    UnauthorizedError,
)
from banking.services.account_service import AccountService
from banking.services.audit_service import AuditService
from banking.services.transfer_service import TransferService

router = APIRouter()

# These will be injected at app startup
_account_service: AccountService | None = None
_transfer_service: TransferService | None = None
_audit_service: AuditService | None = None


def configure_routes(
    account_service: AccountService,
    transfer_service: TransferService,
    audit_service: AuditService,
) -> None:
    global _account_service, _transfer_service, _audit_service
    _account_service = account_service
    _transfer_service = transfer_service
    _audit_service = audit_service


def _banking_error_to_http(exc: BankingError) -> HTTPException:
    if isinstance(exc, AccountNotFoundError):
        return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc))
    if isinstance(exc, UnauthorizedError):
        return HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))
    if isinstance(exc, (SelfTransferError, CurrencyMismatchError)):
        return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    if isinstance(exc, InsufficientFundsError):
        return HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc))
    if isinstance(exc, AccountFrozenError):
        return HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))


# --- Account endpoints ---


@router.post("/accounts", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(req: CreateAccountRequest) -> AccountResponse:
    assert _account_service is not None
    try:
        account = _account_service.create_account(
            owner=req.owner,
            initial_balance=req.initial_balance,
            currency=req.currency,
        )
    except BankingError as exc:
        raise _banking_error_to_http(exc)
    return AccountResponse(
        id=account.id,
        owner=account.owner,
        balance=account.balance,
        currency=account.currency,
        is_frozen=account.is_frozen,
    )


@router.get("/accounts", response_model=list[AccountResponse])
def list_accounts() -> list[AccountResponse]:
    assert _account_service is not None
    return [
        AccountResponse(
            id=a.id, owner=a.owner, balance=a.balance, currency=a.currency, is_frozen=a.is_frozen
        )
        for a in _account_service.list_accounts()
    ]


@router.get("/accounts/{account_id}", response_model=AccountResponse)
def get_account(account_id: str) -> AccountResponse:
    assert _account_service is not None
    try:
        account = _account_service.get_account(account_id)
    except BankingError as exc:
        raise _banking_error_to_http(exc)
    return AccountResponse(
        id=account.id,
        owner=account.owner,
        balance=account.balance,
        currency=account.currency,
        is_frozen=account.is_frozen,
    )


@router.post("/accounts/{account_id}/freeze", response_model=AccountResponse)
def freeze_account(account_id: str, req: FreezeRequest) -> AccountResponse:
    assert _account_service is not None
    try:
        account = _account_service.freeze_account(account_id, actor=req.actor)
    except BankingError as exc:
        raise _banking_error_to_http(exc)
    return AccountResponse(
        id=account.id,
        owner=account.owner,
        balance=account.balance,
        currency=account.currency,
        is_frozen=account.is_frozen,
    )


@router.post("/accounts/{account_id}/unfreeze", response_model=AccountResponse)
def unfreeze_account(account_id: str, req: FreezeRequest) -> AccountResponse:
    assert _account_service is not None
    try:
        account = _account_service.unfreeze_account(account_id, actor=req.actor)
    except BankingError as exc:
        raise _banking_error_to_http(exc)
    return AccountResponse(
        id=account.id,
        owner=account.owner,
        balance=account.balance,
        currency=account.currency,
        is_frozen=account.is_frozen,
    )


# --- Transfer endpoints ---


@router.post("/transfers", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def create_transfer(req: TransferRequest) -> TransactionResponse:
    assert _transfer_service is not None
    try:
        txn = _transfer_service.transfer(
            source_account_id=req.source_account_id,
            destination_account_id=req.destination_account_id,
            amount=req.amount,
            initiated_by=req.initiated_by,
            reason=req.reason,
        )
    except BankingError as exc:
        raise _banking_error_to_http(exc)
    return TransactionResponse(
        id=txn.id,
        source_account_id=txn.source_account_id,
        destination_account_id=txn.destination_account_id,
        amount=txn.amount,
        currency=txn.currency,
        status=txn.status.value,
        initiated_by=txn.initiated_by,
        reason=txn.reason,
        failure_reason=txn.failure_reason,
        created_at=txn.created_at.isoformat(),
        completed_at=txn.completed_at.isoformat() if txn.completed_at else None,
    )


@router.get("/accounts/{account_id}/transactions", response_model=list[TransactionResponse])
def list_account_transactions(account_id: str) -> list[TransactionResponse]:
    assert _transfer_service is not None
    return [
        TransactionResponse(
            id=t.id,
            source_account_id=t.source_account_id,
            destination_account_id=t.destination_account_id,
            amount=t.amount,
            currency=t.currency,
            status=t.status.value,
            initiated_by=t.initiated_by,
            reason=t.reason,
            failure_reason=t.failure_reason,
            created_at=t.created_at.isoformat(),
            completed_at=t.completed_at.isoformat() if t.completed_at else None,
        )
        for t in _transfer_service.get_account_transactions(account_id)
    ]


# --- Audit endpoints ---


@router.get("/audit", response_model=list[AuditEntryResponse])
def list_audit_log() -> list[AuditEntryResponse]:
    assert _audit_service is not None
    return [
        AuditEntryResponse(
            id=e.id,
            timestamp=e.timestamp.isoformat(),
            action=e.action.value,
            actor=e.actor,
            resource_type=e.resource_type,
            resource_id=e.resource_id,
            details=e.details,
        )
        for e in _audit_service.get_full_log()
    ]


@router.get("/audit/{resource_type}/{resource_id}", response_model=list[AuditEntryResponse])
def get_resource_audit_trail(resource_type: str, resource_id: str) -> list[AuditEntryResponse]:
    assert _audit_service is not None
    return [
        AuditEntryResponse(
            id=e.id,
            timestamp=e.timestamp.isoformat(),
            action=e.action.value,
            actor=e.actor,
            resource_type=e.resource_type,
            resource_id=e.resource_id,
            details=e.details,
        )
        for e in _audit_service.get_audit_trail(resource_type, resource_id)
    ]
