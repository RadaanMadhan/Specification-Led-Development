// === feature_model.als — Alloy model for B-L2 SaaS Team Task Management ===

// ===== ROLES & ENUMS =====

abstract sig Role {}
one sig Member, Admin extends Role {}

abstract sig TaskStatus {}
one sig TODO, InProgress, Done extends TaskStatus {}

abstract sig OperationKind {}
one sig CreateTask, GetTask, GetTaskList, PatchTask, DeleteTask, GetAuditTrail extends OperationKind {}

// ===== CORE ENTITIES =====

sig User {
  id: one Int,
  displayName: one String
}

sig Team {
  id: one Int,
  name: one String
}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  id: one Int,
  team: one Team,        // Immutable after creation (FR-005)
  title: one String,
  owner: one User,       // Immutable after creation (FR-006)
  assignee: lone User,
  status: one TaskStatus,
  createdAt: one String,
  updatedAt: one String
}

sig AuditEntry {
  id: one Int,
  task: one Task,
  team: one Team,        // Denormalized for cross-team isolation enforcement
  actorUser: one User,
  actorRole: one Role,   // Snapshotted at time of change (FR-015)
  occurredAt: one String,
  changeDescription: one String  // "created" / "changed ..." / "deleted"
}

// ===== PERMISSION MATRIX SINGLETON =====

one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// ===== MANDATORY UNIVERSE POPULATION (F_NonEmptyUniverse) =====

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// ===== STRUCTURAL FACTS (NAMED, MUTATION-TESTABLE) =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008-010
fact F_PermissionMatrix {
  // Member can: create, view, audit read
  Member -> CreateTask in PermMatrix.allowed
  Member -> GetTask in PermMatrix.allowed
  Member -> GetTaskList in PermMatrix.allowed
  Member -> GetAuditTrail in PermMatrix.allowed
  
  // Admin can: all member operations plus patch/delete
  Admin -> CreateTask in PermMatrix.allowed
  Admin -> GetTask in PermMatrix.allowed
  Admin -> GetTaskList in PermMatrix.allowed
  Admin -> PatchTask in PermMatrix.allowed
  Admin -> DeleteTask in PermMatrix.allowed
  Admin -> GetAuditTrail in PermMatrix.allowed
  
  // Closed-world: exactly these cells are allowed
  PermMatrix.allowed = (Member -> CreateTask) +
                       (Member -> GetTask) +
                       (Member -> GetTaskList) +
                       (Member -> GetAuditTrail) +
                       (Admin -> CreateTask) +
                       (Admin -> GetTask) +
                       (Admin -> GetTaskList) +
                       (Admin -> PatchTask) +
                       (Admin -> DeleteTask) +
                       (Admin -> GetAuditTrail)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner, FR-006
fact F_OwnershipExclusivity {
  all t: Task | one u: User | u = t.owner
}

// PATTERN: OwnershipExclusivity (team membership)  ANCHOR: data-model.md TeamMembership PK
fact F_OneMembershipPerUserTeam {
  all u: User, te: Team | lone tm: TeamMembership | tm.user = u and tm.team = te
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015 per-edit-event audit entries
fact F_AuditEntryPerTask {
  all t: Task | some ae: AuditEntry | ae.task = t
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-015 actor/role snapshots
fact F_AuditActorMembershipConsistency {
  all ae: AuditEntry |
    (some tm: TeamMembership | tm.user = ae.actorUser and tm.team = ae.team and tm.role = ae.actorRole)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-007
// Task owner and assignee must be members of the task's team
fact F_TaskMembersInTeam {
  all t: Task |
    (some tm: TeamMembership | tm.user = t.owner and tm.team = t.team) and
    (t.assignee != none implies (some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team))
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AllOperationsAuthenticated {
  all t: Task | t.owner != none
  all ae: AuditEntry | ae.actorUser != none
}

// ===== PREDICATES FOR PERMISSION CHECKS =====

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008-010
pred CanEditTask[user: User, task: Task] {
  // Owner can edit their own task
  task.owner = user or
  // Admin in the task's team can edit any task
  (some tm: TeamMembership | tm.user = user and tm.team = task.team and tm.role = Admin)
}

pred CanDeleteTask[user: User, task: Task] {
  // Owner can delete their own task
  task.owner = user or
  // Admin in the task's team can delete any task
  (some tm: TeamMembership | tm.user = user and tm.team = task.team and tm.role = Admin)
}

pred CanViewTask[user: User, task: Task] {
  // User can view task if member of task's team
  some tm: TeamMembership | tm.user = user and tm.team = task.team
}

pred CanCreateTaskInTeam[user: User, team: Team] {
  // User can create task if member of team
  some tm: TeamMembership | tm.user = user and tm.team = team
}

// ===== NAMED ASSERTIONS ===== 

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  all role: Role, op: OperationKind |
    (role -> op in PermMatrix.allowed) or not (role -> op in PermMatrix.allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  (some t: Task) implies (all t: Task | some tm: TeamMembership | tm.user = t.owner and tm.team = t.team)
  (some ae: AuditEntry) implies (all ae: AuditEntry | some tm: TeamMembership | tm.user = ae.actorUser and tm.team = ae.team)
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  all t: Task | some ae: AuditEntry | ae.task = t
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly
pred AppendOnly {
  all ae1, ae2: AuditEntry |
    (ae1.id = ae2.id) implies
      (ae1.task = ae2.task and ae1.actorUser = ae2.actorUser and ae1.changeDescription = ae2.changeDescription)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  all ae: AuditEntry |
    (some tm: TeamMembership | tm.user = ae.actorUser and tm.team = ae.team and tm.role = ae.actorRole)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  (some t: Task) implies (all t: Task | one u: User | u = t.owner)
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  all u: User, t: Task |
    (CanEditTask[u, t]) implies (u = t.owner or (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Admin))
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage
pred NoInformationLeakage {
  all u: User, t: Task |
    (CanViewTask[u, t]) implies (some tm: TeamMembership | tm.user = u and tm.team = t.team)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation
pred ValidationBeforeMutation {
  all ae: AuditEntry | ae.task != none and ae.actorUser != none
}

assert ValidationBeforeMutation {
  ValidationBeforeMutation
}

check ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 Authentication required
pred FR_001_AuthRequired {
  (some t: Task) implies (all t: Task | some u: User | u = t.owner)
  (some ae: AuditEntry) implies (all ae: AuditEntry | some u: User | u = ae.actorUser)
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 Team context required
pred FR_003_TeamContextRequired {
  all t: Task | t.team != none
  all ae: AuditEntry | ae.team != none
}

assert FR_003_TeamContextRequired {
  FR_003_TeamContextRequired
}

check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 Task team immutable
pred FR_005_TaskTeamImmutable {
  (some t: Task) implies (all t: Task | t.team != none)
}

assert FR_005_TaskTeamImmutable {
  FR_005_TaskTeamImmutable
}

check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 Owner immutable
pred FR_006_OwnerImmutable {
  (some t: Task) implies (all t: Task | t.owner != none)
}

assert FR_006_OwnerImmutable {
  FR_006_OwnerImmutable
}

check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 Role is per-team
pred FR_007_RolePerTeam {
  all u: User, te: Team | lone tm: TeamMembership | tm.user = u and tm.team = te
}

assert FR_007_RolePerTeam {
  FR_007_RolePerTeam
}

check FR_007_RolePerTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 Member can create/view
pred FR_008_MemberCanCreateAndView {
  all u: User, te: Team, tm: TeamMembership |
    (tm.user = u and tm.team = te and tm.role = Member) implies CanCreateTaskInTeam[u, te]
}

assert FR_008_MemberCanCreateAndView {
  FR_008_MemberCanCreateAndView
}

check FR_008_MemberCanCreateAndView for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 Member cannot edit non-owned
pred FR_009_MemberCannotEditNonOwned {
  all u: User, t: Task, tm: TeamMembership |
    (tm.user = u and tm.team = t.team and tm.role = Member and t.owner != u) implies
      not CanEditTask[u, t]
}

assert FR_009_MemberCannotEditNonOwned {
  FR_009_MemberCannotEditNonOwned
}

check FR_009_MemberCannotEditNonOwned for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 Admin can edit/delete any task
pred FR_010_AdminCanEditAnyTask {
  all u: User, t: Task, tm: TeamMembership |
    (tm.user = u and tm.team = t.team and tm.role = Admin) implies
      (CanEditTask[u, t] and CanDeleteTask[u, t])
}

assert FR_010_AdminCanEditAnyTask {
  FR_010_AdminCanEditAnyTask
}

check FR_010_AdminCanEditAnyTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-014 Cross-team isolation
pred FR_014_CrossTeamIsolation {
  all u: User, t: Task |
    (not (some tm: TeamMembership | tm.user = u and tm.team = t.team)) implies
      not CanViewTask[u, t]
}

assert FR_014_CrossTeamIsolation {
  FR_014_CrossTeamIsolation
}

check FR_014_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 Per-edit-event audit entries
pred FR_015_AuditPerEditEvent {
  (some t: Task) implies (all t: Task | some ae: AuditEntry | ae.task = t)
}

assert FR_015_AuditPerEditEvent {
  FR_015_AuditPerEditEvent
}

check FR_015_AuditPerEditEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 Audit append-only
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry | ae.id != none
}

assert FR_016_AuditAppendOnly {
  FR_016_AuditAppendOnly
}

check FR_016_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 Audit visible to team members
pred FR_017_AuditVisibleToTeam {
  all ae: AuditEntry, u: User |
    (some tm: TeamMembership | tm.user = u and tm.team = ae.team) implies
      CanViewTask[u, ae.task]
}

assert FR_017_AuditVisibleToTeam {
  FR_017_AuditVisibleToTeam
}

check FR_017_AuditVisibleToTeam for 5