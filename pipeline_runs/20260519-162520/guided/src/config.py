"""
Application configuration and KPI threshold constants.

All KPI thresholds are derived from the Azure Well-Architected Framework (WAF)
unified compliance report, Section 6.
"""

from __future__ import annotations

from pydantic_settings import BaseSettings


# ---------------------------------------------------------------------------
# KPI Threshold Constants (WAF-derived, Section 6)
# ---------------------------------------------------------------------------

# FR-001 — Atomic transfer success rate (Pillar: Cost Optimization)
METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD = 99.99  # percentage, higher is better

# FR-002 — Balance validation accuracy (Pillar: Cost Optimization)
METRIC_BALANCE_VALIDATION_ACCURACY_THRESHOLD = 99.0  # percentage, higher is better

# FR-003 — Unique transaction reference ID count (Pillar: Reliability)
METRIC_UNIQUE_TRANSACTION_REFERENCE_ID_COUNT_THRESHOLD = 1.0  # count, higher is better

# FR-004 — Audit log entry creation success rate (Pillar: Cost Optimization)
METRIC_AUDIT_LOG_ENTRY_CREATION_SUCCESS_RATE_THRESHOLD = 95.0  # percentage, higher is better

# FR-005 — Security alert mean-time-to-detect (Pillar: Security)
METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD = 15.0  # minutes, lower is better

# FR-006 — Transfer limit enforcement rate (Pillar: Security)
METRIC_TRANSFER_LIMIT_ENFORCEMENT_RATE_THRESHOLD = 99.0  # percentage, higher is better

# FR-007 — Anomaly detection MTTD (Pillar: Reliability)
METRIC_ANOMALY_DETECTION_MTTD_MINUTES_THRESHOLD = 15.0  # minutes, lower is better
METRIC_ANOMALY_FALSE_POSITIVE_RATE_THRESHOLD = 5.0  # percentage, lower is better
METRIC_MFA_IMPLEMENTATION_AUDIT_RATE_THRESHOLD = 100.0  # percentage, higher is better

# FR-008 — Read-after-write consistency rate (Pillar: Cost Optimization)
METRIC_READ_AFTER_WRITE_CONSISTENCY_RATE_THRESHOLD = 99.0  # percentage, higher is better

# FR-009 — Transfer reversal audit linkage (Pillar: Security)
METRIC_TRANSFER_REVERSAL_AUDIT_LINKAGE_PERCENTAGE_THRESHOLD = 95.0  # percentage, higher is better

# FR-010 — Identified failure modes count (Pillar: Reliability)
METRIC_IDENTIFIED_FAILURE_MODES_COUNT_THRESHOLD = 0.0  # all P0/P1 failures documented


# ---------------------------------------------------------------------------
# Application Settings
# ---------------------------------------------------------------------------

class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # Database
    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/banking"
    database_echo: bool = False

    # Auth / IdP
    jwt_secret_key: str = "CHANGE-ME-IN-PRODUCTION"
    jwt_algorithm: str = "HS256"
    jwt_issuer: str = "banking-idp"

    # Transfer configuration
    default_daily_limit_cents: int = 1_000_000_00  # $1,000,000 in cents
    reversal_window_days: int = 30
    default_currency: str = "USD"

    # Fraud / velocity detection
    velocity_window_minutes: int = 10
    velocity_max_transfers: int = 3
    fraud_step_up_threshold: int = 500   # risk score 0-1000
    fraud_block_threshold: int = 800     # risk score 0-1000

    # Server
    host: str = "0.0.0.0"
    port: int = 8000

    model_config = {"env_prefix": "BANKING_"}


settings = Settings()
