// === feature_model.als — Alloy model for Team Task Management (B-L1) ===
// Feature branch: 006-task-management
// Patterns applied: AuthRequiredEverywhere, AppendOnly, AuditCompleteness,
//   AttributionCorrectness, OwnershipExclusivity, ValidationBeforeMutation

// ── Status enum ───────────────────────────────────────────────────────────

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ── Caller hierarchy ──────────────────────────────────────────────────────

abstract sig Caller {}
one sig Unauthenticated extends Caller {}
// Member is a dynamic sig: every authenticated user is a workspace member (FR-003)
sig Member extends Caller {}

// ── Task identity: shared between live tasks and deletion log ─────────────
// TaskRef is an opaque identifier atom.  A task is either "live" (LiveTask
// exists pointing to the ref) or "deleted" (TaskDeletion points to the ref).
sig TaskRef {}

sig LiveTask {
  taskRef   : one  TaskRef,
  creator   : one  Member,
  assignee  : lone Member,
  status    : one  TaskStatus,
  lastEditor: lone Member        // set on every successful edit (FR-017)
}

// Operational deletion log (FR-018).  Append-only; no API read path.
sig TaskDeletion {
  loggedRef : one TaskRef,
  deleter   : one Member
}

// ── Operation model ───────────────────────────────────────────────────────

abstract sig OperationKind {}
one sig OpCreateTask, OpListTasks, OpGetTask, OpUpdateTask, OpDeleteTask
    extends OperationKind {}

sig Operation {
  kind  : one OperationKind,
  caller: one Caller
}

// Every delete operation is paired with a TaskDeletion log entry (FR-018).
sig DeleteOperation extends Operation {
  deletedRef: one  TaskRef,
  auditEntry: one  TaskDeletion
}

// Edit operations model PATCH /tasks/{id} (FR-011 closed-task rule).
sig EditOp {
  actor            : one  Member,
  targetTask       : one  LiveTask,
  // lone means "includes a status change"; empty = no status change in this request
  newStatus        : lone TaskStatus
}

// ── Permission matrix ─────────────────────────────────────────────────────

// Flat peer model (FR-004): every authenticated Member may perform every
// OperationKind.  We still materialise the matrix so LeastPrivilege and
// PermissionCompleteness predicates have something concrete to assert.
one sig PermMatrix {
  Allowed: set Member -> OperationKind
}

// ── Non-empty universe fact ───────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Member
  some TaskRef
  some LiveTask
  some TaskDeletion
  some Operation
  some EditOp
}

// ── Named structural facts ────────────────────────────────────────────────

// Flat-peer permission matrix: every Member × every OperationKind is allowed.
fact F_PermissionMatrix {
  PermMatrix.Allowed = Member -> OperationKind
}

// Authentication boundary: every Operation must have an authenticated Member
// as its caller; unauthenticated callers are rejected before any handler runs.
fact F_AuthBoundary {
  all op: Operation | op.caller in Member
}

// Every DeleteOperation kind must be OpDeleteTask.
fact F_DeleteOpKind {
  all dop: DeleteOperation | dop.kind = OpDeleteTask
}

// The deletion log entry paired with a DeleteOperation records the same task
// ref and the same deleter (AttributionCorrectness for deletions).
fact F_DeleteOpAttribution {
  all dop: DeleteOperation |
    dop.auditEntry.loggedRef  = dop.deletedRef and
    dop.auditEntry.deleter    = dop.caller
}

// Each TaskRef appears at most once in TaskDeletion (append-only: a task can
// only be "deleted" once; log rows are never updated or duplicated).
fact F_AppendOnlyDeletionLog {
  all disj d1, d2: TaskDeletion | d1.loggedRef != d2.loggedRef
}

// Live tasks and deleted tasks have disjoint TaskRefs: permanent deletion
// means the live-task row is removed when the log entry is written.
fact F_PermanentDeletion {
  no t: LiveTask | t.taskRef in TaskDeletion.loggedRef
}

// Each LiveTask occupies a unique TaskRef (no duplicate live tasks).
fact F_UniqueTaskRefs {
  all disj t1, t2: LiveTask | t1.taskRef != t2.taskRef
}

// Assignee, when present, must be a Member of the workspace (FR-008).
fact F_AssigneeIsMember {
  all t: LiveTask | t.assignee in Member
}

// Creator must be a Member; this field is set at creation and never changes
// (in a single-state snapshot the invariant is: creator is always a Member).
fact F_CreatorIsMember {
  all t: LiveTask | t.creator in Member
}

// lastEditor, when set, must be a Member.
fact F_EditorIsMember {
  all t: LiveTask | t.lastEditor in Member
}

// Deletion log deleter must be a Member.
fact F_DeletionDeleterIsMember {
  all d: TaskDeletion | d.deleter in Member
}

// EditOp actor is a Member (all members may edit, FR-004).
fact F_EditOpActorIsMember {
  all e: EditOp | e.actor in Member
}

// Closed-task edit rule (FR-011): an edit targeting a task with status Done
// MUST include a newStatus change AND that newStatus must not be Done itself.
fact F_ClosedTaskEditRule { /* MUTATED — body cleared by validator */ }

// If an EditOp supplies a newStatus, it must be a valid TaskStatus value
// (vacuously true given the type, but makes the constraint explicit).
fact F_ValidNewStatus {
  all e: EditOp | some e.newStatus implies e.newStatus in TaskStatus
}

// AuditCompleteness for deletions: every TaskDeletion is paired with at
// least one DeleteOperation that records the same ref.
fact F_AuditCompleteness {
  all d: TaskDeletion | some dop: DeleteOperation | dop.auditEntry = d
}

// Validation-before-mutation: if an EditOp targets a Done task and has no
// newStatus (i.e., it is an invalid request), then it should never appear
// in the model at all.  The F_ClosedTaskEditRule fact enforces this; this
// fact makes the positive side explicit: every stored EditOp on a Done task
// carries a non-Done newStatus.
fact F_ValidationBeforeMutation {
  all e: EditOp |
    e.targetTask.status = Done implies
      (e.newStatus = Todo or e.newStatus = InProgress)
}

// ── Catalogue-pattern predicates ──────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.caller in Member
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE … task_deletions"
pred AppendOnly {
  some TaskDeletion
  all disj d1, d2: TaskDeletion | d1.loggedRef != d2.loggedRef
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions
pred AuditCompleteness {
  some TaskDeletion
  all d: TaskDeletion | (some dop: DeleteOperation | dop.auditEntry = d)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md deleted_by_user_id
pred AttributionCorrectness {
  some DeleteOperation
  all dop: DeleteOperation |
    dop.auditEntry.deleter = dop.caller and
    dop.auditEntry.loggedRef = dop.deletedRef
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md assignee_id lone FK
pred OwnershipExclusivity {
  some LiveTask
  all t: LiveTask | lone t.assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-011 closed-task rule; contracts/http-api.md 409 task_closed
pred ValidationBeforeMutation {
  some EditOp
  // Every edit stored in the model is valid: done-task edits always reopen the task
  all e: EditOp |
    e.targetTask.status = Done implies
      (e.newStatus = Todo or e.newStatus = InProgress)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ── Feature-specific predicates ───────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-003; FR-004 flat peer model / single workspace
pred FR_003_004_FlatPeerAccess {
  some Member
  some Operation
  // Every Member may perform every OperationKind (closed-world: exactly that set)
  PermMatrix.Allowed = Member -> OperationKind
}
assert FR_003_004_FlatPeerAccess { FR_003_004_FlatPeerAccess }
check FR_003_004_FlatPeerAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md Edge Cases "unauthenticated request"
pred FR_001_AuthRequired {
  some Operation
  no op: Operation | op.caller = Unauthenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md assignee_id FK→users.id
pred FR_008_AssigneeIsMember {
  some LiveTask
  all t: LiveTask | t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md created_by NOT NULL FK
pred FR_009_CreatorIsAlwaysMember {
  some LiveTask
  all t: LiveTask | t.creator in Member
}
assert FR_009_CreatorIsAlwaysMember { FR_009_CreatorIsAlwaysMember }
check FR_009_CreatorIsAlwaysMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010; data-model.md TaskStatus enum + CHECK constraint
pred FR_010_ValidStatus {
  some LiveTask
  all t: LiveTask | t.status in TaskStatus
}
assert FR_010_ValidStatus { FR_010_ValidStatus }
check FR_010_ValidStatus for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md 409 task_closed; spec.md US2 #5
pred FR_011_ClosedTaskEditRule {
  some EditOp
  all e: EditOp |
    e.targetTask.status = Done implies
      (e.newStatus = Todo or e.newStatus = InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md "hard delete + INSERT task_deletions"
pred FR_012_PermanentDeletion {
  // A TaskRef that appears in the deletion log must NOT also appear in a LiveTask
  some TaskDeletion
  no t: LiveTask | t.taskRef in TaskDeletion.loggedRef
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md created_at/updated_at semantics
pred FR_017_EditorIsMember {
  some LiveTask
  all t: LiveTask | t.lastEditor in Member
}
assert FR_017_EditorIsMember { FR_017_EditorIsMember }
check FR_017_EditorIsMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md task_deletions NOT NULL fields
pred FR_018_DeletionLogComplete {
  some TaskDeletion
  all d: TaskDeletion |
    (some d.loggedRef) and
    (d.deleter in Member)
}
assert FR_018_DeletionLogComplete { FR_018_DeletionLogComplete }
check FR_018_DeletionLogComplete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002; spec.md FR-002 identity from auth context
// The actor on any EditOp must be a valid Member (identity from auth, not payload).
pred FR_002_AuthContextIdentity {
  some EditOp
  all e: EditOp | e.actor in Member
}
assert FR_002_AuthContextIdentity { FR_002_AuthContextIdentity }
check FR_002_AuthContextIdentity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004; contracts/http-api.md "no 403 permission_denied"
// No permission denial: every member is allowed to perform every operation kind.
pred FR_004_NoPermissionDenial {
  some Member
  all m: Member, ok: OperationKind | m -> ok in PermMatrix.Allowed
}
assert FR_004_NoPermissionDenial { FR_004_NoPermissionDenial }
check FR_004_NoPermissionDenial for 6

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-003; data-model.md "no Team entity"
// Single-workspace invariant: every LiveTask's creator is a Member
// (there is no workspace gating — all Member atoms are workspace members).
pred FR_003_SingleWorkspace {
  some LiveTask
  all t: LiveTask | t.creator in Member
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ClosedTaskViolation { some e: EditOp | e.targetTask.status = Done and no e.newStatus }
