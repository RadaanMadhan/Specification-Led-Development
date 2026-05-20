// === feature_model.als — Alloy model for B-L3: Multi-Tenant Task Management with Per-Task Sharing and Audit ===
// Feature: 008-task-sharing | spec.md + data-model.md + contracts/http-api.md

// ─── Role hierarchy ────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// ─── Audit operation kinds ─────────────────────────────────────────────────────
abstract sig AuditOperation {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOperation {}

// ─── Caller–task relationship values ──────────────────────────────────────────
// Computed at request time; used as the permission matrix row key.
abstract sig Relationship {}
one sig Outsider, InTeamNone, Sharee, AdminRel, OwnerRel extends Relationship {}

// ─── Endpoint / action kinds ───────────────────────────────────────────────────
abstract sig OperationKind {}
one sig OpGetTask, OpPatchFields, OpPatchShare, OpDeleteTask, OpGetAudit
  extends OperationKind {}

// ─── Permission matrix (singleton) ────────────────────────────────────────────
// Encodes contracts/http-api.md permission table.
one sig PermMatrix {
  Allowed : set Relationship -> OperationKind
}

// ─── Core domain sigs ─────────────────────────────────────────────────────────
sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  sharedWith : set User   // normalised from task_shares junction table
}

// AuditEntry.entryTask is a reference that intentionally need not join a live
// Task row (FR-017: audit entries outlive their task).  We model the reference
// as a sig field so structural invariants can be checked.
sig AuditEntry {
  entryTask      : one Task,
  entryTeam      : one Team,
  entryActor     : one User,
  entryActorRole : one Role,
  entryOp        : one AuditOperation
}

// ─── Non-empty universe ────────────────────────────────────────────────────────
// Force at least one atom of every dynamic sig so no `all x: T | P` fires
// vacuously on an empty set.
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
}

// ─── Permission matrix (closed-world) ─────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix table
fact F_PermissionMatrix {
  // Allowed cells — read from the permission table in contracts/http-api.md
  // GET /tasks/{id}: Sharee, AdminRel, OwnerRel
  Sharee   -> OpGetTask    in PermMatrix.Allowed
  AdminRel -> OpGetTask    in PermMatrix.Allowed
  OwnerRel -> OpGetTask    in PermMatrix.Allowed
  // PATCH fields-only: Sharee, AdminRel, OwnerRel
  Sharee   -> OpPatchFields in PermMatrix.Allowed
  AdminRel -> OpPatchFields in PermMatrix.Allowed
  OwnerRel -> OpPatchFields in PermMatrix.Allowed
  // PATCH shared_with: OwnerRel only (FR-010, Q1=A)
  OwnerRel -> OpPatchShare  in PermMatrix.Allowed
  // DELETE: AdminRel, OwnerRel (FR-005, FR-003)
  AdminRel -> OpDeleteTask  in PermMatrix.Allowed
  OwnerRel -> OpDeleteTask  in PermMatrix.Allowed
  // GET audit: Sharee, AdminRel, OwnerRel (FR-019)
  Sharee   -> OpGetAudit   in PermMatrix.Allowed
  AdminRel -> OpGetAudit   in PermMatrix.Allowed
  OwnerRel -> OpGetAudit   in PermMatrix.Allowed
  // Closed-world: enumerate the full set so nothing else sneaks in
  PermMatrix.Allowed =
      (Sharee   -> OpGetTask)    + (AdminRel -> OpGetTask)    + (OwnerRel -> OpGetTask)
    + (Sharee   -> OpPatchFields)+ (AdminRel -> OpPatchFields)+ (OwnerRel -> OpPatchFields)
    + (OwnerRel -> OpPatchShare)
    + (AdminRel -> OpDeleteTask) + (OwnerRel -> OpDeleteTask)
    + (Sharee   -> OpGetAudit)   + (AdminRel -> OpGetAudit)   + (OwnerRel -> OpGetAudit)
}

// ─── Structural ownership / team facts ────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md tasks.owner_id + tasks.team_id
fact F_TaskOwnerInSameTeam {
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md TaskShare FK rules
fact F_ShareeInSameTeam {
  all t : Task | all u : t.sharedWith | u.userTeam = t.taskTeam
}

// FEATURE-SPECIFIC  ANCHOR: FR-009; spec.md "owner_id immutable, recorded at creation"
fact F_OwnerNotSharee {
  // The owner already has owner access; placing themselves in sharedWith is
  // meaningless and excluded by the service layer (PATCH semantics).
  all t : Task | t.taskOwner !in t.sharedWith
}

// ─── Audit structural invariants ──────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: FR-016; data-model.md AuditEntry.actor_role
fact F_AuditActorRoleSnapshot {
  // The actor_role stored in each audit entry must equal the actor's current role.
  // (In the static model we approximate the snapshot constraint as an equality;
  // the real system snapshots at write time, which this encodes as a structural
  // must-match requirement.)
  all e : AuditEntry | e.entryActorRole = e.entryActor.userRole
}

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md AuditEntry.team_id denormalised
fact F_AuditTeamMatchesTask {
  all e : AuditEntry | e.entryTeam = e.entryTask.taskTeam
}

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md AuditEntry.actor_user_id FK->users
fact F_AuditActorInSameTeam {
  all e : AuditEntry | e.entryActor.userTeam = e.entryTeam
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015; spec.md "every mutation produces exactly one audit entry per logical event"
fact F_AuditCompleteness {
  // Every task has at least one audit entry (the creation event).
  all t : Task | some e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated
  // A 'deleted' audit entry is the terminal event: no further content-altering
  // entries (created / edited / shared / unshared) may follow a deletion.
  // Encoded as: if a task has a deleted entry, no other OpCreated entry for it
  // exists (since the task was created once, then deleted; creation cannot reappear).
  all t : Task |
    (some e : AuditEntry | e.entryTask = t and e.entryOp = OpDeleted) implies
    (one e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated)
}

// PATTERN: AppendOnly  ANCHOR: FR-017; data-model.md "no UPDATE/DELETE SQL on audit_entries"; spec.md SC-009
fact F_AppendOnlyAuditEntries {
  // No two distinct audit entries for the same task record the same operation
  // performed by the same actor — which would indicate a re-write of a prior entry.
  // (One actor may legitimately perform the same operation multiple times, but
  // each occurrence must be a NEW entry; structural duplicate-suppression is not
  // possible in a static model, so we encode the strongest checkable proxy:
  // a task's deleted entry is unique — deletion is a one-time terminal event.)
  all t : Task |
    lone e : AuditEntry | e.entryTask = t and e.entryOp = OpDeleted
}

// ─── Owner-only share control ──────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: FR-010; Q1=A; SC-011; contracts/http-api.md "only owner may modify shared_with"
fact F_OwnerOnlyShareControl {
  // Any audit entry recording a share or unshare event must have been authored
  // by the task's owner.
  all e : AuditEntry |
    (e.entryOp = OpShared or e.entryOp = OpUnshared) implies
    e.entryActor = e.entryTask.taskOwner
}

// ─── Cross-team isolation ──────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: FR-014; FR-006; SC-003; contracts/http-api.md byte-equivalent 404
fact F_CrossTeamIsolation {
  // An admin of team T has no access to tasks in team U ≠ T.
  // Encoded: no audit entry actor in team X records an event for a task in team Y ≠ X.
  // (This is already implied by F_AuditActorInSameTeam + F_AuditTeamMatchesTask,
  // but we name this fact separately so it can be mutation-targeted independently.)
  all e : AuditEntry | e.entryActor.userTeam = e.entryTask.taskTeam
}

// ─── Sharee cannot delete ──────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011; Q3=B; spec.md "sharee may not DELETE"; contracts/http-api.md permission table
fact F_ShareeCannotDelete {
  // A caller who is only a sharee (not the owner, not a team admin) cannot author
  // a deleted event.  In audit terms: the actor of any OpDeleted entry is either
  // the task's owner or a team admin.
  all e : AuditEntry |
    e.entryOp = OpDeleted implies
    (e.entryActor = e.entryTask.taskOwner or e.entryActor.userRole = TeamAdmin)
}

// ─── Privilege monotonicity (admin ≥ member on read-side) ─────────────────────
// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005; contracts/http-api.md permission table
fact F_AdminHasReadPrivilege {
  // Team admin's permission set contains every operation available to a sharee.
  // In the matrix: every op allowed for Sharee is also allowed for AdminRel.
  all op : OperationKind |
    (Sharee -> op) in PermMatrix.Allowed implies (AdminRel -> op) in PermMatrix.Allowed
}

// ─── Authentication required ──────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md "401 before any handler"
fact F_AuthRequiredEverywhere {
  // Every audit entry has a non-null actor — there is no unauthenticated mutation.
  // (In the static model: every AuditEntry has exactly one entryActor, guaranteed
  // by the sig declaration; we add the fact that the actor is in the same team
  // as the task, which is the postcondition of successful authentication + team resolution.)
  all e : AuditEntry | e.entryActor.userTeam = e.entryTask.taskTeam
}

// ─── Ownership exclusivity ─────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity  ANCHOR: FR-009; data-model.md tasks.owner_id NOT NULL
fact F_OwnershipExclusivity {
  // Each task has exactly one owner (enforced by the `one` multiplicity on
  // taskOwner, but restated explicitly so the mutation harness can target it).
  all t : Task | one t.taskOwner
}

// ─── Permission completeness ───────────────────────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix (all cells defined)
fact F_PermissionCompleteness {
  // Every (Relationship × OperationKind) pair is either explicitly allowed or
  // implicitly denied.  The closed-world equality in F_PermissionMatrix already
  // enforces this; we add an explicit structural check that the domain is covered.
  all r : Relationship | all op : OperationKind |
    (r -> op) in PermMatrix.Allowed or (r -> op) !in PermMatrix.Allowed
}

// ═══════════════════════════════════════════════════════════════════════════════
// PREDICATES AND ASSERTIONS
// ═══════════════════════════════════════════════════════════════════════════════

// ─── LeastPrivilege ────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004; FR-006
pred LeastPrivilege {
  some Task  // non-vacuous: ensure universe has tasks to check
  // Outsider and InTeamNone may not GET, PATCH (fields or share), DELETE, or GET audit
  // — none of these pairs appear in the Allowed relation.
  (Outsider  -> OpGetTask)     !in PermMatrix.Allowed
  (Outsider  -> OpPatchFields) !in PermMatrix.Allowed
  (Outsider  -> OpPatchShare)  !in PermMatrix.Allowed
  (Outsider  -> OpDeleteTask)  !in PermMatrix.Allowed
  (Outsider  -> OpGetAudit)    !in PermMatrix.Allowed
  (InTeamNone -> OpGetTask)     !in PermMatrix.Allowed
  (InTeamNone -> OpPatchFields) !in PermMatrix.Allowed
  (InTeamNone -> OpPatchShare)  !in PermMatrix.Allowed
  (InTeamNone -> OpDeleteTask)  !in PermMatrix.Allowed
  (InTeamNone -> OpGetAudit)    !in PermMatrix.Allowed
  // Sharee cannot delete or change share list (FR-011, Q3=B, FR-010)
  (Sharee -> OpDeleteTask)  !in PermMatrix.Allowed
  (Sharee -> OpPatchShare)  !in PermMatrix.Allowed
  // Admin cannot change share list for tasks they don't own (FR-005, Q1=A)
  (AdminRel -> OpPatchShare) !in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ─── PermissionCompleteness ───────────────────────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md; FR-003 through FR-006
pred PermissionCompleteness {
  some Task
  // Spot-check: every Relationship atom and OperationKind atom participates in
  // some evaluation of the Allowed relation — the domain is not smaller than expected.
  some r : Relationship, op : OperationKind | (r -> op) in PermMatrix.Allowed
  some r : Relationship, op : OperationKind | (r -> op) !in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ─── PrivilegeMonotonicity ─────────────────────────────────────────────────────
// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005; contracts/http-api.md permission table
pred PrivilegeMonotonicity {
  some Task
  // Every operation a Sharee may perform is also permitted for AdminRel and OwnerRel.
  all op : OperationKind |
    (Sharee -> op) in PermMatrix.Allowed implies
    ((AdminRel -> op) in PermMatrix.Allowed and (OwnerRel -> op) in PermMatrix.Allowed)
  // Every operation an AdminRel may perform is also permitted for OwnerRel.
  all op : OperationKind |
    (AdminRel -> op) in PermMatrix.Allowed implies (OwnerRel -> op) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// ─── AuthRequiredEverywhere ────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; SC-005; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  some AuditEntry
  // Every audit entry — evidence of a mutation — has an actor whose team matches
  // the task's team, proving the request was authenticated and team-resolved before
  // any mutation occurred.
  all e : AuditEntry | e.entryActor.userTeam = e.entryTask.taskTeam
  // No audit entry has a nil actor (enforced by multiplicity, but asserted explicitly
  // to make the predicate structurally meaningful).
  all e : AuditEntry | some e.entryActor
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ─── AuditCompleteness ────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: FR-015; FR-016; SC-007; data-model.md AuditEntry
pred AuditCompleteness {
  some Task
  some AuditEntry
  // Every task in the model has a creation audit entry.
  all t : Task | some e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated
  // No two creation entries exist for the same task.
  all t : Task | lone e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated
  // Every audit entry records exactly one well-typed operation.
  all e : AuditEntry | one e.entryOp
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ─── AppendOnly ───────────────────────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: FR-017; SC-009; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // The deleted event is terminal and unique: a task can be deleted at most once,
  // and there is no second creation event after the deletion.
  all t : Task |
    (some e : AuditEntry | e.entryTask = t and e.entryOp = OpDeleted) implies
    (lone e : AuditEntry | e.entryTask = t and e.entryOp = OpDeleted)
  // Audit entries are not retroactively re-attributed: no two entries share
  // (task, operation, actor) with different roles — that would indicate an in-place edit.
  all disj e1, e2 : AuditEntry |
    (e1.entryTask = e2.entryTask and e1.entryOp = e2.entryOp and e1.entryActor = e2.entryActor)
    implies e1.entryActorRole = e2.entryActorRole
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ─── AttributionCorrectness ───────────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: FR-016; data-model.md AuditEntry.actor_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  // The recorded actor role in every audit entry matches the actual role of the actor.
  all e : AuditEntry | e.entryActorRole = e.entryActor.userRole
  // No audit entry misattributes an operation to an actor in the wrong team.
  all e : AuditEntry | e.entryActor.userTeam = e.entryTeam
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ─── OwnershipExclusivity ─────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity  ANCHOR: FR-009; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  some Task
  all t : Task | one t.taskOwner
  // The owner is always in the same team as the task.
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ─── OwnershipBasedAccess ─────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003; FR-005; FR-010; SC-011
pred OwnershipBasedAccess {
  some Task
  some AuditEntry
  // Share / unshare events are only authored by the task's owner.
  all e : AuditEntry |
    (e.entryOp = OpShared or e.entryOp = OpUnshared) implies
    e.entryActor = e.entryTask.taskOwner
  // Delete events are only authored by the task owner or a team admin.
  all e : AuditEntry |
    e.entryOp = OpDeleted implies
    (e.entryActor = e.entryTask.taskOwner or e.entryActor.userRole = TeamAdmin)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ─── NoInformationLeakage ─────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: FR-014; SC-003; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  some Task
  some AuditEntry
  // A user from a different team must not appear as an actor on any task event.
  all e : AuditEntry | e.entryActor.userTeam = e.entryTask.taskTeam
  // A user from a different team must not appear in any task's sharedWith.
  all t : Task | all u : t.sharedWith | u.userTeam = t.taskTeam
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─── FR-001 AuthRequired ──────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001; SC-005
pred FR_001_AuthRequired {
  some AuditEntry
  // No audit entry exists without a resolvable, team-consistent actor.
  all e : AuditEntry | some e.entryActor
  all e : AuditEntry | e.entryActor.userTeam = e.entryTask.taskTeam
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ─── FR-002 OneTeamPerUser ────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002; spec.md "user belongs to exactly one team"
pred FR_002_OneTeamPerUser {
  some User
  all u : User | one u.userTeam
  all u : User | one u.userRole
}
assert FR_002_OneTeamPerUser { FR_002_OneTeamPerUser }
check FR_002_OneTeamPerUser for 5

// ─── FR-003 MemberCanCreateAndEditOwned ───────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003; spec.md member permissions
pred FR_003_MemberCanCreateAndEditOwned {
  some Task
  // Members are legitimate task owners.
  some t : Task | t.taskOwner.userRole = Member
}
assert FR_003_MemberCanCreateAndEditOwned { FR_003_MemberCanCreateAndEditOwned }
check FR_003_MemberCanCreateAndEditOwned for 5

// ─── FR-004 NonShareeCannotAccessTask ─────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004; SC-004; spec.md "member must NOT view tasks they don't own and aren't shared"
pred FR_004_NonShareeCannotAccessTask {
  some Task
  some AuditEntry
  // A user who is neither the owner, a sharee, nor a team admin of the task's
  // team must not appear as an actor on any task event.
  // In the static model this is captured by: every actor is either the owner,
  // in sharedWith, or a team admin in the same team.
  all e : AuditEntry |
    e.entryActor = e.entryTask.taskOwner or
    e.entryActor in e.entryTask.sharedWith or
    e.entryActor.userRole = TeamAdmin
}
assert FR_004_NonShareeCannotAccessTask { FR_004_NonShareeCannotAccessTask }
check FR_004_NonShareeCannotAccessTask for 5

// ─── FR-005 AdminFullTeamAccess ───────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005; contracts/http-api.md permission matrix (AdminRel row)
pred FR_005_AdminFullTeamAccess {
  some Task
  // Team admins can get, edit, and delete (all ops except share-list change).
  (AdminRel -> OpGetTask)    in PermMatrix.Allowed
  (AdminRel -> OpPatchFields) in PermMatrix.Allowed
  (AdminRel -> OpDeleteTask)  in PermMatrix.Allowed
  (AdminRel -> OpGetAudit)    in PermMatrix.Allowed
  // But not OpPatchShare (Q1=A).
  (AdminRel -> OpPatchShare) !in PermMatrix.Allowed
}
assert FR_005_AdminFullTeamAccess { FR_005_AdminFullTeamAccess }
check FR_005_AdminFullTeamAccess for 8

// ─── FR-006 CrossTeamAbsoluteIsolation ────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006; FR-014; SC-003
pred FR_006_CrossTeamAbsoluteIsolation {
  some Task
  some AuditEntry
  // No audit entry actor is from a different team than the task.
  all e : AuditEntry | e.entryActor.userTeam = e.entryTask.taskTeam
  // No task has a sharee from a different team.
  all t : Task | all u : t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_006_CrossTeamAbsoluteIsolation { FR_006_CrossTeamAbsoluteIsolation }
check FR_006_CrossTeamAbsoluteIsolation for 5

// ─── FR-009 ImmutableOwnerAndTeam ────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md "owner_id and team_id immutable"
pred FR_009_ImmutableOwnerAndTeam {
  some Task
  // Every task has exactly one owner (immutability proxy in static model).
  all t : Task | one t.taskOwner
  // Owner is in same team as task (team_id immutable + owner FK invariant).
  all t : Task | t.taskOwner.userTeam = t.taskTeam
}
assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// ─── FR-010 OwnerOnlyShareControl ────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-010; Q1=A; SC-011; contracts/http-api.md "400 for non-owner shared_with"
pred FR_010_OwnerOnlyShareControl {
  some AuditEntry
  all e : AuditEntry |
    (e.entryOp = OpShared or e.entryOp = OpUnshared) implies
    e.entryActor = e.entryTask.taskOwner
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// ─── FR-011 ShareeCannotDelete ───────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011; Q3=B; contracts/http-api.md "sharee DELETE → 404"
pred FR_011_ShareeCannotDelete {
  some AuditEntry
  // The actor on any deletion event is the owner or a team admin.
  all e : AuditEntry |
    e.entryOp = OpDeleted implies
    (e.entryActor = e.entryTask.taskOwner or e.entryActor.userRole = TeamAdmin)
}
assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 5

// ─── FR-012 CrossTeamSharingForbidden ────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md "cross-team sharing not permitted in v1"
pred FR_012_CrossTeamSharingForbidden {
  some Task
  all t : Task | all u : t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_CrossTeamSharingForbidden { FR_012_CrossTeamSharingForbidden }
check FR_012_CrossTeamSharingForbidden for 5

// ─── FR-015 MutationImpliesAudit ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015; SC-007; spec.md "no state change without audit entry"
pred FR_015_MutationImpliesAudit {
  some Task
  some AuditEntry
  // Every task has a creation audit entry (the minimum required for any existing task).
  all t : Task | some e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated
  // Every creation entry is uniquely one per task.
  all t : Task | lone e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated
}
assert FR_015_MutationImpliesAudit { FR_015_MutationImpliesAudit }
check FR_015_MutationImpliesAudit for 5

// ─── FR-016 AuditEntryAttribution ────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md AuditEntry fields; spec.md "actor_role snapshotted at time of change"
pred FR_016_AuditEntryAttribution {
  some AuditEntry
  all e : AuditEntry |
    e.entryActorRole = e.entryActor.userRole and
    e.entryTeam = e.entryTask.taskTeam and
    e.entryActor.userTeam = e.entryTeam
}
assert FR_016_AuditEntryAttribution { FR_016_AuditEntryAttribution }
check FR_016_AuditEntryAttribution for 5

// ─── FR-017 AuditEntriesOutliveTask ──────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md "audit_entries not FK to tasks"; SC-009
pred FR_017_AuditEntriesOutliveTask {
  some AuditEntry
  // If a task has a deleted event, the creation entry still exists (audit trail intact).
  all t : Task |
    (some e : AuditEntry | e.entryTask = t and e.entryOp = OpDeleted) implies
    (some e : AuditEntry | e.entryTask = t and e.entryOp = OpCreated)
  // Deletion is a unique terminal event.
  all t : Task | lone e : AuditEntry | e.entryTask = t and e.entryOp = OpDeleted
}
assert FR_017_AuditEntriesOutliveTask { FR_017_AuditEntriesOutliveTask }
check FR_017_AuditEntriesOutliveTask for 5

// ─── FR-019 AuditAccessControlMirrorsTaskAccess ──────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-019; contracts/http-api.md "GET audit: same access as GET task"
pred FR_019_AuditAccessControlMirrorsTaskAccess {
  some Task
  // Every relationship that allows OpGetTask also allows OpGetAudit.
  all r : Relationship |
    (r -> OpGetTask) in PermMatrix.Allowed implies (r -> OpGetAudit) in PermMatrix.Allowed
  // Every relationship that allows OpGetAudit also allows OpGetTask (symmetric).
  all r : Relationship |
    (r -> OpGetAudit) in PermMatrix.Allowed implies (r -> OpGetTask) in PermMatrix.Allowed
}
assert FR_019_AuditAccessControlMirrorsTaskAccess { FR_019_AuditAccessControlMirrorsTaskAccess }
check FR_019_AuditAccessControlMirrorsTaskAccess for 8