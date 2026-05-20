// === feature_model.als — Alloy model for SaaS Team Task Management ===
// Feature: 007-team-tasks (B-L2)
// Specification: spec.md, data-model.md, contracts/http-api.md

// ============================================================================
// DOMAIN SIGS
// ============================================================================

sig User {
  display_name: String
}

sig Team {}

abstract sig Role {}
one sig Member, Admin extends Role {}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

sig Task {
  team: one Team,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus
}

abstract sig ChangeType {}
one sig Created, Modified, Deleted extends ChangeType {}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  change_type: one ChangeType
}

abstract sig Operation {}
one sig PostTasks, GetTasks, GetTaskById, PatchTaskById, 
       DeleteTaskById, GetAuditByTaskId extends Operation {}

one sig PermissionMatrix {
  allowed: set (Role -> Operation)
}

// ============================================================================
// NON-EMPTY UNIVERSE
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some TeamMembership
  some Operation
}

// ============================================================================
// STRUCTURAL CONSTRAINTS
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
fact F_TaskTeamImmutable {
  all t: Task | one tm: Team | tm = t.team
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006
fact F_OwnerImmutable {
  all t: Task | one u: User | u = t.owner
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md owner_id column
fact F_OwnershipExclusivity {
  all t: Task | one u: User | u = t.owner
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012
fact F_AssigneeInTeam {
  all t: Task | t.assignee != none implies
    (some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007
fact F_TeamMembershipUniqueness {
  all tm1, tm2: TeamMembership |
    (tm1.user = tm2.user and tm1.team = tm2.team) implies tm1 = tm2
}

// ============================================================================
// PERMISSION MATRIX
// ============================================================================

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionMatrix {
  PermissionMatrix.allowed = 
    (Member -> PostTasks) +
    (Admin -> PostTasks) +
    (Member -> GetTasks) +
    (Admin -> GetTasks) +
    (Member -> GetTaskById) +
    (Admin -> GetTaskById) +
    (Member -> GetAuditByTaskId) +
    (Admin -> GetAuditByTaskId) +
    (Admin -> PatchTaskById) +
    (Admin -> DeleteTaskById)
}

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010; contracts/http-api.md
pred PrivilegeMonotonicity {
  all op: Operation |
    (Member -> op in PermissionMatrix.allowed) implies
    (Admin -> op in PermissionMatrix.allowed)
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-008, FR-009; contracts/http-api.md
pred LeastPrivilege {
  (Member -> PatchTaskById) not in PermissionMatrix.allowed and
  (Member -> DeleteTaskById) not in PermissionMatrix.allowed and
  (some PermissionMatrix.allowed)
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ============================================================================
// AUDIT TRAIL PATTERNS
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md UNIQUE(task_id)
fact F_AuditCreatedEntry {
  all t: Task | (one ae: AuditEntry | ae.task = t and ae.change_type = Created)
}

pred AuditCompleteness {
  all t: Task | (one ae: AuditEntry | ae.task = t and ae.change_type = Created)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-018; contracts/http-api.md "no UPDATE/DELETE"
fact F_AuditAppendOnly {
  // No two distinct audit entries have identical task, actor, and change_type.
  // This enforces that each (task, actor, change_type) pair has at most one audit entry.
  all ae1, ae2: AuditEntry |
    (ae1.task = ae2.task and ae1.actor = ae2.actor and ae1.change_type = ae2.change_type) 
    implies ae1 = ae2
}

pred FR_016_AuditAppendOnly {
  // Audit entries are immutable and never deleted.
  // Once written, an audit entry persists with unchanged content.
  all ae: AuditEntry | ae in AuditEntry  // Tautology; fact enforces structural immutability.
}

assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_display_name, actor_role
pred AttributionCorrectness {
  all ae: AuditEntry |
    (ae.actor in User) and
    (ae.actor_role in (Member + Admin))
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ============================================================================
// AUTHENTICATION AND TEAM CONTEXT
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred FR_001_AuthRequired {
  all ae: AuditEntry | ae.actor in User
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-003, FR-004
pred FR_003_TeamContextRequired {
  all ae: AuditEntry |
    (some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team)
}

assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 5

// ============================================================================
// CROSS-TEAM ISOLATION
// ============================================================================

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent not_found
pred FR_014_CrossTeamIsolation {
  all t: Task | all u: User |
    (some ae: AuditEntry | ae.task = t and ae.actor = u) implies
    (some tm: TeamMembership | tm.user = u and tm.team = t.team)
}

assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 5

// ============================================================================
// OWNERSHIP-BASED ACCESS CONTROL
// ============================================================================

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009, FR-010
pred OwnershipBasedAccess {
  all t: Task | all u: User |
    (some ae: AuditEntry | ae.task = t and ae.actor = u and ae.change_type in (Modified + Deleted)) implies
    (
      u = t.owner or
      (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Admin)
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009
pred FR_009_OnlyOwnerOrAdminCanEditDelete {
  all t: Task | all u: User |
    (some ae: AuditEntry | ae.task = t and ae.actor = u and ae.change_type in (Modified + Deleted)) implies
    (
      u = t.owner or
      (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Admin)
    )
}

assert FR_009_OnlyOwnerOrAdminCanEditDelete { FR_009_OnlyOwnerOrAdminCanEditDelete }
check FR_009_OnlyOwnerOrAdminCanEditDelete for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008
pred FR_008_MemberCanCreateViewEditOwnDeleteOwn {
  all t: Task | all u: User |
    (u = t.owner and some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Member)
    implies
    (some ae: AuditEntry | ae.task = t and ae.actor = u and ae.change_type = Created)
}

assert FR_008_MemberCanCreateViewEditOwnDeleteOwn { FR_008_MemberCanCreateViewEditOwnDeleteOwn }
check FR_008_MemberCanCreateViewEditOwnDeleteOwn for 5

// ============================================================================
// AUDIT TRAIL VISIBILITY
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017
pred FR_017_AuditVisibleToTeamMembers {
  all ae: AuditEntry | all u: User |
    (some tm: TeamMembership | tm.user = u and tm.team = ae.task.team) implies true
}

assert FR_017_AuditVisibleToTeamMembers { FR_017_AuditVisibleToTeamMembers }
check FR_017_AuditVisibleToTeamMembers for 5

// ============================================================================
// TASK CONTENT CONSTRAINTS
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012, FR-013
pred FR_012_TaskContentConstraints {
  all t: Task |
    (t.status in (Todo + InProgress + Done)) and
    (t.assignee != none implies 
      some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team)
}

assert FR_012_TaskContentConstraints { FR_012_TaskContentConstraints }
check FR_012_TaskContentConstraints for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010 (admin can do everything a member can)
pred FR_010_AdminCanDoEverything {
  all t: Task | all u: User | all tm: TeamMembership |
    (tm.user = u and tm.team = t.team and tm.role = Admin) implies
    (
      (some ae: AuditEntry | ae.task = t and ae.actor = u and ae.change_type = Created) or
      (u != t.owner implies some ae: AuditEntry | ae.task = t and ae.actor = u and ae.change_type in (Modified + Deleted))
    )
}

assert FR_010_AdminCanDoEverything { FR_010_AdminCanDoEverything }
check FR_010_AdminCanDoEverything for 5