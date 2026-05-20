// === feature_model.als — Alloy model for Team Task Management (006-task-management) ===
// Encodes structural invariants from spec.md (FR-001..FR-018), data-model.md, and
// contracts/http-api.md. Single implicit workspace, flat peer permissions, append-only
// deletion log, closed-task PATCH rule.

abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig OperationKind {}
one sig CreateOp, ViewOp, ListOp, EditOp, DeleteOp extends OperationKind {}

abstract sig Role {}
one sig Member extends Role {}

sig User {}

sig Token {
  resolvesTo: one User
}

sig Task {
  creator: one User,
  assignee: lone User,
  status: one TaskStatus
}

sig TaskDeletion {
  task: one Task,
  deletedBy: one User
}

sig Operation {
  kind: one OperationKind,
  authenticated: one Bool,
  caller: lone User,
  target: lone Task,
  succeeded: one Bool,
  setsStatusToOpen: one Bool,
  deletionRecord: lone TaskDeletion
}

// Permission matrix as a singleton-sig field (per protocol).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ----------------- NON-EMPTY UNIVERSE -----------------

fact F_NonEmptyUniverse {
  some User
  some Token
  some Task
  some TaskDeletion
  some Operation
}

// ----------------- STRUCTURAL FACTS -----------------

// Flat-peer permission matrix from FR-004 + contracts/http-api.md
// (no 403 response exists; every authenticated caller may perform every operation).
fact F_PermissionMatrix {
  PermMatrix.Allowed = (Member -> CreateOp) +
                       (Member -> ViewOp) +
                       (Member -> ListOp) +
                       (Member -> EditOp) +
                       (Member -> DeleteOp)
}

// Caller is present exactly when the operation is authenticated.
fact F_AuthCallerLink {
  all op: Operation | (some op.caller) iff op.authenticated = True
}

// Shape: Create/List take no Task target; View/Edit/Delete take exactly one.
fact F_OperationTargetShape {
  all op: Operation |
    (op.kind in (ViewOp + EditOp + DeleteOp)) iff (some op.target)
}

// Only DeleteOp may carry a deletionRecord field.
fact F_DeletionRecordOnlyOnDelete {
  all op: Operation | op.kind != DeleteOp implies no op.deletionRecord
}

// FR-001 + SC-005: no operation may succeed without authentication.
fact F_AuthRequired {
  all op: Operation | op.succeeded = True implies op.authenticated = True
}

// FR-002: caller identity is bound to a Token, never sourced from the request body.
fact F_IdentityFromToken {
  all op: Operation | op.authenticated = True implies
    (some t: Token | t.resolvesTo = op.caller)
}

// FR-018 + AppendOnly: task_deletions has no UPDATE/DELETE path; at most one row per task.
fact F_AppendOnlyDeletions {
  all disj d1, d2: TaskDeletion | d1.task != d2.task
}

// FR-018: every successful DeleteOp produces exactly one TaskDeletion targeting the
// same task; every TaskDeletion is justified by some successful DeleteOp.
fact F_AuditCompleteness {
  all op: Operation |
    (op.kind = DeleteOp and op.succeeded = True) implies
      (one op.deletionRecord and op.deletionRecord.task = op.target)
  all d: TaskDeletion |
    (some op: Operation |
       op.kind = DeleteOp and op.succeeded = True and op.deletionRecord = d)
}

// FR-018: the recorded deleter on the log row equals the caller of the delete op.
fact F_AttributionCorrectness {
  all op: Operation |
    (op.kind = DeleteOp and op.succeeded = True) implies
      op.deletionRecord.deletedBy = op.caller
}

// FR-011: PATCH on a `done` task is only accepted if the same request transitions
// the status back to `todo` or `in_progress`.
fact F_ClosedTaskRule {
  all op: Operation |
    (op.kind = EditOp and op.succeeded = True and op.target.status = Done) implies
      op.setsStatusToOpen = True
}

// FR-012: deletion is permanent; no successful non-delete operation may target a
// task that already has a TaskDeletion record.
fact F_NoOpOnDeletedTask {
  all op: Operation |
    (op.succeeded = True and op.kind != DeleteOp and some op.target) implies
      (no d: TaskDeletion | d.task = op.target)
}

// =============== PATTERN ASSERTIONS ===============

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  // every successful operation has both an authenticated flag and a resolved caller
  all op: Operation |
    op.succeeded = True implies (op.authenticated = True and some op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md (no 403); FR-004
pred PermissionCompleteness {
  // every (Role × OperationKind) cell has a defined verdict (here all "allow")
  all r: Role, k: OperationKind | r -> k in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 1 Role, exactly 5 OperationKind

// PATTERN: LeastPrivilege  ANCHOR: FR-004; contracts/http-api.md (flat peers, no privilege escalation)
pred LeastPrivilege {
  // every successful operation's (role -> kind) cell is in the permission matrix
  all op: Operation |
    op.succeeded = True implies (Member -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AppendOnly  ANCHOR: data-model.md "No UPDATE/DELETE code path targets task_deletions"; FR-018
pred AppendOnly {
  // no Task appears in more than one TaskDeletion row
  all t: Task | lone { d: TaskDeletion | d.task = t }
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-018; data-model.md task_deletions
pred AuditCompleteness {
  // every successful deletion yields exactly one log row pointing at the deleted task
  all op: Operation |
    (op.kind = DeleteOp and op.succeeded = True) implies
      (one d: TaskDeletion | d = op.deletionRecord and d.task = op.target)
  // every log row is justified by some successful deletion
  all d: TaskDeletion |
    (some op: Operation |
       op.kind = DeleteOp and op.succeeded = True and op.deletionRecord = d)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-018 "deleter identity"
pred AttributionCorrectness {
  // recorded deleter on the log row matches the caller of the delete operation
  all op: Operation |
    (op.kind = DeleteOp and op.succeeded = True and some op.deletionRecord) implies
      op.deletionRecord.deletedBy = op.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.created_by NOT NULL; FR-009
pred OwnershipExclusivity {
  // every Task has exactly one creator and that creator is a User
  all t: Task | one t.creator and t.creator in User
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// =============== FR ASSERTIONS ===============

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth required on every operation)
pred FR_001_AuthRequired {
  // no operation may simultaneously succeed and be unauthenticated
  no op: Operation | op.succeeded = True and op.authenticated = False
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (caller from auth context, not payload)
pred FR_002_IdentityFromAuth {
  // every authenticated op's caller is resolvable from some Token
  all op: Operation |
    op.authenticated = True implies (some t: Token | t.resolvesTo = op.caller)
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (single implicit workspace; every user is a member)
pred FR_003_SingleWorkspace {
  // there is no Team/Workspace sig; every authenticated caller is in User and may
  // be the caller of any operation kind without further isolation.
  all op: Operation | op.authenticated = True implies op.caller in User
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (flat permissions, all members peers)
pred FR_004_FlatPermissions {
  // exactly one role exists and every OperationKind is permitted to it
  one Role
  all k: OperationKind | Member -> k in PermMatrix.Allowed
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 (at most one assignee per task)
pred FR_008_AtMostOneAssignee {
  all t: Task | lone t.assignee
}
assert FR_008_AtMostOneAssignee { FR_008_AtMostOneAssignee }
check FR_008_AtMostOneAssignee for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (creator immutable & exactly one per task)
pred FR_009_OneCreatorPerTask {
  all t: Task | one t.creator
}
assert FR_009_OneCreatorPerTask { FR_009_OneCreatorPerTask }
check FR_009_OneCreatorPerTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 (status in {todo, in_progress, done})
pred FR_010_StatusInAllowedSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusInAllowedSet { FR_010_StatusInAllowedSet }
check FR_010_StatusInAllowedSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 (closed-task PATCH rule)
pred FR_011_ClosedTaskEditRule {
  // any successful edit on a Done task must also flip status to Todo or InProgress
  all op: Operation |
    (op.kind = EditOp and op.succeeded = True and op.target.status = Done) implies
      op.setsStatusToOpen = True
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (permanent deletion; no resurrection)
pred FR_012_NoOpAfterDeletion {
  all op: Operation |
    (op.succeeded = True and op.kind != DeleteOp and some op.target) implies
      (no d: TaskDeletion | d.task = op.target)
}
assert FR_012_NoOpAfterDeletion { FR_012_NoOpAfterDeletion }
check FR_012_NoOpAfterDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (v1 manage scope is exactly create/view/list/edit/delete)
pred FR_013_ScopeClosed {
  all op: Operation | op.kind in (CreateOp + ViewOp + ListOp + EditOp + DeleteOp)
}
assert FR_013_ScopeClosed { FR_013_ScopeClosed }
check FR_013_ScopeClosed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 (operational deletion log records every deletion)
pred FR_018_DeletionLogged {
  all op: Operation |
    (op.kind = DeleteOp and op.succeeded = True) implies
      (one d: TaskDeletion |
         d = op.deletionRecord and d.task = op.target and d.deletedBy = op.caller)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_MissingDeletionLog { some op: Operation | op.kind = DeleteOp and op.succeeded = True and op.authenticated = True and no op.deletionRecord }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
