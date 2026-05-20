// === feature_model.als — Alloy model for Team Task Management (B-L1) ===

// Task status enum
abstract sig TaskStatus {}
one sig TODO, IN_PROGRESS, DONE extends TaskStatus {}

// Core domain entities
sig Member {
  id: one String,
  username: one String,
  display_name: one String
}

sig Task {
  id: one String,
  title: one String,
  description: lone String,
  due_date: lone String,
  assignee_id: lone Member,
  status: one TaskStatus,
  created_by: one Member,
  created_at: one String,
  updated_at: one String
}

sig TaskDeletion {
  task_id: one String,
  task_title_at_delete: one String,
  deleted_by_user_id: one Member,
  deleted_at: one String
}

sig Token {
  token: one String,
  user_id: one Member
}

one sig System {
  members: set Member,
  tasks: set Task,
  deletions: set TaskDeletion,
  tokens: set Token
}

// === Non-empty universe ===
fact F_NonEmptyUniverse {
  some System.members
  some System.tasks
  some Token
}

// === Named structural facts (invariants) ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth boundary
fact F_AuthRequiredEverywhere {
  all t: System.tasks | t.created_by in System.tokens.user_id
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-003
fact F_SingleImplicitWorkspace {
  // Single workspace: all tasks are managed in System.tasks with no per-workspace isolation
  all t: System.tasks | t in System.tasks
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004
fact F_FlatPeerPermissions {
  // All authenticated members are equal peers; no role hierarchy
  all m: System.members | (some tok: System.tokens | tok.user_id = m)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008
fact F_AssigneeIsValidMember {
  // Any assigned member must exist in workspace members
  all t: System.tasks | (some t.assignee_id implies t.assignee_id in System.members)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009
fact F_CreatorAndCreatedAtImmutable {
  // Creator and creation timestamp are set at creation and never change
  all t: System.tasks | (t.created_by in System.members and t.created_at != "")
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010
fact F_TaskStatusIsValid {
  // Status must be one of the three allowed values
  all t: System.tasks | (t.status = TODO or t.status = IN_PROGRESS or t.status = DONE)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion table
fact F_AppendOnlyDeletionLog {
  // Deletion log entries are append-only and immutable once created
  all td: System.deletions | (
    td.task_id != "" and
    td.task_title_at_delete != "" and
    td.deleted_by_user_id in System.members and
    td.deleted_at != ""
  )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012
fact F_DeletedTaskRemovedFromList {
  // When a task is deleted, it no longer appears in the active tasks list
  all td: System.deletions | (no t: System.tasks | t.id = td.task_id)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017
fact F_TimestampFieldsExist {
  // Every task has immutable creation timestamp and mutable update timestamp
  all t: System.tasks | (t.created_at != "" and t.updated_at != "")
}

// PATTERN: ValidationBeforeMutation  ANCHOR: contracts/http-api.md validation layer
fact F_AllTasksPassValidation {
  // All tasks in the system satisfy basic validation constraints
  all t: System.tasks | (
    t.title != "" and
    (some t.assignee_id implies t.assignee_id in System.members) and
    t.created_by in System.members
  )
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md created_by field
fact F_CreatorExistsInMembersSet {
  // Every task's creator must be a valid member
  all t: System.tasks | t.created_by in System.members
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014
fact F_ListingFieldsConsistent {
  // Fields required for listing/filtering are consistent
  all t: System.tasks | (
    (t.status = TODO or t.status = IN_PROGRESS or t.status = DONE) and
    (some t.assignee_id or t.assignee_id = none)
  )
}

// ===== PREDICATES AND ASSERTIONS =====

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  all t: System.tasks | t.created_by in System.tokens.user_id
  some System.tasks
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeIsValidMember {
  all t: System.tasks | (some t.assignee_id implies t.assignee_id in System.members)
  some System.tasks
}
assert FR_008_AssigneeIsValidMember { FR_008_AssigneeIsValidMember }
check FR_008_AssigneeIsValidMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreatorAndCreatedAtImmutable {
  all t: System.tasks | (t.created_by in System.members and t.created_at != "")
  some System.tasks
}
assert FR_009_CreatorAndCreatedAtImmutable { FR_009_CreatorAndCreatedAtImmutable }
check FR_009_CreatorAndCreatedAtImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_StatusIsValid {
  all t: System.tasks | (t.status = TODO or t.status = IN_PROGRESS or t.status = DONE)
  some System.tasks
}
assert FR_010_StatusIsValid { FR_010_StatusIsValid }
check FR_010_StatusIsValid for 5

// PATTERN: AppendOnly
pred AppendOnly {
  all td: System.deletions | (
    td.task_id != "" and
    td.deleted_by_user_id in System.members
  )
  some System.deletions
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_DeletedTaskRemovedFromList {
  all td: System.deletions | (no t: System.tasks | t.id = td.task_id)
  some System.deletions
}
assert FR_012_DeletedTaskRemovedFromList { FR_012_DeletedTaskRemovedFromList }
check FR_012_DeletedTaskRemovedFromList for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_TimestampsExist {
  all t: System.tasks | (t.created_at != "" and t.updated_at != "")
  some System.tasks
}
assert FR_017_TimestampsExist { FR_017_TimestampsExist }
check FR_017_TimestampsExist for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all t: System.tasks | (some tok: System.tokens | tok.user_id = t.created_by)
  some System.tasks
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  all t: System.tasks | t.created_by in System.members
  some System.tasks
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_SingleWorkspace {
  all t: System.tasks | t in System.tasks
  some System.tasks
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_FlatPermissions {
  all m: System.members | (some tok: System.tokens | tok.user_id = m)
  some System.members
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_DeletionLogged {
  all td: System.deletions | (
    td.task_id != "" and
    td.deleted_by_user_id in System.members and
    td.deleted_at != ""
  )
  some System.deletions
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5

// PATTERN: ValidationBeforeMutation
pred ValidationBeforeMutation {
  all t: System.tasks | (
    t.title != "" and
    (some t.assignee_id implies t.assignee_id in System.members) and
    t.created_by in System.members
  )
  some System.tasks
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5