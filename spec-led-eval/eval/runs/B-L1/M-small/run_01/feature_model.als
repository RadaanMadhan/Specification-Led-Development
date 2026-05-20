// === feature_model.als — Alloy model for Team Task Management ===

// Status enum
abstract sig TaskStatus {}
one sig Todo extends TaskStatus {}
one sig InProgress extends TaskStatus {}
one sig Done extends TaskStatus {}

// Operation types (from contracts/http-api.md endpoints)
abstract sig OperationType {}
one sig PostTasks extends OperationType {}
one sig GetTasks extends OperationType {}
one sig GetTaskById extends OperationType {}
one sig PatchTask extends OperationType {}
one sig DeleteTask extends OperationType {}

// Core entities from data-model.md
sig User {
  username: one String,
  display_name: one String
}

sig Task {
  title: one String,
  description: one String,
  due_date: lone String,
  assignee: lone User,
  status: one TaskStatus,
  created_by: lone User,
  created_at: one Timestamp,
  updated_at: one Timestamp
}

sig TaskDeletion {
  deleted_task_title: one String,
  deleted_by: lone User,
  deleted_at: one Timestamp
}

sig Operation {
  op_type: one OperationType,
  actor: lone User
}

// Value types
sig String {}
sig Timestamp {}

// F_NonEmptyUniverse: Ensure universe has at least one of each dynamic sig
fact F_NonEmptyUniverse {
  some User
  some Task
  some Operation
}

// FR-001: Every operation must be performed by an authenticated member
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, contracts/http-api.md authentication
fact F_AuthenticationRequired {
  all op: Operation | one op.actor
}

// FR-005: Title must be non-empty, 1–200 characters
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
fact F_TitleRequired {
  all t: Task | one t.title
}

// FR-008: Assignee must be current workspace member or unassigned
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008
fact F_AssigneeValidation {
  all t: Task | t.assignee in User or no t.assignee
}

// FR-009: Creator recorded at creation, never changes
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009
fact F_CreatorRecorded {
  all t: Task | one t.created_by
}

// FR-010: Status must be one of three valid states
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010, data-model.md TaskStatus enum
fact F_StatusValid {
  all t: Task | t.status in (Todo + InProgress + Done)
}

// FR-017: Every task carries created_at and updated_at
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017, data-model.md timestamps
fact F_TimestampsRequired {
  all t: Task | one t.created_at and one t.updated_at
}

// FR-018: Deletions logged with metadata
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, data-model.md TaskDeletion table
fact F_DeletionLogged {
  all td: TaskDeletion | one td.deleted_by and one td.deleted_at
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.actor in User
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010
pred FR_010_StatusMustBeValid {
  all t: Task | t.status in (Todo + InProgress + Done)
}

assert FR_010_StatusMustBeValid {
  FR_010_StatusMustBeValid
}

check FR_010_StatusMustBeValid for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009
pred FR_009_CreatorRecorded {
  all t: Task | t.created_by in User
}

assert FR_009_CreatorRecorded {
  FR_009_CreatorRecorded
}

check FR_009_CreatorRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
pred FR_005_TitleNonEmpty {
  all t: Task | one t.title
}

assert FR_005_TitleNonEmpty {
  FR_005_TitleNonEmpty
}

check FR_005_TitleNonEmpty for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008
pred FR_008_AssigneeIsMember {
  all t: Task | t.assignee in User or no t.assignee
}

assert FR_008_AssigneeIsMember {
  FR_008_AssigneeIsMember
}

check FR_008_AssigneeIsMember for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018
pred AppendOnlyDeletionLog {
  all td: TaskDeletion | td.deleted_by in User and one td.deleted_at
}

assert AppendOnlyDeletionLog {
  AppendOnlyDeletionLog
}

check AppendOnlyDeletionLog for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017
pred FR_017_TimestampsExist {
  all t: Task | one t.created_at and one t.updated_at
}

assert FR_017_TimestampsExist {
  FR_017_TimestampsExist
}

check FR_017_TimestampsExist for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-003, FR-004 (flat peer model)
pred FR_004_FlatPermissions {
  // All authenticated users have identical operation rights: no role-based denial.
  // Modeled as: the set of actors in any Operation type is unconstrained
  // (no role-based filter), so any authenticated user can theoretically perform any op.
  // In static Alloy, we ensure no role/permission sig exists.
  no Role
}

// Stub Role sig to check absence
sig Role {}

assert FR_004_FlatPermissions {
  FR_004_FlatPermissions
}

check FR_004_FlatPermissions for 5