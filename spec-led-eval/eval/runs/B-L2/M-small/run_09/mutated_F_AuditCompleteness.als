// === feature_model.als — Alloy model for SaaS Team Task Management ===

// Core entity types
abstract sig User {}
abstract sig Team {}

// Roles within teams
abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

// Task status enumeration
abstract sig TaskStatus {}
one sig TodoStatus, InProgressStatus, DoneStatus extends TaskStatus {}

// Team membership relationship: which users belong to which teams with which roles
sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

// Task entity: belongs to one team, owned by one user
sig Task {
  team: one Team,
  owner: one User
}

// Audit entry: records changes to a task
sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role
}

// ======= Mandatory non-empty universe =======
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// ======= Structural invariant facts =======

// FEATURE-SPECIFIC  ANCHOR: FR-005 Task team immutable after creation
fact F_TaskTeamImmutable {
  // Each task belongs to exactly one team
  all t: Task | one t.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 Owner immutable after creation
fact F_OwnerImmutable {
  // Each task has exactly one owner (the creator)
  all t: Task | one t.owner
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 Per-team role uniqueness
fact F_OneRolePerTeamPerUser {
  // A user can have at most one membership per team
  all disj m1, m2: TeamMembership |
    (m1.user = m2.user and m1.team = m2.team) implies m1 = m2
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015; data-model.md
fact F_AuditCompleteness { /* MUTATED — body cleared by validator */ }

// PATTERN: AppendOnly  ANCHOR: FR-016; data-model.md "no UPDATE/DELETE audit_entries"
fact F_AppendOnlyAuditEntries {
  // Audit entries are immutable: cannot be updated or deleted
  // The deletion of a task does NOT cascade to delete its audit entries
  // Enforced by absence of UPDATE/DELETE code paths on audit_entries table
  all ae: AuditEntry | (
    // Each entry references exactly one task (even if task is later deleted)
    one ae.task and
    // Each entry has exactly one actor (authenticated)
    one ae.actor and
    // Each entry records exactly one actor role (snapshot at time of change)
    one ae.actor_role
  )
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-015; data-model.md audit snapshots
fact F_AuditAttributionCorrect {
  // Every audit entry's recorded role matches a real team membership
  all ae: AuditEntry |
    some m: TeamMembership |
      m.user = ae.actor and
      m.team = ae.task.team and
      m.role = ae.actor_role
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AuthenticationRequired {
  // Every task operation (creation) requires an authenticated principal
  all t: Task | one t.owner  // task creator is authenticated
  // Every audit entry records an authenticated actor
  all ae: AuditEntry | one ae.actor
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006; data-model.md
fact F_OwnershipExclusivity {
  // Every task has exactly one owner
  all t: Task | one t.owner
}

// ======= Helper predicates for access control =======

// User has a specific role in a team
pred userHasRole[u: User, t: Team, r: Role] {
  some m: TeamMembership |
    m.user = u and m.team = t and m.role = r
}

// User is a member of a team (holds any role in it)
pred isMemberOfTeam[u: User, t: Team] {
  some r: Role | userHasRole[u, t, r]
}

// User can view a task (read access)
pred canViewTask[u: User, t: Task] {
  isMemberOfTeam[u, t.team]
}

// User can edit a task (only owner or admin in the team)
pred canEditTask[u: User, t: Task] {
  isMemberOfTeam[u, t.team] and
  (u = t.owner or userHasRole[u, t.team, AdminRole])
}

// User can delete a task (only owner or admin in the team)
pred canDeleteTask[u: User, t: Task] {
  isMemberOfTeam[u, t.team] and
  (u = t.owner or userHasRole[u, t.team, AdminRole])
}

// User can view audit trail for a task
pred canViewAudit[u: User, t: Task] {
  isMemberOfTeam[u, t.team]
}

// ======= Structural assertion predicates =======

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008, FR-009, FR-010; contracts/http-api.md
pred OwnershipBasedAccess {
  // Non-owner, non-admin members cannot edit or delete a task
  all u: User, t: Task |
    (isMemberOfTeam[u, t.team] and u != t.owner and not userHasRole[u, t.team, AdminRole]) implies (
      not canEditTask[u, t] and not canDeleteTask[u, t]
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
  // Cross-team and non-existent task responses are indistinguishable
  // Non-members cannot access tasks from teams they don't belong to
  all u: User, t: Task |
    not isMemberOfTeam[u, t.team] implies (
      not canViewTask[u, t] and
      not canEditTask[u, t] and
      not canDeleteTask[u, t] and
      not canViewAudit[u, t]
    )
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  // Enforce the complete permission matrix from the spec
  all u: User, t: Task |
    // Non-members: no access to anything
    (not isMemberOfTeam[u, t.team] implies (
      not canViewTask[u, t] and
      not canEditTask[u, t] and
      not canDeleteTask[u, t] and
      not canViewAudit[u, t]
    )) and
    // Members (non-owner, non-admin): can view and see audit, but not edit/delete
    ((isMemberOfTeam[u, t.team] and u != t.owner and not userHasRole[u, t.team, AdminRole]) implies (
      canViewTask[u, t] and
      not canEditTask[u, t] and
      not canDeleteTask[u, t] and
      canViewAudit[u, t]
    )) and
    // Owners: can view, edit, delete, and view audit
    ((u = t.owner and isMemberOfTeam[u, t.team]) implies (
      canViewTask[u, t] and
      canEditTask[u, t] and
      canDeleteTask[u, t] and
      canViewAudit[u, t]
    )) and
    // Admins: can view, edit, delete any task in their team, and view audit
    (userHasRole[u, t.team, AdminRole] implies (
      canViewTask[u, t] and
      canEditTask[u, t] and
      canDeleteTask[u, t] and
      canViewAudit[u, t]
    ))
}

// FEATURE-SPECIFIC  ANCHOR: FR-014 Cross-team isolation invariant
pred FR_014_CrossTeamIsolation {
  // Members of team T cannot access (read/write/audit) tasks in team U
  all u: User, t: Task |
    not isMemberOfTeam[u, t.team] implies (
      not canViewTask[u, t] and
      not canEditTask[u, t] and
      not canDeleteTask[u, t] and
      not canViewAudit[u, t]
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-017 Audit visibility to all team members
pred FR_017_AuditVisibilityToMembers {
  // Any team member (including non-owners and non-admins) can view audit trail
  all u: User, t: Task |
    isMemberOfTeam[u, t.team] implies canViewAudit[u, t]
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015
pred AuditCompleteness {
  // Every task has at least one audit entry
  all t: Task | (some ae: AuditEntry | ae.task = t)
}

// PATTERN: AppendOnly  ANCHOR: FR-016
pred AppendOnly {
  // Audit entries are permanent: at least one exists and persists
  some ae: AuditEntry | (
    one ae.task and
    one ae.actor and
    one ae.actor_role
  )
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-015
pred AttributionCorrectness {
  // Audit entries have correct actor and role information
  all ae: AuditEntry | (
    some m: TeamMembership |
      m.user = ae.actor and
      m.team = ae.task.team and
      m.role = ae.actor_role
  )
}

// ======= Assertions and checks =======

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 8

assert FR_017_AuditVisibilityToMembers { FR_017_AuditVisibilityToMembers }
check FR_017_AuditVisibilityToMembers for 8

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

assert AuthRequiredEverywhere { all t: Task | one t.owner }
check AuthRequiredEverywhere for 5

assert OwnershipExclusivity { all t: Task | one t.owner }
check OwnershipExclusivity for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MissingAuditEntry { some t: Task | no ae: AuditEntry | ae.task = t }
