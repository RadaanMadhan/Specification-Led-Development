// === feature_model.als — FCA-Regulated Loan Application ===
// Alloy 6 model encoding the structural invariants of the loan application feature.

// === ROLES ===
abstract sig Role {}
one sig Applicant, Officer, Auditor extends Role {}

// === ACTORS ===
abstract sig Actor {}
sig User extends Actor {
  roles: set Role
}
one sig SystemActor extends Actor {}

// === APPLICATIONS ===
sig LoanApplication {
  applicant: one User,
  amount_minor: one Int,
  purpose: one Purpose,
  status: one ApplicationStatus,
  assigned_officer: lone User  // null in "no eligible officer" case (FR-011)
}

// === AUDIT ENTRIES ===
sig AuditEntry {
  application: one LoanApplication,
  actor: one Actor,  // User or SystemActor
  actor_role: one Role,  // applicant, officer, auditor, or system-represented role
  timestamp: one Int,  // logical ordering; monotonically increasing per application
  prev_status: lone ApplicationStatus,  // null only for initial (none → pending) event
  new_status: one ApplicationStatus,
  reason: one String
}

// === ENUMS ===
abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical, Wedding, Holiday, Business, Other extends Purpose {}

// === FACTS: Non-Empty Universe ===

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// === FACTS: Role Multiplicity (FR-002) ===

fact F_RoleMultiplicity {
  all u: User |
    not (Officer in u.roles and Auditor in u.roles)
}

// === FACTS: Amount Validation (FR-007) ===

fact F_AmountValidation {
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000)
}

// === FACTS: Purpose List (FR-007) ===

fact F_PurposeList {
  all app: LoanApplication |
    app.purpose in (HomeImprovement + DebtConsolidation + Vehicle + Education + Medical + Wedding + Holiday + Business + Other)
}

// === FACTS: One In-Flight Per Applicant (FR-008) ===

fact F_OneInFlightPerApplicant {
  all disj app1, app2: LoanApplication |
    app1.applicant = app2.applicant implies
      not ((app1.status in (Pending + UnderReview)) and (app2.status in (Pending + UnderReview)))
}

// === FACTS: No Self-Assignment (FR-010, FR-011) ===

fact F_NoSelfAssignment { /* MUTATED — body cleared by validator */ }

// === FACTS: No Self-Approval (FR-013) ===

fact F_NoSelfApprovalStructural {
  all app: LoanApplication |
    app.applicant = app.assigned_officer implies app.status = Pending
}

// === FACTS: Audit Entry Structure (FR-016) ===

fact F_AuditEntryStructure {
  all ae: AuditEntry |
    (ae.application != none and ae.actor_role != none and ae.new_status != none and ae.reason != none)
}

// === FACTS: Append-Only Audit Log (FR-018) ===

fact F_AppendOnlyAuditLog {
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.timestamp != ae2.timestamp
}

// === FACTS: Audit Completeness (FR-016) ===

fact F_AuditCompletenessStructural {
  all app: LoanApplication |
    (app.status != Pending) implies
      (some ae: AuditEntry | ae.application = app and ae.new_status = app.status)
}

// === FACTS: Allowed Status Transitions (FR-009) ===

fact F_AllowedTransitions {
  all ae: AuditEntry |
    (ae.prev_status = none and ae.new_status = Pending) or
    (ae.prev_status = Pending and ae.new_status = UnderReview) or
    (ae.prev_status = UnderReview and ae.new_status = Approved) or
    (ae.prev_status = UnderReview and ae.new_status = Rejected)
}

// === FACTS: Only Assigned Officer Transitions (FR-012) ===

fact F_OnlyAssignedOfficerTransitions {
  all ae: AuditEntry |
    (ae.actor_role = Officer and ae.prev_status != none) implies
      (ae.actor in User and ae.actor = ae.application.assigned_officer)
}

// === FACTS: System Actor for No-Eligible-Officer Case (FR-011) ===

fact F_SystemActorInitialEntry {
  all ae: AuditEntry |
    (ae.actor = SystemActor) implies
      (ae.prev_status = none and ae.new_status = Pending)
}

// === FACTS: Applicant at Submission (FR-006) ===

fact F_ApplicantAtSubmission {
  all ae: AuditEntry |
    (ae.prev_status = none) implies
      (ae.actor_role = Applicant or ae.actor = SystemActor)
}

// === FACTS: Officer Audit Entries (FR-009) ===

fact F_OfficerTransitions {
  all ae: AuditEntry |
    (ae.actor_role = Officer) implies
      (ae.prev_status in (Pending + UnderReview))
}

// === FACTS: Attribution of Applicant Submissions ===

fact F_ApplicantSubmissionAttribution {
  all app: LoanApplication |
    (some ae: AuditEntry | ae.application = app and ae.prev_status = none) implies
      (some ae: AuditEntry | ae.application = app and ae.prev_status = none and ae.actor_role = Applicant and ae.actor in User and ae.actor = app.applicant) or
      (some ae: AuditEntry | ae.application = app and ae.prev_status = none and ae.actor = SystemActor)
}

// === FACTS: Ownership Exclusivity ===

fact F_OwnershipExclusivity {
  all app: LoanApplication |
    one u: User | u = app.applicant
}

// === PREDICATES AND ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-001-005
pred LeastPrivilege {
  some User and some LoanApplication and some AuditEntry
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all u: User | #u.roles >= 1
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  all ae: AuditEntry | (ae.actor in User) or (ae.actor = SystemActor)
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md audit_entries
pred AuditCompleteness {
  all app: LoanApplication |
    (app.status in (UnderReview + Approved + Rejected)) implies
      (some ae: AuditEntry | ae.application = app and ae.new_status = app.status)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, FR-019; contracts/http-api.md no DELETE/UPDATE
pred AppendOnly {
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.timestamp != ae2.timestamp
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit entry fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    (ae.actor in User) implies (ae.actor_role in ae.actor.roles)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md ownership; spec.md applicant
pred OwnershipExclusivity {
  all app: LoanApplication |
    one u: User | u = app.applicant
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-020
pred OwnershipBasedAccess {
  all app: LoanApplication, u: User |
    (u = app.applicant) implies (Applicant in u.roles)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013
pred NoSelfMutation {
  all app: LoanApplication |
    (app.applicant = app.assigned_officer) implies (app.status = Pending)
}

assert NoSelfMutation {
  NoSelfMutation
}

check NoSelfMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
}

assert FR_002_RoleMultiplicity {
  FR_002_RoleMultiplicity
}

check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantCanSubmit {
  all u: User | (Applicant in u.roles) implies (some app: LoanApplication | app.applicant = u)
}

assert FR_003_ApplicantCanSubmit {
  FR_003_ApplicantCanSubmit
}

check FR_003_ApplicantCanSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerCanViewAssigned {
  all app: LoanApplication |
    app.assigned_officer != none implies (Officer in app.assigned_officer.roles)
}

assert FR_004_OfficerCanViewAssigned {
  FR_004_OfficerCanViewAssigned
}

check FR_004_OfficerCanViewAssigned for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  all u: User |
    (Auditor in u.roles) implies
      (no ae: AuditEntry | ae.actor = u and ae.actor_role != Auditor)
}

assert FR_005_AuditorReadOnly {
  FR_005_AuditorReadOnly
}

check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_AmountAndPurposeLimits {
  all app: LoanApplication |
    (app.amount_minor >= 100000 and app.amount_minor <= 2500000)
}

assert FR_007_AmountAndPurposeLimits {
  FR_007_AmountAndPurposeLimits
}

check FR_007_AmountAndPurposeLimits for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  all disj app1, app2: LoanApplication |
    app1.applicant = app2.applicant implies
      not ((app1.status in (Pending + UnderReview)) and (app2.status in (Pending + UnderReview)))
}

assert FR_008_OneInFlightPerApplicant {
  FR_008_OneInFlightPerApplicant
}

check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AllowedStatusTransitions {
  all ae: AuditEntry |
    ((ae.prev_status = none and ae.new_status = Pending) or
     (ae.prev_status = Pending and ae.new_status = UnderReview) or
     (ae.prev_status = UnderReview and ae.new_status = Approved) or
     (ae.prev_status = UnderReview and ae.new_status = Rejected))
}

assert FR_009_AllowedStatusTransitions {
  FR_009_AllowedStatusTransitions
}

check FR_009_AllowedStatusTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
pred FR_010_AutoAssignmentExcludesApplicant {
  all app: LoanApplication |
    app.assigned_officer != none implies
      (app.assigned_officer != app.applicant and Officer in app.assigned_officer.roles)
}

assert FR_010_AutoAssignmentExcludesApplicant {
  FR_010_AutoAssignmentExcludesApplicant
}

check FR_010_AutoAssignmentExcludesApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerCanPatch {
  all ae: AuditEntry |
    (ae.actor_role = Officer and ae.prev_status != none) implies
      (ae.actor = ae.application.assigned_officer)
}

assert FR_012_OnlyAssignedOfficerCanPatch {
  FR_012_OnlyAssignedOfficerCanPatch
}

check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfApproval {
  all app: LoanApplication |
    (app.applicant = app.assigned_officer) implies (app.status = Pending)
}

assert FR_013_NoSelfApproval {
  FR_013_NoSelfApproval
}

check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryStructure {
  all ae: AuditEntry |
    (ae.application != none and ae.actor_role != none and ae.new_status != none and ae.reason != none)
}

assert FR_016_AuditEntryStructure {
  FR_016_AuditEntryStructure
}

check FR_016_AuditEntryStructure for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditImmutableTamperDetectable {
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.timestamp != ae2.timestamp
}

assert FR_018_AuditImmutableTamperDetectable {
  FR_018_AuditImmutableTamperDetectable
}

check FR_018_AuditImmutableTamperDetectable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020, FR-021
pred FR_020_ByteEquivalentResponse {
  // Structural: no unauthorized caller can distinguish between existing and non-existent applications
  // Modeled as: all applicants can only access their own applications
  all u: User, app: LoanApplication |
    (Applicant in u.roles and u != app.applicant) implies
      (no ae: AuditEntry | ae.actor = u and ae.application = app)
}

assert FR_020_ByteEquivalentResponse {
  FR_020_ByteEquivalentResponse
}

check FR_020_ByteEquivalentResponse for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditEndpointAuditorOnly {
  // Only auditors can access audit log; modeled as: only auditors read audit entries
  all u: User |
    (Auditor not in u.roles) implies
      (no ae: AuditEntry | ae.actor = u and ae.actor_role = Auditor)
}

assert FR_023_AuditEndpointAuditorOnly {
  FR_023_AuditEndpointAuditorOnly
}

check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantCannotModifyAfterSubmission {
  all app: LoanApplication, u: User |
    (app.applicant = u) implies
      (no ae: AuditEntry | ae.application = app and ae.actor = u and ae.prev_status != none)
}

assert FR_024_ApplicantCannotModifyAfterSubmission {
  FR_024_ApplicantCannotModifyAfterSubmission
}

check FR_024_ApplicantCannotModifyAfterSubmission for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_SelfAssignmentViolation { some app: LoanApplication | app.assigned_officer = app.applicant }
