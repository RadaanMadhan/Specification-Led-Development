# Unified Compliance Report — `005-a-banking-transfer-system-with-audit-logging`

*Feature folder:* `C:\Users\Keshav\Desktop\TelecomParis\3A - MVA - Imperial College London\Microsoft group project\Specification-Led-Development\specs\005-a-banking-transfer-system-with-audit-logging`

## Executive summary

- **Alloy / structural:** 20/20 assertions PASS (20 declared; 11 patterns applied). Mutation strength: 0/6 targets bit.
- **WAF / KPI:** skipped.

---

## 1. Structural Verification (Alloy)

**Feature:** `005-a-banking-transfer-system-with-audit-logging`

**Alloy model:** `C:\Users\Keshav\Desktop\TelecomParis\3A - MVA - Imperial College London\Microsoft group project\Specification-Led-Development\runs\005-a-banking-transfer-system-with-audit-logging\feature_model.als`

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

_Skipped via `--skip-kpi`._
