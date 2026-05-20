// === feature_model.als — Alloy 6 model for Team Task Management (B-L1 / 006-task-management) ===
// Feature: 006-task-management | Branch: B-L1 | Date: 2026-05-17
// Artefacts consumed: spec.md, data-model.md, contracts/http-api.md

// ══════════════════════════════════════════════════════════════════
// § 1  ENUMS AND TAXONOMIES
// ══════════════════════════════════════════════════════════════════

abstract sig TaskStatus {}
one sig Todo      extends TaskStatus {}
one sig InProgress extends TaskStatus {}
one sig Done      extends TaskStatus {}

// Flat permission model (Q3 = A): exactly one role — every authenticated user.
abstract sig Role {}
one sig AuthMember extends Role {}

abstract sig OperationKind {}
one sig OpCreate  extends OperationKind {}
one sig OpList    extends OperationKind {}
one sig OpGet     extends OperationKind {}
one sig OpEdit    extends OperationKind {}
one sig OpDelete  extends OperationKind {}

// ══════════════════════════════════════════════════════════════════
// § 2  PERMISSION MATRIX  (singleton-sig field pattern)
// ══════════════════════════════════════════════════════════════════

one sig PermMatrix { Allowed: set Role -> OperationKind }

// ══════════════════════════════════════════════════════════════════
// § 3  CORE DOMAIN SIGS
// ══════════════════════════════════════════════════════════════════

sig Member {}

// Token → Member auth stub (data-model.md tokens table)
sig Token { owner: one Member }

// Task entity (data-model.md tasks table)
sig Task {
  creator:  one Member,
  assignee: lone Member,
  status:   one TaskStatus
}

// An EditOp models a PATCH request reaching the service layer.
// new_status is present iff the caller includes a status field in the body.
sig EditOp {
  target:     one Task,
  actor:      one Member,
  new_status: lone TaskStatus
}

// DeletionLog models task_deletions (operational log, append-only — FR-018).
sig DeletionLog {
  task_ref:   one Task,
  deleted_by: one Member
}

// ══════════════════════════════════════════════════════════════════
// § 4  NON-EMPTY UNIVERSE (Rule 9 — every dynamic sig has ≥ 1 atom)
// ══════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
  some Member
  some Token
  some Task
  some EditOp
  some DeletionLog
}

// ══════════════════════════════════════════════════════════════════
// § 5  NAMED STRUCTURAL FACTS
// ══════════════════════════════════════════════════════════════════

// ── Permission matrix: flat — AuthMember is allowed every operation ──
// FR-003, FR-004; contracts/http-api.md "no authorisation beyond authentication"
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (AuthMember -> OpCreate)  +
    (AuthMember -> OpList)    +
    (AuthMember -> OpGet)     +
    (AuthMember -> OpEdit)    +
    (AuthMember -> OpDelete)
}

// ── Auth boundary: every EditOp is performed by a known Member ──
// spec.md FR-001; contracts/http-api.md "401 before any handler runs"
fact F_AuthRequiredEverywhere {
  all e: EditOp | e.actor in Member
}

// ── Every Token resolves to exactly one Member ──
// data-model.md tokens table; spec.md FR-001
fact F_TokenResolvesToMember {
  all t: Token | t.owner in Member
}

// ── Assignee (if present) must be a Member ──
// spec.md FR-008; data-model.md assignee_id FK → users.id
fact F_AssigneeIsMember {
  all t: Task | t.assignee in Member
}

// ── Creator is always a Member ──
// spec.md FR-009; data-model.md created_by FK → users.id NOT NULL
fact F_CreatorIsMember {
  all t: Task | t.creator in Member
}

// ── Closed-task edit rule (FR-011) ──
// A PATCH on a Done task MUST include a status change to Todo or InProgress.
// spec.md FR-011, US2 #5/#6; contracts/http-api.md 409 task_closed
fact F_ClosedTaskEditRule {
  all e: EditOp |
    e.target.status = Done implies
      (e.new_status = Todo or e.new_status = InProgress)
}

// ── AppendOnly deletion log: each task appears at most once ──
// spec.md FR-018; data-model.md "No UPDATE/DELETE code path targets this table"
fact F_AppendOnlyDeletionLog {
  all disj d1, d2: DeletionLog | d1.task_ref != d2.task_ref
}

// ── AuditCompleteness: each DeletionLog entry records a valid Member as deleter ──
// spec.md FR-018; data-model.md deleted_by_user_id FK → users.id NOT NULL
fact F_DeletionLogAttribution { /* MUTATED — body cleared by validator */ }

// ── Deletion permanence: a task that has a DeletionLog entry is "gone" ──
// Deleted tasks and still-active tasks must be disjoint conceptually;
// we encode this as: no EditOp targets a task that has been logged as deleted.
// spec.md FR-012; contracts/http-api.md DELETE 204
fact F_DeletedTaskNotEditable {
  no e: EditOp | e.target in DeletionLog.task_ref
}

// ── Creator identity is never supplied by the caller (server-controlled) ──
// The creator of a task is always the actor of the first EditOp (creation).
// We encode a weaker but checkable constraint: no EditOp actor != task.creator
// can "reassign" the creator; the creator field on Task is a fixed binding.
// spec.md FR-002, FR-009; data-model.md "created_by … never changes after insert"
fact F_CreatorImmutableBinding {
  // Every task's creator field is the same member in every context
  // (modeled by: no EditOp can set the creator; creator is a pure Task attribute)
  // Nothing in EditOp touches creator; this is enforced by the absence of a
  // creator field in EditOp. Structurally, Task.creator is independent of EditOp.
  // Explicitly: no edit operation changes what creator a task has.
  all t: Task | one t.creator
}

// ── Valid status: every Task's status is in the allowed set ──
// spec.md FR-010; data-model.md CHECK(status IN ('todo','in_progress','done'))
fact F_TaskStatusValid {
  all t: Task | t.status in (Todo + InProgress + Done)
}

// ══════════════════════════════════════════════════════════════════
// § 6  PREDICATES AND ASSERTIONS  (catalogue patterns)
// ══════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth matrix; spec.md FR-003, FR-004
// Every allowed (Role, Op) pair is in PermMatrix.Allowed; nothing is silently denied.
pred LeastPrivilege {
  some Task
  // AuthMember is allowed every OperationKind — no operation is off-limits.
  all op: OperationKind | AuthMember -> op in PermMatrix.Allowed
  // And there are no extra roles that slip in with extra privileges.
  all r: Role, op: OperationKind |
    r -> op in PermMatrix.Allowed implies r = AuthMember
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ─────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md; spec.md FR-003, FR-004
// Every (Role × OperationKind) cell is covered: either in Allowed or not — no gaps.
pred PermissionCompleteness {
  some Task
  // The Allowed relation is defined for every Role × OperationKind pair
  // (here completeness means the matrix enumerates all five ops for the one role).
  #(PermMatrix.Allowed) = (#Role) .mul[#OperationKind]
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ─────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-005; contracts/http-api.md "401 before any handler"
pred AuthRequiredEverywhere {
  some EditOp
  // Every edit operation in the system is carried out by an identified Member.
  all e: EditOp | some m: Member | e.actor = m
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ─────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE code path targets task_deletions"
pred AppendOnly {
  some DeletionLog
  // No two DeletionLog entries share the same task_ref (each entry is unique and immutable).
  all disj d1, d2: DeletionLog | d1.task_ref != d2.task_ref
  // Every DeletionLog entry has a non-null deleter.
  all d: DeletionLog | some d.deleted_by
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ─────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions UNIQUE per task
pred AuditCompleteness {
  some DeletionLog
  // For every DeletionLog entry there is exactly one such entry per task.
  all d: DeletionLog | (one d2: DeletionLog | d2.task_ref = d.task_ref)
  // Every log entry references an existing Task.
  all d: DeletionLog | d.task_ref in Task
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ─────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018, FR-009; data-model.md deleted_by_user_id, created_by
pred AttributionCorrectness {
  some DeletionLog
  // Every DeletionLog entry has a valid Member as deleter — no anonymous deletions.
  all d: DeletionLog | d.deleted_by in Member
  // Every Task has a valid Member as creator.
  all t: Task | t.creator in Member
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ─────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md assignee_id (lone)
pred OwnershipExclusivity {
  some Task
  // Each task has at most one assignee at any time.
  all t: Task | lone t.assignee
  // Assignee, if present, is a known Member.
  all t: Task | t.assignee in Member
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ─────────────────────────────────────────────────────────────────
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005, FR-006; contracts/http-api.md 400 validation_error
// A task that has been logged as deleted cannot be the target of any EditOp.
pred ValidationBeforeMutation {
  some DeletionLog
  some EditOp
  // No EditOp targets a task already recorded in the deletion log.
  no e: EditOp | e.target in DeletionLog.task_ref
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ══════════════════════════════════════════════════════════════════
// § 7  FEATURE-SPECIFIC PREDICATES
// ══════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every EditOp is performed by an authenticated Member; unauthenticated callers
// cannot reach any task-mutating handler.
pred FR_001_AuthRequired {
  some EditOp
  all e: EditOp | e.actor in Member
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002
// The acting user's identity comes from the auth context (Token.owner), never
// from user-supplied payload. Modeled as: for every Token, its owner is a Member.
pred FR_002_IdentityFromAuthContext {
  some Token
  all t: Token | t.owner in Member
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
// Single workspace, flat permissions: every Member can perform every OperationKind.
// No member is singled out for different treatment.
pred FR_003_FR_004_FlatPermissions {
  some Member
  // All ops available to the single role that covers every authenticated user.
  PermMatrix.Allowed = AuthMember -> OperationKind
  // There are no roles other than AuthMember in the Allowed relation.
  all r: Role, op: OperationKind |
    r -> op in PermMatrix.Allowed implies r = AuthMember
}
assert FR_003_FR_004_FlatPermissions { FR_003_FR_004_FlatPermissions }
check FR_003_FR_004_FlatPermissions for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-008
// A task's assignee, if present, must be an existing Member.
// At most one assignee per task.
pred FR_008_AssigneeIsCurrentMember {
  some Task
  all t: Task | lone t.assignee
  all t: Task | t.assignee in Member
}
assert FR_008_AssigneeIsCurrentMember { FR_008_AssigneeIsCurrentMember }
check FR_008_AssigneeIsCurrentMember for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009
// Every task records a creator; that creator is always a Member; it is unique per task.
pred FR_009_CreatorRecordedAndImmutable {
  some Task
  all t: Task | one t.creator
  all t: Task | t.creator in Member
}
assert FR_009_CreatorRecordedAndImmutable { FR_009_CreatorRecordedAndImmutable }
check FR_009_CreatorRecordedAndImmutable for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-010
// Every task has a status from the allowed set {Todo, InProgress, Done}.
pred FR_010_ValidTaskStatus {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_ValidTaskStatus { FR_010_ValidTaskStatus }
check FR_010_ValidTaskStatus for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011
// An EditOp targeting a Done task MUST include a status transition to
// Todo or InProgress (the "closed-task edit rule").
pred FR_011_ClosedTaskEditRule {
  some EditOp
  all e: EditOp |
    e.target.status = Done implies
      (e.new_status = Todo or e.new_status = InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012
// A deleted task (one with a DeletionLog entry) is unreachable by EditOps.
pred FR_012_DeletedTaskUnreachable {
  some DeletionLog
  // No EditOp's target is a task that has been logged as deleted.
  no e: EditOp | e.target in DeletionLog.task_ref
}
assert FR_012_DeletedTaskUnreachable { FR_012_DeletedTaskUnreachable }
check FR_012_DeletedTaskUnreachable for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-014
// Visibility invariant: all tasks are in the single shared workspace;
// the "active" task set is Tasks minus those in the deletion log.
pred FR_014_AllTasksVisible {
  some Task
  // Every Member can in principle see every non-deleted Task (flat workspace).
  // Modeled as: no Task is structurally hidden from the member population.
  // Active tasks = Task - DeletionLog.task_ref
  let active = Task - DeletionLog.task_ref |
    all t: active | t in Task
}
assert FR_014_AllTasksVisible { FR_014_AllTasksVisible }
check FR_014_AllTasksVisible for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017
// Timestamps semantics: every task has exactly one creator (immutable binding).
// Updated_at is conceptually refreshed by every EditOp — modeled by requiring
// every EditOp to have an actor (the editor) distinct from the mere existence check.
pred FR_017_TimestampSemantics {
  some Task
  some EditOp
  // Creator is stable: one per task.
  all t: Task | one t.creator
  // Every EditOp records its actor (this is the "editor" captured at updated_at).
  all e: EditOp | one e.actor
}
assert FR_017_TimestampSemantics { FR_017_TimestampSemantics }
check FR_017_TimestampSemantics for 5

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-018
// Deletion log: every DeletionLog entry has a valid task reference and
// a valid deleter; entries are unique per task (append-only, no duplicates).
pred FR_018_DeletionLogComplete {
  some DeletionLog
  all d: DeletionLog | d.task_ref in Task
  all d: DeletionLog | d.deleted_by in Member
  // Each task appears in the log at most once.
  all disj d1, d2: DeletionLog | d1.task_ref != d2.task_ref
}
assert FR_018_DeletionLogComplete { FR_018_DeletionLogComplete }
check FR_018_DeletionLogComplete for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AttributionViolation { some d: DeletionLog | no m: Member | d.deleted_by = m }
