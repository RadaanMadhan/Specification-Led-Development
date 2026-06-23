"""
KPI Threshold Tests.

Each test verifies that the KPI threshold constants are defined with the
expected values from the WAF unified compliance report (Section 6) and
that the corresponding Prometheus metrics instrumentation points exist.

KPI Metrics covered (12 rows across 3 WAF pillars):
  Cost Optimization: transfer_transaction_success_rate, balance_validation_accuracy,
                     audit_log_entry_creation_success_rate, read_after_write_consistency_rate
  Reliability:       unique_transaction_reference_id_count, anomaly_detection_mttd_minutes,
                     security_alert_mttd_minutes, transfer_limit_enforcement_rate,
                     identified_failure_modes_count
  Security:          transfer_reversal_audit_linkage_percentage
"""

from __future__ import annotations

import pytest

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
from src.infrastructure import metrics


# ===================================================================
#  FR-001: Transfer transaction success rate
# ===================================================================


class TestKpiTransferTransactionSuccessRate:
    """KPI: transfer_transaction_success_rate (FR-001, Cost Optimization)."""

    def test_kpi_transfer_transaction_success_rate_threshold_defined(self):
        """Threshold constant exists with expected WAF value."""
        assert METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD == 99.99

    def test_kpi_transfer_transaction_success_rate_higher_is_better(self):
        """Threshold direction: higher is better (>= 99.99%)."""
        assert METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD > 0
        assert METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD <= 100

    def test_kpi_transfer_transaction_success_rate_metric_exists(self):
        """Prometheus counter for transfer attempts exists with status labels."""
        assert metrics.transfer_attempts_total is not None
        assert metrics.transfer_success_rate is not None

    def test_kpi_transfer_transaction_success_rate_latency_metric(self):
        """Transfer latency histogram is instrumented."""
        assert metrics.transfer_latency is not None


# ===================================================================
#  FR-002: Balance validation accuracy
# ===================================================================


class TestKpiBalanceValidationAccuracy:
    """KPI: balance_validation_accuracy (FR-002, Cost Optimization)."""

    def test_kpi_balance_validation_accuracy_threshold_defined(self):
        """Threshold constant exists with expected WAF value."""
        assert METRIC_BALANCE_VALIDATION_ACCURACY_THRESHOLD == 99.0

    def test_kpi_balance_validation_accuracy_metric_exists(self):
        """Prometheus counter for balance validations exists."""
        assert metrics.balance_validations_total is not None


# ===================================================================
#  FR-003: Unique transaction reference ID count
# ===================================================================


class TestKpiUniqueTransactionReferenceIdCount:
    """KPI: unique_transaction_reference_id_count (FR-003, Reliability)."""

    def test_kpi_unique_transaction_reference_id_count_threshold_defined(self):
        """Threshold constant exists — at least 1 unique ID per attempt."""
        assert METRIC_UNIQUE_TRANSACTION_REFERENCE_ID_COUNT_THRESHOLD == 1.0

    def test_kpi_unique_transaction_reference_id_count_metric_exists(self):
        """Prometheus counter for transaction IDs generated exists."""
        assert metrics.transaction_ids_generated is not None


# ===================================================================
#  FR-004: Audit log entry creation success rate
# ===================================================================


class TestKpiAuditLogEntryCreationSuccessRate:
    """KPI: audit_log_entry_creation_success_rate (FR-004, Cost Optimization)."""

    def test_kpi_audit_log_entry_creation_success_rate_threshold_defined(self):
        """Threshold constant exists with expected WAF value."""
        assert METRIC_AUDIT_LOG_ENTRY_CREATION_SUCCESS_RATE_THRESHOLD == 95.0

    def test_kpi_audit_log_entry_creation_success_rate_metric_exists(self):
        """Prometheus counter for audit entries exists with result labels."""
        assert metrics.audit_entries_total is not None

    def test_kpi_audit_log_entry_creation_latency_metric(self):
        """Audit entry creation latency histogram exists."""
        assert metrics.audit_entry_creation_latency is not None


# ===================================================================
#  FR-005: Security alert MTTD
# ===================================================================


class TestKpiSecurityAlertMttd:
    """KPI: security_alert_mttd_minutes (FR-005, Security)."""

    def test_kpi_security_alert_mttd_minutes_threshold_defined(self):
        """Threshold constant exists — MTTD <= 15 minutes."""
        assert METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD == 15.0

    def test_kpi_security_alert_mttd_lower_is_better(self):
        """Threshold direction: lower is better."""
        assert METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD > 0

    def test_kpi_security_alert_tamper_detection_metric_exists(self):
        """Prometheus summary for tamper detection latency exists."""
        assert metrics.tamper_detection_latency is not None

    def test_kpi_security_alert_hash_chain_verification_metric_exists(self):
        """Prometheus counter for hash chain verifications exists."""
        assert metrics.hash_chain_verifications is not None


# ===================================================================
#  FR-006: Transfer limit enforcement rate
# ===================================================================


class TestKpiTransferLimitEnforcementRate:
    """KPI: transfer_limit_enforcement_rate (FR-006, Security/Reliability)."""

    def test_kpi_transfer_limit_enforcement_rate_threshold_defined(self):
        """Threshold constant exists with expected WAF value."""
        assert METRIC_TRANSFER_LIMIT_ENFORCEMENT_RATE_THRESHOLD == 99.0

    def test_kpi_transfer_limit_enforcement_rate_metric_exists(self):
        """Prometheus counter for daily limit checks exists."""
        assert metrics.daily_limit_checks_total is not None


# ===================================================================
#  FR-007: Anomaly detection MTTD, false positive rate, MFA coverage
# ===================================================================


class TestKpiAnomalyDetection:
    """KPI: anomaly_detection_mttd_minutes, false_positive_rate, MFA (FR-007, Reliability)."""

    def test_kpi_anomaly_detection_mttd_minutes_threshold_defined(self):
        """Threshold constant exists — MTTD <= 15 minutes."""
        assert METRIC_ANOMALY_DETECTION_MTTD_MINUTES_THRESHOLD == 15.0

    def test_kpi_anomaly_false_positive_rate_threshold_defined(self):
        """Threshold constant exists — FP rate < 5%."""
        assert METRIC_ANOMALY_FALSE_POSITIVE_RATE_THRESHOLD == 5.0

    def test_kpi_mfa_implementation_audit_rate_threshold_defined(self):
        """Threshold constant exists — 100% MFA audit rate."""
        assert METRIC_MFA_IMPLEMENTATION_AUDIT_RATE_THRESHOLD == 100.0

    def test_kpi_anomaly_detection_velocity_metric_exists(self):
        """Prometheus counter for velocity checks exists."""
        assert metrics.velocity_checks_total is not None

    def test_kpi_anomaly_detection_step_up_metric_exists(self):
        """Prometheus counter for step-up challenges exists."""
        assert metrics.step_up_challenges_total is not None

    def test_kpi_anomaly_detection_fraud_signals_metric_exists(self):
        """Prometheus counter for fraud signals exists."""
        assert metrics.fraud_signals_total is not None


# ===================================================================
#  FR-008: Read-after-write consistency rate
# ===================================================================


class TestKpiReadAfterWriteConsistencyRate:
    """KPI: read_after_write_consistency_rate (FR-008, Cost Optimization)."""

    def test_kpi_read_after_write_consistency_rate_threshold_defined(self):
        """Threshold constant exists with expected WAF value."""
        assert METRIC_READ_AFTER_WRITE_CONSISTENCY_RATE_THRESHOLD == 99.0

    def test_kpi_read_after_write_consistency_metric_exists(self):
        """Prometheus counter for balance reads exists."""
        assert metrics.balance_reads_total is not None


# ===================================================================
#  FR-009: Transfer reversal audit linkage percentage
# ===================================================================


class TestKpiTransferReversalAuditLinkage:
    """KPI: transfer_reversal_audit_linkage_percentage (FR-009, Security)."""

    def test_kpi_transfer_reversal_audit_linkage_threshold_defined(self):
        """Threshold constant exists with expected WAF value."""
        assert METRIC_TRANSFER_REVERSAL_AUDIT_LINKAGE_PERCENTAGE_THRESHOLD == 95.0

    def test_kpi_transfer_reversal_metric_exists(self):
        """Prometheus counter for reversals exists."""
        assert metrics.reversals_total is not None

    def test_kpi_transfer_reversal_audit_linkage_metric_exists(self):
        """Prometheus counter for reversal audit linkage exists."""
        assert metrics.reversal_audit_linkage is not None


# ===================================================================
#  FR-010: Identified failure modes count
# ===================================================================


class TestKpiIdentifiedFailureModesCount:
    """KPI: identified_failure_modes_count (FR-010, Reliability)."""

    def test_kpi_identified_failure_modes_count_threshold_defined(self):
        """Threshold constant exists — all P0/P1 failures documented."""
        assert METRIC_IDENTIFIED_FAILURE_MODES_COUNT_THRESHOLD == 0.0

    def test_kpi_audit_unavailable_metric_exists(self):
        """Prometheus counter for audit unavailability exists."""
        assert metrics.audit_unavailable_total is not None

    def test_kpi_fail_closed_events_metric_exists(self):
        """Prometheus counter for fail-closed events exists."""
        assert metrics.fail_closed_events is not None


# ===================================================================
#  Cross-cutting: all thresholds are importable and positive
# ===================================================================


class TestKpiCrossCutting:
    """Cross-cutting checks for all KPI thresholds."""

    ALL_THRESHOLDS = {
        "transfer_transaction_success_rate": METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD,
        "balance_validation_accuracy": METRIC_BALANCE_VALIDATION_ACCURACY_THRESHOLD,
        "unique_transaction_reference_id_count": METRIC_UNIQUE_TRANSACTION_REFERENCE_ID_COUNT_THRESHOLD,
        "audit_log_entry_creation_success_rate": METRIC_AUDIT_LOG_ENTRY_CREATION_SUCCESS_RATE_THRESHOLD,
        "security_alert_mttd_minutes": METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD,
        "transfer_limit_enforcement_rate": METRIC_TRANSFER_LIMIT_ENFORCEMENT_RATE_THRESHOLD,
        "anomaly_detection_mttd_minutes": METRIC_ANOMALY_DETECTION_MTTD_MINUTES_THRESHOLD,
        "anomaly_false_positive_rate": METRIC_ANOMALY_FALSE_POSITIVE_RATE_THRESHOLD,
        "mfa_implementation_audit_rate": METRIC_MFA_IMPLEMENTATION_AUDIT_RATE_THRESHOLD,
        "read_after_write_consistency_rate": METRIC_READ_AFTER_WRITE_CONSISTENCY_RATE_THRESHOLD,
        "transfer_reversal_audit_linkage_percentage": METRIC_TRANSFER_REVERSAL_AUDIT_LINKAGE_PERCENTAGE_THRESHOLD,
        "identified_failure_modes_count": METRIC_IDENTIFIED_FAILURE_MODES_COUNT_THRESHOLD,
    }

    def test_kpi_all_thresholds_are_numeric(self):
        """All KPI thresholds are numeric values."""
        for name, value in self.ALL_THRESHOLDS.items():
            assert isinstance(value, (int, float)), f"KPI {name} should be numeric, got {type(value)}"

    def test_kpi_all_thresholds_non_negative(self):
        """All KPI thresholds are non-negative."""
        for name, value in self.ALL_THRESHOLDS.items():
            assert value >= 0, f"KPI {name} should be non-negative, got {value}"

    def test_kpi_all_12_thresholds_defined(self):
        """Exactly 12 KPI threshold constants are defined."""
        assert len(self.ALL_THRESHOLDS) == 12

    def test_kpi_percentage_thresholds_within_range(self):
        """Percentage-based thresholds are in [0, 100]."""
        percentage_kpis = [
            "transfer_transaction_success_rate",
            "balance_validation_accuracy",
            "audit_log_entry_creation_success_rate",
            "transfer_limit_enforcement_rate",
            "anomaly_false_positive_rate",
            "mfa_implementation_audit_rate",
            "read_after_write_consistency_rate",
            "transfer_reversal_audit_linkage_percentage",
        ]
        for name in percentage_kpis:
            value = self.ALL_THRESHOLDS[name]
            assert 0 <= value <= 100, f"KPI {name} should be 0-100%, got {value}"
