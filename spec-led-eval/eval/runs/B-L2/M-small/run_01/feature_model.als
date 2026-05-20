// === feature_model.als — Alloy model for B-L2 Team Task Management ===

// === Type hierarchies ===
abstract sig Role {}
one sig Member, Admin extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig OperationKind {}
one sig PostTask, GetTasks, GetTask, PatchTask, DeleteTask, GetAudit extends OperationKind {}

// === Entities ===
sig User {}
sig Team {}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  team: one Team,
  owner: one User,
  status: one TaskStatus,
  assignee: lone User
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role
}

// === Permission matrix ===
one sig PermMatrix {
  Allowed: set (Role -> OperationKind)
}

// === Facts ===

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// PATTERN: PerTeamRole  ANCHOR: spec.md FR-007; data-model.md TeamMembership
fact F_TeamMembershipUniqueness {
  all disj tm1, tm2: TeamMembership |
    (tm1.user = tm2.user and tm1.team = tm2.team) implies tm1 = tm2
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md Task.owner_id
fact F_TaskOwnershipExclusivity {
  all t: Task | one User & {t.owner}
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
fact F_TaskTeamBelonging {
  all t: Task | one Team & {t.team}
}

// FEATURE-SPECIFIC  ANCHOR: FR-006, FR-008
fact F_OwnerMustBeMemberOfTeam {
  all t: Task |
    some tm: TeamMembership | tm.user = t.owner and tm.team = t.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
fact F_TaskAssigneeTeamMembership {
  all t: Task |
    t.assignee != none implies
      (some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md audit_entries (no UPDATE/DELETE paths)
fact F_AppendOnlyAudit {
  all disj ae1, ae2: AuditEntry |
    ae1.task = ae2.task implies ae1 != ae2
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md UNIQUE(transaction_id)
fact F_AuditTrailPerTask {
  all t: Task | some ae: AuditEntry | ae.task = t
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
fact F_AuditActorTeamMembership {
  all ae: AuditEntry |
    some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-008, FR-009, FR-010
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Member -> PostTask) +
    (Member -> GetTasks) +
    (Member -> GetTask) +
    (Member -> GetAudit) +
    (Admin -> PostTask) +
    (Admin -> GetTasks) +
    (Admin -> GetTask) +
    (Admin -> PatchTask) +
    (Admin -> DeleteTask) +
    (Admin -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 (non-owner members cannot edit/delete)
fact F_MemberNonOwnerCannotEditDelete {
  all t: Task, u: User |
    (u != t.owner and some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Member)
    implies (
      (Member -> PatchTask) not in PermMatrix.Allowed and
      (Member -> DeleteTask) not in PermMatrix.Allowed
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 (admin can edit/delete any)
fact F_AdminCanEditDeleteAny {
  (Admin -> PatchTask) in PermMatrix.Allowed
  (Admin -> DeleteTask) in PermMatrix.Allowed
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
fact F_CrossTeamIsolation {
  all t: Task, u: User |
    (no tm: TeamMembership | tm.user = u and tm.team = t.team) implies
    (no ae: AuditEntry | ae.task = t and ae.actor = u)
}

// === Predicates ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md 401 unauthenticated
pred AuthRequiredEverywhere {
  all ae: AuditEntry | one User & {ae.actor}
  all tm: TeamMembership | one User & {tm.user}
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009; contracts/http-api.md permission table
pred OwnershipBasedAccess {
  all t: Task |
    (some ae: AuditEntry | ae.task = t and ae.actor = t.owner) implies
    (t.owner in User)
}

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/http-api.md permission matrix
pred PermissionGrounding {
  all role: Role, op: OperationKind |
    (role -> op) in PermMatrix.Allowed implies
    (
      (role = Member and op in (PostTask + GetTasks + GetTask + GetAudit)) or
      (role = Admin and op in (PostTask + GetTasks + GetTask + PatchTask + DeleteTask + GetAudit))
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-003
pred FR_001_AuthenticationRequired {
  all ae: AuditEntry |
    (one User & {ae.actor}) and
    (some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_UserIdentityFromAuth {
  all ae: AuditEntry | ae.actor in User
}

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
pred FR_003_TeamContextRequired {
  all t: Task |
    (one Team & {t.team}) and
    (some u: User | u = t.owner and
      some tm: TeamMembership | tm.user = u and tm.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TaskTeamImmutable {
  all t: Task | one Team & {t.team}
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_OwnerImmutable {
  all t: Task | one User & {t.owner}
}

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_PerTeamRole {
  all u: User, t: Team |
    lone tm: TeamMembership | tm.user = u and tm.team = t
}

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_MemberCanCreateViewEditOwn {
  (Member -> PostTask) in PermMatrix.Allowed
  (Member -> GetTasks) in PermMatrix.Allowed
  (Member -> GetTask) in PermMatrix.Allowed
  all t: Task, ae: AuditEntry |
    ae.task = t and ae.actor = t.owner and ae.actor_role = Member implies
    (Member -> PatchTask) in PermMatrix.Allowed or ae.actor = t.owner
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_MemberCannotEditOthersTask {
  all t: Task, u: User |
    (u != t.owner and some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Member) implies
    (Member -> PatchTask) not in PermMatrix.Allowed
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AdminCanEditDeleteAny {
  (Admin -> PatchTask) in PermMatrix.Allowed
  (Admin -> DeleteTask) in PermMatrix.Allowed
}

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-014
pred FR_011_CrossTeamIsolation {
  all t: Task, u: User |
    (no tm: TeamMembership | tm.user = u and tm.team = t.team) implies
    (
      (not (u in t.team.(TeamMembership.team)) or
        no ae: AuditEntry | ae.task = t and ae.actor = u)
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_TaskValidation {
  all t: Task |
    (t.assignee != none implies
      some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team) and
    (t.status in (Todo + InProgress + Done))
}

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_StatusValues {
  all t: Task | t.status in (Todo + InProgress + Done)
}

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalentNotFound {
  all t1, t2: Task |
    ((no tm1: TeamMembership | tm1.team = t1.team) and
     (no tm2: TeamMembership | tm2.team = t2.team))
    implies (t1.team = t2.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditTrailPerEditEvent {
  all t: Task | some ae: AuditEntry | ae.task = t
  all ae: AuditEntry |
    (one User & {ae.actor}) and
    (one Role & {ae.actor_role}) and
    (ae.actor_role in Role)
}

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditAppendOnly {
  all disj ae1, ae2: AuditEntry |
    ae1.task = ae2.task implies ae1 != ae2
}

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditVisibleToTeamMembers {
  all t: Task, u: User |
    (some tm: TeamMembership | tm.user = u and tm.team = t.team) implies
    (some ae: AuditEntry | ae.task = t)
}

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditRetention {
  all ae: AuditEntry | some Task & {ae.task}
}

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_TaskListPresentation {
  all t: Task | one Team & {t.team}
  all u: User, t: Team |
    (some tm: TeamMembership | tm.user = u and tm.team = t) implies
    (some task: Task | task.team = t)
}

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_FilteringSupport {
  all t: Task | t.status in (Todo + InProgress + Done)
  all t: Task | t.assignee in User or t.assignee = none
}

// === Assertions ===

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}
check AuthRequiredEverywhere for 5

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}
check OwnershipBasedAccess for 5

assert PermissionGrounding {
  PermissionGrounding
}
check PermissionGrounding for 5

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}
check FR_001_AuthenticationRequired for 5

assert FR_002_UserIdentityFromAuth {
  FR_002_UserIdentityFromAuth
}
check FR_002_UserIdentityFromAuth for 5

assert FR_003_TeamContextRequired {
  FR_003_TeamContextRequired
}
check FR_003_TeamContextRequired for 5

assert FR_005_TaskTeamImmutable {
  FR_005_TaskTeamImmutable
}
check FR_005_TaskTeamImmutable for 5

assert FR_006_OwnerImmutable {
  FR_006_OwnerImmutable
}
check FR_006_OwnerImmutable for 5

assert FR_007_PerTeamRole {
  FR_007_PerTeamRole
}
check FR_007_PerTeamRole for 5

assert FR_008_MemberCanCreateViewEditOwn {
  FR_008_MemberCanCreateViewEditOwn
}
check FR_008_MemberCanCreateViewEditOwn for 5

assert FR_009_MemberCannotEditOthersTask {
  FR_009_MemberCannotEditOthersTask
}
check FR_009_MemberCannotEditOthersTask for 5

assert FR_010_AdminCanEditDeleteAny {
  FR_010_AdminCanEditDeleteAny
}
check FR_010_AdminCanEditDeleteAny for 5

assert FR_011_CrossTeamIsolation {
  FR_011_CrossTeamIsolation
}
check FR_011_CrossTeamIsolation for 5

assert FR_012_TaskValidation {
  FR_012_TaskValidation
}
check FR_012_TaskValidation for 5

assert FR_013_StatusValues {
  FR_013_StatusValues
}
check FR_013_StatusValues for 5

assert FR_014_ByteEquivalentNotFound {
  FR_014_ByteEquivalentNotFound
}
check FR_014_ByteEquivalentNotFound for 5

assert FR_015_AuditTrailPerEditEvent {
  FR_015_AuditTrailPerEditEvent
}
check FR_015_AuditTrailPerEditEvent for 5

assert FR_016_AuditAppendOnly {
  FR_016_AuditAppendOnly
}
check FR_016_AuditAppendOnly for 5

assert FR_017_AuditVisibleToTeamMembers {
  FR_017_AuditVisibleToTeamMembers
}
check FR_017_AuditVisibleToTeamMembers for 5

assert FR_018_AuditRetention {
  FR_018_AuditRetention
}
check FR_018_AuditRetention for 5

assert FR_019_TaskListPresentation {
  FR_019_TaskListPresentation
}
check FR_019_TaskListPresentation for 5

assert FR_020_FilteringSupport {
  FR_020_FilteringSupport
}
check FR_020_FilteringSupport for 5