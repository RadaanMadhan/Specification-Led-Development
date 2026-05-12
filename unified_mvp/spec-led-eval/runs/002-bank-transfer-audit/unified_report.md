# Unified Compliance Report — `002-bank-transfer-audit`

*Feature folder:* `/Users/leonhausmann/Imperial_College/teaching/term3/microsoft_spec_led_dev/testing/speckit_testing/speckit-trial/specs/002-bank-transfer-audit`

## Executive summary

- **Alloy / structural:** 24/26 assertions PASS (26 declared; 12 patterns applied). Mutation strength: 4/6 targets bit.
- **WAF / KPI:** 16 GQM chains, 17 KPI rows across 16 FRs. Pillars covered: cost, security.

---

## 1. Structural Verification (Alloy)

**Feature:** `002-bank-transfer-audit`

**Alloy model:** `/Users/leonhausmann/Imperial_College/teaching/term3/microsoft_spec_led_dev/testing/speckit_testing/unified_mvp/spec-led-eval/runs/002-bank-transfer-audit/feature_model.als`

**Verdict:** 24/26 assertions PASS via Alloy (26 declared in the lifted model).

**Patterns applied** (from `patterns.md`):

- `LeastPrivilege`
- `PermissionCompleteness`
- `PermissionGrounding`
- `PrivilegeMonotonicity`
- `AuthRequiredEverywhere`
- `AuditCompleteness`
- `AppendOnly`
- `AttributionCorrectness`
- `OwnershipExclusivity`
- `OwnershipBasedAccess`
- `NoSelfMutation`
- `NoInformationLeakage`

### Compliance matrix

| Assertion | Verdict | Anchor |
|---|---|---|
| `LeastPrivilege` | **PASS** | PATTERN LeastPrivilege: contracts/http-api.md authorization tables |
| `PermissionCompleteness` | **PASS** | PATTERN PermissionCompleteness: contracts/http-api.md permission tables |
| `AuthRequiredEverywhere` | **PASS** | PATTERN AuthRequiredEverywhere: FR-001; contracts/http-api.md auth section |
| `AuditCompleteness` | **PASS** | PATTERN AuditCompleteness: FR-009; data-model.md UNIQUE(transaction_id) |
| `AppendOnly` | **PASS** | PATTERN AppendOnly: FR-010; data-model.md "no UPDATE/DELETE" |
| `AttributionCorrectness` | **PASS** | PATTERN AttributionCorrectness: FR-011; data-model.md audit-entry fields |
| `OwnershipExclusivity` | **PASS** | PATTERN OwnershipExclusivity: data-model.md — Account owned by exactly one User |
| `OwnershipBasedAccess` | **PASS** | PATTERN OwnershipBasedAccess: FR-003, FR-006; contracts/http-api.md |
| `NoSelfMutation` | **PASS** | PATTERN NoSelfMutation: FR-008, FR-012; data-model.md CHECK constraint |
| `NoInformationLeakage` | **FAIL** | PATTERN NoInformationLeakage: FR-015; contracts/http-api.md GET /transfers/{id} |
| `FR_001_AuthRequired` | **PASS** | FEATURE-SPECIFIC: FR-001 |
| `FR_002_OneRolePerUser` | **PASS** | FEATURE-SPECIFIC: FR-002 |
| `FR_003_OwnerSourceOnly` | **PASS** | FEATURE-SPECIFIC: FR-003 |
| `FR_004_AuditorReadOnly` | **PASS** | FEATURE-SPECIFIC: FR-004 |
| `FR_005_AdminFullAccess` | **PASS** | FEATURE-SPECIFIC: FR-005 |
| `FR_006_OwnerReadOnly` | **PASS** | FEATURE-SPECIFIC: FR-006 |
| `FR_007_AuditLogRestricted` | **PASS** | FEATURE-SPECIFIC: FR-007 |
| `FR_008_DistinctAccounts` | **PASS** | FEATURE-SPECIFIC: FR-008 |
| `FR_009_OneAuditPerTransfer` | **PASS** | FEATURE-SPECIFIC: FR-009 |
| `FR_010_AuditAppendOnly` | **PASS** | FEATURE-SPECIFIC: FR-010 |
| `FR_011_AuditCaptures` | **PASS** | FEATURE-SPECIFIC: FR-011 |
| `FR_012_ValidationNoSelfTransfer` | **PASS** | FEATURE-SPECIFIC: FR-012 (validation — no self-transfer, positive amount) |
| `FR_015_NoLeakage` | **FAIL** | FEATURE-SPECIFIC: FR-015 |
| `FR_016_ExactlyThreeEndpoints` | **PASS** | FEATURE-SPECIFIC: FR-016 — exactly three endpoints |
| `PermissionGrounding` | **PASS** | PATTERN PermissionGrounding: spec.md FRs; contracts/http-api.md |
| `PrivilegeMonotonicity` | **PASS** | PATTERN PrivilegeMonotonicity: spec.md — admin ⊇ auditor read perms, admin ⊇ AH |

### Counterexamples (Alloy SAT)

Each failing assertion has at least one structurally-valid world inside the Alloy scope that violates the invariant.

- **`NoInformationLeakage`** — PATTERN NoInformationLeakage: FR-015; contracts/http-api.md GET /transfers/{id}
  - Alloy: `09. check NoInformationLeakage     0    1/1     SAT`
- **`FR_015_NoLeakage`** — FEATURE-SPECIFIC: FR-015
  - Alloy: `22. check FR_015_NoLeakage         0    1/1     SAT`

### FR coverage

| FR | Covering assertions |
|---|---|
| `FR-001` | `FR_001_AuthRequired`=PASS, `AuthRequiredEverywhere`=PASS |
| `FR-002` | `FR_002_OneRolePerUser`=PASS |
| `FR-003` | `FR_003_OwnerSourceOnly`=PASS, `OwnershipBasedAccess`=PASS |
| `FR-004` | `FR_004_AuditorReadOnly`=PASS, `LeastPrivilege`=PASS |
| `FR-005` | `FR_005_AdminFullAccess`=PASS, `PrivilegeMonotonicity`=PASS |
| `FR-006` | `FR_006_OwnerReadOnly`=PASS |
| `FR-007` | `FR_007_AuditLogRestricted`=PASS, `LeastPrivilege`=PASS |
| `FR-008` | `FR_008_DistinctAccounts`=PASS, `NoSelfMutation`=PASS |
| `FR-009` | `FR_009_OneAuditPerTransfer`=PASS, `AuditCompleteness`=PASS |
| `FR-010` | `FR_010_AuditAppendOnly`=PASS, `AppendOnly`=PASS |
| `FR-011` | `FR_011_AuditCaptures`=PASS, `AttributionCorrectness`=PASS |
| `FR-012` | `FR_012_ValidationNoSelfTransfer`=PASS |
| `FR-013` | `AuditCompleteness`=PASS |
| `FR-014` | `AuditCompleteness`=PASS |
| `FR-015` | `FR_015_NoLeakage`=FAIL, `NoInformationLeakage`=FAIL |
| `FR-016` | `FR_016_ExactlyThreeEndpoints`=PASS |

> All FRs have at least one matching assertion.

### Mutation tests (assertion-strength validation)

**Summary:** 4/6 targets bit. A vacuous target either restates the cleared fact verbatim or is redundantly enforced by another fact.

| Fact mutated | Verdict | Asserts targeted |
|---|---|---|
| `F_AppendOnlyAuditEntries` | **VACUOUS** | `AppendOnly`, `FR_010_AuditAppendOnly` |
| `F_NoSelfTransfer` | **BIT** | `NoSelfMutation`, `FR_008_DistinctAccounts`, `FR_012_ValidationNoSelfTransfer` |
| `F_OwnershipTransferRestriction` | **BIT** | `OwnershipBasedAccess`, `FR_003_OwnerSourceOnly` |
| `F_AuditorCannotTransfer` | **BIT** | `FR_004_AuditorReadOnly` |
| `F_AuditAttribution` | **BIT** | `AttributionCorrectness`, `FR_011_AuditCaptures` |
| `F_AuthRequired` | **VACUOUS** | `AuthRequiredEverywhere`, `FR_001_AuthRequired` |

---

## 2. Runtime KPI Targets (WAF-derived)

**Feature:** `Feature Specification: Bank Transfer with Audit Trail (PoC)`

**Spec run id:** `spec-20260512-104549`

**Volume:** 16 GQM chains, 17 KPI rows across 16 FRs.

**Pillar breakdown:**

| Pillar | KPI rows |
|---|---|
| Cost Optimization (CO) | 2 |
| Security (SE) | 15 |

### Per-FR detail

#### `FR-001`

> System MUST require valid authentication on every request to POST /transfers, GET /transfers/{id}, and GET /audit. Requests without valid authentication MUST be rejected before any authorization or business logic runs.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `SE:07`, `SE:09`
- **Goal:** Ensure that all API requests to POST /transfers, GET /transfers/{id}, and GET /audit are authenticated before processing.
- **Question:** What would you need to measure to know if the system enforces valid authentication consistently?
- **Metric:** `auth_coverage_percentage` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| 100% | higher is better | 100.0 | API gateway logging and monitoring |

#### `FR-002`

> System MUST associate every authenticated caller with exactly one role from the set {account_holder, auditor, admin}.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `SE:04`, `SE:12`
- **Goal:** Ensure all authenticated callers are correctly assigned a role to enforce access control.
- **Question:** What metrics indicate that each user has a correct and unique role assignment?
- **Metric:** `auth_role_assignment_accuracy` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 95% | higher is better | 95.0 | automated access logs review |

#### `FR-003`

> System MUST allow a caller with role account_holder to initiate a transfer **only** when the source account is owned by that caller. Attempts to initiate a transfer from an account the caller does not own MUST be rejected with an authorization error and MUST NOT create a Transaction or an AuditEntry.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:01`, `SE:12`
- **Goal:** Ensure that account holders can only initiate transfers from their own accounts to maintain security.
- **Question:** What metrics indicate whether only authorized account holders are able to initiate transfers?
- **Metric:** `transfer_authorization_error_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | Audit logs review and error tracking |

#### `FR-004`

> System MUST allow a caller with role auditor to read any transfer and to read the audit log. System MUST reject any attempt by an auditor to initiate a transfer with an authorization error.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:04`, `CO:01`
- **Goal:** Ensure that auditors can access the necessary information while being restricted from unauthorized actions.
- **Question:** What metrics indicate that auditors can read transfers and logs without initiating unauthorized transfers?
- **Metric:** `auth_coverage_percentage` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 100% | higher is better | 100.0 | Identity Access Management Audit |
| 0 | lower is better | 0 | Audit Log Analysis |

#### `FR-005`

> System MUST allow a caller with role admin to initiate transfers between any two valid accounts and to read any transfer and the audit log.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `RE:02`, `CO:01`
- **Goal:** Ensure that only admin users can initiate transfers and access audit logs securely.
- **Question:** What needs to be measured to confirm that the access control for admin users is appropriately enforced?
- **Metric:** `privileged_access_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| <= 5 | lower is better | 5 | audit logs review |

#### `FR-006`

> System MUST allow a caller with role account_holder to read a transfer via GET /transfers/{id} **only** when that transfer involves at least one account owned by the caller. Other transfers MUST be inaccessible to that caller.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:01`, `RE:02`
- **Goal:** Ensure that account holders can only access their relevant transfers through the API.
- **Question:** What metrics need to be measured to confirm that account holders are restricted to their transfers?
- **Metric:** `access_control_accuracy` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99.9% | higher is better | 99.9 | audit log analysis |

#### `FR-007`

> System MUST forbid every role other than auditor and admin from reading the audit log. account_holder requests to GET /audit MUST be rejected with an authorization error.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:04`, `SE:09`
- **Goal:** Ensure that only auditor and admin roles have access to read the audit log as required.
- **Question:** What metrics can indicate the effectiveness of access controls to the audit log?
- **Metric:** `unauthorized_access_attempts_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| gte 0 | higher is better | 0.0 | Monitoring access logs for unsuccessful audit log access attempts |

#### `FR-008`

> Every successful transfer MUST debit exactly one Account (the source) and credit exactly one Account (the destination). Source and destination MUST be different accounts.

- **Pillar:** Cost Optimization (CO)
- **WAF refs:** `CO:09`, `CO:01`, `RE:05`
- **Goal:** Ensure that every successful transfer correctly debits one source account and credits one different destination account.
- **Question:** What metrics would indicate the correctness and reliability of transfer operations?
- **Metric:** `successful_transfer_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99.5% | higher is better | 99.5 | transaction monitoring and analysis |

#### `FR-009`

> Every successful transfer MUST produce exactly one AuditEntry, and that AuditEntry MUST be linked to that Transaction. No successful transfer may produce zero AuditEntries or more than one AuditEntry.

- **Pillar:** Cost Optimization (CO)
- **WAF refs:** `CO:01`, `SE:05`, `CO:09`
- **Goal:** Ensure that every successful transfer consistently results in the creation of exactly one AuditEntry linked to a Transaction.
- **Question:** What metrics can verify that the system produces exactly one AuditEntry for each successful transfer?
- **Metric:** `successful_transfer_auditentry_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| = 1 | higher is better | 1.0 | automated audit log analysis |

#### `FR-010`

> AuditEntries MUST be append-only. The system MUST NOT expose any operation that updates or deletes an existing AuditEntry through any role, including admin.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `SE:09`, `SE:07`
- **Goal:** Ensure that AuditEntries are strictly append-only and immutable by controlling access appropriately.
- **Question:** What measures can confirm that no AuditEntry can be updated or deleted by any user role?
- **Metric:** `unauthorized_audit_entry_modifications_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| == 0 | lower is better | 0.0 | Audit logging analysis |

#### `FR-011`

> Each AuditEntry MUST capture, at minimum: the Transaction it refers to, the identity of the caller who initiated the transfer, the role that caller acted under, and the time the action was recorded.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `SE:07`, `CO:03`
- **Goal:** Ensure that each AuditEntry captures the required information defined in FR-011.
- **Question:** What metrics would indicate that all AuditEntries are capturing the necessary details as specified?
- **Metric:** `AuditEntry completeness percentage` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 100% | higher is better | 100.0 | automated data validation tool |

#### `FR-012`

> System MUST reject transfer requests that are invalid on their face (non-positive amount, missing or unknown source/destination account, identical source and destination) with a validation error. No Transaction or AuditEntry MUST be created for a rejected request.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `RE:02`, `RE:03`
- **Goal:** Ensure the system effectively rejects invalid transfer requests without creating transactions or audit entries.
- **Question:** What would you need to measure to know if the system is properly rejecting invalid transfer requests?
- **Metric:** `invalid_transfer_request_rejection_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | system logs analysis |

#### `FR-013`

> System MUST reject transfer requests that would overdraw the source account's available balance. No Transaction or AuditEntry MUST be created in that case.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:01`, `CO:03`
- **Goal:** Ensure that the system accurately rejects transfer requests that would overdraw the source account's available balance.
- **Question:** What percentage of transfer requests that would overdraw the account are correctly rejected without creating a transaction or audit entry?
- **Metric:** `transfer_request_rejection_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | Automated test reporting |

#### `FR-014`

> System MUST ensure that concurrent transfer initiations against the same source account do not jointly produce a state inconsistent with FR-008, FR-009, or FR-013 (e.g., negative balance, missing audit entry, duplicate audit entry).

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `CO:01`, `CO:09`
- **Goal:** Ensure the system maintains consistency during concurrent transfer initiations to prevent negative balances or audit discrepancies.
- **Question:** What metrics would indicate the system's ability to handle concurrent transfer requests without creating inconsistencies?
- **Metric:** `concurrent_transfer_consistency_success_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | automated transaction validation tests |

#### `FR-015`

> For an account_holder caller, GET /transfers/{id} responses for transfers they are not permitted to read MUST NOT distinguish "not found" from "exists but not yours" — the response MUST not leak the existence of other users' transfers.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `SE:07`, `CO:01`
- **Goal:** Ensure that the API does not leak information about the existence of unauthorized transfers.
- **Question:** What metrics indicate if the API responses correctly anonymize access to transfers?
- **Metric:** `unauthorized_transfer_error_rate` (percentage)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 99% | higher is better | 99.0 | API logging and monitoring |

#### `FR-016`

> System MUST expose exactly the three endpoints in scope: POST /transfers, GET /transfers/{id}, GET /audit. No additional endpoint may be introduced that bypasses the permission or audit invariants above.

- **Pillar:** Security (SE)
- **WAF refs:** `SE:05`, `SE:07`, `SE:04`
- **Goal:** Ensure the system strictly adheres to exposing only the specified API endpoints.
- **Question:** What metrics will confirm that only the allowed API endpoints are exposed and access is properly managed?
- **Metric:** `endpoint_exposure_count` (count)

| Threshold | Direction | Numeric | Measurement |
|---|---|---|---|
| >= 3 | higher is better | 3.0 | API gateway monitoring |
