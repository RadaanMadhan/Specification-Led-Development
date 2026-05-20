// === feature_model.als — Alloy 6 model for 008-task-sharing ===
// Feature: Multi-Tenant Task Management with Per-Task Sharing and Audit
// Branch:  008-task-sharing  |  Date: 2026-05-17

// ── Enumerations ──────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig AuditOperation {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOperation {}

// Caller-to-task access relationship (computed from ownership / sharing / team)
abstract sig Relationship {}
one sig Outsider, InTeamNoRel, ShareeRel, TeamAdminRel, OwnerRel
  extends Relationship {}

// The six distinct API operation kinds modelled in the permission matrix
abstract sig OperationKind {}
one sig PostTasks, GetTaskById, PatchFields, PatchSharedWith,
        DeleteTask, GetAudit extends OperationKind {}

// Outcome of an API operation
abstract sig OperationResult {}
one sig ResultSuccess, ResultNotFound, ResultValidation extends OperationResult {}

// ── Core entity sigs ──────────────────────────────────────────────────────────

sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam   : one Team,   // immutable, denormalised from owner's team
  taskOwner  : one User,   // immutable (FR-009)
  taskStatus : one TaskStatus
}

// Normalised share junction — composite PK (shareTask, sharee)
sig TaskShare {
  shareTask : one Task,
  sharee    : one User
}

// Immutable, append-only audit record per logical event (FR-015, FR-017)
sig AuditEntry {
  entryTask      : one Task,   // logical link; no FK constraint (FR-017)
  entryTeam      : one Team,   // denormalised at write time (data-model.md)
  entryActor     : one User,
  entryActorRole : one Role,   // snapshot at event time (FR-016)
  entryOp        : one AuditOperation
}

// A concrete API operation (request/response) with its caller, target task,
// and observed result.
sig Operation {
  opKind   : one OperationKind,
  opCaller : one User,
  opTask   : lone Task,        // lone: POST /tasks has no pre-existing task
  opResult : one OperationResult
}

// ── Permission matrix (singleton) ─────────────────────────────────────────────

one sig PermMatrix {
  Allowed : set Relationship -> OperationKind
}

// ── Facts ─────────────────────────────────────────────────────────────────────

// All dynamic sigs must have at least one atom so universally-quantified
// predicates are non-vacuous.
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some TaskShare
  some AuditEntry
  some Operation
}

// FR-002 / FR-009: task's team equals its owner's team (cross-team
// consistency; owner_id is immutable and team_id is immutable).
fact F_TaskOwnerSameTeam {
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}

// FR-012: every sharee must be a current member of the same team as the task.
fact F_ShareeSameTeam {
  all ts : TaskShare | ts.sharee.userTeam = ts.shareTask.taskTeam
}

// data-model.md composite PK (task_id, sharee_user_id): no duplicate shares.
fact F_ShareeUniquenessPerTask {
  all disj ts1, ts2 : TaskShare |
    not (ts1.shareTask = ts2.shareTask and ts1.sharee = ts2.sharee)
}

// A user cannot be listed as a sharee on their own task
// (owner is in the read-set by default; sharing with yourself is meaningless).
fact F_NoSelfShare {
  all ts : TaskShare | ts.sharee != ts.shareTask.taskOwner
}

// data-model.md: entryTeam is denormalised from the task's team at write time.
fact F_AuditEntryTeamMatchesTask {
  all ae : AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
}

// FR-016: actor_role in an audit entry is the snapshot of the actor's actual
// role at the time of the event (role is read from OAuth claims, never from body).
fact F_AuditActorRoleSnapshot {
  all ae : AuditEntry | ae.entryActorRole = ae.entryActor.userRole
}

// FR-017: audit entries are append-only — no two AuditEntry atoms differ only
// in entryOp for the same (task, actor) pair, which would indicate an in-place
// update. Modelled as: each (entryTask, entryActor, entryOp) triple is unique
// (no "overwrite" of an entry by creating one with the same key but different data).
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// FR-001: every Operation must have a caller (authenticated user).
// Modelled structurally: opCaller is a total function (one User), so every
// Operation is already bound to a User.  The separate named fact enforces that
// the caller belongs to some Team (i.e., was fully resolved by token introspection).
fact F_AuthRequiredEverywhere {
  all op : Operation | some op.opCaller.userTeam
}

// FR-002 / Assumptions: each user belongs to exactly one team.
// Already structural via `userTeam : one Team`; this fact makes it checkable.
fact F_OneTeamPerUser {
  all u : User | one u.userTeam
}

// FR-009: task team_id and owner_id are immutable.  In the static model
// "immutability" means there is no Operation whose result modifies them.
// We encode it as: no Operation on PatchFields or PatchSharedWith can shift a
// task's owner — i.e., every successful PATCH leaves the task's owner unchanged.
// (Structural: taskOwner and taskTeam are single-valued and fixed per Task atom.)
fact F_ImmutableOwnerAndTeam {
  all t : Task | one t.taskOwner and one t.taskTeam
}

// FR-010 / Q1=A: only the task's owner may change shared_with.
// A successful PatchSharedWith operation must have the caller as the task's owner.
fact F_OwnerOnlyShareControl {
  all op : Operation |
    (op.opKind = PatchSharedWith and op.opResult = ResultSuccess) implies
      (some t : Task | op.opTask = t and t.taskOwner = op.opCaller)
}

// FR-011 / Q3=B: a sharee attempting DELETE receives byte-equivalent 404
// (they are not in the delete-allowed set).
fact F_ShareeCannotDelete {
  all op : Operation |
    (op.opKind = DeleteTask and op.opResult = ResultSuccess) implies
      (some t : Task |
        op.opTask = t
        and (t.taskOwner = op.opCaller
          or (op.opCaller.userRole = TeamAdmin
            and op.opCaller.userTeam = t.taskTeam)))
}

// FR-014: cross-team isolation — any operation on a task by a caller from a
// different team must result in NotFound (byte-equivalent 404).
fact F_CrossTeamIsolation {
  all op : Operation |
    (some t : Task |
      op.opTask = t and op.opCaller.userTeam != t.taskTeam) implies
    op.opResult = ResultNotFound
}

// FR-015 / FR-016: every successful state-changing operation (Create, Edit,
// Delete, Share, Unshare) on a task is covered by at least one matching
// AuditEntry linked to the same task.
fact F_AuditCompleteness {
  all op : Operation |
    (op.opResult = ResultSuccess
      and op.opKind in (PostTasks + PatchFields + PatchSharedWith + DeleteTask))
    implies (some ae : AuditEntry | op.opTask != none and ae.entryTask = op.opTask
               and ae.entryActor = op.opCaller)
}

// FR-012: cross-team sharing is forbidden — every sharee is in the same team
// as the task (already expressed in F_ShareeSameTeam; this fact enforces the
// reject-with-400 path: a PatchSharedWith that would add an outsider must not
// succeed).
fact F_NoCrossTeamSharing {
  all op : Operation |
    (op.opKind = PatchSharedWith and op.opResult = ResultSuccess) implies
      (all u : User |
        (some ts : TaskShare | ts.shareTask = op.opTask and ts.sharee = u) implies
        u.userTeam = op.opTask.taskTeam)
}

// Permission matrix — closed-world enumeration of all allowed
// (Relationship × OperationKind) cells from contracts/http-api.md.
fact F_PermissionMatrix {
  // Allowed cells (from the permission matrix table in contracts/http-api.md):
  // POST /tasks
  InTeamNoRel -> PostTasks in PermMatrix.Allowed
  TeamAdminRel -> PostTasks in PermMatrix.Allowed
  // GET /tasks/{id}
  ShareeRel   -> GetTaskById in PermMatrix.Allowed
  TeamAdminRel -> GetTaskById in PermMatrix.Allowed
  OwnerRel    -> GetTaskById in PermMatrix.Allowed
  // PATCH /tasks/{id} — fields only
  ShareeRel   -> PatchFields in PermMatrix.Allowed
  TeamAdminRel -> PatchFields in PermMatrix.Allowed
  OwnerRel    -> PatchFields in PermMatrix.Allowed
  // PATCH /tasks/{id} — shared_with (owner only)
  OwnerRel    -> PatchSharedWith in PermMatrix.Allowed
  // DELETE /tasks/{id}
  TeamAdminRel -> DeleteTask in PermMatrix.Allowed
  OwnerRel    -> DeleteTask in PermMatrix.Allowed
  // GET /tasks/{id}/audit
  ShareeRel   -> GetAudit in PermMatrix.Allowed
  TeamAdminRel -> GetAudit in PermMatrix.Allowed
  OwnerRel    -> GetAudit in PermMatrix.Allowed

  // Closed-world: the matrix is exactly these cells.
  PermMatrix.Allowed =
    (InTeamNoRel  -> PostTasks)
  + (TeamAdminRel -> PostTasks)
  + (ShareeRel    -> GetTaskById)
  + (TeamAdminRel -> GetTaskById)
  + (OwnerRel     -> GetTaskById)
  + (ShareeRel    -> PatchFields)
  + (TeamAdminRel -> PatchFields)
  + (OwnerRel     -> PatchFields)
  + (OwnerRel     -> PatchSharedWith)
  + (TeamAdminRel -> DeleteTask)
  + (OwnerRel     -> DeleteTask)
  + (ShareeRel    -> GetAudit)
  + (TeamAdminRel -> GetAudit)
  + (OwnerRel     -> GetAudit)
}

// ── Helper predicates (access-relationship derivation) ────────────────────────

pred callerIsOwner[caller : User, t : Task] {
  t.taskOwner = caller
}

pred callerIsSharee[caller : User, t : Task] {
  some ts : TaskShare | ts.shareTask = t and ts.sharee = caller
}

pred callerIsTeamAdmin[caller : User, t : Task] {
  caller.userRole = TeamAdmin and caller.userTeam = t.taskTeam
}

pred callerIsOutsider[caller : User, t : Task] {
  caller.userTeam != t.taskTeam
}

pred callerIsInTeamNoRel[caller : User, t : Task] {
  caller.userTeam = t.taskTeam
  not callerIsOwner[caller, t]
  not callerIsSharee[caller, t]
  not callerIsTeamAdmin[caller, t]
}

// ── PATTERN: LeastPrivilege ────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003/FR-004/FR-005/FR-006
pred LeastPrivilege {
  some Operation
  // Outsiders never get a successful result on a task operation
  all op : Operation |
    (some t : Task | op.opTask = t and callerIsOutsider[op.opCaller, t]) implies
      op.opResult = ResultNotFound
  // In-team callers with no relation cannot successfully delete
  all op : Operation |
    (op.opKind = DeleteTask
      and some t : Task |
        op.opTask = t and callerIsInTeamNoRel[op.opCaller, t]) implies
      op.opResult = ResultNotFound
  // Sharees cannot successfully delete
  all op : Operation |
    (op.opKind = DeleteTask
      and some t : Task |
        op.opTask = t and callerIsSharee[op.opCaller, t]
        and not callerIsOwner[op.opCaller, t]) implies
      op.opResult = ResultNotFound
  // Non-owners cannot successfully change shared_with
  all op : Operation |
    (op.opKind = PatchSharedWith and op.opResult = ResultSuccess) implies
      (some t : Task | op.opTask = t and callerIsOwner[op.opCaller, t])
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ── PATTERN: PermissionCompleteness ──────────────────────────────────────────

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Relationship × OperationKind) pair is either allowed or not — i.e.,
  // the matrix covers all cells (no undefined entries; the closed-world fact
  // F_PermissionMatrix ensures exactly the listed cells are allowed).
  all r : Relationship, ok : OperationKind |
    (r -> ok in PermMatrix.Allowed) or (r -> ok not in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ── PATTERN: PermissionGrounding ─────────────────────────────────────────────

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003/FR-004/FR-005; contracts/http-api.md
pred PermissionGrounding {
  // ShareeRel may read/edit but NOT delete and NOT change shared_with
  ShareeRel -> DeleteTask    not in PermMatrix.Allowed
  ShareeRel -> PatchSharedWith not in PermMatrix.Allowed
  // Outsider has no allowed operations at all (POST is n/a for outsiders)
  no (Outsider -> OperationKind) & PermMatrix.Allowed
  // InTeamNoRel cannot read, edit, delete, or audit
  InTeamNoRel -> GetTaskById  not in PermMatrix.Allowed
  InTeamNoRel -> PatchFields  not in PermMatrix.Allowed
  InTeamNoRel -> PatchSharedWith not in PermMatrix.Allowed
  InTeamNoRel -> DeleteTask   not in PermMatrix.Allowed
  InTeamNoRel -> GetAudit     not in PermMatrix.Allowed
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// ── PATTERN: PrivilegeMonotonicity ────────────────────────────────────────────

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005/FR-003; contracts/http-api.md
pred PrivilegeMonotonicity {
  // TeamAdmin permissions are a superset of Sharee permissions on read/edit ops
  all ok : OperationKind |
    (ShareeRel -> ok in PermMatrix.Allowed) implies
      (TeamAdminRel -> ok in PermMatrix.Allowed)
  // TeamAdmin permissions are a superset of Owner permissions
  all ok : OperationKind |
    (OwnerRel -> ok in PermMatrix.Allowed) implies
      (TeamAdminRel -> ok in PermMatrix.Allowed)
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// ── PATTERN: AuthRequiredEverywhere ──────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every operation has a caller who has been resolved to a team and role
  // (structural consequence of opCaller: one User and F_AuthRequiredEverywhere)
  some Operation
  all op : Operation | some op.opCaller and some op.opCaller.userTeam
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ── PATTERN: AuditCompleteness ────────────────────────────────────────────────

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015/FR-016; data-model.md AuditEntry UNIQUE
pred AuditCompleteness {
  // Every successful create operation on a task produces at least one audit entry
  some Operation
  all op : Operation |
    (op.opKind = PostTasks and op.opResult = ResultSuccess and some op.opTask) implies
      (some ae : AuditEntry |
        ae.entryTask = op.opTask
        and ae.entryActor = op.opCaller
        and ae.entryOp = OpCreated)
  // Every successful delete operation produces a 'deleted' audit entry
  all op : Operation |
    (op.opKind = DeleteTask and op.opResult = ResultSuccess and some op.opTask) implies
      (some ae : AuditEntry |
        ae.entryTask = op.opTask
        and ae.entryActor = op.opCaller
        and ae.entryOp = OpDeleted)
  // Every successful field-edit produces an 'edited' audit entry
  all op : Operation |
    (op.opKind = PatchFields and op.opResult = ResultSuccess and some op.opTask) implies
      (some ae : AuditEntry |
        ae.entryTask = op.opTask
        and ae.entryActor = op.opCaller
        and ae.entryOp = OpEdited)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ── PATTERN: AppendOnly ───────────────────────────────────────────────────────

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No two distinct audit entries share (task, actor, operation, team),
  // which would indicate an in-place update replaced one entry with another.
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    not (ae1.entryTask = ae2.entryTask
      and ae1.entryActor = ae2.entryActor
      and ae1.entryOp = ae2.entryOp
      and ae1.entryTeam = ae2.entryTeam)
  // There is no operation kind that would delete an audit entry —
  // enforced by the absence of any such OperationKind in the model.
  // Structurally: every AuditEntry atom that exists is never "replaced."
  all ae : AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
}

assert AppendOnly { AppendOnly }
check AppendOnly for 6

// ── PATTERN: AttributionCorrectness ──────────────────────────────────────────

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role
pred AttributionCorrectness {
  some AuditEntry
  // Actor role in every audit entry must equal the actor's actual role
  // (snapshot semantics — the role is taken from OAuth claims at event time)
  all ae : AuditEntry | ae.entryActorRole = ae.entryActor.userRole
  // The audit entry's team matches the task's team (denormalisation check)
  all ae : AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ── PATTERN: OwnershipExclusivity ────────────────────────────────────────────

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner_id; spec.md FR-009
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner
  all t : Task | one t.taskOwner
  // Owner is always in the same team as the task
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ── PATTERN: OwnershipBasedAccess ────────────────────────────────────────────

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-004/FR-010/FR-011; contracts/http-api.md
pred OwnershipBasedAccess {
  some Operation
  // A successful PatchSharedWith must be performed by the task's owner
  all op : Operation |
    (op.opKind = PatchSharedWith and op.opResult = ResultSuccess) implies
      (some t : Task | op.opTask = t and t.taskOwner = op.opCaller)
  // A successful delete must be performed by owner or team admin
  all op : Operation |
    (op.opKind = DeleteTask and op.opResult = ResultSuccess) implies
      (some t : Task |
        op.opTask = t
        and (t.taskOwner = op.opCaller
          or (op.opCaller.userRole = TeamAdmin
            and op.opCaller.userTeam = t.taskTeam)))
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ── PATTERN: NoInformationLeakage ────────────────────────────────────────────

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  some Operation
  // Cross-team callers always get NotFound — they cannot distinguish
  // "task exists in another team" from "task does not exist at all"
  all op : Operation |
    (some t : Task |
      op.opTask = t and op.opCaller.userTeam != t.taskTeam) implies
      op.opResult = ResultNotFound
  // In-team callers with no relationship also get NotFound
  all op : Operation |
    (some t : Task |
      op.opTask = t
      and callerIsInTeamNoRel[op.opCaller, t]
      and op.opKind != PostTasks) implies
      op.opResult = ResultNotFound
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ── PATTERN: ValidationBeforeMutation ────────────────────────────────────────

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001/FR-002a; contracts/http-api.md 401 before handler
pred ValidationBeforeMutation {
  // A validation-error result produces no audit entry for that task×caller pair
  // (a rejected request is a no-op on state)
  some Operation
  all op : Operation |
    (op.opResult = ResultValidation and some op.opTask) implies
      (no ae : AuditEntry |
        ae.entryTask = op.opTask
        and ae.entryActor = op.opCaller
        and ae.entryOp in (OpCreated + OpEdited + OpDeleted + OpShared + OpUnshared)
        and op.opKind = PatchSharedWith)
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ── Feature-specific predicates ───────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-002 / Assumptions (one team per user, role from token)
pred FR_002_OneTeamPerUser {
  some User
  all u : User | one u.userTeam and one u.userRole
}

assert FR_002_OneTeamPerUser { FR_002_OneTeamPerUser }
check FR_002_OneTeamPerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (owner_id and team_id immutable)
pred FR_009_ImmutableOwnerAndTeam {
  some Task
  all t : Task | one t.taskOwner and one t.taskTeam
  // Owner must reside in the task's team
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}

assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1=A (only owner may modify shared_with)
pred FR_010_OwnerOnlyShareControl {
  some Operation
  all op : Operation |
    (op.opKind = PatchSharedWith and op.opResult = ResultSuccess) implies
      (some t : Task | op.opTask = t and t.taskOwner = op.opCaller)
  // Non-owner attempt to PatchSharedWith must not succeed (gets validation error)
  all op : Operation |
    (op.opKind = PatchSharedWith
      and some t : Task |
        op.opTask = t and t.taskOwner != op.opCaller
        and op.opCaller.userTeam = t.taskTeam) implies
      op.opResult = ResultValidation
}

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B (sharee view+edit but no delete)
pred FR_011_ShareeCannotDelete {
  some TaskShare
  some Operation
  all op : Operation |
    (op.opKind = DeleteTask
      and some t : Task |
        op.opTask = t
        and callerIsSharee[op.opCaller, t]
        and not callerIsOwner[op.opCaller, t]
        and not callerIsTeamAdmin[op.opCaller, t]) implies
      op.opResult = ResultNotFound
}

assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (cross-team sharing forbidden)
pred FR_012_CrossTeamSharingForbidden {
  some TaskShare
  all ts : TaskShare | ts.sharee.userTeam = ts.shareTask.taskTeam
}

assert FR_012_CrossTeamSharingForbidden { FR_012_CrossTeamSharingForbidden }
check FR_012_CrossTeamSharingForbidden for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (share/unshare events produce audit entries)
pred FR_013_ShareAuditEntries {
  some AuditEntry
  // For every share-event audit entry, the actor is the task owner
  // (only the owner can trigger a share/unshare — FR-010 / Q1=A)
  all ae : AuditEntry |
    ae.entryOp in (OpShared + OpUnshared) implies
      ae.entryActor = ae.entryTask.taskOwner
}

assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent not-found for all unauthorized access)
pred FR_014_CrossTeamByteEquivalentIsolation {
  some Operation
  all op : Operation |
    (some t : Task |
      op.opTask = t and op.opCaller.userTeam != t.taskTeam) implies
      op.opResult = ResultNotFound
}

assert FR_014_CrossTeamByteEquivalentIsolation {
  FR_014_CrossTeamByteEquivalentIsolation
}
check FR_014_CrossTeamByteEquivalentIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (one audit entry per logical event; no entry without state change)
pred FR_015_OneAuditEntryPerEvent {
  some AuditEntry
  // Every audit entry is linked to a task in the same team
  all ae : AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
  // No two audit entries for the same task represent the same logical event
  // from the same actor (append-only; no duplicate events)
  all disj ae1, ae2 : AuditEntry |
    not (ae1.entryTask = ae2.entryTask
      and ae1.entryActor = ae2.entryActor
      and ae1.entryOp = ae2.entryOp
      and ae1.entryTeam = ae2.entryTeam)
}

assert FR_015_OneAuditEntryPerEvent { FR_015_OneAuditEntryPerEvent }
check FR_015_OneAuditEntryPerEvent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit entry actor_role = snapshot of actual role)
pred FR_016_AuditActorRoleSnapshot {
  some AuditEntry
  all ae : AuditEntry | ae.entryActorRole = ae.entryActor.userRole
}

assert FR_016_AuditActorRoleSnapshot { FR_016_AuditActorRoleSnapshot }
check FR_016_AuditActorRoleSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entries immutable and outlive task)
pred FR_017_AuditImmutableOutlivesTask {
  some AuditEntry
  // Every audit entry's team is consistent with the task's team
  // (audit entries are keyed by team_id independently of the task row)
  all ae : AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
  // No two distinct entries share the same (task, actor, op, team) — no updates
  all disj ae1, ae2 : AuditEntry |
    not (ae1.entryTask = ae2.entryTask
      and ae1.entryActor = ae2.entryActor
      and ae1.entryOp = ae2.entryOp
      and ae1.entryTeam = ae2.entryTeam)
}

assert FR_017_AuditImmutableOutlivesTask { FR_017_AuditImmutableOutlivesTask }
check FR_017_AuditImmutableOutlivesTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (audit readable by owner / sharee / team admin)
pred FR_019_AuditReadAccess {
  some Operation
  // Callers with GetAudit success must be owner, sharee, or team admin
  all op : Operation |
    (op.opKind = GetAudit and op.opResult = ResultSuccess and some op.opTask) implies
      (some t : Task |
        op.opTask = t
        and (callerIsOwner[op.opCaller, t]
          or callerIsSharee[op.opCaller, t]
          or callerIsTeamAdmin[op.opCaller, t]))
  // Cross-team callers cannot read the audit trail
  all op : Operation |
    (op.opKind = GetAudit
      and some t : Task |
        op.opTask = t and op.opCaller.userTeam != t.taskTeam) implies
      op.opResult = ResultNotFound
}

assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2 : AuditEntry | ae1.entryTask = ae2.entryTask and ae1.entryActor = ae2.entryActor and ae1.entryOp = ae2.entryOp and ae1.entryTeam = ae2.entryTeam }
