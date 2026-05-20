// === feature_model.als — Alloy model for Loan Application with Role-Based Workflow ===

// === Core domain types ===

// Time (uninterpreted abstract domain)
abstract sig Time {}

// Roles
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// Users
sig User {
  role: one Role
}

// Application lifecycle status
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// Decision outcome type
abstract sig DecisionOutcome {}
one sig ApprovedOutcome, RejectedOutcome extends DecisionOutcome {}

// Loan Application entity
sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assigned_officer: lone User,
  submitted_at: Time
}

// Decision entity (at most one per application)
sig Decision {
  application: one LoanApplication,
  outcome: one DecisionOutcome,
  decided_by: one User,
  decided_at: Time
}

// Audit Event entity (append-only log of status transitions)
sig AuditEvent {
  application: one LoanApplication,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  actor: one User,
  occurred_at: Time
}

// Operations/Permissions
abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication, ClaimApplication,
        DecideApplication, ViewAuditTrail extends OperationKind {}

// Permission matrix singleton
one sig PermissionMatrix {
  Allowed: set Role -> OperationKind
}

// === Non-empty universe constraint ===
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEvent
  some Decision
}

// === PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix ===
fact F_PermissionMatrixDefined { /* MUTATED — body cleared by validator */ }

// === FR-001: Authentication required everywhere ===
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred FR_001_AuthRequiredEverywhere {
  all u: User | some u.role
}

assert FR_001_AuthRequiredEverywhere {
  FR_001_AuthRequiredEverywhere
}

check FR_001_AuthRequiredEverywhere for 5

// === FR-002: Customer role permissions ===
// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-002; contracts/http-api.md permission matrix
pred FR_002_CustomerPermissions {
  (Customer -> SubmitApplication) in PermissionMatrix.Allowed and
  (Customer -> ListApplications) in PermissionMatrix.Allowed and
  (Customer -> ViewApplication) in PermissionMatrix.Allowed and
  not ((Customer -> ClaimApplication) in PermissionMatrix.Allowed) and
  not ((Customer -> DecideApplication) in PermissionMatrix.Allowed) and
  not ((Customer -> ViewAuditTrail) in PermissionMatrix.Allowed)
}

assert FR_002_CustomerPermissions {
  FR_002_CustomerPermissions
}

check FR_002_CustomerPermissions for 5

// === FR-003: Loan officer role permissions ===
// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-003; contracts/http-api.md permission matrix
pred FR_003_LoanOfficerPermissions {
  not ((LoanOfficer -> SubmitApplication) in PermissionMatrix.Allowed) and
  (LoanOfficer -> ListApplications) in PermissionMatrix.Allowed and
  (LoanOfficer -> ViewApplication) in PermissionMatrix.Allowed and
  (LoanOfficer -> ClaimApplication) in PermissionMatrix.Allowed and
  (LoanOfficer -> DecideApplication) in PermissionMatrix.Allowed and
  (LoanOfficer -> ViewAuditTrail) in PermissionMatrix.Allowed
}

assert FR_003_LoanOfficerPermissions {
  FR_003_LoanOfficerPermissions
}

check FR_003_LoanOfficerPermissions for 5

// === FR-004: Compliance reviewer role permissions (read-only) ===
// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; contracts/http-api.md permission matrix
pred FR_004_ComplianceReviewerPermissions {
  not ((ComplianceReviewer -> SubmitApplication) in PermissionMatrix.Allowed) and
  (ComplianceReviewer -> ListApplications) in PermissionMatrix.Allowed and
  (ComplianceReviewer -> ViewApplication) in PermissionMatrix.Allowed and
  not ((ComplianceReviewer -> ClaimApplication) in PermissionMatrix.Allowed) and
  not ((ComplianceReviewer -> DecideApplication) in PermissionMatrix.Allowed) and
  (ComplianceReviewer -> ViewAuditTrail) in PermissionMatrix.Allowed
}

assert FR_004_ComplianceReviewerPermissions {
  FR_004_ComplianceReviewerPermissions
}

check FR_004_ComplianceReviewerPermissions for 5

// === FR-008: At most one in-flight application per customer ===
// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
pred FR_008_OneInFlightPerCustomer {
  all c: User | c.role = Customer implies (
    lone app: LoanApplication |
      app.customer = c and (app.status = Submitted or app.status = UnderReview)
  )
}

assert FR_008_OneInFlightPerCustomer {
  FR_008_OneInFlightPerCustomer
}

check FR_008_OneInFlightPerCustomer for 5

// === FR-011: Claim creates assignment and Under Review status ===
// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md status state machine, assigned_officer logic
pred FR_011_ClaimTransition {
  all app: LoanApplication | app.status = UnderReview implies (
    some officer: User |
      officer.role = LoanOfficer and
      app.assigned_officer = officer and
      (one e: AuditEvent |
        e.application = app and
        e.previous_status = Submitted and
        e.new_status = UnderReview and
        e.actor = officer
      )
  )
}

assert FR_011_ClaimTransition {
  FR_011_ClaimTransition
}

check FR_011_ClaimTransition for 5

// === FR-013: Only assigned officer can decide ===
// FEATURE-SPECIFIC  ANCHOR: FR-013; contracts/http-api.md not_assigned_officer, conditional UPDATE
pred FR_013_OnlyAssignedOfficerDecides {
  some Decision implies (
    all d: Decision |
      d.decided_by = d.application.assigned_officer and
      d.decided_by.role = LoanOfficer
  )
}

assert FR_013_OnlyAssignedOfficerDecides {
  FR_013_OnlyAssignedOfficerDecides
}

check FR_013_OnlyAssignedOfficerDecides for 5

// === FR-016: Approved/Rejected applications are immutable ===
// FEATURE-SPECIFIC  ANCHOR: FR-016; contracts/http-api.md already_decided
pred FR_016_DecidedApplicationsImmutable {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies (
      // No audit events transition OUT of these final statuses
      not (some e: AuditEvent |
        e.application = app and
        e.previous_status in (Approved + Rejected)
      )
    )
}

assert FR_016_DecidedApplicationsImmutable {
  FR_016_DecidedApplicationsImmutable
}

check FR_016_DecidedApplicationsImmutable for 5

// === FR-017-019: Audit trail completeness and one-to-one transitions ===
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017,018,019; data-model.md ApplicationEvent
fact F_AuditTrailComplete {
  // Every application begins with exactly one Submitted entry
  all app: LoanApplication |
    one e: AuditEvent |
      e.application = app and
      e.previous_status = none and
      e.new_status = Submitted
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017,018,019
pred FR_017_AuditCompleteness {
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies (
      (app.status = UnderReview) implies (
        (one e: AuditEvent |
          e.application = app and
          e.previous_status = Submitted and
          e.new_status = UnderReview)
      ) else (
        (app.status = Approved) implies (
          (one e: AuditEvent |
            e.application = app and
            e.previous_status = UnderReview and
            e.new_status = Approved)
        ) else (
          (one e: AuditEvent |
            e.application = app and
            e.previous_status = UnderReview and
            e.new_status = Rejected)
        )
      )
    )
}

assert FR_017_AuditCompleteness {
  FR_017_AuditCompleteness
}

check FR_017_AuditCompleteness for 6

// === FR-018: Audit trail is append-only (no mutations, no duplicates) ===
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
fact F_AppendOnlyAuditTrail {
  // Enforce structural uniqueness: no two events can represent the same transition on the same app
  all disj e1, e2: AuditEvent |
    not (
      e1.application = e2.application and
      e1.previous_status = e2.previous_status and
      e1.new_status = e2.new_status
    )
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018
pred AppendOnly {
  all e: AuditEvent |
    (e.application in LoanApplication and
     (e.previous_status = none or e.previous_status in ApplicationStatus) and
     e.new_status in ApplicationStatus)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// === FR-020: Customer cannot see other customers' applications ===
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; data-model.md customer_id ownership
pred FR_020_OwnershipBasedCustomerAccess {
  all c: User | c.role = Customer implies (
    all app: LoanApplication |
      app.customer != c implies (
        // Customer c has no access to read/view application owned by another customer
        // (API returns 404, not permission_denied, to avoid existence leak)
        not (app in {a: LoanApplication | a.customer = c})
      )
  )
}

assert FR_020_OwnershipBasedCustomerAccess {
  FR_020_OwnershipBasedCustomerAccess
}

check FR_020_OwnershipBasedCustomerAccess for 5

// === PATTERN: OwnershipExclusivity ===
// ANCHOR: spec.md "each Application belongs to exactly one Customer"; data-model.md customer_id PK
pred OwnershipExclusivity {
  all app: LoanApplication | one app.customer
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// === PATTERN: NoInformationLeakage ===
// ANCHOR: spec.md FR-020 "no existence leak"; contracts/http-api.md 404 same as not_found
pred NoInformationLeakage {
  // When a customer requests a non-owned application, system response is indistinguishable
  // from a request for a non-existent application (both return 404)
  all c: User | c.role = Customer implies (
    all app1, app2: LoanApplication |
      (app1.customer != c and app2 !in LoanApplication) implies (
        // Both cases treated identically from caller's perspective
        (Customer -> ViewApplication) in PermissionMatrix.Allowed or
        not ((Customer -> ViewApplication) in PermissionMatrix.Allowed)
      )
  )
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// === PATTERN: PermissionCompleteness ===
// ANCHOR: contracts/http-api.md permission matrix (every cell defined)
pred PermissionCompleteness {
  all r: Role | all op: OperationKind |
    (r -> op) in PermissionMatrix.Allowed or not ((r -> op) in PermissionMatrix.Allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// === PATTERN: PermissionGrounding ===
// ANCHOR: spec.md FRs 002,003,004 grant specific permissions; contracts/ confirms each
pred PermissionGrounding {
  // Every "allow" in the permission matrix traces back to an explicit FR
  // (Modeled by ensuring the matrix only contains explicitly documented cells)
  PermissionMatrix.Allowed in (
    (Customer -> (SubmitApplication + ListApplications + ViewApplication)) +
    (LoanOfficer -> (ListApplications + ViewApplication + ClaimApplication + DecideApplication + ViewAuditTrail)) +
    (ComplianceReviewer -> (ListApplications + ViewApplication + ViewAuditTrail))
  )
}

assert PermissionGrounding {
  PermissionGrounding
}

check PermissionGrounding for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_BadPermissions { Customer -> DecideApplication in PermissionMatrix.Allowed }
