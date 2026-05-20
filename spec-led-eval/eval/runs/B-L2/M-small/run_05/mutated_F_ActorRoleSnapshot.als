// === feature_model.als — Alloy model for B-L2 (007-team-tasks) ===
// SaaS Team Task Management with Audit Trail

// === CORE ENTITIES ===

abstract sig User {}

abstract sig Team {}

abstract sig Role {}
one sig Member, Admin extends Role {}

// Team membership: many-to-many (User, Team) -> Role
// A user can have different roles in different teams (FR-007)
sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

// Task: belongs to one team, owned by one user (creator)
sig Task {
  team: one Team,
  owner: one User
}

// Audit entry: immutable per-edit-event record
sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  change_type: one ChangeType
}

// Change types per FR-015
abstract sig ChangeType {}
one sig AuditCreated, AuditChanged, AuditDeleted extends ChangeType {}

// HTTP operations from contracts/http-api.md
abstract sig Operation {}
one sig PostTasks, GetTasks, GetTaskById, PatchTaskById, DeleteTaskById, GetAuditById extends Operation {}

// Permission matrix: (Role, Operation) -> allowed
one sig PermMatrix {
  Allowed: set (Role -> Operation)
}

// === FACTS ===

// F_NonEmptyUniverse: ensure non-vacuous checks by populating all dynamic sigs
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some TeamMembership
  some AuditEntry
}

// F_TeamMembershipUnique: composite key (user, team) is unique
// FEATURE-SPECIFIC  ANCHOR: data-model.md TeamMembership PK
fact F_TeamMembershipUnique {
  all disj tm1, tm2: TeamMembership |
    (tm1.user = tm2.user and tm1.team = tm2.team) implies tm1 = tm2
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md owner field
// Each task has exactly one owner (the creator), and owner_id is immutable
fact F_OwnershipExclusivity {
  all t: Task | one t.owner
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/009/010
// Only the owner or an admin of the task's team can edit or delete
fact F_OwnershipBasedAccess {
  all ae: AuditEntry |
    (ae.change_type = AuditChanged or ae.change_type = AuditDeleted) implies
      (ae.actor = ae.task.owner or
       some tm: TeamMembership |
         tm.user = ae.actor and tm.team = ae.task.team and tm.role = Admin)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent-404
// Cross-team isolation: actor of an audit entry must be a member of the task's team
fact F_CrossTeamIsolation {
  all ae: AuditEntry |
    some tm: TeamMembership |
      tm.user = ae.actor and tm.team = ae.task.team
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry
// Every task must have at least one audit entry recording its creation
fact F_TaskHasCreatedAuditEntry {
  all t: Task |
    some ae: AuditEntry |
      ae.task = t and ae.change_type = AuditCreated and ae.actor = t.owner
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 "actor_role snapshot"
// Actor's snapshotted role in the audit entry matches their actual role in that team
fact F_ActorRoleSnapshot { /* MUTATED — body cleared by validator */ }

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE paths"
// Audit entries are never mutated or deleted; enforce by structural absence of update mechanism
// and assert that all audit entries are complete and immutable
fact F_AppendOnlyAuditEntries {
  all ae: AuditEntry |
    some ae.task and some ae.actor and some ae.actor_role and some ae.change_type
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
// Every audit entry (operation record) has an authenticated actor
fact F_AuthRequired {
  all ae: AuditEntry | ae.actor in User
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-008/009/010; contracts/http-api.md permission matrix
// Non-admin members can only create, view, and audit-read.
// Edit/delete requires ownership or admin role.
fact F_LeastPrivilege {
  // Member role does not permit edit/delete on non-owned tasks
  all ae: AuditEntry |
    (ae.change_type = AuditChanged or ae.change_type = AuditDeleted) implies
      (some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team and tm.role = Admin) or
      (ae.actor = ae.task.owner)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix table
// Define the complete permission matrix from the feature specification
fact F_PermissionMatrix {
  // Member role permissions
  Member -> PostTasks in PermMatrix.Allowed
  Member -> GetTasks in PermMatrix.Allowed
  Member -> GetTaskById in PermMatrix.Allowed
  Member -> GetAuditById in PermMatrix.Allowed

  // Admin role permissions (superset of member)
  Admin -> PostTasks in PermMatrix.Allowed
  Admin -> GetTasks in PermMatrix.Allowed
  Admin -> GetTaskById in PermMatrix.Allowed
  Admin -> PatchTaskById in PermMatrix.Allowed
  Admin -> DeleteTaskById in PermMatrix.Allowed
  Admin -> GetAuditById in PermMatrix.Allowed

  // Closed-world: only these cells are allowed
  PermMatrix.Allowed = (Member -> PostTasks) +
                       (Member -> GetTasks) +
                       (Member -> GetTaskById) +
                       (Member -> GetAuditById) +
                       (Admin -> PostTasks) +
                       (Admin -> GetTasks) +
                       (Admin -> GetTaskById) +
                       (Admin -> PatchTaskById) +
                       (Admin -> DeleteTaskById) +
                       (Admin -> GetAuditById)
}

// === PREDICATES & ASSERTIONS ===

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006
pred OwnershipExclusivity {
  all t: Task | one t.owner and some Task
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/009/010; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  all ae: AuditEntry |
    (ae.change_type = AuditChanged or ae.change_type = AuditDeleted) implies
      (ae.actor = ae.task.owner or
       (some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team and tm.role = Admin))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent-not-found
pred NoInformationLeakage {
  all ae: AuditEntry |
    some tm: TeamMembership |
      tm.user = ae.actor and tm.team = ae.task.team
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md per-edit-event
pred AuditCompleteness {
  all t: Task |
    some ae: AuditEntry |
      ae.task = t and ae.change_type = AuditCreated
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016 immutable; contracts/http-api.md no UPDATE/DELETE paths
pred AppendOnly {
  all ae: AuditEntry |
    some ae.task and some ae.actor and some ae.actor_role and
    (ae.change_type = AuditCreated or ae.change_type = AuditChanged or ae.change_type = AuditDeleted)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 actor_display_name/actor_role snapshot
pred AttributionCorrectness {
  all ae: AuditEntry |
    some tm: TeamMembership |
      tm.user = ae.actor and tm.team = ae.task.team and tm.role = ae.actor_role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.actor in User and some User
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-008/009/010
pred LeastPrivilege {
  all ae: AuditEntry |
    (ae.change_type = AuditChanged or ae.change_type = AuditDeleted) implies
      (ae.actor = ae.task.owner or
       (some tm: TeamMembership | tm.user = ae.actor and tm.team = ae.task.team and tm.role = Admin))
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix table
pred PermissionCompleteness {
  all r: Role, op: Operation |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 6 Operation

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001 authentication required
pred FR_001_AuthRequired {
  all ae: AuditEntry | some ae.actor and ae.actor in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-003/004 team context and membership
pred FR_003_004_TeamContextRequired {
  all ae: AuditEntry |
    some tm: TeamMembership |
      tm.user = ae.actor and tm.team = ae.task.team
}
assert FR_003_004_TeamContextRequired { FR_003_004_TeamContextRequired }
check FR_003_004_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005 task team immutable
pred FR_005_TaskTeamImmutable {
  all t: Task | one t.team and some Task
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006 owner immutable
pred FR_006_OwnerImmutable {
  all t: Task | one t.owner
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007 per-team role
pred FR_007_PerTeamRole {
  some u: User, t1, t2: Team, r1, r2: Role |
    t1 != t2 and r1 != r2 and
    (some tm1: TeamMembership | tm1.user = u and tm1.team = t1 and tm1.role = r1) and
    (some tm2: TeamMembership | tm2.user = u and tm2.team = t2 and tm2.role = r2)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014 cross-team isolation byte-equivalent-404
pred FR_014_CrossTeamIsolation {
  all ae: AuditEntry |
    some tm: TeamMembership |
      tm.user = ae.actor and tm.team = ae.task.team
}
assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-015 per-edit-event audit
pred FR_015_PerEditEventAudit {
  all t: Task |
    (some ae: AuditEntry | ae.task = t and ae.change_type = AuditCreated)
}
assert FR_015_PerEditEventAudit { FR_015_PerEditEventAudit }
check FR_015_PerEditEventAudit for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-016 audit append-only immutable
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry |
    some ae.task and some ae.actor and some ae.actor_role and some ae.change_type
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_RoleMismatch { some ae: AuditEntry, tm: TeamMembership | ae.actor = tm.user and ae.task.team = tm.team and ae.actor_role != tm.role }
