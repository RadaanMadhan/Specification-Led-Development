// === feature_model.als — Alloy model for Loan Application with Role-Based Workflow and Audit Trail ===
// Feature: A-L2 (spec folder: 004-loan-application-rbac)
// Artefacts consumed: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// USERS  (dynamic — appears in F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────────────────
sig User {
  role: one Role
}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────────────────────
// DECISION TYPE
// ─────────────────────────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATIONS (permission-matrix columns)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
         ClaimApplication, DecideApplication, GetAuditTrail extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton carrier; contracts/http-api.md §Permission matrix)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// LOAN APPLICATION  (dynamic)
// ─────────────────────────────────────────────────────────────────────────────
sig LoanApplication {
  appCustomer    : one User,
  status         : one ApplicationStatus,
  assignedOfficer: lone User
}

// ─────────────────────────────────────────────────────────────────────────────
// DECISION  (dynamic; at most one per application)
// ─────────────────────────────────────────────────────────────────────────────
sig Decision {
  appDecision  : one LoanApplication,
  decisionType : one DecisionType,
  decidedBy    : one User
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT ENTRY  (dynamic; append-only log)
// ─────────────────────────────────────────────────────────────────────────────
sig AuditEntry {
  auditApp   : one LoanApplication,
  actor      : one User,
  prevStatus : lone ApplicationStatus,   // lone = NULL for initial submission
  newStatus  : one ApplicationStatus
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE  (ensures no assertion passes vacuously over empty worlds)
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX DEFINITION
// contracts/http-api.md §Permission matrix — closed-world enumeration
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Customer          -> PostApplications  ) +
      (Customer          -> GetApplications   ) +
      (Customer          -> GetApplicationByRef) +
      (LoanOfficer       -> GetApplications   ) +
      (LoanOfficer       -> GetApplicationByRef) +
      (LoanOfficer       -> ClaimApplication  ) +
      (LoanOfficer       -> DecideApplication ) +
      (LoanOfficer       -> GetAuditTrail     ) +
      (ComplianceReviewer-> GetApplications   ) +
      (ComplianceReviewer-> GetApplicationByRef) +
      (ComplianceReviewer-> GetAuditTrail     )
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL INVARIANT FACTS
// ─────────────────────────────────────────────────────────────────────────────

// FR-005: customer field always references a Customer-role user
fact F_AppCustomerIsCustomerRole {
  all a: LoanApplication | a.appCustomer.role = Customer
}

// FR-003 / FR-013: assigned officer is always a LoanOfficer-role user
fact F_AssignedOfficerIsLoanOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

// data-model.md CHECK: (status='Submitted') <=> (assignedOfficer IS NULL)
fact F_StatusOfficerConsistency {
  all a: LoanApplication |
    (a.status = Submitted implies no a.assignedOfficer) and
    (a.status != Submitted implies one a.assignedOfficer)
}

// FR-008: at most one in-flight application per customer
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
    not (a1.status in (Submitted + UnderReview) and
         a2.status in (Submitted + UnderReview))
}

// FR-012: each application has at most one assigned officer (structural exclusivity)
fact F_ExclusiveOfficerAssignment {
  all a: LoanApplication | lone a.assignedOfficer
}

// FR-015 / FR-016: a Decision row exists only for Approved / Rejected applications
fact F_DecisionOnlyForDecidedApps {
  all d: Decision | d.appDecision.status in (Approved + Rejected)
}

// FR-016: at most one Decision per application
fact F_AtMostOneDecisionPerApplication {
  all disj d1, d2: Decision | d1.appDecision != d2.appDecision
}

// FR-013 / FR-015: the deciding officer must be the application's assigned officer
fact F_DeciderIsAssignedOfficer {
  all d: Decision | d.decidedBy = d.appDecision.assignedOfficer
}

// FR-016: every decided application has exactly one Decision
fact F_DecidedAppsHaveDecision {
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
    (one d: Decision | d.appDecision = a)
}

// FR-015: decision type is consistent with application status
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.appDecision.status = Approved iff d.decisionType = DecApproved) and
    (d.appDecision.status = Rejected iff d.decisionType = DecRejected)
}

// FR-017 / FR-019: initial audit entry — no prevStatus iff newStatus = Submitted
fact F_AuditInitialEntryStructure {
  all e: AuditEntry |
    (no e.prevStatus iff e.newStatus = Submitted)
}

// FR-017 / FR-019: no no-op audit entry (prevStatus must differ from newStatus)
fact F_NoNoOpAuditEntry {
  all e: AuditEntry |
    some e.prevStatus implies e.prevStatus != e.newStatus
}

// FR-017: actor role matches the kind of transition
//   submission → actor is Customer; all other transitions → actor is LoanOfficer
fact F_AuditActorRolesMatchTransition { /* MUTATED — body cleared by validator */ }

// FR-019 / FR-009: every application has exactly one initial (null → Submitted) audit entry
fact F_UniqueInitialAuditEntry {
  all a: LoanApplication |
    one e: AuditEntry | (e.auditApp = a and e.newStatus = Submitted and no e.prevStatus)
}

// FR-017: every application has at least one audit entry
fact F_AuditEntryExistsPerApp {
  all a: LoanApplication | some e: AuditEntry | e.auditApp = a
}

// FR-004 / FR-023: compliance reviewer's role has no write operations in the matrix
fact F_ComplianceWriteProhibited {
  no (ComplianceReviewer -> (PostApplications + ClaimApplication + DecideApplication))
    & PermMatrix.Allowed
}

// FR-002: customer has no claim / decide / audit-read operations
fact F_CustomerWriteProhibited {
  no (Customer -> (ClaimApplication + DecideApplication + GetAuditTrail))
    & PermMatrix.Allowed
}

// FR-021: audit-entry actors for non-submission transitions are never customers
//   (officer identity is hidden from customer responses; customer never drives
//    a non-submission transition)
fact F_AuditNonSubmissionActorIsOfficer {
  all e: AuditEntry |
    some e.prevStatus implies e.actor.role = LoanOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §Permission matrix; spec.md FR-002 FR-003 FR-004
pred LeastPrivilege {
  // Customer cannot claim or decide
  Customer -> ClaimApplication  not in PermMatrix.Allowed
  Customer -> DecideApplication not in PermMatrix.Allowed
  // Customer cannot read audit trail
  Customer -> GetAuditTrail not in PermMatrix.Allowed
  // ComplianceReviewer cannot write
  ComplianceReviewer -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication  not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed
  // LoanOfficer cannot submit applications as customer
  LoanOfficer -> PostApplications not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §Permission matrix
pred PermissionCompleteness {
  // Every (Role x OperationKind) cell is either allowed or not; the closed-world
  // encoding means PermMatrix.Allowed covers the entire allowed set with no gaps.
  // Assert the total count of allowed cells is exactly 11 (as per the matrix).
  #(PermMatrix.Allowed) = 11
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  // Every operation in the system is covered by the permission matrix for at
  // least one role — no operation is orphaned (reachable without a role check).
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017 FR-019; data-model.md application_events
pred AuditCompleteness {
  // Every application has at least one audit entry
  some LoanApplication
  all a: LoanApplication | some e: AuditEntry | e.auditApp = a
  // Every decided application additionally has an UnderReview→Decided audit entry
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
    (some e: AuditEntry | e.auditApp = a and
       e.prevStatus = UnderReview and e.newStatus = a.status)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  // In the snapshot model, AppendOnly means: no two distinct AuditEntry atoms
  // for the same application share the same (prevStatus, newStatus) transition —
  // i.e., the log is free of duplicate entries for the same applied change.
  some AuditEntry
  all disj e1, e2: AuditEntry |
    (e1.auditApp = e2.auditApp and
     e1.prevStatus = e2.prevStatus and
     e1.newStatus  = e2.newStatus) implies e1 = e2
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  some AuditEntry
  // Submission entries are attributed to a customer
  all e: AuditEntry |
    e.newStatus = Submitted implies e.actor.role = Customer
  // Claim and decision entries are attributed to a loan officer
  all e: AuditEntry |
    e.newStatus in (UnderReview + Approved + Rejected) implies e.actor.role = LoanOfficer
  // The actor on a transition to Approved/Rejected must be the application's assigned officer
  all e: AuditEntry |
    e.newStatus in (Approved + Rejected) implies
    e.actor = e.auditApp.assignedOfficer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id; spec.md §Customer entity
pred OwnershipExclusivity {
  some LoanApplication
  // Every application has exactly one customer (already one in sig; verify role)
  all a: LoanApplication | one a.appCustomer and a.appCustomer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
  // Customer-role users can only be the applicant on applications whose
  // appCustomer field points to them.  Encoded as: the customer field of every
  // application is a User with role = Customer, and that same user is the only
  // customer who "owns" the application.
  some LoanApplication
  all a: LoanApplication |
    a.appCustomer.role = Customer and
    (all u: User | u.role = Customer and u != a.appCustomer implies
      u not in a.assignedOfficer)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found" note
pred NoInformationLeakage {
  // A LoanApplication's customer must be a Customer-role user.
  // Officer identity is never held by a Customer-role user in any app field.
  some LoanApplication
  all a: LoanApplication |
    a.appCustomer.role = Customer and
    (some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer) and
    a.appCustomer != a.assignedOfficer
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-006 FR-014; data-model.md validation.py
pred ValidationBeforeMutation {
  // No Decision exists for an application that is still Submitted or UnderReview —
  // i.e., a decision write can only land once the status guard (UnderReview) passes.
  some LoanApplication
  all d: Decision |
    d.appDecision.status in (Approved + Rejected) and
    d.decidedBy = d.appDecision.assignedOfficer
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012 SC-006; data-model.md conditional UPDATE
pred ConcurrencySafety {
  // Exactly one officer can claim each application: no two distinct applications
  // with the same customer are both UnderReview simultaneously (FR-008),
  // and no single application has more than one assigned officer.
  some LoanApplication
  all a: LoanApplication | lone a.assignedOfficer
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
    not (a1.status in (Submitted + UnderReview) and a2.status in (Submitted + UnderReview))
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // Every OperationKind is reachable only through a defined Role entry.
  // No operation is allowed for zero roles (auth is total).
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
  // Customer CAN submit and read applications
  Customer -> PostApplications   in PermMatrix.Allowed
  Customer -> GetApplications    in PermMatrix.Allowed
  Customer -> GetApplicationByRef in PermMatrix.Allowed
  // Customer CANNOT claim, decide, or read audit
  Customer -> ClaimApplication   not in PermMatrix.Allowed
  Customer -> DecideApplication  not in PermMatrix.Allowed
  Customer -> GetAuditTrail      not in PermMatrix.Allowed
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerPermissions {
  // LoanOfficer CAN list, view, claim, decide, audit
  LoanOfficer -> GetApplications    in PermMatrix.Allowed
  LoanOfficer -> GetApplicationByRef in PermMatrix.Allowed
  LoanOfficer -> ClaimApplication   in PermMatrix.Allowed
  LoanOfficer -> DecideApplication  in PermMatrix.Allowed
  LoanOfficer -> GetAuditTrail      in PermMatrix.Allowed
  // LoanOfficer CANNOT submit as customer
  LoanOfficer -> PostApplications   not in PermMatrix.Allowed
}
assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_ComplianceReviewerPermissions {
  // ComplianceReviewer CAN list, view, audit-read
  ComplianceReviewer -> GetApplications    in PermMatrix.Allowed
  ComplianceReviewer -> GetApplicationByRef in PermMatrix.Allowed
  ComplianceReviewer -> GetAuditTrail      in PermMatrix.Allowed
  // ComplianceReviewer CANNOT submit, claim, or decide
  ComplianceReviewer -> PostApplications   not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication   not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication  not in PermMatrix.Allowed
}
assert FR_004_ComplianceReviewerPermissions { FR_004_ComplianceReviewerPermissions }
check FR_004_ComplianceReviewerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_CustomerIdentityFromAuth {
  // The customer on every application is a User with role=Customer.
  // (The customer field is never a LoanOfficer or ComplianceReviewer.)
  some LoanApplication
  all a: LoanApplication | a.appCustomer.role = Customer
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerCustomer {
  // No customer has two applications simultaneously in {Submitted, UnderReview}.
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
    not (a1.status in (Submitted + UnderReview) and
         a2.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md UNIQUE(reference), application_events initial row
pred FR_009_AuditOnSubmission {
  // Every application has exactly one null-prevStatus audit entry whose newStatus = Submitted.
  some LoanApplication
  all a: LoanApplication |
    one e: AuditEntry | (e.auditApp = a and no e.prevStatus and e.newStatus = Submitted)
}
assert FR_009_AuditOnSubmission { FR_009_AuditOnSubmission }
check FR_009_AuditOnSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md Submitted->UnderReview transition
pred FR_011_ClaimTransitionAudit {
  // Every UnderReview application has a Submitted->UnderReview audit entry
  // whose actor is the assigned officer.
  some a: LoanApplication | a.status = UnderReview
  all a: LoanApplication |
    a.status = UnderReview implies
    (some e: AuditEntry |
       e.auditApp = a and
       e.prevStatus = Submitted and
       e.newStatus = UnderReview and
       e.actor = a.assignedOfficer)
}
assert FR_011_ClaimTransitionAudit { FR_011_ClaimTransitionAudit }
check FR_011_ClaimTransitionAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md conditional UPDATE claim race
pred FR_012_ExclusiveClaim {
  // At most one officer is ever assigned to a given application.
  some LoanApplication
  all a: LoanApplication | lone a.assignedOfficer
}
assert FR_012_ExclusiveClaim { FR_012_ExclusiveClaim }
check FR_012_ExclusiveClaim for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md assigned_officer_id conditional UPDATE
pred FR_013_OnlyAssignedOfficerDecides {
  // For every Decision, the deciding officer equals the application's assignedOfficer.
  some Decision
  all d: Decision | d.decidedBy = d.appDecision.assignedOfficer
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 FR-016; data-model.md decisions table PK + status machine
pred FR_015_AtomicDecisionRecord {
  // Every Approved/Rejected application has exactly one Decision,
  // and its decisionType matches the status.
  some Decision
  all a: LoanApplication |
    a.status = Approved implies
    (one d: Decision | d.appDecision = a and d.decisionType = DecApproved)
  all a: LoanApplication |
    a.status = Rejected implies
    (one d: Decision | d.appDecision = a and d.decisionType = DecRejected)
}
assert FR_015_AtomicDecisionRecord { FR_015_AtomicDecisionRecord }
check FR_015_AtomicDecisionRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md no UPDATE/DELETE on decisions
pred FR_016_TerminalStateImmutability {
  // No Decision exists for an application that is not yet in a terminal state.
  // No application in a terminal state lacks a Decision.
  some Decision
  all d: Decision | d.appDecision.status in (Approved + Rejected)
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
    (some d: Decision | d.appDecision = a)
}
assert FR_016_TerminalStateImmutability { FR_016_TerminalStateImmutability }
check FR_016_TerminalStateImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 FR-019; data-model.md application_events
pred FR_017_AuditForEveryTransition {
  // 1) Every application has a (null -> Submitted) entry.
  // 2) UnderReview applications have a (Submitted -> UnderReview) entry.
  // 3) Terminal applications have an (UnderReview -> terminal-status) entry.
  some LoanApplication
  all a: LoanApplication |
    one e: AuditEntry | (e.auditApp = a and no e.prevStatus and e.newStatus = Submitted)
  all a: LoanApplication |
    a.status in (UnderReview + Approved + Rejected) implies
    (some e: AuditEntry |
       e.auditApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
    (some e: AuditEntry |
       e.auditApp = a and e.prevStatus = UnderReview and e.newStatus = a.status)
}
assert FR_017_AuditForEveryTransition { FR_017_AuditForEveryTransition }
check FR_017_AuditForEveryTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred FR_018_AppendOnlyAudit {
  // No two distinct AuditEntry atoms record the same (application, prev, new)
  // triple — the log has no duplicate entries for the same applied transition.
  some AuditEntry
  all disj e1, e2: AuditEntry |
    not (e1.auditApp = e2.auditApp and
         e1.prevStatus = e2.prevStatus and
         e1.newStatus  = e2.newStatus)
}
assert FR_018_AppendOnlyAudit { FR_018_AppendOnlyAudit }
check FR_018_AppendOnlyAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md "exactly one entry per status change"
pred FR_019_ExactlyOneAuditPerTransition {
  some LoanApplication
  // Exactly one initial entry per application
  all a: LoanApplication |
    one e: AuditEntry | (e.auditApp = a and no e.prevStatus and e.newStatus = Submitted)
  // At most one Submitted->UnderReview entry per application
  all a: LoanApplication |
    lone e: AuditEntry | (e.auditApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
  // At most one UnderReview->terminal entry per application
  all a: LoanApplication |
    lone e: AuditEntry | (e.auditApp = a and e.prevStatus = UnderReview and
                           e.newStatus in (Approved + Rejected))
}
assert FR_019_ExactlyOneAuditPerTransition { FR_019_ExactlyOneAuditPerTransition }
check FR_019_ExactlyOneAuditPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020; contracts/http-api.md "404 not_found — no existence leak"
pred FR_020_CustomerOwnsApplication {
  // No customer-role user appears as the assigned officer on any application.
  // Each application's customer field is uniquely a Customer-role user.
  some LoanApplication
  all a: LoanApplication |
    a.appCustomer.role = Customer and
    (some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer) and
    a.appCustomer != a.assignedOfficer
}
assert FR_020_CustomerOwnsApplication { FR_020_CustomerOwnsApplication }
check FR_020_CustomerOwnsApplication for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021; contracts/http-api.md §Response scrubbing
pred FR_021_OfficerIdentityHiddenFromCustomer {
  // Officer-role users never appear in the customer field of any application.
  // Audit entries whose actor is a LoanOfficer are never the initial submission entry.
  some AuditEntry
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Submitted) implies e.actor.role = Customer
  all a: LoanApplication | a.appCustomer.role = Customer
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023; spec.md FR-004; contracts/http-api.md §Permission matrix
pred FR_023_ComplianceReadOnly {
  // ComplianceReviewer has no entry in Allowed for any write operation.
  ComplianceReviewer -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication  not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed
}
assert FR_023_ComplianceReadOnly { FR_023_ComplianceReadOnly }
check FR_023_ComplianceReadOnly for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_WrongActorRole { some e: AuditEntry | e.newStatus = UnderReview and e.actor.role = Customer }
