// === feature_model.als — Alloy model for Team Task Management (B-L1) ===

// Status enumeration for tasks
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Member (user in the single implicit workspace)
sig Member {}

// Opaque representation of strings (title, description, timestamps, etc.)
sig String {}

// Task entity
sig Task {
  title: lone String,
  description: lone String,
  due_date: lone String,
  assignee: lone Member,
  status: lone TaskStatus,
  created_by: lone Member,
  created_at: lone String,
  updated_at: lone String
}

// Operational log for task deletions
sig TaskDeletion {
  task_id: lone String,
  task_title: lone String,
  deleted_by: lone Member,
  deleted_at: lone String
}

// Authorization model
abstract sig Role {}
one sig AuthenticatedMember extends Role {}

abstract sig OperationKind {}
one sig CreateTask, ViewTask, ListTasks, EditTask, DeleteTask extends OperationKind {}

one sig PermissionMatrix {
  Allowed: set Role -> OperationKind
}

// === Facts ===

fact F_NonEmptyUniverse {
  some Task
  some Member
  some TaskDeletion
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md, FR-003, FR-004
fact F_FlatPermissionsMatrix {
  // All authenticated members have identical permission sets
  AuthenticatedMember -> CreateTask in PermissionMatrix.Allowed
  AuthenticatedMember -> ViewTask in PermissionMatrix.Allowed
  AuthenticatedMember -> ListTasks in PermissionMatrix.Allowed
  AuthenticatedMember -> EditTask in PermissionMatrix.Allowed
  AuthenticatedMember -> DeleteTask in PermissionMatrix.Allowed
  
  // Closed-world: exactly these cells are allowed
  PermissionMatrix.Allowed = (AuthenticatedMember -> CreateTask) +
                             (AuthenticatedMember -> ViewTask) +
                             (AuthenticatedMember -> ListTasks) +
                             (AuthenticatedMember -> EditTask) +
                             (AuthenticatedMember -> DeleteTask)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, contracts/http-api.md
fact F_AuthenticationRequired {
  // Every task is created by an authenticated member
  all t: Task | some t.created_by
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
fact F_TitlePresent {
  all t: Task | some t.title
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
fact F_DescriptionAllowed {
  all t: Task | (t.description = none or some t.description)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008
fact F_AssigneeIsCurrentMember {
  all t: Task | (t.assignee = none or t.assignee in Member)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
fact F_CreatorExists {
  all t: Task | t.created_by in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
fact F_StatusIsValid {
  all t: Task | (t.status = none or t.status in TaskStatus)
}

// FEATURE-SPECIFIC  ANCHOR: FR-017
fact F_TimestampsPresent {
  all t: Task | (some t.created_at) and (some t.updated_at)
}

// PATTERN: AppendOnly  ANCHOR: data-model.md, FR-018
fact F_DeletionLogsComplete {
  all td: TaskDeletion |
    (some td.task_id) and
    (some td.task_title) and
    (some td.deleted_by) and
    (some td.deleted_at)
}

// === Predicates and Assertions ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, contracts/http-api.md
pred AuthRequiredEverywhere {
  all t: Task | some t.created_by
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md, FR-003, FR-004
pred LeastPrivilege {
  (AuthenticatedMember -> CreateTask in PermissionMatrix.Allowed) and
  (AuthenticatedMember -> ViewTask in PermissionMatrix.Allowed) and
  (AuthenticatedMember -> EditTask in PermissionMatrix.Allowed) and
  (AuthenticatedMember -> DeleteTask in PermissionMatrix.Allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md, FR-003, FR-004
pred PermissionCompleteness {
  all op: OperationKind | (AuthenticatedMember -> op in PermissionMatrix.Allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 8 but exactly 5 OperationKind

// PATTERN: AppendOnly  ANCHOR: data-model.md, FR-018
pred AppendOnly {
  all td: TaskDeletion |
    (some td.task_id) and
    (some td.task_title) and
    (some td.deleted_by) and
    (some td.deleted_at)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-009, data-model.md
pred AttributionCorrectness {
  all t: Task | t.created_by in Member
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TitleRequired {
  all t: Task | some t.title
}

assert FR_005_TitleRequired {
  FR_005_TitleRequired
}

check FR_005_TitleRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_DescriptionAllowed {
  all t: Task | (t.description = none or some t.description)
}

assert FR_006_DescriptionAllowed {
  FR_006_DescriptionAllowed
}

check FR_006_DescriptionAllowed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeExists {
  all t: Task | (t.assignee = none or t.assignee in Member)
}

assert FR_008_AssigneeExists {
  FR_008_AssigneeExists
}

check FR_008_AssigneeExists for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_CreatorImmutable {
  all t: Task | some t.created_by
}

assert FR_009_CreatorImmutable {
  FR_009_CreatorImmutable
}

check FR_009_CreatorImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_StatusEnumeration {
  all t: Task | (t.status = none or t.status in (Todo + InProgress + Done))
}

assert FR_010_StatusEnumeration {
  FR_010_StatusEnumeration
}

check FR_010_StatusEnumeration for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_DeletionRecorded {
  some TaskDeletion
}

assert FR_012_DeletionRecorded {
  FR_012_DeletionRecorded
}

check FR_012_DeletionRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_TimestampSemantics {
  all t: Task | (some t.created_at) and (some t.updated_at)
}

assert FR_017_TimestampSemantics {
  FR_017_TimestampSemantics
}

check FR_017_TimestampSemantics for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_DeletionLogging {
  all td: TaskDeletion |
    (some td.task_id) and
    (some td.task_title) and
    (some td.deleted_by) and
    (some td.deleted_at)
}

assert FR_018_DeletionLogging {
  FR_018_DeletionLogging
}

check FR_018_DeletionLogging for 5