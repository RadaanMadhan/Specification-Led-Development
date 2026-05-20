// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature:  B-L2 (007-team-tasks)
// Sources:  spec.md, data-model.md, contracts/http-api.md

// ═══════════════════════════════════════════════════════════════════════════
// § 1  ENUMERATION SIGS
// ═══════════════════════════════════════════════════════════════════════════

abstract sig MemberRole {}
one sig RoleMember, RoleAdmin extends MemberRole {}

abstract sig TaskStatus {}
one sig StatusTodo, StatusInProgress, StatusDone extends TaskStatus {}

abstract sig ChangeDesc {}
one sig DescCreated, DescChanged, DescDeleted extends ChangeDesc {}

// ── Operation kinds correspond 1-to-1 with HTTP endpoints ─────────────────
abstract sig OperationKind {}
one sig OpPostTasks, OpGetTasks, OpGetTaskById,
        OpPatchTask, OpDeleteTask, OpGetAudit,
        OpPatchOwner            // special: PATCH body that targets owner_id (FR-006)
  extends OperationKind {}

// ── Caller kinds: auth state × team membership × task ownership ───────────
abstract sig CallerKind {}
one sig CallerMemberOwner,      // authenticated + team member + task owner
        CallerMemberNonOwner,   // authenticated + team member + NOT task owner
        CallerAdmin,            // authenticated + team admin (any task)
        CallerNonMember,        // authenticated but not a member of the task's team
        CallerUnauth            // unauthenticated
  extends CallerKind {}

// ── Permission matrix (singleton carrier) ─────────────────────────────────
one sig PermMatrix {
  Allowed: set CallerKind -> OperationKind
}

// ═══════════════════════════════════════════════════════════════════════════
// § 2  DOMAIN ENTITY SIGS
// ═══════════════════════════════════════════════════════════════════════════

sig User {}
sig Team {}

sig TeamMembership {
  mem_user : one User,
  mem_team : one Team,
  mem_role : one MemberRole
}

sig Task {
  task_team     : one Team,
  task_owner    : one User,
  task_assignee : lone User,
  task_status   : one TaskStatus
}

// DeletedTask ⊆ Task — task row removed but audit entries survive (FR-016)
sig DeletedTask in Task {}

sig AuditEntry {
  ae_task       : one Task,
  ae_team       : one Team,
  ae_actor      : one User,
  ae_actor_role : one MemberRole,
  ae_change     : one ChangeDesc
}

// ═══════════════════════════════════════════════════════════════════════════
// § 3  NAMED FACTS
// ═══════════════════════════════════════════════════════════════════════════

// ── Non-empty universe (all dynamic sigs) ─────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// ── Permission matrix encoding from contracts/http-api.md ─────────────────
// Allowed cells only; all other (CallerKind × OperationKind) pairs are denied.
// CallerNonMember and CallerUnauth appear in NO allowed cell (FR-001, FR-014).
// OpPatchOwner (owner-mutation PATCH) is denied for every caller (FR-006).
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CallerMemberNonOwner -> OpPostTasks)   +
    (CallerMemberNonOwner -> OpGetTasks)    +
    (CallerMemberNonOwner -> OpGetTaskById) +
    (CallerMemberNonOwner -> OpGetAudit)    +
    (CallerMemberOwner    -> OpPostTasks)   +
    (CallerMemberOwner    -> OpGetTasks)    +
    (CallerMemberOwner    -> OpGetTaskById) +
    (CallerMemberOwner    -> OpPatchTask)   +
    (CallerMemberOwner    -> OpDeleteTask)  +
    (CallerMemberOwner    -> OpGetAudit)    +
    (CallerAdmin          -> OpPostTasks)   +
    (CallerAdmin          -> OpGetTasks)    +
    (CallerAdmin          -> OpGetTaskById) +
    (CallerAdmin          -> OpPatchTask)   +
    (CallerAdmin          -> OpDeleteTask)  +
    (CallerAdmin          -> OpGetAudit)
}

// ── Unique team membership: at most one row per (user, team) ──────────────
// data-model.md: composite PK (user_id, team_id) on team_memberships
fact F_UniqueTeamMembership {
  all disj m1, m2: TeamMembership |
    not (m1.mem_user = m2.mem_user and m1.mem_team = m2.mem_team)
}

// ── Task owner is a member of the task's team ─────────────────────────────
// data-model.md: owner_id FK→users, enforced via membership check (FR-004)
fact F_OwnerIsMember {
  all t: Task | some m: TeamMembership |
    m.mem_user = t.task_owner and m.mem_team = t.task_team
}

// ── Task assignee (if set) is a member of the same team ───────────────────
// FR-012, data-model.md validation: assignee_id must be current member of team_id
fact F_AssigneeIsMember {
  all t: Task |
    t.task_assignee != none implies
      (some m: TeamMembership |
        m.mem_user = t.task_assignee and m.mem_team = t.task_team)
}

// ── Audit entry team matches the referenced task's team ───────────────────
// data-model.md: audit_entries.team_id denormalised = tasks.team_id (FR-014/017)
fact F_AuditTeamMatchesTask {
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
}

// ── Every task has exactly one "created" audit entry ──────────────────────
// FR-015: a "created" entry is written atomically with task insertion
fact F_AuditCreatedEntry { /* MUTATED — body cleared by validator */ }

// ── Every deleted task has exactly one "deleted" audit entry ──────────────
// FR-015/FR-016: DELETE handler inserts one "deleted" entry before removing row
fact F_AuditDeletedEntry {
  all t: DeletedTask |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescDeleted
}

// ── Live (non-deleted) tasks have no "deleted" audit entry ────────────────
fact F_AuditNoDeletedForLiveTask {
  all t: Task - DeletedTask |
    no ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescDeleted
}

// ── Audit entries for deleted tasks survive task deletion ─────────────────
// FR-016: task row deleted; audit_entries NOT FK-constrained → entries persist
fact F_AppendOnlyAuditEntries {
  // Every deleted task still has at least its audit entries (no cascade delete)
  all t: DeletedTask | some ae: AuditEntry | ae.ae_task = t
  // No audit entry references a task from a different team
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
}

// ── Audit actor is attributed to a member of the task's team ──────────────
// FR-015: actor_user_id + actor_role are captured from current auth context
fact F_AuditActorAttributed {
  all ae: AuditEntry | some m: TeamMembership |
    m.mem_user = ae.ae_actor and
    m.mem_team = ae.ae_team and
    m.mem_role = ae.ae_actor_role
}

// ── Owner mutation (OpPatchOwner) is denied for every caller ──────────────
// FR-006: owner_id is immutable; validation rejects PATCH body containing it
fact F_OwnerImmutableViaMatrix {
  all ck: CallerKind | (ck -> OpPatchOwner) not in PermMatrix.Allowed
}

// ── Non-member and unauthenticated callers appear in no allowed cell ───────
// FR-001, FR-004, FR-014
fact F_CrossTeamIsolation {
  all op: OperationKind |
    (CallerNonMember -> op) not in PermMatrix.Allowed and
    (CallerUnauth    -> op) not in PermMatrix.Allowed
}

// ── Admin permissions are a strict superset of MemberOwner permissions ─────
// FR-010: admin can do everything a member can, plus edit/delete any task
fact F_AdminSupersetOfMemberOwner {
  { op: OperationKind | (CallerMemberOwner -> op) in PermMatrix.Allowed }
    in { op: OperationKind | (CallerAdmin -> op) in PermMatrix.Allowed }
}

// ── MemberOwner permissions are a strict superset of MemberNonOwner ────────
// FR-008/FR-009: owner can PATCH/DELETE own tasks; non-owner member cannot
fact F_OwnerSupersetOfNonOwner {
  { op: OperationKind | (CallerMemberNonOwner -> op) in PermMatrix.Allowed }
    in { op: OperationKind | (CallerMemberOwner -> op) in PermMatrix.Allowed }
}

// ═══════════════════════════════════════════════════════════════════════════
// § 4  PREDICATES & ASSERTIONS — CATALOGUE PATTERNS
// ═══════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008–FR-011
pred LeastPrivilege {
  // Non-members and unauthenticated callers are denied every operation
  some PermMatrix  // force non-empty universe of PermMatrix
  all op: OperationKind {
    (CallerNonMember -> op) not in PermMatrix.Allowed
    (CallerUnauth    -> op) not in PermMatrix.Allowed
  }
  // Non-owner members are denied PATCH and DELETE
  (CallerMemberNonOwner -> OpPatchTask)  not in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpDeleteTask) not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (CallerKind × OperationKind) cell is either allowed or implicitly denied;
  // no cell is "undefined" — Alloy's closed-world means absence = denied.
  // Positive check: every authenticated team-member can at minimum read tasks and audit.
  some PermMatrix
  (CallerMemberOwner    -> OpGetTaskById) in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpGetTaskById) in PermMatrix.Allowed
  (CallerAdmin          -> OpGetTaskById) in PermMatrix.Allowed
  (CallerMemberOwner    -> OpGetAudit)    in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpGetAudit)    in PermMatrix.Allowed
  (CallerAdmin          -> OpGetAudit)    in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-008/FR-010; contracts/http-api.md
pred PermissionGrounding {
  // Every allowed cell involves an authenticated, team-member caller kind
  // (i.e. no silent grants to CallerNonMember or CallerUnauth)
  some PermMatrix
  no ck: (CallerNonMember + CallerUnauth) |
    some op: OperationKind | (ck -> op) in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010; contracts/http-api.md
pred PrivilegeMonotonicity {
  // Admin allowed ops ⊇ MemberOwner allowed ops ⊇ MemberNonOwner allowed ops
  some PermMatrix
  { op: OperationKind | (CallerMemberNonOwner -> op) in PermMatrix.Allowed }
    in { op: OperationKind | (CallerMemberOwner -> op) in PermMatrix.Allowed }
  { op: OperationKind | (CallerMemberOwner -> op) in PermMatrix.Allowed }
    in { op: OperationKind | (CallerAdmin -> op) in PermMatrix.Allowed }
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  // Unauthenticated caller is denied every operation
  some PermMatrix
  all op: OperationKind | (CallerUnauth -> op) not in PermMatrix.Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry
pred AuditCompleteness {
  // Every task has exactly one "created" entry
  some Task
  all t: Task |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescCreated
  // Every deleted task has exactly one "deleted" entry
  all t: DeletedTask |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescDeleted
  // Live tasks have no "deleted" entry
  all t: Task - DeletedTask |
    no ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescDeleted
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // Every deleted task still has at least one audit entry (entries survive row deletion)
  some Task
  all t: DeletedTask | some ae: AuditEntry | ae.ae_task = t
  // All audit entries reference their task's correct team (entries not orphaned/mutated)
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_role snapshot
pred AttributionCorrectness {
  // Every audit entry's actor has a team membership matching the entry's team and role
  some AuditEntry
  all ae: AuditEntry | some m: TeamMembership |
    m.mem_user = ae.ae_actor and
    m.mem_team = ae.ae_team and
    m.mem_role = ae.ae_actor_role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005/FR-006; data-model.md tasks.owner_id
pred OwnershipExclusivity {
  // Every task has exactly one owner (lone field on owner is enforced by 'one' type)
  some Task
  all t: Task | one t.task_owner
  // Every task has exactly one team
  all t: Task | one t.task_team
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/FR-009/FR-010; contracts/http-api.md
pred OwnershipBasedAccess {
  // Owner-or-admin operations (PATCH, DELETE) are NOT available to non-owner members
  some PermMatrix
  (CallerMemberNonOwner -> OpPatchTask)  not in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpDeleteTask) not in PermMatrix.Allowed
  // But owner can PATCH and DELETE
  (CallerMemberOwner -> OpPatchTask)  in PermMatrix.Allowed
  (CallerMemberOwner -> OpDeleteTask) in PermMatrix.Allowed
  // And admin can PATCH and DELETE
  (CallerAdmin -> OpPatchTask)  in PermMatrix.Allowed
  (CallerAdmin -> OpDeleteTask) in PermMatrix.Allowed
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md §Byte-equivalent not-found
pred NoInformationLeakage {
  // Cross-team and unauthenticated callers are denied all task-scoped operations
  // (they receive a uniform 404/401, not a distinguishing response)
  some PermMatrix
  (CallerNonMember -> OpGetTaskById) not in PermMatrix.Allowed
  (CallerNonMember -> OpPatchTask)   not in PermMatrix.Allowed
  (CallerNonMember -> OpDeleteTask)  not in PermMatrix.Allowed
  (CallerNonMember -> OpGetAudit)    not in PermMatrix.Allowed
  (CallerUnauth    -> OpGetTaskById) not in PermMatrix.Allowed
  (CallerUnauth    -> OpPatchTask)   not in PermMatrix.Allowed
  (CallerUnauth    -> OpDeleteTask)  not in PermMatrix.Allowed
  (CallerUnauth    -> OpGetAudit)    not in PermMatrix.Allowed
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002; contracts/http-api.md §400 validation_error
pred ValidationBeforeMutation {
  // Owner-mutation PATCH (OpPatchOwner) is denied for every caller kind —
  // validation blocks it before any state change occurs
  some PermMatrix
  all ck: CallerKind | (ck -> OpPatchOwner) not in PermMatrix.Allowed
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ═══════════════════════════════════════════════════════════════════════════
// § 5  PREDICATES & ASSERTIONS — FEATURE-SPECIFIC (per FR-NNN)
// ═══════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some PermMatrix
  all op: OperationKind | (CallerUnauth -> op) not in PermMatrix.Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 / FR-003 team-context gate
pred FR_004_NonMemberDenied {
  some PermMatrix
  all op: OperationKind | (CallerNonMember -> op) not in PermMatrix.Allowed
}
assert FR_004_NonMemberDenied { FR_004_NonMemberDenied }
check FR_004_NonMemberDenied for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005; data-model.md tasks.team_id immutable after insert
pred FR_005_TaskBelongsToOneTeam {
  some Task
  all t: Task | one t.task_team
}
assert FR_005_TaskBelongsToOneTeam { FR_005_TaskBelongsToOneTeam }
check FR_005_TaskBelongsToOneTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006; data-model.md owner_id immutable; contracts/http-api.md OpPatchOwner
pred FR_006_OwnerImmutable {
  some PermMatrix
  // OpPatchOwner must not appear in any caller's allowed set
  all ck: CallerKind | (ck -> OpPatchOwner) not in PermMatrix.Allowed
  // Every task has exactly one owner
  some Task
  all t: Task | one t.task_owner
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007; data-model.md TeamMembership composite PK
pred FR_007_PerTeamRole {
  // A user can hold different roles in different teams
  some m1, m2: TeamMembership |
    m1.mem_user = m2.mem_user and
    m1.mem_team != m2.mem_team and
    m1.mem_role != m2.mem_role
  // At most one membership row per (user, team)
  all disj x, y: TeamMembership |
    not (x.mem_user = y.mem_user and x.mem_team = y.mem_team)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; contracts/http-api.md — member can create and read
pred FR_008_MemberCanCreateAndRead {
  some PermMatrix
  (CallerMemberNonOwner -> OpPostTasks)   in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpGetTasks)    in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpGetTaskById) in PermMatrix.Allowed
  (CallerMemberOwner    -> OpPostTasks)   in PermMatrix.Allowed
  (CallerMemberOwner    -> OpGetTasks)    in PermMatrix.Allowed
  (CallerMemberOwner    -> OpGetTaskById) in PermMatrix.Allowed
}
assert FR_008_MemberCanCreateAndRead { FR_008_MemberCanCreateAndRead }
check FR_008_MemberCanCreateAndRead for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009; contracts/http-api.md — non-owner member cannot edit/delete
pred FR_009_NonOwnerMemberCannotEditDelete {
  some PermMatrix
  (CallerMemberNonOwner -> OpPatchTask)  not in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpDeleteTask) not in PermMatrix.Allowed
}
assert FR_009_NonOwnerMemberCannotEditDelete { FR_009_NonOwnerMemberCannotEditDelete }
check FR_009_NonOwnerMemberCannotEditDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010; contracts/http-api.md — admin can edit/delete any task
pred FR_010_AdminCanEditDeleteAny {
  some PermMatrix
  (CallerAdmin -> OpPatchTask)  in PermMatrix.Allowed
  (CallerAdmin -> OpDeleteTask) in PermMatrix.Allowed
}
assert FR_010_AdminCanEditDeleteAny { FR_010_AdminCanEditDeleteAny }
check FR_010_AdminCanEditDeleteAny for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011/FR-014; spec.md cross-team isolation invariant
pred FR_011_CrossTeamIsolation {
  some PermMatrix
  all op: OperationKind {
    (CallerNonMember -> op) not in PermMatrix.Allowed
    (CallerUnauth    -> op) not in PermMatrix.Allowed
  }
}
assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md assignee_id membership constraint
pred FR_012_AssigneeInSameTeam {
  some Task
  all t: Task |
    t.task_assignee != none implies
      (some m: TeamMembership |
        m.mem_user = t.task_assignee and m.mem_team = t.task_team)
}
assert FR_012_AssigneeInSameTeam { FR_012_AssigneeInSameTeam }
check FR_012_AssigneeInSameTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015; spec.md per-edit-event audit entry shape
pred FR_015_AuditPerSave {
  some Task
  // Every task has exactly one "created" entry
  all t: Task |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescCreated
  // Audit team always matches task team
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
  // Actor is attributed with a role via a membership
  all ae: AuditEntry | some m: TeamMembership |
    m.mem_user = ae.ae_actor and
    m.mem_team = ae.ae_team and
    m.mem_role = ae.ae_actor_role
}
assert FR_015_AuditPerSave { FR_015_AuditPerSave }
check FR_015_AuditPerSave for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016; spec.md audit append-only; data-model.md no FK cascade
pred FR_016_AuditAppendOnly {
  // Deleted tasks still have at least their audit entries
  some Task
  all t: DeletedTask | some ae: AuditEntry | ae.ae_task = t
  // No live task has a "deleted" audit entry
  all t: Task - DeletedTask |
    no ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescDeleted
  // Every deleted task has exactly one "deleted" audit entry
  all t: DeletedTask |
    one ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescDeleted
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017; spec.md audit readable by any team member
pred FR_017_AuditReadableByAnyMember {
  some PermMatrix
  // All authenticated team-member caller kinds can access the audit endpoint
  (CallerMemberOwner    -> OpGetAudit) in PermMatrix.Allowed
  (CallerMemberNonOwner -> OpGetAudit) in PermMatrix.Allowed
  (CallerAdmin          -> OpGetAudit) in PermMatrix.Allowed
  // Non-members and unauth cannot
  (CallerNonMember -> OpGetAudit) not in PermMatrix.Allowed
  (CallerUnauth    -> OpGetAudit) not in PermMatrix.Allowed
}
assert FR_017_AuditReadableByAnyMember { FR_017_AuditReadableByAnyMember }
check FR_017_AuditReadableByAnyMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014; spec.md US6 — admin in team T has no access to team-U tasks
pred FR_014_AdminPrivilegeDoesNotCrossTeam {
  // Even CallerAdmin is denied operations when they are "NonMember" of the target team.
  // In the model: CallerAdmin only covers admin within the SAME team (cross-team
  // requests resolve to CallerNonMember regardless of admin status in another team).
  // We check: CallerNonMember is denied all task-scoped operations.
  some PermMatrix
  (CallerNonMember -> OpGetTaskById) not in PermMatrix.Allowed
  (CallerNonMember -> OpPatchTask)   not in PermMatrix.Allowed
  (CallerNonMember -> OpDeleteTask)  not in PermMatrix.Allowed
  (CallerNonMember -> OpGetAudit)    not in PermMatrix.Allowed
}
assert FR_014_AdminPrivilegeDoesNotCrossTeam { FR_014_AdminPrivilegeDoesNotCrossTeam }
check FR_014_AdminPrivilegeDoesNotCrossTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 actor-role snapshot; data-model.md actor_role NOT NULL
pred FR_015_ActorRoleSnapshotted {
  // Every audit entry carries a concrete role (member or admin) matching a real membership
  some AuditEntry
  all ae: AuditEntry |
    (ae.ae_actor_role = RoleMember or ae.ae_actor_role = RoleAdmin) and
    (some m: TeamMembership |
      m.mem_user = ae.ae_actor and
      m.mem_team = ae.ae_team and
      m.mem_role = ae.ae_actor_role)
}
assert FR_015_ActorRoleSnapshotted { FR_015_ActorRoleSnapshotted }
check FR_015_ActorRoleSnapshotted for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MissingCreatedAudit { some t: Task | no ae: AuditEntry | ae.ae_task = t and ae.ae_change = DescCreated }
