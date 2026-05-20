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
