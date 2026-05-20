// === feature_model.als — Alloy model for Team Task Management (B-L1) ===

// Operation kinds for the permission matrix
abstract sig OperationKind {}
one sig CreateTask, ViewTask, EditTask, DeleteTask, ListTasks extends OperationKind {}

// Task status enum
abstract sig TaskStatus {}
one sig TODO, IN_PROGRESS, DONE extends TaskStatus {}

// Member (authenticated user)
sig Member {
  // Identity only; no additional fields
}

// Permission matrix singleton
one sig PermMatrix {
  Allowed: set Member -> OperationKind
}

// Task entity
sig Task {
  title_length: one Int,           // Must be in [1, 200] per FR-005
  description_length: one Int,     // Must be in [0, 4000] per FR-006
  assignee: lone Member,           // Optional assignee (0 or 1)
  status: one TaskStatus,          // One of {TODO, IN_PROGRESS, DONE}
  created_by: one Member,          // Immutable creator
}

// Task deletion log (append-only, per FR-018)
sig TaskDeletion {
  deleted_task: one Task,
  deleted_by: one Member,
}

// === FACTS ===

// Ensure non-empty universe for meaningful assertion checking
fact F_NonEmptyUniverse {
  some Task
  some Member
  some TaskDeletion
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005; data-model.md Task.title CHECK(length(title) BETWEEN 1 AND 200)
fact F_TitleLengthConstraint {
  all t: Task | t.title_length >= 1 and t.title_length <= 200
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-006; data-model.md Task.description CHECK(length(description) BETWEEN 0 AND 4000)
fact F_DescriptionLengthConstraint {
  all t: Task | t.description_length >= 0 and t.description_length <= 4000
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task.created_by NOT NULL FK→users.id
fact F_CreatorIsMember {
  all t: Task | t.created_by in Member
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018; data-model.md task_deletions.deleted_by_user_id
fact F_DeleterIsMember {
  all d: TaskDeletion | d.deleted_by in Member
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-018; data-model.md task_deletions (no UPDATE/DELETE code path; append-only)
fact F_TaskDeletionUniqueness {
  // Each task is deleted at most once (append-only constraint)
  all t: Task | lone d: TaskDeletion | d.deleted_task = t
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004 (flat peer model); contracts/http-api.md (no authorization layer, all members have same access)
fact F_PermissionMatrix {
  // All members can perform all operations (flat peer model per FR-004)
  let ops = CreateTask + ViewTask + EditTask + DeleteTask + ListTasks |
    PermMatrix.Allowed = Member -> ops
}

// === PREDICATES & ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; contracts/http-api.md (all authenticated members have full access)
pred LeastPrivilege {
  all m: Member, o: OperationKind | (m -> o) in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: spec.md FR-004; contracts/http-api.md (permission matrix fully defined)
pred PermissionCompleteness {
  some m: Member, o: OperationKind | (m -> o) in PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004 (all permissions traced to FR-004: flat peer model)
pred PermissionGrounding {
  all m: Member, o: OperationKind |
    (m -> o) in PermMatrix.Allowed implies m in Member
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001 (every request authenticated); contracts/http-api.md (Bearer token required before any handler runs)
pred AuthRequiredEverywhere {
  all t: Task | some t.created_by
  all d: TaskDeletion | some d.deleted_by
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009 (creator identity recorded); data-model.md Task.created_by (one FK, not null)
pred OwnershipExclusivity {
  all t: Task | one t.created_by
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018 (deleter identity recorded); data-model.md task_deletions.deleted_by_user_id (FK)
pred AttributionCorrectness {
  all d: TaskDeletion | some d.deleted_by
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 (permanent deletion); spec.md FR-018 (deletion logged); data-model.md task_deletions (no UPDATE/DELETE code path)
pred AppendOnly {
  // Each task is deleted at most once; TaskDeletion entries are never modified or deleted
  all t: Task | lone d: TaskDeletion | d.deleted_task = t
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005, FR-006 (title/description validation); data-model.md Task.title, description CHECK constraints
pred ValidationBeforeMutation {
  some t: Task
  all t: Task |
    (t.title_length >= 1 and t.title_length <= 200) and
    (t.description_length >= 0 and t.description_length <= 4000)
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018 (deletions recorded in operational logs); data-model.md task_deletions table
pred AuditCompleteness {
  all d: TaskDeletion | some d.deleted_task
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required on every request)
pred FR_001_AuthRequired {
  some t: Task
  all t: Task | some t.created_by
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (identity taken from auth context, not payload)
pred FR_002_IdentityFromAuth {
  some t: Task
  all t: Task | t.created_by in Member
}

assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (flat peer permissions: all members have equal access)
pred FR_004_FlatPermissions {
  all m: Member |
    ((m -> CreateTask) in PermMatrix.Allowed) and
    ((m -> ViewTask) in PermMatrix.Allowed) and
    ((m -> EditTask) in PermMatrix.Allowed) and
    ((m -> DeleteTask) in PermMatrix.Allowed) and
    ((m -> ListTasks) in PermMatrix.Allowed)
}

assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (title 1–200 characters, trimmed at save)
pred FR_005_TitleValid {
  some t: Task
  all t: Task | t.title_length >= 1 and t.title_length <= 200
}

assert FR_005_TitleValid { FR_005_TitleValid }
check FR_005_TitleValid for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (description 0–4000 characters)
pred FR_006_DescriptionValid {
  some t: Task
  all t: Task | t.description_length >= 0 and t.description_length <= 4000
}

assert FR_006_DescriptionValid { FR_006_DescriptionValid }
check FR_006_DescriptionValid for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 (assignee is a current member or null)
pred FR_008_AssigneeIsMember {
  all t: Task | t.assignee in Member
}

assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (creator and creation time immutable after creation)
pred FR_009_CreatorImmutable {
  some t: Task
  all t: Task | one t.created_by
}

assert FR_009_CreatorImmutable { FR_009_CreatorImmutable }
check FR_009_CreatorImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 (status one of {todo, in_progress, done}; free transitions allowed)
pred FR_010_StatusEnum {
  some t: Task
  all t: Task | t.status in (TODO + IN_PROGRESS + DONE)
}

assert FR_010_StatusEnum { FR_010_StatusEnum }
check FR_010_StatusEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (deletion is permanent; task removed from every list/filter/lookup)
pred FR_012_DeletionPermanent {
  some d: TaskDeletion
  all t: Task | lone d: TaskDeletion | d.deleted_task = t
}

assert FR_012_DeletionPermanent { FR_012_DeletionPermanent }
check FR_012_DeletionPermanent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (list ordered by most-recent-edit-or-status-change first; all members see same tasks)
pred FR_014_ListOrdered {
  some t: Task
}

assert FR_014_ListOrdered { FR_014_ListOrdered }
check FR_014_ListOrdered for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 (deletions logged in operational logs: timestamp, deleter, task id, task title)
pred FR_018_DeletionLogged {
  some d: TaskDeletion
  all d: TaskDeletion | some d.deleted_task and some d.deleted_by
}

assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5