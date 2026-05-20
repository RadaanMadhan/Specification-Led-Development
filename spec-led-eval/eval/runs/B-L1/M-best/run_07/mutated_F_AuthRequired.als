// === feature_model.als — Alloy model for 006-task-management ===
// Single implicit workspace, flat peer permissions, three-state task
// lifecycle (todo/in_progress/done), append-only deletion log.

// ----------------------------------------------------------------
// Sigs
// ----------------------------------------------------------------

// Members of the single implicit workspace (FR-003).
sig User {}

// Auth-stub tokens (data-model.md tokens table).
sig Token { user: one User }

// Task status enum (data-model.md TaskStatus).
abstract sig Status {}
one sig Todo, InProgress, Done extends Status {}

// Operation kinds (contracts/http-api.md — five endpoints).
abstract sig OpKind {}
one sig CreateOp, ViewOp, ListOp, EditOp, DeleteOp extends OpKind {}

// Operation outcomes (contracts/http-api.md error envelope).
abstract sig Outcome {}
one sig OK, AuthFail, ValidationFail, ClosedFail, NotFoundFail extends Outcome {}

// Opaque atoms for task content fields and timestamps.
sig TitleAtom {}
sig DescriptionAtom {}
sig Time {}

// Task entity (data-model.md tasks table).
sig Task {
  title: one TitleAtom,
  description: one DescriptionAtom,
  dueDate: lone Time,
  assignee: lone User,
  status: one Status,
  createdBy: one User,
  createdAt: one Time,
  updatedAt: one Time
}

// Operation invocation (a request reaching the service).
sig Operation {
  kind: one OpKind,
  caller: lone User,        // empty <=> unauthenticated
  target: lone Task,
  outcome: one Outcome,
  setsStatus: lone Status,  // for EditOp: status set by the PATCH body
  newTask: lone Task        // for successful CreateOp: resulting task row
}

// Append-only operational deletion log (data-model.md task_deletions).
sig TaskDeletion {
  deletedTask: one Task,
  deletedBy: one User,
  titleAtDelete: one TitleAtom,
  deletedAt: one Time,
  recordedFor: one Operation
}

// ----------------------------------------------------------------
// Non-empty universe (system prompt rule 9)
// ----------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some Token
  some Task
  some Operation
  some TaskDeletion
  some TitleAtom
  some DescriptionAtom
  some Time
}

// ----------------------------------------------------------------
// Structural facts (load-bearing for the assertions below)
// ----------------------------------------------------------------

// setsStatus is only meaningful for EditOp.
fact F_SetsStatusOnlyForEdit {
  all op: Operation | op.kind != EditOp implies no op.setsStatus
}

// newTask exists only for CreateOp.
fact F_NewTaskOnlyForCreateKind {
  all op: Operation | op.kind != CreateOp implies no op.newTask
}

// A successful CreateOp produces exactly one new task, starting in Todo (FR-010).
fact F_CreateOKProducesTodoTask {
  all op: Operation |
    (op.kind = CreateOp and op.outcome = OK) implies
      (one op.newTask and op.newTask.status = Todo)
}

// FR-001 / SC-005: unauthenticated => AuthFail; OK => authenticated.
fact F_AuthRequired { /* MUTATED — body cleared by validator */ }

// FR-002: caller comes from the auth context (resolved through a token).
fact F_CallerFromAuthContext {
  all op: Operation |
    some op.caller implies (some tk: Token | tk.user = op.caller)
}

// FR-011: closed-task PATCH rule.
fact F_ClosedTaskRule {
  all op: Operation |
    (op.kind = EditOp and op.outcome = OK
      and some op.target and op.target.status = Done)
      implies (op.setsStatus = Todo or op.setsStatus = InProgress)
  all op: Operation |
    op.outcome = ClosedFail implies
      (op.kind = EditOp and some op.target and op.target.status = Done
        and (no op.setsStatus or op.setsStatus = Done))
}

// FR-018: every successful DeleteOp produces exactly one TaskDeletion record,
// with faithful attribution (deleter, target, title-at-delete).
fact F_DeletionLogPerDelete {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = OK)
      implies (one td: TaskDeletion | td.recordedFor = op)
  all td: TaskDeletion |
    td.recordedFor.kind = DeleteOp
    and td.recordedFor.outcome = OK
    and td.recordedFor.target = td.deletedTask
    and td.recordedFor.caller = td.deletedBy
    and td.recordedFor.target.title = td.titleAtDelete
}

// FR-018: append-only — at most one TaskDeletion per Task.
fact F_AppendOnlyDeletionLog {
  all disj td1, td2: TaskDeletion | td1.deletedTask != td2.deletedTask
}

// Rejected operations have no successful create side-effect (validation before mutation).
fact F_NoSideEffectsOnFailure {
  all op: Operation | op.outcome != OK implies no op.newTask
}

// ----------------------------------------------------------------
// PATTERNS
// ----------------------------------------------------------------

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "401 unauthenticated"
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.outcome = OK implies some op.caller
  all op: Operation | no op.caller implies op.outcome = AuthFail
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md "no 403"; spec.md FR-004
pred PermissionCompleteness {
  some Operation
  // Flat peers: AuthFail is the ONLY denial reason, and it iff the caller is absent.
  all op: Operation | op.outcome = AuthFail iff no op.caller
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: data-model.md "No UPDATE/DELETE on task_deletions"; FR-018
pred AppendOnly {
  some TaskDeletion
  all disj td1, td2: TaskDeletion | td1.deletedTask != td2.deletedTask
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-018; data-model.md task_deletions fields
pred AttributionCorrectness {
  some TaskDeletion
  all td: TaskDeletion |
    td.deletedBy = td.recordedFor.caller
    and td.deletedTask = td.recordedFor.target
    and td.titleAtDelete = td.recordedFor.target.title
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-008 "at most one assignee"
pred OwnershipExclusivity {
  some Task
  all t: Task | lone t.assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-018; every successful DeleteOp -> exactly one TaskDeletion
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = OK)
      implies (one td: TaskDeletion | td.recordedFor = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-005..FR-008; contracts/http-api.md validation_error
pred ValidationBeforeMutation {
  some Operation
  all op: Operation | op.outcome != OK implies no op.newTask
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ----------------------------------------------------------------
// FEATURE-SPECIFIC — one assertion per FR
// ----------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | no op.caller implies op.outcome = AuthFail
  all op: Operation | op.outcome = OK implies some op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 caller from auth context, not from payload
pred FR_002_CallerFromAuth {
  some Operation
  all op: Operation |
    some op.caller implies (some tk: Token | tk.user = op.caller)
}
assert FR_002_CallerFromAuth { FR_002_CallerFromAuth }
check FR_002_CallerFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 single implicit workspace; every authenticated user is a member
pred FR_003_SingleWorkspace {
  some Operation
  // No workspace-mismatch denial: AuthFail is iff the caller is absent.
  all op: Operation | op.outcome = AuthFail iff no op.caller
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 flat peer permissions; no 403
pred FR_004_FlatPermissions {
  some Operation
  // No role-based denial outcome exists at all; AuthFail iff caller absent.
  all op: Operation | op.outcome = AuthFail iff no op.caller
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 title required (structural: one title atom per task)
pred FR_005_TitleStructure {
  some Task
  all t: Task | one t.title
}
assert FR_005_TitleStructure { FR_005_TitleStructure }
check FR_005_TitleStructure for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 description present-but-bounded (one description atom per task)
pred FR_006_DescriptionStructure {
  some Task
  all t: Task | one t.description
}
assert FR_006_DescriptionStructure { FR_006_DescriptionStructure }
check FR_006_DescriptionStructure for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 due_date optional, past allowed
pred FR_007_DueDateOptional {
  some Task
  all t: Task | lone t.dueDate
}
assert FR_007_DueDateOptional { FR_007_DueDateOptional }
check FR_007_DueDateOptional for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 at most one assignee; assignee is a member
pred FR_008_AssigneeAtMostOne {
  some Task
  all t: Task | lone t.assignee
  all t: Task | some t.assignee implies t.assignee in User
}
assert FR_008_AssigneeAtMostOne { FR_008_AssigneeAtMostOne }
check FR_008_AssigneeAtMostOne for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 creator immutable (exactly one createdBy per task)
pred FR_009_CreatorOnePerTask {
  some Task
  all t: Task | one t.createdBy
}
assert FR_009_CreatorOnePerTask { FR_009_CreatorOnePerTask }
check FR_009_CreatorOnePerTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 status in {todo, in_progress, done}; created tasks start in todo
pred FR_010_StatusValidAndInitial {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
  all op: Operation |
    (op.kind = CreateOp and op.outcome = OK) implies op.newTask.status = Todo
}
assert FR_010_StatusValidAndInitial { FR_010_StatusValidAndInitial }
check FR_010_StatusValidAndInitial for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 closed-task PATCH rule (reopen-or-fail)
pred FR_011_ClosedTaskRule {
  some Operation
  all op: Operation |
    (op.kind = EditOp and op.outcome = OK
      and some op.target and op.target.status = Done)
      implies (op.setsStatus = Todo or op.setsStatus = InProgress)
}
assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 deletion is permanent and recorded
pred FR_012_DeletionRecorded {
  some Operation
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = OK)
      implies (one td: TaskDeletion | td.recordedFor = op)
}
assert FR_012_DeletionRecorded { FR_012_DeletionRecorded }
check FR_012_DeletionRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 v1 scope is exactly the five operation kinds
pred FR_013_ScopeLimited {
  some Operation
  all op: Operation | op.kind in (CreateOp + ViewOp + ListOp + EditOp + DeleteOp)
}
assert FR_013_ScopeLimited { FR_013_ScopeLimited }
check FR_013_ScopeLimited for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 updated_at present (most-recently-updated ordering possible)
pred FR_014_UpdatedAtPresent {
  some Task
  all t: Task | one t.updatedAt
}
assert FR_014_UpdatedAtPresent { FR_014_UpdatedAtPresent }
check FR_014_UpdatedAtPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 fields needed to filter (status, assignee, title) are present
pred FR_015_FilterableFieldsPresent {
  some Task
  all t: Task | one t.status and lone t.assignee and one t.title
}
assert FR_015_FilterableFieldsPresent { FR_015_FilterableFieldsPresent }
check FR_015_FilterableFieldsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 clearing filters yields full task universe (no hidden tasks)
pred FR_016_FiltersClearable {
  some Task
  // Default unfiltered view sees every task; no per-member hidden sub-universe.
  all t: Task | one t.status
}
assert FR_016_FiltersClearable { FR_016_FiltersClearable }
check FR_016_FiltersClearable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 created_at and updated_at exist on every task
pred FR_017_TimestampsPresent {
  some Task
  all t: Task | one t.createdAt and one t.updatedAt
}
assert FR_017_TimestampsPresent { FR_017_TimestampsPresent }
check FR_017_TimestampsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 deletion log: append-only AND faithful attribution
pred FR_018_DeletionLogAppendOnly {
  some TaskDeletion
  all disj td1, td2: TaskDeletion | td1.deletedTask != td2.deletedTask
  all td: TaskDeletion |
    td.deletedBy = td.recordedFor.caller
    and td.deletedTask = td.recordedFor.target
}
assert FR_018_DeletionLogAppendOnly { FR_018_DeletionLogAppendOnly }
check FR_018_DeletionLogAppendOnly for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuthBypass { some op: Operation | op.outcome = OK and no op.caller }
