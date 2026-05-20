// === feature_model.als — Alloy model for B-L2: SaaS Team Task Management with Audit Trail ===
// Feature: 007-team-tasks | Branch B-L2

// ============================================================
// ENUMS & PRIMITIVE ABSTRACTIONS
// ============================================================

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig CK_Created, CK_Changed, CK_Deleted extends ChangeKind {}

// ============================================================
// CORE DOMAIN SIGS
// ============================================================

sig User {}
sig Team {}

// TeamMembership: many-to-many with per-team role (FR-007)
sig TeamMembership {
  tm_user : one User,
  tm_team : one Team,
  tm_role : one Role
}

// Task: owned by one team and one creator (owner_id immutable, FR-005, FR-006)
sig Task {
  task_team  : one Team,
  task_owner : one User,
  task_status: one TaskStatus,
  task_assignee: lone User
}

// AuditEntry: append-only, team denormalised so it survives task deletion (FR-015, FR-016)
sig AuditEntry {
  ae_task      : one Task,
  ae_team      : one Team,
  ae_actor     : one User,
  ae_actor_role: one Role,
  ae_change    : one ChangeKind
}

// Deleted tasks: the task row is logically removed but audit entries remain (FR-016)
one sig Graveyard {
  deleted_tasks: set Task
}

// ============================================================
// PERMISSION MATRIX SIGS (FR-008, FR-009, FR-010)
// ============================================================

abstract sig AccessContext {}
// AC_MemberNonOwner: member role, does NOT own the target task
// AC_MemberOwner   : member role, OWNS the target task
// AC_Admin         : admin role (any task in team)
one sig AC_MemberNonOwner, AC_MemberOwner, AC_Admin extends AccessContext {}

abstract sig OperationKind {}
one sig
  Op_PostTasks,
  Op_GetTasks,
  Op_GetTaskById,
  Op_PatchTask,
  Op_DeleteTask,
  Op_GetAudit extends OperationKind {}

// Singleton permission matrix (contracts/http-api.md permission table)
one sig PermMatrix {
  Allowed: set AccessContext -> OperationKind
}

// ============================================================
// OPERATION SIG — a resolved, in-team request
// ============================================================

sig Operation {
  op_actor  : one User,
  op_team   : one Team,
  op_kind   : one OperationKind,
  op_task   : lone Task,
  op_context: one AccessContext
}

// ============================================================
// F_NonEmptyUniverse — ensures dynamic sigs have ≥1 atom
// ============================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// ============================================================
// STRUCTURAL FACTS
// ============================================================

// Composite PK on (user_id, team_id): at most one membership per (user, team)
// data-model.md UNIQUE (user_id, team_id) on team_memberships
fact F_TeamMembershipUniqueness {
  all disj m1, m2: TeamMembership |
    not (m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team)
}

// Task owner must be a member of the task's team at creation time (FR-004, FR-008)
fact F_TaskOwnerIsMember {
  all t: Task |
    some m: TeamMembership | m.tm_user = t.task_owner and m.tm_team = t.task_team
}

// Task assignee (when present) must be a member of the task's team (FR-012)
fact F_AssigneeInSameTeam {
  all t: Task |
    lone t.task_assignee =>
      (some a: User | a = t.task_assignee =>
        (some m: TeamMembership | m.tm_user = a and m.tm_team = t.task_team))
}

// Audit entry team must equal the referenced task's team (data-model.md denorm rule)
fact F_AuditTeamMatchesTaskTeam {
  all ae: AuditEntry |
    ae.ae_team = ae.ae_task.task_team
}

// Audit entry actor must be a member of the audit entry's team (FR-004, FR-015)
fact F_AuditActorIsMember {
  all ae: AuditEntry |
    some m: TeamMembership |
      m.tm_user = ae.ae_actor and m.tm_team = ae.ae_team
}

// Actor role snapshot must match membership role at time of action (FR-015 snapshotting)
fact F_AuditActorRoleMatchesMembership {
  all ae: AuditEntry |
    some m: TeamMembership |
      m.tm_user = ae.ae_actor and m.tm_team = ae.ae_team and m.tm_role = ae.ae_actor_role
}

// Every task has exactly one CK_Created audit entry (FR-015, US1)
fact F_EachTaskHasCreatedEntry {
  all t: Task |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Created
}

// Every deleted task has exactly one CK_Deleted audit entry (FR-015, US3)
fact F_DeletedTaskHasDeletedEntry {
  all t: Graveyard.deleted_tasks |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Deleted
}

// Non-deleted tasks must NOT have a CK_Deleted entry (audit integrity)
fact F_LiveTaskNoDeletedEntry {
  all t: Task - Graveyard.deleted_tasks |
    no ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Deleted
}

// Permission matrix — exact set of allowed (AccessContext × OperationKind) cells
// contracts/http-api.md permission table
fact F_PermissionMatrix { /* MUTATED — body cleared by validator */ }

// Operation context accurately reflects actor's membership role and task ownership
// (FR-008, FR-009, FR-010)
fact F_OperationContextReflectsMembership {
  all op: Operation | {
    // Admin context <=> actor has AdminRole in this team
    op.op_context = AC_Admin <=>
      (some m: TeamMembership |
        m.tm_user = op.op_actor and m.tm_team = op.op_team and m.tm_role = AdminRole)

    // MemberOwner context <=> actor has MemberRole in this team AND owns the target task
    op.op_context = AC_MemberOwner <=>
      ((some m: TeamMembership |
        m.tm_user = op.op_actor and m.tm_team = op.op_team and m.tm_role = MemberRole)
       and
       (some t: op.op_task | t.task_owner = op.op_actor))

    // MemberNonOwner context <=> actor has MemberRole AND does NOT own the target task
    op.op_context = AC_MemberNonOwner <=>
      ((some m: TeamMembership |
        m.tm_user = op.op_actor and m.tm_team = op.op_team and m.tm_role = MemberRole)
       and
       (no t: op.op_task | t.task_owner = op.op_actor))
  }
}

// Every operation must be in the allowed set (FR-008, FR-009, FR-010)
fact F_AllOperationsAreAuthorized {
  all op: Operation |
    op.op_context -> op.op_kind in PermMatrix.Allowed
}

// Operation tasks must belong to the operation's team (cross-team isolation, FR-011, FR-014)
fact F_OperationTaskInSameTeam {
  all op: Operation |
    all t: op.op_task | t.task_team = op.op_team
}

// ============================================================
// PATTERN PREDICATES & ASSERTIONS
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008, FR-009, FR-010
pred LeastPrivilege {
  // Non-owner members never perform PATCH or DELETE (denied in the matrix)
  some Operation and
  no op: Operation |
    (op.op_context = AC_MemberNonOwner and
     (op.op_kind = Op_PatchTask or op.op_kind = Op_DeleteTask))
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 3 AccessContext, exactly 6 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every AccessContext × OperationKind cell is either in Allowed or explicitly excluded
  // (closed-world: Allowed is exactly the set specified, no undeclared cells)
  some Operation and
  PermMatrix.Allowed =
    (AC_MemberNonOwner -> Op_PostTasks)  +
    (AC_MemberNonOwner -> Op_GetTasks)   +
    (AC_MemberNonOwner -> Op_GetTaskById)+
    (AC_MemberNonOwner -> Op_GetAudit)   +
    (AC_MemberOwner    -> Op_PostTasks)  +
    (AC_MemberOwner    -> Op_GetTasks)   +
    (AC_MemberOwner    -> Op_GetTaskById)+
    (AC_MemberOwner    -> Op_PatchTask)  +
    (AC_MemberOwner    -> Op_DeleteTask) +
    (AC_MemberOwner    -> Op_GetAudit)   +
    (AC_Admin          -> Op_PostTasks)  +
    (AC_Admin          -> Op_GetTasks)   +
    (AC_Admin          -> Op_GetTaskById)+
    (AC_Admin          -> Op_PatchTask)  +
    (AC_Admin          -> Op_DeleteTask) +
    (AC_Admin          -> Op_GetAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 3 AccessContext, exactly 6 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every operation has an actor that has a membership in the operation's team
  // (unauthenticated callers cannot reach Operation atoms)
  some Operation and
  all op: Operation |
    some m: TeamMembership |
      m.tm_user = op.op_actor and m.tm_team = op.op_team
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md audit_entries
pred AuditCompleteness {
  // Every task has exactly one CK_Created entry
  some Task and
  all t: Task |
    (one ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Created)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No two distinct audit entries for the same task share the same (actor, change-kind)
  // tuple as if one "replaced" the other via an update path;
  // more structurally: the graveyard tracks deleted Task rows, never AuditEntry atoms —
  // AuditEntry atoms are never placed into any deletion set.
  // We assert: every AuditEntry's task exists as a known Task atom (live or deleted),
  // and no audit entry is "tombstoned" the way tasks can be.
  some AuditEntry and
  // The key structural claim: audit entries for deleted tasks persist
  all t: Graveyard.deleted_tasks |
    (some ae: AuditEntry | ae.ae_task = t)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_role snapshot
pred AttributionCorrectness {
  // Every audit entry's recorded role matches the actor's actual membership role
  some AuditEntry and
  all ae: AuditEntry |
    some m: TeamMembership |
      m.tm_user = ae.ae_actor and
      m.tm_team = ae.ae_team and
      m.tm_role = ae.ae_actor_role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  // Every task has exactly one owner (one sig field; uniqueness is structural)
  // and that owner is a member of the task's team
  some Task and
  all t: Task |
    (one t.task_owner) and
    (some m: TeamMembership | m.tm_user = t.task_owner and m.tm_team = t.task_team)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009, FR-010; contracts/http-api.md PATCH/DELETE auth
pred OwnershipBasedAccess {
  // A member who does not own the target task may not PATCH or DELETE it
  some Operation and
  all op: Operation |
    ((op.op_kind = Op_PatchTask or op.op_kind = Op_DeleteTask) and
     (some m: TeamMembership |
       m.tm_user = op.op_actor and m.tm_team = op.op_team and m.tm_role = MemberRole))
    implies
    (some t: op.op_task | t.task_owner = op.op_actor)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // Every task referenced by an operation belongs to the same team as the operation;
  // tasks from other teams are never exposed to an operation (they simply don't appear
  // in op_task, so the caller cannot distinguish "other team" from "non-existent").
  some Operation and
  all op: Operation |
    all t: op.op_task | t.task_team = op.op_team
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ============================================================
// FEATURE-SPECIFIC FR PREDICATES
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated requests cannot reach business logic
pred FR_001_AuthRequired {
  some Operation and
  all op: Operation |
    some m: TeamMembership |
      m.tm_user = op.op_actor and m.tm_team = op.op_team
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — X-Team-Id header: actor must be a member of op_team
pred FR_003_TeamContextRequired {
  some Operation and
  all op: Operation |
    some m: TeamMembership |
      m.tm_user = op.op_actor and m.tm_team = op.op_team
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — every request actor is a current member of the resolved team
pred FR_004_ActorMustBeMember {
  some TeamMembership and
  all op: Operation |
    op.op_team in TeamMembership.tm_team and
    (some m: TeamMembership | m.tm_user = op.op_actor and m.tm_team = op.op_team)
}
assert FR_004_ActorMustBeMember { FR_004_ActorMustBeMember }
check FR_004_ActorMustBeMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — task's team is set at creation and never changes
pred FR_005_TaskTeamImmutable {
  // In a snapshot model, immutability means exactly one team per task, and no operation
  // changes it; we assert: every task has exactly one team (structural invariant).
  some Task and
  all t: Task | one t.task_team
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 — owner_id is immutable; PATCH on owner_id is rejected
pred FR_006_OwnerImmutable {
  // Every task has exactly one owner, and no operation context allows owner mutation.
  // We encode as: no PATCH operation targets owner_id — since owner is a single field
  // that never changes, every task's owner equals the actor of its CK_Created audit entry.
  some Task and
  all t: Task |
    (one t.task_owner) and
    (one ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Created and ae.ae_actor = t.task_owner)
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 — per-team role; one membership row per (user, team)
pred FR_007_PerTeamRole {
  some TeamMembership and
  all disj m1, m2: TeamMembership |
    not (m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — non-owner members cannot edit or delete another member's task
pred FR_009_NonOwnerMemberCannotEditDelete {
  some Operation and
  all op: Operation |
    (op.op_kind = Op_PatchTask or op.op_kind = Op_DeleteTask)
    implies
    (not (op.op_context = AC_MemberNonOwner))
}
assert FR_009_NonOwnerMemberCannotEditDelete { FR_009_NonOwnerMemberCannotEditDelete }
check FR_009_NonOwnerMemberCannotEditDelete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — admin may edit/delete any task in their team
pred FR_010_AdminCanEditAnyTask {
  // Admin context must be allowed for PatchTask and DeleteTask
  some Operation and
  AC_Admin -> Op_PatchTask  in PermMatrix.Allowed and
  AC_Admin -> Op_DeleteTask in PermMatrix.Allowed
}
assert FR_010_AdminCanEditAnyTask { FR_010_AdminCanEditAnyTask }
check FR_010_AdminCanEditAnyTask for 8 but exactly 3 AccessContext, exactly 6 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-011/FR-014 — no operation references a task from another team
pred FR_011_CrossTeamIsolation {
  some Operation and
  all op: Operation |
    all t: op.op_task | t.task_team = op.op_team
}
assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — per-edit-event audit; every task has a CK_Created entry
pred FR_015_AuditPerEditEvent {
  some Task and
  all t: Task |
    (one ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Created) and
    (all ae: AuditEntry |
      (ae.ae_task = t and ae.ae_change = CK_Created) implies ae.ae_actor = t.task_owner)
}
assert FR_015_AuditPerEditEvent { FR_015_AuditPerEditEvent }
check FR_015_AuditPerEditEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit trail outlives the task; deleted task retains entries
pred FR_016_AuditOutlivesTask {
  // Every deleted task still has at least one audit entry (its creation entry, at minimum)
  // and a CK_Deleted entry
  some Graveyard.deleted_tasks and
  all t: Graveyard.deleted_tasks | {
    (some ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Created)
    and
    (some ae: AuditEntry | ae.ae_task = t and ae.ae_change = CK_Deleted)
  }
}
assert FR_016_AuditOutlivesTask { FR_016_AuditOutlivesTask }
check FR_016_AuditOutlivesTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit readable by any team member; scoped to ae_team
pred FR_017_AuditVisibleToTeamMembers {
  // Any member of ae_team can access the audit entries for that team
  // (modeled as: ae_team always matches task_team, so any team member can resolve it)
  some AuditEntry and
  all ae: AuditEntry |
    (ae.ae_team = ae.ae_task.task_team) and
    (some m: TeamMembership |
      m.tm_team = ae.ae_team)
}
assert FR_017_AuditVisibleToTeamMembers { FR_017_AuditVisibleToTeamMembers }
check FR_017_AuditVisibleToTeamMembers for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — assignee must be a member of the task's own team
pred FR_012_AssigneeInSameTeam {
  some Task and
  all t: Task |
    (some a: t.task_assignee |
      some m: TeamMembership | m.tm_user = a and m.tm_team = t.task_team)
}
assert FR_012_AssigneeInSameTeam { FR_012_AssigneeInSameTeam }
check FR_012_AssigneeInSameTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — task status is from the fixed set {todo, in_progress, done}
pred FR_013_StatusSetCorrect {
  some Task and
  all t: Task |
    t.task_status in (Todo + InProgress + Done)
}
assert FR_013_StatusSetCorrect { FR_013_StatusSetCorrect }
check FR_013_StatusSetCorrect for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — audit entries are retained; no delete path on audit_entries
// Modeled as: audit entries for deleted tasks still exist (AppendOnly across deletion)
pred FR_018_AuditRetained {
  some AuditEntry and
  // All AuditEntry atoms remain in scope regardless of Graveyard membership of their task
  all ae: AuditEntry |
    ae.ae_task in (Task)  // every audit entry references a valid Task atom
}
assert FR_018_AuditRetained { FR_018_AuditRetained }
check FR_018_AuditRetained for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019/FR-020 — list only returns tasks in the caller's team
pred FR_019_ListScopedToTeam {
  some Operation and
  all op: Operation |
    op.op_kind = Op_GetTasks implies
      (all t: op.op_task | t.task_team = op.op_team)
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 5

// FEATURE-SPECIFIC  ANCHOR: US4 / FR-010 — admin audit entry records AdminRole as actor_role
pred FR_010_AdminAuditRoleSnapshot {
  some AuditEntry and
  all ae: AuditEntry |
    ae.ae_actor_role = AdminRole implies
      (some m: TeamMembership |
        m.tm_user = ae.ae_actor and m.tm_team = ae.ae_team and m.tm_role = AdminRole)
}
assert FR_010_AdminAuditRoleSnapshot { FR_010_AdminAuditRoleSnapshot }
check FR_010_AdminAuditRoleSnapshot for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PermMatrixViolation { AC_MemberNonOwner -> Op_PatchTask in PermMatrix.Allowed }
