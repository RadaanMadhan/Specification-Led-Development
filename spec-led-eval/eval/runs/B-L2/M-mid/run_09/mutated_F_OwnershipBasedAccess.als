// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature folder: B-L2  (spec branch 007-team-tasks)
// Spec date: 2026-05-17
// Patterns applied: LeastPrivilege, PermissionCompleteness, PrivilegeMonotonicity,
//   AuthRequiredEverywhere, AuditCompleteness, AppendOnly, AttributionCorrectness,
//   OwnershipExclusivity, OwnershipBasedAccess, NoInformationLeakage,
//   ValidationBeforeMutation
// Feature-specific predicates: FR_005_TaskTeamImmutability, FR_006_OwnerImmutability,
//   FR_007_PerTeamRole, FR_014_CrossTeamIsolation, FR_015_AuditPerSave,
//   FR_016_AuditOutlivesTask, FR_017_AuditReadableByTeamMember

// ════════════════════════════════════════════════════════════════════════════
// Core vocabulary sigs
// ════════════════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// The six HTTP-API endpoints
abstract sig OperationKind {}
one sig PostTasks, GetTaskList, GetTaskById, PatchTask, DeleteTask, GetAudit
  extends OperationKind {}

// Permission matrix encoded as a field on a singleton sig (canonical pattern)
one sig PermMatrix { Allowed: set Role -> OperationKind }

sig User {}
sig Team {}

// TeamMembership: the (user, team, role) join table; composite PK (user, team)
sig TeamMembership {
  memUser : one User,
  memTeam : one Team,
  memRole : one Role
}

// Tasks live in exactly one team; abstract because we distinguish active/deleted
abstract sig Task {
  taskTeam     : one Team,
  taskOwner    : one User,
  taskAssignee : lone User,
  taskStatus   : one TaskStatus
}
sig ActiveTask  extends Task {}
sig DeletedTask extends Task {}

// Audit-entry change-kind vocabulary
abstract sig ChangeKind {}
one sig AuditCreated, AuditDeleted extends ChangeKind {}
sig AuditChanged extends ChangeKind {}   // represents "changed <fields>"

// Audit entries survive task deletion (no FK cascade on task_id)
sig AuditEntry {
  aeTask      : one Task,
  aeTeam      : one Team,
  aeActor     : one User,
  aeActorRole : one Role,
  aeChange    : one ChangeKind
}

// Operations: authenticated, team-context-resolved API calls that reach business logic
sig Operation {
  opKind       : one OperationKind,
  opCaller     : one User,
  opTeam       : one Team,
  opCallerRole : one Role,
  opTask       : lone Task      // absent for PostTasks and GetTaskList
}

// A MutationEvent is a successfully-committed write paired with its single audit entry
sig MutationEvent {
  mutOp    : one Operation,
  mutAudit : one AuditEntry
}

// ════════════════════════════════════════════════════════════════════════════
// F_NonEmptyUniverse — ensure dynamic sigs are inhabited so quantifiers bite
// ════════════════════════════════════════════════════════════════════════════
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some ActiveTask
  some DeletedTask
  some AuditChanged
  some AuditEntry
  some Operation
  some MutationEvent
}

// ════════════════════════════════════════════════════════════════════════════
// F_PermissionMatrix — unconditional (Role × OperationKind) grants
// contracts/http-api.md permission matrix; FR-008, FR-009, FR-010
// Member unconditional: PostTasks, GetTaskList, GetTaskById, GetAudit
// Admin unconditional : all six (PATCH/DELETE conditional on ownership only for Member)
// ════════════════════════════════════════════════════════════════════════════
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (MemberRole -> PostTasks)   +
      (MemberRole -> GetTaskList) +
      (MemberRole -> GetTaskById) +
      (MemberRole -> GetAudit)    +
      (AdminRole  -> PostTasks)   +
      (AdminRole  -> GetTaskList) +
      (AdminRole  -> GetTaskById) +
      (AdminRole  -> PatchTask)   +
      (AdminRole  -> DeleteTask)  +
      (AdminRole  -> GetAudit)
}

// ════════════════════════════════════════════════════════════════════════════
// F_UniqueTeamMembership — composite PK (user_id, team_id)
// data-model.md TeamMembership PRIMARY KEY (user_id, team_id)
// ════════════════════════════════════════════════════════════════════════════
fact F_UniqueTeamMembership {
  all disj m1, m2: TeamMembership |
    not (m1.memUser = m2.memUser and m1.memTeam = m2.memTeam)
}

// ════════════════════════════════════════════════════════════════════════════
// F_OperationCallerIsMember — auth+team-context boundary guarantees the caller
// is a current member of the operation's team with the stated role (FR-003/FR-004)
// ════════════════════════════════════════════════════════════════════════════
fact F_OperationCallerIsMember {
  all op: Operation |
    some m: TeamMembership |
      m.memUser = op.opCaller and
      m.memTeam = op.opTeam   and
      m.memRole = op.opCallerRole
}

// ════════════════════════════════════════════════════════════════════════════
// F_TaskOwnerIsMember — task owner is a member of the task's team (FR-005/FR-006)
// ════════════════════════════════════════════════════════════════════════════
fact F_TaskOwnerIsMember {
  all t: Task |
    some m: TeamMembership |
      m.memUser = t.taskOwner and m.memTeam = t.taskTeam
}

// ════════════════════════════════════════════════════════════════════════════
// F_AssigneeIsTeamMember — assignee (if any) must be a member of the task's team
// data-model.md assignee validation; FR-012
// ════════════════════════════════════════════════════════════════════════════
fact F_AssigneeIsTeamMember {
  all t: Task |
    (some t.taskAssignee) implies
      (some m: TeamMembership | m.memUser = t.taskAssignee and m.memTeam = t.taskTeam)
}

// ════════════════════════════════════════════════════════════════════════════
// F_AuditEntryTeamConsistency — audit entry's team = the referenced task's team
// data-model.md AuditEntry.team_id (denormalised for isolation queries)
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditEntryTeamConsistency {
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// ════════════════════════════════════════════════════════════════════════════
// F_AuditEntryActorIsMember — actor in every audit entry was a member of the
// entry's team with the snapshotted role (FR-015 attribution)
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditEntryActorIsMember {
  all ae: AuditEntry |
    some m: TeamMembership |
      m.memUser = ae.aeActor and
      m.memTeam = ae.aeTeam  and
      m.memRole = ae.aeActorRole
}

// ════════════════════════════════════════════════════════════════════════════
// F_EachTaskHasCreatedEntry — every task has exactly one AuditCreated entry
// FR-015; spec.md US1 acceptance scenario 1
// ════════════════════════════════════════════════════════════════════════════
fact F_EachTaskHasCreatedEntry {
  all t: Task |
    one ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditCreated
}

// ════════════════════════════════════════════════════════════════════════════
// F_AppendOnlyAudit — deleted tasks have exactly one AuditDeleted entry
// (audit entries outlive the task row); active tasks have none.
// FR-016; spec.md US3; data-model.md "no ON DELETE CASCADE on audit_entries.task_id"
// ════════════════════════════════════════════════════════════════════════════
fact F_AppendOnlyAudit {
  all t: DeletedTask |
    one ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditDeleted
  all t: ActiveTask |
    no ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditDeleted
}

// ════════════════════════════════════════════════════════════════════════════
// F_OwnerImmutability — the actor of a task's AuditCreated entry is the task's
// owner (owner set at creation, immutable thereafter; FR-006)
// ════════════════════════════════════════════════════════════════════════════
fact F_OwnerImmutability {
  all t: Task |
    all ae: AuditEntry |
      (ae.aeTask = t and ae.aeChange = AuditCreated) implies ae.aeActor = t.taskOwner
}

// ════════════════════════════════════════════════════════════════════════════
// F_OwnershipBasedAccess — a MemberRole caller may only PatchTask/DeleteTask
// a task they own; AdminRole callers may do so unconditionally (FR-008/009/010)
// ════════════════════════════════════════════════════════════════════════════
fact F_OwnershipBasedAccess { /* MUTATED — body cleared by validator */ }

// ════════════════════════════════════════════════════════════════════════════
// F_CrossTeamIsolation — any operation's target task (when present) must
// belong to the operation's team; cross-team access is structurally impossible
// FR-011/FR-014; SC-004
// ════════════════════════════════════════════════════════════════════════════
fact F_CrossTeamIsolation {
  all op: Operation |
    (some op.opTask) implies op.opTask.taskTeam = op.opTeam
}

// ════════════════════════════════════════════════════════════════════════════
// F_MutationOperationsHaveAuditEntry — every successful write operation
// (PostTasks, PatchTask, DeleteTask) maps to exactly one MutationEvent
// FR-015; SC-007
// ════════════════════════════════════════════════════════════════════════════
fact F_MutationOperationsHaveAuditEntry {
  all op: Operation |
    (op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask) implies
      (one me: MutationEvent | me.mutOp = op)
}

// ════════════════════════════════════════════════════════════════════════════
// F_MutationEventConsistency — the audit entry produced by a mutation reflects
// the operation's team, caller, and role (FR-015 attribution snapshot)
// ════════════════════════════════════════════════════════════════════════════
fact F_MutationEventConsistency {
  all me: MutationEvent | {
    me.mutAudit.aeTeam      = me.mutOp.opTeam
    me.mutAudit.aeActor     = me.mutOp.opCaller
    me.mutAudit.aeActorRole = me.mutOp.opCallerRole
    me.mutAudit.aeTask      = me.mutOp.opTask
  }
}

// ════════════════════════════════════════════════════════════════════════════
// F_AuditChangeKindMatchesOp — change-kind in audit entry matches operation kind
// FR-015 change-description shapes
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditChangeKindMatchesOp {
  all me: MutationEvent | {
    me.mutOp.opKind = PostTasks  implies me.mutAudit.aeChange = AuditCreated
    me.mutOp.opKind = DeleteTask implies me.mutAudit.aeChange = AuditDeleted
    me.mutOp.opKind = PatchTask  implies me.mutAudit.aeChange in AuditChanged
  }
}

// ════════════════════════════════════════════════════════════════════════════
// F_ValidationBeforeMutation — a failed/invalid operation produces no MutationEvent
// FR-012; spec.md US2 acceptance scenario 2; contracts validation_error
// We model this as: MutationEvents exist only for operations that pass all checks.
// The converse (invalid ops have no MutationEvent) is structural in this model:
// every Operation in the universe has already passed auth+team-ctx; failed ops
// are not represented as Operation atoms (they are rejected before reaching logic).
// This fact closes the loop: no MutationEvent references a non-write opKind.
// ════════════════════════════════════════════════════════════════════════════
fact F_ValidationBeforeMutation {
  all me: MutationEvent |
    me.mutOp.opKind in (PostTasks + PatchTask + DeleteTask)
}

// ════════════════════════════════════════════════════════════════════════════
// PREDICATES AND ASSERTIONS
// ════════════════════════════════════════════════════════════════════════════

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008/009/010
// ────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
  // MemberRole is NOT unconditionally allowed to patch or delete tasks
  MemberRole -> PatchTask  not in PermMatrix.Allowed
  MemberRole -> DeleteTask not in PermMatrix.Allowed
  // AdminRole IS unconditionally allowed to patch and delete any team task
  AdminRole -> PatchTask  in PermMatrix.Allowed
  AdminRole -> DeleteTask in PermMatrix.Allowed
  // All members can read and create
  MemberRole -> PostTasks   in PermMatrix.Allowed
  MemberRole -> GetTaskById in PermMatrix.Allowed
  MemberRole -> GetAudit    in PermMatrix.Allowed
  some Operation
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 6 OperationKind

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
// ────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
  // Every (Role, OperationKind) pair has a defined verdict (allow or deny);
  // the Allowed relation plus its complement cover the full product.
  PermMatrix.Allowed + (Role -> OperationKind - PermMatrix.Allowed) = Role -> OperationKind
  some AuditEntry
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 6 OperationKind

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 (admin ⊇ member read-side)
// ────────────────────────────────────────────────────────────────────────────
pred PrivilegeMonotonicity {
  // Admin's unconditional allowed set is a superset of Member's
  MemberRole.(PermMatrix.Allowed) in AdminRole.(PermMatrix.Allowed)
  some Operation
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8 but exactly 2 Role, exactly 6 OperationKind

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md 401 boundary
// ────────────────────────────────────────────────────────────────────────────
pred AuthRequiredEverywhere {
  // Every operation that reaches business logic has an authenticated caller
  // whose identity resolves to a team membership — no anonymous callers.
  all op: Operation |
    some m: TeamMembership |
      m.memUser = op.opCaller and
      m.memTeam = op.opTeam   and
      m.memRole = op.opCallerRole
  some Operation
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; SC-007; data-model.md AuditEntry
// ────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
  // Every write operation has exactly one paired audit entry via MutationEvent
  all op: Operation |
    (op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask) implies
      (one me: MutationEvent | me.mutOp = op)
  // Every task has a created entry
  all t: Task | one ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditCreated
  some MutationEvent
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; SC-008; data-model.md "no UPDATE/DELETE on audit_entries"
// ────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
  // Every deleted task retains a final AuditDeleted entry (audit survives task deletion)
  all t: DeletedTask |
    some ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditDeleted
  // No active task has a deleted entry (no spurious deletion markers)
  all t: ActiveTask |
    no ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditDeleted
  some DeletedTask
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 actor snapshot; data-model.md AuditEntry
// ────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
  // Every audit entry produced by a mutation records the correct actor and role
  all me: MutationEvent | {
    me.mutAudit.aeActor     = me.mutOp.opCaller
    me.mutAudit.aeActorRole = me.mutOp.opCallerRole
    me.mutAudit.aeTeam      = me.mutOp.opTeam
  }
  some MutationEvent
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id NOT NULL
// ────────────────────────────────────────────────────────────────────────────
pred OwnershipExclusivity {
  // Every task has exactly one owner (owner_id NOT NULL, set at creation)
  all t: Task | one t.taskOwner
  some Task
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/009/010; contracts/http-api.md 403 rule
// ────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
  // A MemberRole caller can only PATCH or DELETE a task they own
  all op: Operation |
    (op.opCallerRole = MemberRole and
      (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
        (some t: Task | t = op.opTask and t.taskOwner = op.opCaller)
  some op: Operation | op.opKind = PatchTask
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equiv 404
// ────────────────────────────────────────────────────────────────────────────
pred NoInformationLeakage {
  // Every operation with a task target can only see tasks in its own team
  all op: Operation |
    (some op.opTask) implies op.opTask.taskTeam = op.opTeam
  some op: Operation | some op.opTask
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ────────────────────────────────────────────────────────────────────────────
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-012; contracts/http-api.md validation_error
// ────────────────────────────────────────────────────────────────────────────
pred ValidationBeforeMutation {
  // MutationEvents only arise from write-kind operations; read-only ops produce no audit entry
  all me: MutationEvent |
    me.mutOp.opKind in (PostTasks + PatchTask + DeleteTask)
  // Read operations have no associated MutationEvent
  all op: Operation |
    (op.opKind in (GetTaskList + GetTaskById + GetAudit)) implies
      (no me: MutationEvent | me.mutOp = op)
  some MutationEvent
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005 task.team_id immutable after creation
// ────────────────────────────────────────────────────────────────────────────
pred FR_005_TaskTeamImmutability {
  // In the static model: each task's team is fixed.
  // The AuditCreated entry records the actor in the same team as the task;
  // no PatchTask operation can change the team field (no UpdateTeam op exists).
  all t: Task |
    all ae: AuditEntry |
      ae.aeTask = t implies ae.aeTeam = t.taskTeam
  some Task
}
assert FR_005_TaskTeamImmutability { FR_005_TaskTeamImmutability }
check FR_005_TaskTeamImmutability for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006 owner_id immutable; contracts/http-api.md 400 on owner_id PATCH
// ────────────────────────────────────────────────────────────────────────────
pred FR_006_OwnerImmutability {
  // The AuditCreated entry's actor is the task's owner; no other mapping possible.
  all t: Task |
    all ae: AuditEntry |
      (ae.aeTask = t and ae.aeChange = AuditCreated) implies ae.aeActor = t.taskOwner
  some t: Task | some ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditCreated
}
assert FR_006_OwnerImmutability { FR_006_OwnerImmutability }
check FR_006_OwnerImmutability for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role; data-model.md TeamMembership composite PK
// ────────────────────────────────────────────────────────────────────────────
pred FR_007_PerTeamRole {
  // A user may have at most one membership row per team (composite PK)
  all disj m1, m2: TeamMembership |
    not (m1.memUser = m2.memUser and m1.memTeam = m2.memTeam)
  some TeamMembership
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-008/009/010 member can create/read; only owner-or-admin can edit/delete
// ────────────────────────────────────────────────────────────────────────────
pred FR_008_010_OwnerOrAdminEditDelete {
  // Every PATCH or DELETE operation is either by an AdminRole caller, or by
  // the MemberRole owner of the targeted task.
  all op: Operation |
    (op.opKind = PatchTask or op.opKind = DeleteTask) implies
      (op.opCallerRole = AdminRole or
        (some t: Task | t = op.opTask and t.taskOwner = op.opCaller))
  some op: Operation | op.opKind = PatchTask
}
assert FR_008_010_OwnerOrAdminEditDelete { FR_008_010_OwnerOrAdminEditDelete }
check FR_008_010_OwnerOrAdminEditDelete for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011/014 cross-team isolation; SC-004
// ────────────────────────────────────────────────────────────────────────────
pred FR_014_CrossTeamIsolation {
  // No operation can target a task belonging to a different team
  all op: Operation |
    (some op.opTask) implies op.opTask.taskTeam = op.opTeam
  // Even AdminRole in team T cannot reach a task in team U (U ≠ T)
  all op: Operation |
    (op.opCallerRole = AdminRole and some op.opTask) implies
      op.opTask.taskTeam = op.opTeam
  some op: Operation | some op.opTask
}
assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 per-edit-event audit; one entry per save
// ────────────────────────────────────────────────────────────────────────────
pred FR_015_AuditPerSave {
  // Every successful write operation yields exactly one MutationEvent
  all op: Operation |
    (op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask) implies
      (one me: MutationEvent | me.mutOp = op)
  // Change-kind correctness by operation type
  all me: MutationEvent | {
    me.mutOp.opKind = PostTasks  implies me.mutAudit.aeChange = AuditCreated
    me.mutOp.opKind = DeleteTask implies me.mutAudit.aeChange = AuditDeleted
    me.mutOp.opKind = PatchTask  implies me.mutAudit.aeChange in AuditChanged
  }
  some me: MutationEvent | me.mutOp.opKind = PatchTask
}
assert FR_015_AuditPerSave { FR_015_AuditPerSave }
check FR_015_AuditPerSave for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016 audit outlives task; no delete path on audit_entries
// ────────────────────────────────────────────────────────────────────────────
pred FR_016_AuditOutlivesTask {
  // Every DeletedTask has a AuditDeleted entry (the final audit event persists after task row deletion)
  all t: DeletedTask |
    some ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditDeleted
  // Every task (active or deleted) retains its AuditCreated entry
  all t: Task |
    some ae: AuditEntry | ae.aeTask = t and ae.aeChange = AuditCreated
  some DeletedTask
}
assert FR_016_AuditOutlivesTask { FR_016_AuditOutlivesTask }
check FR_016_AuditOutlivesTask for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017 audit readable by any team member; same isolation as GET /tasks
// ────────────────────────────────────────────────────────────────────────────
pred FR_017_AuditReadableByTeamMember {
  // GetAudit operations are in the unconditional allow set for both roles
  MemberRole -> GetAudit in PermMatrix.Allowed
  AdminRole  -> GetAudit in PermMatrix.Allowed
  // Audit entries are only reachable via operations scoped to the correct team
  all op: Operation |
    (op.opKind = GetAudit and some op.opTask) implies op.opTask.taskTeam = op.opTeam
  some op: Operation | op.opKind = GetAudit
}
assert FR_017_AuditReadableByTeamMember { FR_017_AuditReadableByTeamMember }
check FR_017_AuditReadableByTeamMember for 8 but exactly 2 Role, exactly 6 OperationKind

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012 assignee must be a current member of the same team
// ────────────────────────────────────────────────────────────────────────────
pred FR_012_AssigneeTeamMember {
  all t: Task |
    (some t.taskAssignee) implies
      (some m: TeamMembership | m.memUser = t.taskAssignee and m.memTeam = t.taskTeam)
  some t: Task | some t.taskAssignee
}
assert FR_012_AssigneeTeamMember { FR_012_AssigneeTeamMember }
check FR_012_AssigneeTeamMember for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001 all business-logic ops have authenticated callers
// ────────────────────────────────────────────────────────────────────────────
pred FR_001_AuthRequired {
  // Every Operation that reaches business logic has a caller with a verified team membership
  all op: Operation |
    some m: TeamMembership |
      m.memUser = op.opCaller and m.memTeam = op.opTeam
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003/004 team context: caller is a member of X-Team-Id team
// ────────────────────────────────────────────────────────────────────────────
pred FR_003_TeamContextRequired {
  // Every operation's caller is a member of the operation's team with the correct role
  all op: Operation |
    some m: TeamMembership |
      m.memUser = op.opCaller and m.memTeam = op.opTeam and m.memRole = op.opCallerRole
  some Operation
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OwnershipViolation { some op: Operation, t: ActiveTask | op.opKind = PatchTask and op.opCallerRole = MemberRole and op.opTask = t and t.taskOwner != op.opCaller }
