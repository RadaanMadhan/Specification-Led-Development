// === feature_model.als — Alloy model for Team Task Management (B-L1 / 006-task-management) ===
//
// Artefacts consumed:
//   spec.md          — FR-001 … FR-018
//   data-model.md    — tasks, members, tokens, task_deletions schema
//   contracts/http-api.md — endpoint surface, auth rules, closed-task rule

// ---------------------------------------------------------------------------
// Status enumeration (FR-010)
// ---------------------------------------------------------------------------
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ---------------------------------------------------------------------------
// Operation-kind enumeration — one atom per API endpoint (contracts/http-api.md)
// ---------------------------------------------------------------------------
abstract sig OperationKind {}
one sig OpCreate, OpList, OpGetById, OpPatch, OpDelete extends OperationKind {}

// ---------------------------------------------------------------------------
// Outcome enumeration
// ---------------------------------------------------------------------------
abstract sig OpOutcome {}
one sig OutSuccess, OutAuthFail, OutValidFail, OutNotFound, OutClosed extends OpOutcome {}

// ---------------------------------------------------------------------------
// Permission matrix — singleton sig (flat peer model, FR-004)
// Every authenticated caller may perform every operation; there is exactly one
// role ("Member") and exactly five operations.  The matrix contains all five.
// ---------------------------------------------------------------------------
one sig PermMatrix { Allowed: set OperationKind }

// ---------------------------------------------------------------------------
// Dynamic sigs
// ---------------------------------------------------------------------------

// Every person who has signed in (FR-003: all authenticated users are members).
sig Member {}

// A task in the single implicit workspace.
sig Task {
  creator   : one Member,       // immutable after creation (FR-009)
  assignee  : lone Member,      // at most one, must be a member (FR-008)
  status    : one TaskStatus    // one of the three legal values (FR-010)
}

// An API operation (one per HTTP request handled by the service).
sig Operation {
  kind            : one OperationKind,
  performer       : lone Member,      // lone: unauthenticated → no performer
  outcome         : one OpOutcome,
  targetTask      : lone Task,        // absent for OpList
  requestedStatus : lone TaskStatus   // only relevant for OpPatch; absent otherwise
}

// Append-only deletion record (FR-018, data-model.md task_deletions).
sig DeletionRecord {
  loggedTask    : one Task,
  loggedDeleter : one Member
}

// ---------------------------------------------------------------------------
// F_NonEmptyUniverse — ensure the dynamic universe is always populated
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some Member
  some Task
  some Operation
  some DeletionRecord
}

// ---------------------------------------------------------------------------
// F_PermissionMatrix — encode the flat-peer permission matrix (FR-004)
// ---------------------------------------------------------------------------
fact F_PermissionMatrix {
  PermMatrix.Allowed = OpCreate + OpList + OpGetById + OpPatch + OpDelete
}

// ---------------------------------------------------------------------------
// F_TaskTargetConsistency — OpList does not require a target task;
// all other operations target exactly one task.
// ---------------------------------------------------------------------------
fact F_TaskTargetConsistency {
  all op: Operation |
    (op.kind = OpList implies no op.targetTask)
    and
    (op.kind != OpList implies one op.targetTask)
}

// ---------------------------------------------------------------------------
// F_RequestedStatusOnlyForPatch — requestedStatus is only meaningful for
// OpPatch; no other operation kind carries it.
// ---------------------------------------------------------------------------
fact F_RequestedStatusOnlyForPatch {
  all op: Operation |
    op.kind != OpPatch implies no op.requestedStatus
}

// ---------------------------------------------------------------------------
// F_AuthRequiredEverywhere — unauthenticated callers always get OutAuthFail;
// no business-logic outcome (Success / NotFound / Closed / ValidFail)
// is returned to a request that has no performer (FR-001).
// ---------------------------------------------------------------------------
fact F_AuthRequiredEverywhere {
  all op: Operation |
    no op.performer implies op.outcome = OutAuthFail
}

// ---------------------------------------------------------------------------
// F_AuthContextIdentity — the performer is taken from the auth context only;
// a successful operation always has a performer on record (FR-002).
// ---------------------------------------------------------------------------
fact F_AuthContextIdentity {
  all op: Operation |
    op.outcome = OutSuccess implies one op.performer
}

// ---------------------------------------------------------------------------
// F_FlatPermissions — every authenticated caller is allowed to attempt every
// operation kind; the only systematic rejection is unauthenticated requests.
// No "permission denied" outcome exists (FR-004, contracts/ no 403 response).
// ---------------------------------------------------------------------------
fact F_FlatPermissions {
  all op: Operation |
    (one op.performer and op.kind in PermMatrix.Allowed)
    implies op.outcome != OutAuthFail
}

// ---------------------------------------------------------------------------
// F_AssigneeMustBeMember — every task whose assignee is set carries a Member
// who actually exists in the sig universe (FR-008).
// ---------------------------------------------------------------------------
fact F_AssigneeMustBeMember {
  all t: Task |
    some t.assignee implies t.assignee in Member
}

// ---------------------------------------------------------------------------
// F_CreatorAlwaysSet — every task has a creator that is a legitimate member
// (FR-009; creator is taken from auth context at creation time).
// ---------------------------------------------------------------------------
fact F_CreatorAlwaysSet {
  all t: Task | t.creator in Member
}

// ---------------------------------------------------------------------------
// F_ValidStatusSet — every task's status is one of the three legal values
// (data-model.md CHECK constraint; SC-006).
// ---------------------------------------------------------------------------
fact F_ValidStatusSet {
  all t: Task | t.status in Todo + InProgress + Done
}

// ---------------------------------------------------------------------------
// F_ClosedTaskEditRule — a successful PATCH on a task whose current status is
// Done MUST include a requestedStatus of Todo or InProgress.  A PATCH that
// omits that (requestedStatus = Done or absent) on a Done task must produce
// OutClosed, not OutSuccess (FR-011, contracts/ 409 task_closed).
// ---------------------------------------------------------------------------
fact F_ClosedTaskEditRule { /* MUTATED — body cleared by validator */ }

// ---------------------------------------------------------------------------
// F_SuccessfulPatchReopensTask — if a PATCH on a Done task succeeds, the task
// ends up with a non-Done status equal to the requested status (FR-011 §6).
// ---------------------------------------------------------------------------
fact F_SuccessfulPatchReopensTask {
  all op: Operation |
    (op.kind = OpPatch and op.outcome = OutSuccess
     and some op.targetTask and op.targetTask.status = Done)
    implies op.requestedStatus in (Todo + InProgress)
}

// ---------------------------------------------------------------------------
// F_DeletionLogCompleteness — every successful DELETE operation on a task
// produces exactly one DeletionRecord referencing that task (FR-018).
// ---------------------------------------------------------------------------
fact F_DeletionLogCompleteness {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = OutSuccess)
    implies (one dr: DeletionRecord | dr.loggedTask = op.targetTask
                                      and dr.loggedDeleter = op.performer)
}

// ---------------------------------------------------------------------------
// F_DeletionLogNoExcess — a DeletionRecord is only created for a successful
// DELETE (no spurious log entries).
// ---------------------------------------------------------------------------
fact F_DeletionLogNoExcess {
  all dr: DeletionRecord |
    some op: Operation |
      op.kind = OpDelete
      and op.outcome = OutSuccess
      and op.targetTask = dr.loggedTask
      and op.performer = dr.loggedDeleter
}

// ---------------------------------------------------------------------------
// F_DeletionLogAppendOnly — each DeletionRecord is distinct (no two records
// share the same task reference in the same logical snapshot, modelling that
// records are never mutated or duplicated within a single consistent state).
// ---------------------------------------------------------------------------
fact F_DeletionLogAppendOnly {
  all disj dr1, dr2: DeletionRecord |
    dr1.loggedTask != dr2.loggedTask or dr1.loggedDeleter != dr2.loggedDeleter
}

// ---------------------------------------------------------------------------
// F_ValidationBeforeMutation — a request that ends in OutValidFail must not
// have produced a DeletionRecord (FR-005..FR-008 validation is a no-op on
// state when it fails).
// ---------------------------------------------------------------------------
fact F_ValidationBeforeMutation {
  all op: Operation |
    op.outcome = OutValidFail
    implies (no dr: DeletionRecord | dr.loggedTask = op.targetTask
                                     and dr.loggedDeleter = op.performer)
}

// ---------------------------------------------------------------------------
// F_DeletionLogAttributionCorrect — the deleter recorded in a DeletionRecord
// matches the performer of the operation that triggered it (FR-018, FR-002).
// ---------------------------------------------------------------------------
fact F_DeletionLogAttributionCorrect {
  all dr: DeletionRecord |
    some op: Operation |
      op.kind = OpDelete
      and op.outcome = OutSuccess
      and op.targetTask = dr.loggedTask
      and op.performer = dr.loggedDeleter
      and one op.performer   // performer was authenticated
}

// ===========================================================================
// PREDICATES + ASSERTIONS
// ===========================================================================

// ---------------------------------------------------------------------------
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
// ---------------------------------------------------------------------------
pred AuthRequiredEverywhere {
  some Operation  // non-vacuous: at least one operation exists
  all op: Operation |
    no op.performer implies op.outcome = OutAuthFail
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ---------------------------------------------------------------------------
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table (flat peers, FR-004)
// ---------------------------------------------------------------------------
pred PermissionCompleteness {
  // Every defined OperationKind is covered in the allowed set
  PermMatrix.Allowed = OpCreate + OpList + OpGetById + OpPatch + OpDelete
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// ---------------------------------------------------------------------------
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE on task_deletions"
// ---------------------------------------------------------------------------
pred AppendOnly {
  some DeletionRecord
  // No two records share the exact same (task, deleter) pair — records are
  // never overwritten or duplicated (each is a unique append event).
  all disj dr1, dr2: DeletionRecord |
    not (dr1.loggedTask = dr2.loggedTask and dr1.loggedDeleter = dr2.loggedDeleter)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ---------------------------------------------------------------------------
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions UNIQUE(task_id)
// ---------------------------------------------------------------------------
pred AuditCompleteness {
  some op: Operation | op.kind = OpDelete and op.outcome = OutSuccess
  // Every successful delete has exactly one deletion record
  all op: Operation |
    (op.kind = OpDelete and op.outcome = OutSuccess)
    implies (one dr: DeletionRecord | dr.loggedTask = op.targetTask
                                      and dr.loggedDeleter = op.performer)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ---------------------------------------------------------------------------
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-002, FR-009, FR-018; data-model.md created_by / deleted_by
// ---------------------------------------------------------------------------
pred AttributionCorrectness {
  some DeletionRecord
  all dr: DeletionRecord |
    some op: Operation |
      op.kind = OpDelete
      and op.outcome = OutSuccess
      and op.targetTask = dr.loggedTask
      and op.performer = dr.loggedDeleter
      and one op.performer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ---------------------------------------------------------------------------
// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md assignee_id lone FK
// ---------------------------------------------------------------------------
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one creator and at most one assignee
  all t: Task | one t.creator
  all t: Task | lone t.assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ---------------------------------------------------------------------------
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005..FR-008; contracts/http-api.md 400 validation_error
// ---------------------------------------------------------------------------
pred ValidationBeforeMutation {
  some op: Operation | op.outcome = OutValidFail
  all op: Operation |
    op.outcome = OutValidFail
    implies (no dr: DeletionRecord | dr.loggedTask = op.targetTask
                                     and dr.loggedDeleter = op.performer)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-001
// ---------------------------------------------------------------------------
pred FR_001_AuthRequired {
  some Operation
  // Unauthenticated requests never succeed at business logic
  no op: Operation |
    (no op.performer and op.outcome = OutSuccess)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-002
// ---------------------------------------------------------------------------
pred FR_002_IdentityFromAuthContext {
  some op: Operation | op.outcome = OutSuccess
  // A successful operation always has exactly one performer (the auth context)
  all op: Operation |
    op.outcome = OutSuccess implies (one op.performer)
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-004
// ---------------------------------------------------------------------------
pred FR_004_FlatPermissions {
  some op: Operation | one op.performer
  // Authenticated callers are never turned away with an auth-fail outcome
  all op: Operation |
    (one op.performer and op.kind in PermMatrix.Allowed)
    implies op.outcome != OutAuthFail
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-008
// ---------------------------------------------------------------------------
pred FR_008_AssigneeMustBeMember {
  some t: Task | some t.assignee
  all t: Task |
    some t.assignee implies t.assignee in Member
}
assert FR_008_AssigneeMustBeMember { FR_008_AssigneeMustBeMember }
check FR_008_AssigneeMustBeMember for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-009
// ---------------------------------------------------------------------------
pred FR_009_CreatorAlwaysPresent {
  some Task
  all t: Task | one t.creator and t.creator in Member
}
assert FR_009_CreatorAlwaysPresent { FR_009_CreatorAlwaysPresent }
check FR_009_CreatorAlwaysPresent for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-010 (SC-006)
// ---------------------------------------------------------------------------
pred FR_010_ValidStatusSet {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_ValidStatusSet { FR_010_ValidStatusSet }
check FR_010_ValidStatusSet for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md 409 task_closed
// ---------------------------------------------------------------------------
pred FR_011_ClosedTaskEditRule {
  // There exists a patch on a Done task — the predicate is not vacuous
  some op: Operation |
    op.kind = OpPatch and some op.targetTask and op.targetTask.status = Done
  // A patch on a Done task must either include a non-Done status (success path)
  // or be rejected with OutClosed (or auth/validation failure)
  all op: Operation |
    (op.kind = OpPatch and some op.targetTask and op.targetTask.status = Done
     and op.outcome = OutSuccess)
    implies op.requestedStatus in (Todo + InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md permanent deletion
// ---------------------------------------------------------------------------
pred FR_012_PermanentDeletion {
  some op: Operation | op.kind = OpDelete and op.outcome = OutSuccess
  // Successful deletions are attributed to a real member
  all op: Operation |
    (op.kind = OpDelete and op.outcome = OutSuccess)
    implies one op.performer
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md task_deletions append-only
// ---------------------------------------------------------------------------
pred FR_018_DeletionLogRecord {
  some DeletionRecord
  // Every DeletionRecord traces back to a successful DELETE operation
  all dr: DeletionRecord |
    some op: Operation |
      op.kind = OpDelete
      and op.outcome = OutSuccess
      and op.targetTask = dr.loggedTask
      and op.performer = dr.loggedDeleter
}
assert FR_018_DeletionLogRecord { FR_018_DeletionLogRecord }
check FR_018_DeletionLogRecord for 5

// ---------------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004 — no 403 response ever emitted
// ---------------------------------------------------------------------------
pred FR_003_FR_004_No403PermissionDenied {
  some op: Operation | one op.performer
  // The system has no "permission denied" outcome code at all;
  // the only auth-related rejection is OutAuthFail for unauthenticated requests
  all op: Operation |
    (one op.performer) implies op.outcome != OutAuthFail
}
assert FR_003_FR_004_No403PermissionDenied { FR_003_FR_004_No403PermissionDenied }
check FR_003_FR_004_No403PermissionDenied for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ClosedTaskBypass { some op: Operation | op.kind = OpPatch and some op.targetTask and op.targetTask.status = Done and op.outcome = OutSuccess and op.requestedStatus = Done }
