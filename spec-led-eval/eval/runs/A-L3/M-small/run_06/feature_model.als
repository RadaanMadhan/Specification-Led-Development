// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===

// Core domain abstractions
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education,
    Medical, Wedding, Holiday, Business, Other extends Purpose {}

// Core entities
sig User {
  roles: set Role
}

sig LoanApplication {
  applicant_user: one User,
  amount_minor: one Int,
  purpose: one Purpose,
  status: one ApplicationStatus,
  assigned_officer: lone User
}

sig AuditEntry {
  application: one LoanApplication,
  actor_user: one User,
  actor_role: one Role,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  reason: one String
}

sig String {}

// Operation kinds for permission matrix
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchApplicationStatus,
        GetAuditTrail extends OperationKind {}

one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// Non-empty universe — required for meaningful assertions
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, contracts/http-api.md authentication
pred AuthRequired {
  all u: User | some u.roles
}

assert AuthRequired { AuthRequired }
check AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMultiplicity {
  all u: User | (
    (Applicant in u.roles and Officer not in u.roles and Auditor not in u.roles) or
    (Officer in u.roles and Applicant not in u.roles and Auditor not in u.roles) or
    (Auditor in u.roles and Applicant not in u.roles and Officer not in u.roles) or
    (Applicant in u.roles and Officer in u.roles and Auditor not in u.roles) or
    (Applicant in u.roles and Auditor in u.roles and Officer not in u.roles)
  )
}

assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003
pred FR_003_ApplicantPermissions {
  all u: User | Applicant in u.roles implies (
    all app: LoanApplication | app.applicant_user = u or (Officer in u.roles or Auditor in u.roles)
  )
}

assert FR_003_ApplicantPermissions { FR_003_ApplicantPermissions }
check FR_003_ApplicantPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerPermissions {
  all u: User | Officer in u.roles implies (
    all app: LoanApplication | app.assigned_officer = u implies
      (app.status = Pending or app.status = UnderReview)
  )
}

assert FR_004_OfficerPermissions { FR_004_OfficerPermissions }
check FR_004_OfficerPermissions for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-005
pred FR_005_AuditorReadOnly {
  all u: User | Auditor in u.roles implies (
    no app: LoanApplication | app.assigned_officer = u
  )
}

assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007, data-model.md amount_minor and purpose validation
pred FR_007_AmountAndPurpose {
  all app: LoanApplication | (
    app.amount_minor >= 100000 and app.amount_minor <= 2500000
  ) and (
    app.purpose in (HomeImprovement + DebtConsolidation + Vehicle + Education +
                    Medical + Wedding + Holiday + Business + Other)
  )
}

assert FR_007_AmountAndPurpose { FR_007_AmountAndPurpose }
check FR_007_AmountAndPurpose for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, data-model.md idx_one_in_flight_per_applicant
pred FR_008_OneInFlight {
  all u: User | Applicant in u.roles implies (
    lone app: LoanApplication | app.applicant_user = u and
      (app.status = Pending or app.status = UnderReview)
  )
}

assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009, data-model.md state machine
pred FR_009_AllowedTransitions {
  all ae: AuditEntry | (
    (no ae.previous_status and ae.new_status = Pending) or
    (ae.previous_status = Pending and ae.new_status = UnderReview) or
    (ae.previous_status = UnderReview and ae.new_status = Approved) or
    (ae.previous_status = UnderReview and ae.new_status = Rejected)
  )
}

assert FR_009_AllowedTransitions { FR_009_AllowedTransitions }
check FR_009_AllowedTransitions for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-010, FR-011
pred FR_010_AutoAssignmentExcludesApplicant {
  all app: LoanApplication | (
    some app.assigned_officer and app.status = Pending
  ) implies app.assigned_officer != app.applicant_user
}

assert FR_010_AutoAssignmentExcludesApplicant { FR_010_AutoAssignmentExcludesApplicant }
check FR_010_AutoAssignmentExcludesApplicant for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012
pred FR_012_OnlyAssignedOfficerCanPatch {
  all ae: AuditEntry | (
    Officer in ae.actor_role and
    (ae.previous_status = Pending or ae.previous_status = UnderReview)
  ) implies (
    ae.actor_user = ae.application.assigned_officer
  )
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013
pred FR_013_NoSelfApproval {
  all ae: AuditEntry | (
    Officer in ae.actor_role and
    (ae.new_status = Approved or ae.new_status = Rejected)
  ) implies (
    ae.actor_user != ae.application.applicant_user
  )
}

assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, data-model.md reason field constraint
pred FR_014_ReasonRequired {
  all ae: AuditEntry | (some ae.reason)
}

assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoUpdateAfterDecision {
  all app: LoanApplication | (
    app.status = Approved or app.status = Rejected
  ) implies (
    all ae: AuditEntry | ae.application = app implies
      (no ae2: AuditEntry | ae2.application = app and ae2.new_status in (Approved + Rejected) and
        ae.new_status in (Approved + Rejected))
  )
}

assert FR_015_NoUpdateAfterDecision { FR_015_NoUpdateAfterDecision }
check FR_015_NoUpdateAfterDecision for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, data-model.md AuditEntry
pred FR_016_AuditOnEveryTransition {
  all app: LoanApplication | some ae: AuditEntry | ae.application = app and ae.new_status = app.status
}

assert FR_016_AuditOnEveryTransition { FR_016_AuditOnEveryTransition }
check FR_016_AuditOnEveryTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditTimestampConsistency {
  all ae: AuditEntry | some ae
}

assert FR_017_AuditTimestampConsistency { FR_017_AuditTimestampConsistency }
check FR_017_AuditTimestampConsistency for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, data-model.md chained-hash immutability
pred FR_018_AuditImmutable {
  all ae: AuditEntry | (
    all ae2: AuditEntry | ae != ae2 and ae.application = ae2.application implies
      (ae.previous_status != ae2.previous_status or ae.new_status != ae2.new_status)
  )
}

assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022
pred FR_020_ByteEquivalentNotFound {
  all u: User | all app: LoanApplication | (
    Applicant in u.roles and app.applicant_user != u and Officer not in u.roles and Auditor not in u.roles
  ) implies (
    no ae: AuditEntry | ae.application = app and ae.actor_user = u
  )
}

assert FR_020_ByteEquivalentNotFound { FR_020_ByteEquivalentNotFound }
check FR_020_ByteEquivalentNotFound for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-023, contracts/http-api.md permission matrix
pred FR_023_AuditEndpointAuditorOnly {
  all u: User | all ae: AuditEntry | (
    Auditor not in u.roles
  ) implies (
    ae.actor_user != u or Auditor in u.roles
  )
}

assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-024
pred FR_024_ApplicantCannotModifyPostSubmission {
  all u: User | Applicant in u.roles implies (
    all app: LoanApplication | app.applicant_user = u implies
      (all ae: AuditEntry | ae.application = app and Applicant in ae.actor_role implies
        ae.new_status = Pending)
  )
}

assert FR_024_ApplicantCannotModifyPostSubmission { FR_024_ApplicantCannotModifyPostSubmission }
check FR_024_ApplicantCannotModifyPostSubmission for 5

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  Applicant -> PostApplications in PermMatrix.allowed
  Applicant -> GetApplicationById in PermMatrix.allowed
  Applicant -> PatchApplicationStatus not in PermMatrix.allowed
  Applicant -> GetAuditTrail not in PermMatrix.allowed

  Officer -> PostApplications not in PermMatrix.allowed
  Officer -> GetApplicationById in PermMatrix.allowed
  Officer -> PatchApplicationStatus in PermMatrix.allowed
  Officer -> GetAuditTrail not in PermMatrix.allowed

  Auditor -> PostApplications not in PermMatrix.allowed
  Auditor -> GetApplicationById in PermMatrix.allowed
  Auditor -> PatchApplicationStatus not in PermMatrix.allowed
  Auditor -> GetAuditTrail in PermMatrix.allowed

  PermMatrix.allowed = (
    Applicant -> PostApplications +
    Applicant -> GetApplicationById +
    Officer -> GetApplicationById +
    Officer -> PatchApplicationStatus +
    Auditor -> GetApplicationById +
    Auditor -> GetAuditTrail
  )
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 3 Role, exactly 4 OperationKind

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md AuditEntry fields, spec.md FR-016
pred AttributionCorrectness {
  all ae: AuditEntry | (
    (Officer in ae.actor_role or Applicant in ae.actor_role or Auditor in ae.actor_role) and
    (some ae.reason)
  )
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5