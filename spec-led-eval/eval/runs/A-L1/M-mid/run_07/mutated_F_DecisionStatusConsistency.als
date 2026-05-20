// === feature_model.als — Alloy model for Loan Application (A-L1) ===
// Feature folder : A-L1
// Spec           : spec.md (003-loan-application)
// Data model     : data-model.md
// Contract       : contracts/http-api.md

// ── Roles ──────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ── Operation kinds (API endpoints) ────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAudit extends OperationKind {}

// ── Permission matrix (singleton carrier) ──────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ── Application status ─────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, AppStatus_Approved, AppStatus_Rejected extends ApplicationStatus {}

// ── Event types ────────────────────────────────────────────────────────────
abstract sig EventType {}
one sig EvSubmitted, EvApproved, EvRejected extends EventType {}

// ── Decision types ─────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// ── Dynamic sigs ───────────────────────────────────────────────────────────
sig User { role: one Role }

sig LoanApplication {
  customer  : one User,
  status    : one ApplicationStatus,
  decision  : lone Decision
}

sig Decision {
  application  : one LoanApplication,
  decisionType : one DecisionType,
  decidedBy    : one User
}

sig AuditEntry {
  auditApp  : one LoanApplication,
  eventType : one EventType,
  actor     : one User
}

// An Operation models a single API call (caller, endpoint, optional target app).
sig Operation {
  caller    : one User,
  opKind    : one OperationKind,
  targetApp : lone LoanApplication
}

// ── F_NonEmptyUniverse ─────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some Operation
}

// ── Structural integrity facts ─────────────────────────────────────────────

fact F_ApplicationOwnedByCustomer {
  // All applications belong to a user with Customer role (FR-001).
  all a: LoanApplication | a.customer.role = Customer
}

fact F_DecisionOwnedByStaff {
  // All decisions are recorded by bank staff (FR-009, FR-015).
  all d: Decision | d.decidedBy.role = BankStaff
}

fact F_DecisionApplicationBijection {
  // decision field is the inverse of Decision.application — one-to-one.
  all d: Decision | d.application.decision = d
  all a: LoanApplication | lone a.decision
}

fact F_DecisionStatusConsistency { /* MUTATED — body cleared by validator */ }

fact F_OnePendingPerCustomer {
  // At most one PendingReview application per customer at a time (FR-005).
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
    not (a1.status = PendingReview and a2.status = PendingReview)
}

fact F_AuditAttribution {
  // Submitted events are attributed to the application's customer (FR-016).
  all ae: AuditEntry |
    ae.eventType = EvSubmitted implies ae.actor = ae.auditApp.customer
  // Approve/reject events are attributed to bank staff (FR-016).
  all ae: AuditEntry |
    (ae.eventType = EvApproved or ae.eventType = EvRejected) implies ae.actor.role = BankStaff
}

fact F_AuditCompletenessSubmit {
  // Every application has exactly one Submitted audit entry (FR-016).
  all a: LoanApplication |
    one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvSubmitted
}

fact F_AuditCompletenessDecision {
  // Every approved application has exactly one EvApproved entry; rejected → EvRejected (FR-016).
  all a: LoanApplication |
    a.status = AppStatus_Approved implies
    (one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvApproved)
  all a: LoanApplication |
    a.status = AppStatus_Rejected implies
    (one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvRejected)
  // No spurious decision events on pending applications.
  all ae: AuditEntry |
    ae.eventType = EvApproved implies ae.auditApp.status = AppStatus_Approved
  all ae: AuditEntry |
    ae.eventType = EvRejected implies ae.auditApp.status = AppStatus_Rejected
  // Approve events identify the decider correctly.
  all ae: AuditEntry |
    ae.eventType = EvApproved implies ae.actor = ae.auditApp.decision.decidedBy
  all ae: AuditEntry |
    ae.eventType = EvRejected implies ae.actor = ae.auditApp.decision.decidedBy
}

fact F_AppendOnly {
  // Each (application, eventType) pair appears at most once — no mutation or duplicate.
  all disj ae1, ae2: AuditEntry |
    ae1.auditApp = ae2.auditApp implies ae1.eventType != ae2.eventType
}

fact F_PermissionMatrix {
  // Exact permission matrix from contracts/http-api.md.
  PermMatrix.Allowed =
    (Customer  -> PostApplications)  +
    (Customer  -> GetApplications)   +
    (Customer  -> GetApplicationByRef) +
    (BankStaff -> GetApplications)   +
    (BankStaff -> GetApplicationByRef) +
    (BankStaff -> PostDecision)      +
    (BankStaff -> GetAudit)
}

fact F_OperationsRespectPermissions {
  // Every API call is by a role that is permitted to invoke that endpoint.
  all op: Operation | op.caller.role -> op.opKind in PermMatrix.Allowed
}

fact F_OwnershipBasedAccess {
  // Customers may only target their own applications (FR-013, SC-004).
  all op: Operation |
    (op.caller.role = Customer and op.opKind = GetApplicationByRef and some op.targetApp) implies
    op.targetApp.customer = op.caller
}

fact F_DecisionOnlyOnPending {
  // A PostDecision operation may only target a PendingReview application (FR-009, FR-011).
  all op: Operation |
    (op.opKind = PostDecision and some op.targetApp) implies
    op.targetApp.status = PendingReview
}

// ═══════════════════════════════════════════════════════════════════════════
// PATTERN PREDICATES
// ═══════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  // Customers never post decisions or access the audit trail.
  no op: Operation | op.caller.role = Customer and op.opKind = PostDecision
  no op: Operation | op.caller.role = Customer and op.opKind = GetAudit
  // Bank staff never submit loan applications.
  no op: Operation | op.caller.role = BankStaff and op.opKind = PostApplications
  some Operation
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Exactly 7 allowed cells: 3 for Customer, 4 for BankStaff.
  #(PermMatrix.Allowed) = 7
  // Customer block has exactly 3 allowed operations.
  #{ ok: OperationKind | Customer -> ok in PermMatrix.Allowed } = 3
  // BankStaff block has exactly 4 allowed operations.
  #{ ok: OperationKind | BankStaff -> ok in PermMatrix.Allowed } = 4
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001, FR-007, FR-008, FR-009, FR-013, FR-015, FR-016
pred PermissionGrounding {
  // Every allowed cell traces back to a spec FR.
  Customer  -> PostApplications    in PermMatrix.Allowed    // FR-001
  Customer  -> GetApplications     in PermMatrix.Allowed    // FR-013
  Customer  -> GetApplicationByRef in PermMatrix.Allowed    // FR-013
  BankStaff -> GetApplications     in PermMatrix.Allowed    // FR-007
  BankStaff -> GetApplicationByRef in PermMatrix.Allowed    // FR-008
  BankStaff -> PostDecision        in PermMatrix.Allowed    // FR-009
  BankStaff -> GetAudit            in PermMatrix.Allowed    // FR-016
  // Denied cells that must NOT appear.
  not (Customer  -> PostDecision  in PermMatrix.Allowed)    // FR-015
  not (Customer  -> GetAudit      in PermMatrix.Allowed)    // FR-015
  not (BankStaff -> PostApplications in PermMatrix.Allowed) // implicit FR-015
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md role descriptions; contracts/http-api.md permission matrix
pred PrivilegeMonotonicity {
  // BankStaff read-side permissions are a strict superset of Customer read-side.
  (Customer -> GetApplicationByRef in PermMatrix.Allowed) implies
    (BankStaff -> GetApplicationByRef in PermMatrix.Allowed)
  (Customer -> GetApplications in PermMatrix.Allowed) implies
    (BankStaff -> GetApplications in PermMatrix.Allowed)
  // BankStaff has strictly more allowed operations than Customer overall.
  #{ ok: OperationKind | BankStaff -> ok in PermMatrix.Allowed } >
  #{ ok: OperationKind | Customer  -> ok in PermMatrix.Allowed }
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md Authentication section; spec.md FR-001
pred AuthRequiredEverywhere {
  // Every operation has exactly one authenticated caller.
  all op: Operation | one op.caller
  some Operation
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvSubmitted
  all a: LoanApplication |
    a.status = AppStatus_Approved implies
    (one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvApproved)
  all a: LoanApplication |
    a.status = AppStatus_Rejected implies
    (one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvRejected)
  some LoanApplication
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-017; data-model.md "No UPDATE/DELETE"
pred AppendOnly {
  // Each (application, eventType) pair appears at most once; no overwrites.
  all disj ae1, ae2: AuditEntry |
    ae1.auditApp = ae2.auditApp implies ae1.eventType != ae2.eventType
  some AuditEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
pred AttributionCorrectness {
  // Submitted audit event actor must be the application's customer.
  all ae: AuditEntry |
    ae.eventType = EvSubmitted implies ae.actor = ae.auditApp.customer
  // Decision audit events must be attributed to bank staff.
  all ae: AuditEntry |
    ae.eventType = EvApproved implies ae.actor.role = BankStaff
  all ae: AuditEntry |
    ae.eventType = EvRejected implies ae.actor.role = BankStaff
  // Decision audit event actor must match the recorded decider.
  all ae: AuditEntry |
    ae.eventType = EvApproved implies ae.actor = ae.auditApp.decision.decidedBy
  all ae: AuditEntry |
    ae.eventType = EvRejected implies ae.actor = ae.auditApp.decision.decidedBy
  some AuditEntry
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id; spec.md FR-013
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.opKind = GetApplicationByRef and some op.targetApp) implies
    op.targetApp.customer = op.caller
  // Non-vacuous witness: at least one customer fetches their own application.
  some op: Operation | op.caller.role = Customer and op.opKind = GetApplicationByRef and some op.targetApp
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md 404 not 403
pred NoInformationLeakage {
  // No customer operation targets an application belonging to a different customer.
  no op: Operation |
    op.caller.role = Customer and
    op.opKind = GetApplicationByRef and
    some op.targetApp and
    op.targetApp.customer != op.caller
  some LoanApplication
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002; data-model.md validation.py
pred ValidationBeforeMutation {
  // Only applications that passed validation (customer role) exist in the system.
  all a: LoanApplication | a.customer.role = Customer
  // Pending applications carry no decision record (validation ensures no pre-inserted decision).
  all a: LoanApplication | a.status = PendingReview implies no a.decision
  some LoanApplication
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md conditional UPDATE
pred ConcurrencySafety {
  // At most one decision per application — no concurrent duplicates.
  all d1, d2: Decision | d1.application = d2.application implies d1 = d2
  all a: LoanApplication | lone a.decision
  some d: Decision | some d.application
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// ═══════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | one op.caller
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_ValidationAtSubmission {
  // Only valid (customer-owned) applications exist.
  all a: LoanApplication | a.customer.role = Customer
  some LoanApplication
}
assert FR_002_ValidationAtSubmission { FR_002_ValidationAtSubmission }
check FR_002_ValidationAtSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueReferencePerApplication {
  // Each LoanApplication atom is distinct (guaranteed by Alloy);
  // every application has exactly one customer and one status.
  all a: LoanApplication | one a.customer and one a.status
  some LoanApplication
}
assert FR_004_UniqueReferencePerApplication { FR_004_UniqueReferencePerApplication }
check FR_004_UniqueReferencePerApplication for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
    not (a1.status = PendingReview and a2.status = PendingReview)
  some LoanApplication
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_ConfirmationOnSubmit {
  // Every submitted application has exactly one EvSubmitted audit entry.
  all a: LoanApplication |
    one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvSubmitted
  some LoanApplication
}
assert FR_006_ConfirmationOnSubmit { FR_006_ConfirmationOnSubmit }
check FR_006_ConfirmationOnSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_StaffQueueAccess {
  // Bank staff are permitted to list applications.
  BankStaff -> GetApplications in PermMatrix.Allowed
}
assert FR_007_StaffQueueAccess { FR_007_StaffQueueAccess }
check FR_007_StaffQueueAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_StaffCanViewDetails {
  BankStaff -> GetApplicationByRef in PermMatrix.Allowed
}
assert FR_008_StaffCanViewDetails { FR_008_StaffCanViewDetails }
check FR_008_StaffCanViewDetails for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_DecisionReasonRequired {
  // Every decision has a bank-staff decider (reason is mandatory but unmodelled as string).
  all d: Decision | d.decidedBy.role = BankStaff
  all d: Decision | one d.decidedBy
  some Decision
}
assert FR_009_DecisionReasonRequired { FR_009_DecisionReasonRequired }
check FR_009_DecisionReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_DecisionPersisted {
  all a: LoanApplication |
    (a.status = AppStatus_Approved or a.status = AppStatus_Rejected) implies
    (one d: Decision | d = a.decision and d.decidedBy.role = BankStaff)
  some a: LoanApplication | a.status = AppStatus_Approved or a.status = AppStatus_Rejected
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_DecidedApplicationsImmutable {
  // An approved application has exactly one Approved-type decision; rejected likewise.
  all a: LoanApplication |
    a.status = AppStatus_Approved implies
    (one d: Decision | d = a.decision and d.decisionType = DecApproved)
  all a: LoanApplication |
    a.status = AppStatus_Rejected implies
    (one d: Decision | d = a.decision and d.decisionType = DecRejected)
  some a: LoanApplication | a.status = AppStatus_Approved or a.status = AppStatus_Rejected
}
assert FR_011_DecidedApplicationsImmutable { FR_011_DecidedApplicationsImmutable }
check FR_011_DecidedApplicationsImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NoConcurrentDecisions {
  // No two distinct Decision atoms point to the same LoanApplication.
  all d1, d2: Decision | d1.application = d2.application implies d1 = d2
  some Decision
}
assert FR_012_NoConcurrentDecisions { FR_012_NoConcurrentDecisions }
check FR_012_NoConcurrentDecisions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_CustomerIsolation {
  // Every customer operation that targets an application targets their own.
  all op: Operation |
    (op.caller.role = Customer and some op.targetApp) implies
    op.targetApp.customer = op.caller
  some op: Operation | op.caller.role = Customer and some op.targetApp
}
assert FR_013_CustomerIsolation { FR_013_CustomerIsolation }
check FR_013_CustomerIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_NotificationOnDecision {
  // Decided applications have a corresponding decision-type audit entry (proxy for notification).
  all a: LoanApplication |
    a.status = AppStatus_Approved implies
    (some ae: AuditEntry | ae.auditApp = a and ae.eventType = EvApproved)
  all a: LoanApplication |
    a.status = AppStatus_Rejected implies
    (some ae: AuditEntry | ae.auditApp = a and ae.eventType = EvRejected)
  some a: LoanApplication | a.status = AppStatus_Approved or a.status = AppStatus_Rejected
}
assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_StaffOnlyDecisionActions {
  // No customer can invoke PostDecision or GetAudit.
  all op: Operation |
    op.caller.role = Customer implies (op.opKind != PostDecision and op.opKind != GetAudit)
  // Bank staff can invoke PostDecision.
  some op: Operation | op.caller.role = BankStaff and op.opKind = PostDecision
}
assert FR_015_StaffOnlyDecisionActions { FR_015_StaffOnlyDecisionActions }
check FR_015_StaffOnlyDecisionActions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrailComplete {
  all a: LoanApplication |
    one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvSubmitted
  all a: LoanApplication |
    a.status = AppStatus_Approved implies
    (one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvApproved)
  all a: LoanApplication |
    a.status = AppStatus_Rejected implies
    (one ae: AuditEntry | ae.auditApp = a and ae.eventType = EvRejected)
  some LoanApplication
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_RetentionNoDelete {
  // Every application has its submitted audit entry, proving it was never removed.
  all a: LoanApplication |
    some ae: AuditEntry | ae.auditApp = a and ae.eventType = EvSubmitted
  some LoanApplication
}
assert FR_017_RetentionNoDelete { FR_017_RetentionNoDelete }
check FR_017_RetentionNoDelete for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_DecisionStatusViolation { some a: LoanApplication | a.status = AppStatus_Approved and no a.decision }
