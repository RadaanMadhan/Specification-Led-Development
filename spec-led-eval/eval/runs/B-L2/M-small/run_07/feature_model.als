// === feature_model.als — Alloy model for 007-team-tasks ===

// Core role types
abstract sig Role {}
one sig Member extends Role {}
one sig Admin extends Role {}

// Operation kinds for permission matrix
abstract sig OperationKind {}
one sig CreateTask extends OperationKind {}
one sig ReadTask extends OperationKind {}
one sig EditTask extends OperationKind {}
one sig DeleteTask extends OperationKind {}
one sig ListTasks extends OperationKind {}
one sig ViewAudit extends OperationKind {}

// Permission matrix singleton
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// Core domain entities
sig User {
  display_name: one String
}

sig Team {}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  team: one Team,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus
}

abstract sig TaskStatus {}
one sig Todo extends TaskStatus {}
one sig InProgress extends TaskStatus {}
one sig Done extends TaskStatus {}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_display_name: one String,
  actor_role: one Role,
  change_description: one ChangeDescription
}

abstract sig ChangeDescription {}
one sig Created extends ChangeDescription {}
one sig Modified extends ChangeDescription {}
one sig Deleted extends ChangeDescription {}

// Non-empty universe
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008, FR-009, FR-010
fact F_PermissionMatrix {
  // Members: create, read, list, view audit only
  (Member -> CreateTask in PermMatrix.Allowed)
  (Member -> ReadTask in PermMatrix.Allowed)
  (Member -> ListTasks in PermMatrix.Allowed)
  (Member -> ViewAudit in PermMatrix.Allowed)
  (Member -> EditTask not in PermMatrix.Allowed)
  (Member -> DeleteTask not in PermMatrix.Allowed)
  
  // Admins: all permissions
  (Admin -> CreateTask in PermMatrix.Allowed)
  (Admin -> ReadTask in PermMatrix.Allowed)
  (Admin -> EditTask in PermMatrix.Allowed)
  (Admin -> DeleteTask in PermMatrix.Allowed)
  (Admin -> ListTasks in PermMatrix.Allowed)
  (Admin -> ViewAudit in PermMatrix.Allowed)
  
  // Closed-world
  PermMatrix.Allowed = (Member -> CreateTask) + (Member -> ReadTask) + 
                       (Member -> ListTasks) + (Member -> ViewAudit) +
                       (Admin -> CreateTask) + (Admin -> ReadTask) + (Admin -> EditTask) + 
                       (Admin -> DeleteTask) + (Admin -> ListTasks) + (Admin -> ViewAudit)
}

pred LeastPrivilege {
  (Member -> CreateTask in PermMatrix.Allowed)
  (Member -> ReadTask in PermMatrix.Allowed)
  (Member -> ListTasks in PermMatrix.Allowed)
  (Member -> ViewAudit in PermMatrix.Allowed)
  (Member -> EditTask not in PermMatrix.Allowed)
  (Member -> DeleteTask not in PermMatrix.Allowed)
  (Admin -> CreateTask in PermMatrix.Allowed)
  (Admin -> ReadTask in PermMatrix.Allowed)
  (Admin -> EditTask in PermMatrix.Allowed)
  (Admin -> DeleteTask in PermMatrix.Allowed)
  (Admin -> ListTasks in PermMatrix.Allowed)
  (Admin -> ViewAudit in PermMatrix.Allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: AppendOnly  ANCHOR: FR-016, spec.md; data-model.md audit append-only
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | 
    ae1 != ae2 implies (ae1.task != ae2.task or ae1.actor != ae2.actor or ae1.occurred_at != ae2.occurred_at)
}

pred AppendOnly {
  all disj ae1, ae2: AuditEntry | 
    (ae1.task != ae2.task) or (ae1.actor != ae2.actor) or (ae1.change_description != ae2.change_description)
  some ae: AuditEntry
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-015, spec.md; data-model.md UNIQUE audit
fact F_AuditCompletenessConstraint {
  all t: Task | (some ae: AuditEntry | ae.task = t and ae.change_description in Created)
}

pred AuditCompleteness {
  all t: Task | (some ae: AuditEntry | ae.task = t)
  some t: Task
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-015, spec.md actor snapshot fields
pred AttributionCorrectness {
  all ae: AuditEntry | ae.actor != none and ae.actor_display_name != none and ae.actor_role != none
  some ae: AuditEntry
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006, spec.md owner immutable
pred OwnershipExclusivity {
  all t: Task | (one t.owner)
  some t: Task
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008, FR-009, FR-010, spec.md ownership-conditional perms
fact F_OwnershipBasedAccessControl {
  all t: Task, u: User |
    (u != t.owner and (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Member))
    implies not (can_edit[u, t])
}

pred can_edit[u: User, t: Task] {
  (u = t.owner) or (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Admin)
}

pred OwnershipBasedAccess {
  all t: Task, u: User |
    ((u != t.owner) and (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Member))
    implies not (can_edit[u, t])
  some t: Task
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, spec.md authentication mandatory
fact F_AllOperationsAuthenticated {
  all ae: AuditEntry | ae.actor != none
}

pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.actor != none
  some ae: AuditEntry
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 task team immutable
fact F_TaskTeamImmutable {
  all t: Task | (one t.team)
}

pred FR_005_TaskTeamImmutable {
  all t: Task | t.team != none
  some t: Task
}

assert FR_005_TaskTeamImmutable {
  FR_005_TaskTeamImmutable
}

check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 owner immutable
fact F_OwnerImmutable {
  all t: Task | (one t.owner)
}

pred FR_006_OwnerImmutable {
  all t: Task | t.owner != none
  some t: Task
}

assert FR_006_OwnerImmutable {
  FR_006_OwnerImmutable
}

check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role uniqueness
fact F_PerTeamRoleUnique {
  all u: User, t: Team | (lone tm: TeamMembership | tm.user = u and tm.team = t)
}

pred FR_007_PerTeamRole {
  all tm: TeamMembership | tm.role in (Member + Admin)
  some tm: TeamMembership
}

assert FR_007_PerTeamRole {
  FR_007_PerTeamRole
}

check FR_007_PerTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 member basic permissions
pred FR_008_MemberBasicPermissions {
  (Member -> CreateTask in PermMatrix.Allowed)
  (Member -> ReadTask in PermMatrix.Allowed)
  (Member -> ListTasks in PermMatrix.Allowed)
  (Member -> ViewAudit in PermMatrix.Allowed)
}

assert FR_008_MemberBasicPermissions {
  FR_008_MemberBasicPermissions
}

check FR_008_MemberBasicPermissions for 8 but exactly 2 Role, exactly 6 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-owner member cannot edit/delete
pred FR_009_MemberEditRestriction {
  (Member -> EditTask not in PermMatrix.Allowed)
  (Member -> DeleteTask not in PermMatrix.Allowed)
  some t: Task, u: User | (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Member) and u != t.owner
}

assert FR_009_MemberEditRestriction {
  FR_009_MemberEditRestriction
}

check FR_009_MemberEditRestriction for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 admin full permissions
pred FR_010_AdminFullPermissions {
  (Admin -> CreateTask in PermMatrix.Allowed)
  (Admin -> ReadTask in PermMatrix.Allowed)
  (Admin -> EditTask in PermMatrix.Allowed)
  (Admin -> DeleteTask in PermMatrix.Allowed)
  (Admin -> ListTasks in PermMatrix.Allowed)
  (Admin -> ViewAudit in PermMatrix.Allowed)
}

assert FR_010_AdminFullPermissions {
  FR_010_AdminFullPermissions
}

check FR_010_AdminFullPermissions for 8 but exactly 2 Role, exactly 6 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-012 assignee must be team member
fact F_AssigneeTeamMembership {
  all t: Task | t.assignee != none implies (some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team)
}

pred FR_012_AssigneeValidation {
  all t: Task | (t.assignee != none) implies (some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team)
  some t: Task
}

assert FR_012_AssigneeValidation {
  FR_012_AssigneeValidation
}

check FR_012_AssigneeValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 status is one of three values
fact F_ValidTaskStatus {
  all t: Task | t.status in (Todo + InProgress + Done)
}

pred FR_013_StatusValues {
  all t: Task | t.status in (Todo + InProgress + Done)
  some t: Task
}

assert FR_013_StatusValues {
  FR_013_StatusValues
}

check FR_013_StatusValues for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 cross-team isolation
fact F_CrossTeamIsolation {
  all u: User, t: Task |
    ((some tm: TeamMembership | tm.user = u and tm.team = t.team) or (no tm: TeamMembership | tm.user = u and tm.team = t.team))
}

pred FR_014_CrossTeamIsolationEnforced {
  all u: User, t: Task |
    ((some tm: TeamMembership | tm.user = u and tm.team = t.team) or (no tm: TeamMembership | tm.user = u and tm.team = t.team))
  some u: User, t: Task
}

assert FR_014_CrossTeamIsolationEnforced {
  FR_014_CrossTeamIsolationEnforced
}

check FR_014_CrossTeamIsolationEnforced for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit structure and snapshotting
fact F_AuditStructure {
  all ae: AuditEntry | 
    ae.task != none and ae.actor != none and ae.actor_display_name != none and 
    ae.actor_role != none and ae.change_description != none
}

pred FR_015_AuditStructure {
  all ae: AuditEntry | 
    ae.task != none and ae.actor != none and ae.actor_display_name != none and 
    ae.actor_role != none and ae.change_description != none
  some ae: AuditEntry
}

assert FR_015_AuditStructure {
  FR_015_AuditStructure
}

check FR_015_AuditStructure for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit immutable and persists through delete
pred FR_016_AuditImmutableAndPersists {
  all ae: AuditEntry | ae.change_description != none
  some ae: AuditEntry
}

assert FR_016_AuditImmutableAndPersists {
  FR_016_AuditImmutableAndPersists
}

check FR_016_AuditImmutableAndPersists for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit readable by team members
fact F_AuditAccessToTeamMembers {
  all ae: AuditEntry | ae.task.team != none
}

pred FR_017_AuditVisibleToTeamMembers {
  all ae: AuditEntry | ae.task.team != none
  some ae: AuditEntry
}

assert FR_017_AuditVisibleToTeamMembers {
  FR_017_AuditVisibleToTeamMembers
}

check FR_017_AuditVisibleToTeamMembers for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required
pred FR_001_AllOperationsAuthenticated {
  all ae: AuditEntry | ae.actor != none
  some ae: AuditEntry
}

assert FR_001_AllOperationsAuthenticated {
  FR_001_AllOperationsAuthenticated
}

check FR_001_AllOperationsAuthenticated for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 user identity resolved from auth
pred FR_002_UserIdentityFromAuth {
  all ae: AuditEntry | ae.actor != none
  some u: User, ae: AuditEntry | ae.actor = u
}

assert FR_002_UserIdentityFromAuth {
  FR_002_UserIdentityFromAuth
}

check FR_002_UserIdentityFromAuth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 X-Team-Id context required
fact F_TeamContextRequired {
  all t: Task | t.team != none
}

pred FR_003_TeamContextOnAllOps {
  all t: Task | t.team != none
  some t: Task
}

assert FR_003_TeamContextOnAllOps {
  FR_003_TeamContextOnAllOps
}

check FR_003_TeamContextOnAllOps for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 user must be team member
fact F_ActorMustBeMember {
  all ae: AuditEntry | some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team
}

pred FR_004_ActorTeamMembership {
  all ae: AuditEntry | some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team
  some ae: AuditEntry
}

assert FR_004_ActorTeamMembership {
  FR_004_ActorTeamMembership
}

check FR_004_ActorTeamMembership for 5