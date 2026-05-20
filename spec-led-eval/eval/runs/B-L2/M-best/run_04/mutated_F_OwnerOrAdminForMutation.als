// === feature_model.als — Alloy model for B-L2 (SaaS Team Task Management with Audit Trail) ===

// ---------- Static sigs ----------

abstract sig Role {}
one sig Member, Admin extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById, PatchTask, DeleteTask, GetAudit extends OperationKind {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig Outcome {}
one sig Success, Unauthenticated, MissingTeamContext, NotFound, PermissionDenied, ValidationError extends Outcome {}

abstract sig AuditKind {}
one sig CreatedKind, ModifiedKind, DeletedKind extends AuditKind {}

// ---------- Dynamic sigs ----------

sig User {}
sig Team {}

sig Membership {
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
  teamSnap: one Team,
  actor: one User,
  roleSnap: one Role,
  kind: one AuditKind
}

sig Operation {
  kind: one OperationKind,
  caller: lone User,            // empty = unauthenticated
  teamCtx: lone Team,           // empty = missing team context
  target: lone Task,
  outcome: one Outcome,
  writesAudit: lone AuditEntry
}

// Permission matrix as a singleton-sig field (Role x OperationKind).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe (rule 9) ----------

fact F_NonEmptyUniverse {
  some User
  some Team
  some Membership
  some Task
  some AuditEntry
  some Operation
}

// ---------- Permission matrix encoding (contracts/http-api.md) ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Member -> PostTasks) + (Member -> GetTasks) + (Member -> GetTaskById) +
      (Member -> PatchTask) + (Member -> DeleteTask) + (Member -> GetAudit) +
      (Admin  -> PostTasks) + (Admin  -> GetTasks) + (Admin  -> GetTaskById) +
      (Admin  -> PatchTask) + (Admin  -> DeleteTask) + (Admin  -> GetAudit)
}

// ---------- Membership uniqueness (FR-007) ----------

fact F_AtMostOneMembershipPerUserTeam {
  all disj m1, m2: Membership |
    not (m1.user = m2.user and m1.team = m2.team)
}

// ---------- Task structural invariants ----------

fact F_AssigneeInTaskTeam {
  all t: Task | some t.assignee implies
    (some m: Membership | m.user = t.assignee and m.team = t.team)
}

fact F_OwnerIsMemberOfTaskTeam {
  all t: Task | some m: Membership | m.user = t.owner and m.team = t.team
}

// ---------- Audit team snapshot tracks task team ----------

fact F_AuditTeamMatchesTaskTeam {
  all a: AuditEntry | a.teamSnap = a.task.team
}

// ---------- Authentication boundary (FR-001) ----------

fact F_AuthenticationBoundary {
  all op: Operation | no op.caller implies op.outcome = Unauthenticated
}

// ---------- Team context required (FR-003) ----------

fact F_MissingTeamContextBoundary {
  all op: Operation |
    (some op.caller and no op.teamCtx) implies op.outcome = MissingTeamContext
}

// ---------- Non-member of resolved team gets 404 (FR-003/FR-004) ----------

fact F_NonMemberGets404 {
  all op: Operation |
    (some op.caller and some op.teamCtx and
     (no m: Membership | m.user = op.caller and m.team = op.teamCtx))
       implies op.outcome = NotFound
}

// ---------- Cross-team isolation (FR-011 / FR-014) ----------

fact F_CrossTeamIsolation {
  all op: Operation |
    (op.outcome = Success and some op.target) implies op.target.team = op.teamCtx
}

// ---------- Owner-or-admin required for PATCH/DELETE (FR-008/9/10) ----------

fact F_OwnerOrAdminForMutation { /* MUTATED — body cleared by validator */ }

// ---------- Baseline permission gate (LeastPrivilege scaffolding) ----------

fact F_BaselinePermission {
  all op: Operation | op.outcome = Success implies
    (some m: Membership |
       m.user = op.caller and m.team = op.teamCtx and
       (m.role -> op.kind) in PermMatrix.Allowed)
}

// ---------- Audit entry written for each state-changing success (FR-015) ----------

fact F_AuditEntryForStateChange {
  all op: Operation |
    (op.outcome = Success and op.kind = PostTasks) implies
      (some op.writesAudit and op.writesAudit.task = op.target)
  all op: Operation |
    (op.outcome = Success and op.kind = PatchTask) implies
      (some op.writesAudit and op.writesAudit.task = op.target)
  all op: Operation |
    (op.outcome = Success and op.kind = DeleteTask) implies
      (some op.writesAudit and op.writesAudit.task = op.target)
  // Read-only and failed operations never write audit
  all op: Operation |
    (op.kind = GetTasks or op.kind = GetTaskById or op.kind = GetAudit) implies no op.writesAudit
  all op: Operation | op.outcome != Success implies no op.writesAudit
}

// ---------- Every AuditEntry has exactly one producing Operation ----------

fact F_EveryAuditHasProducer {
  all a: AuditEntry | one op: Operation | op.writesAudit = a
}

// ---------- Audit append-only: kind matches producing op's kind (FR-016) ----------

fact F_AuditAppendOnlyKind {
  all a: AuditEntry, op: Operation | op.writesAudit = a implies
    ((op.kind = PostTasks and a.kind = CreatedKind) or
     (op.kind = PatchTask and a.kind = ModifiedKind) or
     (op.kind = DeleteTask and a.kind = DeletedKind))
}

// ---------- Audit attribution / snapshot correctness (FR-015) ----------

fact F_AuditAttribution {
  all a: AuditEntry, op: Operation | op.writesAudit = a implies
    (a.actor = op.caller and
     (some m: Membership |
        m.user = op.caller and m.team = op.teamCtx and m.role = a.roleSnap))
}

// ---------- Audit visibility requires team membership (FR-017) ----------

fact F_AuditReadByTeamMember {
  all op: Operation |
    (op.outcome = Success and op.kind = GetAudit) implies
      (some m: Membership |
         m.user = op.caller and m.team = op.teamCtx and op.target.team = op.teamCtx)
}

// =========================================================================
//                         PATTERNS + PREDICATES
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008/9/10/11
pred LeastPrivilege {
  all op: Operation | op.outcome = Success implies
    (some m: Membership |
       m.user = op.caller and m.team = op.teamCtx and
       (m.role -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role x OperationKind) cell present in the matrix (closed-world allow).
  all r: Role, k: OperationKind | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = Success implies some op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md audit_entries
pred AuditCompleteness {
  all op: Operation |
    (op.outcome = Success and
     (op.kind = PostTasks or op.kind = PatchTask or op.kind = DeleteTask)) implies
      (one a: AuditEntry | a = op.writesAudit and a.task = op.target)
  all a: AuditEntry | one op: Operation | op.writesAudit = a
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE path on audit_entries"
pred AppendOnly {
  // Each audit entry's kind is determined by its producing op's kind.
  all a: AuditEntry, op: Operation | op.writesAudit = a implies
    ((op.kind = PostTasks and a.kind = CreatedKind) or
     (op.kind = PatchTask and a.kind = ModifiedKind) or
     (op.kind = DeleteTask and a.kind = DeletedKind))
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 (actor/role snapshot)
pred AttributionCorrectness {
  all a: AuditEntry, op: Operation | op.writesAudit = a implies
    (a.actor = op.caller and
     (some m: Membership |
        m.user = op.caller and m.team = op.teamCtx and m.role = a.roleSnap))
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; FR-006
pred OwnershipExclusivity {
  all t: Task | one t.owner
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/FR-009/FR-010
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Success and (op.kind = PatchTask or op.kind = DeleteTask)) implies
      (op.caller = op.target.owner or
       (some m: Membership |
          m.user = op.caller and m.team = op.teamCtx and m.role = Admin))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014 (byte-equivalent 404)
pred NoInformationLeakage {
  // If caller is authenticated and team-resolved but the target task belongs to
  // a different team, the outcome MUST be NotFound — not Success, not PermissionDenied.
  all op: Operation |
    (some op.caller and some op.teamCtx and some op.target and
     op.target.team != op.teamCtx and
     (op.kind = GetTaskById or op.kind = PatchTask or
      op.kind = DeleteTask or op.kind = GetAudit)) implies op.outcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// =========================================================================
//                       FR-NNN FEATURE-SPECIFIC PREDICATES
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 Authentication required
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies op.outcome = Unauthenticated
  all op: Operation | op.outcome = Success implies some op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 Identity resolved from auth context, not payload
pred FR_002_IdentityFromAuthContext {
  // Each operation has at most one caller identity (one source of truth).
  all op: Operation | lone op.caller
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 X-Team-Id required
pred FR_003_TeamContextRequired {
  all op: Operation |
    (some op.caller and no op.teamCtx) implies op.outcome = MissingTeamContext
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 Caller must be a member of the resolved team
pred FR_004_CallerIsMember {
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller and m.team = op.teamCtx)
}
assert FR_004_CallerIsMember { FR_004_CallerIsMember }
check FR_004_CallerIsMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 Task team is immutable
pred FR_005_TaskTeamImmutable {
  // Each task is bound to exactly one team (no co-team, no orphans).
  all t: Task | one t.team
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 Owner immutable
pred FR_006_OwnerImmutable {
  all t: Task | one t.owner
  // Owner must be a member of the task's team (immutability + integrity).
  all t: Task | some m: Membership | m.user = t.owner and m.team = t.team
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 At most one role per (user, team)
pred FR_007_PerTeamRole {
  all disj m1, m2: Membership |
    not (m1.user = m2.user and m1.team = m2.team)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 Member can edit own task
pred FR_008_OwnerCanMutate {
  all op: Operation |
    (op.outcome = Success and (op.kind = PatchTask or op.kind = DeleteTask)) implies
      (op.caller = op.target.owner or
       (some m: Membership |
          m.user = op.caller and m.team = op.teamCtx and m.role = Admin))
}
assert FR_008_OwnerCanMutate { FR_008_OwnerCanMutate }
check FR_008_OwnerCanMutate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 Non-owner non-admin members cannot edit/delete
pred FR_009_NonOwnerMemberDenied {
  all op: Operation |
    (op.outcome = Success and (op.kind = PatchTask or op.kind = DeleteTask) and
     op.caller != op.target.owner) implies
      (some m: Membership |
         m.user = op.caller and m.team = op.teamCtx and m.role = Admin)
}
assert FR_009_NonOwnerMemberDenied { FR_009_NonOwnerMemberDenied }
check FR_009_NonOwnerMemberDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 Admin can edit/delete any task in same team
pred FR_010_AdminCanMutateAnyInTeam {
  // Admin successes are constrained to their own team only.
  all op: Operation |
    (op.outcome = Success and (op.kind = PatchTask or op.kind = DeleteTask) and
     (some m: Membership | m.user = op.caller and m.team = op.teamCtx and m.role = Admin))
        implies op.target.team = op.teamCtx
}
assert FR_010_AdminCanMutateAnyInTeam { FR_010_AdminCanMutateAnyInTeam }
check FR_010_AdminCanMutateAnyInTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 Cross-team isolation
pred FR_011_CrossTeamIsolation {
  all op: Operation |
    (op.outcome = Success and some op.target) implies op.target.team = op.teamCtx
}
assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 Assignee must be in same team
pred FR_012_AssigneeSameTeam {
  all t: Task | some t.assignee implies
    (some m: Membership | m.user = t.assignee and m.team = t.team)
}
assert FR_012_AssigneeSameTeam { FR_012_AssigneeSameTeam }
check FR_012_AssigneeSameTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 Status from fixed set
pred FR_013_StatusInSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_013_StatusInSet { FR_013_StatusInSet }
check FR_013_StatusInSet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 Byte-equivalent NotFound on cross-team or non-existent
pred FR_014_ByteEquivalentNotFound {
  all op: Operation |
    (some op.caller and some op.teamCtx and some op.target and
     op.target.team != op.teamCtx and
     (op.kind = GetTaskById or op.kind = PatchTask or
      op.kind = DeleteTask or op.kind = GetAudit)) implies op.outcome = NotFound
}
assert FR_014_ByteEquivalentNotFound { FR_014_ByteEquivalentNotFound }
check FR_014_ByteEquivalentNotFound for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 Per-edit-event audit entry with snapshot
pred FR_015_AuditPerEdit {
  all op: Operation |
    (op.outcome = Success and
     (op.kind = PostTasks or op.kind = PatchTask or op.kind = DeleteTask)) implies
      (one a: AuditEntry | a = op.writesAudit and a.task = op.target and a.actor = op.caller)
}
assert FR_015_AuditPerEdit { FR_015_AuditPerEdit }
check FR_015_AuditPerEdit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 Audit append-only
pred FR_016_AuditAppendOnly {
  all a: AuditEntry | one op: Operation | op.writesAudit = a
  all a: AuditEntry, op: Operation | op.writesAudit = a implies
    ((op.kind = PostTasks and a.kind = CreatedKind) or
     (op.kind = PatchTask and a.kind = ModifiedKind) or
     (op.kind = DeleteTask and a.kind = DeletedKind))
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 Audit readable only by current team members
pred FR_017_AuditTeamScoped {
  all op: Operation |
    (op.outcome = Success and op.kind = GetAudit) implies
      (some m: Membership |
         m.user = op.caller and m.team = op.teamCtx and op.target.team = op.teamCtx)
}
assert FR_017_AuditTeamScoped { FR_017_AuditTeamScoped }
check FR_017_AuditTeamScoped for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 Retention by code-path absence
pred FR_018_RetentionByCodePathAbsence {
  // No OperationKind exists that mutates or deletes audit entries: only the
  // six declared kinds exist, none of which carry an audit-mutating semantics.
  all op: Operation |
    op.kind in (PostTasks + GetTasks + GetTaskById + PatchTask + DeleteTask + GetAudit)
  // Every existing audit entry has exactly one producing op (no orphans, no deletes).
  all a: AuditEntry | one op: Operation | op.writesAudit = a
}
assert FR_018_RetentionByCodePathAbsence { FR_018_RetentionByCodePathAbsence }
check FR_018_RetentionByCodePathAbsence for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 List scoped to current team
pred FR_019_ListScopedToTeam {
  all op: Operation |
    (op.outcome = Success and op.kind = GetTasks and some op.target) implies
       op.target.team = op.teamCtx
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 Filtered list scoped to current team
pred FR_020_FilteredListScopedToTeam {
  all op: Operation |
    (op.outcome = Success and op.kind = GetTasks and some op.target) implies
       op.target.team = op.teamCtx
}
assert FR_020_FilteredListScopedToTeam { FR_020_FilteredListScopedToTeam }
check FR_020_FilteredListScopedToTeam for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OwnershipBypass { some op: Operation, t: Task, m: Membership | op.kind = PatchTask and op.outcome = Success and op.target = t and m.user = op.caller and m.team = op.teamCtx and m.role = Member and op.caller != t.owner }
