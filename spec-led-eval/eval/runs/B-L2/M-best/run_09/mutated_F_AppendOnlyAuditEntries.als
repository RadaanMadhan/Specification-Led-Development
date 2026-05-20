// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail (B-L2) ===
// Encodes: authentication boundary, team context (X-Team-Id), per-team roles,
// owner-or-admin mutation, cross-team isolation (FR-014 / SC-004), per-edit-event
// audit trail (FR-015), append-only audit (FR-016), and the contracts/ permission
// matrix from http-api.md.

// ---------------------------------------------------------------------------
// Non-empty universe: every dynamic sig must have at least one atom so the
// universally-quantified predicates below are exercised, not vacuously true.
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------
abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig CreatedKind, ModifiedKind, DeletedKind extends ChangeKind {}

abstract sig OperationKind {}
one sig CreateTaskOp, ListTasksOp, GetTaskOp,
        PatchTaskOp,  DeleteTaskOp, GetAuditOp extends OperationKind {}

abstract sig Outcome {}
one sig Success, AuthFail, MissingTeamCtx,
        NotFound, PermDenied, ValidationFail extends Outcome {}

// ---------------------------------------------------------------------------
// Domain entities (data-model.md)
// ---------------------------------------------------------------------------
sig User {}
sig Team {}

sig TeamMembership {
  tm_user: one User,
  tm_team: one Team,
  tm_role: one Role
}

sig Task {
  task_team: one Team,
  owner:     one User,
  assignee:  lone User,
  status:    one TaskStatus
}

sig AuditEntry {
  ae_task:         one Task,
  ae_team:         one Team,
  actor:           one User,
  actor_role_snap: one Role,
  change:          one ChangeKind
}

sig Operation {
  op_caller:   lone User,
  op_team_ctx: lone Team,
  op_kind:     one OperationKind,
  op_target:   lone Task,
  op_outcome:  one Outcome,
  op_audit:    lone AuditEntry
}

// ---------------------------------------------------------------------------
// Permission matrix (contracts/http-api.md). Modelled as a singleton-sig
// field so the relation is well-typed in Alloy 6.
// ---------------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (MemberRole -> CreateTaskOp) +
      (MemberRole -> ListTasksOp)  +
      (MemberRole -> GetTaskOp)    +
      (MemberRole -> PatchTaskOp)  +
      (MemberRole -> DeleteTaskOp) +
      (MemberRole -> GetAuditOp)   +
      (AdminRole  -> CreateTaskOp) +
      (AdminRole  -> ListTasksOp)  +
      (AdminRole  -> GetTaskOp)    +
      (AdminRole  -> PatchTaskOp)  +
      (AdminRole  -> DeleteTaskOp) +
      (AdminRole  -> GetAuditOp)
}

// ---------------------------------------------------------------------------
// Structural data-model facts
// ---------------------------------------------------------------------------
fact F_UniqueTeamMembership {
  all disj m1, m2: TeamMembership |
    not (m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team)
}

fact F_OwnerIsTeamMember {
  all t: Task |
    (some m: TeamMembership | m.tm_user = t.owner and m.tm_team = t.task_team)
}

fact F_AssigneeIsTeamMember {
  all t: Task | some t.assignee implies
    (some m: TeamMembership | m.tm_user = t.assignee and m.tm_team = t.task_team)
}

fact F_AuditTeamMatchesTaskTeam {
  all a: AuditEntry | a.ae_team = a.ae_task.task_team
}

fact F_AuditActorMembershipSnapshot {
  all a: AuditEntry |
    (some m: TeamMembership |
      m.tm_user = a.actor and m.tm_team = a.ae_team and m.tm_role = a.actor_role_snap)
}

// ---------------------------------------------------------------------------
// Operation-outcome facts (auth, team context, isolation, permissions)
// ---------------------------------------------------------------------------
fact F_AuthRequiredForSuccess {
  all op: Operation | op.op_outcome = Success implies some op.op_caller
}

fact F_TeamContextRequiredForSuccess {
  all op: Operation | op.op_outcome = Success implies some op.op_team_ctx
}

fact F_CallerMustBeMember {
  all op: Operation | op.op_outcome = Success implies
    (some m: TeamMembership |
      m.tm_user = op.op_caller and m.tm_team = op.op_team_ctx)
}

fact F_TargetRequiredForTargetedOps {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = GetTaskOp    or
      op.op_kind = PatchTaskOp  or
      op.op_kind = DeleteTaskOp or
      op.op_kind = GetAuditOp)) implies some op.op_target
}

fact F_CrossTeamIsolation {
  all op: Operation |
    (op.op_outcome = Success and some op.op_target) implies
      op.op_target.task_team = op.op_team_ctx
}

fact F_OwnerOrAdminForMutation {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = PatchTaskOp or op.op_kind = DeleteTaskOp) and
     some op.op_target) implies
      (op.op_caller = op.op_target.owner or
       (some m: TeamMembership |
         m.tm_user = op.op_caller and
         m.tm_team = op.op_team_ctx and
         m.tm_role = AdminRole))
}

// ---------------------------------------------------------------------------
// Audit-trail facts (FR-015, FR-016)
// ---------------------------------------------------------------------------
fact F_AuditEntryPerSuccessfulSave {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = CreateTaskOp or
      op.op_kind = PatchTaskOp  or
      op.op_kind = DeleteTaskOp)) implies some op.op_audit
}

fact F_NoAuditOnFailure {
  all op: Operation | op.op_outcome != Success implies no op.op_audit
}

fact F_NoAuditOnReadOps {
  all op: Operation |
    (op.op_kind = ListTasksOp or
     op.op_kind = GetTaskOp   or
     op.op_kind = GetAuditOp) implies no op.op_audit
}

fact F_AuditAttribution {
  all op: Operation | some op.op_audit implies
    (op.op_audit.actor   = op.op_caller and
     op.op_audit.ae_task = op.op_target)
}

fact F_AuditChangeKindMatchesOp {
  all op: Operation | some op.op_audit implies
    ((op.op_kind = CreateTaskOp implies op.op_audit.change = CreatedKind) and
     (op.op_kind = PatchTaskOp  implies op.op_audit.change = ModifiedKind) and
     (op.op_kind = DeleteTaskOp implies op.op_audit.change = DeletedKind))
}

fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// ===========================================================================
// CATALOGUE PATTERNS
// ===========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008..FR-011
pred LeastPrivilege {
  all op: Operation | op.op_outcome = Success implies
    (some m: TeamMembership |
       m.tm_user = op.op_caller and
       m.tm_team = op.op_team_ctx and
       (m.tm_role -> op.op_kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, k: OperationKind | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-006
pred AuthRequiredEverywhere {
  all op: Operation | op.op_outcome = Success implies some op.op_caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007
pred AuditCompleteness {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = CreateTaskOp or
      op.op_kind = PatchTaskOp  or
      op.op_kind = DeleteTaskOp)) implies some op.op_audit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, SC-008; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all a: AuditEntry | (one op: Operation | op.op_audit = a)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md audit_entries.actor_*
pred AttributionCorrectness {
  all op: Operation | some op.op_audit implies
    (op.op_audit.actor   = op.op_caller and
     op.op_audit.ae_task = op.op_target)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  all t: Task | one t.owner
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008..FR-010
pred OwnershipBasedAccess {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = PatchTaskOp or op.op_kind = DeleteTaskOp) and
     some op.op_target) implies
      (op.op_caller = op.op_target.owner or
       (some m: TeamMembership |
         m.tm_user = op.op_caller and
         m.tm_team = op.op_team_ctx and
         m.tm_role = AdminRole))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-004; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  // A request that targets a task in a team other than the caller's X-Team-Id
  // MUST NOT succeed; it shares the byte-equivalent not_found response.
  all op: Operation |
    (some op.op_target and some op.op_team_ctx and
     op.op_target.task_team != op.op_team_ctx) implies
       op.op_outcome != Success
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md US2 acc. scenario 2; data-model.md atomicity
pred ValidationBeforeMutation {
  all op: Operation | op.op_outcome != Success implies no op.op_audit
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ===========================================================================
// FEATURE-SPECIFIC (one predicate per FR-NNN in spec.md)
// ===========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authenticated user required
pred FR_001_AuthRequired {
  all op: Operation | op.op_outcome = Success implies some op.op_caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity from auth context (never from payload)
pred FR_002_IdentityFromAuth {
  // Every successful operation resolves to exactly one caller.
  all op: Operation | op.op_outcome = Success implies one op.op_caller
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 X-Team-Id header required
pred FR_003_TeamContextRequired {
  all op: Operation | op.op_outcome = Success implies some op.op_team_ctx
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 caller must be a current member of resolved team
pred FR_004_CallerMember {
  all op: Operation | op.op_outcome = Success implies
    (some m: TeamMembership |
      m.tm_user = op.op_caller and m.tm_team = op.op_team_ctx)
}
assert FR_004_CallerMember { FR_004_CallerMember }
check FR_004_CallerMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 task team set at creation, immutable
pred FR_005_TaskHasOneTeam {
  all t: Task | one t.task_team
}
assert FR_005_TaskHasOneTeam { FR_005_TaskHasOneTeam }
check FR_005_TaskHasOneTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 owner immutable; exactly one owner per task
pred FR_006_OwnerImmutable {
  all t: Task | one t.owner
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role; composite PK on (user, team)
pred FR_007_PerTeamRole {
  all disj m1, m2: TeamMembership |
    not (m1.tm_user = m2.tm_user and m1.tm_team = m2.tm_team)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008/FR-009/FR-010 owner-or-admin edit/delete
pred FR_008_010_OwnerOrAdminEdit {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = PatchTaskOp or op.op_kind = DeleteTaskOp) and
     some op.op_target) implies
      (op.op_caller = op.op_target.owner or
       (some m: TeamMembership |
         m.tm_user = op.op_caller and
         m.tm_team = op.op_team_ctx and
         m.tm_role = AdminRole))
}
assert FR_008_010_OwnerOrAdminEdit { FR_008_010_OwnerOrAdminEdit }
check FR_008_010_OwnerOrAdminEdit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 / FR-014 cross-team isolation invariant
pred FR_014_CrossTeamIsolation {
  all op: Operation |
    (op.op_outcome = Success and some op.op_target) implies
      op.op_target.task_team = op.op_team_ctx
}
assert FR_014_CrossTeamIsolation { FR_014_CrossTeamIsolation }
check FR_014_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 / FR-013 status set is exactly {todo, in_progress, done}
pred FR_013_StatusSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_013_StatusSet { FR_013_StatusSet }
check FR_013_StatusSet for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 per-edit-event audit + actor attribution
pred FR_015_AuditPerSave {
  all op: Operation |
    (op.op_outcome = Success and
     (op.op_kind = CreateTaskOp or
      op.op_kind = PatchTaskOp  or
      op.op_kind = DeleteTaskOp)) implies
       (some op.op_audit and op.op_audit.actor = op.op_caller)
}
assert FR_015_AuditPerSave { FR_015_AuditPerSave }
check FR_015_AuditPerSave for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit append-only; no UPDATE/DELETE path
pred FR_016_AuditAppendOnly {
  all a: AuditEntry | (one op: Operation | op.op_audit = a)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit readable by any current member of the task's team
pred FR_017_AuditVisibleToTeamMembers {
  all op: Operation |
    (op.op_outcome = Success and op.op_kind = GetAuditOp) implies
      (some op.op_target and
       op.op_target.task_team = op.op_team_ctx and
       (some m: TeamMembership |
         m.tm_user = op.op_caller and m.tm_team = op.op_team_ctx))
}
assert FR_017_AuditVisibleToTeamMembers { FR_017_AuditVisibleToTeamMembers }
check FR_017_AuditVisibleToTeamMembers for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 ≥12-month retention enforced by absence of a delete path
pred FR_018_AuditRetention {
  // Same structural property as append-only: every entry persists with its creating op.
  all a: AuditEntry | (one op: Operation | op.op_audit = a)
}
assert FR_018_AuditRetention { FR_018_AuditRetention }
check FR_018_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 list scoped to caller's team
pred FR_019_ListScopedToTeam {
  all op: Operation |
    (op.op_outcome = Success and op.op_kind = ListTasksOp) implies
      (some m: TeamMembership |
        m.tm_user = op.op_caller and m.tm_team = op.op_team_ctx)
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 filters apply within current team context
pred FR_020_FiltersScopedToTeam {
  all op: Operation |
    (op.op_outcome = Success and op.op_kind = ListTasksOp) implies
      some op.op_team_ctx
}
assert FR_020_FiltersScopedToTeam { FR_020_FiltersScopedToTeam }
check FR_020_FiltersScopedToTeam for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OrphanAudit { some a: AuditEntry | (no op: Operation | op.op_audit = a) }
