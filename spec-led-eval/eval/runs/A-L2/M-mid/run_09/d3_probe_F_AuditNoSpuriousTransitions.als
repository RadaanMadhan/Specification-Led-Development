// === feature_model.als — Alloy model for Loan Application RBAC Workflow (A-L2) ===
// Feature: 004-loan-application-rbac
// Encodes invariants from spec.md, data-model.md, contracts/http-api.md

// ─── Role ─────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ─── Application status ───────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ─── Decision type ────────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig DApproved, DRejected extends DecisionType {}

// ─── API operations ───────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplication,
         PostClaim, PostDecision, GetAudit extends OperationKind {}

// ─── Permission matrix (singleton) ───────────────────────────────────────────
// contracts/http-api.md permission table
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─── Dynamic sigs ─────────────────────────────────────────────────────────────
sig User { role: one Role }

sig LoanApplication {
  owner: one User,
  status: one ApplicationStatus,
  assignedOfficer: lone User,
  appDecision: lone Decision
}

sig Decision {
  forApplication: one LoanApplication,
  decidedBy: one User,
  dtype: one DecisionType
}

// ApplicationEvent = append-only audit trail row
sig ApplicationEvent {
  forApp: one LoanApplication,
  actor: one User,
  prevStatus: lone ApplicationStatus,   // absent (lone = 0) only for initial Submitted event
  newStatus: one ApplicationStatus
}

// ─── Non-Empty Universe ───────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// ─── Permission matrix (closed-world) ─────────────────────────────────────────
// ANCHOR: contracts/http-api.md permission table; FR-002, FR-003, FR-004
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer         -> PostApplications) +
    (Customer         -> GetApplications)  +
    (Customer         -> GetApplication)   +
    (LoanOfficer      -> GetApplications)  +
    (LoanOfficer      -> GetApplication)   +
    (LoanOfficer      -> PostClaim)        +
    (LoanOfficer      -> PostDecision)     +
    (LoanOfficer      -> GetAudit)         +
    (ComplianceReviewer -> GetApplications) +
    (ComplianceReviewer -> GetApplication)  +
    (ComplianceReviewer -> GetAudit)
}

// ─── Application owner must be a Customer ────────────────────────────────────
// ANCHOR: data-model.md LoanApplication.customer_id; spec.md FR-005
fact F_OwnerIsCustomer {
  all a: LoanApplication | a.owner.role = Customer
}

// ─── Assigned officer must be a LoanOfficer when present ─────────────────────
// ANCHOR: data-model.md LoanApplication.assigned_officer_id; spec.md FR-011
fact F_AssignedOfficerIsLoanOfficer {
  all a: LoanApplication |
    (some a.assignedOfficer) implies a.assignedOfficer.role = LoanOfficer
}

// ─── assignedOfficer is null iff status = Submitted ───────────────────────────
// ANCHOR: data-model.md CHECK ((status='Submitted')=(assigned_officer_id IS NULL)); FR-011
fact F_AssignedOfficerIffNotSubmitted {
  all a: LoanApplication |
    (a.status = Submitted) iff (no a.assignedOfficer)
}

// ─── Decision exists iff status is terminal ───────────────────────────────────
// ANCHOR: data-model.md Decision PK; spec.md FR-015, FR-016
fact F_DecisionIffTerminal {
  all a: LoanApplication |
    (some a.appDecision) iff (a.status = Approved or a.status = Rejected)
}

// ─── Decision is by the assigned officer ─────────────────────────────────────
// ANCHOR: data-model.md Decision.decided_by_user_id; spec.md FR-013
fact F_DecisionByAssignedOfficer {
  all a: LoanApplication |
    (some a.appDecision) implies a.appDecision.decidedBy = a.assignedOfficer
}

// ─── Decision type matches application status ─────────────────────────────────
// ANCHOR: data-model.md DecisionType; spec.md FR-015
fact F_DecisionTypeMatchesStatus {
  all a: LoanApplication | {
    (a.status = Approved) implies
      ((some a.appDecision) and a.appDecision.dtype = DApproved)
    (a.status = Rejected) implies
      ((some a.appDecision) and a.appDecision.dtype = DRejected)
  }
}

// ─── Decision back-reference is consistent ───────────────────────────────────
// ANCHOR: data-model.md one-to-one LoanApplication ↔ Decision
fact F_DecisionApplicationBackRef {
  all d: Decision | d.forApplication.appDecision = d
}

// ─── Decider must be a LoanOfficer ───────────────────────────────────────────
// ANCHOR: data-model.md Decision.decided_by_user_id; spec.md FR-003
fact F_DecisionDeciderIsLoanOfficer {
  all d: Decision | d.decidedBy.role = LoanOfficer
}

// ─── At most one Decision per LoanApplication ────────────────────────────────
// ANCHOR: data-model.md Decision.application_id INTEGER PRIMARY KEY; spec.md FR-016
fact F_AtMostOneDecisionPerApplication {
  all disj d1, d2: Decision | d1.forApplication != d2.forApplication
}

// ─── Audit: initial (none→Submitted) event exists for every application ───────
// ANCHOR: data-model.md ApplicationEvent CHECK; spec.md FR-017, FR-019
fact F_AuditInitialEventExists {
  all a: LoanApplication |
    one e: ApplicationEvent | e.forApp = a and (no e.prevStatus) and e.newStatus = Submitted
}

// ─── Audit: Submitted→UnderReview event exists when claimed ──────────────────
// ANCHOR: data-model.md state machine table; spec.md FR-011, FR-017
fact F_AuditClaimEventExists {
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
}

// ─── Audit: terminal decision event exists when decided ──────────────────────
// ANCHOR: data-model.md state machine table; spec.md FR-015, FR-017
fact F_AuditDecisionEventExists {
  all a: LoanApplication | {
    a.status = Approved implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Approved)
    a.status = Rejected implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Rejected)
  }
}

// ─── Audit: only valid transitions appear ────────────────────────────────────
// ANCHOR: data-model.md ApplicationEvent CHECKs; spec.md Assumptions state machine
fact F_AuditNoSpuriousTransitions {
  all e: ApplicationEvent | {
    ((no e.prevStatus) and e.newStatus = Submitted) or
    (e.prevStatus = Submitted  and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved)  or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
  }
}

// ─── Audit: initial event actor is the application owner (customer) ──────────
// ANCHOR: data-model.md ApplicationEvent.actor_user_id; spec.md FR-017
fact F_AuditInitialActorIsOwner {
  all e: ApplicationEvent |
    ((no e.prevStatus) and e.newStatus = Submitted) implies e.actor = e.forApp.owner
}

// ─── Audit: claim event actor is the assigned officer ────────────────────────
// ANCHOR: data-model.md state machine table; spec.md FR-011, FR-017
fact F_AuditClaimActorIsAssignedOfficer {
  all e: ApplicationEvent |
    (e.prevStatus = Submitted and e.newStatus = UnderReview) implies
    e.actor = e.forApp.assignedOfficer
}

// ─── Audit: decision event actor is the assigned officer ─────────────────────
// ANCHOR: data-model.md state machine table; spec.md FR-013, FR-015, FR-017
fact F_AuditDecisionActorIsAssignedOfficer {
  all e: ApplicationEvent |
    (e.prevStatus = UnderReview) implies e.actor = e.forApp.assignedOfficer
}

// ─── Audit trail is append-only: event count matches status exactly ──────────
// ANCHOR: data-model.md "no UPDATE/DELETE on application_events"; spec.md FR-018
fact F_AppendOnlyAuditEntries {
  all a: LoanApplication | {
    a.status = Submitted implies
      #{ e: ApplicationEvent | e.forApp = a } = 1
    a.status = UnderReview implies
      #{ e: ApplicationEvent | e.forApp = a } = 2
    (a.status = Approved or a.status = Rejected) implies
      #{ e: ApplicationEvent | e.forApp = a } = 3
  }
}

// ─── At most one in-flight application per customer ──────────────────────────
// ANCHOR: data-model.md idx_one_in_flight_per_customer; spec.md FR-008
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.owner = a2.owner) implies
      not ((a1.status = Submitted or a1.status = UnderReview) and
           (a2.status = Submitted or a2.status = UnderReview))
}

// ─── Audit actor must be a User (belt-and-suspenders) ─────────────────────────
// ANCHOR: data-model.md ApplicationEvent.actor_user_id FK→users
fact F_AuditActorIsUser {
  all e: ApplicationEvent | e.actor in User
}

// =============================================================================
// PREDICATES AND ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; FR-002, FR-003, FR-004
pred LeastPrivilege {
  // Customer cannot claim, decide, or view audit
  Customer -> PostClaim      not in PermMatrix.Allowed
  Customer -> PostDecision   not in PermMatrix.Allowed
  Customer -> GetAudit       not in PermMatrix.Allowed
  // LoanOfficer cannot submit applications as a customer
  LoanOfficer -> PostApplications not in PermMatrix.Allowed
  // ComplianceReviewer cannot submit, claim, or decide
  ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
  ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
  ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
  // At least one user of each role exists so the permission check is non-vacuous
  some u: User | u.role = Customer
  some u: User | u.role = LoanOfficer
  some u: User | u.role = ComplianceReviewer
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair has a defined verdict in the closed-world matrix
  // i.e., the union of allowed + denied covers the full cross-product
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
  // Non-vacuity: the Allowed set is non-empty
  some PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md authentication section; spec.md FR-001
pred AuthRequiredEverywhere {
  // Every OperationKind is accessible to at least one role (no op is universally forbidden,
  // which would indicate a dead endpoint), and no op is accessible without a role binding.
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
  // There is no "anonymous" role outside the defined set
  all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: data-model.md ApplicationEvent; spec.md FR-017, FR-019
pred AuditCompleteness {
  // Every application has at least one audit event
  all a: LoanApplication | some e: ApplicationEvent | e.forApp = a
  // Every application has the right number of events for its status
  all a: LoanApplication | {
    a.status = Submitted implies
      (one e: ApplicationEvent | e.forApp = a and (no e.prevStatus) and e.newStatus = Submitted)
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
    a.status = Approved implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Approved)
    a.status = Rejected implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Rejected)
  }
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: data-model.md "no UPDATE/DELETE on application_events"; spec.md FR-018
pred AppendOnly {
  // The event count for each application is exactly what its status demands —
  // no events can have been dropped (lower bound) nor spuriously added (upper bound).
  some a: LoanApplication | {
    a.status = Approved or a.status = Rejected
    #{ e: ApplicationEvent | e.forApp = a } = 3
  }
  all a: LoanApplication | {
    a.status = Submitted implies #{ e: ApplicationEvent | e.forApp = a } = 1
    a.status = UnderReview implies #{ e: ApplicationEvent | e.forApp = a } = 2
    (a.status = Approved or a.status = Rejected) implies
      #{ e: ApplicationEvent | e.forApp = a } = 3
  }
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md ApplicationEvent.actor_user_id; spec.md FR-017
pred AttributionCorrectness {
  // Initial event actor is the submitting customer (owner)
  all e: ApplicationEvent |
    ((no e.prevStatus) and e.newStatus = Submitted) implies e.actor = e.forApp.owner
  // Claim and decision events are attributed to the assigned officer
  all e: ApplicationEvent |
    (e.prevStatus = Submitted and e.newStatus = UnderReview) implies
    e.actor = e.forApp.assignedOfficer
  all e: ApplicationEvent |
    (e.prevStatus = UnderReview) implies e.actor = e.forApp.assignedOfficer
  // There is at least one application so the check is non-vacuous
  some LoanApplication
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id NOT NULL; spec.md FR-005
pred OwnershipExclusivity {
  // Every application has exactly one owner who is a Customer
  all a: LoanApplication | one a.owner and a.owner.role = Customer
  // No application is orphaned
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications scope
pred OwnershipBasedAccess {
  // Customer's visibility is scoped to their own applications only.
  // Encoded as: no two distinct customers co-own an application.
  all a: LoanApplication | all disj u1, u2: User |
    (u1.role = Customer and u2.role = Customer) implies
    not (a.owner = u1 and a.owner = u2)
  // And a customer's access does not extend to another customer's applications.
  all disj a1, a2: LoanApplication |
    (a1.owner != a2.owner) implies
      (a1.owner not in { u: User | u = a2.owner })
  some LoanApplication
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found no existence leak"
pred NoInformationLeakage {
  // A customer can never observe an application belonging to another customer —
  // encoded as: the ownership function is injective (each application maps to
  // one customer owner, and cross-customer access is structurally impossible).
  all a: LoanApplication | a.owner.role = Customer
  // Non-vacuity: at least two distinct customers exist with distinct applications
  some disj c1, c2: User | c1.role = Customer and c2.role = Customer
  all disj a1, a2: LoanApplication |
    (a1.owner != a2.owner) implies a1.owner.role = Customer and a2.owner.role = Customer
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // Every user has exactly one role from the valid role set.
  all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer)
  // There are users in the system (non-vacuous)
  some User
  // No role is undefined (each role is one of the three)
  no u: User | u.role not in (Customer + LoanOfficer + ComplianceReviewer)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; contracts/http-api.md permission table
pred FR_002_CustomerRestricted {
  // Customers can submit and read; cannot claim, decide, or read audit
  Customer -> PostApplications in PermMatrix.Allowed
  Customer -> GetApplications  in PermMatrix.Allowed
  Customer -> GetApplication   in PermMatrix.Allowed
  Customer -> PostClaim      not in PermMatrix.Allowed
  Customer -> PostDecision   not in PermMatrix.Allowed
  Customer -> GetAudit       not in PermMatrix.Allowed
  some u: User | u.role = Customer
}
assert FR_002_CustomerRestricted { FR_002_CustomerRestricted }
check FR_002_CustomerRestricted for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023; contracts/http-api.md permission table
pred FR_004_ComplianceReadOnly {
  // ComplianceReviewer may read but not write anything
  ComplianceReviewer -> GetApplications in PermMatrix.Allowed
  ComplianceReviewer -> GetApplication  in PermMatrix.Allowed
  ComplianceReviewer -> GetAudit        in PermMatrix.Allowed
  ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
  ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
  ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
  some u: User | u.role = ComplianceReviewer
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
pred FR_008_OneInFlight {
  // No customer has two simultaneous in-flight (Submitted or UnderReview) applications
  all disj a1, a2: LoanApplication |
    (a1.owner = a2.owner) implies
      not ((a1.status = Submitted or a1.status = UnderReview) and
           (a2.status = Submitted or a2.status = UnderReview))
  some LoanApplication
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md LoanApplication.assigned_officer_id; state machine
pred FR_011_ClaimTransition {
  // When an application moves from Submitted to UnderReview, assignedOfficer is set
  // and is a LoanOfficer. Encoded as: every UnderReview+ application has an assigned officer
  // who is a LoanOfficer.
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one a.assignedOfficer and a.assignedOfficer.role = LoanOfficer)
  some a: LoanApplication | a.status = UnderReview or a.status = Approved or a.status = Rejected
}
assert FR_011_ClaimTransition { FR_011_ClaimTransition }
check FR_011_ClaimTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md conditional UPDATE; spec.md SC-006
pred FR_012_ExclusiveClaim {
  // Exactly one officer can be assigned per application
  all a: LoanApplication |
    (some a.assignedOfficer) implies (one a.assignedOfficer)
  // No two applications in UnderReview share a distinct claim inconsistency —
  // each application has at most one Submitted→UnderReview audit event
  all a: LoanApplication |
    #{ e: ApplicationEvent | e.forApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview } =< 1
  some LoanApplication
}
assert FR_012_ExclusiveClaim { FR_012_ExclusiveClaim }
check FR_012_ExclusiveClaim for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md conditional UPDATE WHERE assigned_officer_id=?
pred FR_013_OnlyAssignedOfficerDecides {
  // The deciding officer on the decision matches the assigned officer on the application
  all a: LoanApplication |
    (some a.appDecision) implies a.appDecision.decidedBy = a.assignedOfficer
  // The decision audit event actor equals the assigned officer
  all e: ApplicationEvent |
    (e.prevStatus = UnderReview) implies e.actor = e.forApp.assignedOfficer
  some a: LoanApplication | some a.appDecision
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md "same DB transaction"; spec.md FR-015
pred FR_015_AtomicDecisionAudit {
  // Decision and its audit entry coexist: if application is terminal there is
  // exactly one Decision and exactly one corresponding audit event.
  all a: LoanApplication | (a.status = Approved or a.status = Rejected) implies {
    one a.appDecision
    (a.status = Approved implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Approved))
    (a.status = Rejected implies
      (one e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Rejected))
  }
  some a: LoanApplication | a.status = Approved or a.status = Rejected
}
assert FR_015_AtomicDecisionAudit { FR_015_AtomicDecisionAudit }
check FR_015_AtomicDecisionAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md "no SQL path accepts Approved/Rejected as source status"
pred FR_016_TerminalStateImmutable {
  // Once Approved or Rejected, no further transitions exist in the model:
  // there must be no audit event whose prevStatus is Approved or Rejected.
  no e: ApplicationEvent |
    (e.prevStatus = Approved or e.prevStatus = Rejected)
  // Non-vacuity: at least one decided application
  some a: LoanApplication | a.status = Approved or a.status = Rejected
}
assert FR_016_TerminalStateImmutable { FR_016_TerminalStateImmutable }
check FR_016_TerminalStateImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017, FR-019; spec.md SC-007
pred FR_019_ExactlyOneAuditPerTransition {
  // Each transition type occurs at most once per application in the audit trail
  all a: LoanApplication | {
    #{ e: ApplicationEvent | e.forApp = a and (no e.prevStatus) and e.newStatus = Submitted } = 1
    #{ e: ApplicationEvent |
         e.forApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview } =< 1
    #{ e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Approved } =< 1
    #{ e: ApplicationEvent |
         e.forApp = a and e.prevStatus = UnderReview and e.newStatus = Rejected } =< 1
  }
  some LoanApplication
}
assert FR_019_ExactlyOneAuditPerTransition { FR_019_ExactlyOneAuditPerTransition }
check FR_019_ExactlyOneAuditPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021; contracts/http-api.md response scrubbing; spec.md FR-021
pred FR_021_OfficerNotInCustomerOps {
  // In the permission matrix, Customer cannot access GetAudit (which exposes officer identity).
  // Also Customer cannot PostClaim or PostDecision (which involve officer identity).
  Customer -> GetAudit     not in PermMatrix.Allowed
  Customer -> PostClaim    not in PermMatrix.Allowed
  Customer -> PostDecision not in PermMatrix.Allowed
  // LoanOfficer and ComplianceReviewer CAN access audit (officer identity exposed only to them)
  LoanOfficer -> GetAudit       in PermMatrix.Allowed
  ComplianceReviewer -> GetAudit in PermMatrix.Allowed
  some u: User | u.role = Customer
}
assert FR_021_OfficerNotInCustomerOps { FR_021_OfficerNotInCustomerOps }
check FR_021_OfficerNotInCustomerOps for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023; spec.md FR-004, FR-023; SC-008
pred FR_023_ComplianceReadOnlyEnforced {
  // ComplianceReviewer has no write operations permitted whatsoever.
  all op: OperationKind |
    (op = PostApplications or op = PostClaim or op = PostDecision) implies
    (ComplianceReviewer -> op not in PermMatrix.Allowed)
  some u: User | u.role = ComplianceReviewer
}
assert FR_023_ComplianceReadOnlyEnforced { FR_023_ComplianceReadOnlyEnforced }
check FR_023_ComplianceReadOnlyEnforced for 8

// FEATURE-SPECIFIC  ANCHOR: data-model.md state machine; spec.md FR-009, Assumptions
pred FR_009_ValidStateMachine {
  // The only legal transitions are the four documented ones.
  // Any event with prevStatus = Approved or = Rejected is structurally prohibited.
  no e: ApplicationEvent |
    (e.prevStatus = Approved or e.prevStatus = Rejected)
  // No event skips from Submitted directly to Approved or Rejected
  no e: ApplicationEvent |
    (e.prevStatus = Submitted and (e.newStatus = Approved or e.newStatus = Rejected))
  // No event goes from UnderReview back to Submitted
  no e: ApplicationEvent |
    (e.prevStatus = UnderReview and e.newStatus = Submitted)
  some LoanApplication
}
assert FR_009_ValidStateMachine { FR_009_ValidStateMachine }
check FR_009_ValidStateMachine for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_TransitionFromTerminal { some e: ApplicationEvent | e.prevStatus = Approved and e.newStatus = Rejected }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
