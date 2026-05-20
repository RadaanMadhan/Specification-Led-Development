// === feature_model.als — Alloy model for B-L1 / Team Task Management (006-task-management) ===
//
// Self-contained Alloy 6 encoding of the structural invariants of the
// "Team Task Management" feature. Anchored to spec.md FR-001..FR-018,
// data-model.md (tasks, task_deletions, users), and contracts/http-api.md.

// -----------------------------------------------------------------------
// Non-empty universe — so universal/existential quantifiers actually bite.
// -----------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some Member
  some Task
  some Operation
  some DeletionLogEntry
  some Timestamp
}

// -----------------------------------------------------------------------
// Booleans (modelling auth-pass / body-reopens / succeeded as a flag).
// -----------------------------------------------------------------------
abstract sig Bool {}
one sig True, False extends Bool {}

// -----------------------------------------------------------------------
// Members. The single implicit workspace (FR-003) means every Member
// is a workspace member; no Team or Workspace entity exists.
// -----------------------------------------------------------------------
sig Member {}

// -----------------------------------------------------------------------
// Roles (flat peer model — Q3=A / FR-004).
// -----------------------------------------------------------------------
abstract sig Role {}
one sig MemberRole extends Role {}

// -----------------------------------------------------------------------
// Task status enum (FR-010).
// -----------------------------------------------------------------------
abstract sig Status {}
one sig Todo, InProgress, Done extends Status {}

// -----------------------------------------------------------------------
// Timestamps (abstract atoms — FR-017 created_at / updated_at).
// -----------------------------------------------------------------------
sig Timestamp {}

// -----------------------------------------------------------------------
// Tasks (data-model.md tasks table).
// -----------------------------------------------------------------------
sig Task {
  creator   : one  Member,      // FR-009: exactly one creator, immutable
  assignee  : lone Member,      // FR-008: optional, at most one
  status    : one  Status,      // FR-010
  titleValid: one  Bool,        // FR-005 surrogate: title 1..200 after trim
  descValid : one  Bool,        // FR-006 surrogate: description 0..4000
  createdAt : one  Timestamp,   // FR-009 / FR-017
  updatedAt : one  Timestamp    // FR-017
}

// -----------------------------------------------------------------------
// Operation surface: the five endpoints abstracted as op kinds.
// -----------------------------------------------------------------------
abstract sig OperationKind {}
one sig CreateTaskKind, ViewTaskKind, EditTaskKind, DeleteTaskKind, ChangeStatusKind
  extends OperationKind {}

// Permission matrix as a singleton-sig field (per system prompt rule 7).
one sig PermMatrix { Allowed: set Role -> OperationKind }

sig Operation {
  kind         : one  OperationKind,
  authenticated: one  Bool,
  caller       : lone Member,
  callerRole   : lone Role,
  target       : lone Task,
  bodyReopens  : one  Bool,   // PATCH that simultaneously sets status to Todo/InProgress
  succeeded    : one  Bool
}

// -----------------------------------------------------------------------
// Deletion log (FR-018) — append-only operational record, no API surface,
// no UPDATE/DELETE code paths (data-model.md task_deletions).
// -----------------------------------------------------------------------
sig DeletionLogEntry {
  deletedTaskId: one Task,
  deleter      : one Member,
  recordedAt   : one Timestamp
}

// =======================================================================
// FACTS — every load-bearing constraint is named so the validator can
// clear its body to test the matching assertion's bite.
// =======================================================================

// Flat permission matrix: every (Role, OperationKind) cell is allow.
fact F_FlatPermissionMatrix {
  PermMatrix.Allowed = Role -> OperationKind
}

// FR-001: every successful operation must be authenticated, with a
// resolved caller and the MemberRole. No bypass.
fact F_AuthRequired {
  all op: Operation | op.succeeded = True implies
    (op.authenticated = True and one op.caller and op.callerRole = MemberRole)
}

// FR-002: identity for a successful create is taken from the auth
// context — the new task's recorded creator equals the op's caller.
fact F_IdentityFromContext {
  all op: Operation |
    (op.kind = CreateTaskKind and op.succeeded = True and some op.target)
      implies op.target.creator = op.caller
}

// FR-005 / FR-006: any persisted task has passed validation on title
// and description length.
fact F_ValidationEnforced {
  all t: Task | t.titleValid = True and t.descValid = True
}

// FR-011: a successful EDIT against a Done task must include a
// simultaneous status change that reopens it.
fact F_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditTaskKind and op.succeeded = True
     and some op.target and op.target.status = Done)
      implies op.bodyReopens = True
}

// FR-018 / AuditCompleteness: every successful delete produces at
// least one log entry referencing the deleted task.
fact F_DeletionLogCompleteness {
  all op: Operation |
    (op.kind = DeleteTaskKind and op.succeeded = True and some op.target)
      implies (some e: DeletionLogEntry | e.deletedTaskId = op.target)
}

// FR-018 / AppendOnly: no two distinct log entries refer to the same
// deleted task (each deletion is recorded once and never duplicated).
fact F_DeletionLogAppendOnly {
  all disj e1, e2: DeletionLogEntry | e1.deletedTaskId != e2.deletedTaskId
}

// FR-018 / AttributionCorrectness: a log entry's deleter equals the
// caller of the delete op it records.
fact F_DeletionAttribution { /* MUTATED — body cleared by validator */ }

// FR-012: a successfully deleted task cannot be the target of any
// other successful operation.
fact F_DeletionPermanent {
  all disj op1, op2: Operation |
    (op1.kind = DeleteTaskKind and op1.succeeded = True
     and some op1.target and op2.target = op1.target)
      implies op2.succeeded = False
}

// =======================================================================
// PATTERN PREDICATES + ASSERTIONS
// =======================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all op: Operation | op.succeeded = True implies
    (op.authenticated = True and some op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md (Q3=A flat peers)
pred PermissionCompleteness {
  all r: Role, k: OperationKind | r -> k in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on task_deletions"
pred AppendOnly {
  all disj e1, e2: DeletionLogEntry | e1.deletedTaskId != e2.deletedTaskId
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018
pred AuditCompleteness {
  all op: Operation |
    (op.kind = DeleteTaskKind and op.succeeded = True and some op.target)
      implies (some e: DeletionLogEntry | e.deletedTaskId = op.target)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md task_deletions.deleted_by_user_id
pred AttributionCorrectness {
  all e: DeletionLogEntry, op: Operation |
    (op.kind = DeleteTaskKind and op.succeeded = True
     and op.target = e.deletedTaskId)
      implies e.deleter = op.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.created_by NOT NULL; assignee NULLABLE single
pred OwnershipExclusivity {
  all t: Task | one t.creator
  all t: Task | lone t.assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005, FR-006; data-model.md CHECK constraints
pred ValidationBeforeMutation {
  all t: Task | t.titleValid = True and t.descValid = True
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// =======================================================================
// FEATURE-SPECIFIC FR-NNN PREDICATES + ASSERTIONS
// =======================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth required on every endpoint)
pred FR_001_AuthRequired {
  all op: Operation | op.succeeded = True implies op.authenticated = True
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (identity from auth context, not payload)
pred FR_002_IdentityFromContext {
  all op: Operation |
    (op.kind = CreateTaskKind and op.succeeded = True and some op.target)
      implies op.target.creator = op.caller
}
assert FR_002_IdentityFromContext { FR_002_IdentityFromContext }
check FR_002_IdentityFromContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (single implicit workspace; no Team entity)
pred FR_003_SingleWorkspace {
  one Role
  // All tasks are addressable by every member — surrogate: view perm is global
  MemberRole -> ViewTaskKind in PermMatrix.Allowed
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (flat permissions — every member can do everything)
pred FR_004_FlatPermissions {
  all r: Role, k: OperationKind | r -> k in PermMatrix.Allowed
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (title 1..200 after trim)
pred FR_005_TitleLength {
  all t: Task | t.titleValid = True
}
assert FR_005_TitleLength { FR_005_TitleLength }
check FR_005_TitleLength for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (description 0..4000)
pred FR_006_DescriptionLength {
  all t: Task | t.descValid = True
}
assert FR_006_DescriptionLength { FR_006_DescriptionLength }
check FR_006_DescriptionLength for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (due_date and assignee optional — modelled as `lone`)
pred FR_007_AssigneeOptional {
  all t: Task | lone t.assignee
}
assert FR_007_AssigneeOptional { FR_007_AssigneeOptional }
check FR_007_AssigneeOptional for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 (assignee, if set, is a real Member)
pred FR_008_AssigneeIsMember {
  all t: Task | t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (creator + created_at recorded, immutable single)
pred FR_009_CreatorRecorded {
  all t: Task | (one t.creator and one t.createdAt)
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 (status from the three-value set)
pred FR_010_StatusInSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusInSet { FR_010_StatusInSet }
check FR_010_StatusInSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 (closed-task edit rule)
pred FR_011_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditTaskKind and op.succeeded = True
     and some op.target and op.target.status = Done)
      implies op.bodyReopens = True
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (deletion is permanent)
pred FR_012_PermanentDeletion {
  all disj op1, op2: Operation |
    (op1.kind = DeleteTaskKind and op1.succeeded = True
     and some op1.target and op2.target = op1.target)
      implies op2.succeeded = False
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (v1 manage scope is exactly the five op kinds)
pred FR_013_V1Scope {
  OperationKind = CreateTaskKind + ViewTaskKind + EditTaskKind
                + DeleteTaskKind + ChangeStatusKind
}
assert FR_013_V1Scope { FR_013_V1Scope }
check FR_013_V1Scope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (default list ordering: every task has updated_at)
pred FR_014_ListOrdering {
  all t: Task | one t.updatedAt
}
assert FR_014_ListOrdering { FR_014_ListOrdering }
check FR_014_ListOrdering for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (filter dimensions: status, assignee — both well-defined)
pred FR_015_Filtering {
  all t: Task | (one t.status and lone t.assignee)
}
assert FR_015_Filtering { FR_015_Filtering }
check FR_015_Filtering for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (clearing filters returns the full workspace view)
pred FR_016_ClearFilters {
  MemberRole -> ViewTaskKind in PermMatrix.Allowed
}
assert FR_016_ClearFilters { FR_016_ClearFilters }
check FR_016_ClearFilters for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (created_at + updated_at on every task)
pred FR_017_Timestamps {
  all t: Task | (one t.createdAt and one t.updatedAt)
}
assert FR_017_Timestamps { FR_017_Timestamps }
check FR_017_Timestamps for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 (operational deletion log — complete + append-only)
pred FR_018_DeletionLog {
  // completeness: every successful delete leaves a log entry
  all op: Operation |
    (op.kind = DeleteTaskKind and op.succeeded = True and some op.target)
      implies (some e: DeletionLogEntry | e.deletedTaskId = op.target)
  // append-only: no two entries reference the same deleted task
  all disj e1, e2: DeletionLogEntry | e1.deletedTaskId != e2.deletedTaskId
}
assert FR_018_DeletionLog { FR_018_DeletionLog }
check FR_018_DeletionLog for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_Misattribution { some op: Operation, e: DeletionLogEntry | op.kind = DeleteTaskKind and op.succeeded = True and op.target = e.deletedTaskId and e.deleter != op.caller }
