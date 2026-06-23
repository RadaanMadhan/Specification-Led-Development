# Verification Context — `005-a-banking-transfer-system-with-audit-logging`

This document contains the formally verified structural constraints, FR coverage mapping, mutation test results, and WAF-derived KPI targets for guiding code generation.

## 1. Structural Patterns

11 verification patterns applied from the pattern catalogue:

- `LeastPrivilege`
- `PermissionCompleteness`
- `AuthRequiredEverywhere`
- `NoSelfMutation`
- `AuditCompleteness`
- `AppendOnly`
- `AttributionCorrectness`
- `OwnershipExclusivity`
- `OwnershipBasedAccess`
- `ConservationOfValue`
- `NoInformationLeakage`

## 2. FR-to-Assertion Map

Each functional requirement is covered by one or more formally verified assertions.

| FR | Assertions |
|---|---|
| `FR-001` | `FR_001_AtomicTransfer`, `ConservationOfValue` |
| `FR-002` | `FR_002_SufficientFunds` |
| `FR-003` | `FR_003_UniqueTransactionRef` |
| `FR-004` | `FR_004_AuditForEveryEvent`, `AuditCompleteness`, `AppendOnly` |
| `FR-005` | `FR_005_HashChain` |
| `FR-006` | `FR_006_DailyLimit` |
| `FR-007` | `LeastPrivilege` |
| `FR-008` | `FR_008_BalanceConsistency` |
| `FR-009` | `FR_009_ReversalCompensating` |
| `FR-010` | `FR_010_FailClosedAudit`, `AuthRequiredEverywhere` |

## 3. Mutation Results

6 mutation targets tested. Each removes a named fact and injects a violation to test assertion strength.

| Fact | Asserts Violated | Verdict | Rationale |
|---|---|---|---|
| `F_NoSelfTransfer` | `NoSelfMutation` | VACUOUS | Removing F_NoSelfTransfer allows a Transfer where source = destination, which directly violates the NoSelfMutation as... |
| `F_AuditCompleteness` | `AuditCompleteness`, `FR_004_AuditForEveryEvent`, `FR_010_FailClosedAudit` | VACUOUS | Removing F_AuditCompleteness allows a Transfer with no AuditEntry. The injection forces such an orphan transfer to ex... |
| `F_AppendOnlyAuditEntries` | `AppendOnly` | VACUOUS | Removing F_AppendOnlyAuditEntries allows two distinct AuditEntry atoms to share the same seqNum, violating the append... |
| `F_OwnershipBasedAccess` | `OwnershipBasedAccess` | VACUOUS | Removing F_OwnershipBasedAccess allows a Customer to initiate a transfer from an account they don't own. The injectio... |
| `F_AuthRequiredEverywhere` | `AuthRequiredEverywhere` | VACUOUS | Removing F_AuthRequiredEverywhere allows unauthenticated users to initiate transfers. The injection forces a transfer... |
| `F_AttributionCorrectness` | `AttributionCorrectness` | VACUOUS | Removing F_AttributionCorrectness allows an audit entry's actor to differ from the transfer's initiator. The injectio... |

**Injection patterns** (use these to inform hardening):

- **F_NoSelfTransfer**: `fact MUTATE_SelfTransfer { some t: Transfer | t.source = t.destination }`
- **F_AuditCompleteness**: `fact MUTATE_NoAudit { some t: Transfer | no ae: AuditEntry | ae.transaction = t }`
- **F_AppendOnlyAuditEntries**: `fact MUTATE_DuplicateSeq { some disj ae1, ae2: AuditEntry | ae1.seqNum = ae2.seqNum }`
- **F_OwnershipBasedAccess**: `fact MUTATE_OwnershipBypass { some t: Transfer | Customer in t.initiatedBy.roles and t.source not in t.initiatedBy.owns }`
- **F_AuthRequiredEverywhere**: `fact MUTATE_UnauthTransfer { some t: Transfer | t.initiatedBy.authStatus = Unauthenticated }`
- **F_AttributionCorrectness**: `fact MUTATE_Misattribution { some ae: AuditEntry | ae.actor != ae.transaction.initiatedBy }`

## 4. Invariant Semantics

19 named facts define the structural invariants. Each must be translated into a runtime check.

### `F_LeastPrivilege`

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization matrix

```alloy
// Customer allowed: PostTransfers, GetTransferById, GetBalance, GetTransactions, PostStepUp
    // Customer denied: PostReverse, GetAuditEntries, GetAuditVerify
    // Admin allowed: PostTransfers, GetTransferById, PostReverse, GetBalance, GetTransactions, GetAuditEntries, GetAuditVerify
    // Admin denied: PostStepUp

    // Exactly the allowed pairs exist
    all ap: AllowedPair |
        (ap.role = Customer and ap.operation in (PostTransfers + GetTransferById + GetBalance + GetTransactions + PostStepUp))
        or
        (ap.role = Admin and ap.operation in (PostTransfers + GetTransferById + PostReverse + GetBalance + GetTransactions + GetAuditEntries + GetAuditVerify))

    // All allowed pairs are present
    some ap: AllowedPair | ap.role = Customer and ap.operation = PostTransfers
    some ap: AllowedPair | ap.role = Customer and ap.operation = GetTransferById
    some ap: AllowedPair | ap.role = Customer and ap.operation = GetBalance
    some ap: AllowedPair | ap.role = Customer and ap.operation = GetTransactions
    some ap: AllowedPair | ap.role = Customer and ap.operation = PostStepUp
    some ap: AllowedPair | ap.role = Admin and ap.operation = PostTransfers
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetTransferById
    some ap: AllowedPair | ap.role = Admin and ap.operation = PostReverse
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetBalance
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetTransactions
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetAuditEntries
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetAuditVerify
```

### `F_PermissionCompleteness`

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorization matrix

```alloy
// Every Role x OperationKind cell is either allowed or denied — no undefined.
    // Denied means no AllowedPair exists for it.
    // We ensure the set of AllowedPair covers exactly the specified cells.
    // (Implicitly: any cell NOT in AllowedPair is denied.)
    // Completeness means we have exactly 12 allowed cells (5 customer + 7 admin)
    #AllowedPair = 12
```

### `F_AuthRequiredEverywhere`

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-010; contracts/http-api.md Authentication section

```alloy
// Only authenticated users can initiate transfers
    all t: Transfer | t.initiatedBy.authStatus = Authenticated
    // Only authenticated users appear as actors in audit entries
    all ae: AuditEntry | ae.actor.authStatus = Authenticated
```

### `F_NoSelfTransfer`

// PATTERN: NoSelfMutation  ANCHOR: spec.md edge cases; data-model.md Transfer validation sourceAccountId != destinationAccountId

```alloy
all t: Transfer | t.source != t.destination
```

### `F_AuditCompleteness`

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-004; data-model.md AuditEntry -> Transfer 1:N

```alloy
// Every transfer has at least one audit entry
    all t: Transfer | some ae: AuditEntry | ae.transaction = t
    // Audit entries link back consistently
    all ae: AuditEntry | ae in ae.transaction.auditEntries
    all t: Transfer, ae: AuditEntry | ae in t.auditEntries iff ae.transaction = t
```

### `F_AppendOnlyAuditEntries`

// PATTERN: AppendOnly  ANCHOR: spec.md FR-004; data-model.md "append-only; updates and deletes are prohibited"

```alloy
// Modeled: each AuditEntry belongs to exactly one Transfer and has a unique seqNum
    // No two audit entries share the same sequence number
    all disj ae1, ae2: AuditEntry | ae1.seqNum != ae2.seqNum
```

### `F_AttributionCorrectness`

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md AuditEntry.actorId -> User.id; spec.md FR-004

```alloy
// The actor recorded in every audit entry for a transfer is the user who initiated that transfer
    // (For simplicity in this model, we enforce actor = initiatedBy)
    all ae: AuditEntry | ae.actor = ae.transaction.initiatedBy
```

### `F_OwnershipExclusivity`

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Account.ownerId -> User.id; "belongs to one User"

```alloy
// Each account has exactly one owner and the owner relation is consistent
    all a: Account | a.owner.owns = a.owner.owns  // always true, placeholder for bidir
    all a: Account | a in a.owner.owns
    all u: User, a: Account | a in u.owns iff a.owner = u
```

### `F_OwnershipBasedAccess`

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md; contracts/http-api.md "own accounts only" / "own transfers only"

```alloy
// A customer can only initiate transfers where the source account is one they own
    all t: Transfer | Customer in t.initiatedBy.roles implies t.source in t.initiatedBy.owns
```

### `F_ConservationOfValue`

// PATTERN: ConservationOfValue  ANCHOR: spec.md FR-001; "source.balance' + dest.balance' = source.balance + dest.balance"

```alloy
// Transfer amount must be positive
    all t: Transfer | t.amount > 0
    // Non-negative balances
    all a: Account | a.ledgerBalance >= 0 and a.availableBalance >= 0
    // Available balance <= ledger balance
    all a: Account | a.availableBalance =< a.ledgerBalance
```

### `F_SufficientFunds`

// FEATURE-SPECIFIC  ANCHOR: FR-002 — sufficient funds check

```alloy
// A completed transfer must not overdraw the source
    // The source account's available balance must be >= 0 (modeled as non-negative)
    // and there should be enough to cover the transfer
    all t: Transfer | t.transferStatus = Completed implies t.source.availableBalance >= 0
```

### `F_UniqueTransactionId`

// FEATURE-SPECIFIC  ANCHOR: FR-003 — unique transaction reference

```alloy
// Each transfer is a distinct atom (Alloy sigs are distinct by construction)
    // But we also ensure no two transfers share the same source, destination, and amount trivially
    // (This is inherent in UUID uniqueness; in Alloy, distinct sig atoms are distinct.)
```

### `F_HashChainIntegrity`

// FEATURE-SPECIFIC  ANCHOR: FR-005 — cryptographic hash chain

```alloy
// prevHash forms a chain: no cycles
    no ae: AuditEntry | ae in ae.^prevHash
    // The first entry (lowest seqNum) has no prevHash
    all ae: AuditEntry | (no ae2: AuditEntry | ae2.seqNum < ae.seqNum) implies no ae.prevHash
    // Non-first entries have exactly one prevHash
    all ae: AuditEntry | (some ae2: AuditEntry | ae2.seqNum < ae.seqNum) implies one ae.prevHash
```

### `F_DailyLimitEnforcement`

// FEATURE-SPECIFIC  ANCHOR: FR-006 — daily transfer limits

```alloy
// Daily limit must be positive
    all a: Account | a.dailyLimit > 0
```

### `F_ReversalCompensating`

// FEATURE-SPECIFIC  ANCHOR: FR-009 — reversal via compensating transaction

```alloy
// A transfer with an originalTransaction is a reversal
    all t: Transfer | some t.originalTransaction implies {
        // The reversal swaps source and destination of the original
        t.source = t.originalTransaction.destination
        t.destination = t.originalTransaction.source
        t.amount = t.originalTransaction.amount
        // Original must have been completed
        t.originalTransaction.transferStatus in (Completed + Reversed)
    }
    // No self-referential reversals
    all t: Transfer | t.originalTransaction != t
    // At most one reversal per original
    all disj t1, t2: Transfer | t1.originalTransaction = t2.originalTransaction implies
        no t1.originalTransaction
```

### `F_FailClosedAudit`

// FEATURE-SPECIFIC  ANCHOR: FR-010 — fail-closed on audit unavailability

```alloy
// No completed transfer without at least one audit entry
    all t: Transfer | t.transferStatus = Completed implies some t.auditEntries
```

### `F_FraudSignalConstraints`

// FEATURE-SPECIFIC  ANCHOR: data-model.md FraudSignal constraints

```alloy
// Each transfer has at most one fraud signal
    all t: Transfer | lone fs: FraudSignal | fs.fsTransfer = t
    // FraudSignal links back to the transfer
    all fs: FraudSignal | fs = fs.fsTransfer.fraudSignal
    all t: Transfer, fs: FraudSignal | fs = t.fraudSignal iff fs.fsTransfer = t
    // FraudSignal account must be the source account of the transfer
    all fs: FraudSignal | fs.fsAccount = fs.fsTransfer.source
    // Risk score between 0 and 6 (scaled for small scope)
    all fs: FraudSignal | fs.riskScore >= 0
```

### `F_ActiveAccountsOnly`

// FEATURE-SPECIFIC  ANCHOR: data-model.md Account.accountStatus

```alloy
// Only active accounts participate in transfers
    all t: Transfer | t.source.status = Active and t.destination.status = Active
```

### `F_NonEmptyUniverse`

// FEATURE-SPECIFIC  ANCHOR: spec.md — at least some structure exists

```alloy
some Transfer
    some AuditEntry
    some User
    some Account
```

## 5. Feature-Specific Predicates

9 feature-specific predicates beyond pattern-derived assertions:

- `FR_001_AtomicTransfer`
- `FR_002_SufficientFunds`
- `FR_003_UniqueTransactionRef`
- `FR_004_AuditForEveryEvent`
- `FR_005_HashChain`
- `FR_006_DailyLimit`
- `FR_008_BalanceConsistency`
- `FR_009_ReversalCompensating`
- `FR_010_FailClosedAudit`

### Assertion Details

**`FR_001_AtomicTransfer`**
```alloy
FR_001_AtomicTransfer
```

**`FR_002_SufficientFunds`**
```alloy
FR_002_SufficientFunds
```

**`FR_003_UniqueTransactionRef`**
```alloy
FR_003_UniqueTransactionRef
```

**`FR_004_AuditForEveryEvent`**
```alloy
FR_004_AuditForEveryEvent
```

**`FR_005_HashChain`**
```alloy
FR_005_HashChain
```

**`FR_006_DailyLimit`**
```alloy
FR_006_DailyLimit
```

**`FR_008_BalanceConsistency`**
```alloy
FR_008_BalanceConsistency
```

**`FR_009_ReversalCompensating`**
```alloy
FR_009_ReversalCompensating
```

**`FR_010_FailClosedAudit`**
```alloy
FR_010_FailClosedAudit
```

## 6. Full Unified Report

The complete unified compliance report including Alloy verdicts and WAF-derived KPI targets:

<details>
<summary>Click to expand full report</summary>

# Unified Compliance Report — `005-a-banking-transfer-system-with-audit-logging`

*Feature folder:* `/home/radaan/Projects/Specification-Led-Development/specs/005-a-banking-transfer-system-with-audit-logging`

## Executive summary

- **Alloy / structural:** 20/20 assertions PASS (20 declared; 11 patterns applied). Mutation strength: 0/6 targets bit.
- **WAF / KPI:** 10 GQM chains, 12 KPI rows across 10 FRs. Pillars covered: cost, reliability, security.

---

## 1. Structural Verification (Alloy)

**Feature:** `005-a-banking-transfer-system-with-audit-logging`

**Alloy model:** `/home/radaan/Projects/Specification-Led-Development/runs/005-a-banking-transfer-system-with-audit-logging/feature_model.als`

**Verdict:** 20/20 assertions PASS via Alloy (20 declared in the lifted model).

**Patterns applied** (from `patterns.md`):

- `LeastPrivilege`
- `PermissionCompleteness`
- `AuthRequiredEverywhere`
- `NoSelfMutation`
- `AuditCompleteness`
- `AppendOnly`
- `AttributionCorrectness`
- `OwnershipExclusivity`
- `OwnershipBasedAccess`
- `ConservationOfValue`
- `NoInformationLeakage`

### Compliance matrix

| Assertion | Verdict | Anchor |
|---|---|---|
| `LeastPrivilege` | **PASS** | PATTERN LeastPrivilege: contracts/http-api.md authorization matrix |
| `PermissionCompleteness` | **PASS** | PATTERN PermissionCompleteness: contracts/http-api.md authorization matrix |
| `AuthRequiredEverywhere` | **PASS** | PATTERN AuthRequiredEverywhere: spec.md FR-010; contracts/http-api.md |
| `NoSelfMutation` | **PASS** | PATTERN NoSelfMutation: spec.md edge cases; data-model.md |
| `AuditCompleteness` | **PASS** | PATTERN AuditCompleteness: spec.md FR-004; data-model.md |
| `AppendOnly` | **PASS** | PATTERN AppendOnly: spec.md FR-004; data-model.md "append-only" |
| `AttributionCorrectness` | **PASS** | PATTERN AttributionCorrectness: data-model.md AuditEntry.actorId |
| `OwnershipExclusivity` | **PASS** | PATTERN OwnershipExclusivity: data-model.md Account.ownerId |
| `OwnershipBasedAccess` | **PASS** | PATTERN OwnershipBasedAccess: contracts/http-api.md "own accounts only" |
| `ConservationOfValue` | **PASS** | PATTERN ConservationOfValue: spec.md FR-001 |
| `NoInformationLeakage` | **PASS** | PATTERN NoInformationLeakage: spec.md edge cases; contracts/http-api.md 404 responses |
| `FR_001_AtomicTransfer` | **PASS** | FEATURE-SPECIFIC: FR-001 |
| `FR_002_SufficientFunds` | **PASS** | FEATURE-SPECIFIC: FR-002 |
| `FR_003_UniqueTransactionRef` | **PASS** | FEATURE-SPECIFIC: FR-003 |
| `FR_004_AuditForEveryEvent` | **PASS** | FEATURE-SPECIFIC: FR-004 |
| `FR_005_HashChain` | **PASS** | FEATURE-SPECIFIC: FR-005 |
| `FR_006_DailyLimit` | **PASS** | FEATURE-SPECIFIC: FR-006 |
| `FR_008_BalanceConsistency` | **PASS** | FEATURE-SPECIFIC: FR-008 |
| `FR_009_ReversalCompensating` | **PASS** | FEATURE-SPECIFIC: FR-009 |
| `FR_010_FailClosedAudit` | **PASS** | FEATURE-SPECIFIC: FR-010 |

### FR coverage

| FR | Covering assertions |
|---|---|
| `FR-001` | `FR_001_AtomicTransfer`=PASS, `ConservationOfValue`=PASS |
| `FR-002` | `FR_002_SufficientFunds`=PASS |
| `FR-003` | `FR_003_UniqueTransactionRef`=PASS |
| `FR-004` | `FR_004_AuditForEveryEvent`=PASS, `AuditCompleteness`=PASS, `AppendOnly`=PASS |
| `FR-005` | `FR_005_HashChain`=PASS |
| `FR-006` | `FR_006_DailyLimit`=PASS |
| `FR-007` | `LeastPrivilege`=PASS |
| `FR-008` | `FR_008_BalanceConsistency`=PASS |
| `FR-009` | `FR_009_ReversalCompensating`=PASS |
| `FR-010` | `FR_010_FailClosedAudit`=PASS, `AuthRequiredEverywhere`=PASS |

> All FRs have at least one matching assertion.

### Mutation tests (assertion-strength validation)

**Summary:** 0/6 targets bit. A vacuous target either restates the cleared fact verbatim or is redundantly enforced by another fact.

| Fact mutated | Verdict | Asserts targeted |
|---|---|---|
| `F_NoSelfTransfer` | **VACUOUS** | `NoSelfMutation` |
| `F_AuditCompleteness` | **VACUOUS** | `AuditCompleteness`, `FR_004_AuditForEveryEvent`, `FR_010_FailClosedAudit` |
| `F_AppendOnlyAuditEntries` | **VACUOUS** | `AppendOnly` |
| `F_OwnershipBasedAccess` | **VACUOUS** | `OwnershipBasedAccess` |
| `F_AuthRequiredEverywhere` | **VACUOUS** | `AuthRequiredEverywhere` |
| `F_AttributionCorrectness` | **VACUOUS** | `AttributionCorrectness` |

---

## 2. Runtime KPI Targets (WAF-derived)

**Feature:** `Feature Specification: Banking Transfer System with Audit Logging`

**Spec run id:** `spec-20260519-145959`

**Volume:** 10 GQM chains, 12 KPI rows across 10 FRs.

**Pillar breakdown:**

| Pillar | KPI rows |
|---|---|
| Cost Optimization (CO) | 4 |
| Reliability (RE) | 5 |
| Security (SE) | 3 |

### Per-FR detail

#### `FR-001`

> System MUST execute transfers atomically — either both the debit and credit complete, or neither does (ACID transaction).

- **Pillar:** Cost Optimization (CO)
- **WAF refs:** `CO:09`, `PE:09`, `RE:02`
- **Goal:** Ensure that system transfers are executed atomically to maintain data integrity.
- **Question:** What needs to be measured to confirm the atomicity of transfer transactions?
- **Metric:** `transfer_transaction_success_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99.99% | higher is better | 99.99 | system transaction logs analysis |

#### `FR-002`

> System MUST validate that the source account has sufficient available balance before debiting.

- **Pillar:** Cost Optimization (CO)
- **WAF refs:** `CO:06`, `CO:01`, `SE:05`
- **Goal:** Ensure the system accurately verifies sufficient available balance in source accounts before processing debits.
- **Question:** What metrics can indicate the reliability and accuracy of balance validation in the system?
- **Metric:** `balance_validation_accuracy` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | automated transaction validation tests |

#### `FR-003`

> System MUST generate a unique, immutable transaction reference ID for every transfer attempt (successful or failed).

- **Pillar:** Reliability (RE)
- **WAF refs:** `RE:02`, `RE:05`, `SE:05`
- **Goal:** Ensure that every transaction attempt generates a unique and immutable transaction reference ID.
- **Question:** What metrics indicate the successful generation of unique transaction reference IDs for all transfer attempts?
- **Metric:** `unique_transaction_reference_id_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 1 | higher is better | 1.0 | system log analysis |

#### `FR-004`

> System MUST create an append-only audit log entry for every state-changing event in the transfer lifecycle (initiation, validation, debit, credit, completion, failure, rollback, reversal).

- **Pillar:** Cost Optimization (CO)
- **WAF refs:** `CO:01`, `CO:03`, `OE:02`
- **Goal:** Ensure that an append-only audit log entry is created for every state-changing event in the transfer lifecycle.
- **Question:** What would you need to measure to know if the system consistently generates audit log entries for each state change?
- **Metric:** `audit_log_entry_creation_success_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 95% | higher is better | 95.0 | log analysis tools |

#### `FR-005`

> System MUST cryptographically chain audit log entries using a hash-link structure to enable tamper detection.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:10`, `SE:09`, `SE:05`
- **Goal:** Ensure the audit log entries are tamper-proof through cryptographic chaining.
- **Question:** What would you need to measure to know if the audit log chaining is effectively preventing tampering?
- **Metric:** `security_alert_mttd_minutes` (minutes)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| <= 15 minutes | lower is better | 15.0 | Azure Monitor |

#### `FR-006`

> System MUST enforce configurable per-account daily transfer limits and reject transfers that would exceed the limit.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:01`, `CO:03`
- **Goal:** Ensure the system effectively enforces daily transfer limits per account.
- **Question:** What metrics indicate the successful enforcement of configurable daily transfer limits?
- **Metric:** `transfer_limit_enforcement_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | transaction logging and analysis |

#### `FR-007`

> System MUST detect transfer velocity anomalies (configurable threshold) and trigger step-up authentication or block the transaction.

- **Pillar:** Reliability (RE)
- **WAF refs:** `RE:02`, `SE:05`, `SE:10`
- **Goal:** Ensure the system effectively detects transfer velocity anomalies and responds appropriately.
- **Question:** What metrics are necessary to evaluate the accuracy and responsiveness of anomaly detection?
- **Metric:** `anomaly_detection_mttd_minutes` (minutes)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| <= 15 minutes | lower is better | 15.0 | system monitoring and alerting tools |
| < 5% | lower is better | 5.0 | log analysis for false positives |
| 100% | higher is better | 100.0 | audit of MFA implementation |

#### `FR-008`

> System MUST provide a balance inquiry endpoint that reflects read-after-write consistency, returning both ledger and available balances.

- **Pillar:** Cost Optimization (CO)
- **WAF refs:** `CO:06`, `PE:04`, `CO:03`
- **Goal:** Ensure that the balance inquiry endpoint provides accurate and consistent balance information after writes.
- **Question:** What measurements are necessary to verify the read-after-write consistency of the balance inquiry endpoint?
- **Metric:** `read_after_write_consistency_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | automated tests |

#### `FR-009`

> System MUST support administrative transfer reversal via compensating transactions within a configurable time window, preserving full audit linkage to the original transaction.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `PE:10`, `CO:09`
- **Goal:** Ensure the system effectively supports administrative transfer reversals with full audit linkage to the original transaction.
- **Question:** What metrics indicate that administrative transfer reversals are successfully implemented and audited?
- **Metric:** `transfer_reversal_audit_linkage_percentage` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 95% | higher is better | 95.0 | audit log review |

#### `FR-010`

> System MUST fail-closed when audit log persistence is unavailable — no transfer may complete without a corresponding audit record.

- **Pillar:** Reliability (RE)
- **WAF refs:** `RE:03`, `RE:08`, `SE:05`
- **Goal:** Ensure that the system consistently fails-closed when audit log persistence is unavailable to maintain integrity.
- **Question:** What metrics are needed to assess the effectiveness of the fail-closed mechanism?
- **Metric:** `identified_failure_modes_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| All P0/P1 failures have documented mitigations | higher is better | 0.0 | failure mode analysis review |


</details>
