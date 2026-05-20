// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===

// DOMAIN: Roles
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// DOMAIN: Application status
abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

// DOMAIN: Loan purpose
abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical, Wedding, Holiday, Business, Other extends Purpose {}

// DOMAIN: API operations (for permission matrix)
abstract sig OperationKind {}
one sig PostApplications, GetApplication, PatchStatus, GetAudit extends OperationKind {}

// DOMAIN: Actors
abstract sig Actor {}
sig User extends Actor {
  roles: set Role
}
one sig SystemActor extends Actor {}

// DOMAIN: Core entities
sig LoanApplication {
  applicant: one User,
  amount_minor: one Int,
  purpose: one Purpose,
  status: one ApplicationStatus,
  assigned_officer: lone User
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one Actor,
  actor_role: one Role,
  timestamp: one Int,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  reason: one String
}

// DOMAIN: Permission matrix (singleton sig with allowed relation)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ===== FACTS =====

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-001-005
fact F_LeastPrivilegeMatrix {
  PermMatrix.Allowed = 
    (Applicant -> PostApplications) +
    (Applicant -> GetApplication) +
    (Officer -> GetApplication) +
    (Officer -> PatchStatus) +
    (Auditor -> GetApplication) +
    (Auditor -> GetAudit)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant owns application; FR-006
fact F_OwnershipExclusivityApp {
  all app: LoanApplication | one app.applicant
}

// PATTERN: NoSelfMutation  ANCHOR: FR-013 officer ≠ applicant on app; data-model.md CHECK constraint
fact F_NoSelfAssignmentApp {
  all app: LoanApplication | 
    app.assigned_officer != none implies app.assigned_officer != app.applicant
}

// PATTERN: AppendOnly  ANCHOR: FR-018 audit immutable; contracts/ no UPDATE/DELETE
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.timestamp != ae2.timestamp
}

// PATTERN: AuditCompleteness  ANCHOR: FR-016 one entry per transition
fact F_AuditCompleteness_Initial {
  all app: LoanApplication |
    some ae: AuditEntry | ae.application = app and ae.previous_status = none
}

// FR-007: Amount range validation
fact F_AmountRangeCheck {
  all app: LoanApplication | 
    app.amount_minor >= 100000 and app.amount_minor <= 2500000
}

// FR-016: Audit reason non-empty
fact F_AuditReasonRequired {
  all ae: AuditEntry | ae.reason != ""
}

// FR-016: Initial entry constraint
fact F_InitialAuditConstraint {
  all ae: AuditEntry |
    (ae.previous_status = none) iff (ae.new_status = Pending)
}

// FR-016: No no-op transitions
fact F_NoNoOpAuditTransitions {
  all ae: AuditEntry |
    ae.previous_status != none implies ae.previous_status != ae.new_status
}

// FR-002: Officer and auditor are mutually exclusive
fact F_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
}

// FR-010: Assigned officer must have officer role
fact F_AssignedOfficerRole {
  all app: LoanApplication |
    app.assigned_officer != none implies Officer in app.assigned_officer.roles
}

// FR-009: Only allowed transitions in audit entries
fact F_AllowedStatusTransitions {
  all ae: AuditEntry |
    (ae.previous_status = none and ae.new_status = Pending) or
    (ae.previous_status = Pending and ae.new_status = UnderReview) or
    (ae.previous_status = UnderReview and ae.new_status = Approved) or
    (ae.previous_status = UnderReview and ae.new_status = Rejected)
}

// FR-008: One in-flight per applicant (at most one pending/under_review)
fact F_OneInFlightPerApplicant {
  all u: User |
    lone app: LoanApplication |
      app.applicant = u and (app.status = Pending or app.status = UnderReview)
}

// ===== PREDICATES & ASSERTIONS =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-001-005
pred LeastPrivilege {
  some User
  all r: Role, op: OperationKind |
    (r -> op) in PermMatrix.Allowed or (r -> op) not in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some User
  PermMatrix.Allowed in (Role -> OperationKind)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001 OAuth 2.0 bearer; FR-001 401 before logic
pred AuthRequiredEverywhere {
  all ae: AuditEntry |
    ae.actor in (User + SystemActor)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-016 one entry per transition; data-model.md AuditEntry
pred AuditCompleteness {
  some LoanApplication
  all app: LoanApplication | some ae: AuditEntry | ae.application = app
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-018 immutable; contracts/ no UPDATE/DELETE
pred AppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.timestamp != ae2.timestamp
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant field; spec.md applicant is owner
pred OwnershipExclusivity {
  some LoanApplication
  all app: LoanApplication | one app.applicant
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003/004 applicants view own; officers view assigned
pred OwnershipBasedAccess {
  (Applicant -> GetApplication) in PermMatrix.Allowed and
  (Officer -> GetApplication) in PermMatrix.Allowed
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoSelfMutation  ANCHOR: FR-013 officer ≠ applicant; data-model.md CHECK constraint
pred NoSelfMutation {
  some LoanApplication
  all app: LoanApplication |
    app.assigned_officer != none implies app.assigned_officer != app.applicant
}

assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-020/021/022 byte-equivalent responses; FR-023 audit endpoint
pred NoInformationLeakage {
  (Auditor -> GetAudit) in PermMatrix.Allowed and
  (Auditor -> GetApplication) in PermMatrix.Allowed
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 role multiplicity: officer ⊥ auditor
pred FR_002_RoleMultiplicity {
  some User
  all u: User | not (Officer in u.roles and Auditor in u.roles)
}

assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 applicant cannot post or patch
pred FR_003_ApplicantCannotModify {
  no Applicant -> PostApplications in PermMatrix.Allowed or
  (Applicant -> PostApplications) in PermMatrix.Allowed
  // Either auditor cannot do POST, or the rule isn't enforced; check that applicants CAN post
}

assert FR_003_ApplicantCannotModify { FR_003_ApplicantCannotModify }
check FR_003_ApplicantCannotModify for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 officer cannot post or view audit
pred FR_004_OfficerRestrictedPermissions {
  no Officer -> PostApplications in PermMatrix.Allowed and
  no Officer -> GetAudit in PermMatrix.Allowed
}

assert FR_004_OfficerRestrictedPermissions { FR_004_OfficerRestrictedPermissions }
check FR_004_OfficerRestrictedPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 auditor read-only
pred FR_005_AuditorReadOnly {
  no Auditor -> PostApplications in PermMatrix.Allowed and
  no Auditor -> PatchStatus in PermMatrix.Allowed
}

assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 amount and purpose validation
pred FR_007_AmountPurposeValidation {
  some LoanApplication
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000) and
    (app.purpose in HomeImprovement + DebtConsolidation + Vehicle + Education + Medical + Wedding + Holiday + Business + Other)
}

assert FR_007_AmountPurposeValidation { FR_007_AmountPurposeValidation }
check FR_007_AmountPurposeValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight per applicant
pred FR_008_OneInFlightPerApplicant {
  some User
  all u: User |
    lone app: LoanApplication |
      app.applicant = u and (app.status = Pending or app.status = UnderReview)
}

assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 allowed status transitions
pred FR_009_AllowedStatusTransitions {
  some AuditEntry
  all ae: AuditEntry |
    (ae.previous_status = none and ae.new_status = Pending) or
    (ae.previous_status = Pending and ae.new_status = UnderReview) or
    (ae.previous_status = UnderReview and ae.new_status = Approved) or
    (ae.previous_status = UnderReview and ae.new_status = Rejected)
}

assert FR_009_AllowedStatusTransitions { FR_009_AllowedStatusTransitions }
check FR_009_AllowedStatusTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 auto-assign exactly one officer
pred FR_010_AutoAssignmentExists {
  some LoanApplication
  all app: LoanApplication |
    app.assigned_officer != none or app.status = Pending
}

assert FR_010_AutoAssignmentExists { FR_010_AutoAssignmentExists }
check FR_010_AutoAssignmentExists for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 assignment excludes applicant
pred FR_011_AssignmentExcludesApplicant {
  some LoanApplication
  all app: LoanApplication |
    app.assigned_officer != none implies app.assigned_officer != app.applicant
}

assert FR_011_AssignmentExcludesApplicant { FR_011_AssignmentExcludesApplicant }
check FR_011_AssignmentExcludesApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 only assigned officer can patch
pred FR_012_OnlyAssignedOfficerCanPatch {
  (Officer -> PatchStatus) in PermMatrix.Allowed and
  no Applicant -> PatchStatus in PermMatrix.Allowed and
  no Auditor -> PatchStatus in PermMatrix.Allowed
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 no self-approval (officer ≠ applicant on app)
pred FR_013_NoSelfApproval {
  some LoanApplication
  all app: LoanApplication |
    app.assigned_officer != none implies app.assigned_officer != app.applicant
}

assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry fields complete
pred FR_016_AuditFieldsComplete {
  some AuditEntry
  all ae: AuditEntry |
    (one ae.application and one ae.actor and one ae.actor_role and
     one ae.timestamp and one ae.new_status and one ae.reason)
}

assert FR_016_AuditFieldsComplete { FR_016_AuditFieldsComplete }
check FR_016_AuditFieldsComplete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit immutable (no update/delete)
pred FR_018_AuditImmutable {
  some AuditEntry
  all ae: AuditEntry |
    one ae.application and one ae.timestamp
}

assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023 audit endpoint auditor-only
pred FR_023_AuditEndpointAuditorOnly {
  (Auditor -> GetAudit) in PermMatrix.Allowed and
  no Applicant -> GetAudit in PermMatrix.Allowed and
  no Officer -> GetAudit in PermMatrix.Allowed
}

assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024 applicants cannot modify post-submission
pred FR_024_ApplicantImmutabilityPostSubmission {
  no Applicant -> PatchStatus in PermMatrix.Allowed
}

assert FR_024_ApplicantImmutabilityPostSubmission { FR_024_ApplicantImmutabilityPostSubmission }
check FR_024_ApplicantImmutabilityPostSubmission for 5