// === feature_model.als — Alloy model for Team Task Management ===
// Feature folder: B-L1  (spec branch: 006-task-management)
// Generated artefacts: spec.md, data-model.md, contracts/http-api.md

// ---------------------------------------------------------------
//  Auxiliary Boolean
// ---------------------------------------------------------------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------------------------------------------------------------
//  Domain: Members and Tokens
// ---------------------------------------------------------------
sig Member {}

sig Token {
  resolves: one Member
}

// ---------------------------------------------------------------
//  Domain: Task
// ---------------------------------------------------------------
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

sig Task {
  creator:    one Member,
  assignee:   lone Member,
  status:     one TaskStatus,
  lastEditor: one Member,
  titleValid: one Bool      // abstracts: title is 1-200 chars after trim
}

// ---------------------------------------------------------------
//  Domain: Deletion log (append-only operational record, FR-018)
// ---------------------------------------------------------------
sig TaskDeletion {
  deletedBy:  one Member,
  sourceTask: one Task     // links deletion record to the deleted task
}

// ---------------------------------------------------------------
//  Domain: Operations (API calls)
// ---------------------------------------------------------------
abstract sig OperationKind {}
one sig OpCreate, OpList, OpGetById, OpEdit, OpDelete extends OperationKind {}

abstract sig Outcome {}
one sig Success, Failure extends Outcome {}

sig Operation {
  kind:           one OperationKind,
  caller:         one Member,
  callerToken:    one Token,
  targetTask:     lone Task,
  outcome:        one Outcome,
  deletion:       lone TaskDeletion,  // present iff kind=OpDelete & outcome=Success
  newStatus:      lone TaskStatus,    // the requested new status (for edit/create)
  includesReopen: one Bool            // edit request includes Todo/InProgress transition
}

// ---------------------------------------------------------------
//  F_NonEmptyUniverse — ensure every dynamic sig has ≥1 atom
// ---------------------------------------------------------------
fact F_NonEmptyUniverse {
  some Member
  some Token
  some Task
  some TaskDeletion
  some Operation
}

// ---------------------------------------------------------------
//  F_TokenCallerConsistency
//  Token must resolve to the operation's caller (auth context integrity)
// ---------------------------------------------------------------
fact F_TokenCallerConsistency {
  all op: Operation |
    op.callerToken.resolves = op.caller
}

// ---------------------------------------------------------------
//  F_AuthRequiredEverywhere
//  Every operation that succeeds had a valid token for its caller.
//  (Structurally: every Operation has a Token that resolves to its Member.)
//  Encodes FR-001 / SC-005: no unauthenticated request may succeed.
// ---------------------------------------------------------------
fact F_AuthRequiredEverywhere {
  all op: Operation |
    op.outcome = Success implies (one t: Token | t.resolves = op.caller and t = op.callerToken)
}

// ---------------------------------------------------------------
//  F_FlatPermissions
//  All authenticated members share the same permitted operation set —
//  no operation is denied to one authenticated member while allowed to another.
//  Encodes FR-004: flat peer model; no role hierarchy.
// ---------------------------------------------------------------
fact F_FlatPermissions {
  all disj m1, m2: Member |
    all k: OperationKind |
      (some op1: Operation | op1.caller = m1 and op1.kind = k and op1.outcome = Success)
      implies
      (some op2: Operation | op2.caller = m2 and op2.kind = k and op2.outcome = Success)
}

// ---------------------------------------------------------------
//  F_AssigneeIsMember
//  A task's assignee (if present) must be a Member.
//  Encodes FR-008.
// ---------------------------------------------------------------
fact F_AssigneeIsMember {
  all t: Task |
    some t.assignee implies t.assignee in Member
}

// ---------------------------------------------------------------
//  F_AtMostOneAssignee
//  Each task has at most one assignee at any time.
//  Encodes FR-008.
// ---------------------------------------------------------------
fact F_AtMostOneAssignee {
  all t: Task |
    lone t.assignee
}

// ---------------------------------------------------------------
//  F_CreatorIsMember
//  A task's creator is always a Member.
//  Encodes FR-009.
// ---------------------------------------------------------------
fact F_CreatorIsMember {
  all t: Task |
    t.creator in Member
}

// ---------------------------------------------------------------
//  F_TaskCreatorFromAuth
//  For every successful CreateOp the operation's caller is the
//  creator of the targeted (newly created) task.
//  Encodes FR-002 (identity from auth context) + FR-009.
// ---------------------------------------------------------------
fact F_TaskCreatorFromAuth {
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    (some t: Task | op.targetTask = t and t.creator = op.caller)
}

// ---------------------------------------------------------------
//  F_InitialStatusTodo
//  A task born from a successful CreateOp has status Todo.
//  Encodes FR-010.
// ---------------------------------------------------------------
fact F_InitialStatusTodo {
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    (some t: Task | op.targetTask = t and t.status = Todo)
}

// ---------------------------------------------------------------
//  F_ValidStatusSet
//  Every task's status is one of {Todo, InProgress, Done}.
//  (Structural — enforced by the sig hierarchy, but stated explicitly
//   so mutation tests can break it.)
//  Encodes FR-010 / SC-006.
// ---------------------------------------------------------------
fact F_ValidStatusSet {
  all t: Task |
    t.status in (Todo + InProgress + Done)
}

// ---------------------------------------------------------------
//  F_ClosedTaskEditRule
//  An edit operation on a Done task MUST include a status transition
//  to Todo or InProgress; otherwise it fails with 409 task_closed.
//  Encodes FR-011 / US2 #5/#6.
// ---------------------------------------------------------------
fact F_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = OpEdit and some op.targetTask and op.targetTask.status = Done) implies
    (op.outcome = Failure or op.includesReopen = BTrue)
}

// ---------------------------------------------------------------
//  F_ReopenMeansNonDoneNewStatus
//  When an edit reopens a Done task (includesReopen=BTrue and Success),
//  the requested newStatus is Todo or InProgress.
//  Encodes FR-011.
// ---------------------------------------------------------------
fact F_ReopenMeansNonDoneNewStatus {
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success and op.includesReopen = BTrue) implies
    (op.newStatus in (Todo + InProgress))
}

// ---------------------------------------------------------------
//  F_DeletionLogged
//  Every successful DeleteOp produces exactly one TaskDeletion record
//  linking back to the target task.
//  Encodes FR-018 / FR-012.
// ---------------------------------------------------------------
fact F_DeletionLogged {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
    (one dl: TaskDeletion |
       op.deletion = dl and dl.sourceTask = op.targetTask and dl.deletedBy = op.caller)
}

// ---------------------------------------------------------------
//  F_DeletionAttributionCorrectness
//  The TaskDeletion's deletedBy equals the caller of the DeleteOp.
//  Encodes FR-018 (deleter identity in operational log).
// ---------------------------------------------------------------
fact F_DeletionAttributionCorrectness {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
    (op.deletion.deletedBy = op.caller)
}

// ---------------------------------------------------------------
//  F_AppendOnlyDeletionLog
//  No two successful DeleteOps share a TaskDeletion record (no overwrite/
//  reuse). Each deletion log entry is unique to its originating operation.
//  Encodes the append-only semantics of task_deletions (data-model.md).
// ---------------------------------------------------------------
fact F_AppendOnlyDeletionLog {
  all disj op1, op2: Operation |
    (op1.kind = OpDelete and op1.outcome = Success and
     op2.kind = OpDelete and op2.outcome = Success) implies
    (op1.deletion != op2.deletion)
}

// ---------------------------------------------------------------
//  F_NoDeletionWithoutOp
//  Every TaskDeletion traces back to exactly one successful DeleteOp.
//  Prevents "orphan" deletion records.
// ---------------------------------------------------------------
fact F_NoDeletionWithoutOp {
  all dl: TaskDeletion |
    one op: Operation |
      op.kind = OpDelete and op.outcome = Success and op.deletion = dl
}

// ---------------------------------------------------------------
//  F_NoDeleteOpWithoutTarget
//  A successful delete must target an existing task.
// ---------------------------------------------------------------
fact F_NoDeleteOpWithoutTarget {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
    (some op.targetTask)
}

// ---------------------------------------------------------------
//  F_TitleValidOnSuccess
//  A successfully created or edited task must have a valid title.
//  Encodes FR-005.
// ---------------------------------------------------------------
fact F_TitleValidOnSuccess {
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    (op.targetTask.titleValid = BTrue)
}

// ---------------------------------------------------------------
//  F_LastEditorFromAuth
//  After any successful edit, the task's lastEditor equals the
//  operation's caller (identity from auth context, FR-002, FR-011).
// ---------------------------------------------------------------
fact F_LastEditorFromAuth {
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success) implies
    (op.targetTask.lastEditor = op.caller)
}

// ---------------------------------------------------------------
//  PATTERN PREDICATES
// ---------------------------------------------------------------

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.outcome = Success implies (op.callerToken.resolves = op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: data-model.md task_deletions "No UPDATE/DELETE"; spec.md FR-018
pred AppendOnly {
  some TaskDeletion
  all disj d1, d2: TaskDeletion |
    d1.sourceTask != d2.sourceTask or d1.deletedBy != d2.deletedBy implies d1 != d2
  -- No two deletion records can be "rewrites" of the same operation
  all disj op1, op2: Operation |
    (op1.kind = OpDelete and op1.outcome = Success and
     op2.kind = OpDelete and op2.outcome = Success) implies
    op1.deletion != op2.deletion
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md TaskDeletion
pred AuditCompleteness {
  some op: Operation | op.kind = OpDelete and op.outcome = Success
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
    (one dl: TaskDeletion | op.deletion = dl and dl.sourceTask = op.targetTask)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009, FR-011, FR-018; data-model.md Task.creator, Task.lastEditor, TaskDeletion.deleted_by
pred AttributionCorrectness {
  some op: Operation | op.outcome = Success
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
      op.targetTask.creator = op.caller
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success) implies
      op.targetTask.lastEditor = op.caller
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
      op.deletion.deletedBy = op.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md Task.assignee_id (lone)
pred OwnershipExclusivity {
  some Task
  all t: Task | lone t.assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005; contracts/http-api.md 400 validation_error
pred ValidationBeforeMutation {
  some op: Operation | op.kind = OpCreate and op.outcome = Failure
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Failure) implies
    (no t: Task | op.targetTask = t and t.titleValid = BFalse)
  -- A failed creation does not produce a stored task with invalid title
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    op.targetTask.titleValid = BTrue
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ---------------------------------------------------------------
//  FEATURE-SPECIFIC PREDICATES
// ---------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 — Every operation requires authentication
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    op.outcome = Success implies (one t: Token | t = op.callerToken and t.resolves = op.caller)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — Identity from auth context, not payload
pred FR_002_IdentityFromAuthContext {
  some op: Operation | op.kind = OpCreate and op.outcome = Success
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    op.targetTask.creator = op.callerToken.resolves
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004 — Flat permissions; no member is denied an operation that another member can perform
pred FR_004_FlatPermissions {
  some m: Member | some op: Operation | op.caller = m and op.outcome = Success
  all disj m1, m2: Member |
    all k: OperationKind |
      (some op1: Operation | op1.caller = m1 and op1.kind = k and op1.outcome = Success)
      implies
      (some op2: Operation | op2.caller = m2 and op2.kind = k and op2.outcome = Success)
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 — Assignee must be a current member
pred FR_008_AssigneeIsMember {
  some Task
  all t: Task |
    some t.assignee implies t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — creator set from auth on creation; immutable
pred FR_009_CreatorRecordedOnCreation {
  some op: Operation | op.kind = OpCreate and op.outcome = Success
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    (op.targetTask.creator = op.caller)
}
assert FR_009_CreatorRecordedOnCreation { FR_009_CreatorRecordedOnCreation }
check FR_009_CreatorRecordedOnCreation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — Initial status is Todo on creation
pred FR_010_InitialStatusTodo {
  some op: Operation | op.kind = OpCreate and op.outcome = Success
  all op: Operation |
    (op.kind = OpCreate and op.outcome = Success) implies
    op.targetTask.status = Todo
}
assert FR_010_InitialStatusTodo { FR_010_InitialStatusTodo }
check FR_010_InitialStatusTodo for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — Status always in allowed set
pred FR_010_ValidStatusSet {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_ValidStatusSet { FR_010_ValidStatusSet }
check FR_010_ValidStatusSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — Editing a Done task requires simultaneous reopen
pred FR_011_ClosedTaskEditRule {
  some op: Operation |
    op.kind = OpEdit and some op.targetTask and op.targetTask.status = Done
  all op: Operation |
    (op.kind = OpEdit and some op.targetTask and op.targetTask.status = Done) implies
    (op.outcome = Failure or op.includesReopen = BTrue)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — Reopen means new status is Todo or InProgress
pred FR_011_ReopenSetsNonDoneStatus {
  some op: Operation |
    op.kind = OpEdit and op.outcome = Success and op.includesReopen = BTrue
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success and op.includesReopen = BTrue) implies
    op.newStatus in (Todo + InProgress)
}
assert FR_011_ReopenSetsNonDoneStatus { FR_011_ReopenSetsNonDoneStatus }
check FR_011_ReopenSetsNonDoneStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012, FR-018 — Deletion is permanent and logged
pred FR_012_DeletionPermanentAndLogged {
  some op: Operation | op.kind = OpDelete and op.outcome = Success
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
    (one dl: TaskDeletion |
      op.deletion = dl and
      dl.sourceTask = op.targetTask and
      dl.deletedBy = op.caller)
}
assert FR_012_DeletionPermanentAndLogged { FR_012_DeletionPermanentAndLogged }
check FR_012_DeletionPermanentAndLogged for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — lastEditor is always a Member (updated_at/editor tracking)
pred FR_017_EditorAlwaysRecorded {
  some op: Operation | op.kind = OpEdit and op.outcome = Success
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success) implies
    op.targetTask.lastEditor in Member
}
assert FR_017_EditorAlwaysRecorded { FR_017_EditorAlwaysRecorded }
check FR_017_EditorAlwaysRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — Deletion log entry carries deleter identity
pred FR_018_DeletionLogHasDeleterIdentity {
  some TaskDeletion
  all dl: TaskDeletion | dl.deletedBy in Member
}
assert FR_018_DeletionLogHasDeleterIdentity { FR_018_DeletionLogHasDeleterIdentity }
check FR_018_DeletionLogHasDeleterIdentity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — No two successful delete ops share the same log entry
pred FR_018_UniqueDeletionLogEntry {
  some op: Operation | op.kind = OpDelete and op.outcome = Success
  all disj op1, op2: Operation |
    (op1.kind = OpDelete and op1.outcome = Success and
     op2.kind = OpDelete and op2.outcome = Success) implies
    op1.deletion != op2.deletion
}
assert FR_018_UniqueDeletionLogEntry { FR_018_UniqueDeletionLogEntry }
check FR_018_UniqueDeletionLogEntry for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_DeletionNotLogged { some op: Operation | op.kind = OpDelete and op.outcome = Success and no op.deletion }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
