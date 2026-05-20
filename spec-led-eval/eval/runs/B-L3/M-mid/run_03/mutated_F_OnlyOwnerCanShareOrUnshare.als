// === feature_model.als — Alloy model for B-L3: Multi-Tenant Task Management with Per-Task Sharing and Audit ===
// Feature: 008-task-sharing
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────
// Core enumerations
// ─────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig AuditOp {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOp {}

// ─────────────────────────────────────────────────────────────────
// Domain sigs (dynamic — every one gets a "some" in F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────

sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam    : one Team,
  taskOwner   : one User,
  taskSharedWith : set User,
  taskStatus  : one TaskStatus
}

sig AuditEntry {
  entryTask      : one Task,
  entryActor     : one User,
  entryActorRole : one Role,
  entryOp        : one AuditOp
}

// Mutation represents one successful state-change event on a task.
// Every Mutation is 1-to-1 with exactly one AuditEntry (FR-015).
sig Mutation {
  mutTask      : one Task,
  mutActor     : one User,
  mutActorRole : one Role,
  mutOp        : one AuditOp,
  mutEntry     : one AuditEntry   // the audit entry that records this mutation
}

// ─────────────────────────────────────────────────────────────────
// Permission-matrix sigs
// ─────────────────────────────────────────────────────────────────

abstract sig OperationKind {}
one sig OpCreateTask,    // POST /tasks (caller becomes owner; no prior task)
        OpGetTask,       // GET  /tasks/{id}
        OpPatchFields,   // PATCH /tasks/{id} — non-shared_with fields
        OpPatchSharedWith,  // PATCH /tasks/{id} — body includes shared_with
        OpDeleteTask,    // DELETE /tasks/{id}
        OpGetAudit       // GET  /tasks/{id}/audit
  extends OperationKind {}

// Caller-to-task relationship (computed from team membership, ownership, sharing)
abstract sig CallerRel {}
one sig RelOutsider,    // caller's team ≠ task's team
        RelInTeamNone,  // same team, not owner/sharee/admin
        RelSharee,      // in task.sharedWith
        RelTeamAdmin,   // team_admin of the task's team (and not owner)
        RelOwner        // task.owner
  extends CallerRel {}

// Permission matrix as a singleton field (spec rule 7)
one sig PermMatrix {
  allowed : set CallerRel -> OperationKind
}

// ─────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — keeps assertions non-vacuous under for 5
// ─────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Mutation
}

// ─────────────────────────────────────────────────────────────────
// STRUCTURAL FACTS
// ─────────────────────────────────────────────────────────────────

// FR-009: owner_id and team_id are immutable and both derived at creation time,
// so the owner must always live in the task's team.
fact F_TaskOwnerInTaskTeam {
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}

// FR-012: sharees must be in the same team as the task (cross-team sharing forbidden).
fact F_ShareeInSameTeam {
  all t : Task | all u : t.taskSharedWith | u.userTeam = t.taskTeam
}

// Sanity: the owner is not listed as their own sharee.
fact F_OwnerNotInSharedWith {
  all t : Task | t.taskOwner not in t.taskSharedWith
}

// FR-016: every audit entry's actor_role field is snapshotted from the actor's
// actual role at the time of the event. Modelled as a structural equality.
fact F_AuditActorRoleMatchesUserRole {
  all ae : AuditEntry | ae.entryActorRole = ae.entryActor.userRole
}

// FR-016 extension: the actor on any audit entry must be in the same team as
// the task it records (captures FR-006 from the audit side).
fact F_AuditActorInTaskTeam {
  all ae : AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
}

// FR-015: Mutation ↔ AuditEntry bijection.
// (a) mutEntry is injective: no two Mutations share the same AuditEntry.
fact F_MutationAuditBijection {
  all disj m1, m2 : Mutation | m1.mutEntry != m2.mutEntry
}

// (b) Every AuditEntry is the record of exactly one Mutation.
fact F_AuditEntryHasOneMutation {
  all ae : AuditEntry | one m : Mutation | m.mutEntry = ae
}

// FR-015 / FR-016: A Mutation's AuditEntry must reference the same task, actor,
// role, and operation as the Mutation itself.
fact F_MutationAuditConsistency {
  all m : Mutation |
    m.mutEntry.entryTask      = m.mutTask     and
    m.mutEntry.entryActor     = m.mutActor    and
    m.mutEntry.entryActorRole = m.mutActorRole and
    m.mutEntry.entryOp        = m.mutOp
}

// FR-016 / FR-002: actor role on a Mutation is snapshotted from the user's role.
fact F_MutationActorRoleSnapshot {
  all m : Mutation | m.mutActorRole = m.mutActor.userRole
}

// Mutating actor must be in the task's team (FR-006 structural invariant).
fact F_MutationActorInTaskTeam {
  all m : Mutation | m.mutActor.userTeam = m.mutTask.taskTeam
}

// FR-017: AppendOnly — audit entries are never deleted or modified.
// In the static model this is encoded as: the set of AuditEntries is stable
// (no AuditEntry is replaced by a modified copy). Concretely, for every pair
// of distinct AuditEntries that record the same task and same operation, they
// must have been written by distinct actors at distinct moments — i.e., they
// are genuinely different events, not edits of the same entry.
// The core immutability constraint: there is no "mutation of an AuditEntry"
// operation in the model (enforced by the absence of any Mutation whose
// mutTask maps to the pseudo-entity AuditEntry — which cannot happen given
// the type system). We additionally require that no two AuditEntries are
// structurally identical (which would indicate a spurious duplicate write).
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2 : AuditEntry |
    not (ae1.entryTask      = ae2.entryTask      and
         ae1.entryActor     = ae2.entryActor     and
         ae1.entryActorRole = ae2.entryActorRole and
         ae1.entryOp        = ae2.entryOp)
}

// FR-010 (owner-only share control): only the task owner is allowed to mutate
// shared_with. Modelled as: if a Mutation records a Shared or Unshared event,
// the mutActor must be the task's owner.
fact F_OnlyOwnerCanShareOrUnshare { /* MUTATED — body cleared by validator */ }

// FR-009: owner_id immutability — there is no Mutation that changes the owner.
// Captured via the rule that the actor on a Created entry must be the owner.
fact F_CreatedActorIsOwner {
  all m : Mutation | m.mutOp = Created implies (m.mutActor = m.mutTask.taskOwner)
}

// FR-011: sharees cannot delete. A Deleted mutation must be performed by the
// owner or a TeamAdmin, never by a pure sharee.
fact F_DeleteByOwnerOrAdmin {
  all m : Mutation |
    m.mutOp = Deleted implies
      (m.mutActor = m.mutTask.taskOwner or m.mutActor.userRole = TeamAdmin)
}

// Permission matrix for task-level operations (FR-003/FR-004/FR-005/FR-006/FR-010/FR-011).
// Derived from contracts/http-api.md permission matrix.
fact F_PermissionMatrix {
  PermMatrix.allowed =
    // Owner: all operations
    (RelOwner -> OpGetTask)       +
    (RelOwner -> OpPatchFields)   +
    (RelOwner -> OpPatchSharedWith) +
    (RelOwner -> OpDeleteTask)    +
    (RelOwner -> OpGetAudit)      +
    // TeamAdmin: all except PatchSharedWith (Q1=A: owner-only share control)
    (RelTeamAdmin -> OpGetTask)       +
    (RelTeamAdmin -> OpPatchFields)   +
    (RelTeamAdmin -> OpDeleteTask)    +
    (RelTeamAdmin -> OpGetAudit)      +
    // Sharee: view, patch fields, view audit — NOT delete, NOT patch shared_with
    (RelSharee -> OpGetTask)      +
    (RelSharee -> OpPatchFields)  +
    (RelSharee -> OpGetAudit)
    // RelOutsider and RelInTeamNone: NO allowed operations on existing tasks
    // OpCreateTask is role-based, not task-relationship-based (any in-team user)
}

// ─────────────────────────────────────────────────────────────────
// Helper predicates — relationship classification
// ─────────────────────────────────────────────────────────────────

pred callerRelToTask[u : User, t : Task, r : CallerRel] {
  r = RelOwner      implies (u = t.taskOwner)
  r = RelTeamAdmin  implies (u.userTeam = t.taskTeam and u.userRole = TeamAdmin and u != t.taskOwner)
  r = RelSharee     implies (u in t.taskSharedWith and u != t.taskOwner)
  r = RelInTeamNone implies (u.userTeam = t.taskTeam and u.userRole = Member
                              and u != t.taskOwner and u not in t.taskSharedWith)
  r = RelOutsider   implies (u.userTeam != t.taskTeam)
}

pred hasReadAccess[u : User, t : Task] {
  u = t.taskOwner
  or u.userRole = TeamAdmin and u.userTeam = t.taskTeam
  or u in t.taskSharedWith
}

pred canDelete[u : User, t : Task] {
  u = t.taskOwner
  or (u.userRole = TeamAdmin and u.userTeam = t.taskTeam)
}

pred canChangeSharedWith[u : User, t : Task] {
  u = t.taskOwner
}

// ─────────────────────────────────────────────────────────────────
// PATTERN PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003 FR-004 FR-005 FR-006
pred LeastPrivilege {
  // Outsiders and in-team-no-rel callers have no allowed operations in the matrix.
  no (RelOutsider -> OperationKind) & PermMatrix.allowed
  no (RelInTeamNone -> OperationKind) & PermMatrix.allowed
  // Sharees do not have delete or share-control operations.
  RelSharee -> OpDeleteTask not in PermMatrix.allowed
  RelSharee -> OpPatchSharedWith not in PermMatrix.allowed
  // TeamAdmin does not have share-control.
  RelTeamAdmin -> OpPatchSharedWith not in PermMatrix.allowed
  // Owner has all task-level operations.
  RelOwner -> OpGetTask        in PermMatrix.allowed
  RelOwner -> OpDeleteTask     in PermMatrix.allowed
  RelOwner -> OpPatchSharedWith in PermMatrix.allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (CallerRel × OperationKind) pair that is relevant has a determined verdict
  // in the model (allowed = in PermMatrix.allowed; denied = absent).
  // Checking completeness by verifying the four non-empty allowed sets are present
  // and the two denied sets are absent.
  some PermMatrix.allowed
  // The allowed set covers only known relationship × operation pairs.
  all r : CallerRel, op : OperationKind |
    (r -> op) in PermMatrix.allowed implies
      (r = RelOwner or r = RelTeamAdmin or r = RelSharee)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005 (admin ⊇ sharee permissions); contracts/http-api.md
pred PrivilegeMonotonicity {
  // TeamAdmin's allowed operations are a superset of Sharee's.
  all op : OperationKind |
    (RelSharee -> op) in PermMatrix.allowed implies (RelTeamAdmin -> op) in PermMatrix.allowed
  // Owner's allowed operations are a superset of TeamAdmin's.
  all op : OperationKind |
    (RelTeamAdmin -> op) in PermMatrix.allowed implies (RelOwner -> op) in PermMatrix.allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  // Every Mutation has an actor who is a known User (structurally enforced by types),
  // and that actor's team matches the task's team (enforced by F_MutationActorInTaskTeam).
  // The predicate asserts: no Mutation exists with an actor outside the task's team
  // (which would indicate an unauthenticated or cross-team invocation slipped through).
  all m : Mutation | m.mutActor.userTeam = m.mutTask.taskTeam
  // All audit entries' actors are also in-team.
  all ae : AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015 FR-016; data-model.md AuditEntry UNIQUE constraint
pred AuditCompleteness {
  // Every Mutation has exactly one corresponding AuditEntry.
  all m : Mutation | one ae : AuditEntry | m.mutEntry = ae
  // Every AuditEntry is the record of exactly one Mutation.
  all ae : AuditEntry | one m : Mutation | m.mutEntry = ae
  // The AuditEntry faithfully records the Mutation's fields.
  all m : Mutation |
    m.mutEntry.entryTask      = m.mutTask     and
    m.mutEntry.entryActor     = m.mutActor    and
    m.mutEntry.entryActorRole = m.mutActorRole and
    m.mutEntry.entryOp        = m.mutOp
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017 SC-009; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No two distinct AuditEntries are structurally identical (which would indicate
  // one is a spurious copy or edit of the other).
  all disj ae1, ae2 : AuditEntry |
    not (ae1.entryTask = ae2.entryTask and
         ae1.entryActor = ae2.entryActor and
         ae1.entryActorRole = ae2.entryActorRole and
         ae1.entryOp = ae2.entryOp)
  // At least one AuditEntry exists (non-vacuous).
  some AuditEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role snapshot
pred AttributionCorrectness {
  // Every audit entry's actor_role equals the actor's actual role (snapshot at write time).
  all ae : AuditEntry | ae.entryActorRole = ae.entryActor.userRole
  // Actor is in the task's team.
  all ae : AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
  // At least one AuditEntry is present to make the predicate non-vacuous.
  some AuditEntry
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task.owner_id NOT NULL immutable
pred OwnershipExclusivity {
  // Every Task has exactly one owner (encoded in the sig: taskOwner: one User).
  // Additionally, the owner must live in the task's team (no orphaned ownership).
  all t : Task | t.taskOwner.userTeam = t.taskTeam
  some Task
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 FR-004 FR-010 FR-011; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  // Share/Unshare mutations are only performed by the task owner.
  all m : Mutation |
    (m.mutOp = Shared or m.mutOp = Unshared) implies (m.mutActor = m.mutTask.taskOwner)
  // Delete mutations are only performed by the owner or a TeamAdmin.
  all m : Mutation |
    m.mutOp = Deleted implies
      (m.mutActor = m.mutTask.taskOwner or m.mutActor.userRole = TeamAdmin)
  // All mutations are performed by someone with access to the task.
  all m : Mutation | hasReadAccess[m.mutActor, m.mutTask]
  some Mutation
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014 SC-003; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // Cross-team callers have no allowed operations in the permission matrix.
  RelOutsider -> OpGetTask    not in PermMatrix.allowed
  RelOutsider -> OpPatchFields not in PermMatrix.allowed
  RelOutsider -> OpDeleteTask  not in PermMatrix.allowed
  RelOutsider -> OpGetAudit    not in PermMatrix.allowed
  // In-team-no-rel callers likewise.
  RelInTeamNone -> OpGetTask    not in PermMatrix.allowed
  RelInTeamNone -> OpPatchFields not in PermMatrix.allowed
  RelInTeamNone -> OpDeleteTask  not in PermMatrix.allowed
  RelInTeamNone -> OpGetAudit    not in PermMatrix.allowed
  // Sharee delete is also in the "denied = 404" bucket (FR-011 / FR-014).
  RelSharee -> OpDeleteTask not in PermMatrix.allowed
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ─────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES (FR-NNN)
// ─────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-002
// Each User belongs to exactly one team, and team_id / role come from the token (not payload).
pred FR_002_UserExactlyOneTeam {
  // Structurally enforced by "userTeam: one Team", but we assert it explicitly
  // so removing the structural fact would surface a counterexample.
  all u : User | one u.userTeam
  all u : User | one u.userRole
  some User
}
assert FR_002_UserExactlyOneTeam { FR_002_UserExactlyOneTeam }
check FR_002_UserExactlyOneTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
// owner_id and team_id are immutable; owner must be in task's team at all times.
pred FR_009_TaskOwnerAndTeamImmutable {
  all t : Task | t.taskOwner.userTeam = t.taskTeam
  // No mutation changes the owner: Created events' actor is the owner.
  all m : Mutation | m.mutOp = Created implies m.mutActor = m.mutTask.taskOwner
  some Task
}
assert FR_009_TaskOwnerAndTeamImmutable { FR_009_TaskOwnerAndTeamImmutable }
check FR_009_TaskOwnerAndTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 Q1=A
// Only the task owner may modify shared_with (share or unshare).
pred FR_010_OwnerOnlyShareControl {
  all m : Mutation |
    (m.mutOp = Shared or m.mutOp = Unshared) implies (m.mutActor = m.mutTask.taskOwner)
  // TeamAdmin is NOT permitted to change shared_with.
  RelTeamAdmin -> OpPatchSharedWith not in PermMatrix.allowed
  some Mutation
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 Q3=B
// Sharee may view and edit but not delete; sharee delete returns byte-equiv 404.
pred FR_011_ShareeCannotDelete {
  // Sharee is NOT in the allowed set for DeleteTask.
  RelSharee -> OpDeleteTask not in PermMatrix.allowed
  // No mutation of kind Deleted is performed by a sharee.
  all m : Mutation |
    m.mutOp = Deleted implies
      (m.mutActor = m.mutTask.taskOwner or m.mutActor.userRole = TeamAdmin)
  // Sharees CAN view and edit tasks (read access holds).
  RelSharee -> OpGetTask    in PermMatrix.allowed
  RelSharee -> OpPatchFields in PermMatrix.allowed
  some Task
}
assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012
// Every sharee must be a current member of the same team as the task owner.
pred FR_012_CrossTeamSharingForbidden {
  all t : Task | all u : t.taskSharedWith | u.userTeam = t.taskTeam
  some Task
}
assert FR_012_CrossTeamSharingForbidden { FR_012_CrossTeamSharingForbidden }
check FR_012_CrossTeamSharingForbidden for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
// Every share/unshare produces a Shared/Unshared audit entry attributed to the owner.
pred FR_013_ShareAuditEntries {
  all m : Mutation |
    m.mutOp = Shared implies (m.mutActor = m.mutTask.taskOwner and m.mutEntry.entryOp = Shared)
  all m : Mutation |
    m.mutOp = Unshared implies (m.mutActor = m.mutTask.taskOwner and m.mutEntry.entryOp = Unshared)
  some Mutation
}
assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
// Cross-team access is denied at the permission matrix level for all four task endpoints.
pred FR_014_CrossTeamIsolation {
  RelOutsider -> OpGetTask     not in PermMatrix.allowed
  RelOutsider -> OpPatchFields not in PermMatrix.allowed
  RelOutsider -> OpPatchSharedWith not in PermMatrix.allowed
  RelOutsider -> OpDeleteTask  not in PermMatrix.allowed
  RelOutsider -> OpGetAudit    not in PermMatrix.allowed
  // All sharees and actors in mutations must be in the same team as their task.
  all m : Mutation | m.mutActor.userTeam = m.mutTask.taskTeam
  all t : Task | all u : t.taskSharedWith | u.userTeam = t.taskTeam
  some Task
}
assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 FR-016 FR-018 SC-007
// Audit completeness: every Mutation has exactly one AuditEntry; no orphan entries.
pred FR_015_AuditCompletenessAndAtomicity {
  all m : Mutation | one ae : AuditEntry | m.mutEntry = ae
  all ae : AuditEntry | one m : Mutation | m.mutEntry = ae
  all m : Mutation |
    m.mutEntry.entryTask = m.mutTask and
    m.mutEntry.entryActor = m.mutActor and
    m.mutEntry.entryOp = m.mutOp
  some Mutation
}
assert FR_015_AuditCompletenessAndAtomicity { FR_015_AuditCompletenessAndAtomicity }
check FR_015_AuditCompletenessAndAtomicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
// Attribution: audit entry actor_role snapshot matches the user's actual role.
pred FR_016_AttributionSnapshot {
  all ae : AuditEntry | ae.entryActorRole = ae.entryActor.userRole
  all m : Mutation | m.mutActorRole = m.mutActor.userRole
  some AuditEntry
}
assert FR_016_AttributionSnapshot { FR_016_AttributionSnapshot }
check FR_016_AttributionSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 SC-009
// Audit entries are append-only and outlive task deletion.
pred FR_017_AuditImmutableAndPersisted {
  // No two AuditEntries represent the same event (no duplicates / rewrites).
  all disj ae1, ae2 : AuditEntry |
    not (ae1.entryTask = ae2.entryTask and
         ae1.entryActor = ae2.entryActor and
         ae1.entryActorRole = ae2.entryActorRole and
         ae1.entryOp = ae2.entryOp)
  // Deleted tasks still have AuditEntries (Task and AuditEntry exist independently).
  // Captured by: every Mutation whose op = Deleted still has a mutEntry.
  all m : Mutation | m.mutOp = Deleted implies (some m.mutEntry)
  some AuditEntry
}
assert FR_017_AuditImmutableAndPersisted { FR_017_AuditImmutableAndPersisted }
check FR_017_AuditImmutableAndPersisted for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019
// Audit trail is readable only by callers in the read-set (owner, sharee, team admin).
pred FR_019_AuditVisibility {
  // Only callers with read access may appear as actors on audit-trail reads.
  // Modelled as: every AuditEntry's actor has read access to the task.
  all ae : AuditEntry | hasReadAccess[ae.entryActor, ae.entryTask]
  // TeamAdmin of the task's team always has read access.
  RelTeamAdmin -> OpGetAudit in PermMatrix.allowed
  RelOwner     -> OpGetAudit in PermMatrix.allowed
  RelSharee    -> OpGetAudit in PermMatrix.allowed
  // Outsider and InTeamNone do NOT have audit access.
  RelOutsider   -> OpGetAudit not in PermMatrix.allowed
  RelInTeamNone -> OpGetAudit not in PermMatrix.allowed
  some AuditEntry
}
assert FR_019_AuditVisibility { FR_019_AuditVisibility }
check FR_019_AuditVisibility for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 FR-004 FR-005 FR-006
// Admin can access all tasks in their team; members can only access tasks they own or share.
pred FR_003_005_AdminFullTeamAccess {
  // All mutations by TeamAdmin actors are within their team.
  all m : Mutation |
    m.mutActor.userRole = TeamAdmin implies m.mutActor.userTeam = m.mutTask.taskTeam
  // TeamAdmin has get/patch-fields/delete/get-audit in the permission matrix.
  RelTeamAdmin -> OpGetTask     in PermMatrix.allowed
  RelTeamAdmin -> OpPatchFields in PermMatrix.allowed
  RelTeamAdmin -> OpDeleteTask  in PermMatrix.allowed
  RelTeamAdmin -> OpGetAudit    in PermMatrix.allowed
  // InTeamNone (member with no relationship) has no allowed task operations.
  no (RelInTeamNone -> OperationKind) & PermMatrix.allowed
  some Task
}
assert FR_003_005_AdminFullTeamAccess { FR_003_005_AdminFullTeamAccess }
check FR_003_005_AdminFullTeamAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 — cross-team isolation overrides all roles
pred FR_006_CrossTeamIsolationAbsolute {
  // No task exists where a sharee is from a different team.
  all t : Task | all u : t.taskSharedWith | u.userTeam = t.taskTeam
  // No mutation is performed by a cross-team actor.
  all m : Mutation | m.mutActor.userTeam = m.mutTask.taskTeam
  // Permission matrix has no grants for outsiders.
  no (RelOutsider -> OperationKind) & PermMatrix.allowed
  some Task
  some Mutation
}
assert FR_006_CrossTeamIsolationAbsolute { FR_006_CrossTeamIsolationAbsolute }
check FR_006_CrossTeamIsolationAbsolute for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ShareControlViolation { some m : Mutation | m.mutOp = Shared and m.mutActor != m.mutTask.taskOwner }
