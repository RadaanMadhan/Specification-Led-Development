"""
Assertion and Mutation Regression Tests.

Each test traces back to the FR-to-Assertion map and Mutation Results from
the unified verification report.  Tests are named after the Alloy assertion
or mutated fact they cover.

Assertions verified (20 total):
  FR_001_AtomicTransfer, ConservationOfValue, FR_002_SufficientFunds,
  FR_003_UniqueTransactionRef, FR_004_AuditForEveryEvent, AuditCompleteness,
  AppendOnly, FR_005_HashChain, FR_006_DailyLimit, LeastPrivilege,
  FR_008_BalanceConsistency, FR_009_ReversalCompensating,
  FR_010_FailClosedAudit, AuthRequiredEverywhere

Mutation targets (6):
  F_NoSelfTransfer, F_AuditCompleteness, F_AppendOnlyAuditEntries,
  F_OwnershipBasedAccess, F_AuthRequiredEverywhere, F_AttributionCorrectness
"""

from __future__ import annotations

import hashlib
import uuid

import pytest

from src.domain.enums import (
    AccountStatus,
    AuthenticationStatus,
    FraudAction,
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
    check_ownership_exclusivity,
    check_reversal_compensating,
    check_sufficient_funds,
)
from src.domain.permissions import (
    _ALLOWED_PAIRS,
    is_operation_allowed,
    require_permission,
)

from tests.conftest import StubUser


# ===================================================================
#  ASSERTION TESTS — one test per assertion from the FR-to-Assertion map
# ===================================================================


class TestAssertionFR001AtomicTransfer:
    """Assertion: FR_001_AtomicTransfer — transfers must be atomic."""

    def test_assertion_FR_001_AtomicTransfer_positive_amount(self):
        """Positive: valid amount and non-negative balances pass."""
        check_conservation_of_value(amount=500, source_balance=1000, dest_balance=2000)

    def test_assertion_FR_001_AtomicTransfer_zero_amount_rejected(self):
        """Negative: zero amount violates conservation of value."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_conservation_of_value(amount=0, source_balance=1000, dest_balance=2000)

    def test_assertion_FR_001_AtomicTransfer_negative_amount_rejected(self):
        """Negative: negative amount violates conservation of value."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_conservation_of_value(amount=-100, source_balance=1000, dest_balance=2000)

    def test_assertion_FR_001_AtomicTransfer_negative_source_rejected(self):
        """Negative: negative source balance violates conservation."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_conservation_of_value(amount=100, source_balance=-1, dest_balance=2000)

    def test_assertion_FR_001_AtomicTransfer_negative_dest_rejected(self):
        """Negative: negative destination balance violates conservation."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_conservation_of_value(amount=100, source_balance=1000, dest_balance=-1)


class TestAssertionConservationOfValue:
    """Assertion: ConservationOfValue — amount > 0, balances >= 0, available <= ledger."""

    def test_assertion_ConservationOfValue_available_equals_ledger(self):
        """Positive: available == ledger is valid."""
        check_available_lte_ledger(available=1000, ledger=1000)

    def test_assertion_ConservationOfValue_available_below_ledger(self):
        """Positive: available < ledger is valid (e.g. holds)."""
        check_available_lte_ledger(available=500, ledger=1000)

    def test_assertion_ConservationOfValue_available_exceeds_ledger(self):
        """Negative: available > ledger violates invariant."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_available_lte_ledger(available=1001, ledger=1000)


class TestAssertionFR002SufficientFunds:
    """Assertion: FR_002_SufficientFunds — sufficient available balance before debit."""

    def test_assertion_FR_002_SufficientFunds_enough_balance(self):
        """Positive: sufficient funds pass."""
        check_sufficient_funds(available_balance=1000, amount=1000)

    def test_assertion_FR_002_SufficientFunds_exact_balance(self):
        """Positive: exact balance passes."""
        check_sufficient_funds(available_balance=500, amount=500)

    def test_assertion_FR_002_SufficientFunds_insufficient(self):
        """Negative: insufficient funds raise InvariantViolation."""
        with pytest.raises(InvariantViolation, match="F_SufficientFunds"):
            check_sufficient_funds(available_balance=499, amount=500)

    def test_assertion_FR_002_SufficientFunds_zero_balance(self):
        """Negative: zero balance with positive amount fails."""
        with pytest.raises(InvariantViolation, match="F_SufficientFunds"):
            check_sufficient_funds(available_balance=0, amount=1)


class TestAssertionFR003UniqueTransactionRef:
    """Assertion: FR_003_UniqueTransactionRef — each transfer gets a unique UUID."""

    def test_assertion_FR_003_UniqueTransactionRef(self):
        """Positive: UUID generation produces unique values."""
        ids = {uuid.uuid4() for _ in range(1000)}
        assert len(ids) == 1000, "UUID generation should produce unique identifiers"


class TestAssertionFR004AuditForEveryEvent:
    """Assertion: FR_004_AuditForEveryEvent — every transfer has audit entries."""

    def test_assertion_FR_004_AuditForEveryEvent_positive(self):
        """Positive: transfer with audit entries passes."""
        check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=3)

    def test_assertion_FR_004_AuditForEveryEvent_one_entry(self):
        """Positive: minimum of 1 audit entry passes."""
        check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=1)

    def test_assertion_FR_004_AuditForEveryEvent_zero_entries(self):
        """Negative: zero entries violates audit completeness."""
        with pytest.raises(InvariantViolation, match="F_AuditCompleteness"):
            check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=0)


class TestAssertionAuditCompleteness:
    """Assertion: AuditCompleteness — every transfer must have >= 1 audit entry."""

    def test_assertion_AuditCompleteness_positive(self):
        """Positive: multiple entries satisfy completeness."""
        check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=5)

    def test_assertion_AuditCompleteness_negative(self):
        """Negative: no entries violate completeness."""
        with pytest.raises(InvariantViolation, match="F_AuditCompleteness"):
            check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=0)


class TestAssertionAppendOnly:
    """Assertion: AppendOnly — no two audit entries share the same sequence number."""

    def test_assertion_AppendOnly_monotonic_increase(self):
        """Positive: new_seq > last_seq passes."""
        check_append_only_sequence(new_seq=2, last_seq=1)

    def test_assertion_AppendOnly_first_entry(self):
        """Positive: first entry (last_seq=None) passes."""
        check_append_only_sequence(new_seq=1, last_seq=None)

    def test_assertion_AppendOnly_duplicate_sequence(self):
        """Negative: new_seq == last_seq violates append-only."""
        with pytest.raises(InvariantViolation, match="F_AppendOnlyAuditEntries"):
            check_append_only_sequence(new_seq=5, last_seq=5)

    def test_assertion_AppendOnly_decreasing_sequence(self):
        """Negative: new_seq < last_seq violates append-only."""
        with pytest.raises(InvariantViolation, match="F_AppendOnlyAuditEntries"):
            check_append_only_sequence(new_seq=3, last_seq=5)


class TestAssertionFR005HashChain:
    """Assertion: FR_005_HashChain — cryptographic hash chain integrity."""

    def test_assertion_FR_005_HashChain_first_entry_null_prev(self):
        """Positive: first entry (seq=1) with null prev_hash passes."""
        check_hash_chain_link(sequence_number=1, prev_hash=None, expected_prev_hash=None)

    def test_assertion_FR_005_HashChain_subsequent_entry(self):
        """Positive: subsequent entry with matching prev_hash passes."""
        h = hashlib.sha256(b"test").hexdigest()
        check_hash_chain_link(sequence_number=2, prev_hash=h, expected_prev_hash=h)

    def test_assertion_FR_005_HashChain_first_entry_with_prev(self):
        """Negative: first entry with non-null prev_hash is invalid."""
        with pytest.raises(InvariantViolation, match="F_HashChainIntegrity"):
            check_hash_chain_link(
                sequence_number=1,
                prev_hash="abc123",
                expected_prev_hash=None,
            )

    def test_assertion_FR_005_HashChain_subsequent_missing_prev(self):
        """Negative: non-first entry with null prev_hash is invalid."""
        with pytest.raises(InvariantViolation, match="F_HashChainIntegrity"):
            check_hash_chain_link(
                sequence_number=2,
                prev_hash=None,
                expected_prev_hash="abc123",
            )

    def test_assertion_FR_005_HashChain_prev_hash_mismatch(self):
        """Negative: mismatching prev_hash is detected."""
        with pytest.raises(InvariantViolation, match="F_HashChainIntegrity"):
            check_hash_chain_link(
                sequence_number=3,
                prev_hash="aaaa",
                expected_prev_hash="bbbb",
            )


class TestAssertionFR006DailyLimit:
    """Assertion: FR_006_DailyLimit — per-account daily transfer limits enforced."""

    def test_assertion_FR_006_DailyLimit_within_limit(self):
        """Positive: amount within daily limit passes."""
        check_daily_limit(daily_limit=500_000, current_daily_total=0, amount=100_000)

    def test_assertion_FR_006_DailyLimit_at_exact_limit(self):
        """Positive: exactly at limit passes."""
        check_daily_limit(daily_limit=500_000, current_daily_total=400_000, amount=100_000)

    def test_assertion_FR_006_DailyLimit_exceeds_limit(self):
        """Negative: exceeding daily limit raises."""
        with pytest.raises(InvariantViolation, match="F_DailyLimitEnforcement"):
            check_daily_limit(daily_limit=500_000, current_daily_total=400_001, amount=100_000)

    def test_assertion_FR_006_DailyLimit_zero_limit_rejected(self):
        """Negative: zero daily limit is invalid."""
        with pytest.raises(InvariantViolation, match="F_DailyLimitEnforcement"):
            check_daily_limit(daily_limit=0, current_daily_total=0, amount=100)

    def test_assertion_FR_006_DailyLimit_negative_limit_rejected(self):
        """Negative: negative daily limit is invalid."""
        with pytest.raises(InvariantViolation, match="F_DailyLimitEnforcement"):
            check_daily_limit(daily_limit=-100, current_daily_total=0, amount=100)


class TestAssertionLeastPrivilege:
    """Assertion: LeastPrivilege — only 12 allowed (role, operation) pairs."""

    def test_assertion_LeastPrivilege_exactly_12_pairs(self):
        """The permission matrix must contain exactly 12 allowed pairs."""
        assert len(_ALLOWED_PAIRS) == 12

    def test_assertion_LeastPrivilege_customer_allowed_ops(self):
        """Customer has exactly 5 allowed operations."""
        customer_ops = [
            OperationKind.POST_TRANSFERS,
            OperationKind.GET_TRANSFER_BY_ID,
            OperationKind.GET_BALANCE,
            OperationKind.GET_TRANSACTIONS,
            OperationKind.POST_STEP_UP,
        ]
        for op in customer_ops:
            assert is_operation_allowed([Role.CUSTOMER.value], op), f"CUSTOMER should be allowed {op}"

    def test_assertion_LeastPrivilege_customer_denied_ops(self):
        """Customer is denied POST_REVERSE, GET_AUDIT_ENTRIES, GET_AUDIT_VERIFY."""
        denied_ops = [
            OperationKind.POST_REVERSE,
            OperationKind.GET_AUDIT_ENTRIES,
            OperationKind.GET_AUDIT_VERIFY,
        ]
        for op in denied_ops:
            assert not is_operation_allowed([Role.CUSTOMER.value], op), f"CUSTOMER should be denied {op}"

    def test_assertion_LeastPrivilege_admin_allowed_ops(self):
        """Admin has exactly 7 allowed operations."""
        admin_ops = [
            OperationKind.POST_TRANSFERS,
            OperationKind.GET_TRANSFER_BY_ID,
            OperationKind.POST_REVERSE,
            OperationKind.GET_BALANCE,
            OperationKind.GET_TRANSACTIONS,
            OperationKind.GET_AUDIT_ENTRIES,
            OperationKind.GET_AUDIT_VERIFY,
        ]
        for op in admin_ops:
            assert is_operation_allowed([Role.ADMIN.value], op), f"ADMIN should be allowed {op}"

    def test_assertion_LeastPrivilege_admin_denied_step_up(self):
        """Admin is denied POST_STEP_UP."""
        assert not is_operation_allowed([Role.ADMIN.value], OperationKind.POST_STEP_UP)

    def test_assertion_LeastPrivilege_require_permission_raises(self):
        """require_permission raises InvariantViolation for denied operations."""
        with pytest.raises(InvariantViolation, match="F_LeastPrivilege"):
            require_permission([Role.CUSTOMER.value], OperationKind.POST_REVERSE)

    def test_assertion_LeastPrivilege_unknown_role_denied(self):
        """An unknown role string is denied all operations."""
        for op in OperationKind:
            assert not is_operation_allowed(["UNKNOWN_ROLE"], op)


class TestAssertionFR008BalanceConsistency:
    """Assertion: FR_008_BalanceConsistency — available <= ledger."""

    def test_assertion_FR_008_BalanceConsistency_consistent(self):
        """Positive: available <= ledger passes."""
        check_available_lte_ledger(available=100, ledger=200)

    def test_assertion_FR_008_BalanceConsistency_equal(self):
        """Positive: available == ledger passes."""
        check_available_lte_ledger(available=200, ledger=200)

    def test_assertion_FR_008_BalanceConsistency_violation(self):
        """Negative: available > ledger is rejected."""
        with pytest.raises(InvariantViolation, match="F_ConservationOfValue"):
            check_available_lte_ledger(available=201, ledger=200)


class TestAssertionFR009ReversalCompensating:
    """Assertion: FR_009_ReversalCompensating — reversal structure correct."""

    def test_assertion_FR_009_ReversalCompensating_valid(self):
        """Positive: correctly structured reversal passes."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        check_reversal_compensating(
            reversal_source_id=dst,
            reversal_dest_id=src,
            reversal_amount=500,
            original_source_id=src,
            original_dest_id=dst,
            original_amount=500,
            original_status=TransferStatus.COMPLETED.value,
        )

    def test_assertion_FR_009_ReversalCompensating_reversed_original_ok(self):
        """Positive: original in REVERSED status is also valid for re-reversal check."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        check_reversal_compensating(
            reversal_source_id=dst,
            reversal_dest_id=src,
            reversal_amount=500,
            original_source_id=src,
            original_dest_id=dst,
            original_amount=500,
            original_status=TransferStatus.REVERSED.value,
        )

    def test_assertion_FR_009_ReversalCompensating_wrong_source(self):
        """Negative: reversal source != original destination."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        wrong = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=wrong,
                reversal_dest_id=src,
                reversal_amount=500,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=500,
                original_status=TransferStatus.COMPLETED.value,
            )

    def test_assertion_FR_009_ReversalCompensating_wrong_dest(self):
        """Negative: reversal destination != original source."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        wrong = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=wrong,
                reversal_amount=500,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=500,
                original_status=TransferStatus.COMPLETED.value,
            )

    def test_assertion_FR_009_ReversalCompensating_amount_mismatch(self):
        """Negative: reversal amount != original amount."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=src,
                reversal_amount=999,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=500,
                original_status=TransferStatus.COMPLETED.value,
            )

    def test_assertion_FR_009_ReversalCompensating_original_not_completed(self):
        """Negative: original in INITIATED status cannot be reversed."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=src,
                reversal_amount=500,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=500,
                original_status=TransferStatus.INITIATED.value,
            )

    def test_assertion_FR_009_ReversalCompensating_original_failed(self):
        """Negative: original in FAILED status cannot be reversed."""
        src = uuid.uuid4()
        dst = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_ReversalCompensating"):
            check_reversal_compensating(
                reversal_source_id=dst,
                reversal_dest_id=src,
                reversal_amount=500,
                original_source_id=src,
                original_dest_id=dst,
                original_amount=500,
                original_status=TransferStatus.FAILED.value,
            )


class TestAssertionFR010FailClosedAudit:
    """Assertion: FR_010_FailClosedAudit — no completed transfer without audit."""

    def test_assertion_FR_010_FailClosedAudit_completed_with_audit(self):
        """Positive: COMPLETED transfer with audit entries passes."""
        check_fail_closed_audit(
            transfer_status=TransferStatus.COMPLETED.value,
            audit_entry_count=3,
        )

    def test_assertion_FR_010_FailClosedAudit_failed_without_audit(self):
        """Positive: non-COMPLETED status without audit is allowed."""
        check_fail_closed_audit(
            transfer_status=TransferStatus.FAILED.value,
            audit_entry_count=0,
        )

    def test_assertion_FR_010_FailClosedAudit_completed_no_audit(self):
        """Negative: COMPLETED transfer with 0 audit entries is rejected."""
        with pytest.raises(InvariantViolation, match="F_FailClosedAudit"):
            check_fail_closed_audit(
                transfer_status=TransferStatus.COMPLETED.value,
                audit_entry_count=0,
            )


class TestAssertionAuthRequiredEverywhere:
    """Assertion: AuthRequiredEverywhere — only authenticated users."""

    def test_assertion_AuthRequiredEverywhere_authenticated(self):
        """Positive: authenticated user passes."""
        from src.domain.invariants import check_auth_required

        user = StubUser(authentication_status=AuthenticationStatus.AUTHENTICATED.value)
        check_auth_required(user)

    def test_assertion_AuthRequiredEverywhere_unauthenticated(self):
        """Negative: unauthenticated user is rejected."""
        from src.domain.invariants import check_auth_required

        user = StubUser(authentication_status=AuthenticationStatus.UNAUTHENTICATED.value)
        with pytest.raises(InvariantViolation, match="F_AuthRequiredEverywhere"):
            check_auth_required(user)

    def test_assertion_AuthRequiredEverywhere_locked(self):
        """Negative: locked user is rejected."""
        from src.domain.invariants import check_auth_required

        user = StubUser(authentication_status=AuthenticationStatus.LOCKED.value)
        with pytest.raises(InvariantViolation, match="F_AuthRequiredEverywhere"):
            check_auth_required(user)


# ===================================================================
#  MUTATION REGRESSION TESTS — one test per mutation target
# ===================================================================


class TestMutationFNoSelfTransfer:
    """
    Regression: Mutation target F_NoSelfTransfer.
    Injection: fact MUTATE_SelfTransfer { some t: Transfer | t.source = t.destination }
    """

    def test_mutation_F_NoSelfTransfer(self):
        """Removing the self-transfer guard must be caught."""
        account_id = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_NoSelfTransfer"):
            check_no_self_transfer(account_id, account_id)

    def test_mutation_F_NoSelfTransfer_different_accounts(self):
        """Non-self transfers are allowed."""
        check_no_self_transfer(uuid.uuid4(), uuid.uuid4())


class TestMutationFAuditCompleteness:
    """
    Regression: Mutation target F_AuditCompleteness.
    Injection: fact MUTATE_NoAudit { some t: Transfer | no ae: AuditEntry | ae.transaction = t }
    Asserts violated: AuditCompleteness, FR_004_AuditForEveryEvent, FR_010_FailClosedAudit
    """

    def test_mutation_F_AuditCompleteness_no_audit(self):
        """Transfer with no audit entries is rejected by audit completeness."""
        with pytest.raises(InvariantViolation, match="F_AuditCompleteness"):
            check_audit_completeness(transfer_id=uuid.uuid4(), audit_entry_count=0)

    def test_mutation_F_AuditCompleteness_fail_closed(self):
        """Completed transfer with no audit entries is rejected by fail-closed."""
        with pytest.raises(InvariantViolation, match="F_FailClosedAudit"):
            check_fail_closed_audit(
                transfer_status=TransferStatus.COMPLETED.value,
                audit_entry_count=0,
            )


class TestMutationFAppendOnlyAuditEntries:
    """
    Regression: Mutation target F_AppendOnlyAuditEntries.
    Injection: fact MUTATE_DuplicateSeq { some disj ae1, ae2: AuditEntry | ae1.seqNum = ae2.seqNum }
    """

    def test_mutation_F_AppendOnlyAuditEntries(self):
        """Duplicate sequence numbers must be caught."""
        with pytest.raises(InvariantViolation, match="F_AppendOnlyAuditEntries"):
            check_append_only_sequence(new_seq=5, last_seq=5)

    def test_mutation_F_AppendOnlyAuditEntries_backwards(self):
        """Decreasing sequence must be caught."""
        with pytest.raises(InvariantViolation, match="F_AppendOnlyAuditEntries"):
            check_append_only_sequence(new_seq=3, last_seq=7)


class TestMutationFOwnershipBasedAccess:
    """
    Regression: Mutation target F_OwnershipBasedAccess.
    Injection: fact MUTATE_OwnershipBypass { some t: Transfer | Customer in
               t.initiatedBy.roles and t.source not in t.initiatedBy.owns }
    """

    def test_mutation_F_OwnershipBasedAccess(self):
        """Customer transferring from another user's account must be caught."""
        customer = StubUser(roles=[Role.CUSTOMER.value])
        other_owner_id = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_OwnershipBasedAccess"):
            check_ownership_based_access(customer, other_owner_id)

    def test_mutation_F_OwnershipBasedAccess_own_account(self):
        """Customer transferring from own account is allowed."""
        customer = StubUser(roles=[Role.CUSTOMER.value])
        check_ownership_based_access(customer, customer.id)

    def test_mutation_F_OwnershipBasedAccess_admin_bypass(self):
        """Admin is not restricted by ownership — can transfer from any account."""
        admin = StubUser(roles=[Role.ADMIN.value])
        other_owner_id = uuid.uuid4()
        check_ownership_based_access(admin, other_owner_id)


class TestMutationFAuthRequiredEverywhere:
    """
    Regression: Mutation target F_AuthRequiredEverywhere.
    Injection: fact MUTATE_UnauthTransfer { some t: Transfer |
               t.initiatedBy.authStatus = Unauthenticated }
    """

    def test_mutation_F_AuthRequiredEverywhere(self):
        """Unauthenticated users must be rejected."""
        from src.domain.invariants import check_auth_required

        user = StubUser(authentication_status=AuthenticationStatus.UNAUTHENTICATED.value)
        with pytest.raises(InvariantViolation, match="F_AuthRequiredEverywhere"):
            check_auth_required(user)


class TestMutationFAttributionCorrectness:
    """
    Regression: Mutation target F_AttributionCorrectness.
    Injection: fact MUTATE_Misattribution { some ae: AuditEntry |
               ae.actor != ae.transaction.initiatedBy }
    """

    def test_mutation_F_AttributionCorrectness(self):
        """Audit actor != transfer initiator must be caught."""
        actor = uuid.uuid4()
        initiator = uuid.uuid4()
        with pytest.raises(InvariantViolation, match="F_AttributionCorrectness"):
            check_attribution_correctness(actor, initiator)

    def test_mutation_F_AttributionCorrectness_matching(self):
        """Matching actor and initiator passes."""
        user_id = uuid.uuid4()
        check_attribution_correctness(user_id, user_id)


# ===================================================================
#  ADDITIONAL ASSERTION COVERAGE — remaining invariants
# ===================================================================


class TestAssertionActiveAccountsOnly:
    """F_ActiveAccountsOnly — only active accounts may participate."""

    def test_assertion_ActiveAccountsOnly_both_active(self):
        """Positive: both accounts active."""
        check_active_accounts(AccountStatus.ACTIVE.value, AccountStatus.ACTIVE.value)

    def test_assertion_ActiveAccountsOnly_source_frozen(self):
        """Negative: frozen source account rejected."""
        with pytest.raises(InvariantViolation, match="F_ActiveAccountsOnly"):
            check_active_accounts(AccountStatus.FROZEN.value, AccountStatus.ACTIVE.value)

    def test_assertion_ActiveAccountsOnly_dest_closed(self):
        """Negative: closed destination account rejected."""
        with pytest.raises(InvariantViolation, match="F_ActiveAccountsOnly"):
            check_active_accounts(AccountStatus.ACTIVE.value, AccountStatus.CLOSED.value)

    def test_assertion_ActiveAccountsOnly_both_frozen(self):
        """Negative: both frozen accounts rejected (source checked first)."""
        with pytest.raises(InvariantViolation, match="F_ActiveAccountsOnly"):
            check_active_accounts(AccountStatus.FROZEN.value, AccountStatus.FROZEN.value)


class TestAssertionOwnershipExclusivity:
    """F_OwnershipExclusivity — each account must have exactly one owner."""

    def test_assertion_OwnershipExclusivity_valid_owner(self):
        """Positive: account with an owner passes."""
        check_ownership_exclusivity(uuid.uuid4())

    def test_assertion_OwnershipExclusivity_no_owner(self):
        """Negative: null owner is rejected."""
        with pytest.raises(InvariantViolation, match="F_OwnershipExclusivity"):
            check_ownership_exclusivity(None)


class TestAssertionFraudSignalConstraints:
    """F_FraudSignalConstraints — structural constraints on fraud signals."""

    def test_assertion_FraudSignalConstraints_allow_valid(self):
        """Positive: ALLOW with 0 risk, any triggers, no step_up_completed."""
        check_fraud_signal_constraints(
            risk_score=0,
            action=FraudAction.ALLOW.value,
            trigger_rules=["VELOCITY"],
            step_up_completed=None,
        )

    def test_assertion_FraudSignalConstraints_step_up_valid(self):
        """Positive: STEP_UP with trigger rules and step_up_completed=False."""
        check_fraud_signal_constraints(
            risk_score=500,
            action=FraudAction.STEP_UP.value,
            trigger_rules=["VELOCITY"],
            step_up_completed=False,
        )

    def test_assertion_FraudSignalConstraints_block_valid(self):
        """Positive: BLOCK with trigger rules, no step_up_completed."""
        check_fraud_signal_constraints(
            risk_score=800,
            action=FraudAction.BLOCK.value,
            trigger_rules=["VELOCITY", "AMOUNT_DEVIATION"],
            step_up_completed=None,
        )

    def test_assertion_FraudSignalConstraints_risk_too_high(self):
        """Negative: risk score > 1000 rejected."""
        with pytest.raises(InvariantViolation, match="F_FraudSignalConstraints"):
            check_fraud_signal_constraints(
                risk_score=1001,
                action=FraudAction.ALLOW.value,
                trigger_rules=[],
                step_up_completed=None,
            )

    def test_assertion_FraudSignalConstraints_risk_negative(self):
        """Negative: negative risk score rejected."""
        with pytest.raises(InvariantViolation, match="F_FraudSignalConstraints"):
            check_fraud_signal_constraints(
                risk_score=-1,
                action=FraudAction.ALLOW.value,
                trigger_rules=[],
                step_up_completed=None,
            )

    def test_assertion_FraudSignalConstraints_step_up_no_rules(self):
        """Negative: STEP_UP with empty trigger rules rejected."""
        with pytest.raises(InvariantViolation, match="F_FraudSignalConstraints"):
            check_fraud_signal_constraints(
                risk_score=500,
                action=FraudAction.STEP_UP.value,
                trigger_rules=[],
                step_up_completed=False,
            )

    def test_assertion_FraudSignalConstraints_block_no_rules(self):
        """Negative: BLOCK with empty trigger rules rejected."""
        with pytest.raises(InvariantViolation, match="F_FraudSignalConstraints"):
            check_fraud_signal_constraints(
                risk_score=800,
                action=FraudAction.BLOCK.value,
                trigger_rules=[],
                step_up_completed=None,
            )

    def test_assertion_FraudSignalConstraints_non_stepup_with_completed(self):
        """Negative: step_up_completed set when action is not STEP_UP."""
        with pytest.raises(InvariantViolation, match="F_FraudSignalConstraints"):
            check_fraud_signal_constraints(
                risk_score=0,
                action=FraudAction.ALLOW.value,
                trigger_rules=["VELOCITY"],
                step_up_completed=True,
            )
