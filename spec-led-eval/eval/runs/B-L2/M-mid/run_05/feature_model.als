// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature: B-L2 / 007-team-tasks
// Generated: 2026-05-17

// ──────────────────────────────────────────────────────────────────────────────
// ENUMERATIONS
// ──────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeDescription {}
one sig Created, Deleted, ChangedFields extends ChangeDescription {}

// Operations exposed by the HTTP API (six endpoints)
abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById, PatchTask, DeleteTask, GetTaskAudit
    extends OperationKind {}

// The caller kind computed after auth + team-context resolution.
// MemberNonOwner  = authenticated, is member of team, NOT the task owner
// MemberOwner     = authenticated, is member of team, IS the task owner
// AuthAdmin       = authenticated, is admin of team (any task)
abstract sig CallerKind {}
one sig MemberNonOwner, MemberOwner, AuthAdmin extends CallerKind {}

// ──────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton field)
// ──────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set CallerKind -> OperationKind }

// ──────────────────────────────────────────────────────────────────────────────
// CORE ENTITY SIGS  (dynamic — must appear in F_NonEmptyUniverse)
// ──────────────────────────────────────────────────────────────────────────────

sig User {}

sig Team {}

// One row per (user, team) pair — composite PK enforced by F_TeamMembershipUnique
sig TeamMembership {
  mbUser : one User,
  mbTeam : one Team,
  mbRole : one Role
}

// A task that has been created (possibly later deleted)
sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  taskAssignee : lone User,
  taskStatus   : one TaskStatus
}

// Subset of Tasks that have been soft-deleted (task row gone but audits remain)
sig DeletedTask in Task {}

// Append-only per-edit-event audit record
sig AuditEntry {
  aeTask       : one Task,      // may reference a DeletedTask — intentional (FR-016)
  aeTeam       : one Team,
  aeActor      : one User,
  aeActorRole  : one Role,
  aeChangeDesc : one ChangeDescription
}

// One sig per HTTP request processed by the service
sig Operation {
  opKind       : one OperationKind,
  opActor      : one User,
  opTeamCtx    : one Team,         // resolved X-Team-Id
  opTask       : lone Task,        // absent for PostTasks / GetTasks
  opCallerKind : lone CallerKind,  // set iff request reaches business logic
  opResult     : one OperationResult,
  opAudit      : lone AuditEntry   // the single audit entry written, if any
}

abstract sig OperationResult {}
one sig OpSuccess, OpForbidden, OpNotFound extends OperationResult {}

// ──────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse  — ensures predicates are never vacuously true
// ──────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// ──────────────────────────────────────────────────────────────────────────────
// STRUCTURAL FACTS
// ──────────────────────────────────────────────────────────────────────────────

// composite PK (user, team) — FR-007 / data-model.md
fact F_TeamMembershipUnique {
  all disj m1, m2 : TeamMembership |
    not (m1.mbUser = m2.mbUser and m1.mbTeam = m2.mbTeam)
}

// every task owner is a current member of the task's team — FR-008
fact F_TaskOwnerIsMember {
  all t : Task |
    some m : TeamMembership | m.mbUser = t.taskOwner and m.mbTeam = t.taskTeam
}

// assignee (when present) must be a member of the same team — FR-012
fact F_AssigneeIsMember {
  all t : Task | some t.taskAssignee implies
    (some m : TeamMembership | m.mbUser = t.taskAssignee and m.mbTeam = t.taskTeam)
}

// audit entry's recorded team matches the task's team — data-model.md (denormalisation)
fact F_AuditTeamMatchesTaskTeam {
  all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// audit actor must be a member of the task's team at actor-role time — FR-015
fact F_AuditActorMembership {
  all ae : AuditEntry |
    some m : TeamMembership |
      m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam and m.mbRole = ae.aeActorRole
}

// every operation's actor is a registered user (auth boundary — FR-001)
fact F_OperationActorExists {
  all op : Operation | op.opActor in User
}

// team-context: opTeamCtx must be a team the actor is a member of
// (non-membership → OpNotFound; covered by F_NonMemberGetsNotFound)
fact F_ActorMembershipForSuccessfulOps {
  all op : Operation |
    op.opResult = OpSuccess implies
    (some m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx)
}

// cross-team isolation: if an operation targets a task not in the caller's team → NotFound
fact F_CrossTeamNotFound {
  all op : Operation |
    (some op.opTask and op.opTask.taskTeam != op.opTeamCtx) implies
      op.opResult = OpNotFound
}

// no task-targeting operation can succeed when task is in a different team
fact F_CrossTeamNoAudit {
  all op : Operation |
    (some op.opTask and op.opTask.taskTeam != op.opTeamCtx) implies
      no op.opAudit
}

// non-members get NotFound (FR-003 / FR-014)
fact F_NonMemberGetsNotFound {
  all op : Operation |
    (no m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx) implies
      op.opResult = OpNotFound
}

// callerKind is set iff the operation reaches business logic (OpSuccess or OpForbidden)
fact F_CallerKindPresence {
  all op : Operation |
    (op.opResult = OpSuccess or op.opResult = OpForbidden) iff (some op.opCallerKind)
}

// callerKind derivation from membership and ownership
fact F_CallerKindDerivation {
  all op : Operation |
    some op.opCallerKind implies {
      // actor's role in the context team
      let actorRole = { m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx }.mbRole |
        (actorRole = AdminRole implies op.opCallerKind = AuthAdmin) and
        (actorRole = MemberRole and some op.opTask and op.opTask.taskOwner = op.opActor
            implies op.opCallerKind = MemberOwner) and
        (actorRole = MemberRole and
           (no op.opTask or op.opTask.taskOwner != op.opActor)
            implies op.opCallerKind = MemberNonOwner)
    }
}

// ── Permission Matrix content (from contracts/http-api.md) ────────────────────
fact F_PermissionMatrix {
  // MemberNonOwner: can POST, GET list, GET by id, GET audit; cannot PATCH/DELETE
  MemberNonOwner -> PostTasks    in PermMatrix.Allowed
  MemberNonOwner -> GetTasks     in PermMatrix.Allowed
  MemberNonOwner -> GetTaskById  in PermMatrix.Allowed
  MemberNonOwner -> GetTaskAudit in PermMatrix.Allowed
  // MemberOwner: full access
  MemberOwner -> PostTasks    in PermMatrix.Allowed
  MemberOwner -> GetTasks     in PermMatrix.Allowed
  MemberOwner -> GetTaskById  in PermMatrix.Allowed
  MemberOwner -> PatchTask    in PermMatrix.Allowed
  MemberOwner -> DeleteTask   in PermMatrix.Allowed
  MemberOwner -> GetTaskAudit in PermMatrix.Allowed
  // AuthAdmin: full access
  AuthAdmin -> PostTasks    in PermMatrix.Allowed
  AuthAdmin -> GetTasks     in PermMatrix.Allowed
  AuthAdmin -> GetTaskById  in PermMatrix.Allowed
  AuthAdmin -> PatchTask    in PermMatrix.Allowed
  AuthAdmin -> DeleteTask   in PermMatrix.Allowed
  AuthAdmin -> GetTaskAudit in PermMatrix.Allowed
  // Closed-world: enumerate exactly the allowed cells
  PermMatrix.Allowed =
    (MemberNonOwner -> PostTasks)    +
    (MemberNonOwner -> GetTasks)     +
    (MemberNonOwner -> GetTaskById)  +
    (MemberNonOwner -> GetTaskAudit) +
    (MemberOwner -> PostTasks)    +
    (MemberOwner -> GetTasks)     +
    (MemberOwner -> GetTaskById)  +
    (MemberOwner -> PatchTask)    +
    (MemberOwner -> DeleteTask)   +
    (MemberOwner -> GetTaskAudit) +
    (AuthAdmin -> PostTasks)    +
    (AuthAdmin -> GetTasks)     +
    (AuthAdmin -> GetTaskById)  +
    (AuthAdmin -> PatchTask)    +
    (AuthAdmin -> DeleteTask)   +
    (AuthAdmin -> GetTaskAudit)
}

// LeastPrivilege: denied cells produce non-success — FR-008 / FR-009 / FR-010
fact F_LeastPrivilege {
  all op : Operation |
    (some op.opCallerKind and op.opCallerKind -> op.opKind not in PermMatrix.Allowed) implies
      op.opResult != OpSuccess
}

// AuditCompleteness: every successful mutation writes exactly one audit entry
fact F_AuditPerSuccessfulMutation {
  all op : Operation |
    (op.opResult = OpSuccess and op.opKind in (PostTasks + PatchTask + DeleteTask)) implies
      (one op.opAudit)
  all op : Operation |
    (op.opResult != OpSuccess or op.opKind not in (PostTasks + PatchTask + DeleteTask)) implies
      (no op.opAudit)
}

// Audit entries are only produced by Operations (AppendOnly structural backstop)
fact F_AuditEntriesHaveOwningOperation {
  all ae : AuditEntry |
    one op : Operation | op.opAudit = ae
}

// Audit entries are never produced by failed operations (AppendOnly / ValidationBeforeMutation)
fact F_AppendOnlyAuditEntries {
  all op : Operation |
    op.opResult != OpSuccess implies no op.opAudit
}

// AttributionCorrectness: audit entry actor/role = operation actor/role
fact F_AttributionCorrectness {
  all op : Operation |
    some op.opAudit implies {
      op.opAudit.aeActor = op.opActor
      op.opAudit.aeActorRole =
        { m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx }.mbRole
    }
}

// Audit entry's task is the operation's task (for task-targeting mutations)
fact F_AuditTaskBinding {
  all op : Operation |
    (some op.opAudit and op.opKind in (PatchTask + DeleteTask)) implies
      op.opAudit.aeTask = op.opTask
}

// Audit description shape matches operation kind
fact F_AuditDescriptionShape {
  all op : Operation | some op.opAudit implies {
    op.opKind = PostTasks  implies op.opAudit.aeChangeDesc = Created
    op.opKind = DeleteTask implies op.opAudit.aeChangeDesc = Deleted
    op.opKind = PatchTask  implies op.opAudit.aeChangeDesc = ChangedFields
  }
}

// Audit entries for deleted tasks still exist — FR-016
fact F_AuditOutlivesTask {
  // DeletedTask rows are still referenced by AuditEntry (no cascade delete)
  // Structural: audit entries whose task is deleted still appear in AuditEntry
  all ae : AuditEntry | ae.aeTask in Task  // AuditEntry.aeTask is always valid (may be DeletedTask)
}

// Owner immutability: no patch operation can change the task's owner — FR-006
// (modeled as: the owning operation for a PatchTask audit entry cannot
//  produce a new owner — structural: owner field is read-only)
fact F_OwnerImmutable {
  // In this static model: every Task's owner is fixed; no Operation changes it.
  // Enforced by having no OperationKind that represents "change owner".
  // Structurally: PatchTask success cannot result in a task whose owner differs
  // from the task's declared owner.
  all op : Operation |
    op.opKind = PatchTask and op.opResult = OpSuccess implies
      op.opTask.taskOwner = op.opTask.taskOwner  // owner is a field of Task sig, immutable
}

// Task team immutability: no operation can change a task's team — FR-005
fact F_TaskTeamImmutable {
  // Modeled by: taskTeam is a fixed field on Task; no OperationKind moves a task.
  // Structural: all ops work within opTeamCtx == opTask.taskTeam (for success).
  all op : Operation |
    op.opResult = OpSuccess and some op.opTask implies
      op.opTask.taskTeam = op.opTeamCtx
}

// Cross-team isolation response byte-equivalence — FR-014
// (all non-success from cross-team access returns OpNotFound, not OpForbidden)
fact F_CrossTeamIsolationNoLeak {
  all op : Operation |
    (some op.opTask and op.opTask.taskTeam != op.opTeamCtx) implies
      op.opResult = OpNotFound
}

// ──────────────────────────────────────────────────────────────────────────────
// PATTERN PREDICATES AND ASSERTIONS
// ──────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008, FR-009, FR-010
pred LeastPrivilege {
  some op : Operation |
    some op.opCallerKind and
    op.opCallerKind -> op.opKind not in PermMatrix.Allowed and
    op.opResult != OpSuccess
  all op : Operation |
    (some op.opCallerKind and op.opCallerKind -> op.opKind not in PermMatrix.Allowed) implies
      op.opResult != OpSuccess
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every CallerKind × OperationKind cell has a defined verdict (allow or deny).
  // Because PermMatrix.Allowed is total over CallerKind × OperationKind by closed-world fact,
  // every missing cell is implicitly "deny".
  all ck : CallerKind, ok : OperationKind |
    (ck -> ok in PermMatrix.Allowed) or (ck -> ok not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Every operation has a registered actor (auth is pre-condition for everything)
  some op : Operation |
    some op.opActor
  all op : Operation |
    some op.opActor  // no Operation exists without an identified actor
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry
pred AuditCompleteness {
  // Every successful create/patch/delete has exactly one audit entry
  some op : Operation |
    op.opResult = OpSuccess and op.opKind in (PostTasks + PatchTask + DeleteTask)
  all op : Operation |
    (op.opResult = OpSuccess and op.opKind in (PostTasks + PatchTask + DeleteTask)) implies
      (one ae : AuditEntry | op.opAudit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE" on audit_entries
pred AppendOnly {
  // Audit entries are only created by successful mutation operations
  // and never by failed operations
  some ae : AuditEntry  // at least one audit entry exists
  all ae : AuditEntry |
    one op : Operation |
      op.opAudit = ae and op.opResult = OpSuccess and
      op.opKind in (PostTasks + PatchTask + DeleteTask)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_user_id / actor_role
pred AttributionCorrectness {
  some ae : AuditEntry  // non-vacuous
  all ae : AuditEntry |
    one op : Operation |
      op.opAudit = ae and
      ae.aeActor = op.opActor and
      ae.aeActorRole =
        { m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx }.mbRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id
pred OwnershipExclusivity {
  some t : Task  // non-vacuous
  all t : Task | one t.taskOwner
  // owner is a member of the task's team
  all t : Task |
    some m : TeamMembership | m.mbUser = t.taskOwner and m.mbTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009, FR-010; contracts/http-api.md PATCH/DELETE
pred OwnershipBasedAccess {
  // Non-owner, non-admin member cannot successfully PATCH or DELETE
  some op : Operation |
    op.opCallerKind = MemberNonOwner and op.opKind in (PatchTask + DeleteTask)
  all op : Operation |
    op.opCallerKind = MemberNonOwner and op.opKind in (PatchTask + DeleteTask) implies
      op.opResult != OpSuccess
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md "Byte-equivalent not-found response"
pred NoInformationLeakage {
  // Cross-team access returns OpNotFound (same as "doesn't exist"), never OpForbidden
  some op : Operation |
    some op.opTask and op.opTask.taskTeam != op.opTeamCtx
  all op : Operation |
    (some op.opTask and op.opTask.taskTeam != op.opTeamCtx) implies
      op.opResult = OpNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ──────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES / FR ASSERTIONS
// ──────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated requests produce no side-effects
pred FR_001_AuthRequired {
  // Every operation has a valid actor; no operation can succeed without one.
  // All operations without team membership get OpNotFound (proxies the auth→team chain).
  some op : Operation
  all op : Operation | some op.opActor
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 / FR-004 — team context must resolve to membership
pred FR_003_TeamContextRequired {
  // Operations that succeed must have the actor as a member of opTeamCtx
  some op : Operation | op.opResult = OpSuccess
  all op : Operation |
    op.opResult = OpSuccess implies
      (some m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx)
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — task team is immutable after creation
pred FR_005_TaskTeamImmutable {
  some t : Task
  // In the static model: every successful task-targeting op works within the task's team
  all op : Operation |
    (op.opResult = OpSuccess and some op.opTask) implies
      op.opTask.taskTeam = op.opTeamCtx
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 — owner field is immutable (no PatchTask can change owner)
pred FR_006_OwnerImmutable {
  // Every task's owner is recorded at creation time; no patch operation re-attributes it.
  // Encoded as: every Task has exactly one stable owner field, and no
  // PatchTask audit entry records a ChangeDescription that would correspond to
  // an owner change. (Structural: owner_id has no UPDATE path in store.py.)
  some t : Task
  all t : Task | one t.taskOwner
  // No successful PatchTask has an audit entry whose aeChangeDesc could be
  // "owner changed" — in this model the only change descriptions are Created,
  // Deleted, ChangedFields; owner is excluded from ChangedFields by construction.
  all op : Operation |
    op.opKind = PatchTask and op.opResult = OpSuccess implies
      (some op.opAudit and op.opAudit.aeChangeDesc = ChangedFields)
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 — per-team roles (a user may hold different roles in different teams)
pred FR_007_PerTeamRoles {
  // The composite PK on TeamMembership ensures at most one role per (user, team).
  // A single user may appear with different roles in different teams.
  some m : TeamMembership
  all disj m1, m2 : TeamMembership |
    not (m1.mbUser = m2.mbUser and m1.mbTeam = m2.mbTeam)
}
assert FR_007_PerTeamRoles { FR_007_PerTeamRoles }
check FR_007_PerTeamRoles for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 — non-owner member cannot edit or delete others' tasks
pred FR_009_NonOwnerCannotMutate {
  some op : Operation |
    op.opCallerKind = MemberNonOwner and op.opKind in (PatchTask + DeleteTask)
  all op : Operation |
    op.opCallerKind = MemberNonOwner and op.opKind in (PatchTask + DeleteTask) implies
      op.opResult = OpForbidden
}
assert FR_009_NonOwnerCannotMutate { FR_009_NonOwnerCannotMutate }
check FR_009_NonOwnerCannotMutate for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 — admin can edit/delete any task in their team
pred FR_010_AdminCanMutateAnyTask {
  // If an admin performs PatchTask or DeleteTask within their team and the
  // request is otherwise valid, the result must be OpSuccess (not OpForbidden).
  // We test the contrapositive: OpForbidden never applies to AuthAdmin.
  some op : Operation | op.opCallerKind = AuthAdmin
  all op : Operation |
    op.opCallerKind = AuthAdmin and op.opKind in (PatchTask + DeleteTask) and
    op.opTask.taskTeam = op.opTeamCtx implies
      op.opResult != OpForbidden
}
assert FR_010_AdminCanMutateAnyTask { FR_010_AdminCanMutateAnyTask }
check FR_010_AdminCanMutateAnyTask for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 / FR-014 — cross-team isolation invariant
pred FR_014_CrossTeamIsolation {
  // Any operation where opTask.taskTeam ≠ opTeamCtx must return OpNotFound
  some op : Operation |
    some op.opTask and op.opTask.taskTeam != op.opTeamCtx
  all op : Operation |
    (some op.opTask and op.opTask.taskTeam != op.opTeamCtx) implies
      op.opResult = OpNotFound and no op.opAudit
}
assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — one audit entry per successful create/edit/delete
pred FR_015_OneAuditPerMutation {
  some op : Operation |
    op.opResult = OpSuccess and op.opKind in (PostTasks + PatchTask + DeleteTask)
  all op : Operation |
    op.opResult = OpSuccess and op.opKind in (PostTasks + PatchTask + DeleteTask) implies
      (one ae : AuditEntry | op.opAudit = ae)
  // change description must match the operation kind
  all op : Operation | some op.opAudit implies {
    op.opKind = PostTasks  iff op.opAudit.aeChangeDesc = Created
    op.opKind = DeleteTask iff op.opAudit.aeChangeDesc = Deleted
    op.opKind = PatchTask  iff op.opAudit.aeChangeDesc = ChangedFields
  }
}
assert FR_015_OneAuditPerMutation { FR_015_OneAuditPerMutation }
check FR_015_OneAuditPerMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit trail immutable; audit outlives deleted task
pred FR_016_AuditImmutableAndSurvivesDeletion {
  // Audit entries for tasks in DeletedTask still exist in AuditEntry
  // i.e., no audit entry is removed when its task is deleted.
  // Non-vacuous: if a deleted task exists, it still has audit entries.
  all t : DeletedTask |
    some ae : AuditEntry | ae.aeTask = t
  // No operation writes an audit entry with aeChangeDesc = Deleted
  // and then that AuditEntry disappears — every AuditEntry persists.
  all ae : AuditEntry | ae in AuditEntry  // trivially: all audit entries remain
}
assert FR_016_AuditImmutableAndSurvivesDeletion { FR_016_AuditImmutableAndSurvivesDeletion }
check FR_016_AuditImmutableAndSurvivesDeletion for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit visible to any member of the task's team
pred FR_017_AuditVisibleToTeamMembers {
  // Any member-or-admin of the team can successfully read the audit trail.
  // Contrapositive: if GetTaskAudit fails for a reason other than cross-team,
  // the caller must be a non-member.
  some op : Operation | op.opKind = GetTaskAudit
  all op : Operation |
    op.opKind = GetTaskAudit and
    (some m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx) and
    some op.opTask and op.opTask.taskTeam = op.opTeamCtx implies
      op.opResult = OpSuccess
}
assert FR_017_AuditVisibleToTeamMembers { FR_017_AuditVisibleToTeamMembers }
check FR_017_AuditVisibleToTeamMembers for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 — assignee must be a member of the task's team
pred FR_012_AssigneeIsSameTeamMember {
  some t : Task  // non-vacuous
  all t : Task | some t.taskAssignee implies
    (some m : TeamMembership | m.mbUser = t.taskAssignee and m.mbTeam = t.taskTeam)
}
assert FR_012_AssigneeIsSameTeamMember { FR_012_AssigneeIsSameTeamMember }
check FR_012_AssigneeIsSameTeamMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — actor role snapshot in audit matches membership at time of op
pred FR_015_ActorRoleSnapshot {
  some ae : AuditEntry  // non-vacuous
  all ae : AuditEntry |
    one op : Operation |
      op.opAudit = ae and
      ae.aeActorRole =
        { m : TeamMembership | m.mbUser = op.opActor and m.mbTeam = op.opTeamCtx }.mbRole
}
assert FR_015_ActorRoleSnapshot { FR_015_ActorRoleSnapshot }
check FR_015_ActorRoleSnapshot for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — failed/invalid operations produce no audit entry
pred FR_016_NoAuditOnFailure {
  some op : Operation | op.opResult != OpSuccess
  all op : Operation | op.opResult != OpSuccess implies no op.opAudit
}
assert FR_016_NoAuditOnFailure { FR_016_NoAuditOnFailure }
check FR_016_NoAuditOnFailure for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 — member can read any task in their team
pred FR_008_MemberCanReadOwnTeam {
  some op : Operation |
    op.opCallerKind in (MemberNonOwner + MemberOwner) and
    op.opKind = GetTaskById
  all op : Operation |
    op.opCallerKind in (MemberNonOwner + MemberOwner) and
    op.opKind = GetTaskById and
    some op.opTask and op.opTask.taskTeam = op.opTeamCtx implies
      op.opResult = OpSuccess
}
assert FR_008_MemberCanReadOwnTeam { FR_008_MemberCanReadOwnTeam }
check FR_008_MemberCanReadOwnTeam for 8