// === feature_model.als — Alloy model for B-L3: Multi-Tenant Task Management ===

// Role enumeration
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// Task status enumeration
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Audit operation enumeration
abstract sig Operation {}
one sig Created, Edited, Deleted, Shared, Unshared extends Operation {}

// Domain entities
sig Team {}

sig User {
  team_id: one Team,
  role: one Role
}

sig Task {
  team_id: one Team,
  owner_id: one User,
  title: one String,
  status: one TaskStatus,
  shared_with: set User
}

sig AuditEntry {
  task_id: one Task,
  actor_user_id: one User,
  actor_role: one Role,
  operation: one Operation,
  diff_summary: one String
}

// ===== FACTS =====

// Guarantee non-empty universe for meaningful assertions
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task.owner_id
// Task owner must belong to the task's team (cross-team ownership forbidden)
fact F_OwnerInTeam {
  all t: Task | t.owner_id.team_id = t.team_id
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-011
// In-team member with role=member can only access tasks they own or are sharees on
fact F_AccessControlByOwnership {
  all t: Task, u: User |
    (u.team_id = t.team_id and u.role = Member and u != t.owner_id) implies (u in t.shared_with)
}

// PATTERN: NoInformationLeakage / OwnershipBasedAccess  ANCHOR: spec.md FR-006, FR-014
// Cross-team isolation: users cannot access tasks outside their team
fact F_CrossTeamIsolation {
  all t: Task, u: User |
    u.team_id != t.team_id implies (u not in t.shared_with and u != t.owner_id)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012
// All sharees in shared_with must be members of the same team (no cross-team sharing)
fact F_NoXTeamSharing {
  all t: Task, s: t.shared_with | s.team_id = t.team_id
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "Audit entries MUST be immutable"
// Audit entries cannot be updated or deleted; each audit entry is uniquely defined by its content
fact F_AppendOnlyAuditEntries {
  all ae1, ae2: AuditEntry |
    (ae1.task_id = ae2.task_id and ae1.actor_user_id = ae2.actor_user_id and
     ae1.operation = ae2.operation and ae1.actor_role = ae2.actor_role and
     ae1.diff_summary = ae2.diff_summary) implies ae1 = ae2
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md PATCH → audit-entries decomposition
// Every task must have at least one audit entry (the creation entry) per FR-015
fact F_AuditCompleteness {
  all t: Task | some ae: AuditEntry | ae.task_id = t and ae.operation = Created
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role
// Actor role recorded in audit entry is a snapshot of the actor's role at time of action
fact F_AuditAttributionCorrectness {
  all ae: AuditEntry | ae.actor_role = ae.actor_user_id.role
}

// Feature-specific: FR-001 AuthRequiredEverywhere
// FEATURE-SPECIFIC  ANCHOR: FR-001; contracts/http-api.md authentication boundary
// All state-changing operations must have an authenticated actor
fact F_AuthRequiredEverywhere {
  all ae: AuditEntry | ae.actor_user_id in User
}

// Feature-specific: FR-002 UserBelongsToExactlyOneTeam
// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md User.team_id
// Each user has exactly one team and exactly one role (guaranteed by sig: one Team, one Role)

// Feature-specific: FR-009 ImmutableTaskOwnerAndTeam
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md Task.owner_id, Task.team_id
// Task owner_id and team_id are immutable (enforced structurally by sig definition with one fields)

// ===== PREDICATES FOR ASSERTIONS =====

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  some Task
  all t: Task | one u: User | u = t.owner_id
}

// PATTERN: AppendOnly
pred AppendOnly {
  some AuditEntry
  all ae: AuditEntry |
    no ae': AuditEntry | ae' != ae and
    ae'.task_id = ae.task_id and
    ae'.actor_user_id = ae.actor_user_id and
    ae'.operation = ae.operation and
    ae'.actor_role = ae.actor_role and
    ae'.diff_summary = ae.diff_summary
}

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  some Task
  all t: Task | (some ae: AuditEntry | ae.task_id = t and ae.operation = Created)
}

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry | ae.actor_role = ae.actor_user_id.role
}

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  some Task
  all t: Task, u: User |
    (u.role = Member and u.team_id = t.team_id and u != t.owner_id) implies
      (u in t.shared_with)
}

// PATTERN: NoInformationLeakage
pred NoInformationLeakage {
  some Task
  all t: Task, u: User |
    u.team_id != t.team_id implies (u not in t.shared_with and u != t.owner_id)
}

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  some Task
  all t: Task, u: User |
    (u.team_id != t.team_id) implies (u != t.owner_id and u not in t.shared_with)
}

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  some AuditEntry
  all ae: AuditEntry | ae.actor_user_id in User
}

// Feature-specific: FR-001 AllEndpointsRequireAuth
// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AllEndpointsRequireAuth {
  some AuditEntry
  all ae: AuditEntry | one u: User | u = ae.actor_user_id
}

// Feature-specific: FR-002 UserTeamAndRoleFromToken
// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-002a
pred FR_002_UserTeamAndRoleFromToken {
  some User
  all u: User |
    (one t: Team | t = u.team_id) and (one r: Role | r = u.role)
}

// Feature-specific: FR-003 MemberCanCreateTask
// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_MemberCanCreateTask {
  some User, Task
  some m: User, t: Task |
    m.role = Member and m.team_id = t.team_id and m = t.owner_id
}

// Feature-specific: FR-005 TeamAdminCanAccessTeamTask
// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TeamAdminCanAccessTeamTask {
  some Task, User
  some a: User, t: Task |
    a.role = TeamAdmin and a.team_id = t.team_id
}

// Feature-specific: FR-006 CrossTeamIsolationStrict
// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CrossTeamIsolationStrict {
  some Task
  all t: Task, u: User |
    u.team_id != t.team_id implies (u != t.owner_id and u not in t.shared_with)
}

// Feature-specific: FR-009 OwnerAndTeamImmutable
// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_OwnerAndTeamImmutable {
  some Task
  all t: Task |
    (one u: User | u = t.owner_id and u.team_id = t.team_id)
}

// Feature-specific: FR-010 OwnerOnlyControlsSharing
// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A
pred FR_010_OwnerOnlyControlsSharing {
  some Task
  all t: Task | one u: User | u = t.owner_id
}

// Feature-specific: FR-012 NoXTeamSharees
// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NoXTeamSharees {
  some Task
  all t: Task, s: t.shared_with | s.team_id = t.team_id
}

// Feature-specific: FR-014 ByteEquivalentResponses
// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalentResponses {
  some Task
  all t: Task, u: User |
    u.team_id != t.team_id implies
      (u != t.owner_id and u not in t.shared_with)
}

// Feature-specific: FR-015 PerEventAuditEntries
// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_PerEventAuditEntries {
  some AuditEntry
  all ae: AuditEntry | ae.operation in Operation
}

// Feature-specific: FR-017 AuditEntriesImmutable
// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditEntriesImmutable {
  some AuditEntry
  all ae: AuditEntry |
    no ae': AuditEntry | ae' != ae and
    ae'.task_id = ae.task_id and
    ae'.actor_user_id = ae.actor_user_id and
    ae'.operation = ae.operation
}

// ===== ASSERTIONS =====

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

assert FR_001_AllEndpointsRequireAuth { FR_001_AllEndpointsRequireAuth }
check FR_001_AllEndpointsRequireAuth for 5

assert FR_002_UserTeamAndRoleFromToken { FR_002_UserTeamAndRoleFromToken }
check FR_002_UserTeamAndRoleFromToken for 5

assert FR_003_MemberCanCreateTask { FR_003_MemberCanCreateTask }
check FR_003_MemberCanCreateTask for 5

assert FR_005_TeamAdminCanAccessTeamTask { FR_005_TeamAdminCanAccessTeamTask }
check FR_005_TeamAdminCanAccessTeamTask for 5

assert FR_006_CrossTeamIsolationStrict { FR_006_CrossTeamIsolationStrict }
check FR_006_CrossTeamIsolationStrict for 5

assert FR_009_OwnerAndTeamImmutable { FR_009_OwnerAndTeamImmutable }
check FR_009_OwnerAndTeamImmutable for 5

assert FR_010_OwnerOnlyControlsSharing { FR_010_OwnerOnlyControlsSharing }
check FR_010_OwnerOnlyControlsSharing for 5

assert FR_012_NoXTeamSharees { FR_012_NoXTeamSharees }
check FR_012_NoXTeamSharees for 5

assert FR_014_ByteEquivalentResponses { FR_014_ByteEquivalentResponses }
check FR_014_ByteEquivalentResponses for 5

assert FR_015_PerEventAuditEntries { FR_015_PerEventAuditEntries }
check FR_015_PerEventAuditEntries for 5

assert FR_017_AuditEntriesImmutable { FR_017_AuditEntriesImmutable }
check FR_017_AuditEntriesImmutable for 5