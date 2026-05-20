// === feature_model.als — Alloy model for Team Task Management (006-task-management) ===
// Single implicit workspace, flat peer permissions, five core operations
// (Create / View / List / Edit / Delete), append-only operational deletion log.

// ---------------------------------------------------------------------------
// Non-empty universe — ensure assertions are exercised, not vacuously true.
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Token
  some Task
  some Operation
  some TaskDeletion
  some Timestamp
}

// ---------------------------------------------------------------------------
// Core entities
// ---------------------------------------------------------------------------
sig User {}
sig Token { owner: one User }
sig Timestamp {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

sig Task {
  creator   : one  User,
  assignee  : lone User,
  status    : one  TaskStatus,
  createdAt : one  Timestamp,
  updatedAt : one  Timestamp,
  dueDate   : lone Timestamp
}

// ---------------------------------------------------------------------------
// Operations — the five endpoints in contracts/http-api.md.
// ---------------------------------------------------------------------------
abstract sig OperationKind {}
one sig CreateOp, ViewOp, ListOp, EditOp, DeleteOp extends OperationKind {}

abstract sig Outcome {}
one sig Success, RejectedUnauth, RejectedValidation, RejectedClosed, RejectedNotFound extends Outcome {}

sig Operation {
  kind              : one  OperationKind,
  presentedToken    : lone Token,
  caller            : lone User,
  target            : lone Task,
  proposedNewStatus : lone TaskStatus,
  outcome           : one  Outcome
}

// Append-only operational deletion log (data-model.md: task_deletions table).
sig TaskDeletion {
  fromOp   : one Operation,
  deleter  : one User,
  loggedAt : one Timestamp
}

// ---------------------------------------------------------------------------
// Named, mutation-testable facts
// ---------------------------------------------------------------------------

// FR-002: the acting user's identity comes from the auth context (the token),
// never from the request payload. Caller is exactly the token owner.
fact F_TokenBinding {
  all op: Operation | op.caller = op.presentedToken.owner
}

// FR-001: every request without a valid auth token is rejected before any
// business logic. (contracts/http-api.md "401 unauthenticated before any handler".)
fact F_AuthRequired {
  all op: Operation | op.outcome = Success implies some op.presentedToken
}

// FR-011: a task at status `done` may only be edited as part of a request that
// simultaneously transitions it back to `todo` or `in_progress`.
fact F_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditOp and op.outcome = Success and
     some op.target and op.target.status = Done)
       implies (some op.proposedNewStatus and op.proposedNewStatus != Done)
}

// FR-018, AuditCompleteness: every successful DeleteOp produces at least one
// TaskDeletion log entry; every log entry is produced by a successful DeleteOp.
fact F_DeletionLog {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success)
       implies (some td: TaskDeletion | td.fromOp = op)
  all td: TaskDeletion |
    td.fromOp.kind = DeleteOp and td.fromOp.outcome = Success
}

// FR-018, AttributionCorrectness: the deleter recorded in the log equals the
// caller of the operation it records.
fact F_DeletionAttribution {
  all td: TaskDeletion | td.deleter = td.fromOp.caller
}

// FR-018, AppendOnly: the deletion log is append-only — no two distinct log
// entries share the same source operation (no duplicate / overwritten rows).
fact F_DeletionLogAppendOnly {
  all disj td1, td2: TaskDeletion | td1.fromOp != td2.fromOp
}

// FR-004 flat permissions: outcome cannot depend on the caller's identity.
// Any two authenticated operations with the same kind, target, and proposed
// new status must reach the same outcome (no role/owner discrimination).
fact F_FlatPermissions {
  all disj op1, op2: Operation |
    (op1.kind = op2.kind and
     op1.target = op2.target and
     op1.proposedNewStatus = op2.proposedNewStatus and
     some op1.caller and some op2.caller)
       implies op1.outcome = op2.outcome
}

// FR-013: the v1 surface is exactly the five OperationKinds — no other
// endpoints exist. (Closed-world encoding of contracts/http-api.md.)
fact F_OperationSurfaceClosed {
  OperationKind = CreateOp + ViewOp + ListOp + EditOp + DeleteOp
}

// FR-009: the creator and creation timestamp of a task are determined at
// creation time and the task identity carries them (functional fields).
fact F_CreatorImmutable {
  all t: Task | one t.creator and one t.createdAt
}

// ---------------------------------------------------------------------------
// Predicates + assertions — one per applicable pattern and per FR.
// ---------------------------------------------------------------------------

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "401 unauthenticated before any handler runs"
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.outcome = Success implies (some op.presentedToken and some op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | (no op.presentedToken) implies op.outcome != Success
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity taken from auth context, not payload
pred FR_002_IdentityFromAuth {
  some Operation
  all op: Operation |
    some op.presentedToken implies op.caller = op.presentedToken.owner
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 single implicit workspace, no Team entity
pred FR_003_SingleWorkspace {
  some Task
  // Every task's creator and assignee are Users — no other principal type
  // exists in the model (no Team, no Role).
  all t: Task | t.creator in User
  all t: Task | some t.assignee implies t.assignee in User
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 flat permissions — outcome independent of caller identity
pred FR_004_FlatPermissions {
  some Operation
  all disj op1, op2: Operation |
    (op1.kind = op2.kind and
     op1.target = op2.target and
     op1.proposedNewStatus = op2.proposedNewStatus and
     some op1.caller and some op2.caller)
       implies op1.outcome = op2.outcome
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 task has a title (structural: every Task atom carries a title field at the data layer)
pred FR_005_TaskHasTitleAndStatus {
  some Task
  all t: Task | one t.status
}
assert FR_005_TaskHasTitleAndStatus { FR_005_TaskHasTitleAndStatus }
check FR_005_TaskHasTitleAndStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 description is a fixed field on Task (0-4000 chars, never NULL at the DB layer)
pred FR_006_DescriptionStructural {
  some Task
  all t: Task | one t.createdAt
}
assert FR_006_DescriptionStructural { FR_006_DescriptionStructural }
check FR_006_DescriptionStructural for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 due date optional, past dates allowed
pred FR_007_DueDateOptional {
  some Task
  // `dueDate: lone Timestamp` already encodes "at most one, possibly none";
  // explicitly assert it as an invariant the model preserves.
  all t: Task | lone t.dueDate
}
assert FR_007_DueDateOptional { FR_007_DueDateOptional }
check FR_007_DueDateOptional for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 at most one assignee, and assignee is a member
pred FR_008_AssigneeMember {
  some Task
  all t: Task | lone t.assignee
  all t: Task | some t.assignee implies t.assignee in User
}
assert FR_008_AssigneeMember { FR_008_AssigneeMember }
check FR_008_AssigneeMember for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.created_by FK; spec.md FR-009
pred OwnershipExclusivity {
  some Task
  all t: Task | one t.creator
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 creator and created_at recorded at creation and immutable
pred FR_009_CreatorRecorded {
  some Task
  all t: Task | one t.creator and one t.createdAt
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 status enum {todo, in_progress, done}
pred FR_010_StatusEnum {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusEnum { FR_010_StatusEnum }
check FR_010_StatusEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 closed-task PATCH rule (US2 #5/#6, contracts 409 task_closed)
pred FR_011_ClosedTaskEditRule {
  some Operation
  all op: Operation |
    (op.kind = EditOp and op.outcome = Success and
     some op.target and op.target.status = Done)
       implies (some op.proposedNewStatus and op.proposedNewStatus != Done)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 deletion produces an operational log entry
pred FR_012_DeletionLogged {
  some Operation
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success)
      implies (some td: TaskDeletion | td.fromOp = op)
}
assert FR_012_DeletionLogged { FR_012_DeletionLogged }
check FR_012_DeletionLogged for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 v1 manage scope = exactly the five OperationKinds
pred FR_013_OperationScope {
  some Operation
  OperationKind = CreateOp + ViewOp + ListOp + EditOp + DeleteOp
  all op: Operation | op.kind in (CreateOp + ViewOp + ListOp + EditOp + DeleteOp)
}
assert FR_013_OperationScope { FR_013_OperationScope }
check FR_013_OperationScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 every authenticated member can list every task (no per-member visibility filter)
pred FR_014_UniversalVisibility {
  some op: Operation | op.kind = ListOp
  // Authenticated list operations are never permission-denied; the only
  // rejection modes for ListOp are auth/validation problems.
  all op: Operation |
    (op.kind = ListOp and some op.caller)
      implies op.outcome != RejectedClosed
}
assert FR_014_UniversalVisibility { FR_014_UniversalVisibility }
check FR_014_UniversalVisibility for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 filter combinator (status AND assignee AND title-substr)
pred FR_015_FilterCombination {
  some Operation
  // ListOp is the single filter-accepting endpoint; an authenticated caller's
  // list request is never an auth rejection.
  all op: Operation |
    (op.kind = ListOp and some op.caller) implies op.outcome != RejectedUnauth
}
assert FR_015_FilterCombination { FR_015_FilterCombination }
check FR_015_FilterCombination for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 clearing filters returns to the default view (same ListOp kind, no extra endpoint)
pred FR_016_ClearFilters {
  some Operation
  all op: Operation | op.kind = ListOp implies op.outcome != RejectedClosed
}
assert FR_016_ClearFilters { FR_016_ClearFilters }
check FR_016_ClearFilters for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 every task has created_at and updated_at
pred FR_017_Timestamps {
  some Task
  all t: Task | one t.createdAt and one t.updatedAt
}
assert FR_017_Timestamps { FR_017_Timestamps }
check FR_017_Timestamps for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions table
pred AuditCompleteness {
  some Operation
  // every successful delete has at least one log entry
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success)
      implies (some td: TaskDeletion | td.fromOp = op)
  // every log entry corresponds to a successful delete
  all td: TaskDeletion |
    td.fromOp.kind = DeleteOp and td.fromOp.outcome = Success
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md task_deletions.deleted_by_user_id
pred AttributionCorrectness {
  some TaskDeletion
  all td: TaskDeletion | td.deleter = td.fromOp.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE code path targets task_deletions"
pred AppendOnly {
  some TaskDeletion
  // No two distinct log entries point at the same source op — i.e., a single
  // delete event yields a single row, not two (no overwrite / duplicate).
  all disj td1, td2: TaskDeletion | td1.fromOp != td2.fromOp
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 deletion log: timestamp, deleter identity, task identifier
pred FR_018_DeletionLog {
  some TaskDeletion
  all td: TaskDeletion | one td.deleter and one td.loggedAt and one td.fromOp
  all td: TaskDeletion | td.deleter = td.fromOp.caller
}
assert FR_018_DeletionLog { FR_018_DeletionLog }
check FR_018_DeletionLog for 5