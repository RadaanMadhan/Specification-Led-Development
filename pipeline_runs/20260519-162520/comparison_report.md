

I'll analyze both implementations systematically across all six dimensions.

# Comparison Report

## Scores

| Dimension | Weight | Guided | Baseline |
|---|---|---|---|
| Structural Completeness | 25% | 9/10 | 1/10 |
| FR Coverage | 25% | 10/10 | 3/10 |
| Invariant Enforcement | 20% | 9/10 | 2/10 |
| Test Quality | 15% | 9/10 | 5/10 |
| KPI Instrumentation | 10% | 10/10 | 0/10 |
| Security Posture | 5% | 8/10 | 2/10 |
| **Weighted Total** | | **8.95** | **2.15** |

## Verdict: GUIDED_WINS

## Analysis

### Structural Completeness

**Guided (9/10):** The guided implementation is saturated with `// PATTERN:` comments that map directly to Alloy-verified structural constraints. Patterns identified and enforced include:

- `PATTERN: AuthRequiredEverywhere` — middleware rejects unauthenticated requests before business logic (`src/middleware/auth.py:49`)
- `PATTERN: LeastPrivilege` — permission matrix with exactly 12 allowed `(Role, OperationKind)` pairs, verified at import time via `assert len(_ALLOWED_PAIRS) == 12` (`src/domain/permissions.py:18-31`)
- `PATTERN: NoInformationLeakage` — 404 returned instead of 403 for unauthorized access attempts (`src/api/routes.py:107-108`)
- `PATTERN: AppendOnly` — audit entries enforce monotonically increasing sequence numbers (`src/domain/audit_service.py:66`)
- `PATTERN: OwnershipBasedAccess` — customers restricted to own accounts (`src/api/routes.py:106`)
- `PATTERN: FailClosedAudit` — audit failure prevents transfer completion (`src/domain/audit_service.py:132-137`)
- `PATTERN: AuditCompleteness` — hash chain verification (`src/domain/audit_service.py:142`)
- `PATTERN: PermissionCompleteness` — static assertion at import time (`src/domain/permissions.py:34-36`)

Database-level constraints reinforce these patterns: `CheckConstraint("source_account_id != destination_account_id")` for `F_NoSelfTransfer`, `CheckConstraint("available_balance <= ledger_balance")` for `F_ConservationOfValue`, `UniqueConstraint("sequence_number")` for `F_AppendOnlyAuditEntries`.

The only gap preventing a 10: some patterns like `PATTERN: PermissionCompleteness` rely on an import-time assert rather than a runtime guard, and there's no explicit structural pattern for concurrency control beyond `with_for_update`.

**Baseline (1/10):** No `// PATTERN:` comments exist anywhere. No structural patterns from any verification context are referenced. The code follows standard application patterns (repository pattern, service layer) but these are generic software engineering practices, not specification-derived structural enforcement. The only structural constraint is Pydantic's `balance_not_negative` validator on the `Account` model — a single, implicit invariant with no traceability to a formal specification.

### FR Coverage

**Guided (10/10):** Every functional requirement FR-001 through FR-010 is explicitly implemented and traced via `Implements FR-NNN` docstrings:

- **FR-001** (AtomicTransfer): `execute_transfer` uses `with_for_update` row locking, `check_conservation_of_value`, and `db.commit()`/`db.rollback()` for ACID guarantees (`src/domain/transfer_service.py:40-42`)
- **FR-002** (SufficientFunds): `check_sufficient_funds` called before debit (`src/domain/transfer_service.py:131`)
- **FR-003** (UniqueTransactionRef): UUID primary key, `TransferResponse` docstring traces it, metric `transaction_ids_generated` tracks generation (`src/api/schemas.py:23`)
- **FR-004** (AuditForEveryEvent): `create_audit_entry` called at every state transition — INITIATED, VALIDATED, DEBITED, CREDITED, COMPLETED, REJECTED, etc. (`src/domain/audit_service.py:68`)
- **FR-005** (HashChain): SHA-256 hash chain with `_compute_hash`, `check_hash_chain_link`, and `verify_hash_chain` endpoint (`src/domain/audit_service.py:35-63`)
- **FR-006** (DailyLimit): `check_daily_limit` with configurable per-account limits (`src/domain/invariants.py:119-130`)
- **FR-007** (VelocityAnomaly): `evaluate_fraud_risk` with velocity window, risk scoring, STEP_UP/BLOCK actions, and step-up completion flow (`src/domain/fraud_service.py:72-152`)
- **FR-008** (BalanceConsistency): Dual ledger/available balances, `check_available_lte_ledger`, read-after-write via synchronous DB reads (`src/api/routes.py:165-180`)
- **FR-009** (ReversalCompensating): `reverse_transfer` with `check_reversal_compensating`, reversal window, compensating transaction structure (`src/domain/transfer_service.py:298-407`)
- **FR-010** (FailClosed): `check_fail_closed_audit` prevents completed transfers without audit entries; `InvariantViolation` raised on audit failure (`src/domain/invariants.py:176-185`)

**Baseline (3/10):** No `Implements FR-NNN` docstrings exist. The baseline covers basic banking functionality but lacks explicit FR traceability:

- FR-001 partially addressed (debit/credit happen, but no ACID row locking, no rollback on partial failure)
- FR-002 partially addressed (balance check exists but uses simple comparison)
- FR-003 partially addressed (UUIDs generated but no traceability)
- FR-004 partially addressed (audit entries created for transfers but no completeness guarantee)
- FR-005 not implemented (no hash chain at all)
- FR-006 not implemented (no daily limits)
- FR-007 not implemented (no fraud detection, no velocity checks, no step-up)
- FR-008 not implemented (single balance field, no ledger/available distinction)
- FR-009 not implemented (no reversal capability)
- FR-010 not implemented (no fail-closed behavior — audit failure doesn't prevent transfer)

### Invariant Enforcement

**Guided (9/10):** A dedicated `src/domain/invariants.py` module translates every named Alloy fact into a runtime validation function:

- `F_NoSelfTransfer` — checked at application level AND enforced via DB `CheckConstraint`
- `F_AuthRequiredEverywhere` — checked in middleware and invariant function
- `F_ConservationOfValue` — amount > 0, balances >= 0, available <= ledger, all with DB constraints
- `F_SufficientFunds` — explicit check before debit
- `F_ActiveAccountsOnly` — account status validation
- `F_DailyLimitEnforcement` — daily limit with positive limit validation
- `F_OwnershipBasedAccess` — role-aware ownership check
- `F_AttributionCorrectness` — audit actor must match transfer initiator
- `F_AuditCompleteness` — minimum audit entry count enforcement
- `F_AppendOnlyAuditEntries` — monotonic sequence enforcement with DB unique constraint
- `F_HashChainIntegrity` — prev_hash linkage validation
- `F_FailClosedAudit` — completed transfers require audit entries
- `F_ReversalCompensating` — reversal structure validation (swap, amount match, status check)
- `F_OwnershipExclusivity` — single owner per account
- `F_FraudSignalConstraints` — risk score range, trigger rules requirements

Each raises `InvariantViolation(fact_name, message)` with the Alloy fact name, enabling direct traceability. The custom exception class carries the `fact_name` attribute used in error responses and metrics.

Minor deduction: `check_hash_chain_link` in `create_audit_entry` passes `prev_hash` as both arguments (`check_hash_chain_link(new_seq, prev_hash, prev_hash)`), which means it's comparing a value to itself — this is a likely bug that makes the chain link check a no-op during creation (though `verify_hash_chain` does catch tampering after the fact).

**Baseline (2/10):** No named invariants or formal facts exist. The only runtime validations are:

- Pydantic `field_validator` for `balance_not_negative` and `amount_positive` (`banking/domain/models.py`)
- Self-transfer check via simple equality comparison (`banking/services/transfer_service.py:46`)
- Frozen account check (`banking/services/transfer_service.py:56-59`)
- Currency mismatch check (`banking/services/transfer_service.py:62-63`)

These are standard business validations, not formally verified invariants. There's no `InvariantViolation` exception, no fact naming, and no traceability to any specification.

### Test Quality

**Guided (9/10):** Three well-structured test files with clear naming conventions:

- `test_acceptance.py`: FR-based acceptance tests organized by `TestFR001AtomicTransfer` through `TestFR010FailClosedAudit`, plus `TestEnumCompleteness` and `TestSettingsDefaults`. Each class has happy-path and edge-case tests.
- `test_assertions.py`: Maps directly to the "FR-to-Assertion map" from the verification report. Contains assertion tests (`TestAssertionFR001AtomicTransfer`, etc.) and mutation regression tests (`TestMutationFNoSelfTransfer`, `TestMutationFAuditCompleteness`, etc.). Mutation tests reference the exact Alloy injection fact used.
- `test_kpi.py`: Tests every KPI threshold constant value, verifies Prometheus metric objects exist, checks percentage ranges, and validates exactly 12 thresholds are defined.

Test naming follows `test_fr_NNN_*`, `test_assertion_*`, `test_mutation_*`, and `test_kpi_*` conventions as specified in the rubric. Tests use lightweight stub fixtures from `conftest.py` to avoid database dependencies.

Total: ~120+ individual test cases with comprehensive positive and negative coverage.

**Baseline (5/10):** Four test files with reasonable coverage of implemented functionality:

- `test_models.py`: Pydantic validation tests (negative balance, empty owner, zero amount)
- `test_transfer_service.py`: Service-level transfer tests (success, insufficient funds, self-transfer, frozen, currency mismatch, unauthorized)
- `test_audit_service.py`: Audit log append-only behavior, attribution, resource trails
- `test_api.py`: HTTP-level integration tests with `TestClient`

Tests are well-structured and cover the implemented features, but:
- No `test_assertion_*`, `test_mutation_*`, or `test_fr_*` naming conventions
- No FR traceability in test names or docstrings
- No KPI tests
- Coverage limited to the subset of FRs that are actually implemented (missing FR-005 through FR-010)

### KPI Instrumentation

**Guided (10/10):** A comprehensive `src/config.py` defines 12 `METRIC_*` threshold constants, each with a comment identifying the WAF pillar and FR mapping:

- `METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD = 99.99` (FR-001, Cost Optimization)
- `METRIC_BALANCE_VALIDATION_ACCURACY_THRESHOLD = 99.0` (FR-002)
- `METRIC_UNIQUE_TRANSACTION_REFERENCE_ID_COUNT_THRESHOLD = 1.0` (FR-003, Reliability)
- `METRIC_AUDIT_LOG_ENTRY_CREATION_SUCCESS_RATE_THRESHOLD = 95.0` (FR-004)
- `METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD = 15.0` (FR-005, Security)
- And 7 more covering FR-006 through FR-010.

`src/infrastructure/metrics.py` defines Prometheus counters, gauges, histograms, and summaries for each KPI, with descriptive names and appropriate label cardinality. Instrumentation points are embedded throughout the business logic:

- `transfer_attempts_total.labels(status="completed").inc()` in `execute_transfer`
- `audit_entries_total.labels(result="success").inc()` in `create_audit_entry`
- `daily_limit_checks_total.labels(result="passed").inc()` in `evaluate_fraud_risk`
- `velocity_checks_total`, `step_up_challenges_total`, `fraud_signals_total` in fraud service
- `balance_reads_total.labels(consistency="consistent").inc()` in balance endpoint
- `reversals_total`, `reversal_audit_linkage` in reversal flow

A dedicated `/metrics` Prometheus endpoint is mounted in `main.py`.

**Baseline (0/10):** No KPI constants, no `METRIC_*` definitions, no Prometheus metrics, no instrumentation of any kind. No concept of SLA thresholds or operational measurement exists in the codebase.

### Security Posture

**Guided (8/10):** Multi-layered security:

- **Auth middleware**: JWT-based authentication via `jose` library with Bearer token extraction, user lookup, and `check_auth_required` invariant (`src/middleware/auth.py`)
- **Role-based authorization**: `require_role_permission` dependency with 12-pair permission matrix enforced before business logic
- **Ownership checks**: Customers restricted to own accounts at both API and domain layers
- **Information leakage prevention**: 404 returned instead of 403 for unauthorized access to prevent account enumeration
- **Input validation**: Pydantic schemas with `gt=0`, `min_length`, `max_length` constraints
- **Database constraints**: Check constraints, foreign keys, and unique constraints as defense-in-depth
- **Audit tamper detection**: SHA-256 hash chain with verification endpoint

Not a 10 because: no rate limiting, JWT secret is hardcoded as default (`"CHANGE-ME-IN-PRODUCTION"`), no CORS configuration, no request size limits beyond Pydantic validation.

**Baseline (2/10):** Minimal security:

- No authentication mechanism (no JWT, no session, no API keys)
- No authorization (any caller can perform any operation)
- No ownership checks (any caller can transfer from any account)
- Basic input validation via Pydantic (`amount > 0`, non-empty owner)
- `UnauthorizedError` only checks for non-empty `initiated_by` string — this is identity assertion, not authentication
- No rate limiting, no CORS, no information leakage prevention

## Key Differences

- **Formal verification traceability**: The guided implementation has end-to-end traceability from Alloy facts to runtime invariants to tests to metrics. The baseline has none.
- **Feature completeness**: Guided implements all 10 FRs; baseline implements ~3-4 partially. Major missing features: hash chain audit (FR-005), daily limits (FR-006), fraud detection/step-up (FR-007), dual-balance model (FR-008), reversals (FR-009), fail-closed behavior (FR-010).
- **Defense in depth**: Guided enforces invariants at 3 layers (application logic, database constraints, API middleware). Baseline relies solely on application-level checks.
- **Operational observability**: Guided has 20+ Prometheus metrics with WAF-derived thresholds. Baseline has zero instrumentation.
- **Authentication/Authorization**: Guided has JWT auth + RBAC with a formally verified permission matrix. Baseline has no real auth — just a string field check.
- **Data model sophistication**: Guided uses PostgreSQL with async SQLAlchemy, row-level locking, optimistic concurrency (version columns), and dual ledger/available balances. Baseline uses in-memory dictionaries with threading locks and a single balance field.
- **Test methodology**: Guided tests are organized by formal assertions and mutation targets with ~120+ tests. Baseline tests are organized by component with ~30 tests covering basic happy/sad paths.
- **Architecture**: Guided follows a hexagonal/clean architecture with domain services, infrastructure layer, and middleware. Baseline follows a simpler layered architecture with repositories and services, but without the formal domain modeling rigor.
