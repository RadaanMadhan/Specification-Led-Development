// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature:  A-L3  (005-fca-loan-applications)
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ═══════════════════════════════════════════════════════════════════════════
// SIGS
// ═══════════════════════════════════════════════════════════════════════════

// ── Roles ──────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

// Users carry a subset of Role.  One special user is the system actor.
sig User {
  roles : some Role
}
one sig SystemUser extends User {}

// ── Application status ─────────────────────────────────────────────────────
abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ── Loan application ───────────────────────────────────────────────────────
sig LoanApplication {
  applicant        : one User,
  assignedOfficer  : lone User,   // lone = nullable (FR-011 edge case)
  status           : one AppStatus
}

// ── Audit entry ────────────────────────────────────────────────────────────
sig AuditEntry {
  application  : one LoanApplication,
  actor        : one User,
  actorRole    : one Role,
  prevStatus   : lone AppStatus,  // lone = null for initial submission entry
  newStatus    : one AppStatus
}

// ── Endpoint/operation kinds ───────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications,
        GetApplicationById,
        PatchApplicationStatus,
        GetApplicationAudit
        extends OperationKind {}

// ── Permission matrix (singleton field pattern) ────────────────────────────
one sig PermMatrix {
  Allowed : set Role -> OperationKind
}

// ═══════════════════════════════════════════════════════════════════════════
// NAMED FACTS
// ═══════════════════════════════════════════════════════════════════════════

// ── Non-empty universe (dynamic sigs only) ─────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// ── Role multiplicity: {officer} and {auditor} are mutually exclusive ──────
// spec.md FR-002; data-model.md Role enum
fact F_RoleMultiplicity {
  // No user holds both Officer and Auditor
  all u : User | not (Officer in u.roles and Auditor in u.roles)
  // SystemRole is the SystemUser's exclusive role; no real user carries it
  all u : User - SystemUser | SystemRole not in u.roles
  SystemUser.roles = SystemRole
}

// ── Permission matrix (role-level, ownership-independent) ─────────────────
// contracts/http-api.md permission matrix table
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Applicant -> PostApplications)     +
    (Applicant -> GetApplicationById)   +
    (Officer   -> PatchApplicationStatus) +
    (Officer   -> GetApplicationById)   +
    (Auditor   -> GetApplicationById)   +
    (Auditor   -> GetApplicationAudit)
}

// ── Applicant field must carry the Applicant role ─────────────────────────
// data-model.md FK + service.py check
fact F_ApplicantHasApplicantRole {
  all app : LoanApplication | Applicant in app.applicant.roles
}

// ── Assigned officer (when present) must carry the Officer role ───────────
// data-model.md: "Must reference a user whose role set includes officer"
fact F_AssignedOfficerHasOfficerRole {
  all app : LoanApplication |
    some app.assignedOfficer implies Officer in app.assignedOfficer.roles
}

// ── No self-assignment: assigned officer != applicant ─────────────────────
// data-model.md CHECK(assigned_officer_id != applicant_id); spec.md FR-011
fact F_NoSelfAssignment {
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}

// ── At most one in-flight application per applicant ───────────────────────
// spec.md FR-008; data-model.md UNIQUE partial index
fact F_OneInFlightPerApplicant {
  all disj a1, a2 : LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview)
           and a2.status in (Pending + UnderReview))
}

// ── Every application has exactly one initial audit entry ─────────────────
// spec.md FR-016, FR-017; data-model.md state-machine table
fact F_InitialAuditEntryExists {
  all app : LoanApplication |
    one ae : AuditEntry |
      ae.application = app and no ae.prevStatus and ae.newStatus = Pending
}

// ── Audit attribution: actorRole is consistent with the actor's roles ─────
// spec.md FR-016; data-model.md AuditEntry.actor_role
fact F_AuditAttribution {
  all ae : AuditEntry | ae.actorRole in ae.actor.roles
}

// ── Auditor never appears as the actor on any audit entry ─────────────────
// spec.md FR-005; contracts: auditor cannot write
fact F_AuditorReadOnly {
  all ae : AuditEntry | ae.actorRole != Auditor
}

// ── No self-approval: the actor on a non-initial entry != the applicant ───
// spec.md FR-013; data-model.md SQL filter applicant_id != ?
fact F_NoSelfApproval { /* MUTATED — body cleared by validator */ }

// ── Valid status transitions ──────────────────────────────────────────────
// spec.md FR-009; data-model.md ApplicationStatus allowed transitions
fact F_ValidTransitions {
  all ae : AuditEntry | {
    // Initial entry: no prevStatus, newStatus must be Pending
    (no ae.prevStatus) implies ae.newStatus = Pending
    // pending -> under_review only
    (ae.prevStatus = Pending) implies ae.newStatus = UnderReview
    // under_review -> approved | rejected only
    (ae.prevStatus = UnderReview) implies
      (ae.newStatus = Approved or ae.newStatus = Rejected)
    // Approved and Rejected are terminal: they never appear as prevStatus
    ae.prevStatus != Approved
    ae.prevStatus != Rejected
    // No self-loop transitions
    (some ae.prevStatus) implies ae.prevStatus != ae.newStatus
  }
}

// ── Append-only: no two entries for the same application share the same
//    (prevStatus, newStatus) pair — prevents "overwriting" a prior entry ───
// spec.md FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2 : AuditEntry |
    ae1.application = ae2.application implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}

// ── Only assigned officer can produce non-initial audit entries ───────────
// spec.md FR-012; data-model.md conditional UPDATE filter
fact F_OnlyAssignedOfficerTransitions {
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor = ae.application.assignedOfficer
}

// ── Audit entries in Approved/Rejected terminal state are complete ─────────
// spec.md FR-015; data-model.md "no PATCH on decided applications"
fact F_TerminalApplicationsHaveDecisionEntry {
  all app : LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (some ae : AuditEntry |
        ae.application = app and ae.newStatus = app.status)
}

// ── Status of an application is consistent with its audit trail ───────────
// spec.md FR-009, FR-015; data-model.md state-machine
fact F_StatusConsistentWithAuditTrail {
  all app : LoanApplication |
    // Current status must appear as the newStatus of at least one entry
    (some ae : AuditEntry | ae.application = app and ae.newStatus = app.status)
}

// ═══════════════════════════════════════════════════════════════════════════
// PREDICATES & ASSERTIONS (structural patterns)
// ═══════════════════════════════════════════════════════════════════════════

// ── Helper: can a user legitimately read an application? ──────────────────
pred canRead[u : User, app : LoanApplication] {
  (Applicant in u.roles and u = app.applicant)          or
  (Officer   in u.roles and u = app.assignedOfficer)    or
  (Auditor   in u.roles)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003 FR-004 FR-005
pred LeastPrivilege {
  some LoanApplication
  // SystemRole is not granted any endpoint permission
  no (SystemRole -> OperationKind) & PermMatrix.Allowed
  // Auditor cannot POST or PATCH
  (Auditor -> PostApplications)      not in PermMatrix.Allowed
  (Auditor -> PatchApplicationStatus) not in PermMatrix.Allowed
  // Applicant cannot PATCH status or read audit log
  (Applicant -> PatchApplicationStatus) not in PermMatrix.Allowed
  (Applicant -> GetApplicationAudit)    not in PermMatrix.Allowed
  // Officer cannot submit applications or read audit log
  (Officer -> PostApplications)      not in PermMatrix.Allowed
  (Officer -> GetApplicationAudit)   not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some LoanApplication
  // Every (concrete-non-system role × operation) cell is either allowed or
  // explicitly denied (not in Allowed).  The Allowed set is total for each
  // non-system role — every role has at least one allowed operation.
  some (Applicant -> OperationKind) & PermMatrix.Allowed
  some (Officer   -> OperationKind) & PermMatrix.Allowed
  some (Auditor   -> OperationKind) & PermMatrix.Allowed
  // SystemRole has no allowed operations — the set is well-defined (empty)
  no (SystemRole -> OperationKind) & PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-004 FR-005; contracts/http-api.md
// Auditor read set is a superset of Officer read set is a superset of Applicant read set
// on the GetApplicationById dimension (auditor reads anything; officer reads assigned;
// applicant reads own). Modeled at role-grant level: auditor has every read grant
// that applicant has.
pred PrivilegeMonotonicity {
  some LoanApplication
  // Auditor inherits every operation that Applicant is allowed
  all op : OperationKind |
    (Applicant -> op) in PermMatrix.Allowed implies (Auditor -> op) in PermMatrix.Allowed
  // Auditor is never less privileged than officer on reads
  (Auditor -> GetApplicationById) in PermMatrix.Allowed
  (Auditor -> GetApplicationAudit) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md OAuth section
// Every AuditEntry (evidence of business logic executing) was produced by a caller
// whose actorRole is actually in their roles — i.e., no un-roled (unauthenticated) actor
// ever produces a state change.
pred AuthRequiredEverywhere {
  some AuditEntry
  all ae : AuditEntry | ae.actorRole in ae.actor.roles
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016 FR-017; data-model.md state-machine table
// Every LoanApplication has at least one AuditEntry, and every terminal application
// has an entry whose newStatus matches the terminal status.  No application exists
// without its provenance being recorded.
pred AuditCompleteness {
  some LoanApplication
  all app : LoanApplication | some ae : AuditEntry | ae.application = app
  all app : LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (some ae : AuditEntry |
        ae.application = app and ae.newStatus = app.status)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
// No two distinct AuditEntries for the same application share the same
// (prevStatus, newStatus) — the signature of "overwriting" a prior entry.
pred AppendOnly {
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    ae1.application = ae2.application implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
// Every AuditEntry's actorRole is a role that the actor actually holds,
// and transitions (non-initial entries) are attributed to the assigned officer
// with the Officer role.
pred AttributionCorrectness {
  some AuditEntry
  all ae : AuditEntry | ae.actorRole in ae.actor.roles
  all ae : AuditEntry |
    (some ae.prevStatus) implies
      (ae.actorRole = Officer and ae.actor = ae.application.assignedOfficer)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id NOT NULL
// Every LoanApplication has exactly one applicant (enforced by `one applicant`),
// and that applicant carries the Applicant role.
pred OwnershipExclusivity {
  some LoanApplication
  all app : LoanApplication | one app.applicant
  all app : LoanApplication | Applicant in app.applicant.roles
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 FR-012; contracts/http-api.md GET matrix
// An applicant-role caller can only see their own application;
// an officer can only act on applications assigned to them.
pred OwnershipBasedAccess {
  some LoanApplication
  // No non-initial audit entry is authored by someone other than the assigned officer
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor = ae.application.assignedOfficer
  // The applicant of an application is NOT the assigned officer (no self-assignment)
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020 FR-021 FR-022; contracts/http-api.md byte-equivalent not-found
// Modeled structurally: no AuditEntry is produced for an unauthorized read attempt.
// Equivalently, no state changes occur for users who cannot legitimately read an application.
// Encoded as: any actor on a non-initial entry who is not the assigned officer
// does not produce an audit record on that application.
pred NoInformationLeakage {
  some LoanApplication
  // A user who cannot read an application produces no audit entry for it
  all ae : AuditEntry | all u : User |
    (not canRead[u, ae.application]) implies ae.actor != u
  // Cross-applicant info leak via POST: in-flight conflict response only reveals
  // the requesting applicant's own application — modeled as: no two applications
  // in-flight belonging to different applicants share audit entries
  all disj a1, a2 : LoanApplication |
    (a1.applicant != a2.applicant) implies
      no (a1.application.~application & a2.application.~application)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK(assigned_officer_id != applicant_id)
// An officer cannot decide their own application.
// The assigned officer of an application is never equal to the application's applicant.
pred NoSelfMutation {
  some LoanApplication
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
  // No non-initial audit entry where the actor is also the applicant
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor != ae.application.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001 FR-006 FR-007 FR-014; data-model.md validation
// Failed / unauthorized operations produce no audit entry.
// Modeled as: every AuditEntry corresponds to a successfully authorized
// state transition (actor's role matches the actorRole on the entry,
// and the actorRole is one that is allowed to trigger such a transition).
pred ValidationBeforeMutation {
  some AuditEntry
  // Initial entries: actor is applicant or system
  all ae : AuditEntry |
    (no ae.prevStatus) implies
      (ae.actorRole = Applicant or ae.actorRole = SystemRole)
  // Transition entries: actor holds the Officer role
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actorRole = Officer
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES (one per FR)
// ═══════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every AuditEntry (produced by business logic) has an actor whose actorRole
// is in their roles — no unauthenticated caller ever mutates state.
pred FR_001_AuthRequired {
  some AuditEntry
  all ae : AuditEntry | ae.actorRole in ae.actor.roles
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
// No user simultaneously holds Officer and Auditor.
pred FR_002_RoleMultiplicity {
  some User
  all u : User | not (Officer in u.roles and Auditor in u.roles)
  all u : User - SystemUser | SystemRole not in u.roles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
// Applicants can POST and GET (own app); Auditor role is never in the set
// that can POST.  Encoded at the permission-matrix level.
pred FR_003_ApplicantPermissions {
  some LoanApplication
  (Applicant -> PostApplications)      in PermMatrix.Allowed
  (Applicant -> GetApplicationById)    in PermMatrix.Allowed
  (Applicant -> PatchApplicationStatus) not in PermMatrix.Allowed
  (Applicant -> GetApplicationAudit)   not in PermMatrix.Allowed
}
assert FR_003_ApplicantPermissions { FR_003_ApplicantPermissions }
check FR_003_ApplicantPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
// Officers can PATCH and GET assigned apps; cannot POST or read audit log.
pred FR_004_OfficerPermissions {
  some LoanApplication
  (Officer -> PatchApplicationStatus) in PermMatrix.Allowed
  (Officer -> GetApplicationById)     in PermMatrix.Allowed
  (Officer -> PostApplications)       not in PermMatrix.Allowed
  (Officer -> GetApplicationAudit)    not in PermMatrix.Allowed
}
assert FR_004_OfficerPermissions { FR_004_OfficerPermissions }
check FR_004_OfficerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
// Auditors can GET any app and read the audit log; cannot POST or PATCH.
pred FR_005_AuditorReadOnly {
  some AuditEntry
  (Auditor -> GetApplicationById)      in PermMatrix.Allowed
  (Auditor -> GetApplicationAudit)     in PermMatrix.Allowed
  (Auditor -> PostApplications)        not in PermMatrix.Allowed
  (Auditor -> PatchApplicationStatus)  not in PermMatrix.Allowed
  // No AuditEntry was written by an actor with Auditor role
  all ae : AuditEntry | ae.actorRole != Auditor
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
// No applicant has two simultaneous in-flight applications.
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication
  all disj a1, a2 : LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview)
           and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
// All audit entries record only allowed transitions; Approved/Rejected are terminal.
pred FR_009_ValidStatusTransitions {
  some AuditEntry
  all ae : AuditEntry | {
    (no ae.prevStatus)         implies ae.newStatus = Pending
    ae.prevStatus = Pending    implies ae.newStatus = UnderReview
    ae.prevStatus = UnderReview implies (ae.newStatus = Approved or ae.newStatus = Rejected)
    ae.prevStatus != Approved
    ae.prevStatus != Rejected
    (some ae.prevStatus) implies ae.prevStatus != ae.newStatus
  }
}
assert FR_009_ValidStatusTransitions { FR_009_ValidStatusTransitions }
check FR_009_ValidStatusTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
// Assigned officer (when present) is always a different user from the applicant.
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
// Every non-initial audit entry is authored by the application's assigned officer.
pred FR_012_OnlyAssignedOfficerPatches {
  some AuditEntry
  all ae : AuditEntry |
    (some ae.prevStatus) implies
      (ae.actor = ae.application.assignedOfficer and Officer in ae.actor.roles)
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
// The actor on any non-initial audit entry must not be the application's applicant.
pred FR_013_NoSelfApproval {
  some AuditEntry
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actor != ae.application.applicant
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
// Once approved or rejected, no further transitions are recorded for an application.
// Approved/Rejected never appear as prevStatus in any AuditEntry.
pred FR_015_TerminalStatusImmutable {
  some AuditEntry
  all ae : AuditEntry | ae.prevStatus != Approved
  all ae : AuditEntry | ae.prevStatus != Rejected
}
assert FR_015_TerminalStatusImmutable { FR_015_TerminalStatusImmutable }
check FR_015_TerminalStatusImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
// Every application has an initial audit entry with no prevStatus and newStatus=Pending.
// Non-initial entries have a valid prevStatus and a consistent actorRole.
pred FR_016_AuditEntryFields {
  some LoanApplication
  all app : LoanApplication |
    one ae : AuditEntry | ae.application = app and no ae.prevStatus and ae.newStatus = Pending
  all ae : AuditEntry | ae.actorRole in ae.actor.roles
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actorRole = Officer
  all ae : AuditEntry |
    (no ae.prevStatus) implies (ae.actorRole = Applicant or ae.actorRole = SystemRole)
}
assert FR_016_AuditEntryFields { FR_016_AuditEntryFields }
check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 FR-018
// Every LoanApplication has at least one AuditEntry (no state change without an entry).
// Structurally, the application's status is witnessed by an AuditEntry.
pred FR_017_AuditWithinTransaction {
  some LoanApplication
  all app : LoanApplication |
    some ae : AuditEntry | ae.application = app and ae.newStatus = app.status
}
assert FR_017_AuditWithinTransaction { FR_017_AuditWithinTransaction }
check FR_017_AuditWithinTransaction for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
// No two distinct AuditEntries on the same application record the same transition.
// (Structural proxy for append-only: you can only add, never overwrite.)
pred FR_018_AuditImmutable {
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    ae1.application = ae2.application implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020 FR-021; contracts/http-api.md byte-equivalent not-found
// No actor produces a state change on an application they cannot legitimately read.
// (Unauthorized reads are no-ops that return the canonical not-found response.)
pred FR_020_ByteEquivalentResponse {
  some LoanApplication
  all ae : AuditEntry | canRead[ae.actor, ae.application]
}
assert FR_020_ByteEquivalentResponse { FR_020_ByteEquivalentResponse }
check FR_020_ByteEquivalentResponse for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023; contracts/http-api.md audit endpoint
// No non-auditor actor appears as the actor on any AuditEntry in a way that
// would imply they read the audit log; the audit endpoint produces no state changes.
// Modeled as: the audit log itself is never written by an Auditor actor.
pred FR_023_AuditEndpointAuditorOnly {
  some AuditEntry
  // Auditor role is in PermMatrix.Allowed for GetApplicationAudit
  (Auditor -> GetApplicationAudit) in PermMatrix.Allowed
  // No other role is granted GetApplicationAudit
  (Applicant -> GetApplicationAudit) not in PermMatrix.Allowed
  (Officer   -> GetApplicationAudit) not in PermMatrix.Allowed
  (SystemRole -> GetApplicationAudit) not in PermMatrix.Allowed
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-024
// Applicants never appear as the actor on a non-initial AuditEntry
// (they cannot modify an application after submission).
pred FR_024_ApplicantCannotModify {
  some AuditEntry
  all ae : AuditEntry |
    (some ae.prevStatus) implies ae.actorRole != Applicant
}
assert FR_024_ApplicantCannotModify { FR_024_ApplicantCannotModify }
check FR_024_ApplicantCannotModify for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_SelfApprovalViolation { some ae: AuditEntry | some ae.prevStatus and ae.actor = ae.application.applicant }
