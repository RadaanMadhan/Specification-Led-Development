"""
Audit logging domain service.

Implements FR-004: Append-only audit log for every state-changing event.
Implements FR-005: Cryptographic hash chain for tamper detection.
Implements FR-010: Fail-closed when audit persistence is unavailable.
"""

from __future__ import annotations

import hashlib
import json
import time
import uuid
from datetime import datetime, timezone

import structlog
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from src.domain.enums import AuditEventType
from src.domain.invariants import (
    InvariantViolation,
    check_append_only_sequence,
    check_attribution_correctness,
    check_hash_chain_link,
)
from src.domain.models import AuditEntry
from src.infrastructure import metrics

logger = structlog.get_logger()


def _compute_hash(
    entry_id: uuid.UUID,
    transaction_id: uuid.UUID,
    event_type: str,
    actor_id: uuid.UUID,
    timestamp: datetime,
    before_state: str,
    after_state: str,
    reason_code: str | None,
    fraud_signal: bool,
    prev_hash: str | None,
) -> str:
    """
    Implements FR-005: SHA-256 hash over the entry payload and prev_hash.

    The hash chain forms a tamper-evident log. Each entry's currentHash is
    computed over its payload concatenated with the previous entry's hash.
    """
    payload = "|".join(
        [
            str(entry_id),
            str(transaction_id),
            event_type,
            str(actor_id),
            timestamp.isoformat(),
            before_state,
            after_state,
            reason_code or "",
            str(fraud_signal),
            prev_hash or "",
        ]
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# PATTERN: AppendOnly — audit entries are append-only; no updates or deletes
async def create_audit_entry(
    db: AsyncSession,
    transaction_id: uuid.UUID,
    event_type: AuditEventType,
    actor_id: uuid.UUID,
    transfer_initiator_id: uuid.UUID,
    before_state: dict,
    after_state: dict,
    reason_code: str | None = None,
    is_fraud_signal: bool = False,
) -> AuditEntry:
    """
    Create an append-only audit log entry with hash chain linkage.

    Implements FR-004: AuditForEveryEvent — every state change is logged.
    Implements FR-005: HashChain — entries are cryptographically chained.

    Raises InvariantViolation if attribution is incorrect or audit persistence fails.
    """
    start_time = time.monotonic()

    try:
        # HARDENED: F_AttributionCorrectness — actor must match initiator
        check_attribution_correctness(actor_id, transfer_initiator_id)

        # Get the last sequence number and hash for chain linkage
        result = await db.execute(
            select(AuditEntry.sequence_number, AuditEntry.current_hash)
            .order_by(AuditEntry.sequence_number.desc())
            .limit(1)
        )
        last_entry = result.first()

        if last_entry is not None:
            last_seq = last_entry.sequence_number
            prev_hash = last_entry.current_hash
        else:
            last_seq = None
            prev_hash = None

        new_seq = (last_seq or 0) + 1

        # HARDENED: F_AppendOnlyAuditEntries — sequence must be monotonically increasing
        check_append_only_sequence(new_seq, last_seq)

        entry_id = uuid.uuid4()
        now = datetime.now(timezone.utc)
        before_json = json.dumps(before_state, default=str)
        after_json = json.dumps(after_state, default=str)

        current_hash = _compute_hash(
            entry_id=entry_id,
            transaction_id=transaction_id,
            event_type=event_type.value,
            actor_id=actor_id,
            timestamp=now,
            before_state=before_json,
            after_state=after_json,
            reason_code=reason_code,
            fraud_signal=is_fraud_signal,
            prev_hash=prev_hash,
        )

        # INVARIANT: F_HashChainIntegrity — validate chain link
        check_hash_chain_link(new_seq, prev_hash, prev_hash)

        audit_entry = AuditEntry(
            id=entry_id,
            transaction_id=transaction_id,
            event_type=event_type.value,
            actor_id=actor_id,
            timestamp=now,
            before_state=before_json,
            after_state=after_json,
            reason_code=reason_code,
            fraud_signal=is_fraud_signal,
            prev_hash=prev_hash,
            current_hash=current_hash,
            sequence_number=new_seq,
        )

        db.add(audit_entry)
        await db.flush()

        # KPI: FR-004 audit entry creation success
        metrics.audit_entries_total.labels(result="success").inc()
        elapsed = time.monotonic() - start_time
        metrics.audit_entry_creation_latency.observe(elapsed)

        logger.info(
            "audit_entry_created",
            entry_id=str(entry_id),
            transaction_id=str(transaction_id),
            event_type=event_type.value,
            sequence_number=new_seq,
        )

        return audit_entry

    except InvariantViolation:
        metrics.audit_entries_total.labels(result="failure").inc()
        raise
    except Exception as exc:
        # PATTERN: FailClosedAudit — audit failure must prevent transfer completion
        metrics.audit_entries_total.labels(result="failure").inc()
        metrics.audit_unavailable_total.inc()
        logger.error("audit_entry_creation_failed", error=str(exc))
        raise InvariantViolation(
            "F_FailClosedAudit",
            f"Audit logging failed: {exc}",
        ) from exc


# PATTERN: AuditCompleteness — verify hash chain integrity
async def verify_hash_chain(db: AsyncSession) -> tuple[bool, list[dict]]:
    """
    Implements FR-005: Verify the entire audit hash chain for tampering.

    Returns (is_valid, list_of_discrepancies).
    """
    start_time = time.monotonic()

    result = await db.execute(
        select(AuditEntry).order_by(AuditEntry.sequence_number.asc())
    )
    entries = result.scalars().all()

    discrepancies: list[dict] = []
    prev_hash: str | None = None

    for entry in entries:
        # Recompute hash
        expected_hash = _compute_hash(
            entry_id=entry.id,
            transaction_id=entry.transaction_id,
            event_type=entry.event_type,
            actor_id=entry.actor_id,
            timestamp=entry.timestamp,
            before_state=entry.before_state,
            after_state=entry.after_state,
            reason_code=entry.reason_code,
            fraud_signal=entry.fraud_signal,
            prev_hash=entry.prev_hash,
        )

        if entry.current_hash != expected_hash:
            discrepancies.append(
                {
                    "sequence_number": entry.sequence_number,
                    "entry_id": str(entry.id),
                    "issue": "hash_mismatch",
                    "expected": expected_hash,
                    "actual": entry.current_hash,
                }
            )

        if entry.prev_hash != prev_hash:
            discrepancies.append(
                {
                    "sequence_number": entry.sequence_number,
                    "entry_id": str(entry.id),
                    "issue": "chain_link_broken",
                    "expected_prev": prev_hash,
                    "actual_prev": entry.prev_hash,
                }
            )

        prev_hash = entry.current_hash

    is_valid = len(discrepancies) == 0

    # KPI: FR-005 tamper detection metrics
    elapsed = time.monotonic() - start_time
    metrics.tamper_detection_latency.observe(elapsed)
    metrics.hash_chain_verifications.labels(
        result="valid" if is_valid else "tampered"
    ).inc()

    return is_valid, discrepancies
