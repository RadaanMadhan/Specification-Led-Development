// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature: 005-fca-loan-applications (A-L3)
// Based on spec.md FR-001–FR-024, data-model.md, contracts/http-api.md

// ===== CORE DOMAIN SIGS =====

abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical,
         Wedding, Holiday, Business, Other extends Purpose {}

abstract sig OperationKind {}
one sig PostApplications, GetApplications, PatchApplicationsStatus,
        GetApplicationsAudit extends OperationKind {}

sig User {
  roles: set Role
}

sig LoanApplication {
  applicant: one User,
  amount_minor: one Int,
  purpose: one Purpose,
  status: one ApplicationStatus,
  assigned_officer: lone User
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actor_role: one Role,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  reason: one String
}

one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// ===== FACTS =====

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionMatrix {
  PermMatrix.allowed = (
    (Applicant -> PostApplications) +
    (Officer -> GetApplications) +
    (Officer -> PatchApplicationsStatus) +
    (Auditor -> GetApplications) +
    (Auditor -> GetApplicationsAudit)
  )
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-002; contracts/http-api.md
fact F_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007
fact F_AmountValidation {
  all app: LoanApplication |
    app.amount_minor >= 100000 and app.amount_minor <= 2500000
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md idx_one_in_flight_per_applicant
fact F_OneInFlightPerApplicant {
  all disj app1, app2: LoanApplication |
    app1.applicant = app2.applicant implies
      not ((app1.status in (Pending + UnderReview)) and (app2.status in (Pending + UnderReview)))
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; data-model.md ApplicationStatus transitions
fact F_AllowedTransitions {
  all ae: AuditEntry | (
    (ae.previous_status = none implies (ae.new_status = Pending)) and
    (ae.previous_status = Pending implies (ae.new_status = UnderReview)) and
    (ae.previous_status = UnderReview implies (ae.new_status = Approved or ae.new_status = Rejected))
  )
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-010, FR-011
fact F_OfficerAssignment {
  all app: LoanApplication |
    (app.assigned_officer != none) implies (
      (Officer in app.assigned_officer.roles) and
      (app.assigned_officer != app.applicant)
    )
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012
fact F_OnlyAssignedOfficerCanPatch {
  all ae: AuditEntry |
    (ae.previous_status != none) implies (
      (ae.actor = ae.application.assigned_officer) and (Officer in ae.actor.roles)
    )
}

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013
fact F_NoSelfDecision {
  all ae: AuditEntry |
    (ae.previous_status != none and Officer in ae.actor.roles) implies
      (ae.actor != ae.application.applicant)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-014
fact F_ReasonRequired {
  all ae: AuditEntry | ae.reason != ""
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-015
fact F_TerminalStates {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (no ae: AuditEntry |
        ae.application = app and (ae.new_status = Approved or ae.new_status = Rejected) and
        (some ae2: AuditEntry | ae2.application = app and ae2.previous_status = ae.new_status))
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md audit_entries
fact F_AuditCompleteness {
  all app: LoanApplication |
    (one ae: AuditEntry | ae.application = app and ae.new_status = app.status)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md (no UPDATE/DELETE)
fact F_AppendOnlyAuditLog {
  all ae: AuditEntry |
    not (some ae2: AuditEntry |
      ae2.application = ae.application and
      ae2.previous_status = ae.previous_status and
      ae2.new_status = ae.new_status and
      ae2.reason = ae.reason and
      ae != ae2)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-024
fact F_ApplicantCannotModify {
  all ae: AuditEntry |
    ae.actor = ae.application.applicant implies (ae.previous_status = none)
}

// ===== PATTERN PREDICATES =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some Role and some OperationKind and some User and
  all r: Role | all op: OperationKind |
    (not (r -> op in PermMatrix.allowed)) implies (
      all u: User | (u.roles = r) implies (no op2: OperationKind | op2 = op and (r -> op2 in PermMatrix.allowed))
    )
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 3 Role, exactly 4 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some User and some LoanApplication and
  all app: LoanApplication | (app.applicant in User) and
  all ae: AuditEntry | (ae.actor in User)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016
pred AuditCompleteness {
  some LoanApplication and some AuditEntry and
  all app: LoanApplication | (one ae: AuditEntry | ae.application = app and ae.new_status = app.status)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018
pred AppendOnly {
  some AuditEntry and
  all ae: AuditEntry |
    (no ae2: AuditEntry |
      ae2.application = ae.application and
      ae2.previous_status = ae.previous_status and
      ae2.new_status = ae.new_status and
      ae2 != ae)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  some AuditEntry and
  all ae: AuditEntry | (ae.actor_role in ae.actor.roles)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008
pred OwnershipExclusivity {
  some LoanApplication and
  all app: LoanApplication | (one a: User | a = app.applicant)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  some LoanApplication and
  all app: LoanApplication | all u: User |
    (Officer in u.roles and u != app.assigned_officer) implies
      (not (u can patch app))
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022
pred NoInformationLeakage {
  some LoanApplication and some User and
  all app: LoanApplication | all u: User |
    (u != app.applicant and u != app.assigned_officer and not (Auditor in u.roles)) implies
      (true)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013
pred NoSelfMutation {
  some LoanApplication and some AuditEntry and
  all ae: AuditEntry |
    (Officer in ae.actor.roles and ae.previous_status != none) implies
      (ae.actor != ae.application.applicant)
}

assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-006, FR-007
pred ValidationBeforeMutation {
  some LoanApplication and
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000)
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ===== FEATURE-SPECIFIC PREDICATES =====

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_NoOfficerAuditorCoexistence {
  some User and
  all u: User | (not (Officer in u.roles and Auditor in u.roles))
}

assert FR_002_NoOfficerAuditorCoexistence { FR_002_NoOfficerAuditorCoexistence }
check FR_002_NoOfficerAuditorCoexistence for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_AmountAndPurposeValidation {
  some LoanApplication and
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000 and app.purpose in Purpose)
}

assert FR_007_AmountAndPurposeValidation { FR_007_AmountAndPurposeValidation }
check FR_007_AmountAndPurposeValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightApplication {
  some LoanApplication and
  all disj app1, app2: LoanApplication |
    (app1.applicant = app2.applicant) implies
      (not ((app1.status in (Pending + UnderReview)) and (app2.status in (Pending + UnderReview))))
}

assert FR_008_OneInFlightApplication { FR_008_OneInFlightApplication }
check FR_008_OneInFlightApplication for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_StatusStateMachine {
  some AuditEntry and
  all ae: AuditEntry | (
    (ae.previous_status = none implies (ae.new_status = Pending)) and
    (ae.previous_status = Pending implies (ae.new_status = UnderReview)) and
    (ae.previous_status = UnderReview implies (ae.new_status = Approved or ae.new_status = Rejected))
  )
}

assert FR_009_StatusStateMachine { FR_009_StatusStateMachine }
check FR_009_StatusStateMachine for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AutoOfficerAssignment {
  some LoanApplication and
  all app: LoanApplication |
    (app.assigned_officer != none) implies (Officer in app.assigned_officer.roles)
}

assert FR_010_AutoOfficerAssignment { FR_010_AutoOfficerAssignment }
check FR_010_AutoOfficerAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_AssignmentExcludesApplicant {
  some LoanApplication and
  all app: LoanApplication |
    (app.assigned_officer != none) implies (app.assigned_officer != app.applicant)
}

assert FR_011_AssignmentExcludesApplicant { FR_011_AssignmentExcludesApplicant }
check FR_011_AssignmentExcludesApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerCanPatch {
  some LoanApplication and some AuditEntry and
  all ae: AuditEntry |
    (ae.previous_status != none) implies (
      (ae.actor = ae.application.assigned_officer) and (Officer in ae.actor.roles)
    )
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfApproval {
  some LoanApplication and some AuditEntry and
  all ae: AuditEntry |
    (ae.previous_status != none and Officer in ae.actor.roles) implies
      (ae.actor != ae.application.applicant)
}

assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ReasonFieldRequired {
  some AuditEntry and
  all ae: AuditEntry | (ae.reason != "")
}

assert FR_014_ReasonFieldRequired { FR_014_ReasonFieldRequired }
check FR_014_ReasonFieldRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_TerminalDecisionStates {
  some LoanApplication and
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (no ae: AuditEntry |
        ae.application = app and
        (ae.new_status = Approved or ae.new_status = Rejected) and
        (some ae2: AuditEntry | ae2.application = app and ae2.previous_status = ae.new_status))
}

assert FR_015_TerminalDecisionStates { FR_015_TerminalDecisionStates }
check FR_015_TerminalDecisionStates for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryPerTransition {
  some LoanApplication and some AuditEntry and
  all app: LoanApplication | (one ae: AuditEntry | ae.application = app and ae.new_status = app.status)
}

assert FR_016_AuditEntryPerTransition { FR_016_AuditEntryPerTransition }
check FR_016_AuditEntryPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditLogImmutable {
  some AuditEntry and
  all ae: AuditEntry |
    (no ae2: AuditEntry |
      ae2.application = ae.application and
      ae2.previous_status = ae.previous_status and
      ae2.new_status = ae.new_status and
      ae2 != ae)
}

assert FR_018_AuditLogImmutable { FR_018_AuditLogImmutable }
check FR_018_AuditLogImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020, FR-021
pred FR_020_ByteEquivalentUnauthorized {
  some LoanApplication and
  all app: LoanApplication | all u: User |
    (u != app.applicant and u != app.assigned_officer and not (Auditor in u.roles)) implies (true)
}

assert FR_020_ByteEquivalentUnauthorized { FR_020_ByteEquivalentUnauthorized }
check FR_020_ByteEquivalentUnauthorized for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantFieldsImmutable {
  some AuditEntry and
  all ae: AuditEntry |
    (ae.actor = ae.application.applicant) implies (ae.previous_status = none)
}

assert FR_024_ApplicantFieldsImmutable { FR_024_ApplicantFieldsImmutable }
check FR_024_ApplicantFieldsImmutable for 5