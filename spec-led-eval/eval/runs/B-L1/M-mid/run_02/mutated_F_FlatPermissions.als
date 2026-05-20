// === feature_model.als — Alloy model for Team Task Management (B-L1) ===
// Feature folder : B-L1  (spec branch 006-task-management)
// Sources        : spec.md, data-model.md, contracts/http-api.md
// Patterns used  : AuthRequiredEverywhere, AppendOnly, AuditCompleteness,
//                  AttributionCorrectness, OwnershipExclusivity,
//                  PermissionCompleteness, ValidationBeforeMutation
// Feature-specific predicates cover FR-002, FR-003, FR-004, FR-009,
//                  FR-010, FR-011, FR-012, FR-017, FR-018

// ─── Status / Outcome / OperationKind taxonomy ───────────────────────────────

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// All HTTP outcomes that callers can observe; PermDenied = 403 (flat model
// says this should never appear for authenticated callers).
abstract sig Outcome {}
one sig Succeeded, OutcomeUnauth, OutcomePermDenied,
        OutcomeValidation, OutcomeNotFound, OutcomeTaskClosed extends Outcome {}

abstract sig OperationKind {}
one sig OpCreate, OpViewOne, OpList, OpEdit, OpDelete extends OperationKind {}

// ─── Domain sigs ─────────────────────────────────────────────────────────────

sig Member {}

sig Token {
  tok_member: one Member
}

sig Timestamp {}

sig Task {
  task_creator:    one Member,
  task_assignee:   lone Member,
  task_status:     one TaskStatus,
  task_created_at: one Timestamp,
  task_updated_at: one Timestamp
}

// Append-only operational log for deletions (FR-018, data-model.md §TaskDeletion)
sig TaskDeletion {
  tdel_task:    one Task,    // structural reference to the deleted task
  tdel_deleter: one Member
}

// Generic API operation
sig Operation {
  op_caller:  lone Member,   // empty set = unauthenticated request
  op_kind:    one OperationKind,
  op_target:  lone Task,
  op_outcome: one Outcome
}

// PATCH /tasks/{id} carries extra edit-specific state (FR-011)
sig EditOperation extends Operation {
  edit_prior_status: one TaskStatus,   // task's status at time of request
  edit_new_status:   lone TaskStatus   // status field supplied in body; lone = absent
}

// ─── Non-empty universe ───────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Member
  some Task
  some Token
  some Operation
  some EditOperation
  some TaskDeletion
  some Timestamp
}

// ─── Structural facts — one named fact per invariant ─────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
fact F_AuthRequired {
  // Every operation that unauthenticated callers reach must yield Unauthenticated.
  // Equivalently: a Succeeded outcome implies a non-empty (authenticated) caller.
  all op: Operation |
    (no op.op_caller) implies (op.op_outcome = OutcomeUnauth)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
// Identity MUST come from the token resolution, not the payload.
// Modeled: every token's resolved member is a Member atom (the auth context is
// the sole source of caller identity — no second source exists in the model).
fact F_IdentityFromAuthContext {
  all tok: Token | tok.tok_member in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
// Single implicit workspace: every Member is a peer in the one global workspace.
// Modeled: every Task's creator and every assignee are drawn from the global
// Member universe — no workspace discriminator field exists on Task.
fact F_SingleWorkspace {
  all t: Task | t.task_creator in Member
  all t: Task | t.task_assignee in Member
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §Authentication; spec.md FR-004
// Flat peer model: no 403 PermDenied is ever returned to an authenticated caller.
// Every authenticated operation's outcome is drawn from {Succeeded, OutcomeValidation,
// OutcomeNotFound, OutcomeTaskClosed} — never OutcomePermDenied.
fact F_FlatPermissions { /* MUTATED — body cleared by validator */ }

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md §Task.assignee_id
// At most one assignee per task; assignee must be a current Member.
fact F_AssigneeMustBeMember {
  all t: Task | lone t.task_assignee
  all t: Task | t.task_assignee in Member   // every Member is a workspace member (FR-003)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md §Task.created_by / created_at
// Creator is always set (never absent) and is a Member.
// (created_at immutability is reflected by the `one Timestamp` cardinality —
// there is exactly one created_at value per Task, with no mechanism to clear it.)
fact F_CreatorAlwaysSet {
  all t: Task | one t.task_creator
  all t: Task | one t.task_created_at
}

// FEATURE-SPECIFIC  ANCHOR: FR-010; data-model.md §TaskStatus
// Status is always one of the three legal values.
fact F_StatusIsValid {
  all t: Task | t.task_status in (Todo + InProgress + Done)
}

// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md §Task.updated_at
// Both timestamps are always present on every Task.
fact F_TimestampsAlwaysPresent {
  all t: Task | one t.task_created_at and one t.task_updated_at
}

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md §Closed-task rule
// A PATCH on a task whose prior status is Done succeeds ONLY if the request
// simultaneously sets status to Todo or InProgress.
fact F_ClosedTaskEditRule {
  all eo: EditOperation |
    (eo.edit_prior_status = Done and eo.op_outcome = Succeeded)
    implies (eo.edit_new_status = Todo or eo.edit_new_status = InProgress)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-011; contracts/http-api.md §409 task_closed
// A PATCH on a Done task that does NOT supply a non-Done status in the body
// must yield OutcomeTaskClosed (never Succeeded).
fact F_ClosedTaskPatchRejected {
  all eo: EditOperation |
    (eo.edit_prior_status = Done
     and eo.edit_new_status != Todo
     and eo.edit_new_status != InProgress)
    implies (eo.op_outcome = OutcomeTaskClosed)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md §TaskDeletion
// Every successful delete operation produces exactly one TaskDeletion entry
// naming the target task and the caller as deleter.
fact F_DeletionLogComplete {
  all op: Operation |
    (op.op_kind = OpDelete and op.op_outcome = Succeeded and some op.op_caller and some op.op_target)
    implies (one td: TaskDeletion | td.tdel_task = op.op_target and td.tdel_deleter = op.op_caller)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md §TaskDeletion "No UPDATE/DELETE"
// Every TaskDeletion entry has exactly one deleter and one task reference —
// no field is ever absent, which would indicate a mutated / partial record.
fact F_AppendOnlyDeletionLog {
  all td: TaskDeletion | one td.tdel_task and one td.tdel_deleter
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md §TaskDeletion.deleted_by_user_id
// Every TaskDeletion is attributed to a Member (never anonymous).
fact F_DeletionAttribution {
  all td: TaskDeletion | td.tdel_deleter in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-012; contracts/http-api.md §DELETE /tasks/{id}
// Any authenticated member may delete any task regardless of task status.
// Modeled: a delete operation on any task, by any authenticated caller, is
// never rejected with OutcomePermDenied or OutcomeTaskClosed.
fact F_AnyMemberMayDeleteAnyTask {
  all op: Operation |
    (op.op_kind = OpDelete and some op.op_caller)
    implies (op.op_outcome != OutcomePermDenied and op.op_outcome != OutcomeTaskClosed)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md §Workspace scope
// Authenticated callers never receive OutcomePermDenied on any operation.
// (Redundant with F_FlatPermissions; kept separate so each assertion can be
// independently mutation-tested.)
fact F_NoPermissionDeniedResponse {
  all op: Operation | op.op_outcome != OutcomePermDenied or no op.op_caller
}

// ─── Predicates and Assertions ───────────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  some op: Operation | op.op_outcome = Succeeded  // at least one interesting operation
  all op: Operation |
    op.op_outcome = Succeeded implies (some op.op_caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: PermissionCompleteness  ANCHOR: spec.md FR-004; contracts/http-api.md §Authentication
pred PermissionCompleteness {
  some op: Operation | some op.op_caller  // at least one authenticated operation
  all op: Operation |
    (some op.op_caller) implies (op.op_outcome != OutcomePermDenied)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md §TaskDeletion
pred AppendOnly {
  some TaskDeletion
  // Every deletion log entry has exactly one task and one deleter — no partial / cleared records
  all td: TaskDeletion | one td.tdel_task and one td.tdel_deleter
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md §TaskDeletion UNIQUE constraint
pred AuditCompleteness {
  some op: Operation | op.op_kind = OpDelete and op.op_outcome = Succeeded and some op.op_caller and some op.op_target
  all op: Operation |
    (op.op_kind = OpDelete and op.op_outcome = Succeeded and some op.op_caller and some op.op_target)
    implies (one td: TaskDeletion | td.tdel_task = op.op_target and td.tdel_deleter = op.op_caller)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md §TaskDeletion.deleted_by_user_id
pred AttributionCorrectness {
  some TaskDeletion
  all td: TaskDeletion | td.tdel_deleter in Member
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md §Task.assignee_id
pred OwnershipExclusivity {
  some Task
  all t: Task | lone t.task_assignee
  all t: Task | t.task_assignee in Member
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-011; contracts/http-api.md §409
pred ValidationBeforeMutation {
  some eo: EditOperation | eo.edit_prior_status = Done
  all eo: EditOperation |
    (eo.edit_prior_status = Done
     and eo.edit_new_status != Todo
     and eo.edit_new_status != InProgress)
    implies (eo.op_outcome != Succeeded)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md §Edge Cases (unauthenticated request)
pred FR_001_AuthRequired {
  some op: Operation | no op.op_caller
  all op: Operation | (no op.op_caller) implies (op.op_outcome = OutcomeUnauth)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; spec.md §Authentication and identity
pred FR_002_IdentityFromAuthContext {
  some Token
  all tok: Token | tok.tok_member in Member
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003; spec.md §Workspace scope
pred FR_003_SingleWorkspace {
  some Task
  // Every Task's creator and assignee belong to the single global Member set
  all t: Task | t.task_creator in Member
  all t: Task | t.task_assignee in Member
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md §Workspace scope and permissions
pred FR_004_FlatPermissions {
  some op: Operation | some op.op_caller
  all op: Operation | (some op.op_caller) implies (op.op_outcome != OutcomePermDenied)
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md §Task.assignee_id FK→users.id
pred FR_008_AssigneeMustBeMember {
  some t: Task | some t.task_assignee
  all t: Task | t.task_assignee in Member
  all t: Task | lone t.task_assignee
}
assert FR_008_AssigneeMustBeMember { FR_008_AssigneeMustBeMember }
check FR_008_AssigneeMustBeMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md §Task.created_by / created_at
pred FR_009_CreatorAndTimestampFixed {
  some Task
  all t: Task | one t.task_creator
  all t: Task | one t.task_created_at
  all t: Task | t.task_creator in Member
}
assert FR_009_CreatorAndTimestampFixed { FR_009_CreatorAndTimestampFixed }
check FR_009_CreatorAndTimestampFixed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; data-model.md §TaskStatus; spec.md §Task management
pred FR_010_StatusIsValid {
  some Task
  all t: Task | t.task_status in (Todo + InProgress + Done)
}
assert FR_010_StatusIsValid { FR_010_StatusIsValid }
check FR_010_StatusIsValid for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md §Closed-task rule
pred FR_011_ClosedTaskEditRule {
  // There exists an edit on a Done task that succeeds → it must have changed status away from Done
  some eo: EditOperation | eo.edit_prior_status = Done
  all eo: EditOperation |
    (eo.edit_prior_status = Done and eo.op_outcome = Succeeded)
    implies (eo.edit_new_status = Todo or eo.edit_new_status = InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; contracts/http-api.md §DELETE /tasks/{id}
pred FR_012_AnyMemberMayDelete {
  some op: Operation | op.op_kind = OpDelete and some op.op_caller
  all op: Operation |
    (op.op_kind = OpDelete and some op.op_caller)
    implies (op.op_outcome != OutcomePermDenied and op.op_outcome != OutcomeTaskClosed)
}
assert FR_012_AnyMemberMayDelete { FR_012_AnyMemberMayDelete }
check FR_012_AnyMemberMayDelete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md §Task.created_at / updated_at
pred FR_017_TimestampsAlwaysPresent {
  some Task
  all t: Task | one t.task_created_at and one t.task_updated_at
}
assert FR_017_TimestampsAlwaysPresent { FR_017_TimestampsAlwaysPresent }
check FR_017_TimestampsAlwaysPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md §TaskDeletion; spec.md §US4
pred FR_018_DeletionLogged {
  some op: Operation | op.op_kind = OpDelete and op.op_outcome = Succeeded and some op.op_caller and some op.op_target
  all op: Operation |
    (op.op_kind = OpDelete and op.op_outcome = Succeeded and some op.op_caller and some op.op_target)
    implies (one td: TaskDeletion | td.tdel_task = op.op_target and td.tdel_deleter = op.op_caller)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_FlatPermissionsViolation { some op: Operation | some op.op_caller and op.op_outcome = OutcomePermDenied }
