// === feature_model.als — Alloy model for Loan Application RBAC Workflow (A-L2) ===
// Feature folder : A-L2  (spec branch 004-loan-application-rbac)
// Sources        : spec.md, data-model.md, contracts/http-api.md
// Generated for  : Alloy 6  –  no external imports, no module declaration

// ─── Roles ───────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

// ─── Application statuses ────────────────────────────────────────────────────
abstract sig AppStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends AppStatus {}

// ─── Decision types ──────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig ApprovedDT, RejectedDT extends DecisionType {}

// ─── Operation kinds (one per API endpoint / action) ─────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        ClaimApp, DecideApp, GetAudit extends OperationKind {}

// ─── Permission matrix (singleton carrier) ───────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─── Dynamic sigs ─────────────────────────────────────────────────────────────
sig User { role: one Role }

sig LoanApplication {
  appCustomer      : one User,
  status           : one AppStatus,
  assignedOfficer  : lone User
}

sig Decision {
  decApp    : one LoanApplication,
  decidedBy : one User,
  dtype     : one DecisionType
}

sig AppEvent {
  evApp      : one LoanApplication,
  prevStatus : lone AppStatus,
  newStatus  : one AppStatus,
  actor      : one User
}

// ─── Non-empty universe (dynamic sigs only) ──────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AppEvent
}

// ─── Permission matrix: closed-world assignment ───────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (CustomerRole         -> PostApplications)
    + (CustomerRole         -> GetApplications)
    + (CustomerRole         -> GetApplicationByRef)
    + (LoanOfficerRole      -> GetApplications)
    + (LoanOfficerRole      -> GetApplicationByRef)
    + (LoanOfficerRole      -> ClaimApp)
    + (LoanOfficerRole      -> DecideApp)
    + (LoanOfficerRole      -> GetAudit)
    + (ComplianceReviewerRole -> GetApplications)
    + (ComplianceReviewerRole -> GetApplicationByRef)
    + (ComplianceReviewerRole -> GetAudit)
}

// ─── Role integrity ───────────────────────────────────────────────────────────
// Every application's customer field references a Customer-role user (FR-005)
fact F_AppCustomerRole {
  all a: LoanApplication | a.appCustomer.role = CustomerRole
}

// Every assigned officer is a LoanOfficer-role user (FR-011)
fact F_AssignedOfficerMustBeLoanOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficerRole
}

// ─── Status / assignment coupling ────────────────────────────────────────────
// data-model.md CHECK((status='Submitted')=(assigned_officer_id IS NULL))
fact F_StatusAssignmentCoupling {
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

// ─── One in-flight application per customer ───────────────────────────────────
// data-model.md idx_one_in_flight_per_customer (FR-008)
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (
        (a1.status = Submitted or a1.status = UnderReview) and
        (a2.status = Submitted or a2.status = UnderReview)
      )
}

// ─── Decision constraints ─────────────────────────────────────────────────────
// Decisions exist only for Approved/Rejected applications (FR-015)
fact F_DecisionOnlyForDecidedApps {
  all d: Decision | d.decApp.status = Approved or d.decApp.status = Rejected
}

// At most one decision per application (data-model.md Decision PK)
fact F_OneDecisionPerApp {
  all disj d1, d2: Decision | d1.decApp != d2.decApp
}

// Decision type mirrors application status
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.dtype = ApprovedDT iff d.decApp.status = Approved) and
    (d.dtype = RejectedDT iff d.decApp.status = Rejected)
}

// Decided applications have exactly one Decision row (FR-015)
fact F_DecidedAppsHaveDecision { /* MUTATED — body cleared by validator */ }

// Decision is made by the assigned officer (FR-013)
fact F_DecisionByAssignedOfficer {
  all d: Decision | d.decidedBy = d.decApp.assignedOfficer
}

// ─── Audit-event structural constraints ──────────────────────────────────────
// Initial event: prevStatus absent iff newStatus = Submitted
// data-model.md CHECK((previous_status IS NULL)=(new_status='Submitted'))
fact F_InitialEventStructure {
  all e: AppEvent | (no e.prevStatus) iff (e.newStatus = Submitted)
}

// No no-op transitions (data-model.md CHECK(previous_status <> new_status))
fact F_NoNoOpTransition {
  all e: AppEvent | some e.prevStatus implies e.prevStatus != e.newStatus
}

// Only the four valid transition shapes are reachable (data-model.md state machine)
fact F_ValidTransitionShapes {
  all e: AppEvent |
    ((no e.prevStatus)             and e.newStatus = Submitted)   or
    (e.prevStatus = Submitted      and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview    and e.newStatus = Approved)    or
    (e.prevStatus = UnderReview    and e.newStatus = Rejected)
}

// Decided applications have no outgoing transitions in the audit trail (FR-016)
fact F_NoTransitionsFromDecidedStatus {
  all e: AppEvent |
    e.prevStatus != Approved and e.prevStatus != Rejected
}

// Every application has exactly one initial (none→Submitted) event (FR-009, FR-019)
fact F_OneInitialEventPerApp {
  all a: LoanApplication |
    one e: AppEvent | e.evApp = a and no e.prevStatus
}

// Claim event exists for any non-Submitted application (FR-011)
fact F_ClaimEventExists {
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one e: AppEvent | e.evApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
}

// Approve event exists iff application is Approved (FR-015, FR-019)
fact F_ApproveEventExists {
  all a: LoanApplication |
    a.status = Approved implies
      (one e: AppEvent | e.evApp = a and e.prevStatus = UnderReview and e.newStatus = Approved)
}

// Reject event exists iff application is Rejected (FR-015, FR-019)
fact F_RejectEventExists {
  all a: LoanApplication |
    a.status = Rejected implies
      (one e: AppEvent | e.evApp = a and e.prevStatus = UnderReview and e.newStatus = Rejected)
}

// Append-only: no two events on the same application share (prevStatus, newStatus) (FR-018)
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: AppEvent |
    e1.evApp = e2.evApp implies
      not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
}

// Submission events are attributed to the application's customer (FR-017)
fact F_SubmissionEventActor {
  all e: AppEvent |
    (no e.prevStatus and e.newStatus = Submitted) implies e.actor = e.evApp.appCustomer
}

// Non-submission events are attributed to a loan officer (FR-017)
fact F_NonSubmissionEventActor {
  all e: AppEvent |
    some e.prevStatus implies e.actor.role = LoanOfficerRole
}

// ════════════════════════════════════════════════════════════════════════════
// PATTERN PREDICATES
// ════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-002, FR-003, FR-004
pred LeastPrivilege {
  // Customers cannot claim, decide, or read the audit trail
  CustomerRole -> ClaimApp   not in PermMatrix.Allowed
  CustomerRole -> DecideApp  not in PermMatrix.Allowed
  CustomerRole -> GetAudit   not in PermMatrix.Allowed
  // Compliance reviewers cannot submit, claim, or decide
  ComplianceReviewerRole -> PostApplications not in PermMatrix.Allowed
  ComplianceReviewerRole -> ClaimApp         not in PermMatrix.Allowed
  ComplianceReviewerRole -> DecideApp        not in PermMatrix.Allowed
  // Loan officers cannot submit as a customer
  LoanOfficerRole -> PostApplications not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every OperationKind is accessible by at least one Role (no dead operation)
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-002, FR-003, FR-004; contracts/http-api.md
pred PermissionGrounding {
  // Every allow cell traces to an explicit FR:
  //   FR-002 grants customers: submit, list own, view own
  CustomerRole -> PostApplications   in PermMatrix.Allowed
  CustomerRole -> GetApplications    in PermMatrix.Allowed
  CustomerRole -> GetApplicationByRef in PermMatrix.Allowed
  //   FR-003 grants loan officers: list, view, claim, decide, audit
  LoanOfficerRole -> GetApplications    in PermMatrix.Allowed
  LoanOfficerRole -> GetApplicationByRef in PermMatrix.Allowed
  LoanOfficerRole -> ClaimApp           in PermMatrix.Allowed
  LoanOfficerRole -> DecideApp          in PermMatrix.Allowed
  LoanOfficerRole -> GetAudit           in PermMatrix.Allowed
  //   FR-004 grants compliance reviewers: list all, view any, audit any
  ComplianceReviewerRole -> GetApplications    in PermMatrix.Allowed
  ComplianceReviewerRole -> GetApplicationByRef in PermMatrix.Allowed
  ComplianceReviewerRole -> GetAudit           in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-003, FR-004; contracts/http-api.md
// Compliance reviewers and loan officers both hold all read-side permissions;
// neither is a subset of the other on write-side — captured as: on every read
// operation, LoanOfficer and ComplianceReviewer have identical access.
pred PrivilegeMonotonicity {
  all op: OperationKind |
    (op = GetApplications or op = GetApplicationByRef or op = GetAudit) implies (
      (LoanOfficerRole -> op in PermMatrix.Allowed) iff
      (ComplianceReviewerRole -> op in PermMatrix.Allowed)
    )
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  // Submitted → exactly 1 event
  all a: LoanApplication | a.status = Submitted implies
    (one e: AppEvent | e.evApp = a)
  // UnderReview → exactly 2 events (initial + claim)
  all a: LoanApplication | a.status = UnderReview implies
    (#{e: AppEvent | e.evApp = a} = 2)
  // Approved or Rejected → exactly 3 events (initial + claim + decision)
  all a: LoanApplication | (a.status = Approved or a.status = Rejected) implies
    (#{e: AppEvent | e.evApp = a} = 3)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some AppEvent
  // No two events on the same application encode the same transition
  all disj e1, e2: AppEvent |
    e1.evApp = e2.evApp implies
      not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
pred AttributionCorrectness {
  some AppEvent
  // Submission event actor == the application's submitting customer
  all e: AppEvent |
    (no e.prevStatus and e.newStatus = Submitted) implies
      e.actor = e.evApp.appCustomer
  // All other events are attributed to a loan officer
  all e: AppEvent |
    some e.prevStatus implies e.actor.role = LoanOfficerRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013, FR-020; data-model.md assigned_officer_id
pred OwnershipBasedAccess {
  some Decision
  // Decision is always made by the application's own assigned officer
  all d: Decision | d.decidedBy = d.decApp.assignedOfficer
  // The assigned officer must hold the LoanOfficer role
  all d: Decision | d.decidedBy.role = LoanOfficerRole
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md 404 on non-owner
// Structural gate: customers cannot reach GetAudit (which reveals actor identities),
// and cannot reach ClaimApp (which would confirm an application's existence to a non-owner).
pred NoInformationLeakage {
  some LoanApplication
  CustomerRole -> GetAudit  not in PermMatrix.Allowed
  CustomerRole -> ClaimApp  not in PermMatrix.Allowed
  CustomerRole -> DecideApp not in PermMatrix.Allowed
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ════════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// ════════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every OperationKind requires an authenticated (role-bearing) caller:
// unauthenticated = no role; every op has at least one allowed role, so
// every successful request must carry a valid role.
pred FR_001_AuthRequired {
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
  CustomerRole -> PostApplications    in PermMatrix.Allowed
  CustomerRole -> GetApplications     in PermMatrix.Allowed
  CustomerRole -> GetApplicationByRef in PermMatrix.Allowed
  CustomerRole -> ClaimApp   not in PermMatrix.Allowed
  CustomerRole -> DecideApp  not in PermMatrix.Allowed
  CustomerRole -> GetAudit   not in PermMatrix.Allowed
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerPermissions {
  LoanOfficerRole -> PostApplications not in PermMatrix.Allowed
  LoanOfficerRole -> GetApplications     in PermMatrix.Allowed
  LoanOfficerRole -> GetApplicationByRef in PermMatrix.Allowed
  LoanOfficerRole -> ClaimApp            in PermMatrix.Allowed
  LoanOfficerRole -> DecideApp           in PermMatrix.Allowed
  LoanOfficerRole -> GetAudit            in PermMatrix.Allowed
}
assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023
pred FR_004_ComplianceReadOnly {
  some LoanApplication
  ComplianceReviewerRole -> PostApplications not in PermMatrix.Allowed
  ComplianceReviewerRole -> ClaimApp         not in PermMatrix.Allowed
  ComplianceReviewerRole -> DecideApp        not in PermMatrix.Allowed
  ComplianceReviewerRole -> GetApplications     in PermMatrix.Allowed
  ComplianceReviewerRole -> GetApplicationByRef in PermMatrix.Allowed
  ComplianceReviewerRole -> GetAudit            in PermMatrix.Allowed
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
pred FR_008_OneInFlightPerCustomer {
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (
        (a1.status = Submitted or a1.status = UnderReview) and
        (a2.status = Submitted or a2.status = UnderReview)
      )
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md application_events initial row
pred FR_009_SubmissionAuditEntry {
  some LoanApplication
  all a: LoanApplication |
    one e: AppEvent | e.evApp = a and no e.prevStatus and e.newStatus = Submitted
}
assert FR_009_SubmissionAuditEntry { FR_009_SubmissionAuditEntry }
check FR_009_SubmissionAuditEntry for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md Submitted→Under Review transition
pred FR_011_ClaimAuditEntry {
  some a: LoanApplication | a.status != Submitted
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one e: AppEvent |
        e.evApp = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
}
assert FR_011_ClaimAuditEntry { FR_011_ClaimAuditEntry }
check FR_011_ClaimAuditEntry for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md assigned_officer_id uniqueness, concurrent claim
pred FR_012_OneOfficerPerApp {
  some LoanApplication
  all a: LoanApplication | lone a.assignedOfficer
}
assert FR_012_OneOfficerPerApp { FR_012_OneOfficerPerApp }
check FR_012_OneOfficerPerApp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md decided_by_user_id == assigned_officer_id
pred FR_013_OnlyAssignedOfficerDecides {
  some Decision
  all d: Decision | d.decidedBy = d.decApp.assignedOfficer
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md decisions table, atomic transaction
pred FR_015_DecisionExistsForDecidedApps {
  some a: LoanApplication | a.status = Approved or a.status = Rejected
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies
      (one d: Decision | d.decApp = a)
}
assert FR_015_DecisionExistsForDecidedApps { FR_015_DecisionExistsForDecidedApps }
check FR_015_DecisionExistsForDecidedApps for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md no SQL path from Approved/Rejected
pred FR_016_DecidedAppsImmutable {
  some LoanApplication
  // No audit event has Approved or Rejected as its previous_status
  all e: AppEvent | e.prevStatus != Approved and e.prevStatus != Rejected
}
assert FR_016_DecidedAppsImmutable { FR_016_DecidedAppsImmutable }
check FR_016_DecidedAppsImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017, FR-019; data-model.md application_events
pred FR_017_AuditPerStatusChange {
  some LoanApplication
  all a: LoanApplication | a.status = Submitted implies
    (one e: AppEvent | e.evApp = a)
  all a: LoanApplication | a.status = UnderReview implies
    (#{e: AppEvent | e.evApp = a} = 2)
  all a: LoanApplication | (a.status = Approved or a.status = Rejected) implies
    (#{e: AppEvent | e.evApp = a} = 3)
}
assert FR_017_AuditPerStatusChange { FR_017_AuditPerStatusChange }
check FR_017_AuditPerStatusChange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred FR_018_AuditAppendOnly {
  some AppEvent
  all disj e1, e2: AppEvent |
    e1.evApp = e2.evApp implies
      not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019; data-model.md "exactly one entry per applied change"
pred FR_019_OneAuditPerTransition {
  some AppEvent
  all disj e1, e2: AppEvent |
    not (e1.evApp = e2.evApp
         and e1.prevStatus = e2.prevStatus
         and e1.newStatus = e2.newStatus)
}
assert FR_019_OneAuditPerTransition { FR_019_OneAuditPerTransition }
check FR_019_OneAuditPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md FR-020, contracts/http-api.md 404 on non-owner
pred FR_020_CustomerIsolation {
  some LoanApplication
  // Every application's customer field references a customer-role user (not an officer)
  all a: LoanApplication | a.appCustomer.role = CustomerRole
  // Customer cannot access audit (existence-leaking endpoint)
  CustomerRole -> GetAudit not in PermMatrix.Allowed
}
assert FR_020_CustomerIsolation { FR_020_CustomerIsolation }
check FR_020_CustomerIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021; contracts/http-api.md scrub_for_role
// Structural gate: customers cannot reach GetAudit (actor identities) or
// DecideApp/ClaimApp (officer-revealing error messages).
pred FR_021_OfficerIdentityHiddenFromCustomer {
  some LoanApplication
  CustomerRole -> GetAudit  not in PermMatrix.Allowed
  CustomerRole -> ClaimApp  not in PermMatrix.Allowed
  CustomerRole -> DecideApp not in PermMatrix.Allowed
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: data-model.md CHECK((status='Submitted')=(assigned_officer_id IS NULL))
pred FR_StatusAssignmentCoupling {
  some LoanApplication
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}
assert FR_StatusAssignmentCoupling { FR_StatusAssignmentCoupling }
check FR_StatusAssignmentCoupling for 5

// FEATURE-SPECIFIC  ANCHOR: data-model.md state machine; spec.md Assumptions (four statuses only)
pred FR_ValidTransitionsOnly {
  some AppEvent
  // Every event encodes one of the four allowed transition shapes
  all e: AppEvent |
    ((no e.prevStatus)             and e.newStatus = Submitted)   or
    (e.prevStatus = Submitted      and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview    and e.newStatus = Approved)    or
    (e.prevStatus = UnderReview    and e.newStatus = Rejected)
}
assert FR_ValidTransitionsOnly { FR_ValidTransitionsOnly }
check FR_ValidTransitionsOnly for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_DecidedNoDecision { some a: LoanApplication | a.status = Approved and (no d: Decision | d.decApp = a) }
