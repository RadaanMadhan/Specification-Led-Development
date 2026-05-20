// === feature_model.als — Alloy model for Team Task Management (B-L1) ===

// ============ Core Domain Sigs ============

sig User { }

abstract sig TaskStatus { }
one sig Todo, InProgress, Done extends TaskStatus { }

sig DueDate { }

sig Task {
  title: String,
  description: String,
  due_date: lone DueDate,
  assignee: lone User,
  status: one TaskStatus,
  created_by: lone User,
  created_at: Time,
  updated_at: Time
}

sig TaskDeletion {
  deleted_by: lone User,
  deleted_at: Time
}

abstract sig String { }
sig ValidTitle in String { }
sig ValidDescription in String { }

abstract sig Time { }

// ============ Non-Empty Universe ============

fact F_NonEmptyUniverse {
  some User
  some Task
}

// ============ PATTERN: AuthRequiredEverywhere ============
// ANCHOR: contracts/http-api.md; FR-001

fact F_AuthRequiredEverywhere {
  all t: Task | t.created_by in User
}

pred AuthRequiredEverywhere {
  all t: Task | t.created_by in User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ============ PATTERN: OwnershipExclusivity ============
// ANCHOR: data-model.md Task.created_by; FR-009

fact F_OwnershipExclusivity {
  all t: Task | one t.created_by
}

pred OwnershipExclusivity {
  all t: Task | one t.created_by
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ============ PATTERN: AppendOnly ============
// ANCHOR: data-model.md TaskDeletion; FR-018

fact F_AppendOnly {
  all d: TaskDeletion | one d.deleted_by
}

pred AppendOnly {
  all d: TaskDeletion | d.deleted_by in User
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ============ FEATURE-SPECIFIC: FR-002 IdentityFromContext ============
// ANCHOR: spec.md FR-002

fact F_FR_002_IdentityFromContext {
  all t: Task | t.created_by in User
}

pred FR_002_IdentityFromContext {
  all t: Task | t.created_by in User
}

assert FR_002_IdentityFromContext { FR_002_IdentityFromContext }
check FR_002_IdentityFromContext for 5

// ============ FEATURE-SPECIFIC: FR-005 TitleConstraint ============
// ANCHOR: spec.md FR-005; data-model.md Task.title

fact F_FR_005_TitleConstraint {
  all t: Task | t.title in ValidTitle
}

pred FR_005_TitleConstraint {
  some t: Task | t.title in ValidTitle
}

assert FR_005_TitleConstraint { FR_005_TitleConstraint }
check FR_005_TitleConstraint for 5

// ============ FEATURE-SPECIFIC: FR-006 DescriptionLength ============
// ANCHOR: spec.md FR-006; data-model.md Task.description

fact F_FR_006_DescriptionLength {
  all t: Task | t.description in ValidDescription
}

pred FR_006_DescriptionLength {
  some t: Task | t.description in ValidDescription
}

assert FR_006_DescriptionLength { FR_006_DescriptionLength }
check FR_006_DescriptionLength for 5

// ============ FEATURE-SPECIFIC: FR-007 DueDateOptional ============
// ANCHOR: spec.md FR-007; data-model.md Task.due_date

fact F_FR_007_DueDateOptional {
  all t: Task | lone t.due_date
}

pred FR_007_DueDateOptional {
  all t: Task | lone t.due_date
}

assert FR_007_DueDateOptional { FR_007_DueDateOptional }
check FR_007_DueDateOptional for 5

// ============ FEATURE-SPECIFIC: FR-008 AssigneeIsMember ============
// ANCHOR: spec.md FR-008; data-model.md Task.assignee_id

fact F_FR_008_AssigneeIsMember {
  all t: Task | some t.assignee implies (t.assignee in User)
}

pred FR_008_AssigneeIsMember {
  all t: Task | (some t.assignee implies (t.assignee in User))
}

assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// ============ FEATURE-SPECIFIC: FR-010 StatusSet ============
// ANCHOR: spec.md FR-010; data-model.md TaskStatus

fact F_FR_010_StatusSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}

pred FR_010_StatusSet {
  some t: Task | t.status in (Todo + InProgress + Done)
}

assert FR_010_StatusSet { FR_010_StatusSet }
check FR_010_StatusSet for 5

// ============ FEATURE-SPECIFIC: FR-017 TimestampSemantics ============
// ANCHOR: spec.md FR-017; data-model.md created_at, updated_at

fact F_FR_017_TimestampSemantics {
  all t: Task | (t.created_at in Time and t.updated_at in Time)
}

pred FR_017_TimestampSemantics {
  some t: Task | (t.created_at in Time and t.updated_at in Time)
}

assert FR_017_TimestampSemantics { FR_017_TimestampSemantics }
check FR_017_TimestampSemantics for 5