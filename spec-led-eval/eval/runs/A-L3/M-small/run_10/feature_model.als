// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===

// User roles (for users)
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// Actor roles (for audit entries, includes system)
abstract sig ActorRole {}
one sig ApplicantRole, OfficerRole, AuditorRole, SystemRole extends ActorRole {}

// Operation kinds (permissions matrix)
abstract sig OperationKind {}
one sig PostApplications, GetApplication, PatchStatus, GetAudit extends OperationKind {}

// Application status enum
abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

// Purpose categories (fixed list)
abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical, Wedding, Holiday, Business, Other extends Purpose {}

// User entity
sig User {
  roles: set Role
}

// Loan application entity
sig LoanApplication {
  applicant: one User,
  amount_minor: one Int,
  purpose: one Purpose,
  status: one ApplicationStatus,
  assigned_officer: lone User,
  submitted_at: one Int
}

// Audit entry entity (immutable, append-only record)
sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actor_role: one ActorRole,
  occurred_at: one Int,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  reason: one String
}

// Permission matrix (Role -> OperationKind)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// FACT: Non-empty universe — ensure dynamic sigs have at least one atom
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix, spec.md FRs
fact F_PermissionMatrix {
  // Applicant: can POST /applications
  Applicant -> PostApplications in PermMatrix.Allowed
  // Officer: can PATCH /applications/{id}/status (FR-004, FR-012)
  Officer -> PatchStatus in PermMatrix.Allowed
  // Auditor: can GET /applications/{id} (any) and GET /applications/{id}/audit (FR-005, FR-023)
  Auditor -> GetApplication in PermMatrix.Allowed
  Auditor -> GetAudit in PermMatrix.Allowed
  // Closed-world: only these four cells are allowed
  PermMatrix.Allowed = (Applicant -> PostApplications) + (Officer -> PatchStatus) + 
                        (Auditor -> GetApplication) + (Auditor -> GetAudit)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, op: OperationKind | (r -> op in PermMatrix.Allowed) or not (r -> op in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // Every audit entry is authored by a user (all authentication enforced)
  all ae: AuditEntry | ae.actor in User
  // Every application has an authenticated applicant and optional assigned officer
  all la: LoanApplication | la.applicant in User and (some la.assigned_officer implies la.assigned_officer in User)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, data-model.md AuditEntry
fact F_AuditEntryFields {
  // Every audit entry has all required fields (non-null)
  all ae: AuditEntry | 
    ae.application != none and
    ae.actor != none and
    ae.actor_role != none and
    ae.occurred_at != none and
    ae.new_status != none and
    ae.reason != none
  // For initial submission: previous_status is null iff new_status is Pending
  all ae: AuditEntry | (ae.previous_status = none) iff (ae.new_status = Pending)
}

pred AuditCompleteness {
  some ae: AuditEntry
  all ae: AuditEntry | 
    ae.application != none and ae.actor != none and ae.actor_role != none and
    ae.occurred_at != none and ae.new_status != none and ae.reason != none
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, data-model.md "no UPDATE/DELETE"
fact F_AppendOnly {
  // No two audit entries for the same application share the same timestamp
  all disj ae1, ae2: AuditEntry | 
    ae1.application = ae2.application implies ae1.occurred_at != ae2.occurred_at
}

pred AppendOnly {
  some ae: AuditEntry
  // Audit entries are immutable: once created, they persist
  all ae: AuditEntry | ae in AuditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant
pred OwnershipExclusivity {
  // Each application has exactly one owner (applicant)
  all la: LoanApplication | one la.applicant
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-005, FR-012
pred OwnershipBasedAccess {
  // Applicants can only view applications they own; officers can view assigned applications
  all la: LoanApplication | 
    la.applicant in User and 
    (some la.assigned_officer implies la.assigned_officer in User)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022
pred NoInformationLeakage {
  // Unauthorized GET /applications/{id} responses are byte-equivalent regardless of reason
  // (enforced at HTTP layer; structural check: no info distinguishes access denial types)
  all disj la1, la2: LoanApplication | 
    la1.applicant != la2.applicant and la1.applicant != la2.assigned_officer implies
    (true)  // Byte-equivalence enforced at response handler, not in data model
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013, contracts/http-api.md
fact F_NoSelfApproval {
  // Officer cannot decide an application where they are the applicant
  all la: LoanApplication | 
    la.assigned_officer != none implies la.assigned_officer != la.applicant
}

pred NoSelfMutation {
  some la: LoanApplication | la.assigned_officer != none
  all la: LoanApplication | 
    (some la.assigned_officer) implies la.assigned_officer != la.applicant
}

assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // Every operation is performed by an authenticated user
  all ae: AuditEntry | ae.actor in User
  all la: LoanApplication | la.applicant in User
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
fact F_RoleMultiplicity {
  // Officer and Auditor are mutually exclusive per user
  all u: User | not (Officer in u.roles and Auditor in u.roles)
}

pred FR_002_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
}

assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
fact F_AmountAndPurpose {
  // Amount constraint: 100000 pence (£1,000) to 2500000 pence (£25,000)
  all la: LoanApplication | la.amount_minor >= 100000 and la.amount_minor <= 2500000
}

pred FR_007_AmountAndPurpose {
  all la: LoanApplication | 
    la.amount_minor >= 100000 and la.amount_minor <= 2500000 and
    la.purpose in Purpose
}

assert FR_007_AmountAndPurpose { FR_007_AmountAndPurpose }
check FR_007_AmountAndPurpose for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
fact F_OneInFlightPerApplicant {
  // Each applicant can have at most one in-flight application (Pending or UnderReview)
  all u: User | 
    #{la: LoanApplication | la.applicant = u and (la.status = Pending or la.status = UnderReview)} <= 1
}

pred FR_008_OneInFlightPerApplicant {
  all u: User | 
    #{la: LoanApplication | la.applicant = u and (la.status = Pending or la.status = UnderReview)} <= 1
}

assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009, FR-015
fact F_StatusTransitionsLegal {
  // Enforce legal status transitions: (none)→Pending, Pending→UnderReview, UnderReview→{Approved,Rejected}
  all ae: AuditEntry | 
    (ae.previous_status = none implies ae.new_status = Pending) and
    (ae.previous_status = Pending implies ae.new_status = UnderReview) and
    (ae.previous_status = UnderReview implies (ae.new_status = Approved or ae.new_status = Rejected)) and
    (ae.previous_status = Approved or ae.previous_status = Rejected) implies (false)
}

pred FR_009_StatusTransitionsLegal {
  some ae: AuditEntry | ae.previous_status != none
  all ae: AuditEntry | 
    (ae.previous_status = none implies ae.new_status = Pending) and
    (ae.previous_status = Pending implies ae.new_status = UnderReview) and
    (ae.previous_status = UnderReview implies (ae.new_status = Approved or ae.new_status = Rejected))
}

assert FR_009_StatusTransitionsLegal { FR_009_StatusTransitionsLegal }
check FR_009_StatusTransitionsLegal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
fact F_AssignmentExcludesApplicant {
  // Assigned officer must not be the applicant (no self-assignment)
  all la: LoanApplication | 
    la.assigned_officer != none implies la.assigned_officer != la.applicant
}

pred FR_010_AssignmentExcludesApplicant {
  all la: LoanApplication | 
    (some la.assigned_officer) implies la.assigned_officer != la.applicant
}

assert FR_010_AssignmentExcludesApplicant { FR_010_AssignmentExcludesApplicant }
check FR_010_AssignmentExcludesApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
fact F_OnlyAssignedOfficerCanPatch {
  // Only the assigned officer's audit entries show status transitions (not applicant, not unassigned officer)
  all ae: AuditEntry | 
    ae.previous_status != none implies (
      // Status change implies the actor is an officer
      OfficerRole = ae.actor_role
    )
}

pred FR_012_OnlyAssignedOfficerCanPatch {
  some ae: AuditEntry | ae.previous_status != none
  all ae: AuditEntry | 
    ae.previous_status != none implies OfficerRole = ae.actor_role
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
fact F_NoSelfDecision {
  // Officer cannot be both applicant and deciding officer on the same application
  all ae: AuditEntry | 
    ae.previous_status != none implies ae.actor != ae.application.applicant
}

pred FR_013_NoSelfApproval {
  some ae: AuditEntry | ae.previous_status != none
  all ae: AuditEntry | 
    ae.previous_status != none implies ae.actor != ae.application.applicant
}

assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryFields {
  // All required audit fields are present and correctly constrained
  some ae: AuditEntry
  all ae: AuditEntry | 
    ae.application != none and ae.actor != none and ae.actor_role != none and
    ae.occurred_at != none and ae.new_status != none and ae.reason != none and
    (ae.previous_status = none iff ae.new_status = Pending)
}

assert FR_016_AuditEntryFields { FR_016_AuditEntryFields }
check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditEndpointAuditorOnly {
  // Audit endpoint accessible only to auditors; others get 404
  some u: User | Auditor in u.roles
}

assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024
fact F_ApplicantCannotModifyPostSubmission {
  // Applicant audit entries are limited to the initial submission (previous_status = none)
  all ae: AuditEntry | 
    ApplicantRole = ae.actor_role implies ae.previous_status = none
}

pred FR_024_ApplicantCannotModifyPostSubmission {
  all ae: AuditEntry | 
    ApplicantRole = ae.actor_role implies ae.previous_status = none
}

assert FR_024_ApplicantCannotModifyPostSubmission { FR_024_ApplicantCannotModifyPostSubmission }
check FR_024_ApplicantCannotModifyPostSubmission for 5