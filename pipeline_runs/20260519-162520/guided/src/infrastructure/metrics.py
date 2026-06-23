"""
Prometheus metrics instrumentation for KPI measurement.

Each metric corresponds to a WAF-derived KPI target from the unified
compliance report (Section 6).
"""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram, Summary

from src.config import (
    METRIC_ANOMALY_DETECTION_MTTD_MINUTES_THRESHOLD,
    METRIC_ANOMALY_FALSE_POSITIVE_RATE_THRESHOLD,
    METRIC_AUDIT_LOG_ENTRY_CREATION_SUCCESS_RATE_THRESHOLD,
    METRIC_BALANCE_VALIDATION_ACCURACY_THRESHOLD,
    METRIC_IDENTIFIED_FAILURE_MODES_COUNT_THRESHOLD,
    METRIC_MFA_IMPLEMENTATION_AUDIT_RATE_THRESHOLD,
    METRIC_READ_AFTER_WRITE_CONSISTENCY_RATE_THRESHOLD,
    METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD,
    METRIC_TRANSFER_LIMIT_ENFORCEMENT_RATE_THRESHOLD,
    METRIC_TRANSFER_REVERSAL_AUDIT_LINKAGE_PERCENTAGE_THRESHOLD,
    METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD,
    METRIC_UNIQUE_TRANSACTION_REFERENCE_ID_COUNT_THRESHOLD,
)


# ---------------------------------------------------------------------------
# FR-001: Transfer transaction success rate (target: >= 99.99%)
# ---------------------------------------------------------------------------

transfer_attempts_total = Counter(
    "banking_transfer_attempts_total",
    "Total number of transfer attempts",
    ["status"],  # completed, failed
)

transfer_success_rate = Gauge(
    "banking_transfer_success_rate",
    "Current transfer success rate percentage",
)

transfer_latency = Histogram(
    "banking_transfer_latency_seconds",
    "Transfer processing latency in seconds",
    buckets=[0.05, 0.1, 0.25, 0.5, 1.0, 1.2, 2.0, 5.0],
)


# ---------------------------------------------------------------------------
# FR-002: Balance validation accuracy (target: >= 99%)
# ---------------------------------------------------------------------------

balance_validations_total = Counter(
    "banking_balance_validations_total",
    "Total balance validation checks",
    ["result"],  # passed, failed
)


# ---------------------------------------------------------------------------
# FR-003: Unique transaction reference ID count (target: >= 1)
# ---------------------------------------------------------------------------

transaction_ids_generated = Counter(
    "banking_transaction_ids_generated_total",
    "Total unique transaction reference IDs generated",
)


# ---------------------------------------------------------------------------
# FR-004: Audit log entry creation success rate (target: >= 95%)
# ---------------------------------------------------------------------------

audit_entries_total = Counter(
    "banking_audit_entries_total",
    "Total audit entry creation attempts",
    ["result"],  # success, failure
)

audit_entry_creation_latency = Histogram(
    "banking_audit_entry_creation_latency_seconds",
    "Audit entry creation latency",
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0],
)


# ---------------------------------------------------------------------------
# FR-005: Security alert MTTD (target: <= 15 minutes)
# ---------------------------------------------------------------------------

tamper_detection_latency = Summary(
    "banking_tamper_detection_latency_seconds",
    "Time to detect audit chain tampering",
)

hash_chain_verifications = Counter(
    "banking_hash_chain_verifications_total",
    "Total hash chain verification runs",
    ["result"],  # valid, tampered
)


# ---------------------------------------------------------------------------
# FR-006: Transfer limit enforcement rate (target: >= 99%)
# ---------------------------------------------------------------------------

daily_limit_checks_total = Counter(
    "banking_daily_limit_checks_total",
    "Total daily limit enforcement checks",
    ["result"],  # passed, blocked
)


# ---------------------------------------------------------------------------
# FR-007: Anomaly detection (target: MTTD <= 15 min, FP < 5%, MFA = 100%)
# ---------------------------------------------------------------------------

velocity_checks_total = Counter(
    "banking_velocity_checks_total",
    "Total velocity anomaly checks",
    ["result"],  # passed, step_up, blocked
)

step_up_challenges_total = Counter(
    "banking_step_up_challenges_total",
    "Total step-up authentication challenges",
    ["result"],  # issued, completed, expired
)

fraud_signals_total = Counter(
    "banking_fraud_signals_total",
    "Total fraud signals generated",
    ["action"],  # allow, step_up, block
)


# ---------------------------------------------------------------------------
# FR-008: Read-after-write consistency rate (target: >= 99%)
# ---------------------------------------------------------------------------

balance_reads_total = Counter(
    "banking_balance_reads_total",
    "Total balance inquiry reads",
    ["consistency"],  # consistent, stale
)


# ---------------------------------------------------------------------------
# FR-009: Transfer reversal audit linkage (target: >= 95%)
# ---------------------------------------------------------------------------

reversals_total = Counter(
    "banking_reversals_total",
    "Total transfer reversal attempts",
    ["result"],  # completed, failed
)

reversal_audit_linkage = Counter(
    "banking_reversal_audit_linkage_total",
    "Reversals with proper audit linkage to original",
    ["linked"],  # yes, no
)


# ---------------------------------------------------------------------------
# FR-010: Fail-closed audit (identified failure modes)
# ---------------------------------------------------------------------------

audit_unavailable_total = Counter(
    "banking_audit_unavailable_total",
    "Times audit logging was unavailable causing fail-closed",
)

fail_closed_events = Counter(
    "banking_fail_closed_events_total",
    "Transfers rejected due to audit unavailability",
)
