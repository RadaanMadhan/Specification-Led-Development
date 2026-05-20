// === feature_model.als — Alloy 6 model for Team Task Management (B-L1) ===
// Feature branch: 006-task-management
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ── Task status ────────────────────────────────────────────────────────────
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ── Core domain entities ───────────────────────────────────────────────────

// Every authenticated user is a Member (data-model.md, FR-003)
sig Member {}

// A persisted, live (non-deleted) task
sig Task {
  status   : one TaskStatus,
  creator  : one Member,
  assignee : lone Member
}

// Append-only operational deletion log (data-model.md TaskDeletion, FR-018)
sig TaskDeletion {
  deletedTask : one TaskRef,   // opaque id – FK severed at delete time
  deletedBy   : one Member
}

// Opaque task identifiers (needed so TaskDeletion can reference deleted tasks)
sig TaskRef {}

// ── Operation model ────────────────────────────────────────────────────────

abstract sig OperationKind {}
one sig OpCreate, OpView, OpList, OpEdit, OpDelete extends OperationKind {}

// An Operation is one API call attempt (authenticated OR unauthenticated).
// `caller` is lone: absent means unauthenticated (no resolved Member).
sig Operation {
  kind   : one OperationKind,
  caller : lone Member
}

// An EditOperation additionally carries the task being edited and,
// optionally, a new status (for the closed-task reopen path, FR-011).
sig EditOperation extends Operation {
  target      : one Task,
  newStatus   : lone TaskStatus   // present iff the request changes status
}

// A DeleteOperation produces exactly one log entry (FR-018).
sig DeleteOperation extends Operation {
  target   : one Task,
  logEntry : one TaskDeletion
}

// A CreateOperation produces exactly one new Task (FR-009).
sig CreateOperation extends Operation {
  produced : one Task
}

// ── Non-empty universe ─────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Member
  some Task
  some TaskRef
  some TaskDeletion
  some Operation
  some EditOperation
  some DeleteOperation
  some CreateOperation
}

// ── Permission matrix ──────────────────────────────────────────────────────
// Flat peer model: all authenticated Members may perform every OperationKind.
// "Unauthenticated" is represented by caller = ∅ (no Member).
// The matrix is trivially full; the key invariant is AuthRequiredEverywhere.
one sig PermMatrix {
  Allowed : set Member -> OperationKind
}

fact F_PermissionMatrix {
  // Every (Member, OperationKind) pair is allowed — flat peer model (FR-004).
  PermMatrix.Allowed = Member -> OperationKind
}

// ── Structural facts ───────────────────────────────────────────────────────

// FR-001, FR-004: Every operation whose caller is absent (unauthenticated)
// is NOT in the allowed set — enforced by requiring that proceeding operations
// (those that reach business logic) always have a caller.
fact F_AuthRequiredEverywhere {
  // Every operation that is any of the concrete sub-kinds has a caller.
  all op : EditOperation   | some op.caller
  all op : DeleteOperation | some op.caller
  all op : CreateOperation | some op.caller
  // Plain view/list operations also require auth (FR-001).
  all op : Operation       | op.kind in (OpView + OpList) implies (some op.caller)
}

// FR-002: The caller is taken from auth context (modelled as: creator of a
// produced task equals the caller of the CreateOperation that produced it).
fact F_AttributionCorrectness {
  all op : CreateOperation | op.produced.creator = op.caller
}

// FR-008: A task's assignee, if present, must be a Member (always true by
// type), and at most one assignee (enforced by lone).  Also: no task is
// its own creator in an impossible sense — assignee can differ from creator.
// The "lone" multiplicity on Task.assignee encodes "at most one assignee".
// Nothing extra to add here; the type system handles it.

// FR-008 / OwnershipExclusivity: every Task has exactly one creator and
// at most one assignee.
fact F_OwnershipExclusivity {
  all t : Task | one t.creator
  all t : Task | lone t.assignee
}

// FR-009: The creator field is set at creation time and never changes.
// In this static snapshot model we encode it as: for every CreateOperation,
// the produced task's creator equals the operation's caller, and no two
// distinct CreateOperations claim to have produced the same Task.
fact F_CreatorImmutability {
  // Each Task is produced by at most one CreateOperation.
  all disj op1, op2 : CreateOperation | op1.produced != op2.produced
}

// FR-010: Initial status on creation is Todo.
fact F_InitialStatusTodo {
  all op : CreateOperation | op.produced.status = Todo
}

// FR-011: Closed-task edit rule.
// An EditOperation targeting a Task whose current status is Done MUST
// include a newStatus value that is NOT Done (i.e., Todo or InProgress).
fact F_ClosedTaskEditRule { /* MUTATED — body cleared by validator */ }

// FR-012 / FR-018: Every DeleteOperation produces exactly one TaskDeletion
// log entry, and the deleter in the log matches the operation caller.
fact F_DeletionLogged {
  all op : DeleteOperation | op.logEntry.deletedBy = op.caller
}

// AppendOnly: No two distinct DeleteOperations share the same TaskDeletion
// log entry — each log entry records exactly one deletion event.
fact F_AppendOnlyDeletionLog {
  all disj op1, op2 : DeleteOperation | op1.logEntry != op2.logEntry
}

// FR-017: updated_at is refreshed on every edit.
// Modelled structurally: every EditOperation targets an existing Task.
fact F_EditTargetsExistingTask {
  all op : EditOperation | op.target in Task
}

// FR-003: Single implicit workspace — all Members and all Tasks coexist
// in one namespace; no isolation between Members.
// Encoded structurally: there is no partition on Task or Member.
// (No additional constraint needed beyond the absence of a workspace field.)

// ── Predicate / assertion pairs ────────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  some Operation
  all op : EditOperation   | some op.caller
  all op : DeleteOperation | some op.caller
  all op : CreateOperation | some op.caller
  all op : Operation | op.kind in (OpView + OpList) implies (some op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §Authentication; spec.md FR-004
pred PermissionCompleteness {
  // Every (Member, OperationKind) cell is defined (allowed in flat peer model).
  some Member
  some OperationKind
  PermMatrix.Allowed = Member -> OperationKind
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: data-model.md TaskDeletion "No UPDATE/DELETE code path targets this table"; spec.md FR-018
pred AppendOnly {
  some TaskDeletion
  // No two distinct delete operations share a log entry.
  all disj op1, op2 : DeleteOperation | op1.logEntry != op2.logEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md TaskDeletion
pred AuditCompleteness {
  some DeleteOperation
  // Every DeleteOperation has a log entry, and the deleter is attributed.
  all op : DeleteOperation | one op.logEntry and op.logEntry.deletedBy = op.caller
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-002, FR-009; data-model.md Task.created_by
pred AttributionCorrectness {
  some CreateOperation
  all op : CreateOperation | op.produced.creator = op.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md Task.assignee_id "at most one assignee"
pred OwnershipExclusivity {
  some Task
  all t : Task | lone t.assignee
  all t : Task | one t.creator
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005, FR-006; data-model.md Validation section
// Encoded as: every CreateOperation has a caller (auth passes) before a Task is produced.
pred ValidationBeforeMutation {
  some CreateOperation
  all op : CreateOperation | some op.caller and one op.produced
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ── FR-specific predicates ─────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  all op : EditOperation   | some op.caller
  all op : DeleteOperation | some op.caller
  all op : CreateOperation | some op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_IdentityFromAuthContext {
  some CreateOperation
  // Creator of produced task equals the operation's resolved caller, not
  // anything that could be supplied in the payload.
  all op : CreateOperation | op.produced.creator = op.caller
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
pred FR_003_004_FlatPeerPermissions {
  some Member
  // All (Member, OperationKind) pairs are in the allowed set.
  PermMatrix.Allowed = Member -> OperationKind
  // No distinguished admin member: every member has the same allowed set.
  all disj m1, m2 : Member |
    m1.(PermMatrix.Allowed) = m2.(PermMatrix.Allowed)
}
assert FR_003_004_FlatPeerPermissions { FR_003_004_FlatPeerPermissions }
check FR_003_004_FlatPeerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeAtMostOneMember {
  some Task
  all t : Task | lone t.assignee
}
assert FR_008_AssigneeAtMostOneMember { FR_008_AssigneeAtMostOneMember }
check FR_008_AssigneeAtMostOneMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreatorRecordedImmutable {
  some CreateOperation
  // Each Task is produced by exactly one CreateOperation.
  all t : Task | one { op : CreateOperation | op.produced = t }
  // That operation's caller is the recorded creator.
  all op : CreateOperation | op.produced.creator = op.caller
}
assert FR_009_CreatorRecordedImmutable { FR_009_CreatorRecordedImmutable }
check FR_009_CreatorRecordedImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_InitialStatusTodo {
  some CreateOperation
  all op : CreateOperation | op.produced.status = Todo
}
assert FR_010_InitialStatusTodo { FR_010_InitialStatusTodo }
check FR_010_InitialStatusTodo for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClosedTaskEditRule {
  some EditOperation
  // Any EditOperation on a Done task must carry a non-Done newStatus.
  all op : EditOperation |
    op.target.status = Done implies
      (some op.newStatus and op.newStatus != Done)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012, FR-018
pred FR_012_018_DeletionLogged {
  some DeleteOperation
  all op : DeleteOperation | one op.logEntry
  all op : DeleteOperation | op.logEntry.deletedBy = op.caller
  // Each log entry belongs to exactly one delete operation.
  all disj op1, op2 : DeleteOperation | op1.logEntry != op2.logEntry
}
assert FR_012_018_DeletionLogged { FR_012_018_DeletionLogged }
check FR_012_018_DeletionLogged for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_CreatorSetOnce {
  some CreateOperation
  // No task is claimed as output by more than one CreateOperation.
  all disj op1, op2 : CreateOperation | op1.produced != op2.produced
}
assert FR_017_CreatorSetOnce { FR_017_CreatorSetOnce }
check FR_017_CreatorSetOnce for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ClosedTaskViolation { some op : EditOperation | op.target.status = Done and no op.newStatus }
