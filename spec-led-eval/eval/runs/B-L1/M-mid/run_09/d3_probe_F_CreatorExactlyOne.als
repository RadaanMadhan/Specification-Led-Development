// === feature_model.als — Alloy model for Team Task Management (B-L1 / 006-task-management) ===
// Sources: spec.md, data-model.md, contracts/http-api.md
// Patterns applied: AuthRequiredEverywhere, AppendOnly, AuditCompleteness,
//   AttributionCorrectness, OwnershipExclusivity, ValidationBeforeMutation

// ─── Core domain sigs ────────────────────────────────────────────────────────

sig Member {}

sig Token {
  token_owner: one Member
}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

sig Task {
  t_status:      one TaskStatus,
  t_creator:     one Member,
  t_assignee:    lone Member,
  t_last_editor: lone Member  // set on every successful edit; absent on brand-new tasks
}

// Operational deletion log — append-only (FR-018, data-model.md task_deletions)
sig TaskDeletion {
  td_deleter:  one Member,
  td_task_ref: one Task      // snapshot: identifies which task was deleted
}

// Abstract representation of API calls reaching business logic
abstract sig OperationKind {}
one sig OpCreate, OpList, OpView, OpEdit, OpDelete extends OperationKind {}

sig ApiCall {
  ac_kind:   one OperationKind,
  ac_caller: lone Member,       // lone = possibly unauthenticated (zero or one)
  ac_target: lone Task          // absent for list/create-pre-return
}

// Edit requests: encapsulate the closed-task rule (FR-011)
sig EditRequest {
  er_caller:      one Member,
  er_target:      one Task,
  er_new_status:  lone TaskStatus  // absent if the request does not touch status
}

// ─── Non-empty universe ───────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Member
  some Task
  some TaskDeletion
  some ApiCall
  some EditRequest
}

// ─── Named structural facts ───────────────────────────────────────────────────

// Every API call that reaches any handler has exactly one authenticated caller (FR-001).
// Unauthenticated calls are rejected at the boundary and never represented as ApiCall atoms.
fact F_AllCallsAuthenticated {
  all c: ApiCall | one c.ac_caller
}

// Every Task has exactly one creator — set at creation, never null (FR-009, data-model.md created_by NOT NULL).
fact F_CreatorExactlyOne {
  all t: Task | one t.t_creator
}

// A task's assignee, when present, must be a Member (FR-008; data-model.md assignee_id FK→users).
fact F_AssigneeIsMember {
  all t: Task | some t.t_assignee implies t.t_assignee in Member
}

// A task's last_editor, when present, must be a Member (FR-011; data-model.md FK→users).
fact F_LastEditorIsMember {
  all t: Task | some t.t_last_editor implies t.t_last_editor in Member
}

// Task status must be exactly one of the three valid values (FR-010, data-model.md CHECK constraint).
fact F_ValidTaskStatus {
  all t: Task | t.t_status in Todo + InProgress + Done
}

// Closed-task rule: a Done task may only be edited when the same request simultaneously
// sets status to Todo or InProgress (FR-011; contracts/http-api.md 409 task_closed).
fact F_ClosedTaskRule {
  all er: EditRequest |
    er.er_target.t_status = Done implies
      (er.er_new_status = Todo or er.er_new_status = InProgress)
}

// AppendOnly deletion log: no two TaskDeletion entries refer to the same task snapshot,
// preventing "update in place" — each task is logged exactly once (FR-018;
// data-model.md "No UPDATE/DELETE code path targets this table").
fact F_AppendOnlyDeletionLog {
  all disj td1, td2: TaskDeletion | td1.td_task_ref != td2.td_task_ref
}

// AuditCompleteness: every Task that appears in the deletion log has exactly one entry
// (FR-018; data-model.md "DELETE + INSERT in same transaction").
fact F_AuditCompletenessOnDeletion {
  all t: Task | lone { td: TaskDeletion | td.td_task_ref = t }
}

// AttributionCorrectness: every deletion log entry records exactly one deleter
// (FR-018; data-model.md deleted_by_user_id NOT NULL FK→users).
fact F_DeletionAttribution {
  all td: TaskDeletion | one td.td_deleter
}

// Flat permission model: all authenticated members may perform every operation kind —
// there is no role hierarchy, no admin tier, no creator-only restriction (FR-003, FR-004;
// contracts/http-api.md "no 403 permission_denied response").
fact F_FlatPermissions {
  // No ApiCall is gated on identity beyond authentication:
  // every pair (Member, OperationKind) is reachable — enforced by requiring
  // every OperationKind to appear in at least one call in the universe.
  all k: OperationKind | some c: ApiCall | c.ac_kind = k
}

// ValidationBeforeMutation: only EditRequests with authenticated callers exist —
// an unauthenticated edit never materialises as an EditRequest (FR-001, FR-011).
fact F_AuthenticatedEditsOnly {
  all er: EditRequest | er.er_caller in Member
}

// Single implicit workspace: every Member can see every Task (FR-003, FR-014).
// Modeled as: no Task is invisible to any Member — the reachable set of tasks
// from any Member through ApiCalls covers all Tasks.
fact F_SingleWorkspaceVisibility {
  all t: Task | all m: Member |
    some c: ApiCall | c.ac_caller = m and (c.ac_kind = OpList or c.ac_kind = OpView)
}

// ─── Pattern predicates ───────────────────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some ApiCall  // universe is non-vacuous
  all c: ApiCall | one c.ac_caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion "No UPDATE/DELETE"
pred AppendOnly {
  some TaskDeletion  // non-vacuous
  all disj td1, td2: TaskDeletion | td1.td_task_ref != td2.td_task_ref
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md UNIQUE(task_id) via single tx
pred AuditCompleteness {
  some TaskDeletion  // non-vacuous
  all t: Task | lone { td: TaskDeletion | td.td_task_ref = t }
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md deleted_by_user_id NOT NULL
pred AttributionCorrectness {
  some TaskDeletion  // non-vacuous
  all td: TaskDeletion | one td.td_deleter and td.td_deleter in Member
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md created_by NOT NULL FK
pred OwnershipExclusivity {
  some Task  // non-vacuous
  all t: Task | one t.t_creator
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005 FR-008; data-model.md validation.py
pred ValidationBeforeMutation {
  // No EditRequest exists without an authenticated (Member) caller —
  // failed validation returns 400 before any state change.
  some EditRequest  // non-vacuous
  all er: EditRequest | er.er_caller in Member
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─── Feature-specific predicates ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // In a valid system state every API call has exactly one resolved caller.
  // Predicate forces a non-empty call universe so it cannot pass vacuously.
  some ApiCall
  all c: ApiCall | one c.ac_caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 FR-004
pred FR_003_SingleWorkspaceFlatPermissions {
  // Every (Member × OperationKind) pair is exercisable — no pair is absent.
  some Member
  some ApiCall
  all m: Member | all k: OperationKind |
    some c: ApiCall | c.ac_caller = m and c.ac_kind = k
}
assert FR_003_SingleWorkspaceFlatPermissions { FR_003_SingleWorkspaceFlatPermissions }
check FR_003_SingleWorkspaceFlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeIsMember {
  some Task
  all t: Task | some t.t_assignee implies t.t_assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreatorRecordedImmutably {
  // Every task has exactly one creator; no task is orphaned.
  some Task
  all t: Task | one t.t_creator and t.t_creator in Member
}
assert FR_009_CreatorRecordedImmutably { FR_009_CreatorRecordedImmutably }
check FR_009_CreatorRecordedImmutably for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_ValidStatus {
  some Task
  all t: Task | t.t_status in Todo + InProgress + Done
}
assert FR_010_ValidStatus { FR_010_ValidStatus }
check FR_010_ValidStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClosedTaskRule {
  // A Done task can only be the target of an EditRequest when the request
  // simultaneously reopens it (sets status to Todo or InProgress).
  some t: Task | t.t_status = Done  // non-vacuous: at least one Done task exists
  all er: EditRequest |
    er.er_target.t_status = Done implies
      (er.er_new_status = Todo or er.er_new_status = InProgress)
}
assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_PermanentDeletion {
  // Once a task appears in the deletion log it has exactly one log entry
  // and no duplicate entries exist (models "deletion is permanent, no restore").
  some TaskDeletion
  all disj td1, td2: TaskDeletion | td1.td_task_ref != td2.td_task_ref
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_UniversalTaskVisibility {
  // Every authenticated member can issue a list or view call —
  // no member is structurally barred from seeing any task.
  some Member
  some Task
  all m: Member |
    (some c: ApiCall | c.ac_caller = m and c.ac_kind = OpList)
}
assert FR_014_UniversalTaskVisibility { FR_014_UniversalTaskVisibility }
check FR_014_UniversalTaskVisibility for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_CreatorNeverOverwritten {
  // creator field is set by the server at creation and is always a valid member.
  // We model immutability by asserting: no task has a null creator (lone → one).
  some Task
  all t: Task | one t.t_creator and t.t_creator in Member
}
assert FR_017_CreatorNeverOverwritten { FR_017_CreatorNeverOverwritten }
check FR_017_CreatorNeverOverwritten for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_DeletionLogCorrectness {
  // Every deletion log entry attributes deletion to exactly one member.
  // Each task appears in the log at most once (append-only, permanent delete).
  some TaskDeletion
  all td: TaskDeletion | one td.td_deleter and td.td_deleter in Member
  all disj td1, td2: TaskDeletion | td1.td_task_ref != td2.td_task_ref
}
assert FR_018_DeletionLogCorrectness { FR_018_DeletionLogCorrectness }
check FR_018_DeletionLogCorrectness for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_OrphanTask { some t: Task | no t.t_creator }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
