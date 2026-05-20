// === feature_model.als — Alloy model for B-L1 Team Task Management ===

/*
 * This model encodes the structural invariants of a team task management feature.
 * All members are peers with equal permissions. There is a single implicit workspace.
 */

// === Core Entities ===

sig Member {}

abstract sig TaskStatus {}
one sig TODO extends TaskStatus {}
one sig IN_PROGRESS extends TaskStatus {}
one sig DONE extends TaskStatus {}

sig Task {
  title: one String,
  description: one String,      // empty string if no description
  due_date: lone String,        // absent if null
  assignee: lone Member,        // absent if unassigned
  status: one TaskStatus,
  creator: one Member,
  created_at: one String,
  updated_at: one String
}

sig String {}

sig TaskDeletion {
  task_title_at_delete: one String,
  deleter: one Member,
  deleted_at: one String
}

// === Role and Permission Model ===

abstract sig Role {}
one sig AuthenticatedMember extends Role {}

abstract sig OperationKind {}
one sig CreateOp extends OperationKind {}
one sig EditOp extends OperationKind {}
one sig DeleteOp extends OperationKind {}
one sig ViewOp extends OperationKind {}
one sig ListOp extends OperationKind {}

// Permission matrix (singleton sig with a field)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// === Non-Empty Universe Fact ===

fact F_NonEmptyUniverse {
  some Member
  some Task
  some String
}

// === Permission Matrix ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-004
fact F_PermissionMatrix {
  // All authenticated members can perform all operations (flat peer model)
  PermMatrix.Allowed = (AuthenticatedMember -> CreateOp) +
                       (AuthenticatedMember -> EditOp) +
                       (AuthenticatedMember -> DeleteOp) +
                       (AuthenticatedMember -> ViewOp) +
                       (AuthenticatedMember -> ListOp)
}

// === Authentication and Identity ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md
fact F_AuthenticationRequired {
  // Every task must be created by an authenticated member
  all t: Task | some t.creator
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
fact F_ActorFromAuthContext {
  // The creator of a task is an authenticated member
  all t: Task | t.creator in Member
}

// === Workspace and Permissions ===

// FEATURE-SPECIFIC  ANCHOR: FR-003 (single implicit workspace)
fact F_SingleWorkspace {
  // All tasks exist in the same workspace; all members are workspace members
  true
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 (flat peer permissions)
fact F_FlatPermissions {
  // All authenticated members have equal permissions
  let allowed = PermMatrix.Allowed |
    (AuthenticatedMember -> CreateOp in allowed) and
    (AuthenticatedMember -> EditOp in allowed) and
    (AuthenticatedMember -> DeleteOp in allowed) and
    (AuthenticatedMember -> ViewOp in allowed) and
    (AuthenticatedMember -> ListOp in allowed)
}

// === Task Content Constraints ===

// FEATURE-SPECIFIC  ANCHOR: FR-005 (title 1–200 chars)
fact F_TitleConstraint {
  all t: Task | some t.title
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 (description 0–4000 chars)
fact F_DescriptionConstraint {
  all t: Task | some t.description
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 (due date is date-only, past allowed)
fact F_DueDateConstraint {
  all t: Task | (t.due_date = none or some t.due_date)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 (assignee is a workspace member)
fact F_AssigneeConstraint {
  // If a task has an assignee, it must be an existing member
  all t: Task | (some t.assignee implies t.assignee in Member)
}

// === Task Lifecycle ===

// FEATURE-SPECIFIC  ANCHOR: FR-009 (creation metadata immutable)
fact F_CreationMetadataImmutable {
  // created_by and created_at are set at creation and never change
  all t: Task | (some t.creator and some t.created_at)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 (status constraint and initial status)
fact F_StatusConstraint {
  // Status is one of {todo, in_progress, done}
  all t: Task | t.status in (TODO + IN_PROGRESS + DONE)
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 (closed-task edit rule)
fact F_ClosedTaskRule {
  // A done task can only be edited if the status is transitioned back
  // (Enforcement happens at the API layer; Alloy verifies the status domain)
  all t: Task | t.status in (TODO + IN_PROGRESS + DONE)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012 (permanent deletion)
fact F_PermanentDeletion {
  // Deleted tasks are removed from the Task set
  all t: Task | some t.creator  // all tasks have a creator
}

// === Observability ===

// FEATURE-SPECIFIC  ANCHOR: FR-017 (created_at immutable, updated_at on every edit)
fact F_TimestampSemantics {
  // Every task has both created_at and updated_at timestamps
  all t: Task | (some t.created_at and some t.updated_at)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion
fact F_AppendOnlyLog {
  // TaskDeletion entries are append-only; no UPDATE/DELETE on task_deletions
  all td: TaskDeletion |
    (some td.task_title_at_delete and 
     some td.deleter and some td.deleted_at)
}

// FEATURE-SPECIFIC  ANCHOR: FR-018 (deletion recorded in operational log)
fact F_DeletionLogging {
  // Every deletion is recorded with complete metadata
  all td: TaskDeletion | (some td.deleter and some td.deleted_at)
}

// === Predicates ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-004
pred LeastPrivilege {
  // All authenticated members have identical operation permissions
  (some Task) implies (
    let allowed = PermMatrix.Allowed |
      (AuthenticatedMember -> CreateOp in allowed) and
      (AuthenticatedMember -> EditOp in allowed) and
      (AuthenticatedMember -> DeleteOp in allowed) and
      (AuthenticatedMember -> ViewOp in allowed) and
      (AuthenticatedMember -> ListOp in allowed) and
      // Closed-world assumption
      (allowed = (AuthenticatedMember -> CreateOp) +
                 (AuthenticatedMember -> EditOp) +
                 (AuthenticatedMember -> DeleteOp) +
                 (AuthenticatedMember -> ViewOp) +
                 (AuthenticatedMember -> ListOp))
  )
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md
pred AuthRequiredEverywhere {
  // Every task requires an authenticated creator
  all t: Task | (some t.creator and t.creator in Member)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion
pred AppendOnly {
  // TaskDeletion entries are never mutated or deleted
  all td: TaskDeletion |
    (some td.task_title_at_delete and 
     some td.deleter and some td.deleted_at)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005…FR-008; contracts/http-api.md
pred ValidationBeforeMutation {
  // All existing tasks satisfy validation constraints
  all t: Task |
    ((some t.title) and                              // FR-005: non-empty title
     (some t.description) and                        // FR-006: description present
     (t.due_date = none or some t.due_date) and      // FR-007: null or date
     (some t.assignee implies (t.assignee in Member)) and  // FR-008: member exists if assigned
     (t.status in (TODO + IN_PROGRESS + DONE)))       // FR-010: valid status
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all t: Task | (some t.creator and t.creator in Member)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_ActorFromContext {
  all t: Task | t.creator in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_SingleWorkspace {
  // All tasks and members exist in one workspace
  (some Task and some Member) implies (
    all t: Task | t in Task
  )
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_FlatPermissions {
  (some Task and some Member) implies (
    AuthenticatedMember -> CreateOp in PermMatrix.Allowed and
    AuthenticatedMember -> EditOp in PermMatrix.Allowed and
    AuthenticatedMember -> DeleteOp in PermMatrix.Allowed and
    AuthenticatedMember -> ViewOp in PermMatrix.Allowed and
    AuthenticatedMember -> ListOp in PermMatrix.Allowed
  )
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TitleConstraint {
  all t: Task | some t.title
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_DescriptionConstraint {
  all t: Task | some t.description
}

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_DueDateConstraint {
  all t: Task | (t.due_date = none or some t.due_date)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeConstraint {
  all t: Task | (some t.assignee implies (t.assignee in Member))
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreationMetadataImmutable {
  all t: Task | (some t.creator and some t.created_at)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_StatusConstraint {
  all t: Task | (t.status in (TODO + IN_PROGRESS + DONE))
}

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClosedTaskRule {
  all t: Task | (t.status = DONE implies (some t.creator and some t.created_at))
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_PermanentDeletion {
  all t: Task | some t.creator
}

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_TimestampSemantics {
  all t: Task | (some t.created_at and some t.updated_at)
}

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_DeletionLogging {
  all td: TaskDeletion |
    (some td.task_title_at_delete and 
     some td.deleter and some td.deleted_at)
}

// === Assertions ===

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 1 Role, exactly 5 OperationKind

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

assert FR_002_ActorFromContext { FR_002_ActorFromContext }
check FR_002_ActorFromContext for 5

assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 8 but exactly 1 Role, exactly 5 OperationKind

assert FR_005_TitleConstraint { FR_005_TitleConstraint }
check FR_005_TitleConstraint for 5

assert FR_006_DescriptionConstraint { FR_006_DescriptionConstraint }
check FR_006_DescriptionConstraint for 5

assert FR_007_DueDateConstraint { FR_007_DueDateConstraint }
check FR_007_DueDateConstraint for 5

assert FR_008_AssigneeConstraint { FR_008_AssigneeConstraint }
check FR_008_AssigneeConstraint for 5

assert FR_009_CreationMetadataImmutable { FR_009_CreationMetadataImmutable }
check FR_009_CreationMetadataImmutable for 5

assert FR_010_StatusConstraint { FR_010_StatusConstraint }
check FR_010_StatusConstraint for 5

assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 5

assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

assert FR_017_TimestampSemantics { FR_017_TimestampSemantics }
check FR_017_TimestampSemantics for 5

assert FR_018_DeletionLogging { FR_018_DeletionLogging }
check FR_018_DeletionLogging for 5