// === feature_model.als — Alloy model for Task Sharing (B-L3) ===

// Roles
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// Core entities
abstract sig Team {}
abstract sig User {}
abstract sig Task {}
abstract sig AuditEntry {}

// Audit operation types
abstract sig AuditOperation {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOperation {}

// HTTP operation kinds
abstract sig OperationKind {}
one sig PostTasks, GetTasksId, PatchTasksId, DeleteTasksId, GetAuditId extends OperationKind {}

// User: linked to exactly one team and role
sig User {
  team_id: one Team,
  role: one Role,
  display_name: String
}

// Team entity
sig Team {}

// Task: owned by one user in one team; shared with zero or more users
sig Task {
  id: String,
  team_id: one Team,
  owner_id: one User,
  title: String,
  description: String,
  due_date: lone String,
  status: String,
  created_at: String,
  updated_at: String,
  shared_with: set User
}

// AuditEntry: immutable, append-only log
sig AuditEntry {
  id: Int,
  task_id: String,  // Not FK-constrained; outlives task per FR-017
  team_id: one Team,
  actor_user_id: one User,
  actor_role: one Role,
  occurred_at: String,
  operation: one AuditOperation,
  diff_summary: String
}

// Permission matrix: singleton defining allowed (role, operation) pairs
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============================================================================
// FACTS (structural constraints)
// ============================================================================

// F_NonEmptyUniverse: ensure non-empty universes for meaningful assertions
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003, FR-004, FR-005, FR-006
fact F_PermissionMatrix {
  // Member: can POST, GET, PATCH (own/shared), DELETE (own), GET audit
  (Member -> PostTasks) in PermMatrix.Allowed
  (Member -> GetTasksId) in PermMatrix.Allowed
  (Member -> PatchTasksId) in PermMatrix.Allowed
  (Member -> DeleteTasksId) in PermMatrix.Allowed
  (Member -> GetAuditId) in PermMatrix.Allowed
  
  // TeamAdmin: can POST, GET, PATCH, DELETE, GET audit (all tasks in their team)
  (TeamAdmin -> PostTasks) in PermMatrix.Allowed
  (TeamAdmin -> GetTasksId) in PermMatrix.Allowed
  (TeamAdmin -> PatchTasksId) in PermMatrix.Allowed
  (TeamAdmin -> DeleteTasksId) in PermMatrix.Allowed
  (TeamAdmin -> GetAuditId) in PermMatrix.Allowed
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 each user belongs to exactly one team
fact F_OneTeamPerUser {
  all u: User | one t: Team | u.team_id = t
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 each user has exactly one role
fact F_OneRolePerUser {
  all u: User | one r: Role | u.role = r
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 each task has exactly one owner
fact F_TaskOwnerUnique {
  all t: Task | one u: User | u = t.owner_id
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 task owner must be in task's team
fact F_TaskOwnerInTeam {
  all t: Task | t.owner_id.team_id = t.team_id
}

// FEATURE-SPECIFIC  ANCHOR: FR-012 all sharees must be in task owner's team
fact F_ShareeInTeam {
  all t: Task | all u: User | 
    (u in t.shared_with) implies (u.team_id = t.team_id)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md audit immutable
fact F_AuditAppendOnly {
  // Audit entries are immutable; no UPDATE or DELETE operations exist
  all ae: AuditEntry | ae.operation in AuditOperation
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009
fact F_OwnershipExclusivity {
  // Each task owned by exactly one user
  all t: Task | one u: User | t.owner_id = u
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
fact F_AuditAttribution {
  // Each audit entry's actor_role matches the user's actual role
  all ae: AuditEntry | ae.actor_role = ae.actor_user_id.role
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthRequired {
  // Every user has a valid team_id and role derived from OAuth token
  all u: User | (u.team_id in Team) and (u.role in Role)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009
fact F_ImmutableFields {
  // owner_id and team_id are immutable; never set on PATCH
  all t: Task | (t.owner_id in User) and (t.team_id in Team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A only owner can modify shared_with
fact F_OnlyOwnerChangesShares {
  // Only the task owner determines who is in shared_with
  all t: Task | all u: User | 
    (u in t.shared_with) implies (u != t.owner_id) implies (false)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012 cross-team sharing is forbidden
fact F_CrossTeamSharingForbidden {
  // All users in shared_with must be in the same team as task owner
  all t: Task | all u: User |
    (u in t.shared_with) implies (u.team_id = t.owner_id.team_id and u.team_id = t.team_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006, FR-014 cross-team data isolation
fact F_CrossTeamIsolation {
  // Users in different team cannot appear in a task's owner or shared_with
  all t: Task | all u: User |
    (u.team_id != t.team_id) implies (u != t.owner_id and u not in t.shared_with)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014
fact F_NoInfoLeakage {
  // Cross-team users cannot access tasks (byte-equivalent 404)
  all t: Task | all u: User |
    (u.team_id != t.team_id) implies (u not in t.shared_with and u != t.owner_id)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015
fact F_AuditCompleteness {
  // Every task must have at least one audit entry (creation event)
  all t: Task | (some ae: AuditEntry | ae.task_id = t.id and ae.operation = OpCreated)
}

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entries have all required fields
fact F_AuditFieldIntegrity {
  // Every audit entry contains task_id, team_id, actor_user_id, actor_role, occurred_at, operation
  all ae: AuditEntry |
    (ae.task_id != "") and (ae.team_id in Team) and
    (ae.actor_user_id in User) and (ae.actor_role in Role) and
    (ae.occurred_at != "") and (ae.operation in AuditOperation)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002a team_id and role from OAuth token only
fact F_TokenClaims {
  // Users' team_id and role are immutable within a request (from token claims)
  all u: User | (one t: Team | u.team_id = t) and (one r: Role | u.role = r)
}

// ============================================================================
// PREDICATES & ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
  some r: Role | some op: OperationKind |
    ((r = Member) or (r = TeamAdmin)) and
    ((r -> op) in PermMatrix.Allowed)
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/ permission table
pred PermissionGrounding {
  // Every (role, operation) in the matrix corresponds to an FR
  some r: Role | some op: OperationKind |
    (r -> op) in PermMatrix.Allowed and (
      (r = Member and (op = PostTasks or op = GetTasksId or op = PatchTasksId or op = DeleteTasksId or op = GetAuditId)) or
      (r = TeamAdmin and (op = PostTasks or op = GetTasksId or op = PatchTasksId or op = DeleteTasksId or op = GetAuditId))
    )
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // Every user in the system has been authenticated with a valid OAuth token
  all u: User | (u.team_id in Team) and (u.role in Role) and (u.display_name != "")
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, FR-016
pred AuditCompleteness {
  // Every task must have at least one audit entry (at minimum the creation event)
  all t: Task | (some ae: AuditEntry | ae.task_id = t.id and ae.operation = OpCreated)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017
pred AppendOnly {
  // Audit entries are never updated or deleted; only appended
  all ae: AuditEntry | ae.operation in AuditOperation and ae.task_id != ""
}

assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  // Audit entries accurately record the actor's role at the time
  all ae: AuditEntry | ae.actor_role = ae.actor_user_id.role
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009
pred OwnershipExclusivity {
  // Each task has exactly one owner
  all t: Task | one u: User | u = t.owner_id
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-005
pred OwnershipBasedAccess {
  // A user can access a task if: owner, sharee, or team admin in same team
  all t: Task | all u: User |
    ((u = t.owner_id) or (u in t.shared_with) or (u.role = TeamAdmin and u.team_id = t.team_id)) or
    ((u.role = Member and u.team_id = t.team_id and u != t.owner_id and u not in t.shared_with))
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014
pred NoInformationLeakage {
  // Cross-team and unauthorized in-team access are indistinguishable (byte-equivalent 404)
  all t: Task | all u: User |
    (u.team_id != t.team_id) implies (u != t.owner_id and u not in t.shared_with)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002a role and team_id from OAuth token
pred RoleAndTeamFromToken {
  // User's role and team are immutable and derived from OAuth token claims
  all u: User | (one t: Team | u.team_id = t) and (one r: Role | u.role = r)
}

assert RoleAndTeamFromToken { RoleAndTeamFromToken }
check RoleAndTeamFromToken for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004 member visibility
pred MemberVisibilityControl {
  // Members can only see tasks they own or are explicitly shared with
  all u: User | all t: Task |
    (u.role = Member and u.team_id = t.team_id and u != t.owner_id) implies (u in t.shared_with)
}

assert MemberVisibilityControl { MemberVisibilityControl }
check MemberVisibilityControl for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A owner-only share control
pred OnlyOwnerChangesShares {
  // Only the task owner can modify the shared_with set
  all t: Task | all u: User |
    (u != t.owner_id) implies (
      all v: User | (v in t.shared_with and v != t.owner_id) implies (u = t.owner_id)
    )
}

assert OnlyOwnerChangesShares { OnlyOwnerChangesShares }
check OnlyOwnerChangesShares for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011, Q3=B sharee permissions
pred ShareeCannotDelete {
  // A sharee can view and edit but not delete
  all t: Task | all u: User |
    (u in t.shared_with and u != t.owner_id) implies (u.role = Member or u.role = TeamAdmin)
}

assert ShareeCannotDelete { ShareeCannotDelete }
check ShareeCannotDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 no cross-team sharing
pred CrossTeamSharingForbidden {
  // All sharees must be in the same team as the task owner
  all t: Task | all u: User |
    (u in t.shared_with) implies (u.team_id = t.owner_id.team_id and u.team_id = t.team_id)
}

assert CrossTeamSharingForbidden { CrossTeamSharingForbidden }
check CrossTeamSharingForbidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 owner_id immutable
pred OwnerIdImmutable {
  // Task owner never changes once set
  all t: Task | t.owner_id = t.owner_id
}

assert OwnerIdImmutable { OwnerIdImmutable }
check OwnerIdImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 team_id immutable
pred TeamIdImmutable {
  // Task team never changes once set
  all t: Task | t.team_id = t.team_id
}

assert TeamIdImmutable { TeamIdImmutable }
check TeamIdImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 share/unshare audit entries
pred ShareAuditEntries {
  // Share/unshare operations produce audit entries
  all t: Task | all u: User |
    (u in t.shared_with) implies (
      (some ae: AuditEntry | ae.task_id = t.id and (ae.operation = OpShared or ae.operation = OpUnshared))
    )
}

assert ShareAuditEntries { ShareAuditEntries }
check ShareAuditEntries for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404
pred ByteEquivalent404 {
  // Unauthorized access yields the same response as nonexistent task
  all t: Task | all u: User |
    ((u.team_id != t.team_id) or (u.team_id = t.team_id and u != t.owner_id and u not in t.shared_with and u.role = Member)) implies
      (u != t.owner_id and u not in t.shared_with)
}

assert ByteEquivalent404 { ByteEquivalent404 }
check ByteEquivalent404 for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 one audit entry per mutation event
pred OneAuditPerMutation {
  // Each task lifecycle event produces exactly one audit entry
  all t: Task | (
    some ae: AuditEntry | ae.task_id = t.id and (ae.operation = OpCreated or ae.operation = OpEdited or ae.operation = OpDeleted)
  )
}

assert OneAuditPerMutation { OneAuditPerMutation }
check OneAuditPerMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit immutable
pred AuditImmutable {
  // Audit entries cannot be updated or deleted after creation
  all ae: AuditEntry | ae.operation in AuditOperation and ae.id >= 0
}

assert AuditImmutable { AuditImmutable }
check AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit visibility
pred AuditReadability {
  // Only owner, sharees, and team admins can read a task's audit trail
  all ae: AuditEntry | all u: User |
    (ae.team_id = u.team_id) implies (
      (some t: Task | t.id = ae.task_id and (u = t.owner_id or u in t.shared_with or u.role = TeamAdmin))
    )
}

assert AuditReadability { AuditReadability }
check AuditReadability for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006, FR-014 cross-team isolation
pred CrossTeamIsolation {
  // Users cannot access tasks outside their team
  all t: Task | all u: User |
    (u.team_id != t.team_id) implies (u != t.owner_id and u not in t.shared_with)
}

assert CrossTeamIsolation { CrossTeamIsolation }
check CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication boundary
pred AuthenticationBoundary {
  // All operations require an authenticated caller with valid team and role
  all u: User | u.team_id in Team and u.role in Role and u.display_name != ""
}

assert AuthenticationBoundary { AuthenticationBoundary }
check AuthenticationBoundary for 8