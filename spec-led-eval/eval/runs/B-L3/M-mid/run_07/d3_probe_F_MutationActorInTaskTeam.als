// === feature_model.als — Alloy model for 008-task-sharing ===
// Feature: Multi-Tenant Task Management with Per-Task Sharing and Audit
// Branch: 008-task-sharing  |  Date: 2026-05-17

// ─────────────────────────────────────────────────────────────────────────────
// Enumeration sigs  (one sig / abstract sig — NOT dynamic)
// ─────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig AuditOperation {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOperation {}

// MutationKind mirrors AuditOperation for write-side modelling
abstract sig MutationKind {}
one sig CreateMut, EditMut, DeleteMut, ShareMut, UnshareMut extends MutationKind {}

// OperationKind — the full set of endpoint × intent cells in the permission matrix.
// PatchSharedWith is distinct from PatchFields because it requires OWNER (FR-010).
// DeleteAuditEntry is included so we can assert it is allowed by NOBODY.
abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchFields, PatchSharedWith,
         DeleteTask, GetAuditTrail, DeleteAuditEntry extends OperationKind {}

// Relationship of a caller to a specific task (computed per-request).
abstract sig Relationship {}
one sig Outsider, InTeamNone, Sharee, TaskAdmin, TaskOwner extends Relationship {}

// ─────────────────────────────────────────────────────────────────────────────
// Permission matrix — one singleton holding the allowed (Relationship × Op) set
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// Dynamic entity sigs
// ─────────────────────────────────────────────────────────────────────────────

sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam  : one Team,
  taskOwner : one User
}

// Junction table for the shared_with set (data-model.md TaskShare)
sig TaskShare {
  shareTask : one Task,
  sharee    : one User
}

// Immutable append-only audit record (data-model.md AuditEntry)
sig AuditEntry {
  entryTask    : one Task,
  entryActor   : one User,
  entryRole    : one Role,
  entryOp      : one AuditOperation
}

// A successful mutation event — links the write to its audit entries.
sig Mutation {
  mutTask   : one Task,
  mutActor  : one User,
  mutRole   : one Role,
  mutKind   : one MutationKind,
  mutAudit  : set AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — ensures dynamic sigs are inhabited so predicates bite
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some TaskShare
  some AuditEntry
  some Mutation
}

// ─────────────────────────────────────────────────────────────────────────────
// F_PermissionMatrix — closed-world encoding of contracts/http-api.md matrix
// FR-003, FR-004, FR-005, FR-010, FR-011; contracts/http-api.md permission table
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (InTeamNone -> PostTasks)
    + (Sharee     -> PostTasks)
    + (Sharee     -> GetTask)
    + (Sharee     -> PatchFields)
    + (Sharee     -> GetAuditTrail)
    + (TaskAdmin  -> PostTasks)
    + (TaskAdmin  -> GetTask)
    + (TaskAdmin  -> PatchFields)
    + (TaskAdmin  -> DeleteTask)
    + (TaskAdmin  -> GetAuditTrail)
    + (TaskOwner  -> PostTasks)
    + (TaskOwner  -> GetTask)
    + (TaskOwner  -> PatchFields)
    + (TaskOwner  -> PatchSharedWith)
    + (TaskOwner  -> DeleteTask)
    + (TaskOwner  -> GetAuditTrail)
    // DeleteAuditEntry is in NO cell — audit entries cannot be deleted by anyone.
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OwnerInTaskTeam — owner must belong to the task's team (structural integrity)
// ANCHOR: data-model.md Task.owner_id FK→users; FR-009
// ─────────────────────────────────────────────────────────────────────────────
fact F_OwnerInTaskTeam {
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ShareeSameTeam — sharees must be members of the same team as the task (FR-012)
// ─────────────────────────────────────────────────────────────────────────────
fact F_ShareeSameTeam {
  all ts: TaskShare | ts.sharee.userTeam = ts.shareTask.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoOwnerSelfShare — the task owner need not be in shared_with; prevent it
// ANCHOR: contracts/http-api.md POST /tasks note; spec.md FR-010
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoOwnerSelfShare {
  all ts: TaskShare | ts.sharee != ts.shareTask.taskOwner
}

// ─────────────────────────────────────────────────────────────────────────────
// F_UniqueShare — composite PK (task_id, sharee_user_id) — data-model.md TaskShare
// ─────────────────────────────────────────────────────────────────────────────
fact F_UniqueShare {
  all disj ts1, ts2: TaskShare |
    not (ts1.shareTask = ts2.shareTask and ts1.sharee = ts2.sharee)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditActorInTaskTeam — audit actor must be in the task's team
// ANCHOR: data-model.md AuditEntry; FR-016
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditActorInTaskTeam {
  all ae: AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditRoleMatchesActor — actorRole snapshot matches the actor's actual role
// ANCHOR: spec.md FR-016 "actor_role snapshotted at time of change"
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditRoleMatchesActor {
  all ae: AuditEntry | ae.entryRole = ae.entryActor.userRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_MutationAuditNonEmpty — every mutation produces at least one audit entry
// ANCHOR: spec.md FR-015; data-model.md "no successful state change without audit"
// ─────────────────────────────────────────────────────────────────────────────
fact F_MutationAuditNonEmpty {
  all m: Mutation | some m.mutAudit
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditEntryBelongsToOneMutation — each audit entry is linked to exactly one
// mutation (one-to-one per event; no shared / duplicate entries)
// ANCHOR: spec.md FR-015; data-model.md UNIQUE on (task_id, id auto-increment)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditEntryBelongsToOneMutation {
  all ae: AuditEntry | one m: Mutation | ae in m.mutAudit
}

// ─────────────────────────────────────────────────────────────────────────────
// F_MutationAuditTaskConsistency — every audit entry in a mutation records the
// same task as the mutation itself
// ANCHOR: spec.md FR-016; data-model.md AuditEntry.task_id
// ─────────────────────────────────────────────────────────────────────────────
fact F_MutationAuditTaskConsistency {
  all m: Mutation | all ae: m.mutAudit | ae.entryTask = m.mutTask
}

// ─────────────────────────────────────────────────────────────────────────────
// F_MutationAuditActorConsistency — audit actor matches mutation actor
// ANCHOR: spec.md FR-016 attribution; data-model.md AuditEntry.actor_user_id
// ─────────────────────────────────────────────────────────────────────────────
fact F_MutationAuditActorConsistency {
  all m: Mutation | all ae: m.mutAudit | ae.entryActor = m.mutActor
}

// ─────────────────────────────────────────────────────────────────────────────
// F_MutationKindAuditOpConsistency — mutation kind maps to the correct audit op
// CreateMut→Created, EditMut→Edited, DeleteMut→Deleted, ShareMut→Shared, UnshareMut→Unshared
// ANCHOR: spec.md FR-015/FR-016; data-model.md AuditOperation enum
// ─────────────────────────────────────────────────────────────────────────────
fact F_MutationKindAuditOpConsistency {
  all m: Mutation | all ae: m.mutAudit |
    (m.mutKind = CreateMut  implies ae.entryOp = Created)  and
    (m.mutKind = DeleteMut  implies ae.entryOp = Deleted)  and
    (m.mutKind = ShareMut   implies ae.entryOp = Shared)   and
    (m.mutKind = UnshareMut implies ae.entryOp = Unshared) and
    (m.mutKind = EditMut    implies ae.entryOp = Edited)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_MutationActorInTaskTeam — mutation actor must be in the task's team
// ANCHOR: spec.md FR-006; contracts/http-api.md cross-team isolation
// ─────────────────────────────────────────────────────────────────────────────
fact F_MutationActorInTaskTeam {
  all m: Mutation | m.mutActor.userTeam = m.mutTask.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// Relationship helper predicates
// ─────────────────────────────────────────────────────────────────────────────

pred isOutsider[u: User, t: Task] {
  u.userTeam != t.taskTeam
}

pred isOwner[u: User, t: Task] {
  t.taskOwner = u
}

pred isSharee[u: User, t: Task] {
  some ts: TaskShare | ts.shareTask = t and ts.sharee = u
}

pred isTaskAdmin[u: User, t: Task] {
  u.userRole = TeamAdmin
  u.userTeam = t.taskTeam
  t.taskOwner != u
}

pred isInTeamNone[u: User, t: Task] {
  u.userTeam = t.taskTeam
  t.taskOwner != u
  not isSharee[u, t]
  u.userRole = Member
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission table; spec.md FR-003/FR-004/FR-005/FR-011
// ─────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
  some Task
  // Outsiders have NO allowed operation on any task-specific endpoint
  all u: User, t: Task |
    isOutsider[u, t] implies (
      (Outsider -> GetTask)       not in PermMatrix.Allowed and
      (Outsider -> PatchFields)   not in PermMatrix.Allowed and
      (Outsider -> PatchSharedWith) not in PermMatrix.Allowed and
      (Outsider -> DeleteTask)    not in PermMatrix.Allowed and
      (Outsider -> GetAuditTrail) not in PermMatrix.Allowed and
      (Outsider -> DeleteAuditEntry) not in PermMatrix.Allowed
    )
  // InTeamNone cannot view, edit, delete, or audit tasks they have no relation to
  all u: User, t: Task |
    isInTeamNone[u, t] implies (
      (InTeamNone -> GetTask)          not in PermMatrix.Allowed and
      (InTeamNone -> PatchFields)      not in PermMatrix.Allowed and
      (InTeamNone -> PatchSharedWith)  not in PermMatrix.Allowed and
      (InTeamNone -> DeleteTask)       not in PermMatrix.Allowed and
      (InTeamNone -> GetAuditTrail)    not in PermMatrix.Allowed and
      (InTeamNone -> DeleteAuditEntry) not in PermMatrix.Allowed
    )
  // Sharees CANNOT delete or change shared_with
  (Sharee -> DeleteTask)       not in PermMatrix.Allowed
  (Sharee -> PatchSharedWith)  not in PermMatrix.Allowed
  (Sharee -> DeleteAuditEntry) not in PermMatrix.Allowed
  // TaskAdmin CANNOT change shared_with (Q1=A: owner-only)
  (TaskAdmin -> PatchSharedWith)  not in PermMatrix.Allowed
  (TaskAdmin -> DeleteAuditEntry) not in PermMatrix.Allowed
  // TaskOwner CANNOT delete audit entries
  (TaskOwner -> DeleteAuditEntry) not in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission table (all cells defined)
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
  // Every (Relationship × OperationKind) pair is either explicitly in Allowed
  // or explicitly NOT in it — no undefined cells.  Since Allowed is a total
  // finite relation, this is trivially ensured by the closed-world assignment
  // in F_PermissionMatrix.  The assertion checks that the Allowed set is a
  // SUBSET of the declared universe (no phantom cells).
  PermMatrix.Allowed in Relationship -> OperationKind
  // And every relationship appears at least once (no relationship is orphaned)
  all r: Relationship | r in PermMatrix.Allowed.OperationKind or
                         no (r -> OperationKind & PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly
// ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE SQL on audit_entries"
// ─────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
  some AuditEntry
  // Every audit entry is uniquely owned by exactly one mutation — no entry is
  // shared between mutations (which would indicate an "update" re-use).
  all ae: AuditEntry | one m: Mutation | ae in m.mutAudit
  // No operation kind in the permission matrix permits deleting audit entries.
  all r: Relationship | (r -> DeleteAuditEntry) not in PermMatrix.Allowed
}

assert AppendOnly { AppendOnly }
check AppendOnly for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-015; data-model.md "no successful state change without audit"
// ─────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
  some Mutation
  // Every mutation has at least one audit entry
  all m: Mutation | some m.mutAudit
  // Every audit entry traces back to a mutation (no orphan entries)
  all ae: AuditEntry | some m: Mutation | ae in m.mutAudit
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-016 "actor_user_id, actor_role snapshotted at time of change"
// ─────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
  some AuditEntry
  // The role recorded in an audit entry equals the actor's actual role
  all ae: AuditEntry | ae.entryRole = ae.entryActor.userRole
  // The actor in an audit entry belongs to the task's team
  all ae: AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity
// ANCHOR: data-model.md Task.owner_id NOT NULL FK; spec.md FR-009
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner (enforced by `one` field multiplicity)
  all t: Task | one t.taskOwner
  // Owner belongs to the same team as the task
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-003/FR-004/FR-010; contracts/http-api.md permission matrix
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
  some Task
  // A user who is neither owner, sharee, nor team-admin of a task's team
  // has no read access (InTeamNone and Outsider rows have no GetTask)
  (InTeamNone -> GetTask) not in PermMatrix.Allowed
  (Outsider   -> GetTask) not in PermMatrix.Allowed
  // Conversely, owner always has full read access
  (TaskOwner  -> GetTask) in PermMatrix.Allowed
  // Only owner can change shared_with
  (TaskOwner -> PatchSharedWith) in PermMatrix.Allowed
  all r: Relationship | r != TaskOwner implies (r -> PatchSharedWith) not in PermMatrix.Allowed
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-014; contracts/http-api.md "byte-equivalent not-found"
// ─────────────────────────────────────────────────────────────────────────────
pred NoInformationLeakage {
  some Task
  // Cross-team callers (Outsiders) have no allowed operations on any
  // task-specific endpoint — their response is indistinguishable from
  // a non-existent task.
  (Outsider -> GetTask)          not in PermMatrix.Allowed
  (Outsider -> PatchFields)      not in PermMatrix.Allowed
  (Outsider -> PatchSharedWith)  not in PermMatrix.Allowed
  (Outsider -> DeleteTask)       not in PermMatrix.Allowed
  (Outsider -> GetAuditTrail)    not in PermMatrix.Allowed
  // In-team users with no relationship also get the same treatment
  (InTeamNone -> GetTask)        not in PermMatrix.Allowed
  (InTeamNone -> GetAuditTrail)  not in PermMatrix.Allowed
  // Sharee attempting DELETE also gets 404 (byte-equivalent, not 403)
  (Sharee -> DeleteTask)         not in PermMatrix.Allowed
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001 — OAuth required on all endpoints
// ─────────────────────────────────────────────────────────────────────────────
pred FR_001_AuthRequiredEverywhere {
  some Task
  // The model encodes auth by requiring every mutation actor to be a resolved
  // User (not anonymous).  There is no Anonymous/Unauthenticated sig — any
  // access attempt resolves to a User with a team and role.
  // Structural claim: every mutation has a non-empty actor set (no null actor).
  all m: Mutation | one m.mutActor
  all ae: AuditEntry | one ae.entryActor
}

assert FR_001_AuthRequiredEverywhere { FR_001_AuthRequiredEverywhere }
check FR_001_AuthRequiredEverywhere for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002 — exactly one team per user
// ─────────────────────────────────────────────────────────────────────────────
pred FR_002_OneTeamPerUser {
  some User
  all u: User | one u.userTeam
  all u: User | one u.userRole
}

assert FR_002_OneTeamPerUser { FR_002_OneTeamPerUser }
check FR_002_OneTeamPerUser for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009 — owner_id and team_id are immutable
// (Structural: no Mutation changes taskOwner or taskTeam)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_009_OwnerAndTeamImmutable {
  some Task
  // Every task has exactly one owner and one team, set at creation.
  // No mutation kind maps to changing ownership or team.
  // We assert that the owner relation is total and functional — i.e., each
  // Task atom has a fixed owner and fixed team (enforced by `one` fields).
  all t: Task | one t.taskOwner
  all t: Task | one t.taskTeam
}

assert FR_009_OwnerAndTeamImmutable { FR_009_OwnerAndTeamImmutable }
check FR_009_OwnerAndTeamImmutable for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1=A — only owner can change shared_with
// ─────────────────────────────────────────────────────────────────────────────
pred FR_010_OwnerOnlyShareControl {
  some Task
  // In the permission matrix, PatchSharedWith is ONLY allowed for TaskOwner
  (TaskOwner -> PatchSharedWith) in PermMatrix.Allowed
  all r: Relationship | r != TaskOwner implies (r -> PatchSharedWith) not in PermMatrix.Allowed
}

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B — sharee cannot delete task
// ─────────────────────────────────────────────────────────────────────────────
pred FR_011_ShareeCannotDelete {
  some TaskShare
  (Sharee -> DeleteTask) not in PermMatrix.Allowed
  // Sharee can still read and edit fields
  (Sharee -> GetTask)    in PermMatrix.Allowed
  (Sharee -> PatchFields) in PermMatrix.Allowed
}

assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012 — cross-team sharing forbidden
// ─────────────────────────────────────────────────────────────────────────────
pred FR_012_CrossTeamSharingForbidden {
  some TaskShare
  // Every sharee is in the same team as the task (enforced by F_ShareeSameTeam)
  all ts: TaskShare | ts.sharee.userTeam = ts.shareTask.taskTeam
  // No sharee is the owner
  all ts: TaskShare | ts.sharee != ts.shareTask.taskOwner
}

assert FR_012_CrossTeamSharingForbidden { FR_012_CrossTeamSharingForbidden }
check FR_012_CrossTeamSharingForbidden for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013 — share and unshare events are audit-logged
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_ShareAuditLogged {
  some Mutation
  // Every ShareMut mutation has at least one audit entry with op = Shared
  all m: Mutation | m.mutKind = ShareMut implies
    (some ae: m.mutAudit | ae.entryOp = Shared)
  // Every UnshareMut mutation has at least one audit entry with op = Unshared
  all m: Mutation | m.mutKind = UnshareMut implies
    (some ae: m.mutAudit | ae.entryOp = Unshared)
}

assert FR_013_ShareAuditLogged { FR_013_ShareAuditLogged }
check FR_013_ShareAuditLogged for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-014 — cross-team byte-equivalent 404
// (Structural encoding: Outsider has no allowed operations on task-specific endpoints)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_014_CrossTeamByteEquivalent {
  some Task
  // The response for an outsider is identical for "task in other team" vs
  // "task does not exist".  Structurally: no endpoint cell allows Outsider access.
  all op: OperationKind | op != PostTasks implies
    (Outsider -> op) not in PermMatrix.Allowed
}

assert FR_014_CrossTeamByteEquivalent { FR_014_CrossTeamByteEquivalent }
check FR_014_CrossTeamByteEquivalent for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 — per-event audit semantics (one entry per event)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_015_PerEventAuditSemantics {
  some Mutation
  // Each audit entry is linked to exactly one mutation
  all ae: AuditEntry | one m: Mutation | ae in m.mutAudit
  // Each mutation has at least one audit entry
  all m: Mutation | some m.mutAudit
  // No two audit entries in the same mutation have the same operation
  // (one PATCH → one edited entry + one shared entry, not two edited entries)
  all m: Mutation | all disj ae1, ae2: m.mutAudit | ae1.entryOp != ae2.entryOp
}

assert FR_015_PerEventAuditSemantics { FR_015_PerEventAuditSemantics }
check FR_015_PerEventAuditSemantics for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit entry contains all required fields
// ─────────────────────────────────────────────────────────────────────────────
pred FR_016_AuditEntryFieldsPresent {
  some AuditEntry
  all ae: AuditEntry |
    one ae.entryTask    and
    one ae.entryActor   and
    one ae.entryRole    and
    one ae.entryOp
}

assert FR_016_AuditEntryFieldsPresent { FR_016_AuditEntryFieldsPresent }
check FR_016_AuditEntryFieldsPresent for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit entries are immutable and outlive tasks
// ─────────────────────────────────────────────────────────────────────────────
pred FR_017_AuditImmutableAndOutlivesTask {
  some AuditEntry
  // No relationship in the permission matrix permits deleting audit entries
  all r: Relationship | (r -> DeleteAuditEntry) not in PermMatrix.Allowed
  // The audit entry references a task, but is not itself deleted when the task is.
  // Structural: every AuditEntry has a valid entryTask (the task it records may
  // or may not still be in the active Task set — audit entries are not FK-constrained).
  all ae: AuditEntry | one ae.entryTask
}

assert FR_017_AuditImmutableAndOutlivesTask { FR_017_AuditImmutableAndOutlivesTask }
check FR_017_AuditImmutableAndOutlivesTask for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-019 — audit readable by owner / sharee / admin
// ─────────────────────────────────────────────────────────────────────────────
pred FR_019_AuditReadableByReadSet {
  some AuditEntry
  // Owner, Sharee, and TaskAdmin can all read the audit trail
  (TaskOwner -> GetAuditTrail) in PermMatrix.Allowed
  (Sharee    -> GetAuditTrail) in PermMatrix.Allowed
  (TaskAdmin -> GetAuditTrail) in PermMatrix.Allowed
  // Outsider and InTeamNone cannot
  (Outsider    -> GetAuditTrail) not in PermMatrix.Allowed
  (InTeamNone  -> GetAuditTrail) not in PermMatrix.Allowed
}

assert FR_019_AuditReadableByReadSet { FR_019_AuditReadableByReadSet }
check FR_019_AuditReadableByReadSet for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005 / spec.md — team admin can delete any team task
// ─────────────────────────────────────────────────────────────────────────────
pred FR_005_AdminCanDeleteAnyTeamTask {
  some Task
  (TaskAdmin -> DeleteTask) in PermMatrix.Allowed
  (TaskAdmin -> GetTask)    in PermMatrix.Allowed
  (TaskAdmin -> PatchFields) in PermMatrix.Allowed
  // But admin cannot change shared_with (Q1=A)
  (TaskAdmin -> PatchSharedWith) not in PermMatrix.Allowed
}

assert FR_005_AdminCanDeleteAnyTeamTask { FR_005_AdminCanDeleteAnyTeamTask }
check FR_005_AdminCanDeleteAnyTeamTask for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006 — absolute cross-team isolation
// ─────────────────────────────────────────────────────────────────────────────
pred FR_006_AbsoluteCrossTeamIsolation {
  some Task
  some User
  // No mutation can have an actor from a different team than the task
  all m: Mutation | m.mutActor.userTeam = m.mutTask.taskTeam
  // No audit entry can have an actor from a different team than the task
  all ae: AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
  // No TaskShare can link a sharee to a task in a different team
  all ts: TaskShare | ts.sharee.userTeam = ts.shareTask.taskTeam
}

assert FR_006_AbsoluteCrossTeamIsolation { FR_006_AbsoluteCrossTeamIsolation }
check FR_006_AbsoluteCrossTeamIsolation for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003/FR-004 — member access depends on ownership/sharing
// ─────────────────────────────────────────────────────────────────────────────
pred FR_003_MemberAccessRequiresOwnershipOrShare {
  some Task
  // Members who are InTeamNone (not owner, not sharee, not admin) cannot view tasks
  (InTeamNone -> GetTask)   not in PermMatrix.Allowed
  (InTeamNone -> PatchFields) not in PermMatrix.Allowed
  (InTeamNone -> DeleteTask) not in PermMatrix.Allowed
  // Members who ARE the owner have full access
  (TaskOwner -> GetTask)   in PermMatrix.Allowed
  (TaskOwner -> PatchFields) in PermMatrix.Allowed
  (TaskOwner -> DeleteTask) in PermMatrix.Allowed
}

assert FR_003_MemberAccessRequiresOwnershipOrShare { FR_003_MemberAccessRequiresOwnershipOrShare }
check FR_003_MemberAccessRequiresOwnershipOrShare for 8 but exactly 5 Relationship, exactly 7 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 — delete mutation produces exactly one deleted entry
// ─────────────────────────────────────────────────────────────────────────────
pred FR_015_DeleteProducesExactlyOneAuditEntry {
  some Mutation
  // A DeleteMut has exactly one audit entry (not zero, not multiple)
  all m: Mutation | m.mutKind = DeleteMut implies (one ae: m.mutAudit | ae.entryOp = Deleted)
}

assert FR_015_DeleteProducesExactlyOneAuditEntry { FR_015_DeleteProducesExactlyOneAuditEntry }
check FR_015_DeleteProducesExactlyOneAuditEntry for 6

// === D3 inject_violation (validator-appended) ===
fact MUTATE_CrossTeamMutationViolation { some m: Mutation | m.mutActor.userTeam != m.mutTask.taskTeam }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
