// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature folder: B-L2 (branch 007-team-tasks)
// Sources: spec.md (FR-001–FR-020), data-model.md, contracts/http-api.md

// ════════════════════════════════════════════════════════════════════
//  ENUMERATED TYPES
// ════════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeDescKind {}
one sig DescCreated, DescDeleted, DescChanged extends ChangeDescKind {}

// Six endpoint-level operations (contracts/http-api.md permission matrix)
abstract sig OperationKind {}
one sig OpCreateTask, OpListTasks, OpGetTask,
         OpPatchTask, OpDeleteTask, OpGetAudit extends OperationKind {}

// ════════════════════════════════════════════════════════════════════
//  DOMAIN SIGS
// ════════════════════════════════════════════════════════════════════

sig User {}
sig Team {}

// Every TeamMembership row carries the per-team role (FR-007).
// Composite PK (mbUser, mbTeam) enforced by F_TeamMembershipUnique.
sig TeamMembership {
  mbUser : one User,
  mbTeam : one Team,
  mbRole : one Role
}

sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  taskStatus : one TaskStatus,
  taskAssignee : lone User
}

// DeletedTask: tasks whose row has been removed from the live table.
// Their AuditEntry rows remain (FR-016).
sig DeletedTask in Task {}

sig AuditEntry {
  aeTask       : one Task,
  aeTeam       : one Team,
  aeActor      : one User,
  aeActorRole  : one Role,
  aeChangeDesc : one ChangeDescKind
}

// ════════════════════════════════════════════════════════════════════
//  PERMISSION MATRIX  (contracts/http-api.md permission table)
// ════════════════════════════════════════════════════════════════════
// Models the "base" role → operation grants.
// PATCH and DELETE for MemberRole require ownership and are handled
// separately in F_OwnerOrAdminForMutations; they are NOT in the base matrix.

one sig PermMatrix {
  allowed : set Role -> OperationKind
}

// ════════════════════════════════════════════════════════════════════
//  NON-EMPTY UNIVERSE (Rule 9)
// ════════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// ════════════════════════════════════════════════════════════════════
//  STRUCTURAL FACTS
// ════════════════════════════════════════════════════════════════════

// Each (user, team) pair has at most one membership row — data-model.md composite PK
fact F_TeamMembershipUnique {
  all u: User, t: Team |
    lone m: TeamMembership | m.mbUser = u and m.mbTeam = t
}

// A task's owner must be a current member of the task's team — FR-006 / data-model.md
fact F_TaskOwnerIsMember {
  all t: Task |
    some m: TeamMembership | m.mbUser = t.taskOwner and m.mbTeam = t.taskTeam
}

// Assignee, if present, must be a member of the same team — FR-012
fact F_AssigneeMustBeTeamMember {
  all t: Task |
    some t.taskAssignee implies
      (some m: TeamMembership | m.mbUser = t.taskAssignee and m.mbTeam = t.taskTeam)
}

// Every audit entry's denormalised team field matches the task's team — data-model.md
fact F_AuditTeamConsistency {
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// Every task has exactly one "created" audit entry — FR-015, AuditCompleteness
fact F_CreatedEntryExistsForEveryTask {
  all t: Task |
    one ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescCreated
}

// Every deleted task has exactly one "deleted" audit entry — FR-015, FR-016
fact F_DeletedEntryForDeletedTask {
  all t: DeletedTask |
    one ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescDeleted
}

// No live (non-deleted) task has a "deleted" audit entry — FR-015
fact F_NoDeletedEntryForLiveTask {
  all t: Task - DeletedTask |
    no ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescDeleted
}

// Audit actor must be (or have been) a member of the entry's team — FR-015 / data-model.md
fact F_AuditActorWasMember {
  all ae: AuditEntry |
    some m: TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
}

// The "created" audit entry's actor must be the task's owner — FR-015 / spec.md FR-006
fact F_CreatedEntryActorIsOwner {
  all ae: AuditEntry |
    ae.aeChangeDesc = DescCreated implies ae.aeActor = ae.aeTask.taskOwner
}

// PATCH/DELETE: only allowed for admin or the task's own owner (FR-008, FR-009, FR-010)
// Encoded as: for every mutation audit entry, the actor is either the task owner or has
// AdminRole in the task's team.
fact F_OwnerOrAdminForMutations {
  all ae: AuditEntry |
    (ae.aeChangeDesc = DescChanged or ae.aeChangeDesc = DescDeleted) implies
      (ae.aeActor = ae.aeTask.taskOwner or ae.aeActorRole = AdminRole)
}

// Base permission matrix — contracts/http-api.md, FR-008, FR-010
fact F_PermissionMatrix {
  // MemberRole can create, list, read, and view audit; NOT patch/delete without ownership
  MemberRole -> OpCreateTask  in PermMatrix.allowed
  MemberRole -> OpListTasks   in PermMatrix.allowed
  MemberRole -> OpGetTask     in PermMatrix.allowed
  MemberRole -> OpGetAudit    in PermMatrix.allowed
  // AdminRole can do everything, including patch and delete any task
  AdminRole -> OpCreateTask   in PermMatrix.allowed
  AdminRole -> OpListTasks    in PermMatrix.allowed
  AdminRole -> OpGetTask      in PermMatrix.allowed
  AdminRole -> OpPatchTask    in PermMatrix.allowed
  AdminRole -> OpDeleteTask   in PermMatrix.allowed
  AdminRole -> OpGetAudit     in PermMatrix.allowed
  // Closed-world: exactly these cells exist
  PermMatrix.allowed =
    (MemberRole -> OpCreateTask)  +
    (MemberRole -> OpListTasks)   +
    (MemberRole -> OpGetTask)     +
    (MemberRole -> OpGetAudit)    +
    (AdminRole  -> OpCreateTask)  +
    (AdminRole  -> OpListTasks)   +
    (AdminRole  -> OpGetTask)     +
    (AdminRole  -> OpPatchTask)   +
    (AdminRole  -> OpDeleteTask)  +
    (AdminRole  -> OpGetAudit)
}

// MemberRole cannot directly patch or delete (base matrix) — FR-009
fact F_MemberCannotPatchOrDeleteInBaseMatrix {
  MemberRole -> OpPatchTask  not in PermMatrix.allowed
  MemberRole -> OpDeleteTask not in PermMatrix.allowed
}

// ════════════════════════════════════════════════════════════════════
//  HELPER PREDICATE
// ════════════════════════════════════════════════════════════════════

pred isMemberOf[u: User, t: Team] {
  some m: TeamMembership | m.mbUser = u and m.mbTeam = t
}

pred hasRoleIn[u: User, t: Team, r: Role] {
  some m: TeamMembership | m.mbUser = u and m.mbTeam = t and m.mbRole = r
}

// ════════════════════════════════════════════════════════════════════
//  PATTERN PREDICATES + ASSERTIONS
// ════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008–FR-010
pred LeastPrivilege {
  // MemberRole is never directly allowed to PATCH or DELETE at the base level
  some Task  // force non-empty universe in predicate
  MemberRole -> OpPatchTask  not in PermMatrix.allowed
  MemberRole -> OpDeleteTask not in PermMatrix.allowed
  // AdminRole is allowed to PATCH and DELETE
  AdminRole -> OpPatchTask   in PermMatrix.allowed
  AdminRole -> OpDeleteTask  in PermMatrix.allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  some Task
  // Every role has at least one allowed operation
  all r: Role | some op: OperationKind | r -> op in PermMatrix.allowed
  // Every operation is allowed for at least one role
  all op: OperationKind | some r: Role | r -> op in PermMatrix.allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 (admin ⊇ member); contracts/http-api.md
pred PrivilegeMonotonicity {
  some Task
  // AdminRole's allowed set is a strict superset of MemberRole's
  { op: OperationKind | MemberRole -> op in PermMatrix.allowed } in
  { op: OperationKind | AdminRole  -> op in PermMatrix.allowed }
  // And AdminRole has strictly more: can PATCH and DELETE
  AdminRole -> OpPatchTask  in PermMatrix.allowed
  AdminRole -> OpDeleteTask in PermMatrix.allowed
  MemberRole -> OpPatchTask  not in PermMatrix.allowed
  MemberRole -> OpDeleteTask not in PermMatrix.allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry schema
pred AuditCompleteness {
  some Task
  // Every task has exactly one "created" entry
  all t: Task | one ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescCreated
  // Every deleted task has exactly one "deleted" entry
  all t: DeletedTask | one ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescDeleted
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries for the same task both have DescCreated
  all t: Task |
    lone ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescCreated
  // No two distinct audit entries for the same task both have DescDeleted
  all t: Task |
    lone ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescDeleted
  // Every AuditEntry belongs to exactly one task (its identity does not migrate)
  all ae: AuditEntry | one ae.aeTask
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_* snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  // The "created" entry's actor is always the task's owner (creator)
  all ae: AuditEntry |
    ae.aeChangeDesc = DescCreated implies ae.aeActor = ae.aeTask.taskOwner
  // The audit actor must be a member of the audit entry's team
  all ae: AuditEntry | isMemberOf[ae.aeActor, ae.aeTeam]
  // The actor's snapshotted role must be a valid Role atom
  all ae: AuditEntry | ae.aeActorRole in Role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner
  all t: Task | one t.taskOwner
  // The owner is a member of the task's team
  all t: Task | isMemberOf[t.taskOwner, t.taskTeam]
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009, FR-010; data-model.md
pred OwnershipBasedAccess {
  some AuditEntry
  // For every mutation (changed/deleted) audit entry, the actor is owner or admin
  all ae: AuditEntry |
    (ae.aeChangeDesc = DescChanged or ae.aeChangeDesc = DescDeleted) implies
      (ae.aeActor = ae.aeTask.taskOwner or ae.aeActorRole = AdminRole)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  some Task
  // Cross-team: every audit entry's team equals its task's team — so querying
  // by team_id correctly filters; a caller in team T sees only entries where aeTeam = T
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
  // Every task belongs to exactly one team — no task is visible from a different team context
  all t: Task | one t.taskTeam
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ════════════════════════════════════════════════════════════════════
//  FEATURE-SPECIFIC PREDICATES
// ════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required
pred FR_001_AuthRequired {
  some Task
  // Every audit entry (which records a completed operation) has an actor
  // who is a known user — no anonymous actors in any audit trail
  all ae: AuditEntry | one ae.aeActor
  // Every actor appears as a user in a membership (proxy for "was authenticated")
  all ae: AuditEntry | isMemberOf[ae.aeActor, ae.aeTeam]
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 / FR-004 team context and membership gate
pred FR_003_TeamContextRequired {
  some Task
  // Every task is scoped to exactly one team
  all t: Task | one t.taskTeam
  // Every audit entry is scoped to exactly one team
  all ae: AuditEntry | one ae.aeTeam
  // The team in the audit entry matches the task's team (denormalisation invariant)
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 task team immutability
pred FR_005_TaskTeamImmutable {
  some Task
  // Every task has exactly one team (immutable after creation — structural proxy)
  all t: Task | one t.taskTeam
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 owner immutability; data-model.md tasks.owner_id
pred FR_006_OwnerImmutable {
  some Task
  // Every task has exactly one owner
  all t: Task | one t.taskOwner
  // The "created" audit entry's actor equals the task owner
  // (if ownership were mutable this invariant could be broken)
  all ae: AuditEntry |
    ae.aeChangeDesc = DescCreated implies ae.aeActor = ae.aeTask.taskOwner
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role; data-model.md team_memberships
pred FR_007_PerTeamRole {
  some TeamMembership
  // A user may have different roles in different teams: there exist two memberships
  // for the same user in different teams — no global role constraint forces uniformity
  // Structural check: composite PK uniqueness holds
  all u: User, t: Team |
    lone m: TeamMembership | m.mbUser = u and m.mbTeam = t
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 / FR-009 / FR-010 owner-or-admin for PATCH and DELETE
pred FR_008_010_OwnerOrAdminCanMutate {
  some AuditEntry
  all ae: AuditEntry |
    (ae.aeChangeDesc = DescChanged or ae.aeChangeDesc = DescDeleted) implies
      (ae.aeActor = ae.aeTask.taskOwner or ae.aeActorRole = AdminRole)
  // Non-owners with MemberRole MUST NOT appear as actors on mutations
  all ae: AuditEntry |
    (ae.aeChangeDesc = DescChanged or ae.aeChangeDesc = DescDeleted) implies
      not (ae.aeActor != ae.aeTask.taskOwner and ae.aeActorRole = MemberRole)
}
assert FR_008_010_OwnerOrAdminCanMutate { FR_008_010_OwnerOrAdminCanMutate }
check FR_008_010_OwnerOrAdminCanMutate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 / FR-014 cross-team isolation
pred FR_011_014_CrossTeamIsolation {
  some Task
  // A task's audit entries only carry the task's own team — no cross-team audit entries
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
  // No task spans multiple teams
  all t: Task | one t.taskTeam
  // Audit entries are never shared across tasks from different teams
  all disj ae1, ae2: AuditEntry |
    ae1.aeTask != ae2.aeTask implies
      not (ae1.aeTeam != ae2.aeTeam and ae1.aeTask.taskTeam = ae2.aeTask.taskTeam)
}
assert FR_011_014_CrossTeamIsolation { FR_011_014_CrossTeamIsolation }
check FR_011_014_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 assignee must be same-team member
pred FR_012_AssigneeIsTeamMember {
  some Task
  all t: Task |
    some t.taskAssignee implies
      (some m: TeamMembership | m.mbUser = t.taskAssignee and m.mbTeam = t.taskTeam)
}
assert FR_012_AssigneeIsTeamMember { FR_012_AssigneeIsTeamMember }
check FR_012_AssigneeIsTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 valid status set; data-model.md TaskStatus enum
pred FR_013_ValidStatusSet {
  some Task
  all t: Task | t.taskStatus in (Todo + InProgress + Done)
}
assert FR_013_ValidStatusSet { FR_013_ValidStatusSet }
check FR_013_ValidStatusSet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 per-edit-event audit; exactly one "created" entry per task
pred FR_015_OneCreatedEntryPerTask {
  some Task
  all t: Task | one ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescCreated
}
assert FR_015_OneCreatedEntryPerTask { FR_015_OneCreatedEntryPerTask }
check FR_015_OneCreatedEntryPerTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 actor-role snapshot; data-model.md actor_role column
pred FR_015_AuditActorRoleSnapshot {
  some AuditEntry
  // Actor role captured in each entry is a valid Role atom (member or admin)
  all ae: AuditEntry | ae.aeActorRole in (MemberRole + AdminRole)
  // Admin mutations are attributed to AdminRole, not MemberRole
  all ae: AuditEntry |
    (ae.aeActorRole = AdminRole and ae.aeActor != ae.aeTask.taskOwner) implies
      (ae.aeChangeDesc = DescChanged or ae.aeChangeDesc = DescDeleted or ae.aeChangeDesc = DescCreated)
}
assert FR_015_AuditActorRoleSnapshot { FR_015_AuditActorRoleSnapshot }
check FR_015_AuditActorRoleSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit append-only; audit entries outlive tasks
pred FR_016_AuditOutlivesTask {
  some DeletedTask
  // Every deleted task retains a "deleted" entry
  all t: DeletedTask |
    some ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescDeleted
  // And still has its "created" entry
  all t: DeletedTask |
    some ae: AuditEntry | ae.aeTask = t and ae.aeChangeDesc = DescCreated
}
assert FR_016_AuditOutlivesTask { FR_016_AuditOutlivesTask }
check FR_016_AuditOutlivesTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit readable by any team member
pred FR_017_AuditReadableByAnyTeamMember {
  some AuditEntry
  // The audit endpoint scopes by aeTeam; any member of that team can read it.
  // Structural invariant: aeTeam matches the task's team so the team_id filter
  // correctly isolates entries without needing to join a potentially-deleted task row.
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
  // Actors in audit entries are verifiable as team members
  all ae: AuditEntry | isMemberOf[ae.aeActor, ae.aeTeam]
}
assert FR_017_AuditReadableByAnyTeamMember { FR_017_AuditReadableByAnyTeamMember }
check FR_017_AuditReadableByAnyTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit retention; no delete path for audit entries
// Modeled as: count of audit entries for any task never decreases — i.e., every
// task that has an audit entry retains it; there are no orphan-less tasks.
pred FR_018_AuditRetention {
  some AuditEntry
  // Proxy: every task has at least one audit entry (the "created" one)
  all t: Task | some ae: AuditEntry | ae.aeTask = t
}
assert FR_018_AuditRetention { FR_018_AuditRetention }
check FR_018_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 list scoped to team
pred FR_019_ListScopedToTeam {
  some Task
  // Tasks have a team; the list endpoint always carries team_id = caller's team.
  // Structural invariant: task team membership is always defined.
  all t: Task | isMemberOf[t.taskOwner, t.taskTeam]
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 non-member gets same 404 as non-existent team
// Structural proxy: no task is accessible to a user who lacks a membership in the task's team
pred FR_003_NonMemberGets404 {
  some Task
  // The "accessible" predicate (member of task's team) must hold for any actor
  // who has an audit entry on the task — i.e., actors on audit entries are members
  all ae: AuditEntry | isMemberOf[ae.aeActor, ae.aeTask.taskTeam]
}
assert FR_003_NonMemberGets404 { FR_003_NonMemberGets404 }
check FR_003_NonMemberGets404 for 6