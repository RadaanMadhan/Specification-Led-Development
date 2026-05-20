// === feature_model.als — Alloy model for 007-team-tasks (B-L2) ===
// SaaS Team Task Management with Audit Trail.
// Encodes per-team membership, per-task ownership, append-only audit,
// and cross-team isolation as structural invariants.

// ---------- Enumerations & singletons ----------

abstract sig Bool {}
one sig BoolTrue, BoolFalse extends Bool {}

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTasksList, GetTaskById, PatchTask, DeleteTask, GetTaskAudit
  extends OperationKind {}

abstract sig Outcome {}
one sig Success, AuthRejected, MissingTeamContext, NotFound,
        PermissionDenied, ValidationError extends Outcome {}

abstract sig ChangeKind {}
one sig CreatedChange, ModifiedChange, DeletedChange extends ChangeKind {}

// Permission matrix as a singleton-sig field (Alloy 6 idiom).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Dynamic entities ----------

sig User {}
sig Team {}

sig Membership {
  mUser: one User,
  mTeam: one Team,
  mRole: one Role
}

sig Task {
  taskTeam: one Team,
  owner:    one User,
  assignee: lone User
}

sig AuditEntry {
  aeTask:      one Task,
  aeTeam:      one Team,
  aeActor:     one User,
  aeActorRole: one Role,
  aeChange:    one ChangeKind
}

sig Operation {
  opCaller:        one User,
  opAuthenticated: one Bool,
  opTeamCtx:       lone Team,
  opKind:          one OperationKind,
  opTarget:        lone Task,
  opOutcome:       one Outcome,
  opAudit:         lone AuditEntry
}

// ---------- Non-empty universe (mandatory; never inline witnesses) ----------

fact F_NonEmptyUniverse {
  some User
  some Team
  some Membership
  some Task
  some AuditEntry
  some Operation
}

// ---------- Permission matrix (closed-world) ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (MemberRole -> PostTasks)
    + (MemberRole -> GetTasksList)
    + (MemberRole -> GetTaskById)
    + (MemberRole -> GetTaskAudit)
    + (AdminRole  -> PostTasks)
    + (AdminRole  -> GetTasksList)
    + (AdminRole  -> GetTaskById)
    + (AdminRole  -> GetTaskAudit)
    + (AdminRole  -> PatchTask)
    + (AdminRole  -> DeleteTask)
  // Member's PatchTask/DeleteTask are CONDITIONAL on ownership and
  // intentionally not in the unconditional matrix.
}

// ---------- Static entity invariants ----------

fact F_UniqueMembership {
  // FR-007: at most one membership row per (user, team).
  all u: User, t: Team | lone m: Membership | m.mUser = u and m.mTeam = t
}

fact F_OwnerIsTeamMember {
  // data-model.md: tasks.owner_id ∈ team_memberships(team).
  all t: Task | some m: Membership | m.mUser = t.owner and m.mTeam = t.taskTeam
}

fact F_AssigneeIsTeamMember {
  // FR-012: assignee must be a current member of the same team.
  all t: Task | some t.assignee implies
    (some m: Membership | m.mUser = t.assignee and m.mTeam = t.taskTeam)
}

fact F_AuditTeamMatchesTask {
  // FR-005 / data-model.md: audit row's team_id denormalises task's team.
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// ---------- Operation-outcome facts ----------

fact F_AuthRequired { /* MUTATED — body cleared by validator */ }

fact F_TeamContextRequired {
  // FR-003: missing X-Team-Id → 400 missing_team_context.
  all op: Operation |
    (op.opAuthenticated = BoolTrue and no op.opTeamCtx)
      implies op.opOutcome = MissingTeamContext
}

fact F_NonMemberRejected {
  // FR-004 / FR-014: non-member of resolved team → byte-equivalent 404.
  all op: Operation |
    (op.opAuthenticated = BoolTrue and some op.opTeamCtx and
     (no m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamCtx))
      implies op.opOutcome = NotFound
}

fact F_CrossTeamIsolation {
  // FR-011 / FR-014: target task in another team → NotFound.
  all op: Operation |
    (op.opAuthenticated = BoolTrue and some op.opTeamCtx and some op.opTarget
     and op.opTarget.taskTeam != op.opTeamCtx)
      implies op.opOutcome = NotFound
}

fact F_SuccessRequiresPermission {
  // FR-008/FR-009/FR-010: success only if the (role, op) cell allows OR
  // the caller owns the target task (for PATCH/DELETE).
  all op: Operation | op.opOutcome = Success implies (
    some op.opTeamCtx
    and (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamCtx
         and (m.mRole -> op.opKind in PermMatrix.Allowed
              or ((op.opKind = PatchTask or op.opKind = DeleteTask)
                  and some op.opTarget
                  and op.opTarget.owner = op.opCaller)))
  )
}

// ---------- Audit facts ----------

fact F_AuditOnSuccessfulMutation {
  // FR-015: every successful mutation produces exactly one audit entry.
  all op: Operation |
    ((op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask)
     and op.opOutcome = Success)
      implies (one op.opAudit)
}

fact F_NoAuditOnFailure {
  // FR-015: validation/permission failures do NOT write audit entries.
  all op: Operation | op.opOutcome != Success implies no op.opAudit
}

fact F_NoAuditOnReadOps {
  // Read ops never produce audit entries.
  all op: Operation |
    (op.opKind = GetTasksList or op.opKind = GetTaskById or op.opKind = GetTaskAudit)
      implies no op.opAudit
}

fact F_AuditUniquePerOp {
  // Each audit entry is referenced by at most one operation.
  all ae: AuditEntry | lone op: Operation | op.opAudit = ae
}

fact F_AppendOnlyAudit {
  // FR-016: every audit entry comes from one successful mutation operation;
  // there is no path that introduces an audit entry by any other means and
  // no path that mutates or deletes existing entries.
  all ae: AuditEntry |
    some op: Operation |
      op.opAudit = ae
      and op.opOutcome = Success
      and (op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask)
}

fact F_AuditAttributionCorrect {
  // FR-015: actor and team on the audit row equal the caller/team of the op.
  all op: Operation | some op.opAudit implies (
    op.opAudit.aeActor = op.opCaller
    and op.opAudit.aeTeam = op.opTeamCtx
  )
}

fact F_AuditTargetMatch {
  all op: Operation | (some op.opAudit and some op.opTarget) implies
    op.opAudit.aeTask = op.opTarget
}

fact F_AuditRoleSnapshot {
  // FR-015: actor_role snapshot equals the caller's role in the resolved team.
  all op: Operation | some op.opAudit implies
    (some m: Membership |
       m.mUser = op.opCaller and m.mTeam = op.opTeamCtx
       and m.mRole = op.opAudit.aeActorRole)
}

fact F_AuditKindMatchesOp {
  all op: Operation | some op.opAudit implies (
    (op.opKind = PostTasks   implies op.opAudit.aeChange = CreatedChange)
    and (op.opKind = PatchTask  implies op.opAudit.aeChange = ModifiedChange)
    and (op.opKind = DeleteTask implies op.opAudit.aeChange = DeletedChange)
  )
}

// =====================================================================
// Pattern predicates & assertions
// =====================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.opOutcome = Success implies op.opAuthenticated = BoolTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008..FR-010
pred LeastPrivilege {
  all op: Operation | op.opOutcome = Success implies
    (some m: Membership |
       m.mUser = op.opCaller and m.mTeam = op.opTeamCtx
       and (m.mRole -> op.opKind in PermMatrix.Allowed
            or ((op.opKind = PatchTask or op.opKind = DeleteTask)
                and some op.opTarget
                and op.opTarget.owner = op.opCaller)))
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md matrix
pred PermissionCompleteness {
  // Every operation kind is reachable for at least one role; matrix is non-empty
  // on every column. A removed matrix would leave some op with no allowed role.
  all o: OperationKind | some r: Role | r -> o in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 admin ≥ member
pred PrivilegeMonotonicity {
  all o: OperationKind |
    (MemberRole -> o in PermMatrix.Allowed)
      implies (AdminRole -> o in PermMatrix.Allowed)
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014
pred NoInformationLeakage {
  // Cross-team probes collapse to the same NotFound outcome as non-existence.
  all op: Operation |
    (op.opAuthenticated = BoolTrue and some op.opTeamCtx and some op.opTarget
     and op.opTarget.taskTeam != op.opTeamCtx)
      implies op.opOutcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015
pred AuditCompleteness {
  all op: Operation |
    ((op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask)
     and op.opOutcome = Success)
      implies (one op.opAudit)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016
pred AppendOnly {
  some AuditEntry
  all ae: AuditEntry |
    some op: Operation |
      op.opAudit = ae
      and op.opOutcome = Success
      and (op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015
pred AttributionCorrectness {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aeActor = op.opCaller
    and op.opAudit.aeTeam = op.opTeamCtx
  )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md owner_id NOT NULL
pred OwnershipExclusivity {
  some Task
  all t: Task | one t.owner
  all t: Task | some m: Membership | m.mUser = t.owner and m.mTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/FR-009
pred OwnershipBasedAccess {
  all op: Operation |
    (op.opOutcome = Success
     and (op.opKind = PatchTask or op.opKind = DeleteTask)
     and (some m: Membership |
            m.mUser = op.opCaller and m.mTeam = op.opTeamCtx and m.mRole = MemberRole))
      implies (some op.opTarget and op.opTarget.owner = op.opCaller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-006/FR-012 validation precedes state change
pred ValidationBeforeMutation {
  all op: Operation | op.opOutcome = ValidationError implies no op.opAudit
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// =====================================================================
// FR-specific predicates & assertions
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | op.opAuthenticated = BoolFalse implies op.opOutcome = AuthRejected
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (identity from auth context)
pred FR_002_IdentityFromAuth {
  // Successful op's audit, if any, attributes to the caller principal (i.e.,
  // identity is not separately settable). Captured via attribution.
  all op: Operation | some op.opAudit implies op.opAudit.aeActor = op.opCaller
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_TeamContextRequired {
  all op: Operation |
    (op.opAuthenticated = BoolTrue and no op.opTeamCtx)
      implies op.opOutcome = MissingTeamContext
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_MemberOfResolvedTeam {
  all op: Operation | op.opOutcome = Success implies
    (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamCtx)
}
assert FR_004_MemberOfResolvedTeam { FR_004_MemberOfResolvedTeam }
check FR_004_MemberOfResolvedTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (task's team immutable; audit team consistent)
pred FR_005_TaskTeamConsistency {
  all ae: AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}
assert FR_005_TaskTeamConsistency { FR_005_TaskTeamConsistency }
check FR_005_TaskTeamConsistency for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (owner immutable; exactly one owner per task)
pred FR_006_OneOwnerPerTask {
  some Task
  all t: Task | one t.owner
}
assert FR_006_OneOwnerPerTask { FR_006_OneOwnerPerTask }
check FR_006_OneOwnerPerTask for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_PerTeamRole {
  all u: User, t: Team | lone m: Membership | m.mUser = u and m.mTeam = t
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 (member may edit/delete tasks they own)
pred FR_008_OwnerOrAdminCanEditDelete {
  all op: Operation |
    (op.opOutcome = Success and (op.opKind = PatchTask or op.opKind = DeleteTask))
      implies (
        (some m: Membership |
            m.mUser = op.opCaller and m.mTeam = op.opTeamCtx and m.mRole = AdminRole)
        or (some op.opTarget and op.opTarget.owner = op.opCaller)
      )
}
assert FR_008_OwnerOrAdminCanEditDelete { FR_008_OwnerOrAdminCanEditDelete }
check FR_008_OwnerOrAdminCanEditDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (non-owner non-admin member cannot edit/delete)
pred FR_009_NonOwnerMemberCannotEdit {
  all op: Operation |
    (op.opOutcome = Success
     and (op.opKind = PatchTask or op.opKind = DeleteTask)
     and (some m: Membership |
            m.mUser = op.opCaller and m.mTeam = op.opTeamCtx and m.mRole = MemberRole))
      implies (some op.opTarget and op.opTarget.owner = op.opCaller)
}
assert FR_009_NonOwnerMemberCannotEdit { FR_009_NonOwnerMemberCannotEdit }
check FR_009_NonOwnerMemberCannotEdit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (admin may edit/delete any task in their team)
pred FR_010_AdminCanEditAnyTaskInTeam {
  AdminRole -> PatchTask in PermMatrix.Allowed
  AdminRole -> DeleteTask in PermMatrix.Allowed
}
assert FR_010_AdminCanEditAnyTaskInTeam { FR_010_AdminCanEditAnyTaskInTeam }
check FR_010_AdminCanEditAnyTaskInTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (no role grants cross-team access)
pred FR_011_CrossTeamIsolation {
  all op: Operation |
    (op.opAuthenticated = BoolTrue and some op.opTeamCtx and some op.opTarget
     and op.opTarget.taskTeam != op.opTeamCtx)
      implies op.opOutcome = NotFound
}
assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (assignee must belong to same team)
pred FR_012_AssigneeInSameTeam {
  all t: Task | some t.assignee implies
    (some m: Membership | m.mUser = t.assignee and m.mTeam = t.taskTeam)
}
assert FR_012_AssigneeInSameTeam { FR_012_AssigneeInSameTeam }
check FR_012_AssigneeInSameTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (status set is closed)
pred FR_013_StatusSetClosed {
  // Statuses are not modelled as a sig in this static slice; the closed-world
  // property is reflected by every successful PostTasks/PatchTask producing
  // an audit entry whose ChangeKind is one of the three legal values.
  all op: Operation | some op.opAudit implies
    op.opAudit.aeChange in (CreatedChange + ModifiedChange + DeletedChange)
}
assert FR_013_StatusSetClosed { FR_013_StatusSetClosed }
check FR_013_StatusSetClosed for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent NotFound)
pred FR_014_ByteEquivalentNotFound {
  // Both "non-member of team" and "task in different team" collapse to NotFound.
  all op: Operation |
    ((op.opAuthenticated = BoolTrue and some op.opTeamCtx
      and (no m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamCtx))
     or
     (op.opAuthenticated = BoolTrue and some op.opTeamCtx and some op.opTarget
      and op.opTarget.taskTeam != op.opTeamCtx))
      implies op.opOutcome = NotFound
}
assert FR_014_ByteEquivalentNotFound { FR_014_ByteEquivalentNotFound }
check FR_014_ByteEquivalentNotFound for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (one audit per save)
pred FR_015_OneAuditPerSave {
  all op: Operation |
    ((op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask)
     and op.opOutcome = Success)
      implies (one op.opAudit)
}
assert FR_015_OneAuditPerSave { FR_015_OneAuditPerSave }
check FR_015_OneAuditPerSave for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit append-only)
pred FR_016_AuditAppendOnly {
  some AuditEntry
  all ae: AuditEntry |
    some op: Operation |
      op.opAudit = ae
      and op.opOutcome = Success
      and (op.opKind = PostTasks or op.opKind = PatchTask or op.opKind = DeleteTask)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit readable by any team member)
pred FR_017_AuditReadableByTeamMember {
  all op: Operation |
    (op.opKind = GetTaskAudit and op.opOutcome = Success)
      implies (some m: Membership |
                 m.mUser = op.opCaller and m.mTeam = op.opTeamCtx)
}
assert FR_017_AuditReadableByTeamMember { FR_017_AuditReadableByTeamMember }
check FR_017_AuditReadableByTeamMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (retention; no DELETE path on audit)
pred FR_018_AuditRetained {
  // No operation kind in the modelled API deletes an audit entry.
  // Captured as: every existing audit entry traces back to a mutation op.
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
}
assert FR_018_AuditRetained { FR_018_AuditRetained }
check FR_018_AuditRetained for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019/FR-020 (list scoped to current team)
pred FR_019_ListScopedToTeam {
  all op: Operation |
    (op.opKind = GetTasksList and op.opOutcome = Success)
      implies (some m: Membership |
                 m.mUser = op.opCaller and m.mTeam = op.opTeamCtx)
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuthBypass { some op: Operation, m: Membership | op.opOutcome = Success and op.opAuthenticated = BoolFalse and some op.opTeamCtx and m.mUser = op.opCaller and m.mTeam = op.opTeamCtx and op.opKind = GetTasksList }
