// === feature_model.als — Alloy model for 004-loan-application-rbac ===
// Loan Application with Role-Based Workflow and Audit Trail

// ============================================================================
// ABSTRACT TYPES
// ============================================================================

abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById, ClaimApplication, DecideApplication, GetAudit extends OperationKind {}

// ============================================================================
// CONCRETE ENTITIES (DYNAMIC SIGS)
// ============================================================================

sig User {
  role: one Role
}

sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assignedOfficer: lone User,
  submittedAt: one Int
}

sig Decision {
  application: one LoanApplication,
  decisionType: one DecisionType,
  reason: one String,
  decidedByOfficer: one User,
  decidedAt: one Int
}

sig AuditEntry {
  application: one LoanApplication,
  previousStatus: lone ApplicationStatus,
  newStatus: one ApplicationStatus,
  actor: one User,
  occurredAt: one Int
}

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============================================================================
// NON-EMPTY UNIVERSE
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
}

// ============================================================================
// PERMISSION MATRIX (FR-002, FR-003, FR-004)
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-002, FR-003, FR-004
fact F_PermissionMatrix {
  CustomerRole -> PostApplications in PermMatrix.Allowed
  CustomerRole -> GetApplications in PermMatrix.Allowed
  CustomerRole -> GetApplicationById in PermMatrix.Allowed
  
  LoanOfficerRole -> GetApplications in PermMatrix.Allowed
  LoanOfficerRole -> GetApplicationById in PermMatrix.Allowed
  LoanOfficerRole -> ClaimApplication in PermMatrix.Allowed
  LoanOfficerRole -> DecideApplication in PermMatrix.Allowed
  LoanOfficerRole -> GetAudit in PermMatrix.Allowed
  
  ComplianceReviewerRole -> GetApplications in PermMatrix.Allowed
  ComplianceReviewerRole -> GetApplicationById in PermMatrix.Allowed
  ComplianceReviewerRole -> GetAudit in PermMatrix.Allowed
  
  PermMatrix.Allowed = (CustomerRole -> PostApplications) +
                       (CustomerRole -> GetApplications) +
                       (CustomerRole -> GetApplicationById) +
                       (LoanOfficerRole -> GetApplications) +
                       (LoanOfficerRole -> GetApplicationById) +
                       (LoanOfficerRole -> ClaimApplication) +
                       (LoanOfficerRole -> DecideApplication) +
                       (LoanOfficerRole -> GetAudit) +
                       (ComplianceReviewerRole -> GetApplications) +
                       (ComplianceReviewerRole -> GetApplicationById) +
                       (ComplianceReviewerRole -> GetAudit)
}

// ============================================================================
// AUTHENTICATION (FR-001)
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; spec.md
fact F_AllUsersAuthenticated {
  all u: User | u.role in (CustomerRole + LoanOfficerRole + ComplianceReviewerRole)
}

// ============================================================================
// OWNERSHIP AND CUSTOMER CONSISTENCY (FR-020)
// ============================================================================

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md; FR-020
fact F_ApplicationOwnershipExclusivity {
  all app: LoanApplication | app.customer.role = CustomerRole
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-020; data-model.md
fact F_CustomerOwnershipLink {
  all app: LoanApplication | one app.customer
}

// FEATURE-SPECIFIC  ANCHOR: FR-008, spec.md
fact F_OneInFlightPerCustomer {
  all c: User | c.role = CustomerRole implies
    (lone app: LoanApplication | app.customer = c and app.status in (Submitted + UnderReview))
}

// ============================================================================
// APPLICATION STATE MACHINE
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-011, data-model.md
fact F_AssignmentConsistency {
  all app: LoanApplication |
    (app.status = Submitted implies no app.assignedOfficer) and
    (app.status in (UnderReview + Approved + Rejected) implies app.assignedOfficer != none)
  
  all app: LoanApplication | app.assignedOfficer != none implies app.assignedOfficer.role = LoanOfficerRole
}

// FEATURE-SPECIFIC  ANCHOR: FR-012, spec.md
fact F_UniqueClaim {
  all app: LoanApplication | app.status != Submitted implies
    (lone ao: User | ao = app.assignedOfficer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-016, data-model.md
fact F_ImmutableDecidedApplication {
  all app: LoanApplication | app.status in (Approved + Rejected) implies
    (no ae: AuditEntry | ae.application = app and ae.newStatus in (Submitted + UnderReview))
}

// ============================================================================
// DECISION CONSISTENCY (FR-013, FR-015)
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-015, data-model.md
fact F_DecisionUniqueness {
  all app: LoanApplication |
    (app.status in (Approved + Rejected) iff (one d: Decision | d.application = app))
}

// FEATURE-SPECIFIC  ANCHOR: FR-013, spec.md
fact F_OnlyAssignedOfficerDecides {
  all d: Decision |
    d.application.status in (Approved + Rejected) and
    d.decidedByOfficer = d.application.assignedOfficer
}

// ============================================================================
// AUDIT TRAIL CONSISTENCY (FR-017, FR-018, FR-019)
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: FR-017, FR-019; data-model.md
fact F_AuditTrailCompleteness {
  all app: LoanApplication |
    (app.status = Submitted implies (one ae: AuditEntry | ae.application = app and ae.newStatus = Submitted and ae.previousStatus = none)) and
    (app.status in (UnderReview + Approved + Rejected) implies (one ae: AuditEntry | ae.application = app and ae.newStatus = app.status))
}

// PATTERN: AppendOnly  ANCHOR: FR-018; data-model.md
fact F_AuditAppendOnly {
  // Audit entries are immutable: no two entries with identical transition timestamp
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.previousStatus = ae2.previousStatus and
         ae1.newStatus = ae2.newStatus and
         ae1.occurredAt = ae2.occurredAt)
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-017; data-model.md
fact F_AuditActorCorrectness {
  all ae: AuditEntry |
    (ae.previousStatus = none implies ae.actor = ae.application.customer) and
    (ae.previousStatus = Submitted implies ae.actor.role = LoanOfficerRole) and
    (ae.previousStatus = UnderReview implies ae.actor.role = LoanOfficerRole)
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md
fact F_AllowedStatusTransitions {
  all ae: AuditEntry |
    (ae.previousStatus = none and ae.newStatus = Submitted) or
    (ae.previousStatus = Submitted and ae.newStatus = UnderReview) or
    (ae.previousStatus = UnderReview and ae.newStatus in (Approved + Rejected))
}

// ============================================================================
// ASSERTIONS AND CHECKS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-002, FR-003, FR-004
pred LeastPrivilege {
  some r: Role, op: OperationKind | r -> op in PermMatrix.Allowed
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  PermMatrix.Allowed = (CustomerRole -> PostApplications) +
                       (CustomerRole -> GetApplications) +
                       (CustomerRole -> GetApplicationById) +
                       (LoanOfficerRole -> GetApplications) +
                       (LoanOfficerRole -> GetApplicationById) +
                       (LoanOfficerRole -> ClaimApplication) +
                       (LoanOfficerRole -> DecideApplication) +
                       (LoanOfficerRole -> GetAudit) +
                       (ComplianceReviewerRole -> GetApplications) +
                       (ComplianceReviewerRole -> GetApplicationById) +
                       (ComplianceReviewerRole -> GetAudit)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; spec.md
pred AuthRequiredEverywhere {
  some u: User | u.role in (CustomerRole + LoanOfficerRole + ComplianceReviewerRole)
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-017, FR-019; data-model.md
pred AuditCompleteness {
  some app: LoanApplication | (one ae: AuditEntry | ae.application = app and ae.newStatus = app.status)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-018; data-model.md
pred AppendOnly {
  some ae: AuditEntry | ae in AuditEntry
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-017; data-model.md
pred AttributionCorrectness {
  some ae: AuditEntry | (ae.previousStatus = none implies ae.actor = ae.application.customer)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md; FR-020
pred OwnershipExclusivity {
  some app: LoanApplication | one app.customer
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-020; data-model.md
pred OwnershipBasedAccess {
  some c: User, app: LoanApplication | c.role = CustomerRole and c = app.customer
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-020; contracts/http-api.md
pred NoInformationLeakage {
  all app: LoanApplication | (one c: User | c = app.customer and c.role = CustomerRole)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-006, FR-014; contracts/http-api.md
pred ValidationBeforeMutation {
  some d: Decision | d.reason != ""
}

assert ValidationBeforeMutation {
  ValidationBeforeMutation
}

check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: FR-012; spec.md
pred ConcurrencySafety {
  some app: LoanApplication | app.status = UnderReview implies (one ao: User | ao = app.assignedOfficer)
}

assert ConcurrencySafety {
  ConcurrencySafety
}

check ConcurrencySafety for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001, spec.md
pred FR_001_AuthRequired {
  all u: User | u.role in (CustomerRole + LoanOfficerRole + ComplianceReviewerRole)
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002, spec.md
pred FR_002_CustomerCanSubmitAndView {
  some u: User, app: LoanApplication |
    u.role = CustomerRole and u = app.customer and
    (CustomerRole -> PostApplications in PermMatrix.Allowed and
     CustomerRole -> GetApplications in PermMatrix.Allowed and
     CustomerRole -> GetApplicationById in PermMatrix.Allowed)
}

assert FR_002_CustomerCanSubmitAndView {
  FR_002_CustomerCanSubmitAndView
}

check FR_002_CustomerCanSubmitAndView for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, spec.md
pred FR_003_LoanOfficerCanDecide {
  some u: User, app: LoanApplication |
    u.role = LoanOfficerRole and u = app.assignedOfficer and
    (LoanOfficerRole -> DecideApplication in PermMatrix.Allowed)
}

assert FR_003_LoanOfficerCanDecide {
  FR_003_LoanOfficerCanDecide
}

check FR_003_LoanOfficerCanDecide for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004, spec.md
pred FR_004_ComplianceReviewerCanViewOnly {
  some u: User | u.role = ComplianceReviewerRole and
    (ComplianceReviewerRole -> GetApplicationById in PermMatrix.Allowed and
     ComplianceReviewerRole -> GetAudit in PermMatrix.Allowed and
     not (ComplianceReviewerRole -> DecideApplication in PermMatrix.Allowed))
}

assert FR_004_ComplianceReviewerCanViewOnly {
  FR_004_ComplianceReviewerCanViewOnly
}

check FR_004_ComplianceReviewerCanViewOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, spec.md
pred FR_008_OneInFlightPerCustomer {
  some c: User | c.role = CustomerRole and (lone app: LoanApplication | app.customer = c and app.status in (Submitted + UnderReview))
}

assert FR_008_OneInFlightPerCustomer {
  FR_008_OneInFlightPerCustomer
}

check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012, spec.md
pred FR_012_ConcurrentClaimSafety {
  some app: LoanApplication | app.status in (UnderReview + Approved + Rejected) implies (one ao: User | ao = app.assignedOfficer)
}

assert FR_012_ConcurrentClaimSafety {
  FR_012_ConcurrentClaimSafety
}

check FR_012_ConcurrentClaimSafety for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, spec.md
pred FR_013_OnlyAssignedOfficerDecides {
  some d: Decision | d.decidedByOfficer = d.application.assignedOfficer
}

assert FR_013_OnlyAssignedOfficerDecides {
  FR_013_OnlyAssignedOfficerDecides
}

check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016, spec.md
pred FR_016_ImmutableDecidedApplication {
  some app: LoanApplication | app.status in (Approved + Rejected) implies (no ae: AuditEntry | ae.application = app and ae.newStatus in (Submitted + UnderReview))
}

assert FR_016_ImmutableDecidedApplication {
  FR_016_ImmutableDecidedApplication
}

check FR_016_ImmutableDecidedApplication for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018, spec.md
pred FR_018_AuditAppendOnly {
  some ae: AuditEntry | ae in AuditEntry
}

assert FR_018_AuditAppendOnly {
  FR_018_AuditAppendOnly
}

check FR_018_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019, spec.md
pred FR_019_OneAuditPerStatusChange {
  some app: LoanApplication | (one ae: AuditEntry | ae.application = app and ae.newStatus = app.status)
}

assert FR_019_OneAuditPerStatusChange {
  FR_019_OneAuditPerStatusChange
}

check FR_019_OneAuditPerStatusChange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020, spec.md
pred FR_020_CustomerVisibilityRestriction {
  some c: User, app: LoanApplication | c.role = CustomerRole and c = app.customer
}

assert FR_020_CustomerVisibilityRestriction {
  FR_020_CustomerVisibilityRestriction
}

check FR_020_CustomerVisibilityRestriction for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023, spec.md
pred FR_023_ComplianceReviewerReadOnly {
  some u: User | u.role = ComplianceReviewerRole and
    (not (u.role -> PostApplications in PermMatrix.Allowed) and
     not (u.role -> ClaimApplication in PermMatrix.Allowed) and
     not (u.role -> DecideApplication in PermMatrix.Allowed))
}

assert FR_023_ComplianceReviewerReadOnly {
  FR_023_ComplianceReviewerReadOnly
}

check FR_023_ComplianceReviewerReadOnly for 5