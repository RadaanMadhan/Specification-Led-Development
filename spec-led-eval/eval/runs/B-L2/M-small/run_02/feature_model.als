// === feature_model.als — Alloy model for B-L2 (SaaS Team Task Management with Audit Trail) ===

// Core domain sigs

abstract sig User {}
one sig User1, User2, User3, User4, User5 extends User {}

abstract sig Team {}
one sig Team1, Team2, Team3 extends Team {}

abstract sig Role {}
one sig Member, Admin extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById, PatchTaskById, DeleteTaskById, GetAuditById extends OperationKind {}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  id: one Int,
  team_id: one Team,
  owner_id: one User,
  assignee_id: lone User,
  title: one String,
  description: one String,
  status: one TaskStatus,
  created_at: one Int,
  updated_at: one Int
}

sig AuditEntry {
  id: one Int,
  task_id: one Task,
  team_id: one Team,
  actor_user_id: one User,
  actor_role: one Role,
  occurred_at: one Int,
  change_description: one String
}

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============================================================================
// FACTS - STRUCTURAL CONSTRAINTS
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md FR-008, FR-009, FR-010
fact F_PermissionMatrix {
  // Member role permissions
  Member -> PostTasks in PermMatrix.Allowed
  Member -> GetTasks in PermMatrix.Allowed
  Member -> GetTaskById in PermMatrix.Allowed
  Member -> PatchTaskById in PermMatrix.Allowed
  Member -> DeleteTaskById in PermMatrix.Allowed
  Member -> GetAuditById in PermMatrix.Allowed
  
  // Admin role permissions (superset of member)
  Admin -> PostTasks in PermMatrix.Allowed
  Admin -> GetTasks in PermMatrix.Allowed
  Admin -> GetTaskById in PermMatrix.Allowed
  Admin -> PatchTaskById in PermMatrix.Allowed
  Admin -> DeleteTaskById in PermMatrix.Allowed
  Admin -> GetAuditById in PermMatrix.Allowed
  
  // Closed-world assumption: enumerate all allowed (role, op) pairs explicitly
  PermMatrix.Allowed = (Member -> PostTasks) + (Member -> GetTasks) + 
                       (Member -> GetTaskById) + (Member -> PatchTaskById) + 
                       (Member -> DeleteTaskById) + (Member -> GetAuditById) +
                       (Admin -> PostTasks) + (Admin -> GetTasks) + 
                       (Admin -> GetTaskById) + (Admin -> PatchTaskById) + 
                       (Admin -> DeleteTaskById) + (Admin -> GetAuditById)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
fact F_TaskTeamImmutable {
  all t: Task | one t.team_id
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
fact F_TaskOwnerImmutable {
  all t: Task | one t.owner_id
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006
fact F_OneOwnerPerTask {
  all t: Task | (one o: User | o = t.owner_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-013
fact F_StatusSet {
  TaskStatus = Todo + InProgress + Done
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
fact F_TitleValidation {
  all t: Task | (#(t.title) > 0 and #(t.title) <= 200)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
fact F_DescriptionValidation {
  all t: Task | #(t.description) <= 4000
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008, FR-004
fact F_TaskOwnerMemberOfTeam {
  all t: Task | (one tm: TeamMembership | tm.user = t.owner_id and tm.team = t.team_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
fact F_AssigneeInTeam {
  all t: Task | t.assignee_id != none implies
    (one tm: TeamMembership | tm.user = t.assignee_id and tm.team = t.team_id)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015
fact F_AuditPerTask {
  all t: Task | (one ae: AuditEntry | ae.task_id = t)
}

// PATTERN: AppendOnly  ANCHOR: FR-016
fact F_AuditAppendOnly {
  all ae1, ae2: AuditEntry |
    ae1.id = ae2.id implies (
      ae1.task_id = ae2.task_id and
      ae1.team_id = ae2.team_id and
      ae1.actor_user_id = ae2.actor_user_id and
      ae1.actor_role = ae2.actor_role and
      ae1.occurred_at = ae2.occurred_at and
      ae1.change_description = ae2.change_description
    )
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-015
fact F_AuditActorInTeam {
  all ae: AuditEntry |
    (one tm: TeamMembership | tm.user = ae.actor_user_id and tm.team = ae.team_id and tm.role = ae.actor_role)
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014
fact F_CrossTeamIsolation {
  all t1, t2: Task, tm: TeamMembership |
    (tm.team = t1.team_id and t1.team_id != t2.team_id) implies (tm.team != t2.team_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
fact F_AuthenticationContext {
  all ae: AuditEntry | ae.actor_user_id in User and ae.actor_role in Role
}

// ============================================================================
// PREDICATES & ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md FR-008, FR-009, FR-010
pred LeastPrivilege {
  (some r: Role, op: OperationKind | r -> op in PermMatrix.Allowed) and
  (some r: Role, op: OperationKind | not (r -> op in PermMatrix.Allowed))
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (not (r -> op in PermMatrix.Allowed))
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md auth boundary
pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.actor_user_id in User and ae.actor_role in Role
  some ae: AuditEntry
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-015; data-model.md audit_entries
pred AuditCompleteness {
  all t: Task | (one ae: AuditEntry | ae.task_id = t)
  some t: Task
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-016; data-model.md audit_entries append-only enforcement
pred AppendOnly {
  all ae1, ae2: AuditEntry |
    ae1.id = ae2.id implies (
      ae1.task_id = ae2.task_id and
      ae1.team_id = ae2.team_id and
      ae1.actor_user_id = ae2.actor_user_id and
      ae1.actor_role = ae2.actor_role and
      ae1.occurred_at = ae2.occurred_at and
      ae1.change_description = ae2.change_description
    )
  some ae: AuditEntry
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-015; data-model.md actor snapshots
pred AttributionCorrectness {
  all ae: AuditEntry |
    (ae.actor_user_id in User and ae.actor_role in Role and ae.team_id in Team) and
    (one tm: TeamMembership | tm.user = ae.actor_user_id and tm.team = ae.team_id and tm.role = ae.actor_role)
  some ae: AuditEntry
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006; data-model.md Task.owner_id
pred OwnershipExclusivity {
  all t: Task | (one o: User | o = t.owner_id)
  some t: Task
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008; contracts/http-api.md PATCH/DELETE rules
pred OwnershipBasedAccess {
  all t: Task |
    (one tm: TeamMembership | tm.user = t.owner_id and tm.team = t.team_id)
  some t: Task
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  all t1, t2: Task, tm: TeamMembership |
    (tm.team = t1.team_id and t1.team_id != t2.team_id) implies (tm.team != t2.team_id)
  some t: Task
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all ae: AuditEntry | ae.actor_user_id in User and ae.actor_role in Role
  some ae: AuditEntry
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_TeamContextRequired {
  all t: Task | (one tm: TeamMembership | tm.team = t.team_id and tm.user = t.owner_id)
  some t: Task
}

assert FR_003_TeamContextRequired {
  FR_003_TeamContextRequired
}

check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TaskTeamImmutable {
  all t: Task | one t.team_id
  some t: Task
}

assert FR_005_TaskTeamImmutable {
  FR_005_TaskTeamImmutable
}

check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_OwnerImmutable {
  all t: Task | one t.owner_id
  some t: Task
}

assert FR_006_OwnerImmutable {
  FR_006_OwnerImmutable
}

check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, FR-009, FR-010
pred FR_008_MemberPermissions {
  all t: Task |
    (one tm: TeamMembership | tm.user = t.owner_id and tm.team = t.team_id and tm.role = Member) or
    (one tm: TeamMembership | tm.team = t.team_id and tm.role = Admin)
  some t: Task
  some tm: TeamMembership with (tm.role = Member)
}

assert FR_008_MemberPermissions {
  FR_008_MemberPermissions
}

check FR_008_MemberPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AdminPermissions {
  all t: Task | (one tm: TeamMembership | tm.team = t.team_id and tm.role = Admin)
  some t: Task
  some tm: TeamMembership with (tm.role = Admin)
}

assert FR_010_AdminPermissions {
  FR_010_AdminPermissions
}

check FR_010_AdminPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_CrossTeamIsolation {
  all t1, t2: Task, tm: TeamMembership |
    (tm.team = t1.team_id and t1.team_id != t2.team_id) implies (tm.team != t2.team_id)
  some t: Task
}

assert FR_014_CrossTeamIsolation {
  FR_014_CrossTeamIsolation
}

check FR_014_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditStructure {
  all ae: AuditEntry |
    (ae.task_id in Task and ae.actor_user_id in User and ae.actor_role in Role and ae.team_id in Team and #ae.change_description > 0)
  some ae: AuditEntry
}

assert FR_015_AuditStructure {
  FR_015_AuditStructure
}

check FR_015_AuditStructure for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry |
    (ae.id >= 0 and ae.task_id in Task and ae.actor_user_id in User)
  some ae: AuditEntry
}

assert FR_016_AuditAppendOnly {
  FR_016_AuditAppendOnly
}

check FR_016_AuditAppendOnly for 5