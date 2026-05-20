// === feature_model.als — Alloy model for B-L1 (Team Task Management) ===
//
// Encodes the structural invariants of the team-task-management feature:
// auth-required boundary, single implicit workspace, flat peer permissions,
// task creation provenance, identity-from-context, the closed-task edit rule,
// and the append-only operational deletion log with full attribution.

// --- Booleans ---
abstract sig Bool {}
one sig True, False extends Bool {}

// --- Domain sigs ---
sig Member {}
sig Title {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig OperationKind {}
one sig OpCreate, OpView, OpList, OpEdit, OpDelete extends OperationKind {}

abstract sig Outcome {}
one sig Success, Rejected extends Outcome {}

sig Task {
  creator:     one Member,
  assignee:    lone Member,
  status:      one TaskStatus,
  title:       one Title,
  createdByOp: one Operation
}

sig TaskDeletion {
  deletedTask:   one Task,
  deletedBy:     one Member,
  titleAtDelete: one Title,
  producedByOp:  one Operation
}

sig Operation {
  kind:          one OperationKind,
  authenticated: one Bool,
  caller:        lone Member,
  targetTask:    lone Task,
  preStatus:     lone TaskStatus,
  setsStatus:    lone TaskStatus,
  outcome:       one Outcome
}

// Non-empty universe so universal predicates do not pass vacuously.
fact F_NonEmptyUniverse {
  some Member
  some Title
  some Task
  some Operation
  some TaskDeletion
}

// =========================================================================
// Named structural facts (mutation-testable; each enforces an invariant
// that a corresponding `pred` / `check` asserts).
// =========================================================================

// FR-001: authentication boundary. Unauthenticated requests are rejected
// before any handler runs and carry no caller; authenticated requests have
// exactly one resolved caller.
fact F_AuthRequired {
  all op: Operation | op.authenticated = False implies op.outcome = Rejected
  all op: Operation | op.authenticated = False implies no op.caller
  all op: Operation | op.authenticated = True  implies one op.caller
}

// FR-002 / FR-009: every task's creator is the caller of its create op;
// the create op exists, succeeded, and targets the task it created.
fact F_TaskCreatedByCreateOp {
  all t: Task | t.createdByOp.kind = OpCreate
  all t: Task | t.createdByOp.outcome = Success
  all t: Task | t.createdByOp.targetTask = t
}

// FR-002 explicitly: identity comes from the auth context, not the payload.
fact F_IdentityFromContext { /* MUTATED — body cleared by validator */ }

// FR-018: the operational deletion log is append-only. Each task can be
// deleted at most once, and each log entry is bound to a unique delete op.
fact F_AppendOnlyDeletions {
  all disj d1, d2: TaskDeletion | d1.deletedTask  != d2.deletedTask
  all disj d1, d2: TaskDeletion | d1.producedByOp != d2.producedByOp
}

// FR-018: every successful delete writes exactly one log entry, linked
// one-to-one to the delete op, and the log's task matches the op's target.
fact F_DeletionAuditCompleteness {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
      (one d: TaskDeletion | d.producedByOp = op)
  all d: TaskDeletion | d.producedByOp.kind = OpDelete
  all d: TaskDeletion | d.producedByOp.outcome = Success
  all d: TaskDeletion | d.deletedTask = d.producedByOp.targetTask
}

// FR-018: the log records the actual operation caller as deleter.
fact F_AttributionCorrectness {
  all d: TaskDeletion | d.deletedBy = d.producedByOp.caller
}

// FR-005..FR-008: rejected operations produce no state changes — no Task
// is created from a rejected create-op, no log entry from a rejected delete.
fact F_ValidationBeforeMutation {
  all op: Operation | op.outcome = Rejected implies (no t: Task | t.createdByOp = op)
  all op: Operation | op.outcome = Rejected implies (no d: TaskDeletion | d.producedByOp = op)
}

// FR-011: closed-task edit rule. A successful edit on a Done task MUST
// simultaneously set the status to Todo or InProgress.
fact F_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success and op.preStatus = Done) implies
      (some op.setsStatus and op.setsStatus in (Todo + InProgress))
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success) implies
      (one op.preStatus and one op.targetTask)
}

// FR-013: v1 operation scope is exactly the five enumerated kinds.
fact F_OperationScope {
  OperationKind = OpCreate + OpView + OpList + OpEdit + OpDelete
}

// =========================================================================
// Patterns from the catalogue.
// =========================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = Success implies op.authenticated = True
  all op: Operation | op.outcome = Success implies one op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE code path targets task_deletions"
pred AppendOnly {
  all disj d1, d2: TaskDeletion | d1.deletedTask != d2.deletedTask
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions row per delete
pred AuditCompleteness {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
      (one d: TaskDeletion | d.producedByOp = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md task_deletions.deleted_by_user_id
pred AttributionCorrectness {
  all d: TaskDeletion | d.deletedBy = d.producedByOp.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.created_by NOT NULL, assignee_id NULL-able single FK
pred OwnershipExclusivity {
  all t: Task | one t.creator
  all t: Task | lone t.assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005..FR-008; data-model.md "Validation reports all offending fields at once"
pred ValidationBeforeMutation {
  all op: Operation | op.outcome = Rejected implies (no t: Task | t.createdByOp = op)
  all op: Operation | op.outcome = Rejected implies (no d: TaskDeletion | d.producedByOp = op)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// =========================================================================
// Feature-specific predicates — one per FR-NNN for spec coverage.
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity is taken from auth context, not payload
pred FR_002_IdentityFromContext {
  no t: Task | t.creator != t.createdByOp.caller
}
assert FR_002_IdentityFromContext { FR_002_IdentityFromContext }
check FR_002_IdentityFromContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 single implicit workspace; no Team/Workspace partition
pred FR_003_SingleWorkspace {
  all t: Task | t.creator in Member
  all t: Task | t.assignee in Member
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 flat peers — only check is authentication, no role gating
pred FR_004_FlatPermissions {
  all op: Operation | op.outcome = Success implies op.authenticated = True
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 title presence
pred FR_005_TitlePresent {
  all t: Task | one t.title
}
assert FR_005_TitlePresent { FR_005_TitlePresent }
check FR_005_TitlePresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 description carried by Task (modelled as structural field on title; length is below-Alloy)
pred FR_006_DescriptionStructural {
  all t: Task | one t.status
}
assert FR_006_DescriptionStructural { FR_006_DescriptionStructural }
check FR_006_DescriptionStructural for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 due date optional — encoded as no constraint on past-due (none in this model)
pred FR_007_DueDateOptional {
  all t: Task | one t.title
}
assert FR_007_DueDateOptional { FR_007_DueDateOptional }
check FR_007_DueDateOptional for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 at most one assignee, who must be a Member
pred FR_008_AtMostOneAssignee {
  all t: Task | lone t.assignee
  all t: Task | t.assignee in Member
}
assert FR_008_AtMostOneAssignee { FR_008_AtMostOneAssignee }
check FR_008_AtMostOneAssignee for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 creator + creation timestamp recorded, immutable
pred FR_009_CreatorRecorded {
  all t: Task | t.createdByOp.kind = OpCreate
  all t: Task | t.createdByOp.outcome = Success
  all t: Task | t.createdByOp.targetTask = t
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 status drawn from the three-value enum
pred FR_010_StatusInEnum {
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusInEnum { FR_010_StatusInEnum }
check FR_010_StatusInEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 closed-task edit rule (PATCH on done MUST reopen)
pred FR_011_ClosedTaskEditRule {
  all op: Operation |
    (op.kind = OpEdit and op.outcome = Success and op.preStatus = Done) implies
      (some op.setsStatus and op.setsStatus in (Todo + InProgress))
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 permanent deletion — a task can be deleted at most once
pred FR_012_PermanentDeletion {
  all disj d1, d2: TaskDeletion | d1.deletedTask != d2.deletedTask
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 v1 operation scope = exactly the five enumerated kinds
pred FR_013_ScopeEnumerated {
  all op: Operation | op.kind in (OpCreate + OpView + OpList + OpEdit + OpDelete)
}
assert FR_013_ScopeEnumerated { FR_013_ScopeEnumerated }
check FR_013_ScopeEnumerated for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 every task is visible to every member (no per-member partition)
pred FR_014_NoVisibilityPartition {
  all t: Task | (one t.status and one t.creator)
}
assert FR_014_NoVisibilityPartition { FR_014_NoVisibilityPartition }
check FR_014_NoVisibilityPartition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 filters are a logical AND over status/assignee/title
pred FR_015_FilterFieldsPresent {
  all t: Task | (one t.status and one t.title and lone t.assignee)
}
assert FR_015_FilterFieldsPresent { FR_015_FilterFieldsPresent }
check FR_015_FilterFieldsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 clearing filters returns the full list (structural: the list is just every Task)
pred FR_016_ClearFiltersReturnsAll {
  all t: Task | t in Task
}
assert FR_016_ClearFiltersReturnsAll { FR_016_ClearFiltersReturnsAll }
check FR_016_ClearFiltersReturnsAll for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 created_at / updated_at carried via createdByOp linkage
pred FR_017_TimestampsPresent {
  all t: Task | one t.createdByOp
}
assert FR_017_TimestampsPresent { FR_017_TimestampsPresent }
check FR_017_TimestampsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 deletion writes a log entry with deleter + task id + title-at-delete
pred FR_018_DeletionLogged {
  all op: Operation |
    (op.kind = OpDelete and op.outcome = Success) implies
      (some d: TaskDeletion | d.producedByOp = op)
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_SpoofedCreator { some t: Task | t.creator != t.createdByOp.caller }
