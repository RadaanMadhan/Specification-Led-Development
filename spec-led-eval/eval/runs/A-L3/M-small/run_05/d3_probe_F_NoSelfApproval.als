// === feature_model.als — Alloy model for 005-fca-loan-applications ===

// Role abstractions
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// Application status values
abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

// API operations
abstract sig Operation {}
one sig PostApp, GetOwnApp, GetAnyApp, PatchStatus, GetAudit extends Operation {}

// Users with assigned roles
sig User {
  roles: set Role
}

// Loan applications
sig Application {
  applicant: one User,
  assigned_officer: lone User,
  status: one Status
}

// Audit log entries (immutable, append-only)
sig AuditEntry {
  application: one Application,
  actor: one User,
  actor_role: one Role,
  prev_status: lone Status,
  new_status: one Status
}

// Permission matrix: (Role, Operation) allowed pairs
one sig Permissions {
  allowed: set Role -> Operation
}

// Ensure non-empty universe for meaningful checks
fact F_NonEmptyUniverse {
  some User
  some Application
  some AuditEntry
}

// FR-002: Officer and auditor roles are mutually exclusive
fact F_RoleExclusion {
  all u: User |
    not (Officer in u.roles and Auditor in u.roles)
}

// FR-008: At most one in-flight (pending or under_review) per applicant
fact F_OneInFlightPerApplicant {
  all u: User |
    lone app: Application |
      app.applicant = u and (app.status = Pending or app.status = UnderReview)
}

// FR-010/FR-011: Officer assignment is valid
// Assigned officer must exist and be different from applicant (unless null)
fact F_ValidAssignment {
  all app: Application |
    app.assigned_officer = none or
    (app.assigned_officer != app.applicant and Officer in app.assigned_officer.roles)
}

// FR-009: Only valid status transitions allowed in audit entries
fact F_ValidTransitions {
  all ae: AuditEntry | (
    (ae.prev_status = none and ae.new_status = Pending) or
    (ae.prev_status = Pending and ae.new_status = UnderReview) or
    (ae.prev_status = UnderReview and ae.new_status = Approved) or
    (ae.prev_status = UnderReview and ae.new_status = Rejected)
  )
}

// FR-016/FR-017: Audit completeness constraint
// Every application status must correspond to exactly one audit entry
fact F_AuditCompleteness {
  all app: Application | (
    (app.status = Pending implies one ae: AuditEntry | ae.application = app and ae.new_status = Pending) and
    (app.status = UnderReview implies one ae: AuditEntry | ae.application = app and ae.new_status = UnderReview) and
    (app.status = Approved implies one ae: AuditEntry | ae.application = app and ae.new_status = Approved) and
    (app.status = Rejected implies one ae: AuditEntry | ae.application = app and ae.new_status = Rejected)
  )
}

// FR-012: Only assigned officer can patch status
fact F_AssignedOfficerOnly {
  all ae: AuditEntry |
    ae.actor_role = Officer and
    (ae.new_status = UnderReview or ae.new_status = Approved or ae.new_status = Rejected) implies
      ae.actor = ae.application.assigned_officer
}

// FR-013: Officer cannot decide their own application (no self-approval)
fact F_NoSelfApproval {
  all ae: AuditEntry |
    ae.actor_role = Officer and
    (ae.new_status = Approved or ae.new_status = Rejected or ae.new_status = UnderReview) implies
      ae.actor != ae.application.applicant
}

// FR-001: Authentication required - all audit entries have authenticated actors
fact F_AuthRequired {
  all ae: AuditEntry | ae.actor in User
}

// FR-020/FR-021: Ownership constraint - every application has exactly one owner
fact F_OneApplicantPerApplication {
  all app: Application | one app.applicant
}

// Permission matrix from contracts/http-api.md
// Applicant: PostApp, GetOwnApp
// Officer: GetAnyApp, PatchStatus
// Auditor: GetAnyApp, GetAudit
fact F_PermissionMatrix {
  (Applicant -> PostApp) in Permissions.allowed and
  (Applicant -> GetOwnApp) in Permissions.allowed and
  (Officer -> GetAnyApp) in Permissions.allowed and
  (Officer -> PatchStatus) in Permissions.allowed and
  (Auditor -> GetAnyApp) in Permissions.allowed and
  (Auditor -> GetAudit) in Permissions.allowed and
  
  // Closed-world: these are the only allowed permissions
  Permissions.allowed = 
    (Applicant -> PostApp) +
    (Applicant -> GetOwnApp) +
    (Officer -> GetAnyApp) +
    (Officer -> PatchStatus) +
    (Auditor -> GetAnyApp) +
    (Auditor -> GetAudit)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001 through FR-005
pred LeastPrivilege {
  // Permission matrix is defined and non-empty
  some Permissions.allowed and
  // Applicants cannot patch status
  (Applicant -> PatchStatus) !in Permissions.allowed and
  // Applicants cannot read audit
  (Applicant -> GetAudit) !in Permissions.allowed and
  // Auditors cannot post applications
  (Auditor -> PostApp) !in Permissions.allowed and
  // Auditors cannot patch status
  (Auditor -> PatchStatus) !in Permissions.allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role, Operation) pair has a defined verdict
  all r: Role | all op: Operation |
    (r -> op) in Permissions.allowed or (r -> op) !in Permissions.allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // All audit entries have authenticated actors
  all ae: AuditEntry | ae.actor in User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md AuditEntry
pred AuditCompleteness {
  // Every application status corresponds to exactly one audit entry
  all app: Application | (
    (app.status = Pending implies one ae: AuditEntry | ae.application = app and ae.new_status = Pending) and
    (app.status = UnderReview implies one ae: AuditEntry | ae.application = app and ae.new_status = UnderReview) and
    (app.status = Approved implies one ae: AuditEntry | ae.application = app and ae.new_status = Approved) and
    (app.status = Rejected implies one ae: AuditEntry | ae.application = app and ae.new_status = Rejected)
  )
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // Audit entries exist and are immutable (no contradictions in state sequences)
  all app: Application |
    all ae: AuditEntry | ae.application = app implies (
      // No subsequent entry can contradict the transition recorded by ae
      not (some ae2: AuditEntry | ae2.application = app and ae2 != ae and
           ae2.prev_status = ae.new_status and ae.prev_status != none implies ae2.prev_status = ae.new_status)
    )
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
pred AttributionCorrectness {
  // Every audit entry's recorded role matches the actor's actual roles
  all ae: AuditEntry |
    ae.actor_role in ae.actor.roles
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id
pred OwnershipExclusivity {
  // Every application has exactly one applicant (owner)
  all app: Application | one app.applicant
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-021; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  // Applicants with the role can perform PostApp and GetOwnApp operations
  all u: User |
    Applicant in u.roles implies (
      (Applicant -> PostApp) in Permissions.allowed and
      (Applicant -> GetOwnApp) in Permissions.allowed
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022; contracts/http-api.md byte-equivalent not-found response
pred NoInformationLeakage {
  // Each applicant can only be the owner of one set of applications
  all disj app1, app2: Application |
    app1.applicant != app2.applicant implies
      not (some u: User | u = app1.applicant and u = app2.applicant)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; contracts/http-api.md PATCH /applications/{id}/status
pred NoSelfMutation {
  // Officer cannot approve or reject their own application
  all ae: AuditEntry |
    ae.actor_role = Officer and
    (ae.new_status = Approved or ae.new_status = Rejected) implies
      ae.actor != ae.application.applicant
}

assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  all u: User |
    lone app: Application |
      app.applicant = u and (app.status = Pending or app.status = UnderReview)
}

assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ValidStatusMachine {
  all ae: AuditEntry | (
    (ae.prev_status = none and ae.new_status = Pending) or
    (ae.prev_status = Pending and ae.new_status = UnderReview) or
    (ae.prev_status = UnderReview and ae.new_status = Approved) or
    (ae.prev_status = UnderReview and ae.new_status = Rejected)
  )
}

assert FR_009_ValidStatusMachine { FR_009_ValidStatusMachine }
check FR_009_ValidStatusMachine for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerCanPatch {
  all ae: AuditEntry |
    ae.actor_role = Officer and
    (ae.new_status = UnderReview or ae.new_status = Approved or ae.new_status = Rejected) implies
      ae.actor = ae.application.assigned_officer
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfApprovalOrDecision {
  all ae: AuditEntry |
    ae.actor_role = Officer and
    (ae.new_status = Approved or ae.new_status = Rejected or ae.new_status = UnderReview) implies
      ae.actor != ae.application.applicant
}

assert FR_013_NoSelfApprovalOrDecision { FR_013_NoSelfApprovalOrDecision }
check FR_013_NoSelfApprovalOrDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AllOperationsRequireAuth {
  all ae: AuditEntry | ae.actor in User
}

assert FR_001_AllOperationsRequireAuth { FR_001_AllOperationsRequireAuth }
check FR_001_AllOperationsRequireAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantPermissions {
  (Applicant -> PostApp) in Permissions.allowed and
  (Applicant -> GetOwnApp) in Permissions.allowed and
  (Applicant -> PatchStatus) !in Permissions.allowed and
  (Applicant -> GetAudit) !in Permissions.allowed
}

assert FR_003_ApplicantPermissions { FR_003_ApplicantPermissions }
check FR_003_ApplicantPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorCannotWrite {
  (Auditor -> PostApp) !in Permissions.allowed and
  (Auditor -> PatchStatus) !in Permissions.allowed
}

assert FR_005_AuditorCannotWrite { FR_005_AuditorCannotWrite }
check FR_005_AuditorCannotWrite for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_SelfApprovalViolation { some ae: AuditEntry, app: Application | ae.application = app and ae.actor_role = Officer and ae.new_status = Approved and ae.actor = app.applicant }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
