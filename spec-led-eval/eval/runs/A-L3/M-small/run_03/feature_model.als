// === feature_model.als — Alloy model for FCA-Regulated Loan Application (005-fca-loan-applications) ===

// Roles in the system
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// Application statuses
abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

// Loan purposes (fixed list)
abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical,
           Wedding, Holiday, Business, Other extends Purpose {}

// API operations
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchApplicationStatus, GetAuditTrail extends OperationKind {}

// Users in the system
sig User {
  roles: set Role
}

// Loan applications
sig LoanApplication {
  applicant: one User,          // Who submitted the application
  amount_minor: one Int,        // Amount in pence
  purpose: one Purpose,         // Chosen from fixed list
  status: one ApplicationStatus, // Current status
  assigned_officer: lone User,  // Officer assigned (can be null if no eligible officer)
  submitted_at: one Int         // Submission timestamp (proxy)
}

// Audit entries — immutable, append-only
sig AuditEntry {
  application: one LoanApplication,
  actor: one User,              // User who caused the transition
  actor_role: one Role,         // Role used for this action
  previous_status: lone ApplicationStatus,  // Null only for initial submission
  new_status: one ApplicationStatus,
  reason: one String,           // Non-empty reason for the transition
  occurred_at: one Int          // Timestamp proxy
}

// Permission matrix as singleton sig with field
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ==============================================================================
// NON-EMPTY UNIVERSE FACT
// ==============================================================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some OperationKind
  some Role
}

// ==============================================================================
// PATTERN: LeastPrivilege
// ==============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003, FR-004, FR-005
pred LeastPrivilege {
  some User and some OperationKind and some Role implies (
    // Applicant: POST, GET own only
    (Applicant -> PostApplications in PermMatrix.Allowed) and
    (Applicant -> GetApplicationById in PermMatrix.Allowed) and
    (Applicant -> PatchApplicationStatus !in PermMatrix.Allowed) and
    (Applicant -> GetAuditTrail !in PermMatrix.Allowed) and
    
    // Officer: GET assigned, PATCH assigned, no POST or audit
    (Officer -> PostApplications !in PermMatrix.Allowed) and
    (Officer -> GetApplicationById in PermMatrix.Allowed) and
    (Officer -> PatchApplicationStatus in PermMatrix.Allowed) and
    (Officer -> GetAuditTrail !in PermMatrix.Allowed) and
    
    // Auditor: read-only access to everything
    (Auditor -> PostApplications !in PermMatrix.Allowed) and
    (Auditor -> GetApplicationById in PermMatrix.Allowed) and
    (Auditor -> PatchApplicationStatus !in PermMatrix.Allowed) and
    (Auditor -> GetAuditTrail in PermMatrix.Allowed)
  )
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5 but exactly 3 Role, exactly 4 OperationKind

// ==============================================================================
// PATTERN: AuthRequiredEverywhere
// ==============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md authentication
pred AuthRequiredEverywhere {
  all app: LoanApplication |
    (some ae: AuditEntry | ae.application = app)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ==============================================================================
// PATTERN: AuditCompleteness
// ==============================================================================

// PATTERN: AuditCompleteness  ANCHOR: FR-016; data-model.md AuditEntry structure
pred AuditCompleteness {
  some LoanApplication and some AuditEntry implies (
    all app: LoanApplication |
      (some ae: AuditEntry |
        ae.application = app and
        ae.previous_status = none and
        ae.new_status = Pending
      )
  )
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ==============================================================================
// PATTERN: AppendOnly
// ==============================================================================

// PATTERN: AppendOnly  ANCHOR: FR-018, FR-019; data-model.md "audit log MUST be immutable"
pred AppendOnly {
  some AuditEntry implies (
    all disj ae1, ae2: AuditEntry |
      ae1.application = ae2.application implies (
        ae1.occurred_at != ae2.occurred_at
      )
  )
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ==============================================================================
// PATTERN: OwnershipExclusivity
// ==============================================================================

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication; spec.md ownership
pred OwnershipExclusivity {
  all app: LoanApplication |
    (one user: User | user = app.applicant)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ==============================================================================
// PATTERN: OwnershipBasedAccess
// ==============================================================================

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-004; spec.md applicant self-access
pred OwnershipBasedAccess {
  all app: LoanApplication, user: User |
    (Applicant in user.roles and GetApplicationById in PermMatrix.Allowed[Applicant]) implies (
      user = app.applicant
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ==============================================================================
// PATTERN: NoInformationLeakage
// ==============================================================================

// PATTERN: NoInformationLeakage  ANCHOR: FR-020, FR-021; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
  all app: LoanApplication, user: User |
    (user != app.applicant and Auditor !in user.roles) implies (
      GetApplicationById !in PermMatrix.Allowed[user]
    )
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ==============================================================================
// PATTERN: NoSelfMutation
// ==============================================================================

// PATTERN: NoSelfMutation  ANCHOR: FR-013 (no self-approval); spec.md FR-013
pred NoSelfMutation {
  some LoanApplication implies (
    all app: LoanApplication |
      (app.assigned_officer != none) implies (app.assigned_officer != app.applicant)
  )
}

assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// ==============================================================================
// FEATURE-SPECIFIC PREDICATES
// ==============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer before business logic
pred FR_001_AuthRequired {
  some LoanApplication and some AuditEntry implies (
    all app: LoanApplication |
      (some ae: AuditEntry | ae.application = app)
  )
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 role multiplicity (officer and auditor mutually exclusive)
pred FR_002_RoleMultiplicity {
  all user: User |
    not (Officer in user.roles and Auditor in user.roles)
}

assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 amount range and fixed purpose list validation
pred FR_007_ValidationConstraints {
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000)
}

assert FR_007_ValidationConstraints { FR_007_ValidationConstraints }
check FR_007_ValidationConstraints for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight application per applicant
pred FR_008_OneInFlightPerApplicant {
  all user: User |
    lone app: LoanApplication |
      app.applicant = user and
      (app.status = Pending or app.status = UnderReview)
}

assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 allowed status transitions
pred FR_009_AllowedTransitions {
  all ae: AuditEntry |
    let prev = ae.previous_status |
    let curr = ae.new_status |
    (prev = none implies curr = Pending) and
    (prev = Pending implies curr = UnderReview) and
    (prev = UnderReview implies (curr = Approved or curr = Rejected))
}

assert FR_009_AllowedTransitions { FR_009_AllowedTransitions }
check FR_009_AllowedTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011 auto-assignment excludes applicant
pred FR_010_AssignmentExcludesApplicant {
  all app: LoanApplication |
    app.assigned_officer != none implies app.assigned_officer != app.applicant
}

assert FR_010_AssignmentExcludesApplicant { FR_010_AssignmentExcludesApplicant }
check FR_010_AssignmentExcludesApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 only assigned officer can PATCH status
pred FR_012_OnlyAssignedOfficerCanModify {
  all ae: AuditEntry |
    ae.previous_status != none implies (
      Officer in ae.actor_role and ae.actor = ae.application.assigned_officer
    )
}

assert FR_012_OnlyAssignedOfficerCanModify { FR_012_OnlyAssignedOfficerCanModify }
check FR_012_OnlyAssignedOfficerCanModify for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 officer cannot decide their own application
pred FR_013_NoSelfApproval {
  some AuditEntry implies (
    all ae: AuditEntry |
      ae.previous_status != none implies ae.actor != ae.application.applicant
  )
}

assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 reason field required on transitions
pred FR_014_ReasonRequired {
  all ae: AuditEntry | ae.reason != ""
}

assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 no changes to decided applications
pred FR_015_NoChangesToDecided {
  all app: LoanApplication, ae: AuditEntry |
    (app.status = Approved or app.status = Rejected) implies
    (ae.application != app or ae.previous_status = none)
}

assert FR_015_NoChangesToDecided { FR_015_NoChangesToDecided }
check FR_015_NoChangesToDecided for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 auditor read-only access
pred FR_005_AuditorReadOnly {
  (Auditor -> PostApplications !in PermMatrix.Allowed) and
  (Auditor -> PatchApplicationStatus !in PermMatrix.Allowed)
}

assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5 but exactly 3 Role, exactly 4 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-023 audit endpoint auditor-only
pred FR_023_AuditEndpointAuditorOnly {
  (Auditor -> GetAuditTrail in PermMatrix.Allowed) and
  (Applicant -> GetAuditTrail !in PermMatrix.Allowed) and
  (Officer -> GetAuditTrail !in PermMatrix.Allowed)
}

assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5 but exactly 3 Role, exactly 4 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-024 applicant immutability post-submission
pred FR_024_ApplicantPostSubmissionImmutability {
  (Applicant -> PostApplications in PermMatrix.Allowed) and
  (Applicant -> PatchApplicationStatus !in PermMatrix.Allowed)
}

assert FR_024_ApplicantPostSubmissionImmutability { FR_024_ApplicantPostSubmissionImmutability }
check FR_024_ApplicantPostSubmissionImmutability for 5 but exactly 3 Role, exactly 4 OperationKind

// ==============================================================================
// NAMED CONSTRAINT FACTS
// ==============================================================================

// ANCHOR: contracts/http-api.md permission matrix definition
fact F_PermissionMatrix {
  // Applicant: POST (submit), GET own application only
  (Applicant -> PostApplications) in PermMatrix.Allowed and
  (Applicant -> GetApplicationById) in PermMatrix.Allowed and
  (Applicant -> PatchApplicationStatus) !in PermMatrix.Allowed and
  (Applicant -> GetAuditTrail) !in PermMatrix.Allowed and
  
  // Officer: GET assigned, PATCH assigned status only
  (Officer -> PostApplications) !in PermMatrix.Allowed and
  (Officer -> GetApplicationById) in PermMatrix.Allowed and
  (Officer -> PatchApplicationStatus) in PermMatrix.Allowed and
  (Officer -> GetAuditTrail) !in PermMatrix.Allowed and
  
  // Auditor: read-only everywhere
  (Auditor -> PostApplications) !in PermMatrix.Allowed and
  (Auditor -> GetApplicationById) in PermMatrix.Allowed and
  (Auditor -> PatchApplicationStatus) !in PermMatrix.Allowed and
  (Auditor -> GetAuditTrail) in PermMatrix.Allowed and
  
  // Closed-world assumption
  PermMatrix.Allowed = (
    (Applicant -> PostApplications) +
    (Applicant -> GetApplicationById) +
    (Officer -> GetApplicationById) +
    (Officer -> PatchApplicationStatus) +
    (Auditor -> GetApplicationById) +
    (Auditor -> GetAuditTrail)
  )
}

// ANCHOR: FR-007; data-model.md amount_minor CHECK constraint
fact F_AmountRange {
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000)
}

// ANCHOR: FR-010, FR-011; data-model.md CHECK constraint on assignment
fact F_OfficerAssignmentConstraint {
  all app: LoanApplication |
    (app.assigned_officer != none) implies (app.assigned_officer != app.applicant)
}

// ANCHOR: FR-009; data-model.md status state machine
fact F_ValidStatusTransitions {
  all ae: AuditEntry |
    let prev = ae.previous_status |
    let curr = ae.new_status |
    (prev = none implies curr = Pending) and
    (prev = Pending implies curr = UnderReview) and
    (prev = UnderReview implies (curr = Approved or curr = Rejected)) and
    (prev = Approved implies false) and
    (prev = Rejected implies false)
}

// ANCHOR: FR-008; data-model.md unique index on in-flight applications
fact F_OneInFlightPerApplicant {
  all user: User |
    lone app: LoanApplication |
      app.applicant = user and
      (app.status = Pending or app.status = UnderReview)
}

// ANCHOR: FR-002; data-model.md roles CHECK constraint
fact F_RoleMultiplicity {
  all user: User |
    not (Officer in user.roles and Auditor in user.roles)
}

// ANCHOR: FR-016, FR-014; data-model.md audit entry fields
fact F_AuditEntryConsistency {
  all ae: AuditEntry |
    ae.application in LoanApplication and
    ae.actor in User and
    ae.actor_role in Role and
    ae.reason != ""
}

// ANCHOR: FR-016; audit entry initial submission requirement
fact F_InitialAuditEntry {
  all app: LoanApplication |
    some ae: AuditEntry |
      ae.application = app and
      ae.previous_status = none and
      ae.new_status = Pending
}

// ANCHOR: FR-013, FR-012; defense-in-depth on officer decision constraints
fact F_OfficerDecisionConstraints {
  all ae: AuditEntry |
    ae.previous_status != none implies (
      (Officer in ae.actor_role) and
      (ae.actor = ae.application.assigned_officer) and
      (ae.actor != ae.application.applicant)
    )
}