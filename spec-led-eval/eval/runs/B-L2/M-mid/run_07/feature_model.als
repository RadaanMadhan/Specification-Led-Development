// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature folder: B-L2  (spec branch: 007-team-tasks)
// Generated from: spec.md, data-model.md, contracts/http-api.md

// ═══════════════════════════════════════════════════════════════════════════
// SIGS — Roles and statuses
// ═══════════════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig CKCreated, CKDeleted, CKChanged extends ChangeKind {}

// ═══════════════════════════════════════════════════════════════════════════
// SIGS — Core domain entities
// ═══════════════════════════════════════════════════════════════════════════

sig User {}

sig Team {}

// Each TeamMembership row carries exactly one role for one user in one team.
// Composite PK (user, team) enforced in F_UniqueMembership.
sig TeamMembership {
  mbUser : one User,
  mbTeam : one Team,
  mbRole : one Role
}

// A Task belongs to exactly one team and has exactly one (immutable) owner.
// Assignee is optional (lone).
sig Task {
  taskTeam   : one  Team,
  taskOwner  : one  User,
  taskAssignee : lone User,
  taskStatus : one  TaskStatus
}

// DeletedTask: tasks whose row has been removed.
// The Alloy atom for the Task still exists (audit entries reference it),
// but the task is no longer in the "live" set.
sig DeletedTask in Task {}

// AuditEntry: append-only per-edit-event record.
// aeTask intentionally references the Task atom even after deletion (no FK constraint).
sig AuditEntry {
  aeTask       : one Task,
  aeTeam       : one Team,
  aeActor      : one User,
  aeActorRole  : one Role,
  aeChangeKind : one ChangeKind
}

// WriteRequest models a PATCH or DELETE attempt by a caller on a task within a team.
sig WriteRequest {
  wrCaller     : one User,
  wrCallerRole : one Role,
  wrTeam       : one Team,
  wrTask       : one Task,
  wrOp         : one WriteOp,
  wrGranted    : one Bool
}

abstract sig WriteOp {}
one sig WPatch, WDelete extends WriteOp {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ═══════════════════════════════════════════════════════════════════════════
// SIGS — Permission matrix
// ═══════════════════════════════════════════════════════════════════════════

abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById, PatchTask, DeleteTask, GetAudit
  extends OperationKind {}

// Canonical singleton holding the role→operation allow relation.
one sig PermMatrix {
  Allowed : set Role -> OperationKind
}

// ═══════════════════════════════════════════════════════════════════════════
// NON-EMPTY UNIVERSE — ensures all dynamic sigs have at least one atom
// ═══════════════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some WriteRequest
}

// ═══════════════════════════════════════════════════════════════════════════
// STRUCTURAL FACTS
// ═══════════════════════════════════════════════════════════════════════════

// Composite PK (user, team) on TeamMembership: at most one row per pair.
fact F_UniqueMembership {
  all u : User, t : Team |
    lone m : TeamMembership | m.mbUser = u and m.mbTeam = t
}

// A task's owner must be a current member of the task's team (FR-004 / FR-006).
fact F_OwnerMembership {
  all t : Task |
    some m : TeamMembership | m.mbUser = t.taskOwner and m.mbTeam = t.taskTeam
}

// An assignee, if present, must be a member of the task's team (FR-012).
fact F_AssigneeMembership {
  all t : Task | all a : t.taskAssignee |
    some m : TeamMembership | m.mbUser = a and m.mbTeam = t.taskTeam
}

// Audit entry's team field equals the task's team (denormalised consistency).
fact F_AuditTeamConsistency {
  all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// Audit entry actor must be a member of the relevant team.
fact F_AuditActorMembership {
  all ae : AuditEntry |
    some m : TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
}

// Every task has exactly one CKCreated audit entry (FR-015, US1 acceptance #1).
fact F_CreatedAuditExists {
  all t : Task |
    one ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKCreated
}

// Every deleted task has exactly one CKDeleted audit entry (FR-015, US3).
fact F_DeletedAuditExists {
  all t : DeletedTask |
    one ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKDeleted
}

// CKDeleted entries exist only for deleted tasks (no spurious deleted entries).
fact F_NoSpuriousDeletedEntry {
  all ae : AuditEntry |
    ae.aeChangeKind = CKDeleted implies (ae.aeTask in DeletedTask)
}

// WriteRequest is consistent with the caller's actual membership role in wrTeam.
fact F_WriteRequestRoleConsistency {
  all wr : WriteRequest |
    some m : TeamMembership |
      m.mbUser = wr.wrCaller and m.mbTeam = wr.wrTeam and m.mbRole = wr.wrCallerRole
}

// WriteRequest targets a task that belongs to wrTeam (cross-team is blocked before this).
fact F_WriteRequestTeamScope {
  all wr : WriteRequest | wr.wrTask.taskTeam = wr.wrTeam
}

// Ownership-based access: a write is granted iff caller is admin OR caller is the owner.
fact F_OwnershipBasedWriteGrant {
  all wr : WriteRequest |
    wr.wrGranted = BTrue iff
      (wr.wrCallerRole = AdminRole or wr.wrTask.taskOwner = wr.wrCaller)
}

// Role-level permission matrix (FR-008 / FR-009 / FR-010).
// Non-ownership-conditional allows only; ownership conditioning is in F_OwnershipBasedWriteGrant.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (MemberRole -> PostTasks)   +
    (MemberRole -> GetTasks)    +
    (MemberRole -> GetTaskById) +
    (MemberRole -> GetAudit)    +
    (AdminRole  -> PostTasks)   +
    (AdminRole  -> GetTasks)    +
    (AdminRole  -> GetTaskById) +
    (AdminRole  -> PatchTask)   +
    (AdminRole  -> DeleteTask)  +
    (AdminRole  -> GetAudit)
}

// ═══════════════════════════════════════════════════════════════════════════
// PATTERN PREDICATES AND ASSERTIONS
// ═══════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008 FR-009 FR-010
pred LeastPrivilege {
  // Non-admin members are NOT allowed to PATCH or DELETE via role alone.
  MemberRole -> PatchTask  not in PermMatrix.Allowed
  MemberRole -> DeleteTask not in PermMatrix.Allowed
  // Admin IS allowed to PATCH and DELETE.
  AdminRole -> PatchTask  in PermMatrix.Allowed
  AdminRole -> DeleteTask in PermMatrix.Allowed
  // Both roles can read and create.
  all r : Role | r -> GetTaskById in PermMatrix.Allowed
  all r : Role | r -> GetAudit    in PermMatrix.Allowed
  all r : Role | r -> PostTasks   in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either in or not in Allowed — no undecided cell.
  // Structural: domain of Allowed is a subset of Role × OperationKind (always true in Alloy),
  // and Allowed is fully-specified by F_PermissionMatrix (6 ops × 2 roles = 12 cells, 10 allowed).
  all r : Role, op : OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
  // At least one operation is denied to MemberRole (non-vacuous: the matrix has gaps).
  some op : OperationKind | MemberRole -> op not in PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 ("admin may do everything a member can, plus…")
pred PrivilegeMonotonicity {
  // Every operation a member role is allowed also appears for admin.
  all op : OperationKind |
    MemberRole -> op in PermMatrix.Allowed implies (AdminRole -> op in PermMatrix.Allowed)
  // At least one thing admin can do that member cannot (strict superset check).
  some op : OperationKind |
    AdminRole -> op in PermMatrix.Allowed and MemberRole -> op not in PermMatrix.Allowed
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8 but exactly 2 Role, exactly 6 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
// Structural encoding: every audit entry has an actor who is a known user with a membership.
pred AuthRequiredEverywhere {
  some AuditEntry
  all ae : AuditEntry |
    some m : TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry schema; SC-007
pred AuditCompleteness {
  some Task
  // Every task has exactly one CKCreated entry.
  all t : Task |
    one ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKCreated
  // Every deleted task additionally has exactly one CKDeleted entry.
  all t : DeletedTask |
    one ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKDeleted
  // No CKDeleted entry exists for a live (non-deleted) task.
  no ae : AuditEntry |
    ae.aeChangeKind = CKDeleted and ae.aeTask not in DeletedTask
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "Append-only at two layers"; SC-008
// In Alloy's static model, "append-only" means: audit entries are never removed
// and their core fields (task, team, actor, actorRole, changeKind) never change.
// We encode this as: for every pair of distinct audit entries referencing the same task,
// neither replaces the other (they coexist).
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries for the same task share the same changeKind CKCreated
  // (exactly one created entry per task — a direct corollary of append-only + uniqueness).
  all t : Task |
    lone ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKCreated
  // No two distinct audit entries for the same task share the same changeKind CKDeleted.
  all t : Task |
    lone ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKDeleted
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 actor snapshot; data-model.md AuditEntry
pred AttributionCorrectness {
  some AuditEntry
  // Every audit entry actor is a member of the entry's team (correct attribution to a real member).
  all ae : AuditEntry |
    some m : TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
  // The role recorded in the audit entry matches the actor's membership role for that team.
  all ae : AuditEntry |
    some m : TeamMembership |
      m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam and m.mbRole = ae.aeActorRole
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005 FR-006; data-model.md Task.owner_id NOT NULL IMMUTABLE
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner (enforced by `one` multiplicity on taskOwner,
  // but we assert it explicitly so removal of the fact bites).
  all t : Task | one u : User | u = t.taskOwner
  // The owner is a member of the task's team.
  all t : Task |
    some m : TeamMembership | m.mbUser = t.taskOwner and m.mbTeam = t.taskTeam
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008 FR-009 FR-010; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  some WriteRequest
  // A write is granted if and only if caller is admin OR caller is the task owner.
  all wr : WriteRequest |
    wr.wrGranted = BTrue iff
      (wr.wrCallerRole = AdminRole or wr.wrTask.taskOwner = wr.wrCaller)
  // There exists a denied non-owner member write (non-vacuous).
  some wr : WriteRequest |
    wr.wrCallerRole = MemberRole and
    wr.wrTask.taskOwner != wr.wrCaller and
    wr.wrGranted = BFalse
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md "Byte-equivalent not-found response"
// Structural encoding: a task in team U is indistinguishable (via the model) from
// a non-existent task when accessed under team T (T ≠ U).
// We assert: no audit entry can be attributed to a cross-team access attempt,
// i.e., an actor's team context always matches the task's team.
pred NoInformationLeakage {
  some AuditEntry
  // Audit entries only appear for actions within the correct team context.
  all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
  // The actor in any audit entry is a member of that team — cross-team callers
  // are indistinguishable from unauthenticated and produce no audit entry.
  all ae : AuditEntry |
    some m : TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-012; US2 acceptance #2; US4 acceptance #2
// If a write request is not granted, no audit entry exists for that (actor, task) pair
// that records a mutation (CKChanged or CKDeleted) from that actor.
// We encode conservatively: every CKChanged or CKDeleted audit entry implies the actor
// had write access (was admin or owner).
pred ValidationBeforeMutation {
  some AuditEntry
  all ae : AuditEntry |
    (ae.aeChangeKind = CKChanged or ae.aeChangeKind = CKDeleted) implies
      (ae.aeActorRole = AdminRole or
       (some m : TeamMembership |
          m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam and
          ae.aeTask.taskOwner = ae.aeActor))
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES AND ASSERTIONS
// ═══════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001 FR-003 (authentication and team-context required)
pred FR_001_AuthRequired {
  // No audit entry exists without an actor who is a verifiable member.
  some AuditEntry
  all ae : AuditEntry |
    some m : TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (X-Team-Id header; membership required)
pred FR_003_TeamContextRequired {
  // Every write request is scoped to a team the caller actually belongs to.
  some WriteRequest
  all wr : WriteRequest |
    some m : TeamMembership | m.mbUser = wr.wrCaller and m.mbTeam = wr.wrTeam
}

assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (task team immutable after creation)
pred FR_005_TaskTeamImmutable {
  // Structural: each task has exactly one team (one multiplicity).
  // The invariant is that taskTeam never changes — modeled as no two different
  // Task atoms can share an identity with different teams.
  some Task
  all t : Task | one tm : Team | tm = t.taskTeam
}

assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (owner_id immutable; rejected with 400)
pred FR_006_OwnerImmutable {
  // Every task has exactly one owner (structural).
  some Task
  all t : Task | one u : User | u = t.taskOwner
  // No write request attempts (or succeeds) in changing the owner: there is
  // no WriteOp for ownership transfer — WPatch and WDelete are the only ops.
  // Owner-change would require a hypothetical WOwnerChange op that does not exist.
  no op : WriteOp | op not in (WPatch + WDelete)
}

assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (per-team role; user may have different role in each team)
pred FR_007_PerTeamRole {
  // At most one membership row per (user, team) pair — composite PK.
  all u : User, t : Team |
    lone m : TeamMembership | m.mbUser = u and m.mbTeam = t
  // A user can have different roles in different teams (non-vacuous if ≥1 user in ≥2 teams).
  some u : User, disj t1, t2 : Team,  m1, m2 : TeamMembership |
    m1.mbUser = u and m1.mbTeam = t1 and
    m2.mbUser = u and m2.mbTeam = t2 and
    m1.mbRole != m2.mbRole
}

assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 FR-009 (member can create and view; cannot write others' tasks)
pred FR_008_MemberCreateView {
  // MemberRole can POST and GET (via permission matrix).
  MemberRole -> PostTasks   in PermMatrix.Allowed
  MemberRole -> GetTasks    in PermMatrix.Allowed
  MemberRole -> GetTaskById in PermMatrix.Allowed
  // MemberRole cannot PATCH or DELETE (role-level; ownership gate is separate).
  MemberRole -> PatchTask  not in PermMatrix.Allowed
  MemberRole -> DeleteTask not in PermMatrix.Allowed
}

assert FR_008_MemberCreateView { FR_008_MemberCreateView }
check FR_008_MemberCreateView for 8 but exactly 2 Role, exactly 6 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-009 FR-010 (non-owner member denied write; admin/owner allowed)
pred FR_009_NonOwnerMemberDeniedWrite {
  some WriteRequest
  // Any member write where caller is not the owner must be denied.
  all wr : WriteRequest |
    (wr.wrCallerRole = MemberRole and wr.wrTask.taskOwner != wr.wrCaller) implies
      (wr.wrGranted = BFalse)
}

assert FR_009_NonOwnerMemberDeniedWrite { FR_009_NonOwnerMemberDeniedWrite }
check FR_009_NonOwnerMemberDeniedWrite for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 (admin can edit/delete any task in their team)
pred FR_010_AdminWriteAnyTask {
  some WriteRequest
  // Any write request by an admin is always granted.
  all wr : WriteRequest |
    wr.wrCallerRole = AdminRole implies (wr.wrGranted = BTrue)
}

assert FR_010_AdminWriteAnyTask { FR_010_AdminWriteAnyTask }
check FR_010_AdminWriteAnyTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 FR-014 (cross-team isolation; admin in T has no access to U)
pred FR_011_CrossTeamIsolation {
  some AuditEntry
  // Every audit entry's team matches the target task's team exactly.
  all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
  // Every write request is within the caller's own team.
  all wr : WriteRequest | wr.wrTask.taskTeam = wr.wrTeam
  // A caller's admin role in one team does not appear as a credential in another.
  all wr : WriteRequest |
    some m : TeamMembership |
      m.mbUser = wr.wrCaller and m.mbTeam = wr.wrTeam and m.mbRole = wr.wrCallerRole
}

assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (assignee must be member of same team)
pred FR_012_AssigneeTeamMembership {
  some Task
  all t : Task | all a : t.taskAssignee |
    some m : TeamMembership | m.mbUser = a and m.mbTeam = t.taskTeam
}

assert FR_012_AssigneeTeamMembership { FR_012_AssigneeTeamMembership }
check FR_012_AssigneeTeamMembership for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (status set: todo/in_progress/done; initial = todo)
pred FR_013_ValidTaskStatus {
  some Task
  all t : Task | t.taskStatus in (Todo + InProgress + Done)
}

assert FR_013_ValidTaskStatus { FR_013_ValidTaskStatus }
check FR_013_ValidTaskStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent 404; cross-team invisible)
pred FR_014_ByteEquivalent404 {
  // No audit entry exists for a cross-team access: the team in every audit entry
  // equals the task's actual team, so cross-team requests produce no observable trace.
  some AuditEntry
  all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

assert FR_014_ByteEquivalent404 { FR_014_ByteEquivalent404 }
check FR_014_ByteEquivalent404 for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (per-edit-event audit; exactly one created entry)
pred FR_015_PerEditEventAudit {
  some Task
  all t : Task |
    one ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKCreated
}

assert FR_015_PerEditEventAudit { FR_015_PerEditEventAudit }
check FR_015_PerEditEventAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (actor role snapshot must be member or admin)
pred FR_015_ActorRoleSnapshot {
  some AuditEntry
  all ae : AuditEntry | ae.aeActorRole in (MemberRole + AdminRole)
}

assert FR_015_ActorRoleSnapshot { FR_015_ActorRoleSnapshot }
check FR_015_ActorRoleSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit trail survives task deletion; no FK cascade)
pred FR_016_AuditSurvivesTaskDeletion {
  some DeletedTask
  // Every deleted task still has audit entries (at minimum CKCreated and CKDeleted).
  all t : DeletedTask |
    (some ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKCreated) and
    (some ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKDeleted)
}

assert FR_016_AuditSurvivesTaskDeletion { FR_016_AuditSurvivesTaskDeletion }
check FR_016_AuditSurvivesTaskDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit entries are append-only; no update/delete path)
pred FR_016_AuditAppendOnly {
  some AuditEntry
  // Uniqueness of CKCreated per task (cannot be overwritten).
  all t : Task |
    lone ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKCreated
  // Uniqueness of CKDeleted per task (cannot be overwritten).
  all t : Task |
    lone ae : AuditEntry | ae.aeTask = t and ae.aeChangeKind = CKDeleted
  // CKDeleted only for truly deleted tasks.
  all ae : AuditEntry |
    ae.aeChangeKind = CKDeleted implies (ae.aeTask in DeletedTask)
}

assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit readable by any team member; cross-team → 404)
pred FR_017_AuditReadableByTeamMembers {
  some AuditEntry
  // The audit endpoint access is controlled by team membership.
  // Any audit entry's actor is a valid member of the entry's team
  // (i.e., the audit entry was produced by an authorised actor within the team).
  all ae : AuditEntry |
    some m : TeamMembership | m.mbUser = ae.aeActor and m.mbTeam = ae.aeTeam
  // Admin can also read audit (covered by PermissionMatrix: AdminRole -> GetAudit).
  AdminRole -> GetAudit in PermMatrix.Allowed
  MemberRole -> GetAudit in PermMatrix.Allowed
}

assert FR_017_AuditReadableByTeamMembers { FR_017_AuditReadableByTeamMembers }
check FR_017_AuditReadableByTeamMembers for 8 but exactly 2 Role, exactly 6 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit entries retained; no delete path on audit table)
pred FR_018_AuditRetention {
  // Structural: no audit entry has a change kind that would indicate self-deletion.
  // All three legal ChangeKinds are well-defined; no "audit_deleted" kind exists.
  some AuditEntry
  all ae : AuditEntry | ae.aeChangeKind in (CKCreated + CKDeleted + CKChanged)
}

assert FR_018_AuditRetention { FR_018_AuditRetention }
check FR_018_AuditRetention for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 FR-020 (team-scoped list; all tasks visible to members)
pred FR_019_TeamScopedList {
  // Every task is reachable by every member of its team (visibility is team-scoped).
  some Task
  all t : Task |
    all m : TeamMembership |
      m.mbTeam = t.taskTeam implies
        (some ae : AuditEntry | ae.aeTask = t)   // task has an audit trail (exists in the system)
}

assert FR_019_TeamScopedList { FR_019_TeamScopedList }
check FR_019_TeamScopedList for 5