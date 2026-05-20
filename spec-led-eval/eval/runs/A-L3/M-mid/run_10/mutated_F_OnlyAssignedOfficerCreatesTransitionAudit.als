// === feature_model.als — Alloy 6 model for A-L3 / 005-fca-loan-applications ===
// FCA-Regulated Loan Application — structural invariants
// Roles: applicant, officer, auditor, system
// Entities: User, LoanApplication, AuditEntry
// Operations: PostApplications, GetApplication, PatchStatus, GetAudit

// ─────────────────────────────────────────────────────
//  Base enumerations
// ─────────────────────────────────────────────────────

abstract sig Role {}
one sig RoleApplicant, RoleOfficer, RoleAuditor, RoleSystem extends Role {}

abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────
//  Domain entities
// ─────────────────────────────────────────────────────

sig User {
  userRoles : set Role
}

sig LoanApplication {
  applicant        : one User,
  assigned_officer : lone User,
  status           : one ApplicationStatus
}

sig AuditEntry {
  app        : one LoanApplication,
  actor      : one User,
  actorRole  : one Role,
  prevStatus : lone ApplicationStatus,
  newStatus  : one ApplicationStatus
}

// ─────────────────────────────────────────────────────
//  Permission matrix (singleton carrier)
// ─────────────────────────────────────────────────────

abstract sig OperationKind {}
one sig OpPostApplications, OpGetApplication, OpPatchStatus, OpGetAudit
  extends OperationKind {}

one sig PermMatrix {
  Allowed : set Role -> OperationKind
}

// ─────────────────────────────────────────────────────
//  Read-result abstraction (information-leakage model)
// ─────────────────────────────────────────────────────

abstract sig ReadResult {}
one sig ResultAuthorised, ResultNotFound extends ReadResult {}

// ─────────────────────────────────────────────────────
//  F_NonEmptyUniverse — force at least one atom per
//  dynamic sig so no assertion is vacuously true
// ─────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// ─────────────────────────────────────────────────────
//  Named structural facts
// ─────────────────────────────────────────────────────

// FR-002: officer and auditor are mutually exclusive; system never on a real user
fact F_RoleMultiplicity {
  no u : User | RoleOfficer in u.userRoles and RoleAuditor in u.userRoles
  no u : User | RoleSystem  in u.userRoles
  all u : User | some u.userRoles
}

// Every application's applicant field references a user who holds RoleApplicant
fact F_ApplicantHasApplicantRole {
  all la : LoanApplication | RoleApplicant in la.applicant.userRoles
}

// If an officer is assigned they must hold RoleOfficer
fact F_AssignedOfficerHasOfficerRole {
  all la : LoanApplication |
    (some la.assigned_officer) implies (RoleOfficer in la.assigned_officer.userRoles)
}

// FR-011: the assigned officer must differ from the applicant
fact F_NoSelfAssignment {
  all la : LoanApplication |
    (some la.assigned_officer) implies la.assigned_officer != la.applicant
}

// FR-008: at most one in-flight (pending or under_review) application per applicant
fact F_OneInFlightPerApplicant {
  all disj a1, a2 : LoanApplication |
    (a1.applicant = a2.applicant) implies
    not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}

// FR-016: initial audit entry has no prevStatus iff newStatus = Pending
fact F_InitialAuditEntryIsSubmission {
  all ae : AuditEntry | (no ae.prevStatus) iff ae.newStatus = Pending
}

// FR-009: only the three allowed transitions may appear in audit entries
fact F_AuditEntryValidTransition {
  all ae : AuditEntry |
    (ae.prevStatus = Pending     implies ae.newStatus = UnderReview) and
    (ae.prevStatus = UnderReview implies ae.newStatus in (Approved + Rejected))
}

// FR-016 attribution: actorRole recorded in an audit entry is a role the actor holds
// (system-actor entries are exempt — system is the sentinel)
fact F_AuditActorRoleMatchesUser {
  all ae : AuditEntry |
    ae.actorRole != RoleSystem implies ae.actorRole in ae.actor.userRoles
}

// FR-018: within one application, no two audit entries share (prevStatus, newStatus)
// (structural proxy for append-only uniqueness of transitions)
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2 : AuditEntry |
    (ae1.app = ae2.app) implies
    not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}

// FR-015: terminal applications have no further outgoing audit entries
fact F_TerminalStatusNoFurtherTransitions {
  all ae : AuditEntry |
    ae.newStatus in (Approved + Rejected) implies
    (no ae2 : AuditEntry | ae2.app = ae.app and ae2.prevStatus = ae.newStatus)
}

// FR-013: the actor of any non-initial audit entry must not be the application's applicant
fact F_NoSelfDecision {
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor != ae.app.applicant
}

// FR-012: every non-initial audit entry's actor must be the application's assigned officer
fact F_OnlyAssignedOfficerCreatesTransitionAudit { /* MUTATED — body cleared by validator */ }

// FR-016 / FR-017: every application has exactly one initial audit entry (none→pending)
fact F_AuditEntryPresentForEveryApplication {
  all la : LoanApplication |
    one ae : AuditEntry | ae.app = la and no ae.prevStatus
}

// contracts/http-api.md permission table (closed-world assignment)
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RoleApplicant -> OpPostApplications) +
    (RoleApplicant -> OpGetApplication)  +
    (RoleOfficer   -> OpGetApplication)  +
    (RoleOfficer   -> OpPatchStatus)     +
    (RoleAuditor   -> OpGetApplication)  +
    (RoleAuditor   -> OpGetAudit)
}

// FR-024: applicants cannot hold the officer-only PATCH permission
// (belt-and-suspenders: encoded in PermMatrix but also stated as a named fact)
fact F_ApplicantCannotPatch {
  RoleApplicant -> OpPatchStatus not in PermMatrix.Allowed
}

// FR-005 / FR-023: auditors cannot post or patch
fact F_AuditorReadOnly {
  RoleAuditor -> OpPostApplications not in PermMatrix.Allowed
  RoleAuditor -> OpPatchStatus      not in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────
//  Helper predicates (not top-level assertions)
// ─────────────────────────────────────────────────────

pred isAuthorisedReader[u : User, la : LoanApplication] {
  (RoleApplicant in u.userRoles and la.applicant = u)
  or
  (RoleOfficer in u.userRoles and la.assigned_officer = u)
  or
  (RoleAuditor in u.userRoles)
}

// Read-result function: authorised → ResultAuthorised, otherwise → ResultNotFound
fun readResult[u : User, la : LoanApplication] : one ReadResult {
  { r : ReadResult |
    (isAuthorisedReader[u, la] and r = ResultAuthorised)
    or
    (not isAuthorisedReader[u, la] and r = ResultNotFound)
  }
}

// ─────────────────────────────────────────────────────
//  PATTERN predicates + assertions
// ─────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003,FR-004,FR-005
pred LeastPrivilege {
  some User
  // Auditor cannot POST or PATCH
  RoleAuditor -> OpPostApplications not in PermMatrix.Allowed
  RoleAuditor -> OpPatchStatus      not in PermMatrix.Allowed
  // Applicant cannot PATCH or GET audit
  RoleApplicant -> OpPatchStatus not in PermMatrix.Allowed
  RoleApplicant -> OpGetAudit    not in PermMatrix.Allowed
  // Officer cannot POST or GET audit
  RoleOfficer -> OpPostApplications not in PermMatrix.Allowed
  RoleOfficer -> OpGetAudit         not in PermMatrix.Allowed
  // System has no allowed API operations
  no op : OperationKind | RoleSystem -> op in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some User
  // Every (concrete role, concrete operation) pair has a defined verdict:
  // present in Allowed (permit) or absent (deny). The closed-world fact
  // F_PermissionMatrix makes this trivially complete; we assert its cardinality.
  // 6 allowed cells out of 4×4 = 16 possible — exactly the spec table.
  #(PermMatrix.Allowed) = 6
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some User
  // Every non-initial audit entry was produced by an officer (authenticated by role);
  // the initial entry was produced by an applicant (or system).
  all ae : AuditEntry | {
    (no ae.prevStatus) implies
      (ae.actorRole = RoleApplicant or ae.actorRole = RoleSystem)
    (some ae.prevStatus) implies
      ae.actorRole = RoleOfficer
  }
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016,FR-017; data-model.md AuditEntry
pred AuditCompleteness {
  some LoanApplication
  // Every application has exactly one initial audit entry
  all la : LoanApplication |
    (one ae : AuditEntry | ae.app = la and no ae.prevStatus)
  // Every audit entry links back to a real application
  all ae : AuditEntry | ae.app in LoanApplication
  // Actor role in every entry is valid (not System for officer-driven transitions)
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actorRole = RoleOfficer
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018,FR-019; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  // Within any application, no two audit entries record the same (prev, new) pair —
  // the structural invariant for append-only uniqueness of transitions.
  all disj ae1, ae2 : AuditEntry |
    (ae1.app = ae2.app) implies
    not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
  // No audit entry has a terminal prevStatus (entries for terminal states cannot exist)
  all ae : AuditEntry |
    ae.prevStatus not in (Approved + Rejected)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some AuditEntry
  // The actorRole recorded in every non-system audit entry is actually held by the actor
  all ae : AuditEntry |
    ae.actorRole != RoleSystem implies ae.actorRole in ae.actor.userRoles
  // Every non-initial audit entry is attributed to the assigned officer of the application
  all ae : AuditEntry |
    (some ae.prevStatus) implies
    (ae.actor = ae.app.assigned_officer and ae.actorRole = RoleOfficer)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id NOT NULL FK
pred OwnershipExclusivity {
  some LoanApplication
  // Every application has exactly one applicant
  all la : LoanApplication | one la.applicant
  // The applicant holds the RoleApplicant role
  all la : LoanApplication | RoleApplicant in la.applicant.userRoles
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003,FR-004; contracts/http-api.md GET permission table
pred OwnershipBasedAccess {
  some LoanApplication
  some u : User | some la : LoanApplication |
    // An applicant who owns the app gets an authorised read result
    (RoleApplicant in u.userRoles and la.applicant = u) implies
    readResult[u, la] = ResultAuthorised
  // A different applicant (not the owner) gets not-found
  all u : User, la : LoanApplication |
    (RoleApplicant in u.userRoles and la.applicant != u
     and RoleOfficer not in u.userRoles and RoleAuditor not in u.userRoles) implies
    readResult[u, la] = ResultNotFound
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020,FR-021,FR-022; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some User
  some LoanApplication
  // Any user without an authorised path to an application sees ResultNotFound —
  // the same result they would see for a non-existent id.
  // The information-leakage invariant: two applications la1 and la2 that a caller
  // is not authorised to read are indistinguishable (both yield ResultNotFound).
  all u : User, la1, la2 : LoanApplication |
    (not isAuthorisedReader[u, la1] and not isAuthorisedReader[u, la2]) implies
    readResult[u, la1] = readResult[u, la2]
  // Additionally, a pure-applicant caller without ownership sees not-found
  all u : User |
    (RoleApplicant in u.userRoles and RoleOfficer not in u.userRoles
     and RoleAuditor not in u.userRoles) implies
    (all la : LoanApplication |
      la.applicant != u implies readResult[u, la] = ResultNotFound)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK(assigned_officer_id != applicant_id)
pred NoSelfMutation {
  some AuditEntry
  // No non-initial audit entry can have the actor equal to the application's applicant
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor != ae.app.applicant
  // Furthermore, no application can have assigned_officer = applicant
  all la : LoanApplication |
    (some la.assigned_officer) implies la.assigned_officer != la.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// ─────────────────────────────────────────────────────
//  FEATURE-SPECIFIC predicates + assertions
// ─────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleExclusivity {
  some User
  // No user holds both officer and auditor simultaneously
  all u : User | not (RoleOfficer in u.userRoles and RoleAuditor in u.userRoles)
  // System role never appears on a real user
  all u : User | RoleSystem not in u.userRoles
}
assert FR_002_RoleExclusivity { FR_002_RoleExclusivity }
check FR_002_RoleExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (applicant permissions)
pred FR_003_ApplicantPermissions {
  some User
  // Applicant (alone) may post and get applications
  RoleApplicant -> OpPostApplications in PermMatrix.Allowed
  RoleApplicant -> OpGetApplication   in PermMatrix.Allowed
  // Applicant may NOT patch or access audit log
  RoleApplicant -> OpPatchStatus not in PermMatrix.Allowed
  RoleApplicant -> OpGetAudit    not in PermMatrix.Allowed
}
assert FR_003_ApplicantPermissions { FR_003_ApplicantPermissions }
check FR_003_ApplicantPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (officer permissions)
pred FR_004_OfficerPermissions {
  some User
  // Officer may view and patch applications
  RoleOfficer -> OpGetApplication in PermMatrix.Allowed
  RoleOfficer -> OpPatchStatus    in PermMatrix.Allowed
  // Officer may NOT post new applications or access the audit endpoint
  RoleOfficer -> OpPostApplications not in PermMatrix.Allowed
  RoleOfficer -> OpGetAudit         not in PermMatrix.Allowed
}
assert FR_004_OfficerPermissions { FR_004_OfficerPermissions }
check FR_004_OfficerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (auditor read-only)
pred FR_005_AuditorReadOnly {
  some User
  // Auditor may get applications and the audit log
  RoleAuditor -> OpGetApplication in PermMatrix.Allowed
  RoleAuditor -> OpGetAudit       in PermMatrix.Allowed
  // Auditor may NOT post or patch anything
  RoleAuditor -> OpPostApplications not in PermMatrix.Allowed
  RoleAuditor -> OpPatchStatus      not in PermMatrix.Allowed
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_applicant
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication
  all disj a1, a2 : LoanApplication |
    (a1.applicant = a2.applicant) implies
    not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md ApplicationStatus transitions
pred FR_009_ValidStatusTransitions {
  some AuditEntry
  // Only three source→target pairs are valid in audit entries
  all ae : AuditEntry |
    (some ae.prevStatus) implies (
      (ae.prevStatus = Pending     and ae.newStatus = UnderReview) or
      (ae.prevStatus = UnderReview and ae.newStatus = Approved) or
      (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
    )
  // No self-loop: prevStatus != newStatus in any audit entry
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.prevStatus != ae.newStatus
}
assert FR_009_ValidStatusTransitions { FR_009_ValidStatusTransitions }
check FR_009_ValidStatusTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md CHECK(assigned_officer_id != applicant_id)
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all la : LoanApplication |
    (some la.assigned_officer) implies la.assigned_officer != la.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md conditional UPDATE on assigned_officer_id
pred FR_012_OnlyAssignedOfficerTransitions {
  some AuditEntry
  // Every non-initial audit entry is authored by the application's assigned officer
  all ae : AuditEntry |
    (some ae.prevStatus) implies (
      ae.actor = ae.app.assigned_officer and
      ae.actorRole = RoleOfficer
    )
}
assert FR_012_OnlyAssignedOfficerTransitions { FR_012_OnlyAssignedOfficerTransitions }
check FR_012_OnlyAssignedOfficerTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md US2 acceptance #5; data-model.md FR-013
pred FR_013_NoSelfDecision {
  some AuditEntry
  // No non-initial audit entry has the actor equal to the application's applicant
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor != ae.app.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md status machine (approved/rejected are terminal)
pred FR_015_TerminalStatusImmutable {
  some AuditEntry
  // No audit entry can have a terminal status as its prevStatus
  all ae : AuditEntry |
    ae.prevStatus not in (Approved + Rejected)
  // Equivalently: if an application is at a terminal status,
  // no audit entry records a transition out of that terminal status
  all la : LoanApplication |
    la.status in (Approved + Rejected) implies
    (no ae : AuditEntry | ae.app = la and ae.prevStatus = la.status)
}
assert FR_015_TerminalStatusImmutable { FR_015_TerminalStatusImmutable }
check FR_015_TerminalStatusImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016,FR-017; data-model.md AuditEntry; spec.md SC-008
pred FR_016_AuditEntryPerTransition {
  some LoanApplication
  // Every application has at least one audit entry (the initial submission entry)
  all la : LoanApplication |
    (one ae : AuditEntry | ae.app = la and no ae.prevStatus)
  // The initial entry's newStatus is always Pending
  all ae : AuditEntry |
    (no ae.prevStatus) implies ae.newStatus = Pending
}
assert FR_016_AuditEntryPerTransition { FR_016_AuditEntryPerTransition }
check FR_016_AuditEntryPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md AppendOnlyInvariant; spec.md SC-009
pred FR_018_AuditImmutableUniqueness {
  some AuditEntry
  // No two audit entries for the same application share (prevStatus, newStatus)
  all disj ae1, ae2 : AuditEntry |
    (ae1.app = ae2.app) implies
    not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert FR_018_AuditImmutableUniqueness { FR_018_AuditImmutableUniqueness }
check FR_018_AuditImmutableUniqueness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020,FR-021; spec.md US5; contracts/http-api.md byte-equivalent not-found
pred FR_020_ByteEquivalentUnauthorisedResponse {
  some User
  some LoanApplication
  // All unauthorised readers of any application receive the same result (ResultNotFound)
  all u : User, la : LoanApplication |
    not isAuthorisedReader[u, la] implies readResult[u, la] = ResultNotFound
  // Two different applications yield the same not-found result for an unauthorised caller
  all u : User, la1, la2 : LoanApplication |
    (not isAuthorisedReader[u, la1] and not isAuthorisedReader[u, la2]) implies
    readResult[u, la1] = readResult[u, la2]
}
assert FR_020_ByteEquivalentUnauthorisedResponse { FR_020_ByteEquivalentUnauthorisedResponse }
check FR_020_ByteEquivalentUnauthorisedResponse for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023; spec.md US3; contracts/http-api.md GET /applications/{id}/audit
pred FR_023_AuditEndpointAuditorOnly {
  some User
  // Only auditors are permitted to access the audit log endpoint
  all u : User |
    (RoleAuditor not in u.userRoles) implies
    (RoleAuditor -> OpGetAudit not in PermMatrix.Allowed or
     -- the caller's own roles don't grant them GetAudit
     no r : u.userRoles | r -> OpGetAudit in PermMatrix.Allowed)
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024; spec.md US4; contracts/http-api.md applicant cannot modify
pred FR_024_ApplicantCannotModifyAfterSubmission {
  some User
  // The PATCH operation is not allowed for RoleApplicant
  RoleApplicant -> OpPatchStatus not in PermMatrix.Allowed
  // Structural consequence: in every non-initial audit entry, the actor's roles
  // include RoleOfficer (not RoleApplicant-only)
  all ae : AuditEntry |
    (some ae.prevStatus) implies RoleOfficer in ae.actor.userRoles
}
assert FR_024_ApplicantCannotModifyAfterSubmission { FR_024_ApplicantCannotModifyAfterSubmission }
check FR_024_ApplicantCannotModifyAfterSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (system role only in audit entries)
pred FR_002_SystemRoleOnlyInAuditEntries {
  some User
  // System role never appears in a user's role set
  no u : User | RoleSystem in u.userRoles
  // System actorRole may appear only in the initial audit entry (no-officer edge case)
  all ae : AuditEntry |
    ae.actorRole = RoleSystem implies no ae.prevStatus
}
assert FR_002_SystemRoleOnlyInAuditEntries { FR_002_SystemRoleOnlyInAuditEntries }
check FR_002_SystemRoleOnlyInAuditEntries for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_WrongOfficerTransition { some ae : AuditEntry | some ae.prevStatus and ae.actor != ae.app.assigned_officer }
