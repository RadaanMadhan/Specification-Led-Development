// === feature_model.als — Alloy 6 model for 008-task-sharing ===
// Feature: Multi-Tenant Task Management with Per-Task Sharing and Audit
// Branch:  B-L3 (008-task-sharing)
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─── Role enum ───────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// ─── Task-status enum ────────────────────────────────────────────────────────
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ─── Audit-operation enum ────────────────────────────────────────────────────
abstract sig AuditOperation {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOperation {}

// ─── Caller-to-task relationship (computed, not persisted) ───────────────────
abstract sig Relationship {}
one sig Outsider, InTeamNoRel, ShareeRel, TeamAdminRel, OwnerRel extends Relationship {}

// ─── API operation kinds ─────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchFields, PatchSharedWith, DeleteTask, GetAudit
  extends OperationKind {}

// ─── Permission matrix (singleton) ───────────────────────────────────────────
// Encodes the allow-cells from contracts/http-api.md §"Permission matrix"
one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ─── Core domain sigs ────────────────────────────────────────────────────────
sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  taskStatus: one TaskStatus,
  sharedWith: set User          // mirrors task_shares junction
}

// AuditEntry — append-only per-event record (FR-015, FR-016, FR-017)
sig AuditEntry {
  auditTask    : one Task,      // logical link (no FK cascade in SQL, but modelled here)
  auditTeam    : one Team,      // denormalised from task at write time
  auditActor   : one User,
  auditActorRole: one Role,     // snapshotted at event time
  auditOp      : one AuditOperation
}

// Mutation — represents one successful state-changing API call
// (POST, a field-changing PATCH, a share-changing PATCH, or DELETE).
// Used to drive audit-completeness and validation-before-mutation assertions.
sig Mutation {
  mutTask         : one Task,
  mutCaller       : one User,
  mutOpKind       : one OperationKind,     // the operation that mutated state
  mutAuditEntries : set AuditEntry         // the entries produced by this mutation
}

// ─── Non-empty universe ───────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Mutation
}

// ─── Permission matrix cells ──────────────────────────────────────────────────
// Source: contracts/http-api.md §"Permission matrix"
// Relationship × OperationKind → allowed (all others denied / 404)
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (InTeamNoRel  -> PostTasks)      +   // member creating a new task becomes owner
    (TeamAdminRel -> PostTasks)      +   // admin can also create tasks
    (OwnerRel     -> GetTask)        +
    (ShareeRel    -> GetTask)        +
    (TeamAdminRel -> GetTask)        +
    (OwnerRel     -> PatchFields)    +
    (ShareeRel    -> PatchFields)    +
    (TeamAdminRel -> PatchFields)    +
    (OwnerRel     -> PatchSharedWith)+   // ONLY owner; FR-010, Q1=A
    (OwnerRel     -> DeleteTask)     +
    (TeamAdminRel -> DeleteTask)     +
    (OwnerRel     -> GetAudit)       +
    (ShareeRel    -> GetAudit)       +
    (TeamAdminRel -> GetAudit)
  // Outsider, InTeamNoRel → no GetTask / Patch / Delete / GetAudit
  // ShareeRel → no PatchSharedWith (400), no DeleteTask (404 byte-equiv)
  // TeamAdminRel → no PatchSharedWith (400 — Q1=A owner-only)
}

// ─── Structural facts ─────────────────────────────────────────────────────────

// FR-002 / FR-002a: Every user belongs to exactly one team
// (one-team-per-user invariant; team_id comes from OAuth token, never payload)
fact F_OneTeamPerUser {
  all u: User | one u.userTeam
}

// FR-009: Task's team equals owner's team (denormalisation is consistent),
// and owner is a user of that same team. Both team_id and owner_id are immutable.
fact F_TaskOwnerInTaskTeam {
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

// FR-012: Every sharee on a task must be a current member of the same team
// as the task (and therefore as the owner). Cross-team sharing is forbidden.
fact F_ShareesSameTeam {
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
}

// FR-010, Q1=A: The owner of a task is NOT in the sharedWith set
// (owner has access via ownership, not via the share list).
fact F_OwnerNotInShareList {
  all t: Task | t.taskOwner not in t.sharedWith
}

// FR-016: Each audit entry's team matches the task's team (denormalisation).
fact F_AuditTeamMatchesTaskTeam {
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}

// FR-016: Actor of an audit entry must be a member of the entry's team
// (ensures entries are not cross-attributed across teams).
fact F_AuditActorInTeam {
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
}

// FR-016: The snapshotted actor_role in the audit entry matches the actor's role
// at event time. In a static model we assert the roles are consistent.
fact F_AuditActorRoleSnapshot {
  all ae: AuditEntry | ae.auditActorRole = ae.auditActor.userRole
}

// FR-015: Every mutation produces at least one audit entry, and every audit
// entry produced by a mutation is linked to the same task as the mutation.
fact F_MutationLinkedToAuditEntries {
  all m: Mutation | some m.mutAuditEntries
  all m: Mutation | all ae: m.mutAuditEntries | ae.auditTask = m.mutTask
}

// FR-015: Audit entries belong to exactly one mutation (no orphan entries,
// no entry counted for two different mutations).
fact F_AuditEntryBelongsToOneMutation {
  all ae: AuditEntry | one m: Mutation | ae in m.mutAuditEntries
}

// FR-015 + FR-016: A mutation via PostTasks must produce exactly one audit
// entry with operation = OpCreated, and the actor must be the task owner
// (the creator becomes the owner).
fact F_CreateMutationProducesCreatedEntry {
  all m: Mutation | m.mutOpKind = PostTasks implies (
    one ae: m.mutAuditEntries |
      ae.auditOp = OpCreated and ae.auditActor = m.mutTask.taskOwner
  )
}

// FR-015: A DELETE mutation produces exactly one audit entry with OpDeleted.
fact F_DeleteMutationProducesDeletedEntry {
  all m: Mutation | m.mutOpKind = DeleteTask implies (
    one ae: m.mutAuditEntries | ae.auditOp = OpDeleted
  )
}

// FR-015: A DELETE mutation produces NO OpCreated entry
// (you cannot create a task and delete it in the same logical event).
fact F_DeleteMutationNoCreatedEntry {
  all m: Mutation | m.mutOpKind = DeleteTask implies (
    no ae: m.mutAuditEntries | ae.auditOp = OpCreated
  )
}

// FR-015: PostTasks mutation produces no OpDeleted / OpEdited / OpShared /
// OpUnshared entries (creation is a single atomic event of type "created").
fact F_CreateMutationOnlyCreatedEntry {
  all m: Mutation | m.mutOpKind = PostTasks implies (
    all ae: m.mutAuditEntries | ae.auditOp = OpCreated
  )
}

// FR-017: Audit entries are immutable and append-only. We model this in a
// static snapshot by asserting that no two distinct audit entries for the
// same task share the same operation AND the same actor — i.e., there is no
// structural evidence of in-place mutation (a mutated entry would appear as
// a duplicate logical record with changed fields, which is impossible when
// each entry is a fresh append).
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// FR-006 / FR-014: Cross-team isolation — the task's team and the caller's team
// must coincide for any permitted read/write operation on that task.
// Callers from outside the task's team must be classified as Outsider and
// therefore have no allowed GET / PATCH / DELETE / GetAudit permission.
// We encode this: PatchSharedWith, GetTask, PatchFields, DeleteTask, GetAudit
// are all absent from (Outsider -> *) in the permission matrix.
fact F_OutsiderDeniedAll {
  no op: OperationKind | Outsider -> op in PermMatrix.Allowed
    and op in (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit)
}

// FR-004 / FR-006: In-team callers with no relationship to the task cannot read
// or mutate it (InTeamNoRel cannot GetTask, PatchFields, PatchSharedWith,
// DeleteTask, GetAudit).
fact F_InTeamNoRelDeniedTaskOps {
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    InTeamNoRel -> op in PermMatrix.Allowed
}

// FR-010, Q1=A: Sharee cannot change shared_with and cannot delete.
fact F_ShareeRestricted {
  ShareeRel -> PatchSharedWith not in PermMatrix.Allowed
  ShareeRel -> DeleteTask not in PermMatrix.Allowed
}

// FR-005, Q1=A: TeamAdmin cannot change shared_with (owner-only).
fact F_AdminCannotChangeSharedWith {
  TeamAdminRel -> PatchSharedWith not in PermMatrix.Allowed
}

// FR-002: Caller identity (team_id, role) comes from the token — modeled by
// requiring every mutation's caller to be a properly-resolved user (has team
// and role set), and the caller's team must match the mutated task's team
// for any non-PostTasks mutation (PostTasks creates the task in the caller's team).
fact F_CallerTeamConsistency {
  all m: Mutation | m.mutCaller.userTeam = m.mutTask.taskTeam
}

// FR-003 / FR-010: Only the task owner may mutate sharedWith.
// Encoded as: if a mutation's opKind is PatchSharedWith, the caller is the owner.
fact F_OnlyOwnerCanChangeSharedWith {
  all m: Mutation | m.mutOpKind = PatchSharedWith implies m.mutCaller = m.mutTask.taskOwner
}

// FR-003 / FR-005: Delete is only allowed for owner or team_admin.
fact F_OnlyOwnerOrAdminCanDelete {
  all m: Mutation | m.mutOpKind = DeleteTask implies (
    m.mutCaller = m.mutTask.taskOwner or m.mutCaller.userRole = TeamAdmin
  )
}

// FR-013: A PatchSharedWith mutation produces audit entries only of type
// OpShared or OpUnshared (one per affected sharee).
fact F_ShareMutationAuditOps {
  all m: Mutation | m.mutOpKind = PatchSharedWith implies (
    all ae: m.mutAuditEntries | ae.auditOp in (OpShared + OpUnshared)
  )
}

// ─── PATTERN PREDICATES ───────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §"Permission matrix"; spec.md FR-003–FR-006
pred LeastPrivilege {
  some Task
  // Outsider is denied every task-level operation
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    Outsider -> op in PermMatrix.Allowed
  // InTeamNoRel is denied every task-level operation except PostTasks
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    InTeamNoRel -> op in PermMatrix.Allowed
  // ShareeRel cannot change shares or delete
  ShareeRel -> PatchSharedWith not in PermMatrix.Allowed
  ShareeRel -> DeleteTask not in PermMatrix.Allowed
  // TeamAdminRel cannot change shares (owner-only)
  TeamAdminRel -> PatchSharedWith not in PermMatrix.Allowed
  // OwnerRel can do everything
  OwnerRel -> GetTask        in PermMatrix.Allowed
  OwnerRel -> PatchFields    in PermMatrix.Allowed
  OwnerRel -> PatchSharedWith in PermMatrix.Allowed
  OwnerRel -> DeleteTask     in PermMatrix.Allowed
  OwnerRel -> GetAudit       in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §"Permission matrix"
pred PermissionCompleteness {
  some Task
  // Every task-level operation is allowed by at least one relationship
  all op: (GetTask + PatchFields + DeleteTask + GetAudit) |
    some r: Relationship | r -> op in PermMatrix.Allowed
  // PostTasks is covered
  some r: Relationship | r -> PostTasks in PermMatrix.Allowed
  // PatchSharedWith is covered (by OwnerRel)
  some r: Relationship | r -> PatchSharedWith in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003, FR-005, FR-010; contracts/http-api.md §"Permission matrix"
pred PermissionGrounding {
  some Task
  // Every allow cell in the matrix corresponds to a documented FR.
  // OwnerRel allowed ops: FR-003 (member owns), FR-010 (share control)
  OwnerRel -> GetTask         in PermMatrix.Allowed
  OwnerRel -> PatchFields     in PermMatrix.Allowed
  OwnerRel -> PatchSharedWith in PermMatrix.Allowed
  OwnerRel -> DeleteTask      in PermMatrix.Allowed
  OwnerRel -> GetAudit        in PermMatrix.Allowed
  // ShareeRel: FR-011 (sharee view/edit/audit, no delete, no shared_with)
  ShareeRel -> GetTask     in PermMatrix.Allowed
  ShareeRel -> PatchFields in PermMatrix.Allowed
  ShareeRel -> GetAudit    in PermMatrix.Allowed
  // TeamAdminRel: FR-005 (admin view/edit/delete in own team, no shared_with)
  TeamAdminRel -> GetTask     in PermMatrix.Allowed
  TeamAdminRel -> PatchFields in PermMatrix.Allowed
  TeamAdminRel -> DeleteTask  in PermMatrix.Allowed
  TeamAdminRel -> GetAudit    in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §"Authentication"
pred AuthRequiredEverywhere {
  some Mutation
  // Every mutation has a caller who is a properly-resolved user
  // (team and role come from token — modelled by requiring non-null fields).
  all m: Mutation | one m.mutCaller
  all m: Mutation | one m.mutCaller.userTeam
  all m: Mutation | one m.mutCaller.userRole
  // Every mutation's caller belongs to the task's team
  all m: Mutation | m.mutCaller.userTeam = m.mutTask.taskTeam
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, FR-016; data-model.md AUTOINCREMENT on audit_entries
pred AuditCompleteness {
  some Mutation
  // Every mutation has at least one audit entry
  all m: Mutation | some m.mutAuditEntries
  // Every audit entry belongs to exactly one mutation
  all ae: AuditEntry | one m: Mutation | ae in m.mutAuditEntries
  // Each audit entry references the same task as the mutation
  all m: Mutation | all ae: m.mutAuditEntries | ae.auditTask = m.mutTask
  // Create mutations produce an OpCreated entry attributed to the owner
  all m: Mutation | m.mutOpKind = PostTasks implies (
    one ae: m.mutAuditEntries |
      ae.auditOp = OpCreated and ae.auditActor = m.mutTask.taskOwner
  )
  // Delete mutations produce an OpDeleted entry
  all m: Mutation | m.mutOpKind = DeleteTask implies (
    one ae: m.mutAuditEntries | ae.auditOp = OpDeleted
  )
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries are identical in every field
  // (a mutated / replaced entry would be indistinguishable from a duplicate)
  all disj ae1, ae2: AuditEntry |
    not (ae1.auditTask = ae2.auditTask
      and ae1.auditOp = ae2.auditOp
      and ae1.auditActor = ae2.auditActor
      and ae1.auditActorRole = ae2.auditActorRole
      and ae1.auditTeam = ae2.auditTeam)
  // Audit entries for a task include at most one OpCreated entry
  // (a second OpCreated would imply the first was overwritten / re-inserted)
  all t: Task | lone ae: AuditEntry | ae.auditTask = t and ae.auditOp = OpCreated
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit_entries.actor_role
pred AttributionCorrectness {
  some AuditEntry
  // Actor role snapshot matches the actor's actual role (static model)
  all ae: AuditEntry | ae.auditActorRole = ae.auditActor.userRole
  // Actor belongs to the audit entry's team
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
  // Audit team matches the task's team
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; spec.md FR-009
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner
  all t: Task | one t.taskOwner
  // Owner belongs to the task's team
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-010; contracts/http-api.md §"Permission matrix"
pred OwnershipBasedAccess {
  some Task
  // OwnerRel is the only relationship that allows PatchSharedWith
  all r: Relationship | r -> PatchSharedWith in PermMatrix.Allowed implies r = OwnerRel
  // Owner-only delete is not the full story: TeamAdmin can also delete;
  // but for PatchSharedWith, exclusively OwnerRel
  one r: Relationship | r -> PatchSharedWith in PermMatrix.Allowed
  // Every mutation that changes shared_with has the task owner as caller
  all m: Mutation | m.mutOpKind = PatchSharedWith implies m.mutCaller = m.mutTask.taskOwner
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, FR-006; contracts/http-api.md §"Byte-equivalent not-found"
pred NoInformationLeakage {
  some Task
  // Outsider is denied all task-level operations (same response as nonexistent)
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    Outsider -> op in PermMatrix.Allowed
  // InTeamNoRel is denied all task-level read/write operations
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    InTeamNoRel -> op in PermMatrix.Allowed
  // ShareeRel attempting DeleteTask is denied (byte-equiv 404 per FR-011)
  ShareeRel -> DeleteTask not in PermMatrix.Allowed
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─── FEATURE-SPECIFIC PREDICATES ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneTeamPerUser {
  some User
  all u: User | one u.userTeam
  all u: User | one u.userRole
}
assert FR_002_OneTeamPerUser { FR_002_OneTeamPerUser }
check FR_002_OneTeamPerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CrossTeamIsolation {
  some Task
  // Callers from a different team than the task must never be permitted
  // to read or write the task: Outsider covers them in the matrix.
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    Outsider -> op in PermMatrix.Allowed
  // Tasks belong to exactly one team
  all t: Task | one t.taskTeam
  // Owner is always in the task's team
  all t: Task | t.taskOwner.userTeam = t.taskTeam
  // Sharees are always in the task's team
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ImmutableOwnership {
  some Task
  // Owner is set at creation and cannot change.
  // In static model: every task has exactly one owner in its team,
  // and no mutation of kind PostTasks changes the taskOwner field after creation.
  // We express: the OpCreated entry's actor equals the task's owner.
  all t: Task | all ae: AuditEntry |
    (ae.auditTask = t and ae.auditOp = OpCreated) implies ae.auditActor = t.taskOwner
  // Owner is never a sharee of their own task
  all t: Task | t.taskOwner not in t.sharedWith
}
assert FR_009_ImmutableOwnership { FR_009_ImmutableOwnership }
check FR_009_ImmutableOwnership for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A
pred FR_010_OwnerOnlyShareControl {
  some Task
  // Only OwnerRel may exercise PatchSharedWith
  all r: Relationship | r -> PatchSharedWith in PermMatrix.Allowed iff r = OwnerRel
  // Every PatchSharedWith mutation has the task owner as caller
  all m: Mutation | m.mutOpKind = PatchSharedWith implies m.mutCaller = m.mutTask.taskOwner
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, Q3=B
pred FR_011_ShareePermissions {
  some Task
  // Sharee can GET, PATCH fields, and GET audit — but NOT delete or change shares.
  ShareeRel -> GetTask     in PermMatrix.Allowed
  ShareeRel -> PatchFields in PermMatrix.Allowed
  ShareeRel -> GetAudit    in PermMatrix.Allowed
  ShareeRel -> DeleteTask      not in PermMatrix.Allowed
  ShareeRel -> PatchSharedWith not in PermMatrix.Allowed
}
assert FR_011_ShareePermissions { FR_011_ShareePermissions }
check FR_011_ShareePermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_SameTeamSharing {
  some Task
  // All sharees are members of the same team as the task
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
  // No sharee is in a different team
  no t: Task | some s: t.sharedWith | s.userTeam != t.taskTeam
}
assert FR_012_SameTeamSharing { FR_012_SameTeamSharing }
check FR_012_SameTeamSharing for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_ShareAuditEntries {
  some Mutation
  // Every PatchSharedWith mutation produces only OpShared / OpUnshared entries
  all m: Mutation | m.mutOpKind = PatchSharedWith implies (
    all ae: m.mutAuditEntries | ae.auditOp in (OpShared + OpUnshared)
  )
  // Every PatchSharedWith mutation produces at least one such entry
  all m: Mutation | m.mutOpKind = PatchSharedWith implies some m.mutAuditEntries
}
assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalentNotFound {
  some Task
  // Outsider gets denied all task operations (same as nonexistent)
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    Outsider -> op in PermMatrix.Allowed
  // InTeamNoRel gets same response as nonexistent for task operations
  no op: (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) |
    InTeamNoRel -> op in PermMatrix.Allowed
  // Sharee attempting delete gets the same byte-equiv 404
  ShareeRel -> DeleteTask not in PermMatrix.Allowed
}
assert FR_014_ByteEquivalentNotFound { FR_014_ByteEquivalentNotFound }
check FR_014_ByteEquivalentNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_PerEventAuditEntries {
  some Mutation
  // Every mutation produces at least one audit entry
  all m: Mutation | some m.mutAuditEntries
  // Every audit entry is attributed to exactly one mutation
  all ae: AuditEntry | one m: Mutation | ae in m.mutAuditEntries
  // All audit entries from a mutation target the same task
  all m: Mutation | all ae: m.mutAuditEntries | ae.auditTask = m.mutTask
  // Create mutation → one and only one OpCreated
  all m: Mutation | m.mutOpKind = PostTasks implies (
    one ae: m.mutAuditEntries | ae.auditOp = OpCreated
  )
  // Delete mutation → one and only one OpDeleted
  all m: Mutation | m.mutOpKind = DeleteTask implies (
    one ae: m.mutAuditEntries | ae.auditOp = OpDeleted
  )
}
assert FR_015_PerEventAuditEntries { FR_015_PerEventAuditEntries }
check FR_015_PerEventAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryContents {
  some AuditEntry
  // Every entry has a role snapshot matching the actor's role
  all ae: AuditEntry | ae.auditActorRole = ae.auditActor.userRole
  // Every entry's team matches the task's team
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
  // Every entry's actor is in the entry's team
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
  // Operation is one of the five valid values (satisfied by sig hierarchy, but explicit)
  all ae: AuditEntry | ae.auditOp in
    (OpCreated + OpEdited + OpDeleted + OpShared + OpUnshared)
}
assert FR_016_AuditEntryContents { FR_016_AuditEntryContents }
check FR_016_AuditEntryContents for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditImmutableAndPersists {
  some AuditEntry
  // Immutability: no two entries for the same task are identical in all fields
  all disj ae1, ae2: AuditEntry |
    not (ae1.auditTask = ae2.auditTask
      and ae1.auditOp = ae2.auditOp
      and ae1.auditActor = ae2.auditActor
      and ae1.auditActorRole = ae2.auditActorRole
      and ae1.auditTeam = ae2.auditTeam)
  // Each task has at most one OpCreated entry (task was created once)
  all t: Task | lone ae: AuditEntry | ae.auditTask = t and ae.auditOp = OpCreated
  // OpDeleted entries are unique per task (a task can only be deleted once)
  all t: Task | lone ae: AuditEntry | ae.auditTask = t and ae.auditOp = OpDeleted
}
assert FR_017_AuditImmutableAndPersists { FR_017_AuditImmutableAndPersists }
check FR_017_AuditImmutableAndPersists for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_AuditAccessControl {
  some Task
  // Audit endpoint follows the same access rules as GetTask
  // (same callers can see audit as can see the task)
  ShareeRel    -> GetAudit in PermMatrix.Allowed
  TeamAdminRel -> GetAudit in PermMatrix.Allowed
  OwnerRel     -> GetAudit in PermMatrix.Allowed
  Outsider     -> GetAudit not in PermMatrix.Allowed
  InTeamNoRel  -> GetAudit not in PermMatrix.Allowed
  // Audit access mirrors GetTask access exactly
  { r: Relationship | r -> GetAudit in PermMatrix.Allowed } =
  { r: Relationship | r -> GetTask  in PermMatrix.Allowed }
}
assert FR_019_AuditAccessControl { FR_019_AuditAccessControl }
check FR_019_AuditAccessControl for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005, spec.md §"Team Admin Views, Edits, or Deletes"
pred FR_005_TeamAdminAccess {
  some Task
  // Admin can GET, PATCH fields, DELETE, GET audit for any task in their team
  TeamAdminRel -> GetTask     in PermMatrix.Allowed
  TeamAdminRel -> PatchFields in PermMatrix.Allowed
  TeamAdminRel -> DeleteTask  in PermMatrix.Allowed
  TeamAdminRel -> GetAudit    in PermMatrix.Allowed
  // Admin cannot change shared_with (Q1=A)
  TeamAdminRel -> PatchSharedWith not in PermMatrix.Allowed
  // Admin mutations must be by a TeamAdmin-role user
  all m: Mutation | (m.mutOpKind = DeleteTask and m.mutCaller != m.mutTask.taskOwner)
    implies m.mutCaller.userRole = TeamAdmin
}
assert FR_005_TeamAdminAccess { FR_005_TeamAdminAccess }
check FR_005_TeamAdminAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
pred FR_003_004_MemberAccessControl {
  some Task
  // Member can view/edit/delete their own tasks
  OwnerRel -> GetTask         in PermMatrix.Allowed
  OwnerRel -> PatchFields     in PermMatrix.Allowed
  OwnerRel -> PatchSharedWith in PermMatrix.Allowed
  OwnerRel -> DeleteTask      in PermMatrix.Allowed
  // Member cannot see tasks they don't own / are not shared on
  InTeamNoRel -> GetTask  not in PermMatrix.Allowed
  InTeamNoRel -> DeleteTask not in PermMatrix.Allowed
  // Sharee can view and edit (but not delete)
  ShareeRel -> GetTask     in PermMatrix.Allowed
  ShareeRel -> PatchFields in PermMatrix.Allowed
  ShareeRel -> DeleteTask not in PermMatrix.Allowed
}
assert FR_003_004_MemberAccessControl { FR_003_004_MemberAccessControl }
check FR_003_004_MemberAccessControl for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md §"Concurrent edits on the same task"; data-model.md
pred FR_001_AuthRequired {
  some Mutation
  // Every mutation has exactly one caller with resolved team and role
  all m: Mutation | one m.mutCaller
  all m: Mutation | one m.mutCaller.userTeam
  all m: Mutation | one m.mutCaller.userRole
  // Caller always belongs to the mutated task's team
  all m: Mutation | m.mutCaller.userTeam = m.mutTask.taskTeam
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.auditTask = ae2.auditTask and ae1.auditOp = ae2.auditOp and ae1.auditActor = ae2.auditActor and ae1.auditActorRole = ae2.auditActorRole and ae1.auditTeam = ae2.auditTeam }
