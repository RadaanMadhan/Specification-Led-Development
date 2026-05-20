"""
Transfer domain service — core business logic.

Implements FR-001: Atomic transfers (ACID).
Implements FR-002: Sufficient funds validation.
Implements FR-003: Unique transaction reference IDs.
Implements FR-008: Balance consistency (read-after-write).
Implements FR-009: Administrative transfer reversal.
Implements FR-010: Fail-closed on audit unavailability.
"""

from __future__ import annotations

import time
import uuid
from datetime import datetime, timedelta, timezone

import structlog
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from src.config import settings
from src.domain.audit_service import create_audit_entry
from src.domain.enums import (
    AuditEventType,
    FailureReasonCode,
    FraudAction,
    TransferStatus,
)
from src.domain.fraud_service import evaluate_fraud_risk, get_daily_transfer_total
from src.domain.invariants import (
    InvariantViolation,
    check_active_accounts,
    check_audit_completeness,
    check_conservation_of_value,
    check_daily_limit,
    check_fail_closed_audit,
    check_no_self_transfer,
    check_ownership_based_access,
    check_reversal_compensating,
    check_sufficient_funds,
)
from src.domain.models import Account, Transfer, User
from src.infrastructure import metrics

logger = structlog.get_logger()


async def execute_transfer(
    db: AsyncSession,
    user: User,
    source_account_id: uuid.UUID,
    destination_account_id: uuid.UUID,
    amount: int,
    currency: str,
) -> Transfer:
    """
    Execute a fund transfer atomically.

    Implements FR-001: AtomicTransfer — either both debit and credit complete, or neither does.
    Implements FR-002: SufficientFunds — validates available balance before debit.
    Implements FR-003: UniqueTransactionRef — UUID primary key as transaction reference.
    Implements FR-006: DailyLimit — enforces per-account daily transfer limits.
    Implements FR-007: Velocity anomaly detection triggers step-up or block.
    Implements FR-010: FailClosedAudit — no transfer completes without audit entries.
    """
    start_time = time.monotonic()
    transfer_id = uuid.uuid4()

    # KPI: FR-003 — unique transaction reference ID generated
    metrics.transaction_ids_generated.inc()

    try:
        # --- Step 1: Pre-validation ---

        # HARDENED: F_NoSelfTransfer — explicit runtime guard against self-transfer
        check_no_self_transfer(source_account_id, destination_account_id)

        # Load accounts with row-level locking for ACID
        source_account = await db.get(Account, source_account_id, with_for_update=True)
        dest_account = await db.get(Account, destination_account_id, with_for_update=True)

        if source_account is None or dest_account is None:
            raise ValueError("Source or destination account not found.")

        # INVARIANT: F_ActiveAccountsOnly — only active accounts participate
        check_active_accounts(source_account.account_status, dest_account.account_status)

        # HARDENED: F_OwnershipBasedAccess — customers can only transfer from own accounts
        check_ownership_based_access(user, source_account.owner_id)

        # Validate currency match
        if source_account.currency != currency or dest_account.currency != currency:
            raise ValueError(
                f"Currency mismatch: transfer={currency}, "
                f"source={source_account.currency}, dest={dest_account.currency}."
            )

        # INVARIANT: F_ConservationOfValue — amount must be positive
        check_conservation_of_value(amount, source_account.available_balance, dest_account.available_balance)

        # Create transfer record in INITIATED state
        transfer = Transfer(
            id=transfer_id,
            source_account_id=source_account_id,
            destination_account_id=destination_account_id,
            amount=amount,
            currency=currency,
            status=TransferStatus.INITIATED.value,
            initiated_by=user.id,
        )
        db.add(transfer)
        await db.flush()

        # PATTERN: AuditCompleteness — log INITIATED event
        await create_audit_entry(
            db=db,
            transaction_id=transfer_id,
            event_type=AuditEventType.INITIATED,
            actor_id=user.id,
            transfer_initiator_id=user.id,
            before_state={
                "source_balance": source_account.available_balance,
                "dest_balance": dest_account.available_balance,
            },
            after_state={"transfer_status": TransferStatus.INITIATED.value},
        )

        # --- Step 2: Fraud evaluation ---

        fraud_signal = await evaluate_fraud_risk(
            db=db,
            source_account=source_account,
            amount=amount,
            transfer_id=transfer_id,
        )

        if fraud_signal.action == FraudAction.BLOCK.value:
            transfer.status = TransferStatus.FAILED.value
            transfer.failure_reason_code = FailureReasonCode.VELOCITY_ALERT.value
            transfer.completed_at = datetime.now(timezone.utc)

            await create_audit_entry(
                db=db,
                transaction_id=transfer_id,
                event_type=AuditEventType.REJECTED,
                actor_id=user.id,
                transfer_initiator_id=user.id,
                before_state={"transfer_status": TransferStatus.INITIATED.value},
                after_state={"transfer_status": TransferStatus.FAILED.value},
                reason_code=FailureReasonCode.VELOCITY_ALERT.value,
                is_fraud_signal=True,
            )

            await db.flush()
            metrics.transfer_attempts_total.labels(status="failed").inc()
            return transfer

        if fraud_signal.action == FraudAction.STEP_UP.value:
            # Transfer stays INITIATED, waiting for step-up completion
            await create_audit_entry(
                db=db,
                transaction_id=transfer_id,
                event_type=AuditEventType.STEP_UP_REQUESTED,
                actor_id=user.id,
                transfer_initiator_id=user.id,
                before_state={"transfer_status": TransferStatus.INITIATED.value},
                after_state={"step_up_required": True},
                is_fraud_signal=True,
            )
            metrics.step_up_challenges_total.labels(result="issued").inc()
            await db.flush()
            return transfer

        # --- Step 3: Validation ---

        # INVARIANT: F_SufficientFunds
        check_sufficient_funds(source_account.available_balance, amount)
        metrics.balance_validations_total.labels(result="passed").inc()

        # FR-006: Daily limit enforcement
        daily_total = await get_daily_transfer_total(db, source_account_id)
        check_daily_limit(source_account.daily_limit, daily_total, amount)

        transfer.status = TransferStatus.VALIDATED.value

        await create_audit_entry(
            db=db,
            transaction_id=transfer_id,
            event_type=AuditEventType.VALIDATED,
            actor_id=user.id,
            transfer_initiator_id=user.id,
            before_state={"transfer_status": TransferStatus.INITIATED.value},
            after_state={"transfer_status": TransferStatus.VALIDATED.value},
        )

        # --- Step 4: Debit source ---

        source_before = source_account.available_balance
        source_account.available_balance -= amount
        source_account.ledger_balance -= amount
        source_account.version += 1

        await create_audit_entry(
            db=db,
            transaction_id=transfer_id,
            event_type=AuditEventType.DEBITED,
            actor_id=user.id,
            transfer_initiator_id=user.id,
            before_state={
                "source_available": source_before,
                "source_ledger": source_before,
            },
            after_state={
                "source_available": source_account.available_balance,
                "source_ledger": source_account.ledger_balance,
            },
        )

        # --- Step 5: Credit destination ---

        dest_before = dest_account.available_balance
        dest_account.available_balance += amount
        dest_account.ledger_balance += amount
        dest_account.version += 1

        await create_audit_entry(
            db=db,
            transaction_id=transfer_id,
            event_type=AuditEventType.CREDITED,
            actor_id=user.id,
            transfer_initiator_id=user.id,
            before_state={
                "dest_available": dest_before,
                "dest_ledger": dest_before,
            },
            after_state={
                "dest_available": dest_account.available_balance,
                "dest_ledger": dest_account.ledger_balance,
            },
        )

        # --- Step 6: Complete transfer ---

        transfer.status = TransferStatus.COMPLETED.value
        transfer.completed_at = datetime.now(timezone.utc)

        await create_audit_entry(
            db=db,
            transaction_id=transfer_id,
            event_type=AuditEventType.COMPLETED,
            actor_id=user.id,
            transfer_initiator_id=user.id,
            before_state={"transfer_status": TransferStatus.VALIDATED.value},
            after_state={"transfer_status": TransferStatus.COMPLETED.value},
        )

        # INVARIANT: F_FailClosedAudit — verify audit entries exist before committing
        await db.flush()
        audit_count = len(transfer.audit_entries) if transfer.audit_entries else 0
        check_fail_closed_audit(transfer.status, audit_count)
        check_audit_completeness(transfer_id, audit_count)

        await db.commit()

        # KPI: FR-001 transfer success
        metrics.transfer_attempts_total.labels(status="completed").inc()
        elapsed = time.monotonic() - start_time
        metrics.transfer_latency.observe(elapsed)

        logger.info(
            "transfer_completed",
            transfer_id=str(transfer_id),
            amount=amount,
            elapsed_seconds=elapsed,
        )

        return transfer

    except InvariantViolation as exc:
        await db.rollback()

        # Map invariant violations to failure reason codes
        reason_map = {
            "F_NoSelfTransfer": FailureReasonCode.SAME_ACCOUNT_TRANSFER,
            "F_SufficientFunds": FailureReasonCode.INSUFFICIENT_FUNDS,
            "F_DailyLimitEnforcement": FailureReasonCode.DAILY_LIMIT_EXCEEDED,
            "F_FailClosedAudit": FailureReasonCode.AUDIT_UNAVAILABLE,
            "F_OwnershipBasedAccess": None,  # 403, not a transfer failure
        }
        reason = reason_map.get(exc.fact_name)

        if reason is not None:
            # Record the failed transfer with reason
            failed_transfer = Transfer(
                id=transfer_id,
                source_account_id=source_account_id,
                destination_account_id=destination_account_id,
                amount=amount,
                currency=currency,
                status=TransferStatus.FAILED.value,
                failure_reason_code=reason.value,
                initiated_by=user.id,
                completed_at=datetime.now(timezone.utc),
            )
            db.add(failed_transfer)
            try:
                await create_audit_entry(
                    db=db,
                    transaction_id=transfer_id,
                    event_type=AuditEventType.REJECTED,
                    actor_id=user.id,
                    transfer_initiator_id=user.id,
                    before_state={},
                    after_state={"failure_reason": reason.value},
                    reason_code=reason.value,
                )
                await db.commit()
            except Exception:
                await db.rollback()

        metrics.transfer_attempts_total.labels(status="failed").inc()
        if exc.fact_name == "F_SufficientFunds":
            metrics.balance_validations_total.labels(result="failed").inc()
        raise

    except Exception as exc:
        await db.rollback()
        metrics.transfer_attempts_total.labels(status="failed").inc()
        logger.error("transfer_failed", transfer_id=str(transfer_id), error=str(exc))
        raise


async def complete_step_up(
    db: AsyncSession,
    user: User,
    transfer_id: uuid.UUID,
) -> Transfer:
    """
    Complete a step-up authentication challenge for a pending transfer.

    After step-up is verified, the transfer resumes normal execution flow.
    """
    transfer = await db.get(Transfer, transfer_id, with_for_update=True)
    if transfer is None:
        raise ValueError(f"Transfer {transfer_id} not found.")

    if transfer.status != TransferStatus.INITIATED.value:
        raise ValueError(f"Transfer {transfer_id} is not awaiting step-up (status={transfer.status}).")

    if transfer.fraud_signal is None or transfer.fraud_signal.action != FraudAction.STEP_UP.value:
        raise ValueError(f"Transfer {transfer_id} does not require step-up.")

    # Mark step-up as completed
    transfer.fraud_signal.step_up_completed = True

    await create_audit_entry(
        db=db,
        transaction_id=transfer_id,
        event_type=AuditEventType.STEP_UP_COMPLETED,
        actor_id=user.id,
        transfer_initiator_id=transfer.initiated_by,
        before_state={"step_up_completed": False},
        after_state={"step_up_completed": True},
    )

    metrics.step_up_challenges_total.labels(result="completed").inc()

    # Resume transfer execution
    return await _resume_transfer_after_step_up(db, user, transfer)


async def _resume_transfer_after_step_up(
    db: AsyncSession,
    user: User,
    transfer: Transfer,
) -> Transfer:
    """Resume a transfer after successful step-up authentication."""
    source_account = await db.get(Account, transfer.source_account_id, with_for_update=True)
    dest_account = await db.get(Account, transfer.destination_account_id, with_for_update=True)

    if source_account is None or dest_account is None:
        raise ValueError("Account not found during step-up resume.")

    # Re-validate after step-up
    check_sufficient_funds(source_account.available_balance, transfer.amount)

    daily_total = await get_daily_transfer_total(db, source_account.id)
    check_daily_limit(source_account.daily_limit, daily_total, transfer.amount)

    transfer.status = TransferStatus.VALIDATED.value

    await create_audit_entry(
        db=db,
        transaction_id=transfer.id,
        event_type=AuditEventType.VALIDATED,
        actor_id=user.id,
        transfer_initiator_id=transfer.initiated_by,
        before_state={"transfer_status": TransferStatus.INITIATED.value},
        after_state={"transfer_status": TransferStatus.VALIDATED.value},
    )

    # Debit
    source_before = source_account.available_balance
    source_account.available_balance -= transfer.amount
    source_account.ledger_balance -= transfer.amount
    source_account.version += 1

    await create_audit_entry(
        db=db,
        transaction_id=transfer.id,
        event_type=AuditEventType.DEBITED,
        actor_id=user.id,
        transfer_initiator_id=transfer.initiated_by,
        before_state={"source_available": source_before},
        after_state={"source_available": source_account.available_balance},
    )

    # Credit
    dest_before = dest_account.available_balance
    dest_account.available_balance += transfer.amount
    dest_account.ledger_balance += transfer.amount
    dest_account.version += 1

    await create_audit_entry(
        db=db,
        transaction_id=transfer.id,
        event_type=AuditEventType.CREDITED,
        actor_id=user.id,
        transfer_initiator_id=transfer.initiated_by,
        before_state={"dest_available": dest_before},
        after_state={"dest_available": dest_account.available_balance},
    )

    # Complete
    transfer.status = TransferStatus.COMPLETED.value
    transfer.completed_at = datetime.now(timezone.utc)

    await create_audit_entry(
        db=db,
        transaction_id=transfer.id,
        event_type=AuditEventType.COMPLETED,
        actor_id=user.id,
        transfer_initiator_id=transfer.initiated_by,
        before_state={"transfer_status": TransferStatus.VALIDATED.value},
        after_state={"transfer_status": TransferStatus.COMPLETED.value},
    )

    await db.flush()
    audit_count = len(transfer.audit_entries) if transfer.audit_entries else 0
    check_fail_closed_audit(transfer.status, audit_count)
    await db.commit()

    metrics.transfer_attempts_total.labels(status="completed").inc()
    return transfer


async def reverse_transfer(
    db: AsyncSession,
    admin_user: User,
    original_transfer_id: uuid.UUID,
) -> Transfer:
    """
    Reverse a completed transfer via a compensating transaction.

    Implements FR-009: ReversalCompensating — reversal swaps source/dest,
    preserves amount, and maintains full audit linkage.
    """
    original = await db.get(Transfer, original_transfer_id, with_for_update=True)
    if original is None:
        raise ValueError(f"Transfer {original_transfer_id} not found.")

    # Check reversal window
    if original.completed_at is None:
        raise ValueError("Original transfer has no completion timestamp.")

    window_end = original.completed_at + timedelta(days=settings.reversal_window_days)
    if datetime.now(timezone.utc) > window_end:
        raise InvariantViolation(
            "F_ReversalCompensating",
            f"Reversal window expired (completed={original.completed_at}, window={settings.reversal_window_days} days).",
        )

    # Check if already reversed
    if original.status == TransferStatus.REVERSED.value:
        raise InvariantViolation(
            "F_ReversalCompensating",
            "Transfer has already been reversed.",
        )

    # INVARIANT: F_ReversalCompensating — validate reversal structure
    check_reversal_compensating(
        reversal_source_id=original.destination_account_id,
        reversal_dest_id=original.source_account_id,
        reversal_amount=original.amount,
        original_source_id=original.source_account_id,
        original_dest_id=original.destination_account_id,
        original_amount=original.amount,
        original_status=original.status,
    )

    # Create compensating transfer
    reversal_id = uuid.uuid4()
    metrics.transaction_ids_generated.inc()

    reversal = Transfer(
        id=reversal_id,
        source_account_id=original.destination_account_id,
        destination_account_id=original.source_account_id,
        amount=original.amount,
        currency=original.currency,
        status=TransferStatus.INITIATED.value,
        original_transaction_id=original.id,
        initiated_by=admin_user.id,
    )
    db.add(reversal)
    await db.flush()

    await create_audit_entry(
        db=db,
        transaction_id=reversal_id,
        event_type=AuditEventType.REVERSAL_INITIATED,
        actor_id=admin_user.id,
        transfer_initiator_id=admin_user.id,
        before_state={
            "original_transfer_id": str(original.id),
            "original_status": original.status,
        },
        after_state={"reversal_status": TransferStatus.INITIATED.value},
    )

    # Execute the reversal (debit original dest, credit original source)
    source_account = await db.get(Account, original.destination_account_id, with_for_update=True)
    dest_account = await db.get(Account, original.source_account_id, with_for_update=True)

    if source_account is None or dest_account is None:
        raise ValueError("Account not found during reversal.")

    check_sufficient_funds(source_account.available_balance, original.amount)

    # Debit
    source_before = source_account.available_balance
    source_account.available_balance -= original.amount
    source_account.ledger_balance -= original.amount
    source_account.version += 1

    await create_audit_entry(
        db=db,
        transaction_id=reversal_id,
        event_type=AuditEventType.DEBITED,
        actor_id=admin_user.id,
        transfer_initiator_id=admin_user.id,
        before_state={"source_available": source_before},
        after_state={"source_available": source_account.available_balance},
    )

    # Credit
    dest_before = dest_account.available_balance
    dest_account.available_balance += original.amount
    dest_account.ledger_balance += original.amount
    dest_account.version += 1

    await create_audit_entry(
        db=db,
        transaction_id=reversal_id,
        event_type=AuditEventType.CREDITED,
        actor_id=admin_user.id,
        transfer_initiator_id=admin_user.id,
        before_state={"dest_available": dest_before},
        after_state={"dest_available": dest_account.available_balance},
    )

    # Complete reversal
    reversal.status = TransferStatus.COMPLETED.value
    reversal.completed_at = datetime.now(timezone.utc)
    original.status = TransferStatus.REVERSED.value

    await create_audit_entry(
        db=db,
        transaction_id=reversal_id,
        event_type=AuditEventType.REVERSAL_COMPLETED,
        actor_id=admin_user.id,
        transfer_initiator_id=admin_user.id,
        before_state={"reversal_status": TransferStatus.INITIATED.value},
        after_state={
            "reversal_status": TransferStatus.COMPLETED.value,
            "original_status": TransferStatus.REVERSED.value,
        },
    )

    await db.flush()
    audit_count = len(reversal.audit_entries) if reversal.audit_entries else 0
    check_fail_closed_audit(reversal.status, audit_count)
    await db.commit()

    # KPI: FR-009 reversal metrics
    metrics.reversals_total.labels(result="completed").inc()
    metrics.reversal_audit_linkage.labels(linked="yes").inc()

    logger.info(
        "transfer_reversed",
        original_id=str(original.id),
        reversal_id=str(reversal_id),
    )

    return reversal
