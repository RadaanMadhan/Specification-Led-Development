// === feature_model.als — Alloy model for Team Task Management (B-L1 / 006-task-management) ===
// Source artefacts: spec.md, data-model.md, contracts/http-api.md

// ── Task status enumeration ──────────────────────────────────────────────────
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ── Operation kinds ──────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig OpCreate, OpGetTask, OpListTasks, OpEdit, OpDelete extends OperationKind {}

// ── Core entities ────────────────────────────────────────────────────────────
// Every row in `users` is a member of the single implicit workspace (FR-003).
sig Member {}

// A Task in the active workspace.
sig Task {
  status:  one TaskStatus,
  creator: one Member,
  assignee: lone Member    // at most one assignee; None = unassigned (FR-008)
}

// An abstract Operation: carries an authenticated caller and an OperationKind.
// All callers are Members; the `one Member` type enforces authentication (FR-001).
sig Operation {
  caller: one Member,
  kind:   one OperationKind
}

// An EditOperation specialises an Operation to carry the targeted Task and
// an optional simultaneous status change (FR-011 closed-task rule).
sig EditOperation {
  caller:    one Member,
  target:    one Task,
  newStatus: lone TaskStatus   // lone = absent means status not changed in this request
}

// A DeleteOperation carries the target Task and a mandatory log entry (FR-018).
sig DeleteOperation {
  caller:    one Member,
  target:    one Task,
  logEntry:  one TaskDeletion  // deletion is atomically logged
}

// Operational log entry for each task deletion (append-only, FR-018).
sig TaskDeletion {
  deletedBy: one Member,
  taskRef:   one TaskRef       // opaque id+title snapshot of the deleted task
}

// Opaque reference capturing a task's id and title at the moment of deletion.
sig TaskRef {}

// ── Permission matrix (flat: every authenticated Member can do every OperationKind) ──
// FR-003, FR-004: no admin tier, no role hierarchy.
one sig PermMatrix {
  Allowed: set Member -> OperationKind
}

// ── Non-empty universe ───────────────────────────────────────────────────────
// Ensures `check` commands exercise all dynamic sigs, not an empty universe.
fact F_NonEmptyUniverse {
  some Member
  some Task
  some Operation
  some EditOperation
  some DeleteOperation
  some TaskDeletion
  some TaskRef
}

// ── Named structural facts ────────────────────────────────────────────────────

// FR-004: flat peer model — the allowed set is the full cartesian product.
fact F_FlatPermissions {
  PermMatrix.Allowed = Member -> OperationKind
}

// FR-001: every operation carries an authenticated caller.
// `one Member` field type already enforces this; the fact makes it mutation-testable.
fact F_AuthRequiredOnEveryOperation {
  all op: Operation    | some op.caller
  all eo: EditOperation | some eo.caller
  all do: DeleteOperation | some do.caller
}

// FR-008: a task's assignee, when present, must be an existing workspace member.
fact F_AssigneeIsMember {
  all t: Task | t.assignee in Member
}

// FR-009: every task has a creator recorded at creation time; creator never null.
fact F_CreatorRecorded { /* MUTATED — body cleared by validator */ }

// FR-011 closed-task edit rule: an EditOperation targeting a Done task MUST
// simultaneously move the task to Todo or InProgress.
fact F_ClosedTaskEditRule {
  all eo: EditOperation |
    eo.target.status = Done implies
      (eo.newStatus = Todo or eo.newStatus = InProgress)
}

// FR-012 + FR-018: every DeleteOperation atomically produces exactly one
// TaskDeletion log entry attributed to the same caller.
fact F_DeletionAlwaysLogged {
  all do: DeleteOperation | do.logEntry.deletedBy = do.caller
}

// FR-018 append-only: every TaskDeletion is the log entry of exactly one
// DeleteOperation; no entry exists unanchored and no entry is shared.
fact F_AppendOnlyDeletionLog {
  all td: TaskDeletion | (one do: DeleteOperation | do.logEntry = td)
}

// FR-003: single workspace — all members see all tasks.
// Encoded by asserting GetTask/ListTasks are in every member's allowed set.
fact F_SingleWorkspaceVisibility {
  all m: Member | m -> OpGetTask   in PermMatrix.Allowed
  all m: Member | m -> OpListTasks in PermMatrix.Allowed
}

// FR-010: task status is always one of the three defined values.
// Guaranteed by the abstract sig hierarchy (Todo, InProgress, Done) — structural.
// Additional fact makes it mutation-testable.
fact F_ValidStatusSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}

// ── Predicates and assertions ─────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission section; spec.md FR-004
// In this feature the "least-privilege" reduces to flat equality: every member
// has exactly the same (full) set of permissions — no member is over- or under-privileged.
pred LeastPrivilege {
  some Member
  all disj m1, m2: Member |
    { ok: OperationKind | m1 -> ok in PermMatrix.Allowed } =
    { ok: OperationKind | m2 -> ok in PermMatrix.Allowed }
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md; spec.md FR-003, FR-004
// Every (Member × OperationKind) cell has a defined verdict (here: all allowed).
pred PermissionCompleteness {
  some Member
  some OperationKind
  all m: Member, ok: OperationKind | m -> ok in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "401 unauthenticated"
// No Operation, EditOperation, or DeleteOperation exists without a Member caller.
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation    | op.caller in Member
  all eo: EditOperation | eo.caller in Member
  all do: DeleteOperation | do.caller in Member
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE … task_deletions"
// Every TaskDeletion is the log entry of exactly one DeleteOperation;
// no TaskDeletion is created, mutated, or shared outside a DeleteOperation.
pred AppendOnly {
  some TaskDeletion
  all td: TaskDeletion | (one do: DeleteOperation | do.logEntry = td)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions INSERT
// Every DeleteOperation produces exactly one TaskDeletion; no delete is silent.
pred AuditCompleteness {
  some DeleteOperation
  all do: DeleteOperation | one do.logEntry
  all do: DeleteOperation | do.logEntry in TaskDeletion
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md deleted_by_user_id
// The TaskDeletion log entry's `deletedBy` field matches the DeleteOperation's caller.
pred AttributionCorrectness {
  some DeleteOperation
  all do: DeleteOperation | do.logEntry.deletedBy = do.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md assignee_id (lone FK)
// Each task has at most one assignee; if present, the assignee is a Member.
pred OwnershipExclusivity {
  some Task
  all t: Task | lone t.assignee
  all t: Task | t.assignee in Member
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every operation (of any kind) is performed by an authenticated Member.
pred FR_001_AuthRequired {
  some Operation
  no op: Operation    | no op.caller
  no eo: EditOperation | no eo.caller
  no do: DeleteOperation | no do.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
// The creator field on a Task is always a Member (sourced from auth context, never absent).
pred FR_002_CreatorFromAuthContext {
  some Task
  all t: Task | t.creator in Member
}
assert FR_002_CreatorFromAuthContext { FR_002_CreatorFromAuthContext }
check FR_002_CreatorFromAuthContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
// All members share a single workspace: every Member can access GetTask and ListTasks.
pred FR_003_SingleWorkspaceAllVisible {
  some Member
  all m: Member |
    m -> OpGetTask   in PermMatrix.Allowed and
    m -> OpListTasks in PermMatrix.Allowed
}
assert FR_003_SingleWorkspaceAllVisible { FR_003_SingleWorkspaceAllVisible }
check FR_003_SingleWorkspaceAllVisible for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
// Flat peer model: every Member can perform every OperationKind; there are no denied cells.
pred FR_004_FlatPeerPermissions {
  some Member
  all m: Member | all ok: OperationKind | m -> ok in PermMatrix.Allowed
}
assert FR_004_FlatPeerPermissions { FR_004_FlatPeerPermissions }
check FR_004_FlatPeerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
// Assignee, if set, must be a current Member; at most one assignee per task.
pred FR_008_AssigneeMustBeMember {
  some Task
  all t: Task | t.assignee in Member
  all t: Task | lone t.assignee
}
assert FR_008_AssigneeMustBeMember { FR_008_AssigneeMustBeMember }
check FR_008_AssigneeMustBeMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
// Every task has a recorded creator (one Member, immutable identity).
pred FR_009_CreatorRecorded {
  some Task
  all t: Task | one t.creator
  all t: Task | t.creator in Member
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
// Every task's status is exactly one of: Todo, InProgress, Done.
pred FR_010_ValidStatusSet {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
  all t: Task | one t.status
}
assert FR_010_ValidStatusSet { FR_010_ValidStatusSet }
check FR_010_ValidStatusSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md "409 task_closed"
// Editing a task with status Done MUST include a simultaneous transition
// to Todo or InProgress. No edit of a Done task leaves it Done.
pred FR_011_ClosedTaskEditRule {
  some EditOperation
  all eo: EditOperation |
    eo.target.status = Done implies
      (eo.newStatus = Todo or eo.newStatus = InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md "Deletion is permanent"
// Any member can delete any task; deletion is permanent (task gone from active set).
// Encoded as: every DeleteOperation targets a Task and is caller-attributed.
pred FR_012_DeletionIsPermanent {
  some DeleteOperation
  all do: DeleteOperation | one do.target
  all do: DeleteOperation | one do.caller
}
assert FR_012_DeletionIsPermanent { FR_012_DeletionIsPermanent }
check FR_012_DeletionIsPermanent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md task_deletions
// Every deletion is recorded in the operational log with deleter identity.
pred FR_018_DeletionLogged {
  some DeleteOperation
  all do: DeleteOperation |
    (one td: TaskDeletion | do.logEntry = td and td.deletedBy = do.caller)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CreatorViolation { some t: Task | t.creator not in Member }
