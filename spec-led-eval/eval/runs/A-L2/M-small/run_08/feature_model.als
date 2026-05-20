// === feature_model.als — Alloy 6 Model: 004-loan-application-rbac ===
// Loan Application with Role-Based Workflow and Audit Trail

// ============ SIGS ============

// Roles
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// Application statuses
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// Decision types
abstract sig DecisionType {}
one sig DecisionApproved, DecisionRejected extends DecisionType {}

// Operation kinds (for permission matrix)
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplication, ClaimApplication, PostDecision, GetAudit extends OperationKind {}

// Users (dynamic)
sig User {
  role: one Role
}

// Loan applications (dynamic)
sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assigned_officer: lone User
}

// Decisions (at most one per application)
sig Decision {
  application: one LoanApplication,
  decision_type: one DecisionType,
  decided_by: one User
}

// Audit events (dynamic, append-only)
sig ApplicationEvent {
  application: one LoanApplication,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  actor: one User
}

// Permission matrix (singleton)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============ FACTS ============

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-002, FR-003, FR-004
fact F_PermissionMatrix {
  PermMatrix.Allowed = 
    (Customer -> PostApplications) +
    (Customer -> GetApplications) +
    (Customer -> GetApplication) +
    (LoanOfficer -> GetApplications) +
    (LoanOfficer -> GetApplication) +
    (LoanOfficer -> ClaimApplication) +
    (LoanOfficer -> PostDecision) +
    (LoanOfficer -> GetAudit) +
    (ComplianceReviewer -> GetApplications) +
    (ComplianceReviewer -> GetApplication) +
    (ComplianceReviewer -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
fact F_OneRolePerUser {
  all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-017, FR-019, SC-007; data-model.md UNIQUE constraints
fact F_AuditCompleteness {
  all app: LoanApplication |
    (
      // Every application has exactly one initial Submitted event
      (one e: ApplicationEvent | 
        e.application = app and 
        e.previous_status = none and 
        e.new_status = Submitted)
    ) and
    (
      // At most one Submitted→UnderReview transition per application
      (lone e: ApplicationEvent | 
        e.application = app and 
        e.previous_status = Submitted and 
        e.new_status = UnderReview)
    ) and
    (
      // At most one UnderReview→{Approved|Rejected} transition per application
      (lone e: ApplicationEvent | 
        e.application = app and 
        e.previous_status = UnderReview and 
        (e.new_status = Approved or e.new_status = Rejected))
    )
}

// PATTERN: AppendOnly  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on application_events"
fact F_AppendOnly {
  // ApplicationEvent sigs are immutable once created; no deletion or modification occurs
  all e: ApplicationEvent | e in ApplicationEvent
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-017; data-model.md audit-entry fields
fact F_AttributionCorrectness {
  all e: ApplicationEvent |
    (
      // Initial submission: actor must be the customer
      (e.previous_status = none and e.new_status = Submitted) implies
        (e.actor.role = Customer and e.actor = e.application.customer)
    ) and
    (
      // Claim (Submitted→UnderReview): actor must be a loan officer becoming the assigned officer
      (e.previous_status = Submitted and e.new_status = UnderReview) implies
        (e.actor.role = LoanOfficer and e.actor = e.application.assigned_officer)
    ) and
    (
      // Decision (UnderReview→{Approved|Rejected}): actor must be the assigned loan officer
      ((e.previous_status = UnderReview and (e.new_status = Approved or e.new_status = Rejected))) implies
        (e.actor.role = LoanOfficer and e.actor = e.application.assigned_officer)
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-020; contracts/http-api.md "no existence leak"
fact F_NoInformationLeakage {
  all u: User, app: LoanApplication |
    (u.role = Customer and u != app.customer) implies
      // A customer who doesn't own this app learns nothing: no audit events act on it
      (no e: ApplicationEvent | e.actor = u and e.application = app)
}

// PATTERN: ConcurrencySafety  ANCHOR: FR-012, SC-006; data-model.md claim race resolution
fact F_ConcurrencySafety {
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
      // Exactly one officer is assigned once the application leaves Submitted state
      (one officer: User | 
        officer = app.assigned_officer and officer.role = LoanOfficer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008
fact F_OneInFlightPerCustomer {
  all customer: User |
    customer.role = Customer implies
      // At most one in-flight (Submitted or UnderReview) application per customer
      (lone app: LoanApplication | 
        app.customer = customer and 
        (app.status = Submitted or app.status = UnderReview))
}

// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-005
fact F_OnlyAssignedOfficerDecides {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (
        // The application must have an assigned officer
        app.assigned_officer != none and
        app.assigned_officer.role = LoanOfficer and
        // There is exactly one decision, made by that officer
        (one d: Decision | d.application = app and d.decided_by = app.assigned_officer)
      )
}

// FEATURE-SPECIFIC  ANCHOR: FR-016
fact F_DecidedApplicationsImmutable {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      // No events exist that transition away from Approved/Rejected
      (no e: ApplicationEvent | 
        e.application = app and 
        (e.previous_status = Approved or e.previous_status = Rejected))
}

// FEATURE-SPECIFIC  ANCHOR: FR-020
fact F_CustomerOwnershipExclusivity {
  all app: LoanApplication |
    // Each application is owned by exactly one customer
    (one customer: User | 
      customer = app.customer and customer.role = Customer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023
fact F_ComplianceReviewerReadOnly {
  all u: User |
    u.role = ComplianceReviewer implies
      (
        u -> PostApplications not in PermMatrix.Allowed and
        u -> ClaimApplication not in PermMatrix.Allowed and
        u -> PostDecision not in PermMatrix.Allowed
      )
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-002, FR-003, FR-004
pred LeastPrivilege {
  all r: Role, op: OperationKind |
    (r -> op not in PermMatrix.Allowed) implies
      (no u: User | u.role = r and u -> op in PermMatrix.Allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/ permission matrix
pred PermissionCompleteness {
  all r: Role, op: OperationKind |
    r -> op in PermMatrix.Allowed or r -> op not in PermMatrix.Allowed
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  (some User) implies
    (all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer))
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-017, FR-019, SC-007
pred AuditCompleteness {
  (some LoanApplication) implies
    (all app: LoanApplication |
      // Every application has its initial submission event
      (some e: ApplicationEvent | 
        e.application = app and 
        e.previous_status = none and 
        e.new_status = Submitted) and
      // No duplicate transitions of the same type
      (all s1, s2: ApplicationStatus |
        (s1 != s2) implies
          (lone e: ApplicationEvent | 
            e.application = app and 
            e.previous_status = s1 and 
            e.new_status = s2))
    )
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-018
pred AppendOnly {
  (some ApplicationEvent) implies
    (all e: ApplicationEvent | e in ApplicationEvent)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-017
pred AttributionCorrectness {
  (some ApplicationEvent) implies
    (all e: ApplicationEvent |
      (
        (e.previous_status = none implies e.actor = e.application.customer) and
        (e.previous_status = Submitted implies e.actor.role = LoanOfficer) and
        (e.previous_status = UnderReview implies e.actor.role = LoanOfficer)
      )
    )
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-020
pred NoInformationLeakage {
  (some User) implies
    (all u: User, app: LoanApplication |
      (u.role = Customer and u != app.customer) implies
        (no e: ApplicationEvent | e.actor = u and e.application = app))
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: ConcurrencySafety  ANCHOR: FR-012, SC-006
pred ConcurrencySafety {
  (some LoanApplication) implies
    (all app: LoanApplication |
      (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
        (one officer: User | officer = app.assigned_officer))
}

assert ConcurrencySafety {
  ConcurrencySafety
}

check ConcurrencySafety for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  (some User) implies
    (all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer))
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerActions {
  (some User) implies
    (all u: User |
      u.role = Customer implies
        (
          u -> PostApplications in PermMatrix.Allowed and
          u -> GetApplications in PermMatrix.Allowed and
          u -> GetApplication in PermMatrix.Allowed and
          u -> ClaimApplication not in PermMatrix.Allowed and
          u -> PostDecision not in PermMatrix.Allowed and
          u -> GetAudit not in PermMatrix.Allowed
        ))
}

assert FR_002_CustomerActions {
  FR_002_CustomerActions
}

check FR_002_CustomerActions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerActions {
  (some User) implies
    (all u: User |
      u.role = LoanOfficer implies
        (
          u -> PostApplications not in PermMatrix.Allowed and
          u -> GetApplications in PermMatrix.Allowed and
          u -> GetApplication in PermMatrix.Allowed and
          u -> ClaimApplication in PermMatrix.Allowed and
          u -> PostDecision in PermMatrix.Allowed and
          u -> GetAudit in PermMatrix.Allowed
        ))
}

assert FR_003_LoanOfficerActions {
  FR_003_LoanOfficerActions
}

check FR_003_LoanOfficerActions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_ComplianceReviewerActions {
  (some User) implies
    (all u: User |
      u.role = ComplianceReviewer implies
        (
          u -> PostApplications not in PermMatrix.Allowed and
          u -> GetApplications in PermMatrix.Allowed and
          u -> GetApplication in PermMatrix.Allowed and
          u -> ClaimApplication not in PermMatrix.Allowed and
          u -> PostDecision not in PermMatrix.Allowed and
          u -> GetAudit in PermMatrix.Allowed
        ))
}

assert FR_004_ComplianceReviewerActions {
  FR_004_ComplianceReviewerActions
}

check FR_004_ComplianceReviewerActions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerCustomer {
  (some LoanApplication) implies
    (all customer: User |
      customer.role = Customer implies
        (lone app: LoanApplication | 
          app.customer = customer and 
          (app.status = Submitted or app.status = UnderReview)))
}

assert FR_008_OneInFlightPerCustomer {
  FR_008_OneInFlightPerCustomer
}

check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OnlyAssignedOfficerDecides {
  (some LoanApplication) implies
    (all app: LoanApplication |
      (app.status = Approved or app.status = Rejected) implies
        (
          app.assigned_officer != none and
          app.assigned_officer.role = LoanOfficer and
          (some d: Decision | d.application = app and d.decided_by = app.assigned_officer)
        ))
}

assert FR_013_OnlyAssignedOfficerDecides {
  FR_013_OnlyAssignedOfficerDecides
}

check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_DecidedApplicationsImmutable {
  (some LoanApplication) implies
    (all app: LoanApplication |
      (app.status = Approved or app.status = Rejected) implies
        (no e: ApplicationEvent | 
          e.application = app and 
          (e.previous_status = Approved or e.previous_status = Rejected)))
}

assert FR_016_DecidedApplicationsImmutable {
  FR_016_DecidedApplicationsImmutable
}

check FR_016_DecidedApplicationsImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditAppendOnly {
  (some ApplicationEvent) implies
    (all e: ApplicationEvent | e in ApplicationEvent)
}

assert FR_018_AuditAppendOnly {
  FR_018_AuditAppendOnly
}

check FR_018_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_CustomerDataExclusivity {
  (some User) implies
    (all u: User, app: LoanApplication |
      (u.role = Customer and u != app.customer) implies
        (no e: ApplicationEvent | e.actor = u and e.application = app))
}

assert FR_020_CustomerDataExclusivity {
  FR_020_CustomerDataExclusivity
}

check FR_020_CustomerDataExclusivity for 5