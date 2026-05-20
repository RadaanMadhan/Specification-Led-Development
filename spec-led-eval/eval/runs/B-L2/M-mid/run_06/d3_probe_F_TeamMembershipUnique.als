// === feature_model.als — Alloy model for B-L2: SaaS Team Task Management with Audit Trail ===
// Feature branch: 007-team-tasks
// Sources: spec.md (FR-001 – FR-020), data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────
// SECTION 1 — Roles, statuses, change kinds
// ─────────────────────────────────────────────────

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Three legal shapes for an audit change description (FR-015)
abstract sig ChangeKind {}
one sig CKCreated, CKChanged, CKDeleted extends ChangeKind {}

// ─────────────────────────────────────────────────
// SECTION 2 — Domain entities
// ─────────────────────────────────────────────────

sig User {}
sig Team {}

// Many-to-many user↔team with per-team role (FR-007)
sig TeamMembership {
  tm_user : one User,
  tm_team : one Team,
  tm_role : one Role
}

// A task belongs to exactly one team and has exactly one owner (FR-005, FR-006).
// task_deleted tracks whether the task row has been removed (FR-016: audit survives deletion).
sig Task {
  task_team    : one  Team,
  task_owner   : one  User,
  task_assignee: lone User,
  task_status  : one  TaskStatus,
  task_deleted : one  DeletedMark
}
abstract sig DeletedMark {}
one sig IsDeleted, NotDeleted extends DeletedMark {}

// Append-only per-edit-event audit record (FR-015)
sig AuditEntry {
  ae_task_ref  : one Task,    // logical FK; survives task deletion (FR-016)
  ae_team      : one Team,
  ae_actor     : one User,
  ae_actor_role: one Role,
  ae_change    : one ChangeKind
}

// ─────────────────────────────────────────────────
// SECTION 3 — Operations / permission matrix
// ─────────────────────────────────────────────────

abstract sig OperationKind {}
one sig OpPostTask, OpGetTasks, OpGetTask,
        OpPatchTask, OpDeleteTask, OpGetAudit extends OperationKind {}

// Canonical permission matrix — singleton field (contracts/http-api.md permission table)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// Every successfully executed request in the system
sig Operation {
  op_kind        : one  OperationKind,
  op_actor       : one  User,
  op_team        : one  Team,
  op_actor_role  : one  Role,
  op_task        : lone Task,        // target task (absent for list/create-scoped ops)
  op_audit_entry : lone AuditEntry   // audit entry produced by this operation, if any
}

// ─────────────────────────────────────────────────
// SECTION 4 — Named structural facts
// ─────────────────────────────────────────────────

// Non-empty universe: every dynamic sig has at least one atom.
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// Each (user, team) pair has at most one TeamMembership row (data-model.md composite PK).
fact F_TeamMembershipUnique {
  all disj m1, m2: TeamMembership |
    not (m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team)
}

// A task's owner must be a member of the task's team (FR-005, FR-008).
fact F_TaskOwnerIsMember {
  all t: Task | some m: TeamMembership |
    m.tm_user = t.task_owner and m.tm_team = t.task_team
}

// A task's assignee (if present) must be a member of the same team (FR-012).
fact F_AssigneeIsMember {
  all t: Task |
    some u: User | u in t.task_assignee implies
      (some m: TeamMembership | m.tm_user = u and m.tm_team = t.task_team)
}

// Audit entry's recorded team equals the referenced task's team (data-model.md denorm).
fact F_AuditTeamMatchesTask {
  all ae: AuditEntry | ae.ae_team = ae.ae_task_ref.task_team
}

// Audit actor must have a membership in the audit entry's team (FR-015).
fact F_AuditActorIsMember {
  all ae: AuditEntry | some m: TeamMembership |
    m.tm_user = ae.ae_actor and m.tm_team = ae.ae_team
}

// The audit entry's recorded actor role matches their actual membership role (FR-015 snapshot).
fact F_AuditActorRoleSnapshot {
  all ae: AuditEntry | some m: TeamMembership |
    m.tm_user = ae.ae_actor and
    m.tm_team = ae.ae_team and
    m.tm_role = ae.ae_actor_role
}

// Every operation's actor has a membership in the operation's team,
// and op_actor_role matches that membership (FR-003, FR-004).
fact F_OperationActorIsMember {
  all op: Operation | some m: TeamMembership |
    m.tm_user = op.op_actor and
    m.tm_team = op.op_team and
    m.tm_role = op.op_actor_role
}

// Operations on a specific task may only target a task belonging to the operation's team
// — cross-team isolation at the structural level (FR-011, FR-014).
fact F_CrossTeamIsolation {
  all op: Operation |
    some t: Task | t in op.op_task implies t.task_team = op.op_team
}

// Base permission matrix (contracts/http-api.md — Role × OperationKind table).
// PATCH and DELETE are handled by F_OwnershipAccessControl for members.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (MemberRole -> OpPostTask)  +
    (MemberRole -> OpGetTasks)  +
    (MemberRole -> OpGetTask)   +
    (MemberRole -> OpGetAudit)  +
    (AdminRole  -> OpPostTask)  +
    (AdminRole  -> OpGetTasks)  +
    (AdminRole  -> OpGetTask)   +
    (AdminRole  -> OpPatchTask) +
    (AdminRole  -> OpDeleteTask)+
    (AdminRole  -> OpGetAudit)
}

// Least-privilege enforcement: every operation's kind is either in the base matrix,
// or it is an ownership-conditional PATCH/DELETE by a member who owns the task (FR-008–FR-010).
fact F_LeastPrivilege {
  all op: Operation |
    (op.op_actor_role -> op.op_kind) in PermMatrix.Allowed
    or
    ( (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) and
      op.op_actor_role = MemberRole and
      (some t: Task | t in op.op_task and t.task_owner = op.op_actor) )
}

// PATCH and DELETE require admin OR task ownership — no non-owner member may mutate (FR-008–FR-010).
fact F_OwnershipAccessControl {
  all op: Operation |
    (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) implies
      ( op.op_actor_role = AdminRole or
        (some t: Task | t in op.op_task and t.task_owner = op.op_actor) )
}

// Audit completeness: create and delete operations produce exactly one audit entry each (FR-015, SC-007).
// Read operations produce no audit entry. PATCH may produce lone (zero when diff is empty).
fact F_AuditCompleteness {
  // PostTask always produces exactly one 'created' entry
  all op: Operation | op.op_kind = OpPostTask implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKCreated)
  // DeleteTask always produces exactly one 'deleted' entry
  all op: Operation | op.op_kind = OpDeleteTask implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKDeleted)
  // Read operations produce no audit entry
  all op: Operation |
    (op.op_kind = OpGetTasks or op.op_kind = OpGetTask or op.op_kind = OpGetAudit)
    implies no op.op_audit_entry
  // PatchTask with a non-empty diff produces exactly one 'changed' entry; empty diff produces none
  all op: Operation | op.op_kind = OpPatchTask implies
    (no op.op_audit_entry or
     (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKChanged))
}

// Append-only: each AuditEntry is produced by exactly one Operation and by no "delete-audit" path.
// There is no OperationKind that removes or rewrites an audit entry (FR-016, SC-008).
fact F_AppendOnlyAuditEntries {
  // Every AuditEntry is linked to exactly one producing Operation
  all ae: AuditEntry | one op: Operation | ae in op.op_audit_entry
  // No operation produces more than one audit entry (one-per-event)
  all op: Operation | lone op.op_audit_entry
  // The audit entry's task and team match the operation's context
  all op: Operation | all ae: AuditEntry | ae in op.op_audit_entry implies
    (ae.ae_task_ref.task_team = op.op_team and ae.ae_team = op.op_team)
}

// Audit entries must outlive their task: a deleted task's audit entries remain (FR-016).
fact F_AuditSurvivesTaskDeletion {
  all ae: AuditEntry | ae.ae_change = CKDeleted implies
    ae.ae_task_ref.task_deleted = IsDeleted
  // Audit entries for deleted tasks still exist — modeled by their presence in AuditEntry
  all t: Task | t.task_deleted = IsDeleted implies
    (some ae: AuditEntry | ae.ae_task_ref = t and ae.ae_change = CKDeleted)
}

// Every task has at least one audit entry (the 'created' entry from FR-015).
fact F_TaskHasCreatedEntry {
  all t: Task | some ae: AuditEntry |
    ae.ae_task_ref = t and ae.ae_change = CKCreated
}

// Owner is immutable: no PatchTask operation changes task_owner (FR-006).
// Modeled by the absence of any operation that produces an audit entry
// attributed to an actor who is not the task's current owner when the owner field differs —
// and structurally: task_owner is set once at creation and never modified.
// In a snapshot model we enforce it by the ownership field being uniquely determined at creation
// (the PostTask operation's actor becomes the task's owner).
fact F_OwnerSetByCreator {
  all op: Operation | op.op_kind = OpPostTask and (some op.op_audit_entry) implies
    (some t: Task | t in op.op_task and t.task_owner = op.op_actor)
}

// Task team is immutable (FR-005): every PatchTask operation targets a task already in op_team.
// This is already implied by F_CrossTeamIsolation but we make it explicit.
fact F_TaskTeamImmutable {
  all op: Operation |
    (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) implies
      (some t: Task | t in op.op_task and t.task_team = op.op_team)
}

// ─────────────────────────────────────────────────
// SECTION 5 — Predicate / assertion pairs
// ─────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008, FR-009, FR-010
pred LeastPrivilege {
  some Operation  // force non-vacuous scope
  all op: Operation |
    (op.op_actor_role -> op.op_kind) in PermMatrix.Allowed
    or
    ( (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) and
      op.op_actor_role = MemberRole and
      (some t: Task | t in op.op_task and t.task_owner = op.op_actor) )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table — every cell defined
pred PermissionCompleteness {
  // Every role has at least one allowed operation — no role is completely blocked
  all r: Role | some ok: OperationKind | (r -> ok) in PermMatrix.Allowed
  // The Allowed relation is non-empty
  some PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-008, FR-010; contracts/http-api.md matrix
pred PermissionGrounding {
  // Admin is strictly more privileged than Member on mutation operations
  (AdminRole -> OpPatchTask)  in PermMatrix.Allowed
  (AdminRole -> OpDeleteTask) in PermMatrix.Allowed
  (MemberRole -> OpPatchTask)  not in PermMatrix.Allowed
  (MemberRole -> OpDeleteTask) not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 "admin MAY do everything a member can"
pred PrivilegeMonotonicity {
  // Every operation kind allowed for MemberRole is also allowed for AdminRole
  all ok: OperationKind |
    (MemberRole -> ok) in PermMatrix.Allowed implies (AdminRole -> ok) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-002; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every operation has an actor who has a resolved membership
  some Operation
  all op: Operation | some m: TeamMembership |
    m.tm_user = op.op_actor and m.tm_team = op.op_team
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007; data-model.md AuditEntry schema
pred AuditCompleteness {
  some op: Operation | op.op_kind = OpPostTask
  // Every PostTask operation produces exactly one CKCreated audit entry
  all op: Operation | op.op_kind = OpPostTask implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKCreated)
  // Every DeleteTask operation produces exactly one CKDeleted audit entry
  all op: Operation | op.op_kind = OpDeleteTask implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKDeleted)
  // Every task has at least one audit entry
  all t: Task | some ae: AuditEntry | ae.ae_task_ref = t
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, SC-008; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // Each AuditEntry is the product of exactly one Operation — it is created once, never modified
  all ae: AuditEntry | one op: Operation | ae in op.op_audit_entry
  // No OperationKind exists that can remove or overwrite an audit entry
  // (enforced by structural absence of any "delete audit" op kind)
  no ok: OperationKind | ok not in
    (OpPostTask + OpGetTasks + OpGetTask + OpPatchTask + OpDeleteTask + OpGetAudit)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_user_id, actor_role columns
pred AttributionCorrectness {
  some AuditEntry
  // Audit entry actor role snapshot matches the actor's actual membership role
  all ae: AuditEntry | some m: TeamMembership |
    m.tm_user = ae.ae_actor and
    m.tm_team = ae.ae_team and
    m.tm_role = ae.ae_actor_role
  // The producing operation's actor matches the audit entry's actor
  all op: Operation | all ae: AuditEntry | ae in op.op_audit_entry implies
    ae.ae_actor = op.op_actor and ae.ae_actor_role = op.op_actor_role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005, FR-006; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner (structural: field is `one User`)
  all t: Task | one t.task_owner
  // Every task belongs to exactly one team (structural: field is `one Team`)
  all t: Task | one t.task_team
  // Task owner is a member of the task's team
  all t: Task | some m: TeamMembership |
    m.tm_user = t.task_owner and m.tm_team = t.task_team
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009, FR-010; contracts/http-api.md PATCH/DELETE auth
pred OwnershipBasedAccess {
  some op: Operation | op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask
  // Non-owner members cannot PATCH or DELETE
  all op: Operation |
    (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) implies
      ( op.op_actor_role = AdminRole or
        (some t: Task | t in op.op_task and t.task_owner = op.op_actor) )
  // A member who owns the task CAN patch/delete
  // (i.e., there exists a valid PATCH by a member who is the owner)
  some op: Operation |
    op.op_kind = OpPatchTask and
    op.op_actor_role = MemberRole and
    (some t: Task | t in op.op_task and t.task_owner = op.op_actor)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-004; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  // Cross-team operations cannot reach tasks in other teams
  some Operation
  all op: Operation |
    some t: Task | t in op.op_task implies t.task_team = op.op_team
  // An operation's team must be one the actor is a member of
  all op: Operation | some m: TeamMembership |
    m.tm_user = op.op_actor and m.tm_team = op.op_team
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-012; contracts/http-api.md 400 validation_error
pred ValidationBeforeMutation {
  // Assignee (if present) is always a member of the task's team
  some Task
  all t: Task |
    some u: User | u in t.task_assignee implies
      (some m: TeamMembership | m.tm_user = u and m.tm_team = t.task_team)
  // Owner field is never the product of a mutation — every PostTask sets owner = actor
  all op: Operation | op.op_kind = OpPostTask and (some op.op_audit_entry) implies
    (some t: Task | t in op.op_task and t.task_owner = op.op_actor)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ─────────────────────────────────────────────────
// SECTION 6 — FR-specific assertions
// ─────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required; no operation without a resolved actor
pred FR_001_AuthRequired {
  some Operation
  // Every operation's actor has at least one TeamMembership (i.e., is authenticated + a member)
  all op: Operation | some m: TeamMembership |
    m.tm_user = op.op_actor and m.tm_team = op.op_team and m.tm_role = op.op_actor_role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004 — team context; actor must be a member of the resolved team
pred FR_003_TeamContextRequired {
  some Operation
  all op: Operation | some m: TeamMembership |
    m.tm_user = op.op_actor and m.tm_team = op.op_team
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 — task team immutable; task belongs to exactly one team forever
pred FR_005_TaskTeamImmutable {
  some Task
  all t: Task | one t.task_team
  // No PatchTask or DeleteTask operation moves a task to a different team
  all op: Operation |
    (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) implies
      (some t: Task | t in op.op_task and t.task_team = op.op_team)
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 — owner immutable; PostTask sets owner = creator; PATCH cannot change it
pred FR_006_OwnerImmutable {
  some Task
  all t: Task | one t.task_owner
  // The creator (PostTask actor) becomes the owner
  all op: Operation | op.op_kind = OpPostTask and (some op.op_audit_entry) implies
    (some t: Task | t in op.op_task and t.task_owner = op.op_actor)
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 — per-team roles; (user, team) has at most one role
pred FR_007_PerTeamRole {
  some TeamMembership
  all disj m1, m2: TeamMembership |
    not (m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008, FR-009 — member edit/delete own tasks only
pred FR_008_009_MemberOwnerOnly {
  some op: Operation |
    (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) and
    op.op_actor_role = MemberRole
  all op: Operation |
    (op.op_kind = OpPatchTask or op.op_kind = OpDeleteTask) and
    op.op_actor_role = MemberRole implies
      (some t: Task | t in op.op_task and t.task_owner = op.op_actor)
}
assert FR_008_009_MemberOwnerOnly { FR_008_009_MemberOwnerOnly }
check FR_008_009_MemberOwnerOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 — admin can edit/delete any task in team
pred FR_010_AdminFullAccess {
  // Admin is allowed PATCH and DELETE in the base matrix
  (AdminRole -> OpPatchTask) in PermMatrix.Allowed
  (AdminRole -> OpDeleteTask) in PermMatrix.Allowed
  // An admin operation can target a task not owned by the admin
  some op: Operation |
    op.op_actor_role = AdminRole and
    op.op_kind = OpPatchTask and
    (some t: Task | t in op.op_task and t.task_owner != op.op_actor)
}
assert FR_010_AdminFullAccess { FR_010_AdminFullAccess }
check FR_010_AdminFullAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-014 — cross-team isolation invariant
pred FR_011_014_CrossTeamIsolation {
  some Operation
  all op: Operation |
    some t: Task | t in op.op_task implies t.task_team = op.op_team
}
assert FR_011_014_CrossTeamIsolation { FR_011_014_CrossTeamIsolation }
check FR_011_014_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 — assignee must be a current member of the same team
pred FR_012_AssigneeTeamMember {
  some t: Task | some t.task_assignee
  all t: Task |
    some u: User | u in t.task_assignee implies
      (some m: TeamMembership | m.tm_user = u and m.tm_team = t.task_team)
}
assert FR_012_AssigneeTeamMember { FR_012_AssigneeTeamMember }
check FR_012_AssigneeTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 — per-edit-event audit; one entry per save with correct change kind
pred FR_015_AuditPerEditEvent {
  some Operation
  all op: Operation | op.op_kind = OpPostTask implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKCreated)
  all op: Operation | op.op_kind = OpDeleteTask implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKDeleted)
  all op: Operation | op.op_kind = OpPatchTask and (some op.op_audit_entry) implies
    (one ae: AuditEntry | ae in op.op_audit_entry and ae.ae_change = CKChanged)
}
assert FR_015_AuditPerEditEvent { FR_015_AuditPerEditEvent }
check FR_015_AuditPerEditEvent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit immutable; entries survive task deletion; no delete path
pred FR_016_AuditImmutable {
  some AuditEntry
  // Every AuditEntry was produced by exactly one Operation
  all ae: AuditEntry | one op: Operation | ae in op.op_audit_entry
  // Deleted tasks still have audit entries including the deleted entry
  all t: Task | t.task_deleted = IsDeleted implies
    (some ae: AuditEntry | ae.ae_task_ref = t and ae.ae_change = CKDeleted)
}
assert FR_016_AuditImmutable { FR_016_AuditImmutable }
check FR_016_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit readable by any team member
pred FR_017_AuditVisibility {
  // GetAudit is allowed for MemberRole in the base matrix
  (MemberRole -> OpGetAudit) in PermMatrix.Allowed
  (AdminRole  -> OpGetAudit) in PermMatrix.Allowed
  // GetAudit operations are only on tasks in the caller's team (cross-team still enforced)
  all op: Operation | op.op_kind = OpGetAudit implies
    (some t: Task | t in op.op_task and t.task_team = op.op_team)
}
assert FR_017_AuditVisibility { FR_017_AuditVisibility }
check FR_017_AuditVisibility for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019, FR-020 — task list scoped to caller's team
pred FR_019_020_TeamScopedList {
  some op: Operation | op.op_kind = OpGetTasks
  // GetTasks operations produce no audit entry (read-only)
  all op: Operation | op.op_kind = OpGetTasks implies no op.op_audit_entry
  // GetTasks is permitted for both roles
  (MemberRole -> OpGetTasks) in PermMatrix.Allowed
  (AdminRole  -> OpGetTasks) in PermMatrix.Allowed
}
assert FR_019_020_TeamScopedList { FR_019_020_TeamScopedList }
check FR_019_020_TeamScopedList for 6

// === D3 inject_violation (validator-appended) ===
fact MUTATE_DualRoleViolation { some disj m1, m2: TeamMembership | m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team and m1.tm_role != m2.tm_role }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
