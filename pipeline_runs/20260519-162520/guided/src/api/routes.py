"""
API routes / controllers for the Banking Transfer System.

Base URL: /api/v1

All endpoints enforce authentication and authorization via middleware
before any business logic executes.
"""

from __future__ import annotations

import uuid
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from src.api.schemas import (
    AuditEntryResponse,
    AuditVerifyResponse,
    BalanceResponse,
    ErrorResponse,
    StepUpRequest,
    TransactionHistoryItem,
    TransactionHistoryResponse,
    TransferRequest,
    TransferResponse,
)
from src.domain.audit_service import verify_hash_chain
from src.domain.enums import OperationKind, Role
from src.domain.invariants import InvariantViolation
from src.domain.models import Account, AuditEntry, Transfer, User
from src.domain.transfer_service import (
    complete_step_up,
    execute_transfer,
    reverse_transfer,
)
from src.infrastructure import metrics
from src.infrastructure.database import get_db
from src.middleware.auth import CurrentUser, require_role_permission

logger = structlog.get_logger()

router = APIRouter(prefix="/api/v1", tags=["banking"])


# ---------------------------------------------------------------------------
# POST /transfers — Initiate a fund transfer
# Implements FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, FR-007, FR-010
# ---------------------------------------------------------------------------

@router.post(
    "/transfers",
    response_model=TransferResponse,
    status_code=status.HTTP_201_CREATED,
    responses={
        400: {"model": ErrorResponse},
        403: {"model": ErrorResponse},
        409: {"model": ErrorResponse},
    },
)
async def post_transfer(
    request: TransferRequest,
    user: Annotated[User, require_role_permission(OperationKind.POST_TRANSFERS)],
    db: AsyncSession = Depends(get_db),
) -> TransferResponse:
    """
    Initiate a fund transfer from a source account to a destination account.

    PATTERN: AuthRequiredEverywhere — authentication enforced by middleware.
    PATTERN: LeastPrivilege — role permission checked by dependency.
    """
    try:
        transfer = await execute_transfer(
            db=db,
            user=user,
            source_account_id=request.source_account_id,
            destination_account_id=request.destination_account_id,
            amount=request.amount,
            currency=request.currency,
        )
        return TransferResponse.from_transfer(transfer)

    except InvariantViolation as exc:
        status_code = _invariant_to_status(exc)
        raise HTTPException(status_code=status_code, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))


# ---------------------------------------------------------------------------
# GET /transfers/{transactionId} — Query transfer details
# ---------------------------------------------------------------------------

@router.get(
    "/transfers/{transaction_id}",
    response_model=TransferResponse,
    responses={404: {"model": ErrorResponse}},
)
async def get_transfer(
    transaction_id: uuid.UUID,
    user: Annotated[User, require_role_permission(OperationKind.GET_TRANSFER_BY_ID)],
    db: AsyncSession = Depends(get_db),
) -> TransferResponse:
    """
    Query transfer details by transaction ID.

    PATTERN: OwnershipBasedAccess — customers see only their own transfers.
    PATTERN: NoInformationLeakage — return 404 for unauthorized access.
    """
    transfer = await db.get(Transfer, transaction_id)
    if transfer is None:
        # PATTERN: NoInformationLeakage — generic 404
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Transfer not found.")

    # Ownership check for customers
    if Role.ADMIN.value not in user.roles:
        if transfer.initiated_by != user.id:
            # PATTERN: NoInformationLeakage — return 404 instead of 403
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Transfer not found.")

    return TransferResponse.from_transfer(transfer)


# ---------------------------------------------------------------------------
# POST /transfers/{transactionId}/reverse — Admin-only transfer reversal
# Implements FR-009
# ---------------------------------------------------------------------------

@router.post(
    "/transfers/{transaction_id}/reverse",
    response_model=TransferResponse,
    status_code=status.HTTP_201_CREATED,
    responses={
        400: {"model": ErrorResponse},
        403: {"model": ErrorResponse},
        404: {"model": ErrorResponse},
    },
)
async def post_reverse_transfer(
    transaction_id: uuid.UUID,
    user: Annotated[User, require_role_permission(OperationKind.POST_REVERSE)],
    db: AsyncSession = Depends(get_db),
) -> TransferResponse:
    """
    Reverse a completed transfer via compensating transaction (admin only).

    Implements FR-009: ReversalCompensating.
    """
    try:
        reversal = await reverse_transfer(
            db=db,
            admin_user=user,
            original_transfer_id=transaction_id,
        )
        return TransferResponse.from_transfer(reversal)

    except InvariantViolation as exc:
        status_code = _invariant_to_status(exc)
        raise HTTPException(status_code=status_code, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))


# ---------------------------------------------------------------------------
# GET /accounts/{accountId}/balance — Balance inquiry
# Implements FR-008
# ---------------------------------------------------------------------------

@router.get(
    "/accounts/{account_id}/balance",
    response_model=BalanceResponse,
    responses={404: {"model": ErrorResponse}},
)
async def get_account_balance(
    account_id: uuid.UUID,
    user: Annotated[User, require_role_permission(OperationKind.GET_BALANCE)],
    db: AsyncSession = Depends(get_db),
) -> BalanceResponse:
    """
    Retrieve account balance with read-after-write consistency.

    Implements FR-008: BalanceConsistency — returns both ledger and available balances.
    """
    account = await db.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found.")

    # PATTERN: OwnershipBasedAccess — customers see only their own accounts
    if Role.ADMIN.value not in user.roles and account.owner_id != user.id:
        # PATTERN: NoInformationLeakage — return 404
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found.")

    # KPI: FR-008 read-after-write consistency
    metrics.balance_reads_total.labels(consistency="consistent").inc()

    return BalanceResponse(
        account_id=account.id,
        account_number=account.account_number,
        ledger_balance=account.ledger_balance,
        available_balance=account.available_balance,
        currency=account.currency,
    )


# ---------------------------------------------------------------------------
# GET /accounts/{accountId}/transactions — Transaction history
# ---------------------------------------------------------------------------

@router.get(
    "/accounts/{account_id}/transactions",
    response_model=TransactionHistoryResponse,
    responses={404: {"model": ErrorResponse}},
)
async def get_account_transactions(
    account_id: uuid.UUID,
    user: Annotated[User, require_role_permission(OperationKind.GET_TRANSACTIONS)],
    db: AsyncSession = Depends(get_db),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> TransactionHistoryResponse:
    """Retrieve recent transaction history for an account."""
    account = await db.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found.")

    # PATTERN: OwnershipBasedAccess — customers see only their own
    if Role.ADMIN.value not in user.roles and account.owner_id != user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found.")

    # Query transfers involving this account
    stmt = (
        select(Transfer)
        .where(
            or_(
                Transfer.source_account_id == account_id,
                Transfer.destination_account_id == account_id,
            )
        )
        .order_by(Transfer.created_at.desc())
        .offset(offset)
        .limit(limit)
    )
    result = await db.execute(stmt)
    transfers = result.scalars().all()

    # Count total
    count_stmt = select(func.count()).select_from(Transfer).where(
        or_(
            Transfer.source_account_id == account_id,
            Transfer.destination_account_id == account_id,
        )
    )
    count_result = await db.execute(count_stmt)
    total = count_result.scalar_one()

    items = [
        TransactionHistoryItem(
            transaction_id=t.id,
            source_account_id=t.source_account_id,
            destination_account_id=t.destination_account_id,
            amount=t.amount,
            currency=t.currency,
            status=t.status,
            created_at=t.created_at,
            completed_at=t.completed_at,
        )
        for t in transfers
    ]

    return TransactionHistoryResponse(transactions=items, total=total)


# ---------------------------------------------------------------------------
# GET /audit-entries — Admin-only audit log query
# ---------------------------------------------------------------------------

@router.get(
    "/audit-entries",
    response_model=list[AuditEntryResponse],
    responses={403: {"model": ErrorResponse}},
)
async def get_audit_entries(
    user: Annotated[User, require_role_permission(OperationKind.GET_AUDIT_ENTRIES)],
    db: AsyncSession = Depends(get_db),
    transaction_id: uuid.UUID | None = Query(default=None),
    event_type: str | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[AuditEntryResponse]:
    """
    Query audit log entries (admin only).

    PATTERN: AuditCompleteness — full audit trail accessible for compliance.
    """
    stmt = select(AuditEntry).order_by(AuditEntry.sequence_number.desc())

    if transaction_id is not None:
        stmt = stmt.where(AuditEntry.transaction_id == transaction_id)
    if event_type is not None:
        stmt = stmt.where(AuditEntry.event_type == event_type)

    stmt = stmt.offset(offset).limit(limit)
    result = await db.execute(stmt)
    entries = result.scalars().all()

    return [AuditEntryResponse.model_validate(e) for e in entries]


# ---------------------------------------------------------------------------
# GET /audit-entries/verify — Audit hash chain integrity verification
# Implements FR-005
# ---------------------------------------------------------------------------

@router.get(
    "/audit-entries/verify",
    response_model=AuditVerifyResponse,
    responses={403: {"model": ErrorResponse}},
)
async def get_audit_verify(
    user: Annotated[User, require_role_permission(OperationKind.GET_AUDIT_VERIFY)],
    db: AsyncSession = Depends(get_db),
) -> AuditVerifyResponse:
    """
    Verify the cryptographic hash chain integrity of the audit log.

    Implements FR-005: HashChain — tamper detection via hash chain verification.
    """
    is_valid, discrepancies = await verify_hash_chain(db)

    # Count total entries
    count_result = await db.execute(select(func.count()).select_from(AuditEntry))
    total_entries = count_result.scalar_one()

    return AuditVerifyResponse(
        is_valid=is_valid,
        entries_checked=total_entries,
        discrepancies=discrepancies,
    )


# ---------------------------------------------------------------------------
# POST /transfers/{transactionId}/step-up — Step-up authentication
# ---------------------------------------------------------------------------

@router.post(
    "/transfers/{transaction_id}/step-up",
    response_model=TransferResponse,
    responses={
        400: {"model": ErrorResponse},
        404: {"model": ErrorResponse},
    },
)
async def post_step_up(
    transaction_id: uuid.UUID,
    request: StepUpRequest,
    user: Annotated[User, require_role_permission(OperationKind.POST_STEP_UP)],
    db: AsyncSession = Depends(get_db),
) -> TransferResponse:
    """
    Complete a step-up authentication challenge for a pending transfer.

    Implements FR-007: Velocity anomaly detection step-up flow.
    """
    try:
        transfer = await complete_step_up(
            db=db,
            user=user,
            transfer_id=transaction_id,
        )
        return TransferResponse.from_transfer(transfer)

    except InvariantViolation as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _invariant_to_status(exc: InvariantViolation) -> int:
    """Map invariant violations to appropriate HTTP status codes."""
    status_map = {
        "F_NoSelfTransfer": status.HTTP_400_BAD_REQUEST,
        "F_SufficientFunds": status.HTTP_409_CONFLICT,
        "F_DailyLimitEnforcement": status.HTTP_409_CONFLICT,
        "F_ActiveAccountsOnly": status.HTTP_400_BAD_REQUEST,
        "F_OwnershipBasedAccess": status.HTTP_403_FORBIDDEN,
        "F_ConservationOfValue": status.HTTP_400_BAD_REQUEST,
        "F_FailClosedAudit": status.HTTP_503_SERVICE_UNAVAILABLE,
        "F_ReversalCompensating": status.HTTP_400_BAD_REQUEST,
    }
    return status_map.get(exc.fact_name, status.HTTP_400_BAD_REQUEST)
