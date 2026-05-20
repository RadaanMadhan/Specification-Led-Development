// === feature_model.als — Alloy model for 004-loan-application-rbac ===

// ============ Role definitions ============

abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ============ User definitions ============

sig User {
  role: one Role
}

// ============ Application status ============

abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ============ Loan application ============

sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assignedOfficer: lone User
}

// ============ Decision ============

sig Decision {
  application: one LoanApplication,
  decidedBy: one User
}

// ============ Audit entry ============

sig AuditEntry {
  application: one LoanApplication,
  previousStatus: lone ApplicationStatus,
  newStatus: one ApplicationStatus,
  actor: one User
}

// ============ Operation kinds (for permission matrix) ============

abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, GetApplication, ClaimApplication, DecideApplication, GetAudit extends OperationKind {}

// ============ Permission matrix ============

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============ Non-empty universe ============

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// ============ Structural Facts (Invariants) ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002, FR-003, FR-004
fact F_PermissionMatrix {
  PermMatrix.Allowed = (
    Customer -> SubmitApplication +
    Customer -> ListApplications +
    Customer -> GetApplication +
    LoanOfficer -> ListApplications +
    LoanOfficer -> GetApplication +
    LoanOfficer -> ClaimApplication +
    LoanOfficer -> DecideApplication +
    LoanOfficer -> GetAudit +
    ComplianceReviewer -> ListApplications +
    ComplianceReviewer -> GetApplication +
    ComplianceReviewer -> GetAudit
  )
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthenticationRequired {
  all u: User | one u.role
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005; data-model.md LoanApplication.customer
fact F_OwnershipExclusivity {
  all app: LoanApplication | one app.customer
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 - one in-flight per customer
fact F_OneInFlightPerCustomer {
  all c: User | #{app: LoanApplication | app.customer = c and (app.status = Submitted or app.status = UnderReview)} <= 1
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 - assignment consistency with status
fact F_AssignmentConsistency { /* MUTATED — body cleared by validator */ }

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md ApplicationEvent
fact F_AuditCompleteness {
  all app: LoanApplication |
    (app.status = Submitted implies (one ae: AuditEntry | ae.application = app and ae.newStatus = Submitted and ae.previousStatus = none)) and
    (app.status = UnderReview implies (one ae: AuditEntry | ae.application = app and ae.newStatus = UnderReview and ae.previousStatus = Submitted)) and
    (app.status = Approved implies (one ae: AuditEntry | ae.application = app and ae.newStatus = Approved and ae.previousStatus = UnderReview)) and
    (app.status = Rejected implies (one ae: AuditEntry | ae.application = app and ae.newStatus = Rejected and ae.previousStatus = UnderReview))
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries {
  all ae: AuditEntry | ae in AuditEntry
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md ApplicationEvent.actor_user_id
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    (ae.newStatus = Submitted implies ae.actor.role = Customer) and
    (ae.newStatus = UnderReview implies ae.actor.role = LoanOfficer) and
    ((ae.newStatus = Approved or ae.newStatus = Rejected) implies (ae.actor.role = LoanOfficer and ae.actor = ae.application.assignedOfficer))
}

// FEATURE-SPECIFIC  ANCHOR: FR-013 - only assigned officer can decide
fact F_OnlyAssignedOfficerDecides {
  all dec: Decision |
    (dec.decidedBy = dec.application.assignedOfficer and dec.decidedBy.role = LoanOfficer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-016 - immutability of decided applications
fact F_ImmutabilityOfDecidedApplications {
  all app: LoanApplication |
    ((app.status = Approved or app.status = Rejected) implies (one dec: Decision | dec.application = app))
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md scoping rules
fact F_OwnershipBasedAccess {
  all app: LoanApplication | one app.customer
}

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023 - compliance reviewer read-only
fact F_ComplianceReviewerReadOnly {
  (ComplianceReviewer -> SubmitApplication not in PermMatrix.Allowed) and
  (ComplianceReviewer -> ClaimApplication not in PermMatrix.Allowed) and
  (ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed)
}

// ============ Predicates and Assertions ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-002, FR-003, FR-004
pred LeastPrivilege {
  (Customer -> SubmitApplication in PermMatrix.Allowed) and
  (LoanOfficer -> DecideApplication in PermMatrix.Allowed) and
  (ComplianceReviewer -> GetAudit in PermMatrix.Allowed) and
  (ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed) and
  (some ae: AuditEntry | ae.application in LoanApplication)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all u: User | (one u.role)
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005
pred OwnershipExclusivity {
  some app: LoanApplication | (one app.customer)
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020
pred OwnershipBasedAccessCheck {
  all c: User |
    c.role = Customer implies (
      (some app: LoanApplication | app.customer = c) or
      (no app: LoanApplication | app.customer = c)
    )
}

assert OwnershipBasedAccessCheck {
  OwnershipBasedAccessCheck
}

check OwnershipBasedAccessCheck for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  some app: LoanApplication |
    (app.status = UnderReview implies (one ae: AuditEntry | ae.application = app and ae.newStatus = UnderReview and ae.previousStatus = Submitted)) and
    (app.status = Approved implies (one ae: AuditEntry | ae.application = app and ae.newStatus = Approved and ae.previousStatus = UnderReview)) and
    (#{ae: AuditEntry | ae.application = app and ae.newStatus = UnderReview} = 1 or #{ae: AuditEntry | ae.application = app and ae.newStatus = UnderReview} = 0)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018
pred AppendOnly {
  some ae: AuditEntry | ae.application in LoanApplication
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017
pred AttributionCorrectness {
  all ae: AuditEntry |
    (ae.newStatus = Submitted implies ae.actor.role = Customer) and
    (ae.newStatus = UnderReview implies ae.actor.role = LoanOfficer) and
    ((ae.newStatus = Approved or ae.newStatus = Rejected) implies ae.actor.role = LoanOfficer)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 - one in-flight per customer
pred FR_008_OneInFlightPerCustomer {
  some c: User |
    c.role = Customer and
    (#{app: LoanApplication | app.customer = c and (app.status = Submitted or app.status = UnderReview)} <= 1)
}

assert FR_008_OneInFlightPerCustomer {
  FR_008_OneInFlightPerCustomer
}

check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 - assignment consistency
pred FR_012_AssignmentConsistency {
  some app: LoanApplication |
    ((app.status = UnderReview or app.status = Approved or app.status = Rejected) implies (app.assignedOfficer != none and app.assignedOfficer.role = LoanOfficer))
}

assert FR_012_AssignmentConsistency {
  FR_012_AssignmentConsistency
}

check FR_012_AssignmentConsistency for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 - only assigned officer decides
pred FR_013_OnlyAssignedOfficerDecides {
  some dec: Decision | dec.decidedBy = dec.application.assignedOfficer
}

assert FR_013_OnlyAssignedOfficerDecides {
  FR_013_OnlyAssignedOfficerDecides
}

check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 - immutability of decided applications
pred FR_016_ImmutabilityOfDecidedApplications {
  some app: LoanApplication |
    ((app.status = Approved or app.status = Rejected) implies (one dec: Decision | dec.application = app))
}

assert FR_016_ImmutabilityOfDecidedApplications {
  FR_016_ImmutabilityOfDecidedApplications
}

check FR_016_ImmutabilityOfDecidedApplications for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023 - compliance reviewer read-only
pred FR_004_ComplianceReviewerReadOnly {
  (ComplianceReviewer -> SubmitApplication not in PermMatrix.Allowed) and
  (ComplianceReviewer -> ClaimApplication not in PermMatrix.Allowed) and
  (ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed) and
  (ComplianceReviewer -> GetAudit in PermMatrix.Allowed)
}

assert FR_004_ComplianceReviewerReadOnly {
  FR_004_ComplianceReviewerReadOnly
}

check FR_004_ComplianceReviewerReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 - customer limited operations
pred FR_002_CustomerOperations {
  some u: User |
    u.role = Customer and
    (Customer -> SubmitApplication in PermMatrix.Allowed) and
    (Customer -> DecideApplication not in PermMatrix.Allowed)
}

assert FR_002_CustomerOperations {
  FR_002_CustomerOperations
}

check FR_002_CustomerOperations for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AssignmentConsistencyViolation { some app: LoanApplication | (app.status = UnderReview or app.status = Approved or app.status = Rejected) and app.assignedOfficer = none }
