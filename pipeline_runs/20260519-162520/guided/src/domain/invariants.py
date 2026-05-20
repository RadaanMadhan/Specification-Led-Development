"""
Runtime invariant checks translated from Alloy-verified structural constraints.

Every named fact from the Alloy specification is implemented here as a
validation function that raises on violation.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import TYPE_CHECKING

from src.domain.enums import (
    AccountStatus,
    AuthenticationStatus,
    FailureReasonCode,
    FraudAction,
    Role,
    TransferStatus,
)

if TYPE_CHECKING:
    from src.domain.models import Account, AuditEntry, FraudSignal, Transfer, User


class InvariantViolation(Exception):
    """Raised when a formally verified structural invariant is violated at runtime."""

    def __init__(self, fact_name: str, message: str) -> None:
        self.fact_name = fact_name
        super().__init__(f"Invariant [{fact_name}]: {message}")


# ---------------------------------------------------------------------------
# F_NoSelfTransfer
# HARDENED: F_NoSelfTransfer — explicit runtime guard against self-transfer
# ---------------------------------------------------------------------------

def check_no_self_transfer(source_account_id: uuid.UUID, destination_account_id: uuid.UUID) -> None:
    """Implements FR-001 (edge case): source and destination must differ."""
    if source_account_id == destination_account_id:
        raise InvariantViolation(
            "F_NoSelfTransfer",
            "Self-transfer is not permitted: source and destination accounts must differ.",
        )


# ---------------------------------------------------------------------------
# F_AuthRequiredEverywhere
# HARDENED: F_AuthRequiredEverywhere — reject unauthenticated users
# ---------------------------------------------------------------------------

def check_auth_required(user: User) -> None:
    """
    Implements FR-010: Only authenticated users may initiate transfers or
    appear as actors in audit entries.
    """
    if user.authentication_status != AuthenticationStatus.AUTHENTICATED.value:
        raise InvariantViolation(
            "F_AuthRequiredEverywhere",
            f"User {user.id} is not authenticated (status={user.authentication_status}).",
        )


# ---------------------------------------------------------------------------
# F_ConservationOfValue
# ---------------------------------------------------------------------------

def check_conservation_of_value(amount: int, source_balance: int, dest_balance: int) -> None:
    """
    Implements FR-001: Transfer amount must be positive, balances non-negative.
    """
    if amount <= 0:
        raise InvariantViolation("F_ConservationOfValue", "Transfer amount must be positive.")
    if source_balance < 0:
        raise InvariantViolation("F_ConservationOfValue", "Source balance must be non-negative.")
    if dest_balance < 0:
        raise InvariantViolation("F_ConservationOfValue", "Destination balance must be non-negative.")


def check_available_lte_ledger(available: int, ledger: int) -> None:
    """Implements FR-008: available balance must not exceed ledger balance."""
    if available > ledger:
        raise InvariantViolation(
            "F_ConservationOfValue",
            f"Available balance ({available}) exceeds ledger balance ({ledger}).",
        )


# ---------------------------------------------------------------------------
# F_SufficientFunds
# ---------------------------------------------------------------------------

def check_sufficient_funds(available_balance: int, amount: int) -> None:
    """Implements FR-002: Source must have sufficient available balance."""
    if available_balance < amount:
        raise InvariantViolation(
            "F_SufficientFunds",
            f"Insufficient funds: available={available_balance}, requested={amount}.",
        )


# ---------------------------------------------------------------------------
# F_ActiveAccountsOnly
# ---------------------------------------------------------------------------

def check_active_accounts(source_status: str, dest_status: str) -> None:
    """Only active accounts may participate in transfers."""
    if source_status != AccountStatus.ACTIVE.value:
        raise InvariantViolation(
            "F_ActiveAccountsOnly",
            f"Source account is not active (status={source_status}).",
        )
    if dest_status != AccountStatus.ACTIVE.value:
        raise InvariantViolation(
            "F_ActiveAccountsOnly",
            f"Destination account is not active (status={dest_status}).",
        )


# ---------------------------------------------------------------------------
# F_DailyLimitEnforcement
# ---------------------------------------------------------------------------

def check_daily_limit(daily_limit: int, current_daily_total: int, amount: int) -> None:
    """Implements FR-006: Enforce per-account daily transfer limits."""
    if daily_limit <= 0:
        raise InvariantViolation("F_DailyLimitEnforcement", "Daily limit must be positive.")
    if current_daily_total + amount > daily_limit:
        raise InvariantViolation(
            "F_DailyLimitEnforcement",
            f"Transfer would exceed daily limit: current_total={current_daily_total}, "
            f"amount={amount}, limit={daily_limit}.",
        )


# ---------------------------------------------------------------------------
# F_OwnershipBasedAccess
# HARDENED: F_OwnershipBasedAccess — customers can only transfer from own accounts
# ---------------------------------------------------------------------------

def check_ownership_based_access(
    user: User,
    source_account_owner_id: uuid.UUID,
) -> None:
    """Customers may only initiate transfers from accounts they own."""
    if Role.CUSTOMER.value in user.roles and user.id != source_account_owner_id:
        raise InvariantViolation(
            "F_OwnershipBasedAccess",
            f"User {user.id} does not own source account (owner={source_account_owner_id}).",
        )


# ---------------------------------------------------------------------------
# F_AttributionCorrectness
# HARDENED: F_AttributionCorrectness — audit actor must match transfer initiator
# ---------------------------------------------------------------------------

def check_attribution_correctness(
    audit_actor_id: uuid.UUID,
    transfer_initiator_id: uuid.UUID,
) -> None:
    """Audit entry actor must match the transfer initiator."""
    if audit_actor_id != transfer_initiator_id:
        raise InvariantViolation(
            "F_AttributionCorrectness",
            f"Audit actor {audit_actor_id} does not match transfer initiator {transfer_initiator_id}.",
        )


# ---------------------------------------------------------------------------
# F_AuditCompleteness
# HARDENED: F_AuditCompleteness — every transfer must have audit entries
# ---------------------------------------------------------------------------

def check_audit_completeness(transfer_id: uuid.UUID, audit_entry_count: int) -> None:
    """Implements FR-004: Every transfer must have at least one audit entry."""
    if audit_entry_count < 1:
        raise InvariantViolation(
            "F_AuditCompleteness",
            f"Transfer {transfer_id} has no audit entries.",
        )


# ---------------------------------------------------------------------------
# F_AppendOnlyAuditEntries
# HARDENED: F_AppendOnlyAuditEntries — unique sequence numbers
# ---------------------------------------------------------------------------

def check_append_only_sequence(new_seq: int, last_seq: int | None) -> None:
    """No two audit entries may share the same sequence number."""
    if last_seq is not None and new_seq <= last_seq:
        raise InvariantViolation(
            "F_AppendOnlyAuditEntries",
            f"New sequence {new_seq} is not greater than last sequence {last_seq}.",
        )


# ---------------------------------------------------------------------------
# F_HashChainIntegrity
# ---------------------------------------------------------------------------

def check_hash_chain_link(
    sequence_number: int,
    prev_hash: str | None,
    expected_prev_hash: str | None,
) -> None:
    """Implements FR-005: Cryptographic hash chain integrity."""
    if sequence_number == 1:
        if prev_hash is not None:
            raise InvariantViolation(
                "F_HashChainIntegrity",
                "First audit entry must have null prevHash.",
            )
    else:
        if prev_hash is None:
            raise InvariantViolation(
                "F_HashChainIntegrity",
                f"Non-first audit entry (seq={sequence_number}) must have a prevHash.",
            )
        if prev_hash != expected_prev_hash:
            raise InvariantViolation(
                "F_HashChainIntegrity",
                f"prevHash mismatch at seq={sequence_number}.",
            )


# ---------------------------------------------------------------------------
# F_FailClosedAudit
# ---------------------------------------------------------------------------

def check_fail_closed_audit(transfer_status: str, audit_entry_count: int) -> None:
    """
    Implements FR-010: No completed transfer may exist without at least one
    audit entry. The system must fail-closed when audit logging is unavailable.
    """
    if transfer_status == TransferStatus.COMPLETED.value and audit_entry_count < 1:
        raise InvariantViolation(
            "F_FailClosedAudit",
            "A completed transfer must have at least one audit entry.",
        )


# ---------------------------------------------------------------------------
# F_ReversalCompensating
# ---------------------------------------------------------------------------

def check_reversal_compensating(
    reversal_source_id: uuid.UUID,
    reversal_dest_id: uuid.UUID,
    reversal_amount: int,
    original_source_id: uuid.UUID,
    original_dest_id: uuid.UUID,
    original_amount: int,
    original_status: str,
) -> None:
    """Implements FR-009: Reversal must swap source/dest and match amount."""
    if reversal_source_id != original_dest_id:
        raise InvariantViolation(
            "F_ReversalCompensating",
            "Reversal source must equal original destination.",
        )
    if reversal_dest_id != original_source_id:
        raise InvariantViolation(
            "F_ReversalCompensating",
            "Reversal destination must equal original source.",
        )
    if reversal_amount != original_amount:
        raise InvariantViolation(
            "F_ReversalCompensating",
            "Reversal amount must equal original amount.",
        )
    if original_status not in (TransferStatus.COMPLETED.value, TransferStatus.REVERSED.value):
        raise InvariantViolation(
            "F_ReversalCompensating",
            f"Original transfer must be COMPLETED or REVERSED, got {original_status}.",
        )


# ---------------------------------------------------------------------------
# F_OwnershipExclusivity
# ---------------------------------------------------------------------------

def check_ownership_exclusivity(account_owner_id: uuid.UUID) -> None:
    """Each account must have exactly one owner (enforced by FK + NOT NULL)."""
    if account_owner_id is None:
        raise InvariantViolation(
            "F_OwnershipExclusivity",
            "Account must have an owner.",
        )


# ---------------------------------------------------------------------------
# F_FraudSignalConstraints
# ---------------------------------------------------------------------------

def check_fraud_signal_constraints(
    risk_score: int,
    action: str,
    trigger_rules: list[str],
    step_up_completed: bool | None,
) -> None:
    """Validate fraud signal structural constraints."""
    if risk_score < 0 or risk_score > 1000:
        raise InvariantViolation(
            "F_FraudSignalConstraints",
            f"Risk score must be 0-1000, got {risk_score}.",
        )
    if action in (FraudAction.STEP_UP.value, FraudAction.BLOCK.value) and not trigger_rules:
        raise InvariantViolation(
            "F_FraudSignalConstraints",
            f"Trigger rules required when action is {action}.",
        )
    if action != FraudAction.STEP_UP.value and step_up_completed is not None:
        raise InvariantViolation(
            "F_FraudSignalConstraints",
            "step_up_completed must be null when action is not STEP_UP.",
        )
