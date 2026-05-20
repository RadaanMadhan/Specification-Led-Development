// === feature_model.als — Alloy model for Loan Application with Role-Based Workflow and Audit Trail ===
// Feature: 004-loan-application-rbac (A-L2)
// Self-contained Alloy 6 model encoding the spec.md / data-model.md / contracts/ invariants.

// -----------------------------------------------------------------------------
// STATIC ENUM-LIKE SIGS
// -----------------------------------------------------------------------------

abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

abstract sig OperationKind {}
one sig SubmitApp, ListApps, ViewApp, ClaimApp, DecideApp, ViewAudit extends OperationKind {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig Outcome {}
one sig Success, PermissionDeniedOutcome, NotFound, AlreadyClaimed,
        AlreadyDecided, NotAssignedOfficer extends Outcome {}

// -----------------------------------------------------------------------------
// DYNAMIC SIGS
// -----------------------------------------------------------------------------

sig User {
  role: one Role
}

sig LoanApplication {
  customer:        one User,
  status:          one Status,
  assignedOfficer: lone User,
  events:          set AuditEntry
}

sig Decision {
  application:  one LoanApplication,
  decidedBy:    one User,
  decisionType: one Status
}

sig AuditEntry {
  prevStatus: lone Status,
  newStatus:  one Status,
  actor:      one User
}

sig Operation {
  caller:  one User,
  kind:    one OperationKind,
  target:  lone LoanApplication,
  outcome: one Outcome
}

// Permission matrix as a singleton-sig field (Role -> OperationKind)
one sig PermMatrix { Allowed: set Role -> OperationKind }

// -----------------------------------------------------------------------------
// NON-EMPTY UNIVERSE (declared exactly once at the top)
// -----------------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Decision
  some Operation
}

// -----------------------------------------------------------------------------
// PERMISSION MATRIX (closed-world)
// Anchor: contracts/http-api.md "Permission matrix"
// -----------------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole          -> SubmitApp) +
    (CustomerRole          -> ListApps)  +
    (CustomerRole          -> ViewApp)   +
    (LoanOfficerRole       -> ListApps)  +
    (LoanOfficerRole       -> ViewApp)   +
    (LoanOfficerRole       -> ClaimApp)  +
    (LoanOfficerRole       -> DecideApp) +
    (LoanOfficerRole       -> ViewAudit) +
    (ComplianceReviewerRole-> ListApps)  +
    (ComplianceReviewerRole-> ViewApp)   +
    (ComplianceReviewerRole-> ViewAudit)
}

// Successful operations require the (role, kind) cell to be allowed.
// Anchor: spec.md FR-001/002/003/004; contracts/http-api.md authorisation tables.
fact F_OperationAuthorized {
  all op: Operation |
    op.outcome = Success implies op.caller.role -> op.kind in PermMatrix.Allowed
}

// -----------------------------------------------------------------------------
// ENTITY INVARIANTS
// -----------------------------------------------------------------------------

// Applications are owned by users whose role is customer.
// Anchor: data-model.md customer_id FK + role check
fact F_CustomerOwnsApp {
  all a: LoanApplication | a.customer.role = CustomerRole
}

// Assigned officer (when present) has role loan_officer.
// Anchor: data-model.md assigned_officer_id role check in service.py
fact F_AssignedIsOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficerRole
}

// status = Submitted iff no assigned officer (data-model.md CHECK constraint).
fact F_StatusAssignmentCoupled {
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

// Decision exists iff app is in Approved/Rejected.
// Anchor: data-model.md decisions PK is application_id; FR-015/016.
fact F_DecisionPresence {
  all d: Decision | d.application.status in (Approved + Rejected)
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies (one d: Decision | d.application = a)
}

// Decision type equals the resulting status (Approved/Rejected).
fact F_DecisionTypeMatchesStatus {
  all d: Decision | d.decisionType = d.application.status
}

// Only the assigned officer can be the decider (FR-013).
fact F_DecidedByAssigned {
  all d: Decision | d.decidedBy = d.application.assignedOfficer
}

// At most one in-flight application per customer (FR-008).
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.customer = a2.customer) implies
      not (a1.status in (Submitted + UnderReview) and
           a2.status in (Submitted + UnderReview))
}

// -----------------------------------------------------------------------------
// AUDIT TRAIL INVARIANTS
// -----------------------------------------------------------------------------

// Every AuditEntry belongs to exactly one LoanApplication.
fact F_AuditEventBelongsToOneApp {
  all e: AuditEntry | one a: LoanApplication | e in a.events
}

// Each app has exactly one "initial" event (no prevStatus); its newStatus = Submitted.
// Anchor: data-model.md CHECK ((previous_status IS NULL) = (new_status = 'Submitted'))
fact F_InitialEventStructure {
  all a: LoanApplication | (one e: a.events | no e.prevStatus)
  all e: AuditEntry | no e.prevStatus implies e.newStatus = Submitted
}

// Initial event's actor is the customer who submitted (FR-009 / FR-017).
fact F_InitialActorIsCustomer {
  all a: LoanApplication, e: a.events |
    no e.prevStatus implies e.actor = a.customer
}

// Only the three legal forward transitions are recordable.
// Anchor: data-model.md "state machine and audit-entry production"
fact F_ValidTransitions {
  all e: AuditEntry |
    some e.prevStatus implies
      ((e.prevStatus = Submitted    and e.newStatus = UnderReview) or
       (e.prevStatus = UnderReview  and e.newStatus in (Approved + Rejected)))
}

// The set of newStatuses on an app's events matches its journey-to-current-status.
// Anchor: FR-017 / FR-019; data-model.md "one row per applied transition".
fact F_AuditMatchesJourney {
  all a: LoanApplication {
    a.status = Submitted    implies a.events.newStatus = Submitted
    a.status = UnderReview  implies a.events.newStatus = (Submitted + UnderReview)
    a.status = Approved     implies a.events.newStatus = (Submitted + UnderReview + Approved)
    a.status = Rejected     implies a.events.newStatus = (Submitted + UnderReview + Rejected)
  }
}

// No two events record the same transition (newStatus) on the same application.
// Anchor: FR-018 append-only; FR-019 exactly-one-entry-per-change.
fact F_NoDuplicateEvents {
  all a: LoanApplication, disj e1, e2: a.events | e1.newStatus != e2.newStatus
}

// Non-initial events are authored by the assigned officer (claim + decide).
// Anchor: data-model.md actor_user_id semantics; FR-017.
fact F_AuditAttribution {
  all a: LoanApplication, e: a.events |
    some e.prevStatus implies e.actor = a.assignedOfficer
}

// -----------------------------------------------------------------------------
// ACCESS-CONTROL INVARIANTS ON OPERATIONS
// -----------------------------------------------------------------------------

// Decide operations require caller = assigned officer (FR-013).
fact F_DecideRequiresAssigned {
  all op: Operation |
    (op.kind = DecideApp and op.outcome = Success and some op.target) implies
      op.caller = op.target.assignedOfficer
}

// Customer ViewApp success requires ownership (FR-020).
fact F_CustomerViewsOwn { /* MUTATED — body cleared by validator */ }

// No information leakage: customer hitting a non-owned application sees NotFound,
// never PermissionDenied (FR-020; contracts/http-api.md).
fact F_NoLeakage {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = ViewApp and
     some op.target and op.target.customer != op.caller) implies
       op.outcome = NotFound
}

// =============================================================================
// CATALOGUE-PATTERN PREDICATES + ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-001..FR-004
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Documented allows are present
  CustomerRole          -> SubmitApp  in PermMatrix.Allowed
  CustomerRole          -> ListApps   in PermMatrix.Allowed
  CustomerRole          -> ViewApp    in PermMatrix.Allowed
  LoanOfficerRole       -> ClaimApp   in PermMatrix.Allowed
  LoanOfficerRole       -> DecideApp  in PermMatrix.Allowed
  LoanOfficerRole       -> ViewAudit  in PermMatrix.Allowed
  ComplianceReviewerRole-> ListApps   in PermMatrix.Allowed
  ComplianceReviewerRole-> ViewApp    in PermMatrix.Allowed
  ComplianceReviewerRole-> ViewAudit  in PermMatrix.Allowed
  // Documented denies are absent
  not (CustomerRole          -> ClaimApp  in PermMatrix.Allowed)
  not (CustomerRole          -> DecideApp in PermMatrix.Allowed)
  not (CustomerRole          -> ViewAudit in PermMatrix.Allowed)
  not (LoanOfficerRole       -> SubmitApp in PermMatrix.Allowed)
  not (ComplianceReviewerRole-> SubmitApp in PermMatrix.Allowed)
  not (ComplianceReviewerRole-> ClaimApp  in PermMatrix.Allowed)
  not (ComplianceReviewerRole-> DecideApp in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md "Authentication (all endpoints)"; FR-001
pred AuthRequiredEverywhere {
  all op: Operation |
    op.outcome = Success implies
      op.caller.role in (CustomerRole + LoanOfficerRole + ComplianceReviewerRole)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication {
    a.status = Submitted              implies #a.events = 1
    a.status = UnderReview            implies #a.events = 2
    a.status in (Approved + Rejected) implies #a.events = 3
  }
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  // Every audit entry belongs to exactly one application
  all e: AuditEntry | one a: LoanApplication | e in a.events
  // No duplicate audit entry for the same transition on the same application
  all a: LoanApplication, disj e1, e2: a.events | e1.newStatus != e2.newStatus
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
pred AttributionCorrectness {
  all a: LoanApplication, e: a.events {
    no e.prevStatus   implies e.actor = a.customer
    some e.prevStatus implies e.actor = a.assignedOfficer
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id FK
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer and a.customer.role = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications/{ref}
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = ViewApp and
     op.outcome = Success and some op.target) implies
       op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found, not 403"
pred NoInformationLeakage {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = ViewApp and
     some op.target and op.target.customer != op.caller) implies
       op.outcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// =============================================================================
// FEATURE-SPECIFIC FR ASSERTIONS
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required
pred FR_001_AuthRequired {
  all op: Operation |
    op.outcome = Success implies
      op.caller.role in (CustomerRole + LoanOfficerRole + ComplianceReviewerRole)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 customer scope
pred FR_002_CustomerScope {
  all op: Operation |
    (op.caller.role = CustomerRole and op.outcome = Success) implies
      op.kind in (SubmitApp + ListApps + ViewApp)
}
assert FR_002_CustomerScope { FR_002_CustomerScope }
check FR_002_CustomerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 loan officer scope
pred FR_003_LoanOfficerScope {
  all op: Operation |
    (op.caller.role = LoanOfficerRole and op.outcome = Success) implies
      op.kind in (ListApps + ViewApp + ClaimApp + DecideApp + ViewAudit)
}
assert FR_003_LoanOfficerScope { FR_003_LoanOfficerScope }
check FR_003_LoanOfficerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 compliance reviewer scope (read-only)
pred FR_004_ComplianceScope {
  all op: Operation |
    (op.caller.role = ComplianceReviewerRole and op.outcome = Success) implies
      op.kind in (ListApps + ViewApp + ViewAudit)
}
assert FR_004_ComplianceScope { FR_004_ComplianceScope }
check FR_004_ComplianceScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 customer identity from auth context
pred FR_005_CustomerIdentityFromAuth {
  all a: LoanApplication | a.customer.role = CustomerRole
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 validation (structural backstop via CHECK constraints — covered indirectly by status legality)
pred FR_006_ValidationStructural {
  // No application can be in a status outside the four legal values
  all a: LoanApplication | a.status in (Submitted + UnderReview + Approved + Rejected)
  // No audit entry records a transition that isn't in the legal set
  all e: AuditEntry |
    some e.prevStatus implies
      ((e.prevStatus = Submitted   and e.newStatus = UnderReview) or
       (e.prevStatus = UnderReview and e.newStatus in (Approved + Rejected)))
}
assert FR_006_ValidationStructural { FR_006_ValidationStructural }
check FR_006_ValidationStructural for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 amount/purpose range (structurally subsumed by status legality + role gating)
pred FR_007_DomainsClosed {
  all a: LoanApplication | a.status in (Submitted + UnderReview + Approved + Rejected)
  all d: Decision | d.decisionType in (Approved + Rejected)
}
assert FR_007_DomainsClosed { FR_007_DomainsClosed }
check FR_007_DomainsClosed for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight application per customer
pred FR_008_OneInFlight {
  all disj a1, a2: LoanApplication |
    (a1.customer = a2.customer) implies
      not (a1.status in (Submitted + UnderReview) and
           a2.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 initial submitted state + initial audit entry
pred FR_009_InitialState {
  all a: LoanApplication |
    (one e: a.events | no e.prevStatus and e.newStatus = Submitted and e.actor = a.customer)
}
assert FR_009_InitialState { FR_009_InitialState }
check FR_009_InitialState for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 unassigned queue is exactly the Submitted set (structural)
pred FR_010_UnassignedQueue {
  // The "queue" is exactly the apps where assigned officer is absent.
  all a: LoanApplication | (no a.assignedOfficer) iff (a.status = Submitted)
}
assert FR_010_UnassignedQueue { FR_010_UnassignedQueue }
check FR_010_UnassignedQueue for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 claim transition Submitted->UnderReview by assigned officer
pred FR_011_ClaimTransition {
  all a: LoanApplication |
    a.status in (UnderReview + Approved + Rejected) implies
      (one e: a.events | e.prevStatus = Submitted and
                         e.newStatus = UnderReview and
                         e.actor    = a.assignedOfficer)
}
assert FR_011_ClaimTransition { FR_011_ClaimTransition }
check FR_011_ClaimTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 exactly one assigned officer per claimed application
pred FR_012_ClaimUnique {
  all a: LoanApplication |
    a.status in (UnderReview + Approved + Rejected) implies one a.assignedOfficer
}
assert FR_012_ClaimUnique { FR_012_ClaimUnique }
check FR_012_ClaimUnique for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 only the assigned officer decides
pred FR_013_OnlyAssignedDecides {
  all d: Decision |
    d.decidedBy = d.application.assignedOfficer and d.decidedBy.role = LoanOfficerRole
  all op: Operation |
    (op.kind = DecideApp and op.outcome = Success and some op.target) implies
      op.caller = op.target.assignedOfficer
}
assert FR_013_OnlyAssignedDecides { FR_013_OnlyAssignedDecides }
check FR_013_OnlyAssignedDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 non-empty reason (structural backstop: a Decision exists only on decided apps with a recorded decider)
pred FR_014_DecisionWellFormed {
  all d: Decision |
    d.decisionType in (Approved + Rejected) and
    d.application.status = d.decisionType and
    d.decidedBy.role = LoanOfficerRole
}
assert FR_014_DecisionWellFormed { FR_014_DecisionWellFormed }
check FR_014_DecisionWellFormed for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 atomic: status change + decision row + audit entry together
pred FR_015_AtomicDecision {
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
      ((one d: Decision | d.application = a) and
       (one e: a.events | e.prevStatus = UnderReview and e.newStatus = a.status))
}
assert FR_015_AtomicDecision { FR_015_AtomicDecision }
check FR_015_AtomicDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 immutability after decision (no further events; decision type matches status)
pred FR_016_NoChangeAfterDecided {
  all a: LoanApplication | a.status in (Approved + Rejected) implies #a.events = 3
  all d: Decision | d.decisionType = d.application.status
}
assert FR_016_NoChangeAfterDecided { FR_016_NoChangeAfterDecided }
check FR_016_NoChangeAfterDecided for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entry for every status change
pred FR_017_AuditEveryChange {
  all a: LoanApplication {
    a.status = Submitted              implies #a.events = 1
    a.status = UnderReview            implies #a.events = 2
    a.status in (Approved + Rejected) implies #a.events = 3
  }
}
assert FR_017_AuditEveryChange { FR_017_AuditEveryChange }
check FR_017_AuditEveryChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit append-only
pred FR_018_AppendOnly {
  all e: AuditEntry | one a: LoanApplication | e in a.events
  all a: LoanApplication, disj e1, e2: a.events | e1.newStatus != e2.newStatus
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 exactly one audit entry per applied transition
pred FR_019_OneAuditPerChange {
  all a: LoanApplication, disj e1, e2: a.events | e1.newStatus != e2.newStatus
  all a: LoanApplication | (one e: a.events | no e.prevStatus)
}
assert FR_019_OneAuditPerChange { FR_019_OneAuditPerChange }
check FR_019_OneAuditPerChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 customer can only see their own applications
pred FR_020_CustomerSeeOwn {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = ViewApp and
     op.outcome = Success and some op.target) implies
       op.target.customer = op.caller
}
assert FR_020_CustomerSeeOwn { FR_020_CustomerSeeOwn }
check FR_020_CustomerSeeOwn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 officer identity hidden from customer (no audit access)
pred FR_021_OfficerHidden {
  not (CustomerRole -> ViewAudit in PermMatrix.Allowed)
}
assert FR_021_OfficerHidden { FR_021_OfficerHidden }
check FR_021_OfficerHidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-022 retention (no DELETE path; audit entries persist as long as the app)
pred FR_022_AuditRetained {
  all a: LoanApplication | some a.events
  all e: AuditEntry | one a: LoanApplication | e in a.events
}
assert FR_022_AuditRetained { FR_022_AuditRetained }
check FR_022_AuditRetained for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023 compliance reviewer has no write capability
pred FR_023_ComplianceReadOnly {
  not (ComplianceReviewerRole -> SubmitApp in PermMatrix.Allowed)
  not (ComplianceReviewerRole -> ClaimApp  in PermMatrix.Allowed)
  not (ComplianceReviewerRole -> DecideApp in PermMatrix.Allowed)
  all op: Operation |
    (op.caller.role = ComplianceReviewerRole and op.outcome = Success) implies
      op.kind in (ListApps + ViewApp + ViewAudit)
}
assert FR_023_ComplianceReadOnly { FR_023_ComplianceReadOnly }
check FR_023_ComplianceReadOnly for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OwnershipBasedAccessViolation { some op: Operation | op.caller.role = CustomerRole and op.kind = ViewApp and op.outcome = Success and some op.target and op.target.customer != op.caller }
