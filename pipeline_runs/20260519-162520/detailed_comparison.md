# Detailed Comparison Report: Guided vs Baseline Implementation

## 1. Architecture Overview

### Guided Track
**Stack:** FastAPI + async SQLAlchemy (PostgreSQL/asyncpg) + Pydantic + Prometheus + python-jose (JWT)

```
src/
├── main.py                          # FastAPI app with Prometheus /metrics
├── config.py                        # Settings + 12 KPI threshold constants
├── api/
│   ├── routes.py                    # 8 endpoints with role-based auth
│   └── schemas.py                   # Request/response models
├── domain/
│   ├── enums.py                     # 8 enums (Role, AuthStatus, AccountStatus, etc.)
│   ├── models.py                    # SQLAlchemy ORM: User, Account, Transfer, AuditEntry, FraudSignal
│   ├── invariants.py                # 15 runtime invariant validators (F_* facts)
│   ├── permissions.py               # 12-pair (Role, OperationKind) permission matrix
│   ├── transfer_service.py          # 6-step transfer execution + reversal
│   ├── audit_service.py             # SHA-256 hash chain audit log
│   └── fraud_service.py             # Velocity anomaly detection + risk scoring
├── infrastructure/
│   ├── database.py                  # Async connection pool
│   └── metrics.py                   # 16 Prometheus counters/gauges/histograms
├── middleware/
│   └── auth.py                      # JWT auth + role-based authorization
└── tests/
    ├── conftest.py                  # Lightweight stub fixtures (no DB)
    ├── test_assertions.py           # 69 assertion + 12 mutation tests
    ├── test_acceptance.py           # 56 FR acceptance tests
    └── test_kpi.py                  # 35 KPI threshold tests
```

**25 Python files, ~4,700 lines**

### Baseline Track
**Stack:** FastAPI + in-memory dictionaries + threading.Lock + Pydantic

```
banking/
├── domain/
│   ├── models.py                    # Pydantic models: Account, Transaction, AuditEntry
│   └── exceptions.py                # 6 custom exceptions
├── repositories/
│   ├── account_repository.py        # ABC + InMemoryAccountRepository
│   ├── transaction_repository.py    # ABC + InMemoryTransactionRepository
│   └── audit_repository.py          # ABC + InMemoryAuditRepository
├── services/
│   ├── account_service.py           # Account CRUD + freeze/unfreeze
│   ├── transfer_service.py          # Transfer with validation chain
│   └── audit_service.py             # Simple audit logging facade
├── api/
│   ├── app.py                       # App factory + DI wiring
│   ├── routes.py                    # 9 endpoints
│   └── schemas.py                   # 7 request/response models
└── tests/
    ├── conftest.py                  # Repository + service fixtures
    ├── test_models.py               # 10 model validation tests
    ├── test_transfer_service.py     # 11 transfer tests
    ├── test_audit_service.py        # 6 audit tests
    └── test_api.py                  # 13 integration tests
```

**22 Python files, ~1,530 lines**

---

## 2. Feature Completeness

| Functional Requirement | Guided | Baseline |
|---|---|---|
| **FR-001** Atomic transfers (debit + credit or neither) | Row-level locking (`with_for_update`), conservation-of-value check, rollback on failure | Simple debit/credit in sequence, no row locking, no rollback |
| **FR-002** Sufficient balance validation | `check_sufficient_funds` invariant + DB constraint `available_balance >= 0` | `InsufficientFundsError` if `balance < amount` |
| **FR-003** Unique transaction reference ID | UUID primary key + `transaction_ids_generated` Prometheus counter | UUID primary key only |
| **FR-004** Append-only audit log per event | 14 event types, monotonic sequence numbers, `UNIQUE(sequence_number)` DB constraint | 6 event types, list-based append-only repo |
| **FR-005** Cryptographic hash chain | SHA-256 chain (`_compute_hash`, `verify_hash_chain` endpoint) | **Not implemented** |
| **FR-006** Daily transfer limits | Per-account `daily_limit` field, `check_daily_limit` with daily aggregation | **Not implemented** |
| **FR-007** Velocity anomaly detection | Risk scoring (0-1000), velocity window, step-up auth, BLOCK/STEP_UP/ALLOW actions | **Not implemented** |
| **FR-008** Balance inquiry (ledger + available) | Dual `ledger_balance` / `available_balance` fields, read-after-write consistency | Single `balance` field only |
| **FR-009** Administrative reversal | Compensating transaction (swap accounts, match amount), reversal window, admin-only | **Not implemented** |
| **FR-010** Fail-closed on audit unavailability | `check_fail_closed_audit` — transfer rejected if no audit entries | **Not implemented** |

**Guided: 10/10 FRs implemented. Baseline: 4/10 partially implemented (FR-001 through FR-004), 6/10 missing.**

---

## 3. Data Model Comparison

### Guided — SQLAlchemy ORM with 5 entities

```
User (id, username, email, roles, authentication_status, created_at)
Account (id, owner_id→User, ledger_balance, available_balance, daily_limit, currency, status, version, created_at)
Transfer (id, source_account_id→Account, destination_account_id→Account, amount, currency, status, failure_reason_code, initiated_by→User, original_transaction_id→Transfer, created_at, completed_at)
AuditEntry (id, transfer_id→Transfer, event_type, actor_id→User, sequence_number, prev_hash, current_hash, fraud_flag, created_at)
FraudSignal (id, transfer_id→Transfer, account_id→Account, risk_score, trigger_rules, action, created_at)
```

Database-level constraints:
- `CHECK(source_account_id != destination_account_id)` — F_NoSelfTransfer
- `CHECK(amount > 0)` — F_ConservationOfValue
- `CHECK(ledger_balance >= 0)`, `CHECK(available_balance >= 0)`, `CHECK(available_balance <= ledger_balance)`
- `CHECK(daily_limit > 0)` — F_DailyLimitEnforcement
- `UNIQUE(sequence_number)` — F_AppendOnlyAuditEntries
- `CHECK(risk_score >= 0 AND risk_score <= 1000)` — F_FraudSignalConstraints
- Foreign keys with NOT NULL for ownership exclusivity

### Baseline — Pydantic models with 3 entities

```
Account (id, owner, balance, currency, is_frozen, created_at)
Transaction (id, source_account_id, destination_account_id, amount, currency, status, initiated_by, reason, failure_reason, created_at, completed_at)
AuditEntry (id, timestamp, action, actor, resource_type, resource_id, details)
```

No database — in-memory dictionaries with `threading.Lock()`.
Validators: `balance >= 0`, `amount > 0`, `owner` non-empty.

**Key differences:**
- Guided has 5 entities vs 3 (adds User, FraudSignal)
- Guided has dual balance fields (ledger + available) vs single balance
- Guided has 7 database CHECK constraints; baseline has 0
- Guided models relationships via foreign keys; baseline uses plain UUIDs
- Guided has `version` column for optimistic concurrency; baseline uses thread locks

---

## 4. Security Comparison

| Security Control | Guided | Baseline |
|---|---|---|
| **Authentication** | JWT (HS256) with Bearer token extraction, user lookup from DB | `initiated_by` string field non-empty check |
| **Authorization** | Role-based: 12 (Role, OperationKind) pairs, checked before route handler | None — any caller can do anything |
| **Ownership enforcement** | Customers restricted to own accounts at API + domain layers | None — any caller can transfer from any account |
| **Rate limiting / velocity** | Velocity window (10 min), risk scoring, step-up auth, block at threshold 800 | None |
| **Information leakage** | 404 for both missing AND unauthorized resources | 403 for frozen, 404 for missing (leaks frozen status) |
| **Input validation** | Pydantic schemas + DB constraints + domain invariants (3 layers) | Pydantic schemas only |
| **Audit tamper detection** | SHA-256 hash chain with verification endpoint | None |
| **Fail-closed** | Transfer rejected if audit logging fails | Audit failure doesn't block transfer |
| **Account locking** | `LOCKED` auth status blocks all operations | `is_frozen` blocks transfers only |

---

## 5. Invariant Enforcement

The guided implementation has a dedicated `invariants.py` module with 15 validator functions, each named after an Alloy fact and raising `InvariantViolation(fact_name, message)`.

| Alloy Fact | Guided Implementation | Baseline Equivalent |
|---|---|---|
| `F_NoSelfTransfer` | Runtime check + DB `CheckConstraint` + `HARDENED` comment | `SelfTransferError` in service |
| `F_AuthRequiredEverywhere` | JWT middleware dependency | `initiated_by` non-empty check |
| `F_ConservationOfValue` | `amount > 0`, `balances >= 0`, `available <= ledger` (code + DB) | `amount > 0` Pydantic validator |
| `F_SufficientFunds` | `check_sufficient_funds` before debit | `InsufficientFundsError` check |
| `F_ActiveAccountsOnly` | Rejects FROZEN/CLOSED accounts | Rejects frozen accounts only |
| `F_DailyLimitEnforcement` | Per-account daily limit with aggregate check | Not implemented |
| `F_OwnershipBasedAccess` | Customer → own accounts only (runtime + API) | Not implemented |
| `F_AttributionCorrectness` | Audit actor must match transfer initiator | Audit actor is the `initiated_by` string |
| `F_AuditCompleteness` | Minimum audit entry count enforced | Not enforced |
| `F_AppendOnlyAuditEntries` | Monotonic sequence + `UNIQUE` DB constraint | List append (no sequence numbers) |
| `F_HashChainIntegrity` | SHA-256 chain link validation | Not implemented |
| `F_FailClosedAudit` | No completed transfer without audit entries | Not implemented |
| `F_ReversalCompensating` | Reversal structure validation (swap, amount match) | Not implemented |
| `F_OwnershipExclusivity` | FK constraint: one owner per account | Owner is a string field |
| `F_FraudSignalConstraints` | Risk score [0, 1000], trigger rules required | Not implemented |
| `F_PermissionCompleteness` | `assert len(_ALLOWED_PAIRS) == 12` at import time | Not implemented |
| `F_LeastPrivilege` | 12-pair permission matrix | Not implemented |
| `F_NonEmptyUniverse` | Not applicable at runtime | Not applicable |
| `F_UniqueTransactionId` | UUID primary key | UUID primary key |

**Guided: 17/19 facts enforced at runtime. Baseline: 4/19 (partially).**

---

## 6. Test Comparison

### Guided — 184 test functions across 3 files + conftest

| Category | Count | Naming Convention | Example |
|---|---|---|---|
| Assertion tests | 69 | `test_assertion_<AssertionName>` | `test_assertion_least_privilege_customer_denied_ops` |
| Mutation regression | 12 | `test_mutation_<FactName>` | `test_mutation_f_no_self_transfer_catches_same_account` |
| KPI threshold | 35 | `test_kpi_<metric>` | `test_kpi_transfer_success_rate_threshold_value` |
| FR acceptance | 56 | `test_fr_NNN_<scenario>` | `test_fr_001_conservation_of_value_debit_equals_credit` |
| Cross-cutting | 12 | Various | `test_enum_completeness_roles`, `test_settings_defaults` |

Test fixtures: 8 lightweight stubs (StubUser, StubAccount, etc.) — no database needed.

### Baseline — 40 test functions across 4 files + conftest

| Category | Count | Naming Convention | Example |
|---|---|---|---|
| Model validation | 10 | `test_<model>_<aspect>` | `test_account_negative_balance_rejected` |
| Transfer service | 11 | `test_<scenario>` | `test_successful_transfer`, `test_self_transfer_rejected` |
| Audit service | 6 | `test_<scenario>` | `test_audit_log_is_append_only` |
| API integration | 13 | `test_<endpoint>_<case>` | `test_create_account`, `test_transfer_insufficient_funds` |

Test fixtures: 7 repository/service fixtures + TestClient.

**Key differences:**
- Guided has 4.6x more tests (184 vs 40)
- Guided categorizes tests by verification artifact (assertion, mutation, KPI, FR)
- Baseline categorizes by component (model, service, API)
- Guided has mutation regression tests reproducing Alloy injection violations
- Guided has KPI threshold tests verifying metric constants exist and are correct
- Baseline has zero tests for FRs 5-10 (since those features aren't implemented)

---

## 7. KPI Instrumentation

### Guided — 12 WAF-derived threshold constants + 16 Prometheus metrics

```python
# config.py — threshold constants
METRIC_TRANSFER_TRANSACTION_SUCCESS_RATE_THRESHOLD = 99.99    # FR-001, CO
METRIC_BALANCE_VALIDATION_ACCURACY_THRESHOLD = 99.0           # FR-002, CO
METRIC_UNIQUE_TRANSACTION_REFERENCE_ID_COUNT_THRESHOLD = 1.0  # FR-003, RE
METRIC_AUDIT_LOG_ENTRY_CREATION_SUCCESS_RATE_THRESHOLD = 95.0 # FR-004, CO
METRIC_SECURITY_ALERT_MTTD_MINUTES_THRESHOLD = 15.0           # FR-005, SE
METRIC_TRANSFER_LIMIT_ENFORCEMENT_RATE_THRESHOLD = 99.0       # FR-006, SE
METRIC_ANOMALY_DETECTION_MTTD_MINUTES_THRESHOLD = 15.0        # FR-007, RE
METRIC_ANOMALY_FALSE_POSITIVE_RATE_THRESHOLD = 5.0            # FR-007, RE
METRIC_MFA_IMPLEMENTATION_AUDIT_RATE_THRESHOLD = 100.0        # FR-007, RE
METRIC_READ_AFTER_WRITE_CONSISTENCY_RATE_THRESHOLD = 99.0     # FR-008, CO
METRIC_TRANSFER_REVERSAL_AUDIT_LINKAGE_PERCENTAGE_THRESHOLD = 95.0  # FR-009, SE
METRIC_IDENTIFIED_FAILURE_MODES_COUNT_THRESHOLD = 0.0         # FR-010, RE
```

Prometheus metrics are incremented at business logic execution points (transfer completion, audit creation, balance reads, fraud evaluation, etc.) with a `/metrics` scrape endpoint.

### Baseline — None

No KPI constants, no metrics library, no instrumentation, no observability.

---

## 8. Traceability

### Guided

Every artifact traces back to the formal specification:

```
Alloy fact F_NoSelfTransfer
    → invariants.py: check_no_self_transfer()   # raises InvariantViolation("F_NoSelfTransfer", ...)
    → models.py: CheckConstraint("source_account_id != destination_account_id")
    → transfer_service.py: # HARDENED: F_NoSelfTransfer
    → routes.py: # PATTERN: NoSelfMutation
    → test_assertions.py: TestMutationFNoSelfTransfer
    → test_acceptance.py: test_fr_001_self_transfer_rejected
```

Traceability markers used:
- `# PATTERN: <Name>` — 8 pattern comments in source
- `# HARDENED: F_<Name>` — 6 mutation hardening comments
- `Implements FR-NNN` — docstrings on service methods
- `InvariantViolation("F_<Name>", ...)` — exception carries fact name
- Test naming: `test_assertion_*`, `test_mutation_*`, `test_fr_NNN_*`, `test_kpi_*`

### Baseline

No traceability markers of any kind. No pattern comments, no FR references, no fact names, no mutation references. Code is functional but unlinked to any specification.

---

## 9. What the Baseline Does Well

Despite scoring lower, the baseline implementation has some positive qualities:

1. **Clean repository pattern** with abstract interfaces — more testable than the guided track's direct SQLAlchemy usage
2. **Thread-safe** in-memory storage (appropriate for its use case)
3. **Well-structured exception hierarchy** with semantic meaning
4. **Account freeze/unfreeze** — a feature the guided track also implements but via account status enum rather than a boolean flag
5. **Integration tests** using FastAPI `TestClient` — the guided track's tests are all unit-level stubs
6. **Simpler, more approachable** codebase — 1,530 lines vs 4,700 lines

---

## 10. Summary

| Dimension | Guided | Baseline | Delta |
|---|---|---|---|
| **Lines of code** | ~4,700 | ~1,530 | 3.1x larger |
| **FRs implemented** | 10/10 | 4/10 (partial) | +6 FRs |
| **Invariants enforced** | 17/19 | 4/19 | +13 invariants |
| **Test functions** | 184 | 40 | 4.6x more |
| **Pattern comments** | 8 | 0 | +8 |
| **HARDENED markers** | 6 | 0 | +6 |
| **KPI constants** | 12 | 0 | +12 |
| **Prometheus metrics** | 16 | 0 | +16 |
| **DB constraints** | 7 CHECK + FK + UNIQUE | 0 | +8 |
| **Auth mechanism** | JWT + RBAC (12-pair matrix) | String field check | Fundamentally different |
| **Audit sophistication** | SHA-256 hash chain, 14 event types | Plain list, 6 event types | +hash chain, +8 events |
| **Fraud detection** | Risk scoring, velocity, step-up auth | None | Entire subsystem |

The verification context provided to the guided track resulted in an implementation that is more complete (all 10 FRs), more secure (JWT + RBAC + fail-closed), more observable (Prometheus metrics with WAF-derived thresholds), and fully traceable to the formal specification. The cost is 3x more code and greater architectural complexity.
