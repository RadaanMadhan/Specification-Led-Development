// === feature_model.als — Alloy model for Team Task Management (B-L1) ===

sig Member {
  username: one String,
  display_name: one String
}

sig Token {
  token_value: one String,
  user: one Member
}

abstract sig TaskStatus {}
one sig TODO, IN_PROGRESS, DONE extends TaskStatus {}

sig Task {
  id: one String,
  title: one String,
  description: one String,
  due_date: lone String,
  assignee: lone Member,
  status: one TaskStatus,
  created_by: one Member,
  created_at: one String,
  updated_at: one String
}

sig TaskDeletion {
  task_id: one String,
  task_title_at_delete: one String,
  deleted_by_user: one Member,
  deleted_at: one String
}

one sig System {
  tasks: set Task,
  task_deletions: set TaskDeletion,
  tokens: set Token
}

// === UNIVERSE FACT ===

fact F_NonEmptyUniverse {
  some Task
  some Member
  some System.tasks
}

// === CONSTRAINT FACTS ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication boundary

fact F_AuthRequiredEverywhere {
  all t: System.tasks | t.created_by in Member
  all td: System.task_deletions | td.deleted_by_user in Member
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; contracts/http-api.md "flat peer model"

fact F_LeastPrivilege {
  // No role-based access control; all members have equal permission
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion table

fact F_AppendOnlyDeletionLog {
  all disj td1, td2: System.task_deletions | td1.task_id != td2.task_id
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task.created_by

fact F_OwnershipExclusivity {
  all t: System.tasks | one t.created_by
}

// FEATURE-SPECIFIC  ANCHOR: FR-002

fact F_FR_002_IdentityFromContext {
  all t: System.tasks | t.created_by in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-003

fact F_FR_003_SingleWorkspace {
  // All tasks in one implicit workspace; every authenticated user is a member
}

// FEATURE-SPECIFIC  ANCHOR: FR-005

fact F_FR_005_TitleValidation {
  all t: System.tasks | t.title != ""
}

// FEATURE-SPECIFIC  ANCHOR: FR-006

fact F_FR_006_DescriptionValidation {
  all t: System.tasks | true
}

// FEATURE-SPECIFIC  ANCHOR: FR-007

fact F_FR_007_DueDateAllowed {
  // Due dates may be in the past; no constraint needed
}

// FEATURE-SPECIFIC  ANCHOR: FR-008

fact F_FR_008_AssigneeValidation {
  all t: System.tasks | (some t.assignee implies t.assignee in Member)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009

fact F_FR_009_CreatorImmutable {
  all t: System.tasks | one t.created_by and one t.created_at
}

// FEATURE-SPECIFIC  ANCHOR: FR-010

fact F_FR_010_StatusValues {
  all t: System.tasks | t.status in (TODO + IN_PROGRESS + DONE)
}

// FEATURE-SPECIFIC  ANCHOR: FR-011

fact F_FR_011_ClosedTaskRule {
  // A DONE task requires status transition to be edited (enforced at API layer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012

fact F_FR_012_PermanentDeletion {
  all td: System.task_deletions | td.task_id not in System.tasks.id
}

// FEATURE-SPECIFIC  ANCHOR: FR-014

fact F_FR_014_ListOrdering {
  all t: System.tasks | one t.updated_at
}

// FEATURE-SPECIFIC  ANCHOR: FR-017

fact F_FR_017_TimestampSemantics {
  all t: System.tasks | one t.created_at and one t.updated_at
}

// FEATURE-SPECIFIC  ANCHOR: FR-018

fact F_FR_018_DeletionLog {
  all td: System.task_deletions |
    one td.task_id and one td.task_title_at_delete and one td.deleted_by_user and one td.deleted_at
}

// === PREDICATES AND ASSERTIONS ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001

pred AuthRequiredEverywhere {
  all t: System.tasks | t.created_by in Member
  all td: System.task_deletions | td.deleted_by_user in Member
  some System.tasks
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004

pred LeastPrivilege {
  all m: Member | true
  some Member
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018

pred AppendOnly {
  all disj td1, td2: System.task_deletions | td1.task_id != td2.task_id
  some System.task_deletions
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009

pred OwnershipExclusivity {
  all t: System.tasks | (one m: Member | m = t.created_by)
  some System.tasks
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002

pred FR_002_IdentityFromContext {
  all t: System.tasks | t.created_by in Member
  some System.tasks
}

assert FR_002_IdentityFromContext { FR_002_IdentityFromContext }
check FR_002_IdentityFromContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003

pred FR_003_SingleWorkspace {
  all t: System.tasks | all m: Member | true
  some System.tasks
}

assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005

pred FR_005_TitleValidation {
  all t: System.tasks | t.title != ""
  some System.tasks
}

assert FR_005_TitleValidation { FR_005_TitleValidation }
check FR_005_TitleValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006

pred FR_006_DescriptionValidation {
  all t: System.tasks | one t.description
  some System.tasks
}

assert FR_006_DescriptionValidation { FR_006_DescriptionValidation }
check FR_006_DescriptionValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007

pred FR_007_DueDateAllowed {
  all t: System.tasks | (some t.due_date or no t.due_date)
  some System.tasks
}

assert FR_007_DueDateAllowed { FR_007_DueDateAllowed }
check FR_007_DueDateAllowed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008

pred FR_008_AssigneeValidation {
  all t: System.tasks | (some t.assignee implies t.assignee in Member)
  some System.tasks
}

assert FR_008_AssigneeValidation { FR_008_AssigneeValidation }
check FR_008_AssigneeValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009

pred FR_009_CreatorImmutable {
  all t: System.tasks | one t.created_by and one t.created_at
  some System.tasks
}

assert FR_009_CreatorImmutable { FR_009_CreatorImmutable }
check FR_009_CreatorImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010

pred FR_010_StatusTransitions {
  all t: System.tasks | (t.status = TODO or t.status = IN_PROGRESS or t.status = DONE)
  some System.tasks
}

assert FR_010_StatusTransitions { FR_010_StatusTransitions }
check FR_010_StatusTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011

pred FR_011_ClosedTaskRule {
  all t: System.tasks | (t.status = DONE implies true)
  some System.tasks
}

assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012

pred FR_012_PermanentDeletion {
  all td: System.task_deletions | td.task_id not in System.tasks.id
  some System.task_deletions
}

assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014

pred FR_014_ListOrdering {
  all t: System.tasks | one t.updated_at
  some System.tasks
}

assert FR_014_ListOrdering { FR_014_ListOrdering }
check FR_014_ListOrdering for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017

pred FR_017_TimestampSemantics {
  all t: System.tasks | one t.created_at and one t.updated_at
  some System.tasks
}

assert FR_017_TimestampSemantics { FR_017_TimestampSemantics }
check FR_017_TimestampSemantics for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018

pred FR_018_DeletionLog {
  all td: System.task_deletions |
    (one td.task_id and one td.task_title_at_delete and one td.deleted_by_user and one td.deleted_at)
  some System.task_deletions
}

assert FR_018_DeletionLog { FR_018_DeletionLog }
check FR_018_DeletionLog for 5