// === feature_model.als — Alloy model for 004-loan-application-rbac ===
// Self-contained Alloy 6 model encoding the structural invariants of the
// loan-application feature: role-based access, claim/decide workflow,
// append-only audit trail, and customer-ownership-with-no-leakage.

// ============================================================
// SIGS
// ============================================================

abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationsList, GetApplication,
        PostClaim, PostDecision, GetAudit extends OperationKind {}

abstract sig DecisionType {}
one sig DTApproved, DTRejected extends DecisionType {}

abstract sig Outcome {}
one sig Success, Denied extends Outcome {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

abstract sig Verdict {}
one sig VNotFound, VPermissionDenied, VOkVisible extends Verdict {}

sig User { userRole: one Role }

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User,
  hasDecision: lone Decision
}

sig Decision {
  decisionType: one DecisionType,
  decidedBy: one User,
  decisionApp: one LoanApplication,
  reasonNonEmpty: one Bool
}

sig ApplicationEvent {
  eventApp: one LoanApplication,
  previousStatus: lone Status,
  newStatus: one Status,
  actor: one User
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication,
  authenticated: one Bool,
  outcome: one Outcome,
  producedEvent: lone ApplicationEvent,
  visibilityVerdict: lone Verdict,
  exposesOfficerIdentity: one Bool
}

one sig PermMatrix { Allowed: set Role -> OperationKind }

// ============================================================
// FACTS
// ============================================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
  some Operation
}

// Permission matrix from contracts/http-api.md authorization tables.
// 11 allow cells across 3 roles x 6 endpoints.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer -> PostApplications) +
    (Customer -> GetApplicationsList) +
    (Customer -> GetApplication) +
    (LoanOfficer -> GetApplicationsList) +
    (LoanOfficer -> GetApplication) +
    (LoanOfficer -> PostClaim) +
    (LoanOfficer -> PostDecision) +
    (LoanOfficer -> GetAudit) +
    (ComplianceReviewer -> GetApplicationsList) +
    (ComplianceReviewer -> GetApplication) +
    (ComplianceReviewer -> GetAudit)
}

fact F_CustomerIsCustomerRole {
  all la: LoanApplication | la.customer.userRole = Customer
}

fact F_AssignedOfficerIsLoanOfficer {
  all la: LoanApplication |
    some la.assignedOfficer implies la.assignedOfficer.userRole = LoanOfficer
}

fact F_AssignmentMatchesStatus {
  all la: LoanApplication | (no la.assignedOfficer) iff (la.status = Submitted)
}

fact F_DecisionExistsIffDecided {
  all la: LoanApplication |
    (some la.hasDecision) iff (la.status in (Approved + Rejected))
}

fact F_DecisionAppConsistent {
  all d: Decision | d.decisionApp.hasDecision = d
}

fact F_DecisionTypeMatchesStatus {
  all la: LoanApplication |
    la.status = Approved implies la.hasDecision.decisionType = DTApproved
  all la: LoanApplication |
    la.status = Rejected implies la.hasDecision.decisionType = DTRejected
}

fact F_DecisionByAssignedOfficer { /* MUTATED — body cleared by validator */ }

fact F_DecisionReasonNonEmpty {
  all d: Decision | d.reasonNonEmpty = BTrue
}

fact F_OneInFlightPerCustomer {
  all u: User | u.userRole = Customer implies
    (lone la: LoanApplication |
      la.customer = u and la.status in (Submitted + UnderReview))
}

fact F_InitialSubmissionEvent {
  all la: LoanApplication |
    (one e: ApplicationEvent |
      e.eventApp = la and no e.previousStatus and e.newStatus = Submitted)
}

fact F_ClaimEvent {
  all la: LoanApplication | la.status in (UnderReview + Approved + Rejected) implies
    (one e: ApplicationEvent |
      e.eventApp = la and e.previousStatus = Submitted and e.newStatus = UnderReview)
}

fact F_DecisionEvent {
  all la: LoanApplication | la.status in (Approved + Rejected) implies
    (one e: ApplicationEvent |
      e.eventApp = la and e.previousStatus = UnderReview and e.newStatus = la.status)
}

fact F_NoSpuriousEvents {
  all e: ApplicationEvent |
    (no e.previousStatus and e.newStatus = Submitted) or
    (e.previousStatus = Submitted and e.newStatus = UnderReview and
       e.eventApp.status in (UnderReview + Approved + Rejected)) or
    (e.previousStatus = UnderReview and e.newStatus = Approved and
       e.eventApp.status = Approved) or
    (e.previousStatus = UnderReview and e.newStatus = Rejected and
       e.eventApp.status = Rejected)
}

fact F_EventActorMatches {
  all e: ApplicationEvent |
    (no e.previousStatus) implies e.actor = e.eventApp.customer
  all e: ApplicationEvent |
    (e.previousStatus = Submitted and e.newStatus = UnderReview) implies
      e.actor = e.eventApp.assignedOfficer
  all e: ApplicationEvent |
    (e.previousStatus = UnderReview and e.newStatus in (Approved + Rejected)) implies
      e.actor = e.eventApp.hasDecision.decidedBy
}

fact F_EventNonTrivial {
  all e: ApplicationEvent |
    some e.previousStatus implies e.previousStatus != e.newStatus
}

fact F_AuthRequiredForSuccess {
  all op: Operation | op.outcome = Success implies op.authenticated = BTrue
}

fact F_SuccessRequiresPermission {
  all op: Operation |
    op.outcome = Success implies (op.caller.userRole -> op.kind) in PermMatrix.Allowed
}

fact F_DecisionRequiresAssignedOfficer {
  all op: Operation |
    (op.kind = PostDecision and op.outcome = Success) implies
      (some op.target and op.caller = op.target.assignedOfficer)
}

fact F_CustomerSuccessReadsOwnOnly {
  all op: Operation |
    (op.outcome = Success and op.caller.userRole = Customer and
     op.kind = GetApplication and some op.target) implies
      op.target.customer = op.caller
}

fact F_StateChangeProducesEvent {
  all op: Operation |
    (op.outcome = Success and op.kind in (PostApplications + PostClaim + PostDecision)) implies
      (some op.producedEvent)
  all op: Operation | (op.outcome = Denied) implies no op.producedEvent
  all op: Operation |
    (op.kind in (GetApplicationsList + GetApplication + GetAudit)) implies no op.producedEvent
}

fact F_EventHasOneOp {
  all e: ApplicationEvent | (one op: Operation | op.producedEvent = e)
}

fact F_OpEventConsistency {
  all op: Operation | some op.producedEvent implies
    (op.producedEvent.actor = op.caller and op.producedEvent.eventApp = op.target)
}

fact F_CustomerNonOwnedReturnsNotFound {
  all op: Operation |
    (op.kind = GetApplication and op.caller.userRole = Customer and
     op.authenticated = BTrue and some op.target and op.target.customer != op.caller) implies
      op.visibilityVerdict = VNotFound
}

fact F_NoOfficerIdentityToCustomer {
  all op: Operation |
    (op.caller.userRole = Customer and op.outcome = Success) implies
      op.exposesOfficerIdentity = BFalse
}

// ============================================================
// CATALOGUE PATTERNS
// ============================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // No operation reaches Success while unauthenticated.
  no op: Operation | op.outcome = Success and op.authenticated = BFalse
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002,003,004
pred LeastPrivilege {
  // Contrapositive form: no successful op has a (role, kind) pair outside the allow matrix.
  no op: Operation |
    op.outcome = Success and (op.caller.userRole -> op.kind) not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // The closed-world allow set has exactly the 11 cells dictated by the contract.
  #PermMatrix.Allowed = 11
  some LoanApplication
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-002,003,004,023 ground each cell
pred PermissionGrounding {
  // Every allow cell can be traced to a role's stated capability.
  Customer -> PostApplications in PermMatrix.Allowed         // FR-002
  LoanOfficer -> PostClaim in PermMatrix.Allowed             // FR-003
  LoanOfficer -> PostDecision in PermMatrix.Allowed          // FR-003
  ComplianceReviewer -> GetAudit in PermMatrix.Allowed       // FR-004/FR-023
  Customer -> PostClaim not in PermMatrix.Allowed            // FR-002 deny
  ComplianceReviewer -> PostDecision not in PermMatrix.Allowed // FR-004 deny
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer NOT NULL FK
pred OwnershipExclusivity {
  // Every loan application has exactly one customer-role owner; no orphans, no co-ownership.
  all la: LoanApplication | one la.customer and la.customer.userRole = Customer
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications
pred OwnershipBasedAccess {
  // No customer successfully reads an application whose customer is not them.
  no op: Operation |
    op.outcome = Success and op.caller.userRole = Customer and
    op.kind = GetApplication and some op.target and op.target.customer != op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md 404 not_found rule
pred NoInformationLeakage {
  // A customer asking about an existing-but-not-owned application sees NotFound,
  // not PermissionDenied — the two outcomes must be byte-identical to the outsider.
  all op: Operation |
    (op.kind = GetApplication and op.caller.userRole = Customer and
     op.authenticated = BTrue and some op.target and op.target.customer != op.caller) implies
      op.visibilityVerdict = VNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-009,011,015,017; data-model.md application_events
pred AuditCompleteness {
  // Every applied transition produces at least one matching audit event.
  all la: LoanApplication |
    (some e: ApplicationEvent | e.eventApp = la and no e.previousStatus and e.newStatus = Submitted)
  all la: LoanApplication | la.status in (UnderReview + Approved + Rejected) implies
    (some e: ApplicationEvent | e.eventApp = la and e.newStatus = UnderReview)
  all la: LoanApplication | la.status in (Approved + Rejected) implies
    (some e: ApplicationEvent | e.eventApp = la and e.newStatus = la.status)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  // No two distinct events describe the same (app, prev, new) transition — append-only
  // means each transition produces one row, never duplicated, never overwritten.
  all disj e1, e2: ApplicationEvent |
    not (e1.eventApp = e2.eventApp and
         e1.previousStatus = e2.previousStatus and
         e1.newStatus = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  // Each event's recorded actor matches the actual actor of the transition it records.
  all e: ApplicationEvent |
    (no e.previousStatus) implies e.actor = e.eventApp.customer
  all e: ApplicationEvent |
    (e.previousStatus = Submitted and e.newStatus = UnderReview) implies
      e.actor = e.eventApp.assignedOfficer
  all e: ApplicationEvent |
    (e.previousStatus = UnderReview and e.newStatus in (Approved + Rejected)) implies
      e.actor = e.eventApp.hasDecision.decidedBy
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012; data-model.md conditional UPDATE on claim
pred ConcurrencySafety {
  // Concurrent claim attempts resolve to at most one Submitted->UnderReview event per app.
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.eventApp = la and e.newStatus = UnderReview)
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-006,014; data-model.md atomic decision+status+audit
pred ValidationBeforeMutation {
  // No decision row exists with an empty reason — validation rejects empty reasons
  // before any persisted state is produced.
  no d: Decision | d.reasonNonEmpty = BFalse
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ============================================================
// FEATURE-SPECIFIC PER-FR PREDICATES
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required on every request
pred FR_001_AuthRequired {
  all op: Operation | op.outcome = Success implies op.authenticated = BTrue
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 customers cannot perform non-customer actions
pred FR_002_CustomerScope {
  no op: Operation |
    op.outcome = Success and op.caller.userRole = Customer and
    op.kind in (PostClaim + PostDecision + GetAudit)
}
assert FR_002_CustomerScope { FR_002_CustomerScope }
check FR_002_CustomerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 loan officers cannot submit applications as customers
pred FR_003_LoanOfficerScope {
  no op: Operation |
    op.outcome = Success and op.caller.userRole = LoanOfficer and op.kind = PostApplications
}
assert FR_003_LoanOfficerScope { FR_003_LoanOfficerScope }
check FR_003_LoanOfficerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 compliance reviewer is read-only
pred FR_004_ComplianceReadOnly {
  no op: Operation |
    op.outcome = Success and op.caller.userRole = ComplianceReviewer and
    op.kind in (PostApplications + PostClaim + PostDecision)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 customer identity taken from auth (not payload)
pred FR_005_CustomerIdentityFromAuth {
  // Every application's recorded customer has the customer role; no impersonation
  // of other roles as the submitter is structurally representable.
  all la: LoanApplication | la.customer.userRole = Customer
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 field-level validation reports
pred FR_006_ValidationConsistency {
  // Surrogate: persisted decisions never carry an empty reason (the validation
  // backstop for the one field-shape FR-014 calls out structurally).
  all d: Decision | d.reasonNonEmpty = BTrue
}
assert FR_006_ValidationConsistency { FR_006_ValidationConsistency }
check FR_006_ValidationConsistency for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 amount range / purpose length (status state machine surrogate)
pred FR_007_StateMachineWellFormed {
  // Every loan application's status is one of the four allowed values; no out-of-band states.
  all la: LoanApplication | la.status in (Submitted + UnderReview + Approved + Rejected)
  some LoanApplication
}
assert FR_007_StateMachineWellFormed { FR_007_StateMachineWellFormed }
check FR_007_StateMachineWellFormed for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight application per customer
pred FR_008_OneInFlightPerCustomer {
  no disj la1, la2: LoanApplication |
    la1.customer = la2.customer and
    la1.status in (Submitted + UnderReview) and
    la2.status in (Submitted + UnderReview)
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 successful submission writes the initial audit entry
pred FR_009_InitialSubmissionAudit {
  all la: LoanApplication |
    (some e: ApplicationEvent |
      e.eventApp = la and no e.previousStatus and e.newStatus = Submitted)
}
assert FR_009_InitialSubmissionAudit { FR_009_InitialSubmissionAudit }
check FR_009_InitialSubmissionAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 unassigned queue is exactly Submitted apps
pred FR_010_UnassignedQueueShape {
  // Submitted iff unassigned — the queue invariant the FR-010 listing relies on.
  all la: LoanApplication | (la.status = Submitted) iff (no la.assignedOfficer)
}
assert FR_010_UnassignedQueueShape { FR_010_UnassignedQueueShape }
check FR_010_UnassignedQueueShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 claim produces Submitted->UnderReview audit
pred FR_011_ClaimCreatesAudit {
  all la: LoanApplication | la.status in (UnderReview + Approved + Rejected) implies
    (some e: ApplicationEvent |
      e.eventApp = la and e.previousStatus = Submitted and e.newStatus = UnderReview)
}
assert FR_011_ClaimCreatesAudit { FR_011_ClaimCreatesAudit }
check FR_011_ClaimCreatesAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 at most one successful claimer per application
pred FR_012_OneClaimerPerApp {
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.eventApp = la and e.newStatus = UnderReview)
}
assert FR_012_OneClaimerPerApp { FR_012_OneClaimerPerApp }
check FR_012_OneClaimerPerApp for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 only the assigned officer decides
pred FR_013_OnlyAssignedOfficerDecides {
  all la: LoanApplication | some la.hasDecision implies
    la.hasDecision.decidedBy = la.assignedOfficer
  no op: Operation |
    op.outcome = Success and op.kind = PostDecision and
    some op.target and op.caller != op.target.assignedOfficer
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 decision reason must be non-empty
pred FR_014_NonEmptyReason {
  all d: Decision | d.reasonNonEmpty = BTrue
}
assert FR_014_NonEmptyReason { FR_014_NonEmptyReason }
check FR_014_NonEmptyReason for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 decision row, status, audit all written together
pred FR_015_DecisionPersistedAtomically {
  all la: LoanApplication | la.status in (Approved + Rejected) implies
    (some la.hasDecision and
     (some e: ApplicationEvent |
       e.eventApp = la and e.previousStatus = UnderReview and e.newStatus = la.status))
  all la: LoanApplication | la.status = Approved implies la.hasDecision.decisionType = DTApproved
  all la: LoanApplication | la.status = Rejected implies la.hasDecision.decisionType = DTRejected
}
assert FR_015_DecisionPersistedAtomically { FR_015_DecisionPersistedAtomically }
check FR_015_DecisionPersistedAtomically for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 no further status changes after Approved/Rejected
pred FR_016_NoChangeAfterDecided {
  // No event records a transition out of a decided state.
  no e: ApplicationEvent | e.previousStatus in (Approved + Rejected)
}
assert FR_016_NoChangeAfterDecided { FR_016_NoChangeAfterDecided }
check FR_016_NoChangeAfterDecided for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries carry actor / prev / new status
pred FR_017_AuditFieldsComplete {
  all e: ApplicationEvent | one e.actor and one e.newStatus
  all e: ApplicationEvent |
    some e.previousStatus implies e.previousStatus != e.newStatus
}
assert FR_017_AuditFieldsComplete { FR_017_AuditFieldsComplete }
check FR_017_AuditFieldsComplete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit trail is append-only
pred FR_018_AppendOnly {
  all disj e1, e2: ApplicationEvent |
    not (e1.eventApp = e2.eventApp and
         e1.previousStatus = e2.previousStatus and
         e1.newStatus = e2.newStatus)
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 exactly one audit entry per applied transition
pred FR_019_OneEntryPerChange {
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.eventApp = la and no e.previousStatus)
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.eventApp = la and e.previousStatus = Submitted)
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.eventApp = la and e.previousStatus = UnderReview)
}
assert FR_019_OneEntryPerChange { FR_019_OneEntryPerChange }
check FR_019_OneEntryPerChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 customer sees own only; no existence leak
pred FR_020_OwnershipAndNoLeak {
  no op: Operation |
    op.outcome = Success and op.kind = GetApplication and
    op.caller.userRole = Customer and
    some op.target and op.target.customer != op.caller
  all op: Operation |
    (op.kind = GetApplication and op.caller.userRole = Customer and
     op.authenticated = BTrue and some op.target and op.target.customer != op.caller) implies
      op.visibilityVerdict = VNotFound
}
assert FR_020_OwnershipAndNoLeak { FR_020_OwnershipAndNoLeak }
check FR_020_OwnershipAndNoLeak for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 officer identity is never exposed to customer
pred FR_021_OfficerIdentityHidden {
  no op: Operation |
    op.outcome = Success and op.caller.userRole = Customer and
    op.exposesOfficerIdentity = BTrue
}
assert FR_021_OfficerIdentityHidden { FR_021_OfficerIdentityHidden }
check FR_021_OfficerIdentityHidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-022 retention >= 6 years — no audit-row deletion path
pred FR_022_RetentionAppendOnly {
  // Surrogate: every persisted application still has its full event chain present;
  // deletion would manifest as a missing initial event.
  all la: LoanApplication | (some e: ApplicationEvent | e.eventApp = la)
}
assert FR_022_RetentionAppendOnly { FR_022_RetentionAppendOnly }
check FR_022_RetentionAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023 compliance role enforced at action level, not only UI
pred FR_023_ComplianceNoWrites {
  no op: Operation |
    op.outcome = Success and op.caller.userRole = ComplianceReviewer and
    op.kind in (PostApplications + PostClaim + PostDecision)
}
assert FR_023_ComplianceNoWrites { FR_023_ComplianceNoWrites }
check FR_023_ComplianceNoWrites for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NonAssignedDecider { some d: Decision | d.decidedBy != d.decisionApp.assignedOfficer }
