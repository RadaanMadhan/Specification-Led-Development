// === feature_model.als — Alloy model for B-L2 (007-team-tasks) ===
// SaaS team task management with per-team roles, ownership-conditional
// mutation rights, cross-team isolation, and per-edit-event audit trail.

// ---------- Static enums / kinds ----------

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTaskList, GetTaskById, PatchTask, DeleteTask, GetAudit
  extends OperationKind {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig CreatedChange, ModifiedChange, DeletedChange extends ChangeKind {}

one sig AuthFlag {}
one sig SuccessFlag {}

// ---------- Dynamic sigs ----------

sig User {}
sig Team {}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  team: one Team,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus
}

sig AuditEntry {
  task: one Task,
  team: one Team,
  actor: one User,
  actorRole: one Role,
  change: one ChangeKind
}

sig Operation {
  kind: one OperationKind,
  caller: one User,
  teamCtx: one Team,
  target: lone Task,
  authenticated: lone AuthFlag,
  succeeded: lone SuccessFlag,
  producedAudit: lone AuditEntry
}

// Permission matrix as a singleton-sig field; closed-world via F_PermissionMatrix.
one sig PermMatrix {
  UnconditionalAllowed: set Role -> OperationKind,
  OwnershipConditional: set Role -> OperationKind
}

// ---------- Non-empty universe ----------

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// ---------- Permission matrix (from contracts/http-api.md table) ----------

fact F_PermissionMatrix {
  // Unconditional allows — caller's role alone suffices.
  PermMatrix.UnconditionalAllowed =
      (MemberRole -> PostTasks)
    + (MemberRole -> GetTaskList)
    + (MemberRole -> GetTaskById)
    + (MemberRole -> GetAudit)
    + (AdminRole -> PostTasks)
    + (AdminRole -> GetTaskList)
    + (AdminRole -> GetTaskById)
    + (AdminRole -> PatchTask)
    + (AdminRole -> DeleteTask)
    + (AdminRole -> GetAudit)
  // Ownership-conditional allows — caller must also own the target task.
  PermMatrix.OwnershipConditional =
      (MemberRole -> PatchTask)
    + (MemberRole -> DeleteTask)
  // A cell is allowed in exactly one of the two classes (or denied).
  no (PermMatrix.UnconditionalAllowed & PermMatrix.OwnershipConditional)
}

// ---------- Domain invariants ----------

fact F_TeamMembershipUnique {
  // At most one membership row per (user, team).
  all disj m1, m2: TeamMembership |
    m1.user != m2.user or m1.team != m2.team
}

fact F_TaskOwnerIsTeamMember {
  all t: Task | some m: TeamMembership |
    m.user = t.owner and m.team = t.team
}

fact F_TaskAssigneeIsTeamMember {
  all t: Task |
    some t.assignee implies
      (some m: TeamMembership | m.user = t.assignee and m.team = t.team)
}

fact F_AuditEntryTeamMatchesTask {
  all ae: AuditEntry | ae.team = ae.task.team
}

fact F_AuditEntryActorRoleSnapshot {
  // The recorded actor + role correspond to a real membership of the recorded team.
  all ae: AuditEntry | some m: TeamMembership |
    m.user = ae.actor and m.team = ae.team and m.role = ae.actorRole
}

// ---------- Operation-level invariants ----------

fact F_AuthRequired {
  all op: Operation |
    some op.succeeded implies some op.authenticated
}

fact F_TeamContextMembership {
  // FR-004: a succeeded op's caller must be a current member of teamCtx.
  all op: Operation |
    some op.succeeded implies
      (some m: TeamMembership | m.user = op.caller and m.team = op.teamCtx)
}

fact F_PermissionGate {
  // FR-008..FR-010: per-role allow rules, with ownership condition where applicable.
  all op: Operation |
    some op.succeeded implies
      (some m: TeamMembership |
        m.user = op.caller and m.team = op.teamCtx and
        ( (m.role -> op.kind) in PermMatrix.UnconditionalAllowed
          or ( (m.role -> op.kind) in PermMatrix.OwnershipConditional
               and some op.target
               and op.target.owner = op.caller ) ))
}

fact F_CrossTeamIsolation { /* MUTATED — body cleared by validator */ }

fact F_OpTargetRequired {
  // Endpoints that name a task in their URL require a target.
  all op: Operation |
    op.kind in (GetTaskById + PatchTask + DeleteTask + GetAudit)
      implies some op.target
}

fact F_StateChangingOpsProduceAudit {
  // FR-015: every successful POST/PATCH/DELETE produces exactly one audit entry.
  all op: Operation |
    (some op.succeeded and op.kind in (PostTasks + PatchTask + DeleteTask))
      implies (one op.producedAudit)
}

fact F_ReadOpsProduceNoAudit {
  all op: Operation |
    op.kind in (GetTaskList + GetTaskById + GetAudit)
      implies no op.producedAudit
}

fact F_AuditAttribution {
  // FR-015: audit entry records the actual caller and team.
  all op: Operation, ae: AuditEntry |
    ae = op.producedAudit implies
      (ae.actor = op.caller and ae.team = op.teamCtx)
}

fact F_AuditChangeKindMatchesOp {
  all op: Operation, ae: AuditEntry |
    ae = op.producedAudit implies
      ( (op.kind = PostTasks implies ae.change = CreatedChange)
        and (op.kind = PatchTask implies ae.change = ModifiedChange)
        and (op.kind = DeleteTask implies ae.change = DeletedChange) )
}

fact F_AuditTaskLink {
  // PATCH/DELETE audit row points at the operation's target.
  all op: Operation, ae: AuditEntry |
    (ae = op.producedAudit and op.kind in (PatchTask + DeleteTask))
      implies ae.task = op.target
  // POST audit row points at a newly created task in teamCtx, owned by caller.
  all op: Operation, ae: AuditEntry |
    (ae = op.producedAudit and op.kind = PostTasks)
      implies (ae.task.team = op.teamCtx and ae.task.owner = op.caller)
}

fact F_AppendOnlyAuditEntries {
  // FR-016: every audit row corresponds to exactly one operation that produced it.
  // No orphan / no double-attribution.
  all ae: AuditEntry | one op: Operation | op.producedAudit = ae
}

fact F_OneCreatedPerTask {
  all t: Task |
    lone ae: AuditEntry | ae.task = t and ae.change = CreatedChange
}

fact F_OneDeletedPerTask {
  all t: Task |
    lone ae: AuditEntry | ae.task = t and ae.change = DeletedChange
}

// =================================================================
// Catalogue patterns
// =================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md 401 boundary
pred AuthRequiredEverywhere {
  all op: Operation |
    some op.succeeded implies some op.authenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008..FR-011
pred LeastPrivilege {
  all op: Operation |
    some op.succeeded implies
      (some m: TeamMembership |
        m.user = op.caller and m.team = op.teamCtx and
        ( (m.role -> op.kind) in PermMatrix.UnconditionalAllowed
          or ( (m.role -> op.kind) in PermMatrix.OwnershipConditional
               and some op.target
               and op.target.owner = op.caller ) ))
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every OperationKind has at least one role that can perform it.
  all k: OperationKind |
    some r: Role |
      (r -> k) in PermMatrix.UnconditionalAllowed
      or (r -> k) in PermMatrix.OwnershipConditional
  // The two classes do not overlap (every cell has at most one verdict).
  no (PermMatrix.UnconditionalAllowed & PermMatrix.OwnershipConditional)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 (admin >= member on shared ops)
pred PrivilegeMonotonicity {
  // Anywhere a member is unconditionally allowed, admin is too.
  all k: OperationKind |
    (MemberRole -> k) in PermMatrix.UnconditionalAllowed implies
      (AdminRole -> k) in PermMatrix.UnconditionalAllowed
  // Anywhere a member is ownership-conditional, admin is unconditionally allowed.
  all k: OperationKind |
    (MemberRole -> k) in PermMatrix.OwnershipConditional implies
      (AdminRole -> k) in PermMatrix.UnconditionalAllowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md audit_entries
pred AuditCompleteness {
  // Every state-changing successful op produces exactly one audit entry.
  all op: Operation |
    (some op.succeeded and op.kind in (PostTasks + PatchTask + DeleteTask))
      implies (one op.producedAudit)
  // Read-only ops never produce audit entries.
  all op: Operation |
    op.kind in (GetTaskList + GetTaskById + GetAudit)
      implies no op.producedAudit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No orphan audit entries; every entry traces back to its originating operation.
  all ae: AuditEntry | some op: Operation | op.producedAudit = ae
  // No two distinct operations claim the same audit entry.
  all ae: AuditEntry | lone op: Operation | op.producedAudit = ae
  // Each task has at most one created-entry and at most one deleted-entry.
  all t: Task | lone ae: AuditEntry | ae.task = t and ae.change = CreatedChange
  all t: Task | lone ae: AuditEntry | ae.task = t and ae.change = DeletedChange
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 (actor / role snapshot)
pred AttributionCorrectness {
  all op: Operation, ae: AuditEntry |
    ae = op.producedAudit implies
      ( ae.actor = op.caller
        and ae.team = op.teamCtx )
  // The recorded actor + role match a real membership of the recorded team.
  all ae: AuditEntry | some m: TeamMembership |
    m.user = ae.actor and m.team = ae.team and m.role = ae.actorRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  // Each task has exactly one owner, and that owner is a member of the task's team.
  all t: Task | one t.owner
  all t: Task | some m: TeamMembership |
    m.user = t.owner and m.team = t.team
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009
pred OwnershipBasedAccess {
  // A member (non-admin) can only PATCH/DELETE a task they own.
  all op: Operation |
    (some op.succeeded and op.kind in (PatchTask + DeleteTask)) implies
      (some m: TeamMembership |
        m.user = op.caller and m.team = op.teamCtx and
        ( m.role = AdminRole
          or ( m.role = MemberRole
               and some op.target
               and op.target.owner = op.caller ) ))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-011, FR-014 (byte-equivalent 404)
pred NoInformationLeakage {
  // A successful op with a target only ever reaches a task inside its team context.
  all op: Operation |
    (some op.succeeded and some op.target) implies op.target.team = op.teamCtx
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// =================================================================
// Feature-specific predicates — one per FR-NNN
// =================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required)
pred FR_001_AuthRequired {
  all op: Operation |
    some op.succeeded implies some op.authenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (actor identity from auth context, not payload)
pred FR_002_ActorFromAuthContext {
  // The audit-recorded actor is always the operation's caller (from auth context).
  all op: Operation, ae: AuditEntry |
    ae = op.producedAudit implies ae.actor = op.caller
}
assert FR_002_ActorFromAuthContext { FR_002_ActorFromAuthContext }
check FR_002_ActorFromAuthContext for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (X-Team-Id required; caller's team context is resolved)
pred FR_003_TeamContextRequired {
  // Every successful operation has a resolved team context with a valid membership.
  all op: Operation |
    some op.succeeded implies
      (some m: TeamMembership | m.user = op.caller and m.team = op.teamCtx)
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (caller must be current member of resolved team)
pred FR_004_CallerIsTeamMember {
  all op: Operation |
    some op.succeeded implies
      (some m: TeamMembership | m.user = op.caller and m.team = op.teamCtx)
}
assert FR_004_CallerIsTeamMember { FR_004_CallerIsTeamMember }
check FR_004_CallerIsTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (task team immutable; audit team matches task team)
pred FR_005_TaskTeamConsistent {
  all ae: AuditEntry | ae.team = ae.task.team
}
assert FR_005_TaskTeamConsistent { FR_005_TaskTeamConsistent }
check FR_005_TaskTeamConsistent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (owner immutable; exactly one owner; owner is team member)
pred FR_006_OwnerImmutableAndExclusive {
  all t: Task | one t.owner
  all t: Task | some m: TeamMembership |
    m.user = t.owner and m.team = t.team
}
assert FR_006_OwnerImmutableAndExclusive { FR_006_OwnerImmutableAndExclusive }
check FR_006_OwnerImmutableAndExclusive for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (per-team role: at most one membership per (user, team))
pred FR_007_OneRolePerUserPerTeam {
  all disj m1, m2: TeamMembership |
    m1.user != m2.user or m1.team != m2.team
}
assert FR_007_OneRolePerUserPerTeam { FR_007_OneRolePerUserPerTeam }
check FR_007_OneRolePerUserPerTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (owner or admin can edit/delete)
pred FR_008_OwnerOrAdminMayMutate {
  all op: Operation |
    (some op.succeeded and op.kind in (PatchTask + DeleteTask)) implies
      (some m: TeamMembership |
        m.user = op.caller and m.team = op.teamCtx and
        ( m.role = AdminRole
          or (some op.target and op.target.owner = op.caller) ))
}
assert FR_008_OwnerOrAdminMayMutate { FR_008_OwnerOrAdminMayMutate }
check FR_008_OwnerOrAdminMayMutate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (members cannot mutate non-owned tasks)
pred FR_009_MemberCannotMutateOthers {
  all op: Operation, m: TeamMembership |
    ( some op.succeeded
      and op.kind in (PatchTask + DeleteTask)
      and m.user = op.caller
      and m.team = op.teamCtx
      and m.role = MemberRole )
    implies (some op.target and op.target.owner = op.caller)
}
assert FR_009_MemberCannotMutateOthers { FR_009_MemberCannotMutateOthers }
check FR_009_MemberCannotMutateOthers for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (admin can edit/delete any task in their team)
pred FR_010_AdminCanMutateAny {
  (AdminRole -> PatchTask) in PermMatrix.UnconditionalAllowed
  (AdminRole -> DeleteTask) in PermMatrix.UnconditionalAllowed
}
assert FR_010_AdminCanMutateAny { FR_010_AdminCanMutateAny }
check FR_010_AdminCanMutateAny for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (no role grants cross-team access)
pred FR_011_NoCrossTeamAccess {
  all op: Operation |
    (some op.succeeded and some op.target) implies op.target.team = op.teamCtx
}
assert FR_011_NoCrossTeamAccess { FR_011_NoCrossTeamAccess }
check FR_011_NoCrossTeamAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (task field validation: team/owner/status/assignee well-formed)
pred FR_012_TaskFieldsValid {
  all t: Task |
    one t.team and one t.owner and one t.status
  all t: Task |
    some t.assignee implies
      (some m: TeamMembership | m.user = t.assignee and m.team = t.team)
}
assert FR_012_TaskFieldsValid { FR_012_TaskFieldsValid }
check FR_012_TaskFieldsValid for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (status set = {todo, in_progress, done})
pred FR_013_StatusSet {
  TaskStatus = Todo + InProgress + Done
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_013_StatusSet { FR_013_StatusSet }
check FR_013_StatusSet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (cross-team byte-equivalent 404)
pred FR_014_CrossTeamIsolation {
  all op: Operation |
    (some op.succeeded and some op.target) implies op.target.team = op.teamCtx
}
assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (one audit entry per save with full attribution)
pred FR_015_AuditPerSave {
  all op: Operation |
    (some op.succeeded and op.kind in (PostTasks + PatchTask + DeleteTask))
      implies (one op.producedAudit)
  all op: Operation, ae: AuditEntry |
    ae = op.producedAudit implies
      (ae.actor = op.caller and ae.team = op.teamCtx)
}
assert FR_015_AuditPerSave { FR_015_AuditPerSave }
check FR_015_AuditPerSave for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit append-only)
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry | one op: Operation | op.producedAudit = ae
  all t: Task | lone ae: AuditEntry | ae.task = t and ae.change = CreatedChange
  all t: Task | lone ae: AuditEntry | ae.task = t and ae.change = DeletedChange
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit readable by any team member, including non-admin)
pred FR_017_AuditReadableByMember {
  (MemberRole -> GetAudit) in PermMatrix.UnconditionalAllowed
  (AdminRole -> GetAudit) in PermMatrix.UnconditionalAllowed
}
assert FR_017_AuditReadableByMember { FR_017_AuditReadableByMember }
check FR_017_AuditReadableByMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (retention via code-path absence — same shape as append-only)
pred FR_018_AuditRetainedViaAppendOnly {
  // No audit entry is orphaned / removable: every one ties to exactly one op.
  all ae: AuditEntry | one op: Operation | op.producedAudit = ae
}
assert FR_018_AuditRetainedViaAppendOnly { FR_018_AuditRetainedViaAppendOnly }
check FR_018_AuditRetainedViaAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019, FR-020 (list/filter scoped to caller's team)
pred FR_019_020_ListScopedToTeam {
  (MemberRole -> GetTaskList) in PermMatrix.UnconditionalAllowed
  (AdminRole -> GetTaskList) in PermMatrix.UnconditionalAllowed
  all op: Operation |
    (some op.succeeded and op.kind = GetTaskList and some op.target)
      implies op.target.team = op.teamCtx
}
assert FR_019_020_ListScopedToTeam { FR_019_020_ListScopedToTeam }
check FR_019_020_ListScopedToTeam for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeam { some op: Operation | some op.succeeded and op.kind = GetTaskById and some op.target and op.target.team != op.teamCtx }
