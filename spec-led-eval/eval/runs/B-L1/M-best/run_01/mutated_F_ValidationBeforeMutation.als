// === feature_model.als — Alloy model for B-L1 Team Task Management ===
// Single implicit workspace; flat peer permissions; FR-001..FR-018.
// Models the HTTP-boundary operations (Create / View / List / Edit / Delete)
// as a single Operation sig with kind + outcome, plus the append-only
// task_deletions log defined by data-model.md.

// ----- Universe non-emptiness -----
fact F_NonEmptyUniverse {
  some User
  some Token
  some Task
  some Operation
  some TaskDeletion
  some Timestamp
}

// ----- Core entities (data-model.md) -----

sig User {}

sig Token { owner: one User }

sig Timestamp {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

sig Task {
  assignee: lone User,
  status: one TaskStatus,
  createdBy: one User,
  createdAt: one Timestamp,
  updatedAt: one Timestamp
}

sig TaskDeletion {
  deletedTaskRef: one Task,
  deletedBy: one User,
  deletedAt: one Timestamp
}

// ----- Operations (contracts/http-api.md boundary) -----

abstract sig OperationKind {}
one sig CreateOp, ViewOp, ListOp, EditOp, DeleteOp extends OperationKind {}

abstract sig Outcome {}
one sig Accepted, RejectedUnauth, RejectedValidation, RejectedClosed, RejectedNotFound extends Outcome {}

sig Operation {
  kind: one OperationKind,
  caller: lone User,                  // none = unauthenticated request
  target: lone Task,                  // none for CreateOp/ListOp
  outcome: one Outcome,
  producedDeletion: lone TaskDeletion, // present iff Accepted DeleteOp
  produced: lone Task,                // present iff Accepted CreateOp
  setsStatusTo: lone TaskStatus       // optional `status` in PATCH body
}

// ----- Roles / permission matrix (Q3 = A — flat peer model) -----

abstract sig Role {}
one sig Member extends Role {}

one sig PermMatrix { Allowed: set Role -> OperationKind }

// ----- Named facts (load-bearing for the assertions below) -----

// Closed-world permission matrix: every cell is "allow" because permissions are flat.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Member -> CreateOp) +
    (Member -> ViewOp) +
    (Member -> ListOp) +
    (Member -> EditOp) +
    (Member -> DeleteOp)
}

// FR-001 / SC-005: every operation requires an authenticated caller.
fact F_AuthRequiredOnAllOps {
  all op: Operation | no op.caller implies op.outcome = RejectedUnauth
  all op: Operation | op.outcome = Accepted implies some op.caller
}

// FR-018: every accepted DELETE produces exactly one task_deletions row;
// that row only exists for accepted DELETEs.
fact F_DeleteAcceptedProducesDeletion {
  all op: Operation | (op.kind = DeleteOp and op.outcome = Accepted) implies one op.producedDeletion
  all op: Operation | some op.producedDeletion implies (op.kind = DeleteOp and op.outcome = Accepted)
  all td: TaskDeletion | (one op: Operation | op.producedDeletion = td)
}

// FR-018: the deletion log records the deleter and the deleted task identity.
fact F_DeletionAttribution {
  all op: Operation | some op.producedDeletion implies op.producedDeletion.deletedBy = op.caller
  all op: Operation | some op.producedDeletion implies op.producedDeletion.deletedTaskRef = op.target
}

// FR-012 + data-model.md: task_deletions is append-only; no two entries cover the same task.
fact F_AppendOnlyDeletionLog {
  all disj td1, td2: TaskDeletion | td1.deletedTaskRef != td2.deletedTaskRef
}

// FR-011: PATCH on a done task is only accepted if the same request reopens it.
fact F_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditOp and some op.target and op.target.status = Done and op.outcome = Accepted)
      implies (op.setsStatusTo = Todo or op.setsStatusTo = InProgress)
}

// FR-005..FR-008 + data-model.md atomicity: rejected mutations have no side-effects.
fact F_ValidationBeforeMutation { /* MUTATED — body cleared by validator */ }

// FR-002 / FR-009: created_by is taken from the auth context, not the payload.
fact F_CreatorMatchesCaller {
  all op: Operation | some op.produced implies op.produced.createdBy = op.caller
}

// Structural housekeeping for the operation model.
fact F_SetsStatusOnlyOnEdit {
  all op: Operation | some op.setsStatusTo implies op.kind = EditOp
}

fact F_TargetShape {
  all op: Operation | op.kind = CreateOp implies no op.target
  all op: Operation | op.kind = ListOp   implies no op.target
  all op: Operation |
    ((op.kind = ViewOp or op.kind = EditOp or op.kind = DeleteOp) and op.outcome = Accepted)
      implies some op.target
}

// ----- Catalogue patterns -----

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = Accepted implies some op.caller
  all op: Operation | no op.caller implies op.outcome != Accepted
  some Operation
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md (flat peer model — every cell defined)
pred PermissionCompleteness {
  all r: Role, k: OperationKind | r -> k in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; every accepted op is permitted by the matrix
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Accepted implies (some r: Role | r -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AppendOnly  ANCHOR: data-model.md "No UPDATE/DELETE code path targets this table"; FR-018
pred AppendOnly {
  all disj td1, td2: TaskDeletion | td1.deletedTaskRef != td2.deletedTaskRef
  some TaskDeletion
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-018; one task_deletions row per accepted DELETE
pred AuditCompleteness {
  all op: Operation | (op.kind = DeleteOp and op.outcome = Accepted) implies one op.producedDeletion
  all td: TaskDeletion | (one op: Operation | op.producedDeletion = td)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-018; deleter recorded in deletion row matches caller
pred AttributionCorrectness {
  all op: Operation | some op.producedDeletion implies op.producedDeletion.deletedBy = op.caller
  all op: Operation | some op.producedDeletion implies op.producedDeletion.deletedTaskRef = op.target
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: data-model.md atomicity contract; FR-005..FR-008
pred ValidationBeforeMutation {
  all op: Operation | (op.kind = CreateOp and op.outcome != Accepted) implies no op.produced
  all op: Operation | (op.kind = DeleteOp and op.outcome != Accepted) implies no op.producedDeletion
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ----- Feature-specific FR predicates -----

// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated requests rejected before any handler runs
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies op.outcome = RejectedUnauth
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — created_by sourced from auth context, not the body
pred FR_002_IdentityFromAuth {
  all op: Operation | some op.produced implies op.produced.createdBy = op.caller
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — single implicit workspace, no Team/Workspace partitioning
pred FR_003_SingleWorkspace {
  // No Team/Workspace sig exists in this model; the absence is the encoding.
  // We assert the consequence: ViewOp denials are due to auth, not membership.
  all op: Operation | (op.kind = ViewOp and op.outcome = RejectedUnauth) implies no op.caller
  some Task
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — flat permissions, every member may perform every operation
pred FR_004_FlatPermissions {
  all k: OperationKind | Member -> k in PermMatrix.Allowed
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 — at most one assignee per task
pred FR_008_AtMostOneAssignee {
  all t: Task | lone t.assignee
  some Task
}
assert FR_008_AtMostOneAssignee { FR_008_AtMostOneAssignee }
check FR_008_AtMostOneAssignee for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — creator and creation timestamp recorded exactly once per task
pred FR_009_CreatorRecorded {
  all t: Task | (one t.createdBy and one t.createdAt)
  some Task
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — status is one of {todo, in_progress, done}
pred FR_010_StatusEnum {
  all t: Task | t.status in (Todo + InProgress + Done)
  some Task
}
assert FR_010_StatusEnum { FR_010_StatusEnum }
check FR_010_StatusEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — done task may only be edited if request simultaneously reopens it
pred FR_011_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditOp and some op.target and op.target.status = Done and op.outcome = Accepted)
      implies (op.setsStatusTo = Todo or op.setsStatusTo = InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — deletion is permanent (any task gets at most one deletion row)
pred FR_012_DeletionPermanent {
  all disj td1, td2: TaskDeletion | td1.deletedTaskRef != td2.deletedTaskRef
}
assert FR_012_DeletionPermanent { FR_012_DeletionPermanent }
check FR_012_DeletionPermanent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — manage scope is exactly the five enumerated operations
pred FR_013_ScopeExactlyFive {
  OperationKind = CreateOp + ViewOp + ListOp + EditOp + DeleteOp
}
assert FR_013_ScopeExactlyFive { FR_013_ScopeExactlyFive }
check FR_013_ScopeExactlyFive for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — created_at and updated_at present on every task
pred FR_017_TimestampsPresent {
  all t: Task | (one t.createdAt and one t.updatedAt)
  some Task
}
assert FR_017_TimestampsPresent { FR_017_TimestampsPresent }
check FR_017_TimestampsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — deletion log records deleter, task, and timestamp
pred FR_018_DeletionLogged {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Accepted) implies
      (one td: TaskDeletion |
         op.producedDeletion = td and
         td.deletedBy = op.caller and
         td.deletedTaskRef = op.target)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ValidationViolation { some op: Operation | op.kind = CreateOp and op.outcome != Accepted and some op.produced }
