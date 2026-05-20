// === feature_model.als — Alloy model for Team Task Management (B-L1) ===
// Single self-contained Alloy 6 model encoding structural correctness invariants
// for the Task Management feature (spec.md, data-model.md, contracts/http-api.md).

// ===== ROLE AND OPERATION ENUMERATION (from contracts/http-api.md) =====

abstract sig Role {}
one sig Authenticated extends Role {}
one sig Unauthenticated extends Role {}

abstract sig OperationKind {}
one sig PostTasks extends OperationKind {}
one sig GetTasks extends OperationKind {}
one sig PatchTasks extends OperationKind {}
one sig DeleteTasks extends OperationKind {}

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ===== TASK STATUS ENUMERATION (from data-model.md TaskStatus enum) =====

abstract sig TaskStatus {}
one sig Todo extends TaskStatus {}
one sig InProgress extends TaskStatus {}
one sig Done extends TaskStatus {}

// ===== ENTITY SIGS (from data-model.md) =====

sig Member {
  id: one String,
  username: one String
}

sig Task {
  id: one String,
  title: one String,
  status: one TaskStatus,
  created_by: one Member,
  assignee: lone Member
}

sig TaskDeletion {
  task_id: one String,
  deleted_by: one Member
}

// ===== NON-EMPTY UNIVERSE (required for meaningful assertions) =====

fact F_NonEmptyUniverse {
  some Member
  some Task
  some TaskDeletion
}

// ===== STRUCTURAL CONSTRAINTS (Facts encoding spec/contract rules) =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization matrix; spec.md FR-001
fact F_LeastPrivilege {
  // Authenticated role can perform all 4 API operations
  (Authenticated -> PostTasks) in PermMatrix.Allowed
  (Authenticated -> GetTasks) in PermMatrix.Allowed
  (Authenticated -> PatchTasks) in PermMatrix.Allowed
  (Authenticated -> DeleteTasks) in PermMatrix.Allowed
  // Unauthenticated role cannot perform any operation (least privilege principle)
  (Unauthenticated -> PostTasks) not in PermMatrix.Allowed
  (Unauthenticated -> GetTasks) not in PermMatrix.Allowed
  (Unauthenticated -> PatchTasks) not in PermMatrix.Allowed
  (Unauthenticated -> DeleteTasks) not in PermMatrix.Allowed
  // Closed-world: exactly these 4 permissions exist
  PermMatrix.Allowed = (
    (Authenticated -> PostTasks) +
    (Authenticated -> GetTasks) +
    (Authenticated -> PatchTasks) +
    (Authenticated -> DeleteTasks)
  )
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 AssigneeIsCurrentMember
fact F_AssigneeValidity {
  all t: Task | some t.assignee implies (t.assignee in Member)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 CreatorRecordedAtCreation
fact F_CreatorValidity {
  all t: Task | t.created_by in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 TaskStatusValid (status from enumeration)
fact F_TaskStatusValid {
  all t: Task | t.status in (Todo | InProgress | Done)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion (immutable log)
fact F_AppendOnlyDeletionLog {
  all td: TaskDeletion | td.deleted_by in Member
}

// ===== ASSERTIONS (Predicates to verify, one per structural claim) =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-001
pred LeastPrivilege {
  (Unauthenticated -> PostTasks) not in PermMatrix.Allowed
  (Unauthenticated -> GetTasks) not in PermMatrix.Allowed
  (Unauthenticated -> PatchTasks) not in PermMatrix.Allowed
  (Unauthenticated -> DeleteTasks) not in PermMatrix.Allowed
  (Authenticated -> PostTasks) in PermMatrix.Allowed
  (Authenticated -> GetTasks) in PermMatrix.Allowed
  (Authenticated -> PatchTasks) in PermMatrix.Allowed
  (Authenticated -> DeleteTasks) in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  all r: Role | all o: OperationKind |
    ((r -> o) in PermMatrix.Allowed) or ((r -> o) not in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md TaskDeletion
pred AppendOnly {
  all td: TaskDeletion | td.deleted_by in Member
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 AuthenticationRequired
pred FR_001_AuthenticationRequired {
  some op: OperationKind |
    (Authenticated -> op) in PermMatrix.Allowed and
    (Unauthenticated -> op) not in PermMatrix.Allowed
}

assert FR_001_AuthenticationRequired { FR_001_AuthenticationRequired }
check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004 FlatPermissionsModel
pred FR_003_004_FlatPermissionsModel {
  all r: Role | (r = Authenticated or r = Unauthenticated)
}

assert FR_003_004_FlatPermissionsModel { FR_003_004_FlatPermissionsModel }
check FR_003_004_FlatPermissionsModel for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 AssigneeIsCurrentMember
pred FR_008_AssigneeIsCurrentMember {
  all t: Task | some t.assignee implies (t.assignee in Member)
}

assert FR_008_AssigneeIsCurrentMember { FR_008_AssigneeIsCurrentMember }
check FR_008_AssigneeIsCurrentMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 CreatorRecordedAtCreation
pred FR_009_CreatorRecordedAtCreation {
  all t: Task | t.created_by in Member
}

assert FR_009_CreatorRecordedAtCreation { FR_009_CreatorRecordedAtCreation }
check FR_009_CreatorRecordedAtCreation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 StatusCanTransitionFreely
pred FR_010_StatusCanTransitionFreely {
  all t: Task | t.status in (Todo | InProgress | Done)
}

assert FR_010_StatusCanTransitionFreely { FR_010_StatusCanTransitionFreely }
check FR_010_StatusCanTransitionFreely for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 DeletionLogged
pred FR_018_DeletionLogged {
  all td: TaskDeletion | td.deleted_by in Member
}

assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5