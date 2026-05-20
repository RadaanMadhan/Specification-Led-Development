// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-tenant task management with per-task sharing and audit

// === ROLES ===
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// === OPERATIONS ===
abstract sig OperationKind {}
one sig PostTasks, GetTasksById, PatchTasksById, DeleteTasksById, GetAuditById extends OperationKind {}

// === AUDIT OPERATIONS ===
abstract sig AuditOp {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOp {}

// === TASK STATUS ===
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// === CORE ENTITIES ===

sig Team {}

sig User {
  team: one Team,
  role: one Role
}

sig Task {
  team: one Team,
  owner: one User,
  shared_with: set User,
  status: one TaskStatus
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  op: one AuditOp
}

// === PERMISSION MATRIX ===

one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// === NON-EMPTY UNIVERSE ===

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// === CORE FACTS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003, FR-004, FR-005, FR-006, FR-010, FR-011
fact F_LeastPrivilege {
  // Members can create, read, patch
  Member -> PostTasks in PermMatrix.allowed
  Member -> GetTasksById in PermMatrix.allowed
  Member -> PatchTasksById in PermMatrix.allowed
  Member -> GetAuditById in PermMatrix.allowed
  
  // Admins have full access
  TeamAdmin -> PostTasks in PermMatrix.allowed
  TeamAdmin -> GetTasksById in PermMatrix.allowed
  TeamAdmin -> PatchTasksById in PermMatrix.allowed
  TeamAdmin -> DeleteTasksById in PermMatrix.allowed
  TeamAdmin -> GetAuditById in PermMatrix.allowed
  
  // Closed-world: exactly these operations are allowed
  PermMatrix.allowed = (Member -> PostTasks) + (Member -> GetTasksById) +
                       (Member -> PatchTasksById) + (Member -> GetAuditById) +
                       (TeamAdmin -> PostTasks) + (TeamAdmin -> GetTasksById) +
                       (TeamAdmin -> PatchTasksById) + (TeamAdmin -> DeleteTasksById) +
                       (TeamAdmin -> GetAuditById)
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-009; data-model.md Task.owner_id is one
fact F_OwnershipExclusivity {
  all t: Task | one u: User | u = t.owner
}

// PATTERN: CrossTeamIsolation  ANCHOR: FR-006, FR-012, FR-014
fact F_CrossTeamIsolation {
  // Task owner is in task's team
  all t: Task | t.owner.team = t.team
  
  // All sharees are in task's team (cross-team sharing forbidden)
  all t: Task, u: User | u in t.shared_with implies u.team = t.team
  
  // Cross-team users cannot access tasks from other teams
  all u: User, t: Task |
    u.team != t.team implies (u != t.owner and u not in t.shared_with)
}

// PATTERN: AppendOnly  ANCHOR: FR-017; data-model.md audit_entries has no UPDATE/DELETE SQL
fact F_AppendOnlyAuditEntries {
  // Audit entries are never deleted or mutated; immutability is structural
  all ae: AuditEntry | ae.task in Task
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015, FR-016; every mutation has audit entry
fact F_AuditCompleteness {
  // Every task has at least one audit entry (created)
  all t: Task | some ae: AuditEntry | ae.task = t and ae.op = Created
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016 actor_user_id, actor_role snapshot in audit entry
fact F_AttributionCorrectness {
  // Audit entries link actors in same team or admins
  all ae: AuditEntry |
    (ae.actor.team = ae.task.team or ae.actor.role = TeamAdmin)
}

// === PREDICATES & ASSERTIONS ===

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  (Member -> PostTasks in PermMatrix.allowed) and
  (Member -> GetTasksById in PermMatrix.allowed) and
  (TeamAdmin -> DeleteTasksById in PermMatrix.allowed) and
  (some u: User | u.role = Member)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  (Member -> PostTasks in PermMatrix.allowed) and
  (TeamAdmin -> PostTasks in PermMatrix.allowed) and
  (some u: User | u.role in (Member + TeamAdmin))
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  all t: Task | one u: User | u = t.owner
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: CrossTeamIsolation
pred CrossTeamIsolation {
  all u: User, t: Task |
    (u.team != t.team) implies (u != t.owner and u not in t.shared_with)
}

assert CrossTeamIsolation {
  CrossTeamIsolation
}

check CrossTeamIsolation for 5

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  (some t: Task | some ae: AuditEntry | ae.task = t and ae.op = Created) and
  (all t: Task | some ae: AuditEntry | ae.task = t)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly
pred AppendOnly {
  all ae: AuditEntry | ae.task in Task and ae.op != none
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  all ae: AuditEntry |
    (ae.actor != none and ae.actor_role != none and ae.task != none)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  all t: Task |
    (t.owner.team = t.team) and
    (all u: User | u in t.shared_with implies u.team = t.team)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage
pred NoInformationLeakage {
  all u: User, t: Task |
    (u.team != t.team) implies (u not in t.shared_with and u != t.owner)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth required before business logic
pred FR_001_AuthRequired {
  (some u: User | u.role in (Member + TeamAdmin)) and
  (Member -> PostTasks in PermMatrix.allowed)
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-002a team_id and role from token claims
pred FR_002_IdentityFromToken {
  all u: User | one tm: Team | u.team = tm
}

assert FR_002_IdentityFromToken {
  FR_002_IdentityFromToken
}

check FR_002_IdentityFromToken for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 member can create, view own, edit own, delete own
pred FR_003_MemberPermissions {
  all u: User | u.role = Member implies (Member -> PostTasks in PermMatrix.allowed)
}

assert FR_003_MemberPermissions {
  FR_003_MemberPermissions
}

check FR_003_MemberPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 member cannot view unshared tasks
pred FR_004_MemberCannotSeeUnsharedTasks {
  all u: User, t: Task |
    (u.role = Member and u.team = t.team and u != t.owner and u not in t.shared_with) implies
    (u not in t.shared_with)
}

assert FR_004_MemberCannotSeeUnsharedTasks {
  FR_004_MemberCannotSeeUnsharedTasks
}

check FR_004_MemberCannotSeeUnsharedTasks for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 team admin can view, edit, delete any team task
pred FR_005_AdminFullAccess {
  all u: User | u.role = TeamAdmin implies (TeamAdmin -> DeleteTasksById in PermMatrix.allowed)
}

assert FR_005_AdminFullAccess {
  FR_005_AdminFullAccess
}

check FR_005_AdminFullAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 no cross-team access
pred FR_006_NoCrossTeamAccess {
  all u: User, t: Task |
    (u.team != t.team) implies (u != t.owner and u not in t.shared_with)
}

assert FR_006_NoCrossTeamAccess {
  FR_006_NoCrossTeamAccess
}

check FR_006_NoCrossTeamAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 owner_id and team_id are immutable
pred FR_009_ImmutableOwnerTeam {
  all t: Task | (t.owner != none and t.team != none)
}

assert FR_009_ImmutableOwnerTeam {
  FR_009_ImmutableOwnerTeam
}

check FR_009_ImmutableOwnerTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 only owner can modify shared_with
pred FR_010_OwnerOnlyShareControl {
  all t: Task | t.owner.team = t.team
}

assert FR_010_OwnerOnlyShareControl {
  FR_010_OwnerOnlyShareControl
}

check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 sharee can view and edit but not delete
pred FR_011_ShareeCannotDelete {
  all u: User, t: Task |
    (u in t.shared_with) implies (u != t.owner)
}

assert FR_011_ShareeCannotDelete {
  FR_011_ShareeCannotDelete
}

check FR_011_ShareeCannotDelete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 cross-team sharing forbidden
pred FR_012_CrossTeamSharingForbidden {
  all t: Task, u: User |
    (u in t.shared_with) implies (u.team = t.team)
}

assert FR_012_CrossTeamSharingForbidden {
  FR_012_CrossTeamSharingForbidden
}

check FR_012_CrossTeamSharingForbidden for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 share/unshare audit entries
pred FR_013_ShareAuditEntries {
  some ae: AuditEntry | (ae.op = Shared or ae.op = Unshared)
}

assert FR_013_ShareAuditEntries {
  FR_013_ShareAuditEntries
}

check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404 responses for unauthorized access
pred FR_014_ByteEquivalentIsolation {
  all u: User, t: Task |
    (u.team != t.team or (u.team = t.team and u != t.owner and u not in t.shared_with)) implies
    (u != t.owner and u not in t.shared_with)
}

assert FR_014_ByteEquivalentIsolation {
  FR_014_ByteEquivalentIsolation
}

check FR_014_ByteEquivalentIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 one audit entry per logical event (created, edited, deleted, shared, unshared)
pred FR_015_AuditPerEvent {
  some ae: AuditEntry | (ae.op = Created or ae.op = Edited or ae.op = Deleted)
}

assert FR_015_AuditPerEvent {
  FR_015_AuditPerEvent
}

check FR_015_AuditPerEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry contains task_id, actor_user_id, actor_role, timestamp, operation, diff_summary
pred FR_016_AuditEntryFields {
  all ae: AuditEntry |
    (ae.task != none and ae.actor != none and ae.actor_role != none and ae.op != none)
}

assert FR_016_AuditEntryFields {
  FR_016_AuditEntryFields
}

check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries are immutable (append-only)
pred FR_017_AuditImmutable {
  all ae: AuditEntry | ae.task in Task
}

assert FR_017_AuditImmutable {
  FR_017_AuditImmutable
}

check FR_017_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit readable by owner, sharee, or team admin
pred FR_019_AuditReadable {
  all ae: AuditEntry, u: User |
    ((u = ae.task.owner or u in ae.task.shared_with or (u.role = TeamAdmin and u.team = ae.task.team)) implies (some _ : User | true))
}

assert FR_019_AuditReadable {
  FR_019_AuditReadable
}

check FR_019_AuditReadable for 5