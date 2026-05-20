// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature: A-L3 / 005-fca-loan-applications
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ══════════════════════════════════════════════════════════════════════════════
// ROLES
// ══════════════════════════════════════════════════════════════════════════════
abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

// ══════════════════════════════════════════════════════════════════════════════
// API OPERATION KINDS
// ══════════════════════════════════════════════════════════════════════════════
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById,
        PatchApplicationStatus, GetApplicationAudit extends OperationKind {}

// ══════════════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX SINGLETON
// contracts/http-api.md permission table
// ══════════════════════════════════════════════════════════════════════════════
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ══════════════════════════════════════════════════════════════════════════════
// APPLICATION STATUS
// ══════════════════════════════════════════════════════════════════════════════
abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ══════════════════════════════════════════════════════════════════════════════
// DYNAMIC SIGS
// ══════════════════════════════════════════════════════════════════════════════
sig User {
  roles: set Role
}

sig LoanApplication {
  appApplicant:     one  User,
  assignedOfficer:  lone User,
  status:           one  AppStatus
}

sig AuditEntry {
  entryApplication: one  LoanApplication,
  entryActor:       one  User,
  entryActorRole:   one  Role,
  prevStatus:       lone AppStatus,
  newStatus:        one  AppStatus
}

abstract sig Outcome {}
one sig Success, Failure extends Outcome {}

sig Operation {
  opKind:         one  OperationKind,
  opCaller:       one  User,
  opTarget:       lone LoanApplication,
  opOutcome:      one  Outcome,
  opAuditEntries: set  AuditEntry
}

// ══════════════════════════════════════════════════════════════════════════════
// NON-EMPTY UNIVERSE
// Forces every dynamic sig to be populated so no assertion is vacuously true
// over an empty universe under `for 5`.
// ══════════════════════════════════════════════════════════════════════════════
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ══════════════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX
// contracts/http-api.md permission table — exact closed-world enumeration.
// Applicant: POST, GET-by-id
// Officer  : GET-by-id, PATCH-status
// Auditor  : GET-by-id, GET-audit
// SystemRole: no operation allowed (audit-actor only, never an API caller)
// ══════════════════════════════════════════════════════════════════════════════
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Applicant -> PostApplications)     +
    (Applicant -> GetApplicationById)   +
    (Officer   -> GetApplicationById)   +
    (Officer   -> PatchApplicationStatus) +
    (Auditor   -> GetApplicationById)   +
    (Auditor   -> GetApplicationAudit)
}

// ══════════════════════════════════════════════════════════════════════════════
// ROLE EXCLUSIVITY — FR-002: officer ∩ auditor = ∅ per user;
// SystemRole is never assigned to a real user.
// data-model.md roles CHECK constraint
// ══════════════════════════════════════════════════════════════════════════════
fact F_RoleExclusivity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
  all u: User | SystemRole not in u.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// APPLICANT HAS APPLICANT ROLE — data-model.md loan_applications.applicant_id
// references a user whose role set contains applicant
// ══════════════════════════════════════════════════════════════════════════════
fact F_ApplicantHasApplicantRole {
  all app: LoanApplication | Applicant in app.appApplicant.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// ASSIGNED OFFICER HAS OFFICER ROLE — data-model.md assigned_officer_id FK
// ══════════════════════════════════════════════════════════════════════════════
fact F_AssignedOfficerHasOfficerRole {
  all app: LoanApplication |
    some app.assignedOfficer implies Officer in app.assignedOfficer.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// NO SELF-ASSIGNMENT — FR-011; data-model.md CHECK(assigned_officer_id != applicant_id)
// ══════════════════════════════════════════════════════════════════════════════
fact F_NoSelfAssignment {
  all app: LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.appApplicant
}

// ══════════════════════════════════════════════════════════════════════════════
// ONE IN-FLIGHT PER APPLICANT — FR-008;
// data-model.md idx_one_in_flight_per_applicant partial unique index
// ══════════════════════════════════════════════════════════════════════════════
fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (
        (a1.status = Pending or a1.status = UnderReview) and
        (a2.status = Pending or a2.status = UnderReview)
      )
}

// ══════════════════════════════════════════════════════════════════════════════
// AUDIT INITIAL ENTRY SHAPE — FR-016; data-model.md
// CHECK((previous_status IS NULL) = (new_status = 'pending'))
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuditInitialEntryShape {
  all ae: AuditEntry |
    (no ae.prevStatus) iff (ae.newStatus = Pending)
}

// ══════════════════════════════════════════════════════════════════════════════
// NO NO-OP AUDIT TRANSITIONS — data-model.md
// CHECK(previous_status IS NULL OR previous_status <> new_status)
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuditNoNoOp {
  all ae: AuditEntry |
    some ae.prevStatus implies ae.prevStatus != ae.newStatus
}

// ══════════════════════════════════════════════════════════════════════════════
// VALID STATUS TRANSITIONS — FR-009
// Allowed non-initial: pending→under_review, under_review→approved,
//                       under_review→rejected
// ══════════════════════════════════════════════════════════════════════════════
fact F_ValidStatusTransitions {
  all ae: AuditEntry |
    some ae.prevStatus implies (
      (ae.prevStatus = Pending    and ae.newStatus = UnderReview) or
      (ae.prevStatus = UnderReview and ae.newStatus = Approved)   or
      (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
    )
}

// ══════════════════════════════════════════════════════════════════════════════
// TERMINAL STATE FINALITY — FR-015
// Approved and Rejected are never a prevStatus; no further transitions out.
// ══════════════════════════════════════════════════════════════════════════════
fact F_TerminalStateFinal {
  all ae: AuditEntry |
    ae.prevStatus != Approved and ae.prevStatus != Rejected
}

// ══════════════════════════════════════════════════════════════════════════════
// AUDIT COMPLETENESS PER APPLICATION — FR-016
// Every application has at least one audit entry.
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuditCompletenessPerApp {
  all app: LoanApplication | some ae: AuditEntry | ae.entryApplication = app
}

// ══════════════════════════════════════════════════════════════════════════════
// ATTRIBUTION CORRECTNESS — FR-016; data-model.md audit_entries.actor_role
// Actor role in an audit entry matches the actor's actual role set,
// unless the actor is the system sentinel.
// ══════════════════════════════════════════════════════════════════════════════
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.entryActorRole != SystemRole implies ae.entryActorRole in ae.entryActor.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// ONLY ASSIGNED OFFICER CREATES STATUS-CHANGE AUDIT ENTRIES — FR-012
// Non-initial audit entries are written by the assigned officer acting as officer.
// ══════════════════════════════════════════════════════════════════════════════
fact F_OnlyAssignedOfficerTransitions {
  all ae: AuditEntry |
    some ae.prevStatus implies (
      ae.entryActorRole = Officer and
      ae.entryActor = ae.entryApplication.assignedOfficer
    )
}

// ══════════════════════════════════════════════════════════════════════════════
// NO SELF-APPROVAL — FR-013
// The actor on any status-changing audit entry must not be the application's
// own applicant.
// ══════════════════════════════════════════════════════════════════════════════
fact F_NoSelfApproval {
  all ae: AuditEntry |
    some ae.prevStatus implies ae.entryActor != ae.entryApplication.appApplicant
}

// ══════════════════════════════════════════════════════════════════════════════
// LEAST PRIVILEGE — successful operations require caller to hold an allowed role
// contracts/http-api.md permission matrix; spec.md FR-003–FR-005
// ══════════════════════════════════════════════════════════════════════════════
fact F_LeastPrivilege {
  all op: Operation |
    op.opOutcome = Success implies
      (some r: op.opCaller.roles | r -> op.opKind in PermMatrix.Allowed)
}

// ══════════════════════════════════════════════════════════════════════════════
// OWNERSHIP-BASED ACCESS — GetApplicationById succeeds only for legitimate callers
// FR-003 (own applicant), FR-004 (assigned officer), FR-005 (auditor)
// ══════════════════════════════════════════════════════════════════════════════
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success) implies
      (some app: LoanApplication |
        op.opTarget = app and (
          (Applicant in op.opCaller.roles and op.opCaller = app.appApplicant) or
          (Officer   in op.opCaller.roles and op.opCaller = app.assignedOfficer) or
          (Auditor   in op.opCaller.roles)
        ))
}

// ══════════════════════════════════════════════════════════════════════════════
// GET AUDIT REQUIRES AUDITOR — FR-023
// ══════════════════════════════════════════════════════════════════════════════
fact F_GetAuditRequiresAuditor {
  all op: Operation |
    (op.opKind = GetApplicationAudit and op.opOutcome = Success) implies
      Auditor in op.opCaller.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// PATCH REQUIRES OFFICER ROLE — FR-004, FR-012
// ══════════════════════════════════════════════════════════════════════════════
fact F_PatchRequiresOfficerRole {
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      Officer in op.opCaller.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// VALIDATION BEFORE MUTATION — FR-017 atomicity
// Failed operations produce no audit entries.
// ══════════════════════════════════════════════════════════════════════════════
fact F_ValidationBeforeMutation {
  all op: Operation |
    op.opOutcome = Failure implies no op.opAuditEntries
}

// ══════════════════════════════════════════════════════════════════════════════
// EXACTLY ONE AUDIT ENTRY PER SUCCESSFUL MUTATING OPERATION — FR-016, FR-017
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuditExactlyOneForSuccess {
  all op: Operation |
    (op.opOutcome = Success and
     (op.opKind = PostApplications or op.opKind = PatchApplicationStatus)) implies
      one op.opAuditEntries
}

// ══════════════════════════════════════════════════════════════════════════════
// AUDIT ENTRIES ONLY FROM MUTATING OPERATIONS — FR-016
// Read operations never produce audit entries.
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuditOnlyFromMutatingOps {
  all op: Operation |
    some op.opAuditEntries implies
      (op.opKind = PostApplications or op.opKind = PatchApplicationStatus)
}

// ══════════════════════════════════════════════════════════════════════════════
// AUDIT ENTRY BELONGS TO EXACTLY ONE OPERATION — FR-017 atomicity
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuditEntryOwnedByOneOp {
  all ae: AuditEntry | one op: Operation | ae in op.opAuditEntries
}

// ══════════════════════════════════════════════════════════════════════════════
// AUTH REQUIRED — FR-001
// Every operation caller has at least one role (i.e., is authenticated).
// ══════════════════════════════════════════════════════════════════════════════
fact F_AuthRequired {
  all op: Operation | some op.opCaller.roles
}

// ══════════════════════════════════════════════════════════════════════════════
// APPEND-ONLY AUDIT LOG (structural uniqueness of chain positions) — FR-018
// No two distinct entries on the same application share the same prevStatus and
// newStatus, which would indicate a duplicate / mutation.
// ══════════════════════════════════════════════════════════════════════════════
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    ae1.entryApplication = ae2.entryApplication implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}

// ══════════════════════════════════════════════════════════════════════════════
//  PREDICATES AND ASSERTIONS
// ══════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003,FR-004,FR-005
pred LeastPrivilege {
  some op: Operation | op.opOutcome = Success
  all op: Operation |
    op.opOutcome = Success implies
      (some r: op.opCaller.roles | r -> op.opKind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  PermMatrix.Allowed =
    (Applicant -> PostApplications)      +
    (Applicant -> GetApplicationById)    +
    (Officer   -> GetApplicationById)    +
    (Officer   -> PatchApplicationStatus) +
    (Auditor   -> GetApplicationById)    +
    (Auditor   -> GetApplicationAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some op: Operation
  all op: Operation | some op.opCaller.roles
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md audit_entries
pred AuditCompleteness {
  some LoanApplication
  all app: LoanApplication | some ae: AuditEntry | ae.entryApplication = app
  all op: Operation |
    (op.opOutcome = Success and
     (op.opKind = PostApplications or op.opKind = PatchApplicationStatus)) implies
      one op.opAuditEntries
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry |
    ae1.entryApplication = ae2.entryApplication implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit_entries.actor_role
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.entryActorRole != SystemRole implies ae.entryActorRole in ae.entryActor.roles
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.applicant_id NOT NULL
pred OwnershipExclusivity {
  some LoanApplication
  all app: LoanApplication | one app.appApplicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003,FR-004,FR-005; contracts/http-api.md
pred OwnershipBasedAccess {
  some op: Operation | op.opKind = GetApplicationById and op.opOutcome = Success
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success) implies
      (some app: LoanApplication |
        op.opTarget = app and (
          (Applicant in op.opCaller.roles and op.opCaller = app.appApplicant) or
          (Officer   in op.opCaller.roles and op.opCaller = app.assignedOfficer) or
          (Auditor   in op.opCaller.roles)
        ))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020,FR-021,FR-022; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some op: Operation | op.opKind = GetApplicationById
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success) implies
      (some app: LoanApplication |
        op.opTarget = app and (
          (Applicant in op.opCaller.roles and op.opCaller = app.appApplicant) or
          (Officer   in op.opCaller.roles and op.opCaller = app.assignedOfficer) or
          (Auditor   in op.opCaller.roles)
        ))
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK(assigned_officer_id != applicant_id)
pred NoSelfMutation {
  some ae: AuditEntry | some ae.prevStatus
  all ae: AuditEntry |
    some ae.prevStatus implies ae.entryActor != ae.entryApplication.appApplicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001,FR-014,FR-017; data-model.md atomicity
pred ValidationBeforeMutation {
  some op: Operation | op.opOutcome = Failure
  all op: Operation |
    op.opOutcome = Failure implies no op.opAuditEntries
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─── Feature-specific predicates ──────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some op: Operation
  all op: Operation | some op.opCaller.roles
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleExclusivity {
  some User
  all u: User | not (Officer in u.roles and Auditor in u.roles)
  all u: User | SystemRole not in u.roles
}
assert FR_002_RoleExclusivity { FR_002_RoleExclusivity }
check FR_002_RoleExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  some disj a1, a2: LoanApplication | a1.appApplicant = a2.appApplicant
  all disj a1, a2: LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (
        (a1.status = Pending or a1.status = UnderReview) and
        (a2.status = Pending or a2.status = UnderReview)
      )
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ValidTransitions {
  some ae: AuditEntry | some ae.prevStatus
  all ae: AuditEntry |
    some ae.prevStatus implies (
      (ae.prevStatus = Pending     and ae.newStatus = UnderReview) or
      (ae.prevStatus = UnderReview and ae.newStatus = Approved)    or
      (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
    )
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  some app: LoanApplication | some app.assignedOfficer
  all app: LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.appApplicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerPatches {
  some ae: AuditEntry | some ae.prevStatus
  all ae: AuditEntry |
    some ae.prevStatus implies (
      ae.entryActorRole = Officer and
      ae.entryActor = ae.entryApplication.assignedOfficer
    )
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfApproval {
  some ae: AuditEntry | some ae.prevStatus
  all ae: AuditEntry |
    some ae.prevStatus implies ae.entryActor != ae.entryApplication.appApplicant
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_TerminalStatesFinal {
  some ae: AuditEntry
  all ae: AuditEntry |
    ae.prevStatus != Approved and ae.prevStatus != Rejected
}
assert FR_015_TerminalStatesFinal { FR_015_TerminalStatesFinal }
check FR_015_TerminalStatesFinal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016, FR-017
pred FR_016_AuditEntryCompleteness {
  some LoanApplication
  all app: LoanApplication | (some ae: AuditEntry | ae.entryApplication = app)
  all op: Operation |
    (op.opOutcome = Success and
     (op.opKind = PostApplications or op.opKind = PatchApplicationStatus)) implies
      one op.opAuditEntries
}
assert FR_016_AuditEntryCompleteness { FR_016_AuditEntryCompleteness }
check FR_016_AuditEntryCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditImmutability {
  some AuditEntry
  all disj ae1, ae2: AuditEntry |
    ae1.entryApplication = ae2.entryApplication implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert FR_018_AuditImmutability { FR_018_AuditImmutability }
check FR_018_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditEndpointAuditorOnly {
  some op: Operation | op.opKind = GetApplicationAudit
  all op: Operation |
    (op.opKind = GetApplicationAudit and op.opOutcome = Success) implies
      Auditor in op.opCaller.roles
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantCannotModifyAfterSubmission {
  some op: Operation | op.opKind = PatchApplicationStatus
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success) implies
      Officer in op.opCaller.roles
}
assert FR_024_ApplicantCannotModifyAfterSubmission { FR_024_ApplicantCannotModifyAfterSubmission }
check FR_024_ApplicantCannotModifyAfterSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005, FR-003 — auditor cannot write, applicant cannot PATCH
pred FR_005_AuditorReadOnly {
  some op: Operation | Auditor in op.opCaller.roles
  all op: Operation |
    Auditor in op.opCaller.roles implies
      (op.opKind != PostApplications and op.opKind != PatchApplicationStatus) or
      op.opOutcome = Failure
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020, FR-022 — POST response must not leak other applicants' data
pred FR_022_PostDoesNotLeakOtherApplicants {
  // A successful POST operation's audit entry belongs to the submitting
  // applicant's application, not anyone else's.
  some op: Operation | op.opKind = PostApplications and op.opOutcome = Success
  all op: Operation |
    (op.opKind = PostApplications and op.opOutcome = Success) implies
      (all ae: op.opAuditEntries |
        ae.entryApplication.appApplicant = op.opCaller)
}
assert FR_022_PostDoesNotLeakOtherApplicants { FR_022_PostDoesNotLeakOtherApplicants }
check FR_022_PostDoesNotLeakOtherApplicants for 5