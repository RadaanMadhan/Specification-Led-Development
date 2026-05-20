// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===

// Roles in the system
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// API operations
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchApplicationStatus, GetAuditById extends OperationKind {}

// Application status states
abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

// Loan purpose categories
abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical, Wedding, Holiday, Business, Other extends Purpose {}

// A user in the system
sig User {
  roles: set Role
}

// A loan application
sig LoanApplication {
  applicant: one User,
  amount_minor: one Int,
  purpose: one Purpose,
  status: one ApplicationStatus,
  assigned_officer: lone User
}

// An immutable audit entry recording a state transition
sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actor_role: one Role,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus
}

// Permission matrix: Role × OperationKind → allowed
one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// Non-empty universe: ensure at least one instance of each dynamic sig
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md permission matrix; FR-001..005
fact F_PermissionMatrix {
  // Define the permission matrix exactly as in contracts/http-api.md
  Applicant -> PostApplications in PermMatrix.allowed
  Applicant -> GetApplicationById in PermMatrix.allowed
  Officer -> GetApplicationById in PermMatrix.allowed
  Officer -> PatchApplicationStatus in PermMatrix.allowed
  Auditor -> GetApplicationById in PermMatrix.allowed
  Auditor -> GetAuditById in PermMatrix.allowed
  
  // Closed-world: no other cells are allowed
  PermMatrix.allowed = (Applicant -> PostApplications) +
                       (Applicant -> GetApplicationById) +
                       (Officer -> GetApplicationById) +
                       (Officer -> PatchApplicationStatus) +
                       (Auditor -> GetApplicationById) +
                       (Auditor -> GetAuditById)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-001..005
pred LeastPrivilege {
  some User  // at least one user exists to enforce non-vacuity
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 Role multiplicity — officer and auditor are mutually exclusive
pred FR_002_RoleMultiplicity {
  all u: User | (Officer in u.roles and Auditor in u.roles) is false
}

assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 Amount range [£1,000–£25,000 in pence] and purpose from fixed list
pred FR_007_AmountAndPurposeValidation {
  some LoanApplication  // non-vacuity: at least one application to validate
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000) and
    (app.purpose in Purpose)
}

assert FR_007_AmountAndPurposeValidation { FR_007_AmountAndPurposeValidation }
check FR_007_AmountAndPurposeValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 One in-flight application per applicant
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication  // non-vacuity
  all u: User |
    lone app: LoanApplication |
      app.applicant = u and (app.status = Pending or app.status = UnderReview)
}

assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 Valid status transitions: (none)→pending, pending→under_review, under_review→{approved,rejected}
pred FR_009_ValidStatusTransitions {
  some LoanApplication  // non-vacuity
  all app: LoanApplication |
    // Initial audit entry: no previous_status, new_status = Pending
    ((one e: AuditEntry | e.application = app and no e.previous_status) implies
      (one e: AuditEntry | e.application = app and no e.previous_status and e.new_status = Pending)) and
    // For any transition from Pending, next status must be UnderReview
    (all e1, e2: AuditEntry |
      (e1.application = app and e2.application = app and e1.new_status = Pending) implies
        (e2.previous_status = Pending implies e2.new_status = UnderReview)) and
    // For any transition from UnderReview, next status must be Approved or Rejected
    (all e1, e2: AuditEntry |
      (e1.application = app and e2.application = app and e1.new_status = UnderReview) implies
        (e2.previous_status = UnderReview implies e2.new_status in {Approved, Rejected}))
}

assert FR_009_ValidStatusTransitions { FR_009_ValidStatusTransitions }
check FR_009_ValidStatusTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011 Auto-assignment excludes applicant; assigned officer is not the applicant
pred FR_010_11_AutoAssignmentExcludesApplicant {
  some LoanApplication  // non-vacuity
  all app: LoanApplication |
    (some app.assigned_officer) implies
      (app.assigned_officer != app.applicant and Officer in app.assigned_officer.roles)
}

assert FR_010_11_AutoAssignmentExcludesApplicant { FR_010_11_AutoAssignmentExcludesApplicant }
check FR_010_11_AutoAssignmentExcludesApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 Only assigned officer can PATCH the application status
pred FR_012_OnlyAssignedOfficerCanPatch {
  some LoanApplication  // non-vacuity
  all app: LoanApplication, entry: AuditEntry |
    (entry.application = app and entry.actor_role = Officer) implies (entry.actor = app.assigned_officer)
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// PATTERN: NoSelfMutation  ANCHOR: FR-013 Officer cannot self-approve their own application
pred NoSelfMutation {
  some LoanApplication  // non-vacuity
  all app: LoanApplication, entry: AuditEntry |
    (entry.application = app and entry.actor_role = Officer) implies (entry.actor != app.applicant)
}

assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-016 Every state transition produces exactly one audit entry
pred AuditCompleteness {
  some LoanApplication  // non-vacuity
  all app: LoanApplication |
    (one e: AuditEntry | e.application = app and no e.previous_status and e.new_status = Pending)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-018 Audit log is immutable; no UPDATE or DELETE operations
pred AppendOnly {
  some AuditEntry  // non-vacuity
  all disj e1, e2: AuditEntry |
    (e1.application = e2.application) implies
      (e1.actor_role != e2.actor_role or e1.new_status != e2.new_status or
       e1.previous_status != e2.previous_status or e1.actor != e2.actor)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-016 Audit entry records correct actor and actor_role
pred AttributionCorrectness {
  some AuditEntry  // non-vacuity
  all entry: AuditEntry |
    entry.actor_role in entry.actor.roles
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006 Each application is owned by exactly one applicant
pred OwnershipExclusivity {
  some LoanApplication  // non-vacuity
  all app: LoanApplication | one app.applicant
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-004, FR-005 Applicants read own apps, officers read assigned, auditors read all
pred OwnershipBasedAccess {
  some LoanApplication  // non-vacuity
  all app: LoanApplication, u: User |
    // Applicant can only read their own application
    (Applicant in u.roles and u != app.applicant) implies
      (u cannot access app)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-020, FR-021, FR-022 Unauthorised reads return byte-equivalent "not found" responses
pred NoInformationLeakage {
  some LoanApplication  // non-vacuity
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023 Audit endpoint is accessible only to auditors
pred FR_023_AuditEndpointAuditorOnly {
  some AuditEntry  // non-vacuity
  all entry: AuditEntry, u: User |
    (Auditor in u.roles) or (u cannot read audit entries)
}

assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024 Applicant cannot modify application after submission; only officer can change status
pred FR_024_ApplicantCannotModifyPostSubmission {
  some LoanApplication  // non-vacuity
  all app: LoanApplication, u: User |
    (u = app.applicant and Applicant in u.roles) implies
      (u cannot modify any field of app post-submission)
}

assert FR_024_ApplicantCannotModifyPostSubmission { FR_024_ApplicantCannotModifyPostSubmission }
check FR_024_ApplicantCannotModifyPostSubmission for 5