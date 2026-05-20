// === feature_model.als — Alloy model for 005-fca-loan-applications ===
// FCA-Regulated Loan Application: applicants submit, officers decide, auditors read.
// Encodes the four-endpoint contract, the role permission matrix, the
// status state machine, the append-only audit log, and the byte-equivalent
// no-leakage invariant.

// ---------- Status enum ----------
abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

// ---------- Role enum ----------
abstract sig Role {}
one sig ApplicantRole, OfficerRole, AuditorRole, SystemRole extends Role {}

// ---------- Operation kinds (the four HTTP endpoints) ----------
abstract sig OperationKind {}
one sig PostApplications, GetApplicationOp, PatchStatus, GetAudit extends OperationKind {}

// ---------- Outcome (response class) ----------
abstract sig Outcome {}
one sig OkSuccess, NotFoundOutcome, ForbiddenOutcome extends Outcome {}

// ---------- Permission matrix (singleton-sig field) ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Actors: human users and the synthetic system actor ----------
abstract sig Actor {}
sig User extends Actor {
  roles: some Role
}
one sig SystemActor extends Actor {}

// ---------- Domain entities ----------
sig LoanApplication {
  applicant: one User,
  assignedOfficer: lone User,
  status: one Status
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one Actor,
  actorRole: one Role,
  prevStatus: lone Status,
  newStatus: one Status,
  reason: one Reason
}

// Reason is modelled as an opaque non-empty token (FR-014 — non-empty reason).
sig Reason {}

// An Operation is a single API call landing on a handler.
sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication,
  outcome: one Outcome
}

// =============================================================
// NON-EMPTY UNIVERSE — keep `all` assertions non-vacuous
// =============================================================
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
  some Reason
}

// =============================================================
// PERMISSION MATRIX  ANCHOR: contracts/http-api.md "Permission matrix"
// =============================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (ApplicantRole -> PostApplications) +
    (ApplicantRole -> GetApplicationOp) +
    (OfficerRole   -> GetApplicationOp) +
    (OfficerRole   -> PatchStatus)      +
    (AuditorRole   -> GetApplicationOp) +
    (AuditorRole   -> GetAudit)
}

// =============================================================
// ROLE WELL-FORMEDNESS  ANCHOR: spec.md FR-002; data-model.md users.roles CHECK
// =============================================================
fact F_NoSystemUser {
  // SystemRole never assigned to any user; only appears on system-actor audit entries.
  all u: User | SystemRole not in u.roles
}

fact F_RoleExclusivity {
  // FR-002: officer + auditor combination is forbidden.
  no u: User | OfficerRole in u.roles and AuditorRole in u.roles
}

// =============================================================
// OWNERSHIP / ASSIGNMENT  ANCHOR: spec.md FR-006, FR-010, FR-011
// =============================================================
fact F_ApplicantHasRole {
  all a: LoanApplication | ApplicantRole in a.applicant.roles
}

fact F_OfficerHasRole {
  all a: LoanApplication |
    some a.assignedOfficer implies OfficerRole in a.assignedOfficer.roles
}

fact F_NoSelfAssignment {
  // FR-011 schema-level: assigned_officer_id != applicant_id
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

// =============================================================
// IN-FLIGHT UNIQUENESS  ANCHOR: spec.md FR-008; data-model.md idx_one_in_flight_per_applicant
// =============================================================
fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    (a1.applicant = a2.applicant) implies
      not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}

// =============================================================
// STATUS TRANSITIONS  ANCHOR: spec.md FR-009; data-model.md state-machine table
// =============================================================
fact F_ValidTransitions {
  all e: AuditEntry |
    // Initial submission: prev=∅ ⇒ new=Pending
    (no e.prevStatus implies e.newStatus = Pending) and
    // pending -> under_review
    (e.prevStatus = Pending implies e.newStatus = UnderReview) and
    // under_review -> approved | rejected
    (e.prevStatus = UnderReview implies e.newStatus in (Approved + Rejected)) and
    // Terminal: nothing transitions out of approved or rejected
    (e.prevStatus != Approved) and
    (e.prevStatus != Rejected) and
    // No no-op transitions
    (some e.prevStatus implies e.prevStatus != e.newStatus)
}

// =============================================================
// AUDIT COMPLETENESS  ANCHOR: spec.md FR-016; SC-008
// Every application's current status is witnessed by at least one audit entry
// with newStatus equal to that status (the latest transition).
// =============================================================
fact F_StatusReflectsAudit { /* MUTATED — body cleared by validator */ }

fact F_OneInitialAuditPerApp {
  // Every application has exactly one initial entry (prev=∅, new=Pending).
  all a: LoanApplication |
    one e: AuditEntry | e.application = a and no e.prevStatus
}

// =============================================================
// APPEND-ONLY  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE"
// At most one audit entry per (application, prev->new) transition: a history
// fork is structurally impossible (a rewrite would create a sibling entry).
// =============================================================
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and
         e1.prevStatus  = e2.prevStatus  and
         e1.newStatus   = e2.newStatus)
}

// =============================================================
// ATTRIBUTION  ANCHOR: spec.md FR-016; data-model.md audit_entries.actor_role
// =============================================================
fact F_AttributionCorrectness {
  all e: AuditEntry |
    (e.actor = SystemActor implies e.actorRole = SystemRole) and
    (e.actor in User       implies e.actorRole in e.actor.roles)
}

// =============================================================
// AUTHORISATION ENFORCEMENT  ANCHOR: contracts/http-api.md permission matrix
// FR-003, FR-004, FR-005, FR-023: only callers in an allowed cell reach the handler.
// =============================================================
fact F_LeastPrivilege {
  all op: Operation |
    some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed
}

// =============================================================
// DECISION-TIME GUARDS  ANCHOR: spec.md FR-012, FR-013
// Only the assigned officer makes officer-role audit entries on an application,
// and never on an application where they are the applicant.
// =============================================================
fact F_OnlyAssignedOfficerDecides {
  all e: AuditEntry |
    (e.actorRole = OfficerRole and e.actor in User) implies
      e.actor = e.application.assignedOfficer
}

fact F_NoSelfDecisionAudit {
  all e: AuditEntry |
    (e.actorRole = OfficerRole and e.actor in User) implies
      e.actor != e.application.applicant
}

// =============================================================
// BYTE-EQUIVALENT NO-LEAKAGE  ANCHOR: spec.md FR-020, FR-021, FR-022, FR-023
// A GetApplicationOp succeeds iff the caller can actually read that application;
// every other case maps to the byte-identical NotFound outcome.
// =============================================================
fact F_GetApplicationOutcome {
  all op: Operation | op.kind = GetApplicationOp implies (
    op.outcome = OkSuccess iff
      (some op.target and CanReadApplication[op.caller, op.target])
  )
}

fact F_NoLeakageOutcome {
  // Any non-success outcome on a GET maps to NotFound (byte-equivalent).
  all op: Operation |
    (op.kind = GetApplicationOp and op.outcome != OkSuccess) implies
      op.outcome = NotFoundOutcome
}

fact F_AuditEndpointNoLeakage {
  // GET /applications/{id}/audit is auditor-only; non-auditors get NotFound,
  // not Forbidden, to avoid leaking existence (FR-023).
  all op: Operation |
    (op.kind = GetAudit and AuditorRole not in op.caller.roles) implies
      op.outcome = NotFoundOutcome
}

// =============================================================
// Helper: caller can legitimately read an application.
// =============================================================
pred CanReadApplication[u: User, a: LoanApplication] {
  AuditorRole in u.roles or
  u = a.applicant or
  u = a.assignedOfficer
}

// ###############################################################
// PATTERN PREDICATES + ASSERTIONS
// ###############################################################

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003, FR-004, FR-005
pred LeastPrivilege {
  some Operation
  all op: Operation |
    some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every operation kind has at least one role authorised to invoke it.
  all k: OperationKind | some r: Role | r -> k in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003, FR-004, FR-005
pred PermissionGrounding {
  // Every grant in the matrix lands on one of the three legitimate user roles.
  all r: Role, k: OperationKind |
    r -> k in PermMatrix.Allowed implies r in (ApplicantRole + OfficerRole + AuditorRole)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  // Every operation has a caller that is a real user (not the system actor),
  // and the system pseudo-role never appears in a caller's role set.
  all op: Operation |
    op.caller in User and
    some op.caller.roles and
    SystemRole not in op.caller.roles
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, SC-008
pred AuditCompleteness {
  some LoanApplication
  // Every application's status is witnessed by a matching audit entry,
  // and every application has its initial (prev=∅) entry.
  (all a: LoanApplication |
     some e: AuditEntry | e.application = a and e.newStatus = a.status) and
  (all a: LoanApplication |
     some e: AuditEntry | e.application = a and no e.prevStatus)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  // No two audit entries record the same transition on the same application
  // (a rewrite would have to materialise as a sibling entry).
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and
         e1.prevStatus  = e2.prevStatus  and
         e1.newStatus   = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry |
    (e.actor = SystemActor implies e.actorRole = SystemRole) and
    (e.actor in User       implies e.actorRole in e.actor.roles)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant_id NOT NULL
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.applicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-020, FR-021
pred OwnershipBasedAccess {
  some Operation
  // A successful read can only arise via documented chains:
  //   caller is auditor, OR caller is applicant of target, OR caller is assigned officer.
  all op: Operation |
    (op.kind = GetApplicationOp and op.outcome = OkSuccess) implies
      (AuditorRole in op.caller.roles or
       op.caller = op.target.applicant or
       op.caller = op.target.assignedOfficer)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022, FR-023
pred NoInformationLeakage {
  some Operation
  // No GET reveals existence to an unauthorised caller — every unauthorised
  // read maps to the same NotFound outcome, regardless of whether target exists.
  (all op: Operation |
     (op.kind = GetApplicationOp and op.outcome = OkSuccess) implies
       (some op.target and CanReadApplication[op.caller, op.target]))
  and
  (all op: Operation |
     (op.kind = GetAudit and op.outcome = OkSuccess) implies
       AuditorRole in op.caller.roles)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013
pred NoSelfMutation {
  some LoanApplication
  // Schema-level: assigned officer is never the applicant.
  (all a: LoanApplication |
     some a.assignedOfficer implies a.assignedOfficer != a.applicant)
  and
  // Audit-level: no officer-role audit entry is authored by the applicant
  // of the application it records.
  (all e: AuditEntry |
     (e.actorRole = OfficerRole and e.actor in User) implies
       e.actor != e.application.applicant)
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// ###############################################################
// FEATURE-SPECIFIC PREDICATES (one per significant FR-NNN)
// ###############################################################

// FEATURE-SPECIFIC  ANCHOR: FR-001 (OAuth bearer required before business logic)
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    op.caller in User and some op.caller.roles
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (officer + auditor combination forbidden)
pred FR_002_RoleExclusivity {
  some User
  no u: User | OfficerRole in u.roles and AuditorRole in u.roles
}
assert FR_002_RoleExclusivity { FR_002_RoleExclusivity }
check FR_002_RoleExclusivity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (one in-flight application per applicant)
pred FR_008_OneInFlight {
  some LoanApplication
  all disj a1, a2: LoanApplication |
    (a1.applicant = a2.applicant) implies
      not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (only legal state transitions)
pred FR_009_ValidTransitions {
  some AuditEntry
  all e: AuditEntry |
    (no e.prevStatus implies e.newStatus = Pending) and
    (e.prevStatus = Pending implies e.newStatus = UnderReview) and
    (e.prevStatus = UnderReview implies e.newStatus in (Approved + Rejected)) and
    (e.prevStatus != Approved) and
    (e.prevStatus != Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (auto-assignment yields officer-role user or null)
pred FR_010_AssignmentInvariants {
  some LoanApplication
  all a: LoanApplication |
    some a.assignedOfficer implies OfficerRole in a.assignedOfficer.roles
}
assert FR_010_AssignmentInvariants { FR_010_AssignmentInvariants }
check FR_010_AssignmentInvariants for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (no self-assignment at the schema)
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (only the assigned officer drives PATCH/status)
pred FR_012_OnlyAssignedOfficerDecides {
  some AuditEntry
  all e: AuditEntry |
    (e.actorRole = OfficerRole and e.actor in User) implies
      e.actor = e.application.assignedOfficer
}
assert FR_012_OnlyAssignedOfficerDecides { FR_012_OnlyAssignedOfficerDecides }
check FR_012_OnlyAssignedOfficerDecides for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (officer cannot decide own application)
pred FR_013_NoSelfDecision {
  some AuditEntry
  all e: AuditEntry |
    (e.actorRole = OfficerRole and e.actor in User) implies
      e.actor != e.application.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (terminal states are immutable)
pred FR_015_TerminalImmutable {
  some AuditEntry
  // No audit entry transitions out of a terminal status.
  all e: AuditEntry |
    e.prevStatus != Approved and e.prevStatus != Rejected
}
assert FR_015_TerminalImmutable { FR_015_TerminalImmutable }
check FR_015_TerminalImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (every transition has an audit entry; reasons exist)
pred FR_016_AuditFieldsPresent {
  some AuditEntry
  // Every audit entry carries a reason and a well-defined role/actor pair.
  (all e: AuditEntry | one e.reason)
  and
  (all e: AuditEntry |
     (e.actor = SystemActor implies e.actorRole = SystemRole) and
     (e.actor in User       implies e.actorRole in e.actor.roles))
}
assert FR_016_AuditFieldsPresent { FR_016_AuditFieldsPresent }
check FR_016_AuditFieldsPresent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit log append-only)
pred FR_018_AuditAppendOnly {
  some AuditEntry
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and
         e1.prevStatus  = e2.prevStatus  and
         e1.newStatus   = e2.newStatus)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020, FR-021 (byte-equivalent unauthorised response)
pred FR_020_ByteEquivalentNoLeak {
  some Operation
  all op: Operation |
    (op.kind = GetApplicationOp and op.outcome = OkSuccess) implies
      (some op.target and CanReadApplication[op.caller, op.target])
}
assert FR_020_ByteEquivalentNoLeak { FR_020_ByteEquivalentNoLeak }
check FR_020_ByteEquivalentNoLeak for 6

// FEATURE-SPECIFIC  ANCHOR: FR-022 (POST response never leaks others' applications)
pred FR_022_NoCrossApplicantLeak {
  // The has_in_flight conflict only ever names the requesting applicant's own app.
  // Modelled here as: no POST operation succeeds for an applicant who already has
  // an in-flight application (which would otherwise force the duplicate-detect branch).
  all op: Operation |
    (op.kind = PostApplications and op.outcome = OkSuccess) implies
      (no a: LoanApplication |
         a.applicant = op.caller and a.status in (Pending + UnderReview))
}
assert FR_022_NoCrossApplicantLeak { FR_022_NoCrossApplicantLeak }
check FR_022_NoCrossApplicantLeak for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023 (audit endpoint auditor-only)
pred FR_023_AuditEndpointAuditorOnly {
  some Operation
  all op: Operation |
    op.kind = GetAudit implies AuditorRole in op.caller.roles
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-024 (applicant cannot mutate application after submission)
pred FR_024_ApplicantImmutability {
  // No PATCH operation is performed by an applicant-only (non-officer) caller.
  all op: Operation |
    op.kind = PatchStatus implies OfficerRole in op.caller.roles
}
assert FR_024_ApplicantImmutability { FR_024_ApplicantImmutability }
check FR_024_ApplicantImmutability for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some a: LoanApplication | a.status = Approved and no e: AuditEntry | e.application = a and e.newStatus = Approved }
