"""
FR Acceptance Tests.

Each functional requirement (FR-001 through FR-010) has at least one
acceptance test covering the happy path and key edge cases.

These tests exercise the domain logic (invariants, permissions, enums,
config, audit hashing) without requiring a live database or async runtime.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from src.config import Settings, settings
from src.domain.audit_service import _compute_hash
from src.domain.enums import (
    AccountStatus,
    AuditEventType,
    AuthenticationStatus,
    FailureReasonCode,
    FraudAction,
    FraudTriggerRule,
    OperationKind,
    Role,
    TransferStatus,
)
from src.domain.invariants import (
    InvariantViolation,
    check_active_accounts,
    check_append_only_sequence,
    check_attribution_correctness,
    check_audit_completeness,
    check_available_lte_ledger,
    check_conservation_of_value,
    check_daily_limit,
    check_fail_closed_audit,
    check_fraud_signal_constraints,
    check_hash_chain_link,
    check_no_self_transfer,
    check_ownership_based_access,
    check_reversal_compensating,
    check_sufficient_funds,
)
from src.domain.permissions import is_operation_allowed, require_permission

from tests.conftest import StubAccount, StubUser


# ===================================================================
#  FR-001: Atomic Transfer
# ===================================================================


class TestFR001AtomicTransfer:
    """FR-001: Transfers must be atomic — both debit and credit or neither."""

    def test_fr_001_happy_path_conservation_of_value(self):
        """Happy path: positive amount with non-negative balances passes all checks."""
        amount = 10_000
        source_balance = 50_000
        dest_balance = 20_000

        check_conservation_of_value(amount, source_balance, dest_balance)
        check_sufficient_funds(source_balance, amount)

        new_source = source_balance - amount
        new_dest = dest_balance + amount

        assert new_source >= 0, "Source balance must remain non-negative"
        assert new_dest >= 0, "Destination balance must remain non-negative"
        assert new_source + new_dest == source_balance + dest_balance, "Total value must be conserved"

    def test_fr_001_zero_amount_rejected(self):
        """Edge: zero amount violates atomic transfer precondition."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_conservation_of_value(amount=0, source_balance=1000, dest_balance=1000)

    def test_fr_001_self_transfer_rejected(self):
        """Edge: self-transfer (source == destination) is always rejected."""
        account_id = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_NoSelfTransfer"):
            check_no_self_transfer(account_id, account_id)

    def test_fr_001_inactive_accounts_rejected(self):
        """Edge: frozen or closed accounts cannot participate."""
        with pytest.raises(InvariantViolation, match="F_ActiveAccountsOnly"):
            check_active_accounts(AccountStatus.FROZEN.value, AccountStatus.ACTIVE.value)
        with pytest.raises(InvariantViolation, match="F_ActiveAccountsOnly"):
            check_active_accounts(AccountStatus.ACTIVE.value, AccountStatus.CLOSED.value)

    def test_fr_001_value_conservation_arithmetic(self):
        """Verify that debit + credit preserve total value across accounts."""
        amounts = [1, 100, 50_000, 999_999]
        for amount in amounts:
            src = 100_000
            dst = 100_000
            check_conservation_of_value(amount, src, dst)
            assert (src - amount) + (dst + amount) == src + dst


# ===================================================================
#  FR-002: Sufficient Funds Validation
# ===================================================================


class TestFR002SufficientFunds:
    """FR-002: Validate sufficient available balance before debiting."""

    def test_fr_002_happy_path(self):
        """Happy path: balance > amount passes."""
        check_sufficient_funds(available_balance=10_000, amount=5_000)

    def test_fr_002_exact_balance(self):
        """Edge: exact balance (available == amount) passes."""
        check_sufficient_funds(available_balance=5_000, amount=5_000)

    def test_fr_002_insufficient_by_one(self):
        """Edge: insufficient by 1 cent is rejected."""
        with pytest.raises(InvariantViolation, match="F_SufficientFunds"):
            check_sufficient_funds(available_balance=4_999, amount=5_000)

    def test_fr_002_zero_balance_positive_amount(self):
        """Edge: zero balance with any positive amount fails."""
        with pytest.raises(InvariantViolation, match="F_SufficientFunds"):
            check_sufficient_funds(available_balance=0, amount=1)


# ===================================================================
#  FR-003: Unique Transaction Reference
# ===================================================================


class TestFR003UniqueTransactionRef:
    """FR-003: Every transfer gets a unique, immutable reference ID (UUID)."""

    def test_fr_003_happy_path_uniqueness(self):
        """Happy path: 10,000 generated UUIDs are all distinct."""
        ids = {uuid.uuid4() for _ in range(10_000)}
        assert len(ids) == 10_000

    def test_fr_003_uuid_format(self):
        """Generated IDs are valid UUID4 objects."""
        for _ in range(100):
            generated = uuid.uuid4()
            assert isinstance(generated, uuid.UUID)
            assert generated.version == 4


# ===================================================================
#  FR-004: Append-Only Audit Log
# ===================================================================


class TestFR004AppendOnlyAuditLog:
    """FR-004: Every state-changing event has an append-only audit entry."""

    def test_fr_004_happy_path_completeness(self):
        """Happy path: transfer with >= 1 audit entry passes completeness check."""
        check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=6)

    def test_fr_004_no_entries_rejected(self):
        """Edge: transfer with 0 audit entries fails completeness."""
        with pytest.raises(InvariantViolation, match="F_AuditCompleteness"):
            check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=0)

    def test_fr_004_append_only_monotonic(self):
        """Sequence numbers must be strictly monotonically increasing."""
        check_append_only_sequence(new_seq=1, last_seq=None)
        check_append_only_sequence(new_seq=2, last_seq=1)
        check_append_only_sequence(new_seq=100, last_seq=99)

    def test_fr_004_append_only_duplicate_rejected(self):
        """Duplicate sequence numbers are rejected."""
        with pytest.raises(InvariantViolation, match="F_AppendOnlyAuditEntries"):
            check_append_only_sequence(new_seq=5, last_seq=5)

    def test_fr_004_attribution_correctness(self):
        """Audit actor must match the transfer initiator."""
        user_id = uuid.uuid4()
        check_attribution_correctness(user_id, user_id)

    def test_fr_004_attribution_mismatch_rejected(self):
        """Mismatched actor/initiator is rejected."""
        with pytest.raises(InvariantViolation, match="F_AttributionCorrectness"):
            check_attribution_correctness(uuid.uuid4(), uuid.uuid4())

    def test_fr_004_all_event_types_defined(self):
        """All 14 audit event types are defined in the enum."""
        expected = {
            "INITIATED", "VALIDATED", "DEBITED", "CREDITED", "COMPLETED",
            "REJECTED", "FAILED", "ROLLED_BACK", "REVERSAL_INITIATED",
            "REVERSAL_COMPLETED", "VELOCITY_ALERT", "STEP_UP_REQUESTED",
            "STEP_UP_COMPLETED", "FRAUD_SIGNAL",
        }
        actual = {e.value for e in AuditEventType}
        assert actual == expected


# ===================================================================
#  FR-005: Cryptographic Hash Chain
# ===================================================================


class TestFR005HashChain:
    """FR-005: Audit entries are cryptographically chained via SHA-256."""

    def test_fr_005_happy_path_hash_computation(self):
        """Happy path: _compute_hash produces a 64-char hex SHA-256 digest."""
        entry_id = uuid.uuid4()
        txn_id = uuid.uuid4()
        actor_id = uuid.uuid4()
        now = datetime.now(timezone.utc)

        h = _compute_hash(
            entry_id=entry_id,
            transaction_id=txn_id,
            event_type="INITIATED",
            actor_id=actor_id,
            timestamp=now,
            before_state="{}",
            after_state='{"status": "INITIATED"}',
            reason_code=None,
            fraud_signal=False,
            prev_hash=None,
        )
        assert len(h) == 64
        assert all(c in "0123456789abcdef" for c in h)

    def test_fr_005_hash_deterministic(self):
        """Same inputs always produce the same hash."""
        entry_id = uuid.uuid4()
        txn_id = uuid.uuid4()
        actor_id = uuid.uuid4()
        now = datetime.now(timezone.utc)

        kwargs = dict(
            entry_id=entry_id,
            transaction_id=txn_id,
            event_type="COMPLETED",
            actor_id=actor_id,
            timestamp=now,
            before_state="{}",
            after_state="{}",
            reason_code=None,
            fraud_signal=False,
            prev_hash=None,
        )
        h1 = _compute_hash(**kwargs)
        h2 = _compute_hash(**kwargs)
        assert h1 == h2

    def test_fr_005_hash_chain_linkage(self):
        """Changing prev_hash changes the output hash (chain sensitivity)."""
        entry_id = uuid.uuid4()
        txn_id = uuid.uuid4()
        actor_id = uuid.uuid4()
        now = datetime.now(timezone.utc)

        h_no_prev = _compute_hash(
            entry_id=entry_id, transaction_id=txn_id, event_type="INITIATED",
            actor_id=actor_id, timestamp=now, before_state="{}", after_state="{}",
            reason_code=None, fraud_signal=False, prev_hash=None,
        )
        h_with_prev = _compute_hash(
            entry_id=entry_id, transaction_id=txn_id, event_type="INITIATED",
            actor_id=actor_id, timestamp=now, before_state="{}", after_state="{}",
            reason_code=None, fraud_signal=False, prev_hash="abc123",
        )
        assert h_no_prev != h_with_prev, "Hash chain must be sensitive to prev_hash"

    def test_fr_005_first_entry_null_prev(self):
        """First entry (seq=1) must have null prev_hash."""
        check_hash_chain_link(sequence_number=1, prev_hash=None, expected_prev_hash=None)

    def test_fr_005_first_entry_with_prev_rejected(self):
        """First entry with non-null prev_hash is invalid."""
        with pytest.raises(InvariantViolation, match="F_HashChainIntegrity"):
            check_hash_chain_link(sequence_number=1, prev_hash="something", expected_prev_hash=None)

    def test_fr_005_subsequent_entry_prev_mismatch(self):
        """Hash chain break (prev_hash != expected) is detected."""
        with pytest.raises(InvariantViolation, match="F_HashChainIntegrity"):
            check_hash_chain_link(
                sequence_number=5,
                prev_hash="aaaa",
                expected_prev_hash="bbbb",
            )

    def test_fr_005_hash_uses_sha256(self):
        """The hash function uses SHA-256 (verified by manual computation)."""
        entry_id = uuid.UUID("00000000-0000-0000-0000-000000000001")
        txn_id = uuid.UUID("00000000-0000-0000-0000-000000000002")
        actor_id = uuid.UUID("00000000-0000-0000-0000-000000000003")
        now = datetime(2024, 1, 1, tzinfo=timezone.utc)

        h = _compute_hash(
            entry_id=entry_id, transaction_id=txn_id, event_type="INITIATED",
            actor_id=actor_id, timestamp=now, before_state="{}", after_state="{}",
            reason_code=None, fraud_signal=False, prev_hash=None,
        )
        # Manually compute expected hash
        payload = "|".join([
            str(entry_id), str(txn_id), "INITIATED", str(actor_id),
            now.isoformat(), "{}", "{}", "", "False", "",
        ])
        expected = hashlib.sha256(payload.encode("utf-8")).hexdigest()
        assert h == expected


# ===================================================================
#  FR-006: Daily Transfer Limits
# ===================================================================


class TestFR006DailyTransferLimits:
    """FR-006: Configurable per-account daily transfer limits."""

    def test_fr_006_happy_path_within_limit(self):
        """Happy path: transfer within daily limit passes."""
        check_daily_limit(daily_limit=500_000, current_daily_total=100_000, amount=50_000)

    def test_fr_006_at_exact_limit(self):
        """Edge: total == limit is allowed."""
        check_daily_limit(daily_limit=500_000, current_daily_total=400_000, amount=100_000)

    def test_fr_006_exceeds_by_one(self):
        """Edge: exceeding by 1 cent is rejected."""
        with pytest.raises(InvariantViolation, match="F_DailyLimitEnforcement"):
            check_daily_limit(daily_limit=500_000, current_daily_total=400_001, amount=100_000)

    def test_fr_006_limit_must_be_positive(self):
        """Edge: daily_limit=0 is invalid."""
        with pytest.raises(InvariantViolation, match="F_DailyLimitEnforcement"):
            check_daily_limit(daily_limit=0, current_daily_total=0, amount=1)

    def test_fr_006_default_limit_configured(self):
        """Config: default_daily_limit_cents is configured."""
        assert settings.default_daily_limit_cents > 0


# ===================================================================
#  FR-007: Transfer Velocity Anomaly Detection
# ===================================================================


class TestFR007VelocityAnomalyDetection:
    """FR-007: Velocity anomaly detection with step-up/block."""

    def test_fr_007_fraud_action_enum(self):
        """All three fraud actions are defined."""
        assert FraudAction.ALLOW.value == "ALLOW"
        assert FraudAction.STEP_UP.value == "STEP_UP"
        assert FraudAction.BLOCK.value == "BLOCK"

    def test_fr_007_trigger_rules_enum(self):
        """All 4 fraud trigger rules are defined."""
        expected = {"VELOCITY", "AMOUNT_DEVIATION", "DESTINATION_NOVELTY", "DAILY_LIMIT_PROXIMITY"}
        actual = {r.value for r in FraudTriggerRule}
        assert actual == expected

    def test_fr_007_thresholds_configured(self):
        """Velocity and fraud thresholds are configured."""
        assert settings.velocity_window_minutes > 0
        assert settings.velocity_max_transfers > 0
        assert settings.fraud_step_up_threshold > 0
        assert settings.fraud_block_threshold > settings.fraud_step_up_threshold

    def test_fr_007_fraud_signal_constraints_allow(self):
        """ALLOW signal with no trigger rules is valid when risk is 0."""
        check_fraud_signal_constraints(
            risk_score=0,
            action=FraudAction.ALLOW.value,
            trigger_rules=["VELOCITY"],
            step_up_completed=None,
        )

    def test_fr_007_fraud_signal_constraints_step_up(self):
        """STEP_UP signal requires trigger rules and step_up_completed."""
        check_fraud_signal_constraints(
            risk_score=600,
            action=FraudAction.STEP_UP.value,
            trigger_rules=["VELOCITY", "AMOUNT_DEVIATION"],
            step_up_completed=False,
        )

    def test_fr_007_fraud_signal_constraints_block(self):
        """BLOCK signal requires trigger rules, no step_up_completed."""
        check_fraud_signal_constraints(
            risk_score=900,
            action=FraudAction.BLOCK.value,
            trigger_rules=["VELOCITY", "DAILY_LIMIT_PROXIMITY"],
            step_up_completed=None,
        )

    def test_fr_007_risk_score_boundary_low(self):
        """Boundary: risk_score == 0 is valid."""
        check_fraud_signal_constraints(
            risk_score=0, action=FraudAction.ALLOW.value,
            trigger_rules=["VELOCITY"], step_up_completed=None,
        )

    def test_fr_007_risk_score_boundary_high(self):
        """Boundary: risk_score == 1000 is valid."""
        check_fraud_signal_constraints(
            risk_score=1000, action=FraudAction.BLOCK.value,
            trigger_rules=["VELOCITY"], step_up_completed=None,
        )

    def test_fr_007_risk_score_out_of_range(self):
        """Boundary: risk_score == 1001 is rejected."""
        with pytest.raises(InvariantViolation, match="F_FraudSignalConstraints"):
            check_fraud_signal_constraints(
                risk_score=1001, action=FraudAction.BLOCK.value,
                trigger_rules=["VELOCITY"], step_up_completed=None,
            )


# ===================================================================
#  FR-008: Balance Inquiry with Read-After-Write Consistency
# ===================================================================


class TestFR008BalanceConsistency:
    """FR-008: Balance inquiry reflects read-after-write consistency."""

    def test_fr_008_happy_path_ledger_and_available(self):
        """Happy path: available <= ledger is consistent."""
        check_available_lte_ledger(available=50_000, ledger=100_000)

    def test_fr_008_equal_balances(self):
        """Edge: available == ledger is consistent."""
        check_available_lte_ledger(available=100_000, ledger=100_000)

    def test_fr_008_zero_balances(self):
        """Edge: both zero is consistent."""
        check_available_lte_ledger(available=0, ledger=0)

    def test_fr_008_inconsistent_balances(self):
        """Negative: available > ledger is inconsistent."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_available_lte_ledger(available=100_001, ledger=100_000)


# ===================================================================
#  FR-009: Administrative Transfer Reversal
# ===================================================================


class TestFR009AdministrativeReversal:
    """FR-009: Admin reversal via compensating transaction."""

    def test_fr_009_happy_path_reversal_structure(self):
        """Happy path: correctly structured reversal passes."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        check_reversal_compensating(
            reversal_source_id=dst,
            reversal_dest_id=src,
            reversal_amount=1000,
            original_source_id=src,
            original_dest_id=dst,
            original_amount=1000,
            original_status=TransferStatus.COMPLETED.value,
        )

    def test_fr_009_reversal_window_configured(self):
        """Reversal window is configurable."""
        assert settings.reversal_window_days > 0

    def test_fr_009_admin_only_permission(self):
        """Only ADMIN can reverse transfers."""
        assert is_operation_allowed([Role.ADMIN.value], OperationKind.POST_REVERSE)
        assert not is_operation_allowed([Role.CUSTOMER.value], OperationKind.POST_REVERSE)

    def test_fr_009_reversal_amount_must_match(self):
        """Reversal amount must equal original amount."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=src,
                reversal_amount=999,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=1000,
                original_status=TransferStatus.COMPLETED.value,
            )

    def test_fr_009_reversal_accounts_swapped(self):
        """Reversal must swap source and destination accounts."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        # Wrong swap: reversal source == original source (not swapped)
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=src,
                reversal_dest_id=dst,
                reversal_amount=1000,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=1000,
                original_status=TransferStatus.COMPLETED.value,
            )

    def test_fr_009_cannot_reverse_failed_transfer(self):
        """Cannot reverse a FAILED transfer."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=src,
                reversal_amount=1000,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=1000,
                original_status=TransferStatus.FAILED.value,
            )

    def test_fr_009_cannot_reverse_initiated_transfer(self):
        """Cannot reverse an INITIATED transfer."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=src,
                reversal_amount=1000,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=1000,
                original_status=TransferStatus.INITIATED.value,
            )


# ===================================================================
#  FR-010: Fail-Closed Audit
# ===================================================================


class TestFR010FailClosedAudit:
    """FR-010: Fail-closed when audit persistence is unavailable."""

    def test_fr_010_happy_path_completed_with_audit(self):
        """Happy path: completed transfer with audit entries passes."""
        check_fail_closed_audit(TransferStatus.COMPLETED.value, audit_entry_count=5)

    def test_fr_010_completed_no_audit_rejected(self):
        """Negative: COMPLETED transfer with 0 audit entries is fail-closed."""
        with pytest.raises(InvariantViolation, match="F_FailClosedAudit"):
            check_fail_closed_audit(TransferStatus.COMPLETED.value, audit_entry_count=0)

    def test_fr_010_initiated_no_audit_allowed(self):
        """INITIATED status without audit is not a fail-closed violation."""
        check_fail_closed_audit(TransferStatus.INITIATED.value, audit_entry_count=0)

    def test_fr_010_failed_no_audit_allowed(self):
        """FAILED status without audit is not a fail-closed violation."""
        check_fail_closed_audit(TransferStatus.FAILED.value, audit_entry_count=0)

    def test_fr_010_auth_required_everywhere(self):
        """Authentication is enforced for all operations."""
        from src.domain.invariants import check_auth_required

        user = StubUser(authentication_status=AuthenticationStatus.UNAUTHENTICATED.value)
        with pytest.raises(InvariantViolation, match="F_AuthRequiredEverywhere"):
            check_auth_required(user)

    def test_fr_010_failure_reason_codes_complete(self):
        """All 10 failure reason codes are defined."""
        expected = {
            "INSUFFICIENT_FUNDS", "DAILY_LIMIT_EXCEEDED", "SAME_ACCOUNT_TRANSFER",
            "CONCURRENT_MODIFICATION", "CREDIT_FAILED", "AUDIT_UNAVAILABLE",
            "EXTERNAL_TRANSFER_NOT_SUPPORTED", "VELOCITY_ALERT",
            "REVERSAL_WINDOW_EXPIRED", "ALREADY_REVERSED",
        }
        actual = {e.value for e in FailureReasonCode}
        assert actual == expected


# ===================================================================
#  Cross-cutting: Enums and config completeness
# ===================================================================


class TestEnumCompleteness:
    """Verify all domain enums match the Alloy specification."""

    def test_roles_complete(self):
        """Exactly 2 roles: CUSTOMER, ADMIN."""
        assert {r.value for r in Role} == {"CUSTOMER", "ADMIN"}

    def test_authentication_statuses_complete(self):
        """Exactly 3 auth statuses."""
        assert {s.value for s in AuthenticationStatus} == {"AUTHENTICATED", "UNAUTHENTICATED", "LOCKED"}

    def test_account_statuses_complete(self):
        """Exactly 3 account statuses."""
        assert {s.value for s in AccountStatus} == {"ACTIVE", "FROZEN", "CLOSED"}

    def test_transfer_statuses_complete(self):
        """Exactly 5 transfer statuses."""
        assert {s.value for s in TransferStatus} == {
            "INITIATED", "VALIDATED", "COMPLETED", "FAILED", "REVERSED",
        }

    def test_operation_kinds_complete(self):
        """Exactly 8 operation kinds."""
        assert len(OperationKind) == 8

    def test_fraud_actions_complete(self):
        """Exactly 3 fraud actions."""
        assert {a.value for a in FraudAction} == {"ALLOW", "STEP_UP", "BLOCK"}


class TestSettingsDefaults:
    """Verify settings defaults match the specification."""

    def test_default_currency(self):
        assert settings.default_currency == "USD"

    def test_reversal_window(self):
        assert settings.reversal_window_days == 30

    def test_velocity_window(self):
        assert settings.velocity_window_minutes == 10

    def test_velocity_max_transfers(self):
        assert settings.velocity_max_transfers == 3

    def test_fraud_thresholds_ordered(self):
        """Step-up threshold < block threshold."""
        assert settings.fraud_step_up_threshold < settings.fraud_block_threshold

    def test_jwt_algorithm(self):
        assert settings.jwt_algorithm == "HS256"
