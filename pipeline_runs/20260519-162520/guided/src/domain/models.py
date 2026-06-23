"""
SQLAlchemy ORM models for the banking transfer system.

Each model corresponds to an entity defined in data-model.md.
Database constraints enforce structural invariants from the Alloy specification.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _new_uuid() -> uuid.UUID:
    return uuid.uuid4()


# ---------------------------------------------------------------------------
# User
# ---------------------------------------------------------------------------

class User(Base):
    """Represents a banking customer or administrator."""

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_new_uuid)
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    full_name: Mapped[str] = mapped_column(String(255), nullable=False)
    roles: Mapped[list[str]] = mapped_column(ARRAY(String), nullable=False)
    authentication_status: Mapped[str] = mapped_column(
        Enum("AUTHENTICATED", "UNAUTHENTICATED", "LOCKED", name="authentication_status_enum"),
        nullable=False,
        default="UNAUTHENTICATED",
    )
    daily_transfer_total: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow, onupdate=_utcnow)

    # Relationships
    accounts: Mapped[list[Account]] = relationship("Account", back_populates="owner", lazy="selectin")

    __table_args__ = (
        CheckConstraint("daily_transfer_total >= 0", name="ck_user_daily_transfer_non_negative"),
        CheckConstraint("array_length(roles, 1) >= 1", name="ck_user_at_least_one_role"),
    )


# ---------------------------------------------------------------------------
# Account
# ---------------------------------------------------------------------------

class Account(Base):
    """
    Represents a bank account belonging to a single user.

    Balances are stored as integer minor units (cents) to eliminate
    floating-point precision errors.
    """

    __tablename__ = "accounts"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_new_uuid)
    owner_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    account_number: Mapped[str] = mapped_column(String(34), unique=True, nullable=False)
    # INVARIANT: F_ConservationOfValue — non-negative balances
    ledger_balance: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    available_balance: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    # INVARIANT: F_DailyLimitEnforcement — daily limit must be > 0
    daily_limit: Mapped[int] = mapped_column(Integer, nullable=False)
    account_status: Mapped[str] = mapped_column(
        Enum("ACTIVE", "FROZEN", "CLOSED", name="account_status_enum"),
        nullable=False,
        default="ACTIVE",
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow, onupdate=_utcnow)

    # Relationships
    owner: Mapped[User] = relationship("User", back_populates="accounts", lazy="joined")

    __table_args__ = (
        # INVARIANT: F_ConservationOfValue — non-negative balances
        CheckConstraint("ledger_balance >= 0", name="ck_account_ledger_non_negative"),
        CheckConstraint("available_balance >= 0", name="ck_account_available_non_negative"),
        # INVARIANT: F_ConservationOfValue — available <= ledger
        CheckConstraint("available_balance <= ledger_balance", name="ck_account_available_lte_ledger"),
        # INVARIANT: F_DailyLimitEnforcement — positive daily limit
        CheckConstraint("daily_limit > 0", name="ck_account_daily_limit_positive"),
        CheckConstraint("version >= 1", name="ck_account_version_positive"),
        Index("ix_account_owner_id", "owner_id"),
    )


# ---------------------------------------------------------------------------
# Transfer
# ---------------------------------------------------------------------------

class Transfer(Base):
    """
    Represents a fund movement between two accounts.

    Implements FR-003: Every transfer has a unique, immutable transaction reference ID (the primary key).
    """

    __tablename__ = "transfers"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_new_uuid)
    source_account_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("accounts.id"), nullable=False)
    destination_account_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("accounts.id"), nullable=False)
    # INVARIANT: F_ConservationOfValue — amount must be positive
    amount: Mapped[int] = mapped_column(Integer, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    status: Mapped[str] = mapped_column(
        Enum("INITIATED", "VALIDATED", "COMPLETED", "FAILED", "REVERSED", name="transfer_status_enum"),
        nullable=False,
        default="INITIATED",
    )
    failure_reason_code: Mapped[str | None] = mapped_column(
        Enum(
            "INSUFFICIENT_FUNDS", "DAILY_LIMIT_EXCEEDED", "SAME_ACCOUNT_TRANSFER",
            "CONCURRENT_MODIFICATION", "CREDIT_FAILED", "AUDIT_UNAVAILABLE",
            "EXTERNAL_TRANSFER_NOT_SUPPORTED", "VELOCITY_ALERT",
            "REVERSAL_WINDOW_EXPIRED", "ALREADY_REVERSED",
            name="failure_reason_code_enum",
        ),
        nullable=True,
    )
    original_transaction_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transfers.id"), nullable=True,
    )
    initiated_by: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Relationships
    source_account: Mapped[Account] = relationship("Account", foreign_keys=[source_account_id], lazy="joined")
    destination_account: Mapped[Account] = relationship("Account", foreign_keys=[destination_account_id], lazy="joined")
    initiator: Mapped[User] = relationship("User", foreign_keys=[initiated_by], lazy="joined")
    original_transaction: Mapped[Transfer | None] = relationship("Transfer", remote_side=[id], foreign_keys=[original_transaction_id], lazy="joined")
    audit_entries: Mapped[list[AuditEntry]] = relationship("AuditEntry", back_populates="transfer", lazy="selectin")
    fraud_signal: Mapped[FraudSignal | None] = relationship("FraudSignal", back_populates="transfer", uselist=False, lazy="joined")

    __table_args__ = (
        # INVARIANT: F_ConservationOfValue — amount must be positive
        CheckConstraint("amount > 0", name="ck_transfer_amount_positive"),
        # HARDENED: F_NoSelfTransfer — DB-level guard against self-transfer
        CheckConstraint("source_account_id != destination_account_id", name="ck_transfer_no_self_transfer"),
        Index("ix_transfer_source_account_id", "source_account_id"),
        Index("ix_transfer_destination_account_id", "destination_account_id"),
        Index("ix_transfer_initiated_by", "initiated_by"),
        Index("ix_transfer_original_transaction_id", "original_transaction_id"),
        Index("ix_transfer_status_created", "status", "created_at"),
        Index("ix_transfer_source_created", "source_account_id", "created_at"),
    )


# ---------------------------------------------------------------------------
# AuditEntry
# ---------------------------------------------------------------------------

class AuditEntry(Base):
    """
    An immutable, append-only record capturing a single lifecycle event.

    Implements FR-004: Audit log entry for every state-changing event.
    Implements FR-005: Cryptographic hash chain for tamper detection.
    """

    __tablename__ = "audit_entries"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_new_uuid)
    transaction_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("transfers.id"), nullable=False)
    event_type: Mapped[str] = mapped_column(
        Enum(
            "INITIATED", "VALIDATED", "DEBITED", "CREDITED", "COMPLETED",
            "REJECTED", "FAILED", "ROLLED_BACK", "REVERSAL_INITIATED",
            "REVERSAL_COMPLETED", "VELOCITY_ALERT", "STEP_UP_REQUESTED",
            "STEP_UP_COMPLETED", "FRAUD_SIGNAL",
            name="audit_event_type_enum",
        ),
        nullable=False,
    )
    actor_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow)
    before_state: Mapped[str] = mapped_column(Text, nullable=False)
    after_state: Mapped[str] = mapped_column(Text, nullable=False)
    reason_code: Mapped[str | None] = mapped_column(String(100), nullable=True)
    fraud_signal: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    prev_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    current_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    # INVARIANT: F_AppendOnlyAuditEntries — unique sequence number
    sequence_number: Mapped[int] = mapped_column(Integer, nullable=False)

    # Relationships
    transfer: Mapped[Transfer] = relationship("Transfer", back_populates="audit_entries", lazy="joined")

    __table_args__ = (
        # HARDENED: F_AppendOnlyAuditEntries — globally unique sequence number
        UniqueConstraint("sequence_number", name="uq_audit_entry_sequence_number"),
        Index("ix_audit_entry_transaction_id", "transaction_id"),
        Index("ix_audit_entry_actor_id", "actor_id"),
        Index("ix_audit_entry_event_type_timestamp", "event_type", "timestamp"),
        Index("ix_audit_entry_sequence_number", "sequence_number"),
        Index("ix_audit_entry_timestamp", "timestamp"),
    )


# ---------------------------------------------------------------------------
# FraudSignal
# ---------------------------------------------------------------------------

class FraudSignal(Base):
    """
    A generated risk indicator associated with a specific transfer attempt.
    """

    __tablename__ = "fraud_signals"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_new_uuid)
    transaction_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("transfers.id"), unique=True, nullable=False)
    account_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("accounts.id"), nullable=False)
    risk_score: Mapped[int] = mapped_column(Integer, nullable=False)
    trigger_rules: Mapped[list[str]] = mapped_column(ARRAY(String), nullable=False)
    action: Mapped[str] = mapped_column(
        Enum("ALLOW", "STEP_UP", "BLOCK", name="fraud_action_enum"),
        nullable=False,
    )
    step_up_completed: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_utcnow)

    # Relationships
    transfer: Mapped[Transfer] = relationship("Transfer", back_populates="fraud_signal", lazy="joined")

    __table_args__ = (
        # INVARIANT: F_FraudSignalConstraints — risk score range
        CheckConstraint("risk_score >= 0 AND risk_score <= 1000", name="ck_fraud_signal_risk_score_range"),
        Index("ix_fraud_signal_transaction_id", "transaction_id", unique=True),
        Index("ix_fraud_signal_account_created", "account_id", "created_at"),
    )
