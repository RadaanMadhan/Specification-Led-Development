// === feature_model.als — Alloy model for B-L1 Team Task Management ===
//
// Single-workspace, flat-permission task management. Structural invariants
// modelled: authentication on every operation, flat permission matrix,
// closed-task PATCH rule, append-only deletion log, audit completeness
// and attribution correctness for deletions.

// ---- Non-empty universe (one named fact, no in-pred witness clauses) ----
fact F_NonEmptyUniverse {
  some Member
  some Token
  some Task
  some Operation
  some DeletionLogEntry
}

// ----------------------------- Core entities ------------------------------

sig Member {}

sig Token { user: one Member }

abstract sig Status {}
one sig Todo, InProgress, Done extends Status {}

sig Task {
  creator: one Member,
  assignee: lone Member,
  status:   one Status
}

// Operational log row (FR-018). Append-only; no in-app API surface.
sig DeletionLogEntry {
  taskRef: one Task,
  deleter: one Member
}

// ----------------------- Roles / operations / outcomes --------------------

abstract sig Role {}
one sig MemberRole, Anonymous extends Role {}

abstract sig OperationKind {}
one sig CreateTask, ListTasks, ViewTask, EditTask, DeleteTask extends OperationKind {}

abstract sig Outcome {}
one sig Success, Rejected extends Outcome {}

// Permission matrix as a singleton-sig field (per the prompt's canonical pattern).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// Every attempted op is an Operation atom.
sig Operation {
  kind:        one OperationKind,
  caller:      lone Member,         // absent ⇒ unauthenticated
  role:        one Role,
  outcome:     one Outcome,
  targetTask:  lone Task,           // present on View/Edit/Delete
  preStatus:   lone Status,         // present on EditTask
  newStatus:   lone Status,         // present on EditTask
  deletionLog: lone DeletionLogEntry
}

// ------------------------- Facts (named, mutable) -------------------------

// Closed-world permission matrix. Flat permissions: only MemberRole has rights.
fact F_PermissionMatrix {
  PermMatrix.Allowed = (MemberRole -> CreateTask)
                     + (MemberRole -> ListTasks)
                     + (MemberRole -> ViewTask)
                     + (MemberRole -> EditTask)
                     + (MemberRole -> DeleteTask)
}

// FR-001: every successful operation has an authenticated caller.
fact F_AuthRequired {
  all op: Operation | op.outcome = Success implies some op.caller
}

// FR-004: success only on (role, kind) cells the matrix marks allowed.
fact F_LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies (op.role -> op.kind) in PermMatrix.Allowed
}

// FR-002: caller of a successful op is resolved through the token table.
// Weak form (only when a caller exists) so it doesn't independently imply
// the FR-001 invariant — that lets F_AuthRequired stand alone as a mutation
// target without being shadowed by this fact.
fact F_CallerIsTokenResolved {
  all op: Operation |
    (op.outcome = Success and some op.caller)
      implies (some t: Token | t.user = op.caller)
}

// Well-formedness: which kinds carry a targetTask.
fact F_TargetTaskShape {
  all op: Operation |
    op.kind in (ViewTask + EditTask + DeleteTask) implies some op.targetTask
  all op: Operation |
    op.kind in (CreateTask + ListTasks) implies no op.targetTask
}

// Well-formedness: only EditTask carries preStatus / newStatus.
fact F_EditOpFields {
  all op: Operation |
    op.kind = EditTask implies (some op.preStatus and some op.newStatus)
  all op: Operation |
    op.kind != EditTask implies (no op.preStatus and no op.newStatus)
}

// Edit's preStatus reflects the target task's current status.
fact F_EditPreStatusMatchesTask {
  all op: Operation |
    op.kind = EditTask implies op.preStatus = op.targetTask.status
}

// FR-011: editing a Done task is permitted only when the same edit moves
// status out of Done.
fact F_ClosedTaskEditRule { /* MUTATED — body cleared by validator */ }

// FR-012 / FR-018: every successful delete spawns exactly one log entry;
// a log entry only arises from a successful delete.
fact F_DeletionLogCompleteness {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies (one op.deletionLog)
  all op: Operation |
    (op.kind != DeleteTask or op.outcome != Success) implies no op.deletionLog
}

// FR-018: log entry attributes record the actual caller and actual target.
fact F_DeletionLogAttribution {
  all op: Operation |
    some op.deletionLog implies
      (op.deletionLog.deleter = op.caller and op.deletionLog.taskRef = op.targetTask)
}

// Append-only: 1-to-1 between successful delete ops and log entries.
fact F_AppendOnlyDeletionLog {
  all e: DeletionLogEntry | (one op: Operation | op.deletionLog = e)
  all disj op1, op2: Operation |
    (some op1.deletionLog and op1.deletionLog = op2.deletionLog) implies op1 = op2
}

// =========================== Pattern assertions ===========================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = Success implies some op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; contracts/http-api.md (no 403 path)
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies (op.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionMatrixComplete {
  // Every cell decided: MemberRole gets all 5, Anonymous gets none, no extras.
  #PermMatrix.Allowed = 5
  MemberRole -> CreateTask in PermMatrix.Allowed
  MemberRole -> ListTasks in PermMatrix.Allowed
  MemberRole -> ViewTask  in PermMatrix.Allowed
  MemberRole -> EditTask  in PermMatrix.Allowed
  MemberRole -> DeleteTask in PermMatrix.Allowed
  no (Anonymous.(PermMatrix.Allowed))
}
assert PermissionMatrixComplete { PermissionMatrixComplete }
check PermissionMatrixComplete for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions
pred AuditCompleteness {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies (one op.deletionLog)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on task_deletions"
pred AppendOnly {
  all disj op1, op2: Operation |
    (some op1.deletionLog and op1.deletionLog = op2.deletionLog) implies op1 = op2
  all e: DeletionLogEntry | (one op: Operation | op.deletionLog = e)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md deleted_by_user_id / task_title_at_delete
pred AttributionCorrectness {
  all op: Operation |
    some op.deletionLog implies
      (op.deletionLog.deleter = op.caller and op.deletionLog.taskRef = op.targetTask)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// ======================= Feature-specific (per-FR) ========================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | op.outcome = Success implies some op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_IdentityFromAuth {
  // Caller of a successful op must be a token-resolved user (never invented
  // from a payload field).
  all op: Operation |
    (op.outcome = Success and some op.caller)
      implies (some t: Token | t.user = op.caller)
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_SingleImplicitWorkspace {
  // No Team / Workspace sig exists; every Task is reachable to every
  // authenticated caller — encoded by: ViewTask success demands only auth,
  // not any per-task membership relation.
  all op: Operation |
    (op.kind = ViewTask and op.outcome = Success) implies some op.caller
}
assert FR_003_SingleImplicitWorkspace { FR_003_SingleImplicitWorkspace }
check FR_003_SingleImplicitWorkspace for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_FlatPermissions {
  // Every (MemberRole, kind) cell is allowed: no hidden gating beyond auth.
  all k: OperationKind | MemberRole -> k in PermMatrix.Allowed
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeIsMember {
  all t: Task | some t.assignee implies t.assignee in Member
  some Task
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreatorAlwaysSet {
  // Every task records a creator from the Member set.
  all t: Task | t.creator in Member
  some Task
}
assert FR_009_CreatorAlwaysSet { FR_009_CreatorAlwaysSet }
check FR_009_CreatorAlwaysSet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_StatusEnum {
  all t: Task | t.status in (Todo + InProgress + Done)
  some Task
}
assert FR_010_StatusEnum { FR_010_StatusEnum }
check FR_010_StatusEnum for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClosedTaskEdit {
  all op: Operation |
    (op.kind = EditTask and op.outcome = Success and op.preStatus = Done)
      implies op.newStatus != Done
}
assert FR_011_ClosedTaskEdit { FR_011_ClosedTaskEdit }
check FR_011_ClosedTaskEdit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_DeletionRecorded {
  // Permanent deletion is observable only via the operational log.
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies (one op.deletionLog)
}
assert FR_012_DeletionRecorded { FR_012_DeletionRecorded }
check FR_012_DeletionRecorded for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OnlyCoreOps {
  // The v1 OperationKind universe is exactly the five core operations.
  OperationKind = CreateTask + ListTasks + ViewTask + EditTask + DeleteTask
}
assert FR_013_OnlyCoreOps { FR_013_OnlyCoreOps }
check FR_013_OnlyCoreOps for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_DeletionLogged {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies
      (some op.deletionLog
        and op.deletionLog.deleter = op.caller
        and op.deletionLog.taskRef = op.targetTask)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ClosedTaskEditViolation { some op: Operation | op.kind = EditTask and op.outcome = Success and op.preStatus = Done and op.newStatus = Done and some op.targetTask and some op.caller }
