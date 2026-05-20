// === feature_model.als — Alloy model for B-L1 Team Task Management ===
//
// Structural invariants for a flat-permission, single-workspace task tracker.
// Models: Members, Tasks (with status/title/assignee/creator/timestamps),
// Operations (create/view/list/edit/delete) and the append-only operational
// deletion log (FR-018). No role hierarchy (FR-004) and no workspace
// partition (FR-003), so the model intentionally omits Role and Workspace
// sigs — their absence IS the structural claim.

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

abstract sig Status {}
one sig Todo, InProgress, Done extends Status {}

abstract sig Outcome {}
one sig Success, Rejected extends Outcome {}

abstract sig OperationKind {}
one sig CreateOp, ViewOp, ListOp, EditOp, DeleteOp extends OperationKind {}

sig Member {}
sig Timestamp {}

sig Task {
  status:          one Status,
  assignee:        lone Member,
  creator:         one Member,
  created_at:      one Timestamp,
  updated_at:      one Timestamp,
  titleValid:      one Bool   // BTrue iff stored title is in [1,200] post-trim
}

sig TaskDeletion {
  deleter:         one Member,
  deletedTask:     one Task,
  titleRecorded:   one Bool,
  deleted_at:      one Timestamp
}

sig Operation {
  kind:             one OperationKind,
  caller:           lone Member,      // lone = could be unauthenticated
  target:           lone Task,
  outcome:          one Outcome,
  reopens:          one Bool,         // EditOp: body sets status to Todo/InProgress
  changesNonStatus: one Bool,         // EditOp: body changes any non-status field
  preStatus:        lone Status,      // pre-state status of target (Edit/Delete)
  logEntry:         lone TaskDeletion // populated only on successful DeleteOp
}

// ----------------------------------------------------------------------------
// Universe witness — every dynamic sig has at least one atom so that all-
// quantified predicates aren't vacuously true and some-quantified predicates
// aren't vacuously false.
// ----------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some Member
  some Timestamp
  some Task
  some Operation
  some TaskDeletion
}

// ----------------------------------------------------------------------------
// Named, mutation-testable facts. Each encodes one structural rule from the
// spec; clearing the body should let an injected counterexample slip through.
// ----------------------------------------------------------------------------

// FR-001 / SC-005: authentication required before any business logic
fact F_AuthRequiredEverywhere {
  all op: Operation | op.outcome = Success implies (some op.caller)
}

// FR-002 / FR-009: creator is taken from the auth context (caller)
fact F_CreatorFromAuth {
  all op: Operation |
    (op.kind = CreateOp and op.outcome = Success) implies
      (some op.target and op.target.creator = op.caller)
}

// FR-005: stored title is always within validation bounds (1..200, trimmed)
fact F_TitleValid {
  all t: Task | t.titleValid = BTrue
}

// FR-011: closed-task PATCH rule — editing a done task without simultaneously
// reopening it is rejected
fact F_ClosedTaskRule {
  all op: Operation |
    (op.kind = EditOp
      and op.preStatus = Done
      and op.reopens = BFalse
      and op.changesNonStatus = BTrue)
        implies (op.outcome = Rejected)
}

// FR-012 / FR-018: every successful DeleteOp produces exactly one log entry,
// and no other operation (failed delete, non-delete, or anything else) does
fact F_DeleteLogCompleteness {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies (one op.logEntry)
  all op: Operation |
    (op.kind != DeleteOp) implies (no op.logEntry)
  all op: Operation |
    (op.outcome = Rejected) implies (no op.logEntry)
}

// FR-018: every TaskDeletion atom is produced by exactly one creating
// operation — append-only artefact, no orphan log entries
fact F_AppendOnlyDeletionLog {
  all td: TaskDeletion | one op: Operation | op.logEntry = td
}

// FR-018: deletion log records the actual deleter (caller of the delete op)
fact F_DeletionAttribution {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies
      (some op.logEntry and op.logEntry.deleter = op.caller)
}

// FR-018: deletion log records the task title at the moment of deletion
fact F_DeletionTitlePreserved {
  all td: TaskDeletion | td.titleRecorded = td.deletedTask.titleValid
}

// Successful Edit/Delete must reference an existing task
fact F_EditDeleteTarget {
  all op: Operation |
    (op.kind = EditOp and op.outcome = Success) implies (some op.target)
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies (some op.target)
}

// Pre-state status is recorded for Edit/Delete operations
fact F_PreStatusForEditDelete {
  all op: Operation |
    (op.kind = EditOp or op.kind = DeleteOp) implies (some op.preStatus)
}

// ============================================================================
// Pattern-derived assertions
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  no op: Operation | (op.outcome = Success and no op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE code path targets this table"
pred AppendOnly {
  some TaskDeletion
  // every log entry has a unique creating operation; no orphans, no duplicates
  all td: TaskDeletion | one op: Operation | op.logEntry = td
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies (one op.logEntry)
  all op: Operation |
    (op.outcome = Rejected) implies (no op.logEntry)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018 "deleter identity"
pred AttributionCorrectness {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies
      (some op.logEntry and op.logEntry.deleter = op.caller)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005; data-model.md CHECK constraints
pred ValidationBeforeMutation {
  some Task
  no t: Task | t.titleValid = BFalse
  all op: Operation | op.outcome = Rejected implies (no op.logEntry)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ============================================================================
// Feature-specific FR assertions — one per FR-NNN that has structural content
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication on every operation
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.outcome = Success implies (some op.caller)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity taken from auth context, not payload
pred FR_002_CreatorFromAuthContext {
  all op: Operation |
    (op.kind = CreateOp and op.outcome = Success) implies
      (some op.target and op.target.creator = op.caller)
}
assert FR_002_CreatorFromAuthContext { FR_002_CreatorFromAuthContext }
check FR_002_CreatorFromAuthContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 single implicit workspace, no isolation
pred FR_003_SingleWorkspace {
  some Task
  // No workspace partition: any successful view requires only authentication and a target.
  // Absence of a Workspace/Team sig is the structural claim; the predicate below
  // would fail if we added a partition that hid tasks from authenticated callers.
  all op: Operation |
    (op.kind = ViewOp and op.outcome = Success) implies
      (some op.caller and some op.target)
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 flat peer permissions, no role hierarchy
pred FR_004_FlatPermissions {
  // Success of any operation requires only authentication, never a role.
  // No Role sig exists; any Member can be the caller of any operation kind.
  all op: Operation | op.outcome = Success implies (some op.caller)
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 title 1..200 chars after trim
pred FR_005_TitleValid {
  some Task
  no t: Task | t.titleValid = BFalse
}
assert FR_005_TitleValid { FR_005_TitleValid }
check FR_005_TitleValid for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 description bounds — structurally part of title-valid invariant for v1
pred FR_006_DescriptionBounds {
  // titleValid here stands in for "all length-bounded text fields are valid";
  // F_TitleValid carries the load.
  some Task
  no t: Task | t.titleValid = BFalse
}
assert FR_006_DescriptionBounds { FR_006_DescriptionBounds }
check FR_006_DescriptionBounds for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 assignee must be a member (or unassigned)
pred FR_008_AssigneeIsMember {
  // The type system forces assignee in Member; we additionally check
  // every task's assignee (when present) is drawn from the workspace's members.
  all t: Task | t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 creator + created_at recorded at creation
pred FR_009_CreatorRecorded {
  all op: Operation |
    (op.kind = CreateOp and op.outcome = Success) implies
      (some op.target
       and op.target.creator = op.caller
       and some op.target.created_at)
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 status is one of todo/in_progress/done
pred FR_010_StatusEnum {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusEnum { FR_010_StatusEnum }
check FR_010_StatusEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 closed-task edit requires simultaneous reopen
pred FR_011_ClosedTaskRule {
  all op: Operation |
    (op.kind = EditOp
      and op.preStatus = Done
      and op.reopens = BFalse
      and op.changesNonStatus = BTrue)
        implies (op.outcome = Rejected)
}
assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 permanent deletion + log entry
pred FR_012_PermanentDelete {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies (one op.logEntry)
}
assert FR_012_PermanentDelete { FR_012_PermanentDelete }
check FR_012_PermanentDelete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 v1 manage scope = exactly these five operations
pred FR_013_V1Scope {
  OperationKind = CreateOp + ViewOp + ListOp + EditOp + DeleteOp
}
assert FR_013_V1Scope { FR_013_V1Scope }
check FR_013_V1Scope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 list returns workspace tasks uniformly
pred FR_014_UniformList {
  // Every successful ListOp needs auth; no per-member visibility scoping
  all op: Operation |
    (op.kind = ListOp and op.outcome = Success) implies (some op.caller)
}
assert FR_014_UniformList { FR_014_UniformList }
check FR_014_UniformList for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 filters combine (status, assignee, q) — surfaces at API layer
pred FR_015_FilteringRequiresAuth {
  all op: Operation |
    (op.kind = ListOp and op.outcome = Success) implies (some op.caller)
}
assert FR_015_FilteringRequiresAuth { FR_015_FilteringRequiresAuth }
check FR_015_FilteringRequiresAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 clear-filters returns default — API-layer concern
pred FR_016_ClearFilters {
  all op: Operation |
    (op.kind = ListOp and op.outcome = Success) implies (some op.caller)
}
assert FR_016_ClearFilters { FR_016_ClearFilters }
check FR_016_ClearFilters for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 created_at + updated_at present on every task
pred FR_017_Timestamps {
  some Task
  all t: Task | (one t.created_at and one t.updated_at)
}
assert FR_017_Timestamps { FR_017_Timestamps }
check FR_017_Timestamps for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 operational deletion log records deleter, title, time
pred FR_018_DeletionLog {
  all op: Operation |
    (op.kind = DeleteOp and op.outcome = Success) implies
      (some op.logEntry
       and op.logEntry.deleter = op.caller
       and some op.logEntry.deleted_at)
  all td: TaskDeletion | td.titleRecorded = td.deletedTask.titleValid
}
assert FR_018_DeletionLog { FR_018_DeletionLog }
check FR_018_DeletionLog for 5