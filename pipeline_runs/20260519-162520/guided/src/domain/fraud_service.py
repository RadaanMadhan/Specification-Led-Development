"""
Fraud detection domain service.

Implements FR-006: Configurable per-account daily transfer limits.
Implements FR-007: Transfer velocity anomaly detection and step-up auth.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import structlog
from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from src.config import settings
from src.domain.enums import (
    AuditEventType,
    FraudAction,
    FraudTriggerRule,
    TransferStatus,
)
from src.domain.invariants import check_daily_limit, check_fraud_signal_constraints
from src.domain.models import Account, FraudSignal, Transfer
from src.infrastructure import metrics

logger = structlog.get_logger()


async def get_daily_transfer_total(
    db: AsyncSession,
    account_id: uuid.UUID,
) -> int:
    """
    Compute the total amount transferred from this account today (UTC).

    Used by FR-006 daily limit enforcement.
    """
    today_start = datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0,
    )
    result = await db.execute(
        select(func.coalesce(func.sum(Transfer.amount), 0)).where(
            and_(
                Transfer.source_account_id == account_id,
                Transfer.status.in_([
                    TransferStatus.COMPLETED.value,
                    TransferStatus.INITIATED.value,
                    TransferStatus.VALIDATED.value,
                ]),
                Transfer.created_at >= today_start,
            )
        )
    )
    return result.scalar_one()


async def get_velocity_count(
    db: AsyncSession,
    account_id: uuid.UUID,
) -> int:
    """
    Count transfers from this account within the velocity detection window.

    Used by FR-007 velocity anomaly detection.
    """
    window_start = datetime.now(timezone.utc) - timedelta(
        minutes=settings.velocity_window_minutes,
    )
    result = await db.execute(
        select(func.count()).where(
            and_(
                Transfer.source_account_id == account_id,
                Transfer.created_at >= window_start,
            )
        )
    )
    return result.scalar_one()


async def evaluate_fraud_risk(
    db: AsyncSession,
    source_account: Account,
    amount: int,
    transfer_id: uuid.UUID,
) -> FraudSignal:
    """
    Evaluate fraud risk for a transfer and generate a FraudSignal.

    Implements FR-006: Daily limit enforcement.
    Implements FR-007: Velocity anomaly detection.

    Returns a FraudSignal indicating the action to take (ALLOW, STEP_UP, BLOCK).
    """
    trigger_rules: list[str] = []
    risk_score = 0

    # --- FR-006: Daily limit check ---
    daily_total = await get_daily_transfer_total(db, source_account.id)

    try:
        check_daily_limit(source_account.daily_limit, daily_total, amount)
        metrics.daily_limit_checks_total.labels(result="passed").inc()
    except Exception:
        trigger_rules.append(FraudTriggerRule.DAILY_LIMIT_PROXIMITY.value)
        risk_score += 400
        metrics.daily_limit_checks_total.labels(result="blocked").inc()

    # Check proximity to daily limit (within 90%)
    if daily_total + amount > source_account.daily_limit * 0.9:
        if FraudTriggerRule.DAILY_LIMIT_PROXIMITY.value not in trigger_rules:
            trigger_rules.append(FraudTriggerRule.DAILY_LIMIT_PROXIMITY.value)
            risk_score += 100

    # --- FR-007: Velocity check ---
    velocity_count = await get_velocity_count(db, source_account.id)

    if velocity_count >= settings.velocity_max_transfers:
        trigger_rules.append(FraudTriggerRule.VELOCITY.value)
        risk_score += 300
        metrics.velocity_checks_total.labels(result="step_up").inc()
    else:
        metrics.velocity_checks_total.labels(result="passed").inc()

    # --- Amount deviation check (simple z-score-like heuristic) ---
    # Compare to daily limit as a proxy for typical transfer size
    if amount > source_account.daily_limit * 0.5:
        trigger_rules.append(FraudTriggerRule.AMOUNT_DEVIATION.value)
        risk_score += 200

    # Determine action based on risk score
    if risk_score >= settings.fraud_block_threshold:
        action = FraudAction.BLOCK.value
        metrics.velocity_checks_total.labels(result="blocked").inc()
    elif risk_score >= settings.fraud_step_up_threshold:
        action = FraudAction.STEP_UP.value
    else:
        action = FraudAction.ALLOW.value

    # Clamp risk score to 0-1000
    risk_score = min(risk_score, 1000)

    # INVARIANT: F_FraudSignalConstraints
    step_up_completed = None
    if action == FraudAction.STEP_UP.value:
        step_up_completed = False  # Pending step-up

    check_fraud_signal_constraints(risk_score, action, trigger_rules, step_up_completed)

    fraud_signal = FraudSignal(
        id=uuid.uuid4(),
        transaction_id=transfer_id,
        account_id=source_account.id,
        risk_score=risk_score,
        trigger_rules=trigger_rules if trigger_rules else [FraudTriggerRule.VELOCITY.value],
        action=action,
        step_up_completed=step_up_completed,
    )

    db.add(fraud_signal)
    await db.flush()

    # KPI: FR-007 fraud signal metrics
    metrics.fraud_signals_total.labels(action=action.lower()).inc()

    logger.info(
        "fraud_risk_evaluated",
        transfer_id=str(transfer_id),
        risk_score=risk_score,
        action=action,
        trigger_rules=trigger_rules,
    )

    return fraud_signal
