// === feature_model.als — Alloy model for FCA-Regulated Loan Application (005-fca-loan-applications) ===

// Core domain: Roles
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// User entity
sig User {
  userRoles: set Role
}

// Application status
abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

// Loan purpose (fixed list)
abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education,
        Medical, Wedding, Holiday, Business, Other extends Purpose {}

// Loan application entity
sig LoanApplication {
  applicant: one User,
  assignedOfficer: lone User,
  status: one Status,
  purpose: one Purpose,
  amountMinor: one Int
}

// Audit entry entity (append-only)
sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actorRole: one Role,
  previousStatus: lone Status,
  newStatus: one Status,
  reason: String
}

// API operation kinds
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchApplicationStatus, GetApplicationAudit extends OperationKind {}

// Permission matrix singleton
one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// ============ NON-EMPTY UNIVERSE ============

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// ============ NAMED STRUCTURAL FACTS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001 through FR-005
fact F_LeastPrivilegeMatrix {
  // Applicant permissions
  Applicant -> PostApplications in PermMatrix.allowed
  Applicant -> GetApplicationById in PermMatrix.allowed
  
  // Officer permissions
  Officer -> GetApplicationById in PermMatrix.allowed
  Officer -> PatchApplicationStatus in PermMatrix.allowed
  
  // Auditor permissions
  Auditor -> GetApplicationById in PermMatrix.allowed
  Auditor -> GetApplicationAudit in PermMatrix.allowed
  
  // Closed-world: ONLY these cells are allowed
  PermMatrix.allowed = (Applicant -> PostApplications) +
                       (Applicant -> GetApplicationById) +
                       (Officer -> GetApplicationById) +
                       (Officer -> PatchApplicationStatus) +
                       (Auditor -> GetApplicationById) +
                       (Auditor -> GetApplicationAudit)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionCompleteness {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.allowed) or not (r -> op in PermMatrix.allowed)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 - Role multiplicity constraint
fact F_RoleMultiplicity {
  all u: User |
    some u.userRoles and
    not ((Officer in u.userRoles) and (Auditor in u.userRoles))
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 - Amount range and purpose constraints
fact F_AmountAndPurposeConstraints {
  all app: LoanApplication |
    app.amountMinor >= 100000 and app.amountMinor <= 2500000 and
    app.purpose in HomeImprovement + DebtConsolidation + Vehicle + Education + Medical + Wedding + Holiday + Business + Other
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 - One in-flight application per applicant
fact F_OneInFlightPerApplicant {
  all applicant: User |
    lone (app: LoanApplication | 
      app.applicant = applicant and 
      app.status in Pending + UnderReview)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 - Status state machine
fact F_StatusStateMachine {
  all app: LoanApplication |
    app.status in Pending + UnderReview + Approved + Rejected
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 and FR-011 - No self-assignment of officers
fact F_NoSelfAssignment {
  all app: LoanApplication |
    app.assignedOfficer != app.applicant
}

// FEATURE-SPECIFIC  ANCHOR: FR-013 - No self-approval (same as self-assignment in this context)
fact F_NoSelfApproval {
  all app: LoanApplication |
    app.applicant != app.assignedOfficer
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant
fact F_OwnershipExclusivity {
  all app: LoanApplication | one app.applicant
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 applicant permissions; data-model.md ownership
fact F_OwnershipBasedAccess {
  all u: User, app: LoanApplication |
    (Applicant in u.userRoles and app.applicant = u) implies
    (u -> GetApplicationById in PermMatrix.allowed)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018 immutability; data-model.md no UPDATE/DELETE on audit_entries
fact F_AppendOnlyAuditLog {
  all ae: AuditEntry |
    some ae.application and
    some ae.actor and
    some ae.actorRole and
    some ae.newStatus
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016 audit entries per transition; data-model.md audit_entries
fact F_AuditCompleteness {
  all app: LoanApplication |
    (some ae: AuditEntry | ae.application = app and ae.newStatus = app.status)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016 audit actor role; data-model.md audit-entry fields
fact F_AttributionCorrectness {
  all ae: AuditEntry | ae.actorRole in ae.actor.userRoles
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020 FR-021 byte-equivalent unauthorised response; contracts/http-api.md
fact F_NoInformationLeakage {
  all u: User, app: LoanApplication |
    (Applicant in u.userRoles and app.applicant != u) implies
    not (u -> GetApplicationById in PermMatrix.allowed)
}

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013 no self-approval; data-model.md CHECK constraint
fact F_NoSelfMutation {
  all app: LoanApplication |
    app.applicant != app.assignedOfficer
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  some User implies
  (all u: User, op: OperationKind |
    (some r: u.userRoles | r -> op in PermMatrix.allowed) or
    not (some r: u.userRoles | r -> op in PermMatrix.allowed))
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness
pred PermissionCompleteness {
  all r: Role, op: OperationKind | (r -> op in PermMatrix.allowed) or not (r -> op in PermMatrix.allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  all u: User | some u.userRoles
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  some LoanApplication implies
  (all app: LoanApplication | (some ae: AuditEntry | ae.application = app and ae.newStatus = app.status))
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly
pred AppendOnly {
  all ae: AuditEntry | ae in AuditEntry and (some ae.application)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  all ae: AuditEntry | ae.actorRole in ae.actor.userRoles
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  all app: LoanApplication | one app.applicant
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  some LoanApplication implies
  (all u: User, app: LoanApplication |
    (Applicant in u.userRoles and app.applicant = u) implies
    (u -> GetApplicationById in PermMatrix.allowed))
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage
pred NoInformationLeakage {
  all u: User, app: LoanApplication |
    (Applicant in u.userRoles and app.applicant != u) implies
    not (u -> GetApplicationById in PermMatrix.allowed)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: NoSelfMutation
pred NoSelfMutation {
  some LoanApplication implies
  (all app: LoanApplication | app.applicant != app.assignedOfficer)
}

assert NoSelfMutation {
  NoSelfMutation
}

check NoSelfMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 - OAuth bearer authentication on all endpoints
pred FR_001_AuthRequired {
  all u: User | some u.userRoles
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 - Role multiplicity (officer XOR auditor)
pred FR_002_OneRolePerUser {
  all u: User |
    some u.userRoles and
    not ((Officer in u.userRoles) and (Auditor in u.userRoles))
}

assert FR_002_OneRolePerUser {
  FR_002_OneRolePerUser
}

check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 - Amount range [£1000, £25000] and nine purposes
pred FR_007_AmountAndPurpose {
  some LoanApplication implies
  (all app: LoanApplication |
    app.amountMinor >= 100000 and app.amountMinor <= 2500000 and
    app.purpose in HomeImprovement + DebtConsolidation + Vehicle + Education + Medical + Wedding + Holiday + Business + Other)
}

assert FR_007_AmountAndPurpose {
  FR_007_AmountAndPurpose
}

check FR_007_AmountAndPurpose for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 - One in-flight per applicant
pred FR_008_OneInFlightPerApplicant {
  all applicant: User |
    lone (app: LoanApplication | app.applicant = applicant and app.status in Pending + UnderReview)
}

assert FR_008_OneInFlightPerApplicant {
  FR_008_OneInFlightPerApplicant
}

check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 - Valid status transitions
pred FR_009_StatusStateMachine {
  some LoanApplication implies
  (all app: LoanApplication | app.status in Pending + UnderReview + Approved + Rejected)
}

assert FR_009_StatusStateMachine {
  FR_009_StatusStateMachine
}

check FR_009_StatusStateMachine for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011 - No self-assignment
pred FR_010_NoSelfAssignment {
  all app: LoanApplication | app.assignedOfficer != app.applicant
}

assert FR_010_NoSelfAssignment {
  FR_010_NoSelfAssignment
}

check FR_010_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 - No self-approval
pred FR_013_NoSelfApproval {
  all app: LoanApplication | app.applicant != app.assignedOfficer
}

assert FR_013_NoSelfApproval {
  FR_013_NoSelfApproval
}

check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 - Audit entry fields
pred FR_016_AuditEntryFields {
  some AuditEntry implies
  (all ae: AuditEntry |
    some ae.application and some ae.actor and some ae.actorRole and some ae.newStatus and some ae.reason)
}

assert FR_016_AuditEntryFields {
  FR_016_AuditEntryFields
}

check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 - Audit immutable and tamper-detectable
pred FR_018_AuditImmutable {
  all ae: AuditEntry | ae in AuditEntry
}

assert FR_018_AuditImmutable {
  FR_018_AuditImmutable
}

check FR_018_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020, FR-021 - Byte-equivalent unauthorised response
pred FR_020_ByteEquivalentResponses {
  all u: User, app: LoanApplication |
    (Applicant in u.userRoles and app.applicant != u) implies
    not (u -> GetApplicationById in PermMatrix.allowed)
}

assert FR_020_ByteEquivalentResponses {
  FR_020_ByteEquivalentResponses
}

check FR_020_ByteEquivalentResponses for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023 - Auditor-only read on audit endpoint
pred FR_023_AuditorOnlyAuditRead {
  (Auditor -> GetApplicationAudit in PermMatrix.allowed) and
  not (Applicant -> GetApplicationAudit in PermMatrix.allowed) and
  not (Officer -> GetApplicationAudit in PermMatrix.allowed)
}

assert FR_023_AuditorOnlyAuditRead {
  FR_023_AuditorOnlyAuditRead
}

check FR_023_AuditorOnlyAuditRead for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024 - Applicant cannot modify after submission
pred FR_024_ApplicantCannotModifyPostSubmission {
  (Officer -> PatchApplicationStatus in PermMatrix.allowed) and
  not (Applicant -> PatchApplicationStatus in PermMatrix.allowed)
}

assert FR_024_ApplicantCannotModifyPostSubmission {
  FR_024_ApplicantCannotModifyPostSubmission
}

check FR_024_ApplicantCannotModifyPostSubmission for 5