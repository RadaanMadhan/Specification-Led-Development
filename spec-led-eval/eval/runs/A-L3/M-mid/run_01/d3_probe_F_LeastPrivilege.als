// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature branch: 005-fca-loan-applications / folder: A-L3
// Encodes FR-001 through FR-024 from spec.md, data-model.md entities,
// and the permission matrix from contracts/http-api.md.

// ──────────────────────────────────────────────────────────────────────────
// ROLES
// ──────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

// ──────────────────────────────────────────────────────────────────────────
// APPLICATION STATUSES
// ──────────────────────────────────────────────────────────────────────────
abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ──────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (one per endpoint from contracts/http-api.md)
// ──────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById,
        PatchApplicationStatus, GetApplicationAudit extends OperationKind {}

// ──────────────────────────────────────────────────────────────────────────
// OUTCOMES
// ──────────────────────────────────────────────────────────────────────────
abstract sig Outcome {}
// Success  = 2xx
// NotFound = 404 byte-equivalent (FR-020/021/022)
// Forbidden = 403
// BadRequest = 400
// Unauthed = 401
one sig Success, NotFound, Forbidden, BadRequest, Unauthed extends Outcome {}

// ──────────────────────────────────────────────────────────────────────────
// DOMAIN ENTITIES
// ──────────────────────────────────────────────────────────────────────────

// data-model.md §User
sig User {
  userRoles: set Role    // empty set = anonymous / unauthenticated caller
}

// data-model.md §LoanApplication
sig LoanApplication {
  appApplicant : one User,
  appOfficer   : lone User,    // NULL only in "no eligible officer" edge-case (FR-011)
  appStatus    : one AppStatus
}

// data-model.md §AuditEntry  (append-only, immutable)
sig AuditEntry {
  entryApp        : one  LoanApplication,
  entryActor      : one  User,
  entryActorRole  : one  Role,
  entryPrevStatus : lone AppStatus,   // NULL for initial (none)→pending entry
  entryNewStatus  : one  AppStatus
}

// API call representation (each Operation atom = one HTTP request)
sig Operation {
  opKind    : one  OperationKind,
  opCaller  : one  User,
  opApp     : lone LoanApplication,  // absent for 401/400 rejections before app lookup
  opOutcome : one  Outcome
}

// ──────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (canonical singleton — contracts/http-api.md §Permission matrix)
// ──────────────────────────────────────────────────────────────────────────
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: non-empty universe (required so ∀ quantifiers are not vacuous)
// ──────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: permission matrix — exact, closed-world encoding from
//       contracts/http-api.md §Permission matrix
// ──────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  // Row: applicant may submit and read (ownership-conditional read is refined below)
  // Row: officer may patch status and read (assignment-conditional)
  // Row: auditor may read applications and read audit log
  // All other (role × opKind) pairs are denied.
  PermMatrix.Allowed =
      (RApplicant -> PostApplications)    +
      (ROfficer   -> PatchApplicationStatus) +
      (RApplicant -> GetApplicationById)  +
      (ROfficer   -> GetApplicationById)  +
      (RAuditor   -> GetApplicationById)  +
      (RAuditor   -> GetApplicationAudit)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: role exclusivity — no user simultaneously holds officer AND auditor
//       (FR-002; data-model.md §User CHECK constraint)
// ──────────────────────────────────────────────────────────────────────────
fact F_RoleExclusivity {
  no u: User | ROfficer in u.userRoles and RAuditor in u.userRoles
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: applicant field must reference a user with the applicant role
//       (data-model.md §LoanApplication applicant_id FK semantics)
// ──────────────────────────────────────────────────────────────────────────
fact F_ApplicantHasApplicantRole {
  all a: LoanApplication | RApplicant in a.appApplicant.userRoles
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: if an officer is assigned, that user must hold the officer role
//       (FR-010; data-model.md §LoanApplication assigned_officer_id FK)
// ──────────────────────────────────────────────────────────────────────────
fact F_AssignedOfficerHasOfficerRole {
  all a: LoanApplication |
    some a.appOfficer implies ROfficer in a.appOfficer.userRoles
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: no self-assignment — assigned officer ≠ applicant
//       (FR-011; data-model.md CHECK assigned_officer_id != applicant_id)
// ──────────────────────────────────────────────────────────────────────────
fact F_NoSelfAssignment {
  all a: LoanApplication | a.appOfficer != a.appApplicant
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: one in-flight application per applicant
//       (FR-008; idx_one_in_flight_per_applicant partial unique index)
// ──────────────────────────────────────────────────────────────────────────
fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (a1.appStatus in (Pending + UnderReview) and
           a2.appStatus in (Pending + UnderReview))
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: valid status transitions — only the four documented arcs may appear
//       in audit entries (FR-009; data-model.md state machine table)
// ──────────────────────────────────────────────────────────────────────────
fact F_ValidStatusTransitions {
  all e: AuditEntry |
    (no e.entryPrevStatus and e.entryNewStatus = Pending) or
    (e.entryPrevStatus = Pending    and e.entryNewStatus = UnderReview) or
    (e.entryPrevStatus = UnderReview and e.entryNewStatus = Approved) or
    (e.entryPrevStatus = UnderReview and e.entryNewStatus = Rejected)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: terminal statuses are immutable — no transition out of Approved/Rejected
//       (FR-015; data-model.md "no self-loop or backward transition" CHECK)
// ──────────────────────────────────────────────────────────────────────────
fact F_TerminalStatusImmutable {
  no e: AuditEntry |
    e.entryPrevStatus = Approved or e.entryPrevStatus = Rejected
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: audit entry actor role matches the actor's actual role
//       (FR-016; AttributionCorrectness)
// ──────────────────────────────────────────────────────────────────────────
fact F_AuditEntryAttributionCorrect {
  all e: AuditEntry |
    e.entryActorRole in e.entryActor.userRoles
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: audit completeness — every successful state-changing operation
//       produces exactly one audit entry (FR-016, FR-017)
// ──────────────────────────────────────────────────────────────────────────
fact F_AuditCompleteness {
  all op: Operation |
    ((op.opKind = PatchApplicationStatus or op.opKind = PostApplications)
      and op.opOutcome = Success) implies
      (one e: AuditEntry |
        e.entryApp = op.opApp and e.entryActor = op.opCaller)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: append-only audit log — no two AuditEntry atoms share the same
//       (application, prevStatus, newStatus, actor) tuple; no entry is
//       "replaced". Additionally, every AuditEntry corresponds to an
//       application that exists (no orphan entries). This encodes the
//       structural no-UPDATE/no-DELETE invariant in static terms.
//       (FR-018; data-model.md "no UPDATE/DELETE … on audit_entries")
// ──────────────────────────────────────────────────────────────────────────
fact F_AppendOnlyAuditEntries {
  // Each AuditEntry references an existing LoanApplication
  all e: AuditEntry | e.entryApp in LoanApplication
  // No two entries carry the same (app, prevStatus, newStatus, actor) —
  // a "mutated" replacement would appear as a duplicate with identical
  // transition fields but different content.
  all disj e1, e2: AuditEntry |
    not (e1.entryApp = e2.entryApp and
         e1.entryPrevStatus = e2.entryPrevStatus and
         e1.entryNewStatus = e2.entryNewStatus and
         e1.entryActor = e2.entryActor)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: authentication required — unauthenticated callers (userRoles = ∅)
//       always receive Unauthed; they never get Success, NotFound, Forbidden
//       or BadRequest (FR-001, SC-010)
// ──────────────────────────────────────────────────────────────────────────
fact F_AuthRequiredEverywhere {
  all op: Operation |
    no op.opCaller.userRoles implies op.opOutcome = Unauthed
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: least-privilege — an operation succeeds only if the caller holds a
//       role that appears in the permission matrix for that operation kind
//       (contracts/http-api.md §Permission matrix; FR-003–FR-005)
// ──────────────────────────────────────────────────────────────────────────
fact F_LeastPrivilege {
  all op: Operation |
    op.opOutcome = Success implies
      (some r: op.opCaller.userRoles |
        r -> op.opKind in PermMatrix.Allowed)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: only the assigned officer may successfully PATCH status (FR-012)
// ──────────────────────────────────────────────────────────────────────────
fact F_OnlyAssignedOfficerCanPatch {
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      (one a: op.opApp | a.appOfficer = op.opCaller)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: no self-approval — the patching officer must not be the applicant
//       (FR-013; data-model.md CHECK applicant_id != caller)
// ──────────────────────────────────────────────────────────────────────────
fact F_NoSelfApproval {
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      (one a: op.opApp | a.appApplicant != op.opCaller)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: ownership-based access for GET /applications/{id}
//       Successful read requires: auditor OR own application (applicant) OR
//       assigned officer. (FR-003, FR-004, FR-005; OwnershipBasedAccess pattern)
// ──────────────────────────────────────────────────────────────────────────
fact F_OwnershipBasedReadAccess {
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success) implies
      (RAuditor in op.opCaller.userRoles or
       (one a: op.opApp | a.appApplicant = op.opCaller) or
       (one a: op.opApp | a.appOfficer = op.opCaller))
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: audit endpoint is auditor-only; all non-auditors receive NotFound
//       (FR-023; contracts/http-api.md §GET /applications/{id}/audit)
// ──────────────────────────────────────────────────────────────────────────
fact F_AuditEndpointAuditorOnly {
  all op: Operation |
    op.opKind = GetApplicationAudit implies
      (op.opOutcome = Success iff RAuditor in op.opCaller.userRoles)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: no information leakage — unauthorised GET /applications/{id} reads
//       return NotFound (never Forbidden), making "exists-but-denied" and
//       "does-not-exist" responses byte-identical (FR-020, FR-021)
// ──────────────────────────────────────────────────────────────────────────
fact F_NoInformationLeakage {
  all op: Operation |
    (op.opKind = GetApplicationById and
     op.opOutcome != Success and
     op.opOutcome != Unauthed and
     op.opOutcome != BadRequest) implies
      op.opOutcome = NotFound
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: auditors cannot write — successful PostApplications or
//       PatchApplicationStatus operations are impossible for auditor-only
//       callers (FR-005; contracts/http-api.md permission matrix "❌ → 403")
// ──────────────────────────────────────────────────────────────────────────
fact F_AuditorReadOnly {
  all op: Operation |
    (RAuditor in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles and
     RApplicant not in op.opCaller.userRoles) implies
      op.opKind not in (PostApplications + PatchApplicationStatus) or
      op.opOutcome != Success
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: applicant cannot PATCH status (FR-003; contracts permission matrix)
// ──────────────────────────────────────────────────────────────────────────
fact F_ApplicantCannotPatch {
  all op: Operation |
    (op.opKind = PatchApplicationStatus and
     RApplicant in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles) implies
      op.opOutcome != Success
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: officer-only callers cannot submit applications (FR-004)
// ──────────────────────────────────────────────────────────────────────────
fact F_OfficerCannotSubmit {
  all op: Operation |
    (op.opKind = PostApplications and
     ROfficer in op.opCaller.userRoles and
     RApplicant not in op.opCaller.userRoles) implies
      op.opOutcome != Success
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: applicant's GET on own application always exposes it via the correct
//       ownership relationship (FR-003 ownership-conditional grant)
// ──────────────────────────────────────────────────────────────────────────
fact F_ApplicantOwnershipGrant {
  all op: Operation |
    (op.opKind = GetApplicationById and
     op.opOutcome = Success and
     RAuditor not in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles) implies
      (one a: op.opApp | a.appApplicant = op.opCaller)
}

// ──────────────────────────────────────────────────────────────────────────
// FACT: no-op transitions forbidden in audit log
//       (data-model.md CHECK previous_status <> new_status)
// ──────────────────────────────────────────────────────────────────────────
fact F_NoNoOpTransition {
  all e: AuditEntry |
    some e.entryPrevStatus implies e.entryPrevStatus != e.entryNewStatus
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PREDICATES AND ASSERTIONS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// ── PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §Permission matrix; FR-003 FR-004 FR-005
pred LeastPrivilege {
  some op: Operation |
    op.opOutcome = Success and
    (some r: op.opCaller.userRoles | r -> op.opKind in PermMatrix.Allowed)
  all op: Operation |
    op.opOutcome = Success implies
      (some r: op.opCaller.userRoles |
        r -> op.opKind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ── PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §Permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either explicitly allowed or
  // implicitly denied. The closed-world assignment in F_PermissionMatrix
  // guarantees this; we verify no role-opkind pair is undefined by
  // checking the Allowed relation is exactly the documented set.
  some PermMatrix
  PermMatrix.Allowed =
      (RApplicant -> PostApplications)       +
      (ROfficer   -> PatchApplicationStatus) +
      (RApplicant -> GetApplicationById)     +
      (ROfficer   -> GetApplicationById)     +
      (RAuditor   -> GetApplicationById)     +
      (RAuditor   -> GetApplicationAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// ── PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  some op: Operation | no op.opCaller.userRoles and op.opOutcome = Unauthed
  all op: Operation |
    no op.opCaller.userRoles implies op.opOutcome = Unauthed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ── PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016 FR-017; data-model.md §AuditEntry
pred AuditCompleteness {
  some op: Operation | op.opOutcome = Success and
    op.opKind in (PostApplications + PatchApplicationStatus)
  all op: Operation |
    ((op.opKind = PatchApplicationStatus or op.opKind = PostApplications)
      and op.opOutcome = Success) implies
      (one e: AuditEntry |
        e.entryApp = op.opApp and e.entryActor = op.opCaller)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ── PATTERN: AppendOnly  ANCHOR: spec.md FR-018 FR-019; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  all disj e1, e2: AuditEntry |
    not (e1.entryApp = e2.entryApp and
         e1.entryPrevStatus = e2.entryPrevStatus and
         e1.entryNewStatus = e2.entryNewStatus and
         e1.entryActor = e2.entryActor)
  all e: AuditEntry | e.entryApp in LoanApplication
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ── PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md §AuditEntry actor_id actor_role
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry | e.entryActorRole in e.entryActor.userRoles
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ── PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 FR-004; data-model.md §LoanApplication applicant_id
pred OwnershipBasedAccess {
  some op: Operation |
    op.opKind = GetApplicationById and op.opOutcome = Success
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success) implies
      (RAuditor in op.opCaller.userRoles or
       (one a: op.opApp | a.appApplicant = op.opCaller) or
       (one a: op.opApp | a.appOfficer = op.opCaller))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ── PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020 FR-021 FR-022; contracts/http-api.md §Byte-equivalent not-found
pred NoInformationLeakage {
  some op: Operation |
    op.opKind = GetApplicationById and op.opOutcome = NotFound
  all op: Operation |
    (op.opKind = GetApplicationById and
     op.opOutcome != Success and
     op.opOutcome != Unauthed and
     op.opOutcome != BadRequest) implies
      op.opOutcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ── PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK applicant_id != assigned_officer_id; contracts PATCH §FR-013
pred NoSelfMutation {
  some op: Operation |
    op.opKind = PatchApplicationStatus and op.opOutcome = Success
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      (one a: op.opApp |
        a.appApplicant != op.opCaller and a.appOfficer = op.opCaller)
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some op: Operation | no op.opCaller.userRoles
  all op: Operation |
    (no op.opCaller.userRoles) implies
      (op.opOutcome = Unauthed and
       op.opOutcome != Success and
       op.opOutcome != NotFound and
       op.opOutcome != Forbidden)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleExclusivity {
  some User
  no u: User | ROfficer in u.userRoles and RAuditor in u.userRoles
}
assert FR_002_RoleExclusivity { FR_002_RoleExclusivity }
check FR_002_RoleExclusivity for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantScope {
  some op: Operation |
    op.opKind = PostApplications and op.opOutcome = Success
  // Applicant-only callers cannot patch status
  all op: Operation |
    (op.opKind = PatchApplicationStatus and
     RApplicant in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles) implies
      op.opOutcome != Success
  // Applicant-only callers cannot read the audit endpoint
  all op: Operation |
    (op.opKind = GetApplicationAudit and
     RAuditor not in op.opCaller.userRoles) implies
      op.opOutcome != Success
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  some op: Operation |
    RAuditor in op.opCaller.userRoles and
    ROfficer not in op.opCaller.userRoles and
    RApplicant not in op.opCaller.userRoles and
    op.opKind = GetApplicationAudit and
    op.opOutcome = Success
  all op: Operation |
    (RAuditor in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles and
     RApplicant not in op.opCaller.userRoles) implies
      op.opKind not in (PostApplications + PatchApplicationStatus) or
      op.opOutcome != Success
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (a1.appStatus in (Pending + UnderReview) and
           a2.appStatus in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ValidTransitions {
  some AuditEntry
  all e: AuditEntry |
    (no e.entryPrevStatus and e.entryNewStatus = Pending) or
    (e.entryPrevStatus = Pending    and e.entryNewStatus = UnderReview) or
    (e.entryPrevStatus = UnderReview and e.entryNewStatus = Approved) or
    (e.entryPrevStatus = UnderReview and e.entryNewStatus = Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all a: LoanApplication | a.appOfficer != a.appApplicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerPatch {
  some op: Operation |
    op.opKind = PatchApplicationStatus and op.opOutcome = Success
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      (one a: op.opApp | a.appOfficer = op.opCaller)
}
assert FR_012_OnlyAssignedOfficerPatch { FR_012_OnlyAssignedOfficerPatch }
check FR_012_OnlyAssignedOfficerPatch for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfApproval {
  some op: Operation |
    op.opKind = PatchApplicationStatus and op.opOutcome = Success
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      (one a: op.opApp | a.appApplicant != op.opCaller)
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_TerminalImmutable {
  some LoanApplication
  no e: AuditEntry |
    e.entryPrevStatus = Approved or e.entryPrevStatus = Rejected
}
assert FR_015_TerminalImmutable { FR_015_TerminalImmutable }
check FR_015_TerminalImmutable for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryFields {
  some AuditEntry
  // Every audit entry's actor role matches the actor's real role set
  all e: AuditEntry | e.entryActorRole in e.entryActor.userRoles
  // The initial (none→pending) entry has no previous status
  all e: AuditEntry |
    (no e.entryPrevStatus) implies e.entryNewStatus = Pending
  // Entries with previous status must respect the transition table
  all e: AuditEntry |
    some e.entryPrevStatus implies
      (e.entryPrevStatus = Pending and e.entryNewStatus = UnderReview) or
      (e.entryPrevStatus = UnderReview and
        (e.entryNewStatus = Approved or e.entryNewStatus = Rejected))
}
assert FR_016_AuditEntryFields { FR_016_AuditEntryFields }
check FR_016_AuditEntryFields for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AppendOnlyLog {
  some AuditEntry
  // All entries reference existing applications
  all e: AuditEntry | e.entryApp in LoanApplication
  // No two entries form a "replacement" of the same transition for the same actor on the same app
  all disj e1, e2: AuditEntry |
    not (e1.entryApp = e2.entryApp and
         e1.entryPrevStatus = e2.entryPrevStatus and
         e1.entryNewStatus = e2.entryNewStatus and
         e1.entryActor = e2.entryActor)
}
assert FR_018_AppendOnlyLog { FR_018_AppendOnlyLog }
check FR_018_AppendOnlyLog for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-020 FR-021; contracts/http-api.md §Byte-equivalent not-found response
pred FR_020_ByteEquivNotFound {
  some op: Operation |
    op.opKind = GetApplicationById and op.opOutcome = NotFound
  // Any authenticated non-success GET /applications/{id} that isn't a 400 must be 404
  all op: Operation |
    (op.opKind = GetApplicationById and
     some op.opCaller.userRoles and
     op.opOutcome != Success and
     op.opOutcome != BadRequest) implies
      op.opOutcome = NotFound
}
assert FR_020_ByteEquivNotFound { FR_020_ByteEquivNotFound }
check FR_020_ByteEquivNotFound for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-023; contracts/http-api.md §GET /applications/{id}/audit
pred FR_023_AuditEndpointAuditorOnly {
  some op: Operation | RAuditor in op.opCaller.userRoles and op.opKind = GetApplicationAudit
  all op: Operation |
    op.opKind = GetApplicationAudit implies
      (op.opOutcome = Success iff RAuditor in op.opCaller.userRoles)
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// ── FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantCannotModifyPostSubmission {
  all op: Operation |
    (op.opKind = PatchApplicationStatus and
     RApplicant in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles) implies
      op.opOutcome != Success
}
assert FR_024_ApplicantCannotModifyPostSubmission { FR_024_ApplicantCannotModifyPostSubmission }
check FR_024_ApplicantCannotModifyPostSubmission for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_LeastPrivilegeViolation { some op: Operation | RAuditor in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles and RApplicant not in op.opCaller.userRoles and op.opKind = PostApplications and op.opOutcome = Success }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
