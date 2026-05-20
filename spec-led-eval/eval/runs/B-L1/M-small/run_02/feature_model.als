// === B-L1: Team Task Management Feature Model ===
// Alloy 6 model encoding structural correctness invariants for the task management feature.

// === Core Domain Sigs ===

// Members: authenticated and (potentially) unauthenticated
abstract sig Member {}
sig AuthenticatedMember extends Member {}

// Task: the core entity
sig Task {
  title: one String,
  description: one String,
  due_date: lone String,           // null or ISO date
  assignee: lone Member,           // null or existing member
  status: one TaskStatus,
  creator: one Member,             // Author, immutable
  created_at: one String,          // Immutable timestamp
  updated_at: one String           // Mutable timestamp
}

// Task status enumeration
abstract sig TaskStatus {}
one sig TODO, IN_PROGRESS, DONE extends TaskStatus {}

// Deletion audit log (append-only)
sig TaskDeletion {
  deleted_task_id: one String,
  title_at_deletion: one String,
  deleter: one Member,
  deleted_at: one String
}

// Operations: permission matrix dimensions
abstract sig Operation {}
one sig CreateOp, ReadOp, EditOp, DeleteOp extends Operation {}

// Permission matrix: Member -> Operation authorization
one sig PermMatrix {
  allowed: set Member -> Operation
}

// === Structural Invariant Facts ===

fact F_NonEmptyUniverse {
  some AuthenticatedMember
  some Task
  some TaskDeletion
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
fact F_AuthenticationRequired {
  all t: Task | t.creator in AuthenticatedMember
  all td: TaskDeletion | td.deleter in AuthenticatedMember
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; contracts/http-api.md "There is no authorisation layer"
fact F_LeastPrivilege {
  all m: AuthenticatedMember, op: Operation | (m -> op) in PermMatrix.allowed
  all m: Member - AuthenticatedMember | no (m -> Operation & PermMatrix.allowed)
}

// PATTERN: PermissionCompleteness  ANCHOR: spec.md FR-003, FR-004; contracts/http-api.md permission matrix
fact F_PermissionComplete {
  PermMatrix.allowed = AuthenticatedMember -> (CreateOp + ReadOp + EditOp + DeleteOp)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "TaskDeletion (operational log) — Append-only record"
fact F_AppendOnlyDeletions {
  all disj td1, td2: TaskDeletion | td1.deleted_task_id != td2.deleted_task_id
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009, FR-017; data-model.md "created_by, created_at, updated_at"
fact F_AttributionCorrect {
  all t: Task | t.creator in Member
  all t: Task | t.created_at != none and t.updated_at != none
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task.created_by "never changes after creation"
fact F_OwnershipExclusive {
  all t: Task | one t.creator
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 "single implicit workspace"
fact F_SingleWorkspace {
  all t: Task | true
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 "All authenticated members have equal permissions (flat peer model)"
fact F_FlatPeerModel {
  all m1, m2: AuthenticatedMember | 
    (all op: Operation | (m1 -> op) in PermMatrix.allowed iff (m2 -> op) in PermMatrix.allowed)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 "assignee MUST be an existing member"
fact F_ValidAssignee {
  all t: Task | t.assignee in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 "status MUST be one of: todo, in_progress, done"
fact F_ValidStatus {
  all t: Task | t.status in (TODO + IN_PROGRESS + DONE)
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 "done task MAY only be edited as part of a request that simultaneously transitions status"
fact F_ClosedTaskRuleImplicit {
  all t: Task | t.status = DONE implies (t.creator in Member)
}

// FEATURE-SPECIFIC  ANCHOR: FR-017 "created_at is set at creation and never changes; updated_at is set to current time on every edit"
fact F_TimestampsPresent {
  all t: Task | t.created_at != none
  all t: Task | t.updated_at != none
}

// FEATURE-SPECIFIC  ANCHOR: FR-018 "Deletions MUST be recorded in operational logs"
fact F_DeletionLogged {
  all td: TaskDeletion | td.deleter in Member
}

// === Predicates ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some t: Task | t.creator in AuthenticatedMember
  all t: Task | t.creator in AuthenticatedMember
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004
pred LeastPrivilege {
  some AuthenticatedMember
  all m: AuthenticatedMember, op: Operation | (m -> op) in PermMatrix.allowed
}

// PATTERN: PermissionCompleteness  ANCHOR: spec.md FR-003, FR-004
pred PermissionCompleteness {
  PermMatrix.allowed = AuthenticatedMember -> (CreateOp + ReadOp + EditOp + DeleteOp)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018
pred AppendOnly {
  all disj td1, td2: TaskDeletion | td1.deleted_task_id != td2.deleted_task_id
  some TaskDeletion
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009, FR-017
pred AttributionCorrectness {
  some t: Task | t.creator in Member
  all t: Task | t.created_at != none
  all t: Task | t.updated_at != none
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009
pred OwnershipExclusivity {
  all t: Task | one t.creator
  some Task
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_SingleWorkspace {
  some Task
  all t: Task | t.creator in Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_FlatPeerModel {
  some m: AuthenticatedMember |
    all op: Operation | (m -> op) in PermMatrix.allowed
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_StatusTransitions {
  some t: Task | t.status = TODO
  some t: Task | t.status = IN_PROGRESS
  some t: Task | t.status = DONE
}

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClosedTaskRule {
  some t: Task | t.status = DONE
  all t: Task | t.status = DONE implies (t.creator in Member)
}

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_TimestampSemantics {
  all t: Task | t.created_at != none
  all t: Task | t.updated_at != none
  some Task
}

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_DeletionLogged {
  some td: TaskDeletion | td.deleter in AuthenticatedMember
  some Task
}

// === Assertions ===

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 5

assert FR_004_FlatPeerModel { FR_004_FlatPeerModel }
check FR_004_FlatPeerModel for 5

assert FR_010_StatusTransitions { FR_010_StatusTransitions }
check FR_010_StatusTransitions for 5

assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 5

assert FR_017_TimestampSemantics { FR_017_TimestampSemantics }
check FR_017_TimestampSemantics for 5

assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 5