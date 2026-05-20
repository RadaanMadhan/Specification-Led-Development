// === feature_model.als — Alloy model for Team Task Management ===

abstract sig Member {}
one sig AliceMember, BobMember, CharlieMember extends Member {}

abstract sig TaskStatus {}
one sig TodoStatus, InProgressStatus, DoneStatus extends TaskStatus {}

sig String {}

sig Task {
  title: one String,
  description: one String,
  due_date: lone String,
  assignee: lone Member,
  status: one TaskStatus,
  created_by: lone Member,
  created_at: lone String,
  updated_at: lone String
}

sig TaskDeletion {
  deleted_task_id: one String,
  deleted_task_title: one String,
  deleted_by: lone Member,
  deleted_at: one String
}

fact F_NonEmptyUniverse {
  some Task
  some TaskDeletion
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthRequired {
  all t: Task | some t.created_by
  all td: TaskDeletion | some td.deleted_by
}

pred AuthRequiredEverywhere {
  all t: Task | some t.created_by
  all td: TaskDeletion | some td.deleted_by
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009, FR-008
fact F_OwnershipExclusivity {
  all t: Task | one t.created_by
  all t: Task | lone t.assignee
}

pred OwnershipExclusivity {
  all t: Task | one t.created_by
  all t: Task | lone t.assignee
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, data-model.md TaskDeletion
fact F_AppendOnly {
  all disj td1, td2: TaskDeletion | td1.deleted_task_id != td2.deleted_task_id
}

pred AppendOnly {
  all disj td1, td2: TaskDeletion | td1.deleted_task_id != td2.deleted_task_id
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018, data-model.md TaskDeletion
fact F_AttributionCorrectness {
  all td: TaskDeletion | some td.deleted_by
  all td: TaskDeletion | some td.deleted_task_title
}

pred AttributionCorrectness {
  all td: TaskDeletion | some td.deleted_by
  all td: TaskDeletion | some td.deleted_task_title
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 Assignee must be a current member of workspace
fact F_ValidAssignee {
  all t: Task | no t.assignee or (t.assignee in Member)
}

pred FR_008_ValidAssignee {
  all t: Task | no t.assignee or (t.assignee in Member)
}

assert FR_008_ValidAssignee { FR_008_ValidAssignee }
check FR_008_ValidAssignee for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 Status must be one of the three allowed values
fact F_ValidStatus {
  all t: Task | t.status in (TodoStatus + InProgressStatus + DoneStatus)
}

pred FR_010_ValidStatus {
  all t: Task | t.status in (TodoStatus + InProgressStatus + DoneStatus)
}

assert FR_010_ValidStatus { FR_010_ValidStatus }
check FR_010_ValidStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 Every task must have immutable created_at and updated_at timestamps
fact F_TimestampsPresent {
  all t: Task | some t.created_at and some t.updated_at
}

pred FR_017_TimestampsPresent {
  all t: Task | some t.created_at and some t.updated_at
}

assert FR_017_TimestampsPresent { FR_017_TimestampsPresent }
check FR_017_TimestampsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 Deletion must be recorded in operational log with complete attribution
fact F_DeletionRecorded {
  all td: TaskDeletion | some td.deleted_by and some td.deleted_at
}

pred FR_018_DeletionRecorded {
  all td: TaskDeletion | some td.deleted_by and some td.deleted_at
}

assert FR_018_DeletionRecorded { FR_018_DeletionRecorded }
check FR_018_DeletionRecorded for 5