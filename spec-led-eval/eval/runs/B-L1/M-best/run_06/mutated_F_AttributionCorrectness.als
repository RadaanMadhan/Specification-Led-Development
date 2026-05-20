// === feature_model.als — Alloy model for Team Task Management (B-L1 / 006-task-management) ===
//
// Anchors:
//   spec.md FR-001 … FR-018 (Team Task Management)
//   data-model.md tasks / task_deletions schema
//   contracts/http-api.md POST /tasks, GET /tasks, GET /tasks/{id},
//                         PATCH /tasks/{id}, DELETE /tasks/{id}
//
// The feature is a flat-peer task manager: every authenticated user is a
// workspace member, every member has the same permissions on every task,
// and deletions are recorded append-only in an operational log.

// --- Static enumerations -----------------------------------------------------

abstract sig AuthState {}
one sig Authenticated, Unauthenticated extends AuthState {}

abstract sig Outcome {}
one sig Accepted, Rejected extends Outcome {}

abstract sig OperationKind {}
one sig CreateTask, ReadTask, EditTask, DeleteTask extends OperationKind {}

abstract sig Status {}
one sig Todo, InProgress, Done extends Status {}

// --- Domain entities ---------------------------------------------------------

sig Member {}

sig Token {
  tokUser: one Member
}

sig Title {}
sig DueDate {}
sig Time {}

sig Task {
  title:       lone Title,
  dueDate:     lone DueDate,
  creator:     lone Member,
  assignee:    lone Member,
  status:      lone Status,
  createdAt:   lone Time,
  updatedAt:   lone Time
}

// An HTTP call against the task service. The fields capture
//   - which endpoint kind (CreateTask / ReadTask / EditTask / DeleteTask)
//   - whether the caller presented valid auth
//   - which Member the auth resolved to (or none for unauth)
//   - which Task is targeted (none for CreateTask/ReadTask-of-list)
//   - the resulting outcome (Accepted/Rejected)
//   - for EditTask: the new status the request is asking to set (if any).
sig Operation {
  kind:      one OperationKind,
  auth:      one AuthState,
  actor:     lone Member,
  target:    lone Task,
  outcome:   one Outcome,
  newStatus: lone Status
}

// Append-only operational deletion log — the task_deletions table.
sig DeletionLog {
  forOp:         one Operation,
  deleter:       one Member,
  recordedTitle: one Title
}

// --- Non-empty universe ------------------------------------------------------

fact F_NonEmptyUniverse {
  some Member
  some Token
  some Title
  some Time
  some Task
  some Operation
  some DeletionLog
}

// --- Token resolution (FR-002, FR-003) ---------------------------------------

fact F_TokenResolves {
  all t: Token | one t.tokUser
}

// --- Authentication boundary (FR-001) ----------------------------------------

fact F_AuthBoundary {
  all op: Operation | op.auth = Unauthenticated implies op.outcome = Rejected
}

fact F_AuthHasActor {
  all op: Operation | op.auth = Authenticated   implies one op.actor
  all op: Operation | op.auth = Unauthenticated implies no  op.actor
}

// --- Identity comes from a valid token (FR-002) ------------------------------

fact F_IdentityFromToken {
  all op: Operation | op.auth = Authenticated implies
    (some t: Token | t.tokUser = op.actor)
}

// --- Flat permissions / single workspace (FR-003, FR-004) --------------------

// Outcome of an authenticated call must depend only on (kind, target,
// newStatus) — never on actor identity. This is the structural form of
// "flat peers": no role, no admin tier, no creator-only path.
fact F_FlatPermissions {
  all disj op1, op2: Operation |
    (op1.auth = Authenticated and op2.auth = Authenticated and
     op1.kind = op2.kind and op1.target = op2.target and
     op1.newStatus = op2.newStatus)
    implies op1.outcome = op2.outcome
}

// --- Task shape (FR-005 … FR-010, FR-017) ------------------------------------

fact F_TaskTitleRequired       { all t: Task | one t.title }
fact F_TaskCreatorRequired     { all t: Task | one t.creator }
fact F_TaskStatusRequired      { all t: Task | one t.status }
fact F_TaskTimestampsRequired  {
  all t: Task | one t.createdAt
  all t: Task | one t.updatedAt
}
fact F_TaskAssigneeAtMostOne   { all t: Task | lone t.assignee }
fact F_TaskDueDateOptional     { all t: Task | lone t.dueDate }

// --- Closed-task PATCH rule (FR-011) -----------------------------------------

fact F_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditTask and op.outcome = Accepted and
     some op.target and op.target.status = Done)
    implies op.newStatus in (Todo + InProgress)
}

// newStatus is meaningful only on EditTask operations.
fact F_NewStatusScopedToEdit {
  all op: Operation | some op.newStatus implies op.kind = EditTask
}

// --- v1 manage scope (FR-013) ------------------------------------------------

fact F_ScopeFourKinds {
  OperationKind = CreateTask + ReadTask + EditTask + DeleteTask
}

// --- Deletion log (FR-012, FR-018) -------------------------------------------

// AuditCompleteness: every Accepted DeleteTask has exactly one log row.
fact F_AuditCompleteness {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Accepted) implies
      (one log: DeletionLog | log.forOp = op)
}

// Only Accepted DeleteTask operations have log rows.
fact F_DeletionLogsAreForAcceptedDeletes {
  all log: DeletionLog |
    log.forOp.kind = DeleteTask and log.forOp.outcome = Accepted
}

// AppendOnly: log rows are immutable — at most one log per operation.
fact F_AppendOnlyDeletionLog {
  all disj l1, l2: DeletionLog | l1.forOp != l2.forOp
}

// AttributionCorrectness: the log's deleter is the operation's actor.
fact F_AttributionCorrectness { /* MUTATED — body cleared by validator */ }

// =============================================================================
//                            PATTERN-BASED ASSERTIONS
// =============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all op: Operation | op.auth = Unauthenticated implies op.outcome = Rejected
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions
pred AuditCompleteness {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Accepted) implies
      (one log: DeletionLog | log.forOp = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on task_deletions"
pred AppendOnly {
  all disj l1, l2: DeletionLog | l1.forOp != l2.forOp
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018 (deleter identity recorded)
pred AttributionCorrectness {
  all log: DeletionLog | log.deleter = log.forOp.actor
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: PermissionCompleteness  ANCHOR: spec.md FR-004 flat peers
pred PermissionCompleteness {
  all disj op1, op2: Operation |
    (op1.auth = Authenticated and op2.auth = Authenticated and
     op1.kind = op2.kind and op1.target = op2.target and
     op1.newStatus = op2.newStatus)
    implies op1.outcome = op2.outcome
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md created_by NOT NULL FK; spec.md FR-009
pred OwnershipExclusivity {
  all t: Task | one t.creator
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001/FR-011 (reject before side-effect)
pred ValidationBeforeMutation {
  all op: Operation |
    op.outcome = Rejected implies (no log: DeletionLog | log.forOp = op)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// =============================================================================
//                          FUNCTIONAL-REQUIREMENT ASSERTIONS
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — every request authenticated before any logic
pred FR_001_AuthRequired {
  all op: Operation | op.auth = Unauthenticated implies op.outcome = Rejected
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — identity from auth context (token), not payload
pred FR_002_IdentityFromAuth {
  all op: Operation | op.auth = Authenticated implies
    (one op.actor and (some t: Token | t.tokUser = op.actor))
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — single implicit workspace; every authed actor is a Member
pred FR_003_SingleWorkspace {
  all op: Operation | op.auth = Authenticated implies op.actor in Member
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — flat peer permissions
pred FR_004_FlatPermissions {
  all disj op1, op2: Operation |
    (op1.auth = Authenticated and op2.auth = Authenticated and
     op1.kind = op2.kind and op1.target = op2.target and
     op1.newStatus = op2.newStatus)
    implies op1.outcome = op2.outcome
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — title is required and present on every task
pred FR_005_TitleRequired {
  all t: Task | one t.title
}
assert FR_005_TitleRequired { FR_005_TitleRequired }
check FR_005_TitleRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 — task is well-formed (title + status + creator present)
pred FR_006_DescriptionStored {
  // Description text is opaque in Alloy; we capture the structural sibling:
  // every task is well-formed (title, status, creator), so description-bearing
  // tasks aren't half-formed records.
  all t: Task | one t.title and one t.status and one t.creator
}
assert FR_006_DescriptionStored { FR_006_DescriptionStored }
check FR_006_DescriptionStored for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 — due date optional, past allowed
pred FR_007_DueDateOptional {
  all t: Task | lone t.dueDate
}
assert FR_007_DueDateOptional { FR_007_DueDateOptional }
check FR_007_DueDateOptional for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 — at most one assignee, who must be a Member
pred FR_008_AssigneeIsMember {
  all t: Task | lone t.assignee
  all t: Task | t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — creator and created_at recorded on creation
pred FR_009_CreatorRecorded {
  all t: Task | one t.creator and one t.createdAt
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — status drawn from {todo, in_progress, done}
pred FR_010_StatusInSet {
  all t: Task | one t.status
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusInSet { FR_010_StatusInSet }
check FR_010_StatusInSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — closed-task edit only if simultaneously reopened
pred FR_011_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = EditTask and op.outcome = Accepted and
     some op.target and op.target.status = Done)
    implies op.newStatus in (Todo + InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — deletion is permanent; recorded in op log
pred FR_012_PermanentDeletion {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Accepted) implies
      (one log: DeletionLog | log.forOp = op)
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — v1 manage scope = exactly four operation kinds
pred FR_013_ScopeFourKinds {
  OperationKind = CreateTask + ReadTask + EditTask + DeleteTask
}
assert FR_013_ScopeFourKinds { FR_013_ScopeFourKinds }
check FR_013_ScopeFourKinds for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 — no per-member visibility differences on Read
pred FR_014_NoPerMemberVisibility {
  // Two authenticated reads of the same task must agree on outcome — there is
  // no per-member visibility filter to make one fail and another succeed.
  all disj op1, op2: Operation |
    (op1.kind = ReadTask and op2.kind = ReadTask and
     op1.auth = Authenticated and op2.auth = Authenticated and
     op1.target = op2.target)
    implies op1.outcome = op2.outcome
}
assert FR_014_NoPerMemberVisibility { FR_014_NoPerMemberVisibility }
check FR_014_NoPerMemberVisibility for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — filter combinations are deterministic (AND)
pred FR_015_FilterAnd {
  // Same structural shadow as FR-014: outcome of a read of a given target
  // does not vary by actor.
  all disj op1, op2: Operation |
    (op1.kind = ReadTask and op2.kind = ReadTask and
     op1.auth = Authenticated and op2.auth = Authenticated and
     op1.target = op2.target)
    implies op1.outcome = op2.outcome
}
assert FR_015_FilterAnd { FR_015_FilterAnd }
check FR_015_FilterAnd for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 — clear filters returns to default unfiltered view
pred FR_016_ClearFilters {
  // The same caller reading the same target deterministically gets the same
  // outcome whether filters are present or absent.
  all disj op1, op2: Operation |
    (op1.kind = ReadTask and op2.kind = ReadTask and
     op1.auth = Authenticated and op2.auth = Authenticated and
     op1.target = op2.target and op1.actor = op2.actor)
    implies op1.outcome = op2.outcome
}
assert FR_016_ClearFilters { FR_016_ClearFilters }
check FR_016_ClearFilters for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — every task carries created_at and updated_at
pred FR_017_Timestamps {
  all t: Task | one t.createdAt and one t.updatedAt
}
assert FR_017_Timestamps { FR_017_Timestamps }
check FR_017_Timestamps for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — deletion log records deleter + task + timestamp
pred FR_018_DeletionLog {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Accepted) implies
      (one log: DeletionLog | log.forOp = op and log.deleter = op.actor)
}
assert FR_018_DeletionLog { FR_018_DeletionLog }
check FR_018_DeletionLog for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_Misattribution { some log: DeletionLog | log.deleter != log.forOp.actor }
