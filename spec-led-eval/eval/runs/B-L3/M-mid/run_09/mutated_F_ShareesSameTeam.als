// === feature_model.als — Alloy model for Multi-Tenant Task Management with Per-Task Sharing and Audit ===
// Feature: B-L3 / 008-task-sharing
// Source artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ENUMERATION SIGS (no dynamic atoms; one sig or abstract with concrete children)
// ─────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig AuditOperation {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOperation {}

// Caller-to-task relationship (computed, not persisted — data-model.md Relationship enum)
abstract sig Relationship {}
one sig Outsider, InTeamNoRel, ShareeRel, AdminRel, OwnerRel extends Relationship {}

// API operation kinds
abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchTaskFields, PatchTaskSharedWith,
        DeleteTask, GetTaskAudit extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (Relationship × OperationKind)
// contracts/http-api.md "Permission matrix" table
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// DOMAIN SIGS (dynamic — need atoms in F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────────────────

sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  taskStatus: one TaskStatus,
  sharedWith: set User
}

// Tasks that have been logically deleted (cascade-deleted from the tasks table,
// but whose AuditEntries survive per FR-017).
sig DeletedTask in Task {}

// Every audit event row (append-only per FR-017; immutable).
sig AuditEntry {
  aeTask      : one Task,    // references Task atom even after deletion (no FK in DB)
  aeTeam      : one Team,
  aeActor     : one User,
  aeActorRole : one Role,    // snapshotted at write time (FR-016)
  aeOp        : one AuditOperation
}

// A Mutation models one logical write operation (create / PATCH / DELETE).
// Each successful mutation produces at least one AuditEntry (FR-015).
sig Mutation {
  mutTask      : one Task,
  mutActor     : one User,
  mutActorRole : one Role,
  mutEntries   : some AuditEntry  // "some" enforces ≥1 entry per mutation
}

// A Request pairs a User with a Task and an OperationKind; rel records the
// computed relationship used by the authorisation check.
sig Request {
  reqCaller : one User,
  reqTask   : one Task,
  reqOp     : one OperationKind,
  reqRel    : one Relationship
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// Every dynamic sig must have at least one atom so `all x: T | P` is non-vacuous.
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Mutation
  some Request
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL INTEGRITY FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Task owner must be in the same team as the task (data-model.md FK owner_id → users;
// tasks.team_id denormalised from owner's team — FR-009).
fact F_TaskOwnerSameTeam {
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

// Cross-team sharing is forbidden in v1: every user in sharedWith must belong
// to the same team as the task (FR-012).
fact F_ShareesSameTeam { /* MUTATED — body cleared by validator */ }

// The task owner is never listed in sharedWith (the owner is already in the
// read-set by definition; spec.md POST /tasks note "do not include their own
// user_id").
fact F_OwnerNotInSharedWith {
  all t: Task | t.taskOwner not in t.sharedWith
}

// AuditEntry's team matches the task's team (denormalised at write time for
// cross-team isolation on the audit endpoint — data-model.md AuditEntry.team_id).
fact F_AuditEntryTeamMatchesTask {
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// Each Mutation references the correct task via its AuditEntries (all audit
// entries produced by a mutation record the same task as the mutation's target).
fact F_MutationEntriesReferSameTask {
  all m: Mutation | all ae: m.mutEntries | ae.aeTask = m.mutTask
}

// Actor and actor-role in mutation entries are consistent with the mutation's
// declared actor (FR-016 snapshot semantics: aeActorRole records the role at
// the time of the event, which equals the actor's role in the same request).
fact F_MutationEntriesActorConsistent {
  all m: Mutation | all ae: m.mutEntries |
    ae.aeActor = m.mutActor and ae.aeActorRole = m.mutActorRole
}

// ─────────────────────────────────────────────────────────────────────────────
// RELATIONSHIP COMPUTATION
// The five mutually-exclusive relationships between a caller and a task.
// Mirrors permissions.relationship() in data-model.md.
// ─────────────────────────────────────────────────────────────────────────────
fact F_RelationshipMutuallyExclusive {
  // Outsider: different team — all others excluded
  all r: Request |
    (r.reqCaller.userTeam != r.reqTask.taskTeam) => r.reqRel = Outsider

  // Owner: caller is the task owner (implicitly same team per F_TaskOwnerSameTeam)
  all r: Request |
    (r.reqCaller = r.reqTask.taskOwner) => r.reqRel = OwnerRel

  // AdminRel: TeamAdmin in the same team, not the owner
  all r: Request |
    (r.reqCaller.userRole = TeamAdmin
     and r.reqCaller.userTeam = r.reqTask.taskTeam
     and r.reqCaller != r.reqTask.taskOwner) => r.reqRel = AdminRel

  // ShareeRel: Member in sharedWith, same team, not owner, not admin
  all r: Request |
    (r.reqCaller in r.reqTask.sharedWith
     and r.reqCaller.userRole = Member
     and r.reqCaller != r.reqTask.taskOwner
     and r.reqCaller.userTeam = r.reqTask.taskTeam) => r.reqRel = ShareeRel

  // InTeamNoRel: same team, Member, not owner, not sharee
  all r: Request |
    (r.reqCaller.userTeam = r.reqTask.taskTeam
     and r.reqCaller.userRole = Member
     and r.reqCaller != r.reqTask.taskOwner
     and r.reqCaller not in r.reqTask.sharedWith) => r.reqRel = InTeamNoRel
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX FACT
// contracts/http-api.md "Permission matrix" — closed world (explicit enumeration).
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  // GetTask: Owner, Sharee, Admin only
  OwnerRel   -> GetTask   in PermMatrix.Allowed
  ShareeRel  -> GetTask   in PermMatrix.Allowed
  AdminRel   -> GetTask   in PermMatrix.Allowed

  // PatchTaskFields (no shared_with): Owner, Sharee, Admin
  OwnerRel   -> PatchTaskFields in PermMatrix.Allowed
  ShareeRel  -> PatchTaskFields in PermMatrix.Allowed
  AdminRel   -> PatchTaskFields in PermMatrix.Allowed

  // PatchTaskSharedWith: Owner only
  OwnerRel   -> PatchTaskSharedWith in PermMatrix.Allowed

  // DeleteTask: Owner and Admin only
  OwnerRel   -> DeleteTask in PermMatrix.Allowed
  AdminRel   -> DeleteTask in PermMatrix.Allowed

  // GetTaskAudit: Owner, Sharee, Admin
  OwnerRel   -> GetTaskAudit in PermMatrix.Allowed
  ShareeRel  -> GetTaskAudit in PermMatrix.Allowed
  AdminRel   -> GetTaskAudit in PermMatrix.Allowed

  // PostTasks: any authenticated in-team user (modelled via InTeamNoRel as
  // baseline "same team, no task relationship yet" plus Owner for completeness)
  InTeamNoRel -> PostTasks in PermMatrix.Allowed
  OwnerRel    -> PostTasks in PermMatrix.Allowed
  AdminRel    -> PostTasks in PermMatrix.Allowed
  ShareeRel   -> PostTasks in PermMatrix.Allowed

  // Closed world: exactly these cells are allowed.
  PermMatrix.Allowed =
    (OwnerRel  -> GetTask)
  + (ShareeRel -> GetTask)
  + (AdminRel  -> GetTask)
  + (OwnerRel  -> PatchTaskFields)
  + (ShareeRel -> PatchTaskFields)
  + (AdminRel  -> PatchTaskFields)
  + (OwnerRel  -> PatchTaskSharedWith)
  + (OwnerRel  -> DeleteTask)
  + (AdminRel  -> DeleteTask)
  + (OwnerRel  -> GetTaskAudit)
  + (ShareeRel -> GetTaskAudit)
  + (AdminRel  -> GetTaskAudit)
  + (InTeamNoRel -> PostTasks)
  + (OwnerRel    -> PostTasks)
  + (AdminRel    -> PostTasks)
  + (ShareeRel   -> PostTasks)
}

// Every allowed Request is consistent with the permission matrix.
fact F_RequestsRespectMatrix {
  all r: Request |
    r.reqRel -> r.reqOp in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Every AuditEntry belongs to exactly one Mutation (no orphan entries).
fact F_AuditEntryBelongsToMutation {
  all ae: AuditEntry | one m: Mutation | ae in m.mutEntries
}

// Deleted tasks retain their audit entries (FR-017): a DeletedTask must have
// at least one AuditEntry with operation = OpDeleted.
fact F_DeletedTaskHasDeletedEntry {
  all t: DeletedTask |
    some ae: AuditEntry | ae.aeTask = t and ae.aeOp = OpDeleted
}

// Append-only: no two distinct AuditEntries record the same (task, operation,
// actor) triple — an edit of an existing entry would appear as an exact duplicate
// from the "what happened" perspective, which is disallowed by immutability
// (FR-017).  We encode immutability as: AuditEntries are never superseded, i.e.,
// no separate fact tracks "this entry replaced that entry."
// (The absence of any UPDATE/DELETE path is the real enforcement; the model
// captures it by making AuditEntry the only record of an event.)
fact F_AppendOnlyAuditEntries {
  // Structural encode: every AuditEntry is reachable via exactly one Mutation's
  // mutEntries set — no entry can be "re-issued" (mutated) because doing so
  // would require it to belong to a second Mutation targeting the same task with
  // the same operation, which our uniqueness rule below prohibits.
  no disj ae1, ae2: AuditEntry |
    ae1.aeTask = ae2.aeTask
    and ae1.aeActor = ae2.aeActor
    and ae1.aeOp = ae2.aeOp
    and ae1.aeActorRole = ae2.aeActorRole
    and ae1 in { m: Mutation | some x: m.mutEntries | x = ae1 }.mutEntries
    and ae2 in { m: Mutation | some x: m.mutEntries | x = ae2 }.mutEntries
    and ae1 != ae2
}

// Attribution: the actor role stored in an AuditEntry is consistent with the
// actor's actual role at the time of mutation (snapshotted per FR-016).
// The snapshot equals the actor's current role in this static model.
fact F_AttributionCorrectness {
  all ae: AuditEntry | ae.aeActorRole = ae.aeActor.userRole
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER PREDICATES
// ─────────────────────────────────────────────────────────────────────────────
pred hasReadAccess[u: User, t: Task] {
  u = t.taskOwner
  or (u.userRole = TeamAdmin and u.userTeam = t.taskTeam)
  or u in t.sharedWith
}

pred canDelete[u: User, t: Task] {
  u = t.taskOwner
  or (u.userRole = TeamAdmin and u.userTeam = t.taskTeam)
}

pred canChangeSharedWith[u: User, t: Task] {
  u = t.taskOwner
}

pred isOutsider[u: User, t: Task] {
  u.userTeam != t.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003, FR-004, FR-005, FR-006
// ─────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
  some Request   // non-vacuous
  // Outsider and InTeamNoRel callers cannot perform any task-level read/write op
  all r: Request |
    (r.reqRel = Outsider or r.reqRel = InTeamNoRel) =>
      r.reqOp not in (GetTask + PatchTaskFields + PatchTaskSharedWith + DeleteTask + GetTaskAudit)
  // Sharee cannot delete
  all r: Request |
    r.reqRel = ShareeRel => r.reqOp != DeleteTask
  // Sharee cannot change shared_with
  all r: Request |
    r.reqRel = ShareeRel => r.reqOp != PatchTaskSharedWith
  // Admin cannot change shared_with (they are not the owner)
  all r: Request |
    r.reqRel = AdminRel => r.reqOp != PatchTaskSharedWith
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission matrix (all cells defined)
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
  // Every (Relationship × OperationKind) pair either is in the allowed set or isn't —
  // the closed-world definition in F_PermissionMatrix guarantees no undefined cells.
  // Check: the number of allowed pairs is exactly what we defined.
  some PermMatrix
  // The allowed set is non-empty (at least one permission granted)
  some PermMatrix.Allowed
  // Outsider and InTeamNoRel have no task-level allowances
  no (Outsider + InTeamNoRel) ->
      (GetTask + PatchTaskFields + PatchTaskSharedWith + DeleteTask + GetTaskAudit)
    & PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere
// ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
// ─────────────────────────────────────────────────────────────────────────────
pred AuthRequiredEverywhere {
  // All Requests in the model are authenticated (the 401-path is pre-dispatch;
  // unauthenticated callers never reach the authorisation layer).
  // Modelled by requiring every Request to have a valid User with a known team.
  some Request
  all r: Request | one r.reqCaller and one r.reqCaller.userTeam and one r.reqCaller.userRole
  // No mutation is attributed to a User that is not in any team
  all m: Mutation | one m.mutActor.userTeam
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-015; data-model.md PATCH→audit decomposition
// ─────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
  some Mutation
  // Every Mutation produces at least one AuditEntry.
  all m: Mutation | some m.mutEntries
  // Every AuditEntry is produced by exactly one Mutation (no orphan entries).
  all ae: AuditEntry | one m: Mutation | ae in m.mutEntries
  // Every AuditEntry records the task that its parent Mutation targeted.
  all m: Mutation | all ae: m.mutEntries | ae.aeTask = m.mutTask
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly
// ANCHOR: spec.md FR-017; data-model.md "Append-only: no UPDATE/DELETE SQL"
// ─────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
  some AuditEntry
  // No AuditEntry is a "re-write" of another entry for the same (task, actor, operation).
  all disj ae1, ae2: AuditEntry |
    not (ae1.aeTask = ae2.aeTask
         and ae1.aeActor = ae2.aeActor
         and ae1.aeOp = ae2.aeOp
         and ae1.aeActorRole = ae2.aeActorRole)
  // Deleted tasks retain their audit entries: every DeletedTask has a deletion entry.
  all t: DeletedTask |
    (some ae: AuditEntry | ae.aeTask = t and ae.aeOp = OpDeleted)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role "snapshotted"
// ─────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
  some AuditEntry
  // Actor role in every entry matches the actor's actual role (snapshot = current
  // role in this static model — the snapshot semantics means at the moment of write
  // the role field equals the actor's role claim from the OAuth token).
  all ae: AuditEntry | ae.aeActorRole = ae.aeActor.userRole
  // Actor in every entry belongs to the same team as the audited task.
  all ae: AuditEntry | ae.aeActor.userTeam = ae.aeTask.taskTeam
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity
// ANCHOR: spec.md FR-009; data-model.md Task.owner_id "immutable … the creator"
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner (enforced by `one` multiplicity on taskOwner).
  all t: Task | one t.taskOwner
  // The owner's team equals the task's team.
  all t: Task | t.taskOwner.userTeam = t.taskTeam
  // No task is ownerless.
  no t: Task | no t.taskOwner
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-003, FR-004, FR-005; contracts/http-api.md permission matrix
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
  some Task
  some User
  // A Member can read a task IFF they own it OR are a sharee.
  all u: User, t: Task |
    (u.userRole = Member and u.userTeam = t.taskTeam) =>
      (hasReadAccess[u, t] <=>
         (u = t.taskOwner or u in t.sharedWith))
  // A TeamAdmin can read any task in their team.
  all u: User, t: Task |
    (u.userRole = TeamAdmin and u.userTeam = t.taskTeam) =>
      hasReadAccess[u, t]
  // Only owner can change sharedWith.
  all u: User, t: Task |
    canChangeSharedWith[u, t] => u = t.taskOwner
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-014; contracts/http-api.md "Byte-equivalent not-found response"
// ─────────────────────────────────────────────────────────────────────────────
// We model "leakage" as any Request by a caller who is an Outsider or InTeamNoRel
// being routed to an operation that would reveal task-existence information.
// The no-leakage invariant is: Outsider and InTeamNoRel callers are NEVER allowed
// to perform GetTask, PatchTaskFields, PatchTaskSharedWith, DeleteTask, or GetTaskAudit.
pred NoInformationLeakage {
  some Request
  // No allowed operation for Outsider or InTeamNoRel reveals task data.
  no r: Request |
    (r.reqRel = Outsider or r.reqRel = InTeamNoRel)
    and r.reqOp in (GetTask + PatchTaskFields + PatchTaskSharedWith + DeleteTask + GetTaskAudit)
  // Specifically: cross-team callers cannot reach the audit endpoint.
  no r: Request |
    r.reqRel = Outsider and r.reqOp = GetTaskAudit
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001 — all endpoints require auth; 401 precedes business logic
// ─────────────────────────────────────────────────────────────────────────────
pred FR_001_AuthRequired {
  some Request
  // Every request has an authenticated caller with a team and role.
  all r: Request |
    one r.reqCaller and one r.reqCaller.userTeam and one r.reqCaller.userRole
  // No mutation can be attributed to an actor without a team claim.
  all m: Mutation |
    some m.mutActor.userTeam
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002 — user belongs to exactly one team
// ─────────────────────────────────────────────────────────────────────────────
pred FR_002_OneTeamPerUser {
  some User
  all u: User | one u.userTeam
}

assert FR_002_OneTeamPerUser { FR_002_OneTeamPerUser }
check FR_002_OneTeamPerUser for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004 — member cannot see tasks they don't own/share
// ─────────────────────────────────────────────────────────────────────────────
pred FR_004_MemberCannotSeeUnrelatedTasks {
  some Task
  some User
  // No Member has read access to a task in their team unless they own or share it.
  all u: User, t: Task |
    (u.userRole = Member and u.userTeam = t.taskTeam
     and u != t.taskOwner and u not in t.sharedWith) =>
      not hasReadAccess[u, t]
}

assert FR_004_MemberCannotSeeUnrelatedTasks { FR_004_MemberCannotSeeUnrelatedTasks }
check FR_004_MemberCannotSeeUnrelatedTasks for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005 — team admin can view/edit/delete any task in their team
// ─────────────────────────────────────────────────────────────────────────────
pred FR_005_AdminFullAccessInTeam {
  some User
  some Task
  // Every TeamAdmin has read access to every task in their own team.
  all u: User, t: Task |
    (u.userRole = TeamAdmin and u.userTeam = t.taskTeam) => hasReadAccess[u, t]
  // Every TeamAdmin can delete tasks in their own team.
  all u: User, t: Task |
    (u.userRole = TeamAdmin and u.userTeam = t.taskTeam) => canDelete[u, t]
}

assert FR_005_AdminFullAccessInTeam { FR_005_AdminFullAccessInTeam }
check FR_005_AdminFullAccessInTeam for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006 — no user accesses tasks in a different team
// ─────────────────────────────────────────────────────────────────────────────
pred FR_006_CrossTeamIsolation {
  some Task
  some User
  // No user can read or act on tasks in a different team.
  all u: User, t: Task |
    u.userTeam != t.taskTeam => (not hasReadAccess[u, t] and not canDelete[u, t])
  // Cross-team requests are never in the allowed set.
  no r: Request |
    r.reqCaller.userTeam != r.reqTask.taskTeam
    and r.reqOp in (GetTask + PatchTaskFields + PatchTaskSharedWith + DeleteTask + GetTaskAudit)
}

assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009 — owner_id and team_id are immutable
// (In the static model this is expressed as: no Mutation changes a task's owner
//  or team — modelled by ensuring the task's owner and team fields are single-valued.)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_009_ImmutableOwnerAndTeam {
  some Task
  // Every task has exactly one owner and one team (immutability encoded as
  // single-valuedness; no Mutation re-assigns them).
  all t: Task | one t.taskOwner and one t.taskTeam
  // The team on every audit entry matches the task's team at the time of write —
  // since team_id never changes, the denormalised team_id is always correct.
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-010 / SC-011 — only owner can change shared_with
// ─────────────────────────────────────────────────────────────────────────────
pred FR_010_OnlyOwnerChangesSharedWith {
  some Task
  some User
  // canChangeSharedWith is true only for the owner.
  all u: User, t: Task |
    canChangeSharedWith[u, t] => u = t.taskOwner
  // Specifically, a TeamAdmin who is not the owner cannot change shared_with.
  all u: User, t: Task |
    (u.userRole = TeamAdmin and u != t.taskOwner) => not canChangeSharedWith[u, t]
  // No Request by a non-owner is allowed the PatchTaskSharedWith operation.
  all r: Request |
    (r.reqCaller != r.reqTask.taskOwner) => r.reqOp != PatchTaskSharedWith
}

assert FR_010_OnlyOwnerChangesSharedWith { FR_010_OnlyOwnerChangesSharedWith }
check FR_010_OnlyOwnerChangesSharedWith for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B — sharee may view/edit but not delete
// ─────────────────────────────────────────────────────────────────────────────
pred FR_011_ShareeCannotDelete {
  some Task
  some User
  // A sharee who is not the owner cannot delete the task.
  all u: User, t: Task |
    (u in t.sharedWith and u != t.taskOwner) => not canDelete[u, t]
  // No Request with ShareeRel is allowed DeleteTask.
  no r: Request |
    r.reqRel = ShareeRel and r.reqOp = DeleteTask
}

assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012 — cross-team sharing forbidden
// ─────────────────────────────────────────────────────────────────────────────
pred FR_012_NoSameTeamSharing {
  some Task
  // Every user in a task's sharedWith list is in the same team as the task.
  all t: Task | all u: t.sharedWith | u.userTeam = t.taskTeam
}

assert FR_012_NoSameTeamSharing { FR_012_NoSameTeamSharing }
check FR_012_NoSameTeamSharing for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013 — share and unshare events produce audit entries
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_ShareAuditEntries {
  // Every Mutation is covered by at least one AuditEntry with a recognised operation.
  some Mutation
  all m: Mutation | some m.mutEntries
  all ae: AuditEntry |
    ae.aeOp in (OpCreated + OpEdited + OpDeleted + OpShared + OpUnshared)
}

assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 — no state change without audit entry; no audit without state change
// ─────────────────────────────────────────────────────────────────────────────
pred FR_015_MutationAuditBijection {
  some Mutation
  // Every Mutation has at least one AuditEntry.
  all m: Mutation | some m.mutEntries
  // Every AuditEntry belongs to exactly one Mutation.
  all ae: AuditEntry | (one m: Mutation | ae in m.mutEntries)
  // No AuditEntry exists without a parent Mutation.
  AuditEntry = { ae: AuditEntry | some m: Mutation | ae in m.mutEntries }
}

assert FR_015_MutationAuditBijection { FR_015_MutationAuditBijection }
check FR_015_MutationAuditBijection for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit entries are immutable and outlive deleted tasks
// ─────────────────────────────────────────────────────────────────────────────
pred FR_017_AuditOutlivesTask {
  some DeletedTask
  // Every DeletedTask has at least one AuditEntry (the 'deleted' event).
  all t: DeletedTask |
    (some ae: AuditEntry | ae.aeTask = t and ae.aeOp = OpDeleted)
  // Audit entries for deleted tasks still exist in the AuditEntry relation.
  all t: DeletedTask | some ae: AuditEntry | ae.aeTask = t
}

assert FR_017_AuditOutlivesTask { FR_017_AuditOutlivesTask }
check FR_017_AuditOutlivesTask for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-019 — audit endpoint access mirrors task read access
// ─────────────────────────────────────────────────────────────────────────────
pred FR_019_AuditAccessMirrorsReadAccess {
  some Request
  // GetTaskAudit is allowed exactly when GetTask is allowed.
  all r: Request |
    (r.reqRel -> GetTaskAudit in PermMatrix.Allowed) <=>
    (r.reqRel -> GetTask in PermMatrix.Allowed)
}

assert FR_019_AuditAccessMirrorsReadAccess { FR_019_AuditAccessMirrorsReadAccess }
check FR_019_AuditAccessMirrorsReadAccess for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PrivilegeMonotonicity
// ANCHOR: spec.md FR-005 (admin is superset of member read-side); contracts/http-api.md matrix
// ─────────────────────────────────────────────────────────────────────────────
// AdminRel permissions are a superset of ShareeRel and InTeamNoRel permissions.
pred PrivilegeMonotonicity {
  some PermMatrix
  // AdminRel allows everything ShareeRel allows.
  all op: OperationKind |
    ShareeRel -> op in PermMatrix.Allowed => AdminRel -> op in PermMatrix.Allowed
  // AdminRel allows everything InTeamNoRel allows.
  all op: OperationKind |
    InTeamNoRel -> op in PermMatrix.Allowed => AdminRel -> op in PermMatrix.Allowed
  // OwnerRel allows everything AdminRel allows (except PatchTaskSharedWith which
  // owner has exclusively — both are verified; the key monotonicity claim is
  // owner ⊇ admin for task-level ops).
  all op: OperationKind |
    AdminRel -> op in PermMatrix.Allowed => OwnerRel -> op in PermMatrix.Allowed
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006 / FR-014 — admin privilege does not cross team boundary
// ─────────────────────────────────────────────────────────────────────────────
pred FR_006_AdminPrivilegeDoesNotCrossTeams {
  some Task
  some User
  // Even a TeamAdmin cannot read a task in a different team.
  all u: User, t: Task |
    (u.userRole = TeamAdmin and u.userTeam != t.taskTeam) =>
      (not hasReadAccess[u, t] and not canDelete[u, t])
}

assert FR_006_AdminPrivilegeDoesNotCrossTeams { FR_006_AdminPrivilegeDoesNotCrossTeams }
check FR_006_AdminPrivilegeDoesNotCrossTeams for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeamShareViolation { some t: Task | some u: User | u in t.sharedWith and u.userTeam != t.taskTeam }
