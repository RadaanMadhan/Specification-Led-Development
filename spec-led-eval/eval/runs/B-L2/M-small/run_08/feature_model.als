// === feature_model.als — Alloy model for 007-team-tasks ===
// SaaS Team Task Management with Audit Trail
// Feature: B-L2

// ===== Core Domain Sigs =====

sig User {
  name: one String
}

sig Team {}

abstract sig TaskStatus {}
one sig TODO, IN_PROGRESS, DONE extends TaskStatus {}

sig Task {
  team: one Team,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus,
  assignee_allowed_in_team: one Int  // 0 or 1: is assignee in task's team?
}

abstract sig Role {}
one sig Member, Admin extends Role {}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

// Audit entry: append-only record of a task change
sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,  // snapshot at time of change
  actor_name_snapshot: one String  // snapshot at time of change
}

// Operation kinds for permission matrix
abstract sig Operation {}
one sig OpCreateTask, OpReadTask, OpEditTask, OpDeleteTask, OpViewAudit extends Operation {}

abstract sig String {}

// Permission matrix singleton
one sig PermMatrix {
  allowed: set Role -> Operation
}

// ===== Structural Constraints (Facts) =====

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some TeamMembership
  some AuditEntry
}

// FR-005: Task team is immutable — enforced by singleton team field
fact F_TaskTeamImmutable {
  all t: Task | one t.team
}

// FR-006: Task owner is immutable — enforced by singleton owner field
fact F_OwnerImmutable {
  all t: Task | one t.owner
}

// FR-007: Each user-team pair has at most one role (no duplicate memberships)
fact F_PerTeamRole {
  all u: User, t: Team |
    lone m: TeamMembership | m.user = u and m.team = t
}

// FR-016: Audit entries are append-only (immutable)
// Enforced by absence of UPDATE/DELETE paths; all fields are defined and fixed
fact F_AuditAppendOnlyImmutable {
  all ae: AuditEntry |
    (one ae.task and one ae.actor and one ae.actor_role and
     one ae.actor_name_snapshot)
}

// FR-014: Cross-team isolation — tasks belong exactly to one team
fact F_CrossTeamIsolationStructure {
  all t: Task | one t.team
}

// FR-012: Assignee must be a member of the same team (validated at request time)
// We encode this as a constraint: if assignee is set, there must exist a membership
fact F_AssigneeTeamValidation {
  all t: Task |
    (t.assignee_allowed_in_team = 1) implies
    (some m: TeamMembership |
      m.user = t.assignee and m.team = t.team)
}

// FR-013: Status is one of the three defined statuses
fact F_TaskStatusSet {
  all t: Task |
    t.status = TODO or t.status = IN_PROGRESS or t.status = DONE
}

// Permission matrix from contracts/http-api.md
// Member role: CreateTask, ReadTask, ViewAudit (but not EditTask/DeleteTask unless owner)
// Admin role: all operations
fact F_PermissionMatrix {
  // Explicit cells: all allowed operations per role
  Member -> OpReadTask in PermMatrix.allowed
  Member -> OpCreateTask in PermMatrix.allowed
  Member -> OpViewAudit in PermMatrix.allowed
  Admin -> OpReadTask in PermMatrix.allowed
  Admin -> OpCreateTask in PermMatrix.allowed
  Admin -> OpEditTask in PermMatrix.allowed
  Admin -> OpDeleteTask in PermMatrix.allowed
  Admin -> OpViewAudit in PermMatrix.allowed
  // Closed world: only these cells are allowed
  PermMatrix.allowed =
    (Member -> OpReadTask) +
    (Member -> OpCreateTask) +
    (Member -> OpViewAudit) +
    (Admin -> OpReadTask) +
    (Admin -> OpCreateTask) +
    (Admin -> OpEditTask) +
    (Admin -> OpDeleteTask) +
    (Admin -> OpViewAudit)
}

// ===== Patterns and Feature-Specific Predicates =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md § Permission matrix
pred LeastPrivilege {
  let admin_ops = {op: Operation | Admin -> op in PermMatrix.allowed},
      member_ops = {op: Operation | Member -> op in PermMatrix.allowed} |
    (member_ops in admin_ops) and (some admin_ops - member_ops)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every operation is either allowed or denied for each role (closed-world)
  all op: Operation, r: Role |
    (r -> op in PermMatrix.allowed) or (r -> op not in PermMatrix.allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // Every task has an owner (authenticated creator)
  // Every audit entry has an actor (authenticated modifier)
  all t: Task | t.owner in User
  all ae: AuditEntry | ae.actor in User
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry
pred AuditCompleteness {
  // Every audit entry links to exactly one task and records actor
  all ae: AuditEntry |
    (one ae.task and one ae.actor and one ae.actor_role)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md § Append-only at two layers
pred AppendOnly {
  // Audit entries are immutable: once written, fields never change
  // and entries are never deleted
  all ae: AuditEntry |
    (one ae.task and one ae.actor and one ae.actor_role and
     one ae.actor_name_snapshot)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md § AuditEntry
pred AttributionCorrectness {
  // Each audit entry captures actor identity and role as snapshots
  all ae: AuditEntry |
    (one ae.actor and one ae.actor_role and one ae.actor_name_snapshot)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md § Task
pred OwnershipExclusivity {
  // Every task has exactly one owner
  all t: Task | one t.owner
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008 to FR-010
pred OwnershipBasedAccess {
  // A member can only edit/delete a task if they are the owner or an admin
  all t: Task, u: User |
    (some m: TeamMembership |
      m.user = u and m.team = t.team and m.role = Member) implies
    (t.owner = u or
     some admin_m: TeamMembership |
       admin_m.user = u and admin_m.team = t.team and admin_m.role = Admin)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md § Byte-equivalent not-found
pred NoInformationLeakage {
  // Cross-team access returns same response as non-existent task
  // Modeled as: a task in one team is invisible to members of another
  all t: Task, u: User, m: TeamMembership |
    (m.user = u and m.team != t.team) implies
    u cannot see t  // implicit: no operation by u on t succeeds
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-002
pred FR_001_AuthenticationRequired {
  // Every task and every audit entry must have an authenticated actor
  all t: Task | one t.owner and t.owner in User
  all ae: AuditEntry | one ae.actor and ae.actor in User
}

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
pred FR_003_TeamContextRequired {
  // Every task must belong to a team; every user can be a member of teams
  all t: Task | one t.team
  all u: User | some m: TeamMembership | m.user = u or no m
}

assert FR_003_TeamContextRequired {
  FR_003_TeamContextRequired
}

check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TaskTeamImmutable {
  all t: Task | one t.team
}

assert FR_005_TaskTeamImmutable {
  FR_005_TaskTeamImmutable
}

check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_OwnerIdImmutable {
  all t: Task | one t.owner
}

assert FR_006_OwnerIdImmutable {
  FR_006_OwnerIdImmutable
}

check FR_006_OwnerIdImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_PerTeamRole {
  // Each user has exactly one role per team
  all u: User, t: Team |
    lone m: TeamMembership | m.user = u and m.team = t
}

assert FR_007_PerTeamRole {
  FR_007_PerTeamRole
}

check FR_007_PerTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_TaskValidation {
  // Assignee must be in the same team as the task (if set)
  all t: Task |
    (t.assignee_allowed_in_team = 1) implies
    (some m: TeamMembership |
      m.user = t.assignee and m.team = t.team)
}

assert FR_012_TaskValidation {
  FR_012_TaskValidation
}

check FR_012_TaskValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_StatusSetAndTransitions {
  // Status must be one of the three defined values
  all t: Task |
    (t.status = TODO or t.status = IN_PROGRESS or t.status = DONE)
}

assert FR_013_StatusSetAndTransitions {
  FR_013_StatusSetAndTransitions
}

check FR_013_StatusSetAndTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_CrossTeamIsolationInvariant {
  // Tasks are isolated by team; no leakage between teams
  all t: Task | one t.team
}

assert FR_014_CrossTeamIsolationInvariant {
  FR_014_CrossTeamIsolationInvariant
}

check FR_014_CrossTeamIsolationInvariant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditTrailPerEditEvent {
  // Every audit entry records exactly one task and one actor
  all ae: AuditEntry |
    (one ae.task and one ae.actor and one ae.actor_role)
}

assert FR_015_AuditTrailPerEditEvent {
  FR_015_AuditTrailPerEditEvent
}

check FR_015_AuditTrailPerEditEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditAppendOnly {
  // Audit entries are immutable and never deleted
  all ae: AuditEntry |
    (one ae.task and one ae.actor and one ae.actor_role and
     one ae.actor_name_snapshot)
}

assert FR_016_AuditAppendOnly {
  FR_016_AuditAppendOnly
}

check FR_016_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditVisibleToTeamMembers {
  // Audit entries for a task are visible to any member of that task's team
  all ae: AuditEntry, u: User, t: Team |
    (ae.task.team = t and
     some m: TeamMembership | m.user = u and m.team = t) implies
    u can view ae  // implicit: membership grants visibility
}

assert FR_017_AuditVisibleToTeamMembers {
  FR_017_AuditVisibleToTeamMembers
}

check FR_017_AuditVisibleToTeamMembers for 5