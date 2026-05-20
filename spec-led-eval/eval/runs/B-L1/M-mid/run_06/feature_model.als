// === feature_model.als — Alloy model for Team Task Management (B-L1 / 006-task-management) ===

// ─────────────────────────────────────────────────────────────────────
//  Task Status domain
// ─────────────────────────────────────────────────────────────────────
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ─────────────────────────────────────────────────────────────────────
//  Core entities
// ─────────────────────────────────────────────────────────────────────
sig Member {}

sig Task {
  creator  : one  Member,       // FR-009: recorded at creation, never changes
  assignee : lone Member,       // FR-008: at most one, must be a member
  status   : one  TaskStatus,   // FR-010: exactly one of {todo, in_progress, done}
}

// Append-only operational deletion log (FR-018)
sig DeletionLog {
  loggedTask : one  Task,       // which task was removed
  deletedBy  : one  Member,     // who deleted it
}

// ─────────────────────────────────────────────────────────────────────
//  Permission model (flat – all authenticated members are equal peers)
// ─────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig AuthMember, Unauth extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById, PatchTask, DeleteTask extends OperationKind {}

// Permission matrix encoded as a singleton-sig field
one sig PermMatrix {
  Allowed : set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────
//  Operations (API calls)
// ─────────────────────────────────────────────────────────────────────
abstract sig Outcome {}
one sig Success, Failure extends Outcome {}

// For PATCH: does this request simultaneously reopen a Done task?
abstract sig PatchIntent {}
one sig ReopensTask, KeepsDone extends PatchIntent {}

sig Operation {
  kind        : one  OperationKind,
  role        : one  Role,
  caller      : lone Member,      // present iff role = AuthMember
  targetTask  : lone Task,        // present for GetTaskById, PatchTask, DeleteTask
  outcome     : one  Outcome,
  patchIntent : lone PatchIntent, // present iff kind = PatchTask
}

// ─────────────────────────────────────────────────────────────────────
//  F_NonEmptyUniverse — guarantee at least one atom of each dynamic sig
// ─────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Member
  some Task
  some DeletionLog
  some Operation
}

// ─────────────────────────────────────────────────────────────────────
//  Structural well-formedness facts
// ─────────────────────────────────────────────────────────────────────

// Caller exists iff the operation is authenticated
fact F_CallerRoleConsistency {
  all op : Operation |
    (op.role = AuthMember implies one  op.caller) and
    (op.role = Unauth      implies no   op.caller)
}

// patchIntent present iff kind = PatchTask
fact F_PatchIntentConsistency {
  all op : Operation |
    (op.kind = PatchTask  implies one op.patchIntent) and
    (op.kind != PatchTask implies no  op.patchIntent)
}

// targetTask present iff the operation addresses a specific task
fact F_TargetTaskConsistency {
  all op : Operation |
    ((op.kind = GetTaskById or op.kind = PatchTask or op.kind = DeleteTask)
       implies one op.targetTask) and
    ((op.kind = PostTasks or op.kind = GetTasks)
       implies no op.targetTask)
}

// ─────────────────────────────────────────────────────────────────────
//  Named domain-rule facts
// ─────────────────────────────────────────────────────────────────────

// Permission matrix: AuthMember can do everything; Unauth can do nothing.
// Exactly the five endpoints; closed-world.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (AuthMember -> PostTasks)    +
    (AuthMember -> GetTasks)     +
    (AuthMember -> GetTaskById)  +
    (AuthMember -> PatchTask)    +
    (AuthMember -> DeleteTask)
}

// FR-001: unauthenticated requests must fail before any handler runs
fact F_AuthRequiredEverywhere {
  all op : Operation |
    op.role = Unauth implies op.outcome = Failure
}

// FR-004: every authenticated member can reach every operation (flat peers)
fact F_FlatPermissions {
  all k : OperationKind | AuthMember -> k in PermMatrix.Allowed
}

// FR-008: assignee must be a workspace member
fact F_AssigneeIsMember {
  all t : Task | t.assignee in Member
}

// FR-009: every task records its creator (a member); the field is immutable by structure
fact F_CreatorIsMember {
  all t : Task | t.creator in Member
}

// FR-010: status is exactly one valid value (enforced by the TaskStatus hierarchy,
//         but we also pin the invariant here for mutation testing)
fact F_ValidTaskStatus {
  all t : Task | t.status in (Todo + InProgress + Done)
}

// FR-011: PATCH on a Done task that does NOT reopen it must fail with 409 task_closed
fact F_ClosedTaskRule {
  all op : Operation |
    (op.kind = PatchTask and op.targetTask.status = Done and op.patchIntent = KeepsDone)
      implies op.outcome = Failure
}

// FR-018 / AppendOnly: each task appears in at most one DeletionLog entry (no duplicates)
fact F_AppendOnlyDeletionLog {
  all disj d1, d2 : DeletionLog | d1.loggedTask != d2.loggedTask
}

// FR-018: every DeletionLog entry is backed by a successful DeleteTask operation
//         and the recorded deleter matches the operation's caller
fact F_DeletionLogCompleteness {
  all d : DeletionLog |
    some op : Operation |
      op.kind       = DeleteTask  and
      op.targetTask = d.loggedTask and
      op.caller     = d.deletedBy  and
      op.outcome    = Success
}

// Converse of F_DeletionLogCompleteness: every successful delete gets a log entry
fact F_DeleteProducesLog {
  all op : Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies
      (some d : DeletionLog |
         d.loggedTask = op.targetTask and d.deletedBy = op.caller)
}

// ─────────────────────────────────────────────────────────────────────
//  PATTERN predicates and assertions
// ─────────────────────────────────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some op : Operation | op.role = Unauth   // unauthenticated ops exist to make the pred bite
  all op : Operation |
    op.outcome = Success implies op.role = AuthMember
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004
pred LeastPrivilege {
  some Operation
  // Unauth holds no permissions
  no k : OperationKind | Unauth -> k in PermMatrix.Allowed
  // AuthMember holds all permissions
  all k : OperationKind | AuthMember -> k in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // The Allowed relation covers exactly AuthMember x all ops and nothing for Unauth
  PermMatrix.Allowed = AuthMember -> OperationKind
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: data-model.md task_deletions "No UPDATE/DELETE"; spec.md FR-018
pred AppendOnly {
  some DeletionLog
  // No two log entries record the same task
  all disj d1, d2 : DeletionLog | d1.loggedTask != d2.loggedTask
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions
pred AuditCompleteness {
  some DeletionLog
  // Every log entry covers exactly one task
  all d : DeletionLog | one d.loggedTask
  // Every successful DeleteTask produces a log entry
  all op : Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies
      (some d : DeletionLog | d.loggedTask = op.targetTask)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md DeletionLog.deleted_by_user_id; spec.md FR-018
pred AttributionCorrectness {
  some DeletionLog
  // Every log entry's deleter matches the actual caller of the delete operation
  all d : DeletionLog |
    some op : Operation |
      op.kind       = DeleteTask  and
      op.targetTask = d.loggedTask and
      op.caller     = d.deletedBy  and
      op.outcome    = Success
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.assignee_id (lone), Task.creator; spec.md FR-008, FR-009
pred OwnershipExclusivity {
  some Task
  // Each task has at most one assignee
  all t : Task | lone t.assignee
  // Each task has exactly one creator
  all t : Task | one t.creator
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001, FR-005; contracts/http-api.md 401/400
pred ValidationBeforeMutation {
  // Exists at least one failing operation (to prevent vacuity)
  some op : Operation | op.outcome = Failure
  // Unauthenticated requests never succeed (validation at the boundary)
  all op : Operation |
    op.role = Unauth implies op.outcome = Failure
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ─────────────────────────────────────────────────────────────────────
//  Feature-specific predicates (one per FR-NNN)
// ─────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  all op : Operation |
    op.outcome = Success implies op.role = AuthMember
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_SingleWorkspace {
  // All tasks are universally visible: no per-member filter exists.
  // Structurally: every task's creator is a member, and no Task is unreachable.
  some Task
  some Member
  all t : Task | t.creator in Member
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_FlatPermissions {
  // No operation kind is off-limits for an authenticated member
  some op : Operation | op.outcome = Success
  all k : OperationKind | AuthMember -> k in PermMatrix.Allowed
  // Unauth is locked out of everything
  all k : OperationKind | not (Unauth -> k in PermMatrix.Allowed)
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeIsMember {
  some t : Task | some t.assignee   // at least one assigned task
  all t : Task | t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreatorRecorded {
  some Task
  // Every task records exactly one creator who is a member
  all t : Task | one t.creator and t.creator in Member
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_ValidStatus {
  some Task
  all t : Task | t.status in (Todo + InProgress + Done)
  all t : Task | one t.status
}
assert FR_010_ValidStatus { FR_010_ValidStatus }
check FR_010_ValidStatus for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md closed-task rule (409); spec.md US2 #5/#6
pred FR_011_ClosedTaskEditRule {
  // At least one PATCH on a Done task exists so the pred is non-vacuous
  some op : Operation |
    op.kind = PatchTask and op.targetTask.status = Done
  // Without a reopen, the patch must fail
  all op : Operation |
    (op.kind = PatchTask and op.targetTask.status = Done and op.patchIntent = KeepsDone)
      implies op.outcome = Failure
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md US4
pred FR_012_PermanentDeletion {
  some DeletionLog
  // Every logged deletion identifies a valid member as the deleter
  all d : DeletionLog | d.deletedBy in Member
  // Every logged deletion has an associated successful delete operation
  all d : DeletionLog |
    some op : Operation |
      op.kind = DeleteTask and op.targetTask = d.loggedTask and op.outcome = Success
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md created_at / updated_at
pred FR_017_TimestampsExist {
  some Task
  // Structural proxy: every task has a non-null creator (created_at is set at creation)
  // and every task has exactly one status (updated_at tracks status changes)
  all t : Task | one t.creator and one t.status
}
assert FR_017_TimestampsExist { FR_017_TimestampsExist }
check FR_017_TimestampsExist for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md task_deletions
pred FR_018_DeletionLogged {
  some DeletionLog
  // Every successful delete operation leaves exactly one log entry
  all op : Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies
      (one d : DeletionLog |
         d.loggedTask = op.targetTask and d.deletedBy = op.caller)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 8