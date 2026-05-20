// === feature_model.als — Alloy model for 007-team-tasks (B-L2) ===
// SaaS Team Task Management with Audit Trail.
// Models authentication, team-context resolution, per-team roles,
// task ownership, cross-team isolation, and append-only audit trail.

// ============================================================
// Sigs
// ============================================================

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig OperationKind {}
one sig CreateTask, ListTasks, GetTask, PatchTask, DeleteTask, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig Success, Unauthenticated, MissingTeamContext, PermissionDenied, NotFound, ValidationError extends Outcome {}

abstract sig Bool {}
one sig BoolTrue, BoolFalse extends Bool {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig CreatedChange, ModifiedChange, DeletedChange extends ChangeKind {}

sig User {}
sig Team {}

sig Membership {
  memberUser: one User,
  memberTeam: one Team,
  memberRole: one Role
}

sig Task {
  taskTeam: one Team,
  taskOwner: one User,
  taskAssignee: lone User,
  taskStatus: one TaskStatus
}

sig AuditEntry {
  auditTask: one Task,
  auditTeam: one Team,
  auditActor: one User,
  auditActorRole: one Role,
  auditChange: one ChangeKind
}

sig Operation {
  opCaller: one User,
  opCallerTeam: one Team,
  opKind: one OperationKind,
  opTarget: lone Task,
  opOutcome: one Outcome,
  opCallerRole: lone Role,
  opAuthenticated: one Bool,
  opTeamHeader: one Bool,
  opProducedAudit: lone AuditEntry,
  opMutatedOwner: one Bool
}

// Permission matrix as a singleton-sig field per the canonical pattern.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ============================================================
// F_NonEmptyUniverse  (single, named, top-of-file)
// ============================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some Membership
  some Task
  some AuditEntry
  some Operation
}

// ============================================================
// Structural facts (each named to be mutation-testable)
// ============================================================

fact F_PermissionMatrix {
  // Closed-world enumeration of the (Role × OperationKind) allow set.
  // Both roles can reach every endpoint; ownership conditions are layered
  // on top by F_OwnerOrAdminMutation, not by the matrix itself.
  PermMatrix.Allowed =
    (MemberRole -> CreateTask) + (MemberRole -> ListTasks) + (MemberRole -> GetTask) +
    (MemberRole -> PatchTask) + (MemberRole -> DeleteTask) + (MemberRole -> GetAudit) +
    (AdminRole  -> CreateTask) + (AdminRole  -> ListTasks) + (AdminRole  -> GetTask) +
    (AdminRole  -> PatchTask) + (AdminRole  -> DeleteTask) + (AdminRole  -> GetAudit)
}

fact F_MembershipUnique {
  // Composite PK (user_id, team_id) on team_memberships.
  all disj m1, m2: Membership |
    not (m1.memberUser = m2.memberUser and m1.memberTeam = m2.memberTeam)
}

fact F_TaskOwnerIsMember {
  all t: Task | some m: Membership |
    m.memberUser = t.taskOwner and m.memberTeam = t.taskTeam
}

fact F_TaskAssigneeIsMember {
  all t: Task | some t.taskAssignee implies
    (some m: Membership |
       m.memberUser = t.taskAssignee and m.memberTeam = t.taskTeam)
}

fact F_AuditFromOperation {
  // Every AuditEntry is produced by at least one Operation (existence).
  all a: AuditEntry | some op: Operation | op.opProducedAudit = a
}

fact F_AuditTeamMatchesTaskTeam {
  all a: AuditEntry | a.auditTeam = a.auditTask.taskTeam
}

fact F_AuthRequired { /* MUTATED — body cleared by validator */ }

fact F_TeamContextRequired {
  all op: Operation |
    (op.opAuthenticated = BoolTrue and op.opTeamHeader = BoolFalse) implies
      op.opOutcome = MissingTeamContext
}

fact F_MembershipRequiredForSuccess {
  all op: Operation | op.opOutcome = Success implies
    (some m: Membership |
       m.memberUser = op.opCaller and
       m.memberTeam = op.opCallerTeam and
       m.memberRole = op.opCallerRole)
}

fact F_CrossTeamIsolation {
  // Cross-team task access yields byte-equivalent NotFound.
  all op: Operation |
    (op.opAuthenticated = BoolTrue and op.opTeamHeader = BoolTrue and
     some op.opTarget and op.opTarget.taskTeam != op.opCallerTeam) implies
      op.opOutcome = NotFound
  // No audit written on cross-team refusal.
  all op: Operation |
    (some op.opTarget and op.opTarget.taskTeam != op.opCallerTeam) implies
      no op.opProducedAudit
}

fact F_OwnerOrAdminMutation {
  // Successful PATCH/DELETE requires Admin role OR caller owns the task.
  all op: Operation |
    (op.opOutcome = Success and (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      (op.opCallerRole = AdminRole or op.opTarget.taskOwner = op.opCaller)
}

fact F_OwnerImmutability {
  // Any attempt to mutate owner_id yields ValidationError and no audit.
  all op: Operation |
    op.opMutatedOwner = BoolTrue implies op.opOutcome = ValidationError
  all op: Operation |
    op.opMutatedOwner = BoolTrue implies no op.opProducedAudit
}

fact F_AuditAppendOnly {
  // At most one Operation may produce a given AuditEntry; no rebinding.
  all disj op1, op2: Operation |
    (some op1.opProducedAudit) implies op1.opProducedAudit != op2.opProducedAudit
}

fact F_AuditPerStateChange {
  // Successful Create/Patch/Delete produces exactly one audit.
  all op: Operation |
    (op.opOutcome = Success and
     (op.opKind = CreateTask or op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      (one op.opProducedAudit)
  // Read-only kinds never produce an audit.
  all op: Operation |
    (op.opKind = ListTasks or op.opKind = GetTask or op.opKind = GetAudit) implies
      no op.opProducedAudit
  // Non-success outcomes never produce an audit.
  all op: Operation |
    op.opOutcome != Success implies no op.opProducedAudit
}

fact F_AuditAttribution {
  // Audit actor, role, and team snapshot equal the producing operation's caller.
  all op: Operation, a: AuditEntry |
    op.opProducedAudit = a implies
      (a.auditActor = op.opCaller and
       a.auditActorRole = op.opCallerRole and
       a.auditTeam = op.opCallerTeam)
}

fact F_AuditChangeKindMatchesOpKind {
  all op: Operation, a: AuditEntry |
    op.opProducedAudit = a implies
      ((op.opKind = CreateTask implies a.auditChange = CreatedChange) and
       (op.opKind = PatchTask  implies a.auditChange = ModifiedChange) and
       (op.opKind = DeleteTask implies a.auditChange = DeletedChange))
}

fact F_AuditReadableByTeamMembers {
  // Successful GetAudit requires target in caller's team.
  all op: Operation |
    (op.opOutcome = Success and op.opKind = GetAudit) implies
      (some op.opTarget and op.opTarget.taskTeam = op.opCallerTeam)
}

// ============================================================
// Pattern predicates and assertions
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008/FR-009/FR-010
pred LeastPrivilege {
  all op: Operation | op.opOutcome = Success implies
    (op.opCallerRole -> op.opKind) in PermMatrix.Allowed
  all op: Operation |
    (op.opOutcome = Success and op.opCallerRole = MemberRole and
     (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      op.opTarget.taskOwner = op.opCaller
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, k: OperationKind | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  all op: Operation | op.opOutcome = Success implies op.opAuthenticated = BoolTrue
  all op: Operation | op.opAuthenticated = BoolFalse implies no op.opProducedAudit
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md audit_entries schema
pred AuditCompleteness {
  all op: Operation |
    (op.opOutcome = Success and
     (op.opKind = CreateTask or op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      (one op.opProducedAudit)
  all op: Operation |
    (op.opKind = ListTasks or op.opKind = GetTask or op.opKind = GetAudit) implies
      no op.opProducedAudit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // Each AuditEntry is produced by exactly one Operation — no rebinding.
  all a: AuditEntry | one op: Operation | op.opProducedAudit = a
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor snapshot fields
pred AttributionCorrectness {
  all op: Operation, a: AuditEntry |
    op.opProducedAudit = a implies
      (a.auditActor = op.opCaller and a.auditActorRole = op.opCallerRole)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL (single owner)
pred OwnershipExclusivity {
  all t: Task | one t.taskOwner
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-009; data-model.md owner-or-admin predicate
pred OwnershipBasedAccess {
  all op: Operation |
    (op.opOutcome = Success and
     (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      (op.opCallerRole = AdminRole or op.opTarget.taskOwner = op.opCaller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  all op: Operation |
    (op.opAuthenticated = BoolTrue and op.opTeamHeader = BoolTrue and
     some op.opTarget and op.opTarget.taskTeam != op.opCallerTeam) implies
      op.opOutcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ============================================================
// Feature-specific FR predicates
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (Authentication required for every request)
pred FR_001_AuthRequired {
  all op: Operation | op.opOutcome = Success implies op.opAuthenticated = BoolTrue
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (Identity resolved from auth context, not payload)
pred FR_002_IdentityFromAuth {
  // Modelled as: a successful op's caller corresponds to a real (user, team) membership row.
  all op: Operation | op.opOutcome = Success implies
    (some m: Membership |
       m.memberUser = op.opCaller and m.memberTeam = op.opCallerTeam)
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (X-Team-Id header required; missing → 400)
pred FR_003_TeamContextRequired {
  all op: Operation |
    (op.opAuthenticated = BoolTrue and op.opTeamHeader = BoolFalse) implies
      op.opOutcome = MissingTeamContext
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (Caller must be current member of resolved team)
pred FR_004_MembershipRequired {
  all op: Operation | op.opOutcome = Success implies
    (some m: Membership |
       m.memberUser = op.opCaller and
       m.memberTeam = op.opCallerTeam and
       m.memberRole = op.opCallerRole)
}
assert FR_004_MembershipRequired { FR_004_MembershipRequired }
check FR_004_MembershipRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (Task team is set at creation and immutable)
pred FR_005_TaskTeamSet {
  all t: Task | one t.taskTeam
}
assert FR_005_TaskTeamSet { FR_005_TaskTeamSet }
check FR_005_TaskTeamSet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (owner_id immutable; PATCH owner → 400 validation_error)
pred FR_006_OwnerImmutable {
  all op: Operation |
    op.opMutatedOwner = BoolTrue implies op.opOutcome = ValidationError
  all op: Operation |
    op.opMutatedOwner = BoolTrue implies no op.opProducedAudit
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (At most one role per (user, team))
pred FR_007_PerTeamRole {
  all disj m1, m2: Membership |
    not (m1.memberUser = m2.memberUser and m1.memberTeam = m2.memberTeam)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (Member may edit/delete tasks they own)
pred FR_008_MemberOwnsCanEdit {
  // Member-role successful mutation requires ownership (matches contract).
  all op: Operation |
    (op.opOutcome = Success and op.opCallerRole = MemberRole and
     (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      op.opTarget.taskOwner = op.opCaller
}
assert FR_008_MemberOwnsCanEdit { FR_008_MemberOwnsCanEdit }
check FR_008_MemberOwnsCanEdit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (Member must not edit/delete tasks they don't own)
pred FR_009_NonOwnerCannotMutate {
  all op: Operation |
    (op.opOutcome = Success and
     op.opCallerRole = MemberRole and
     (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      op.opTarget.taskOwner = op.opCaller
}
assert FR_009_NonOwnerCannotMutate { FR_009_NonOwnerCannotMutate }
check FR_009_NonOwnerCannotMutate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (Admin may edit/delete any task in their team)
pred FR_010_AdminCanMutateAny {
  all op: Operation |
    (op.opOutcome = Success and
     op.opCallerRole = AdminRole and
     (op.opKind = PatchTask or op.opKind = DeleteTask)) implies
      op.opTarget.taskTeam = op.opCallerTeam
}
assert FR_010_AdminCanMutateAny { FR_010_AdminCanMutateAny }
check FR_010_AdminCanMutateAny for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (No role in T grants access to a task in team U)
pred FR_011_NoCrossTeamRoleAccess {
  all op: Operation |
    (op.opOutcome = Success and some op.opTarget) implies
      op.opTarget.taskTeam = op.opCallerTeam
}
assert FR_011_NoCrossTeamRoleAccess { FR_011_NoCrossTeamRoleAccess }
check FR_011_NoCrossTeamRoleAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (Assignee must be member of the task's team)
pred FR_012_AssigneeSameTeam {
  all t: Task | some t.taskAssignee implies
    (some m: Membership |
       m.memberUser = t.taskAssignee and m.memberTeam = t.taskTeam)
}
assert FR_012_AssigneeSameTeam { FR_012_AssigneeSameTeam }
check FR_012_AssigneeSameTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (Status set is exactly todo/in_progress/done)
pred FR_013_StatusEnum {
  all t: Task | t.taskStatus in (Todo + InProgress + Done)
  TaskStatus = Todo + InProgress + Done
}
assert FR_013_StatusEnum { FR_013_StatusEnum }
check FR_013_StatusEnum for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (Cross-team task access yields byte-equivalent 404)
pred FR_014_CrossTeamByteEquivalent {
  all op: Operation |
    (op.opAuthenticated = BoolTrue and op.opTeamHeader = BoolTrue and
     some op.opTarget and op.opTarget.taskTeam != op.opCallerTeam) implies
      op.opOutcome = NotFound
}
assert FR_014_CrossTeamByteEquivalent { FR_014_CrossTeamByteEquivalent }
check FR_014_CrossTeamByteEquivalent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (Audit entries carry actor + role + team snapshots)
pred FR_015_AuditSnapshot {
  all op: Operation, a: AuditEntry |
    op.opProducedAudit = a implies
      (a.auditActor = op.opCaller and
       a.auditActorRole = op.opCallerRole and
       a.auditTeam = op.opCallerTeam)
}
assert FR_015_AuditSnapshot { FR_015_AuditSnapshot }
check FR_015_AuditSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (Audit append-only — no UPDATE/DELETE path)
pred FR_016_AuditAppendOnly {
  all a: AuditEntry | one op: Operation | op.opProducedAudit = a
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (Audit readable by any current member of task's team)
pred FR_017_AuditReadableByTeamMember {
  all op: Operation |
    (op.opOutcome = Success and op.opKind = GetAudit) implies
      (some op.opTarget and
       op.opTarget.taskTeam = op.opCallerTeam and
       (some m: Membership |
          m.memberUser = op.opCaller and m.memberTeam = op.opCallerTeam))
}
assert FR_017_AuditReadableByTeamMember { FR_017_AuditReadableByTeamMember }
check FR_017_AuditReadableByTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (≥12-month retention via absence of any audit-delete path)
pred FR_018_RetentionByAppendOnly {
  // Static encoding: every audit has a producing operation; nothing removes audits.
  all a: AuditEntry | some op: Operation | op.opProducedAudit = a
}
assert FR_018_RetentionByAppendOnly { FR_018_RetentionByAppendOnly }
check FR_018_RetentionByAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019/FR-020 (Listing is scoped to the caller's team)
pred FR_019_ListScopedToTeam {
  all op: Operation |
    (op.opOutcome = Success and op.opKind = ListTasks) implies
      (some m: Membership |
         m.memberUser = op.opCaller and m.memberTeam = op.opCallerTeam)
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuthRequiredViolation { some op: Operation | op.opAuthenticated = BoolFalse and op.opOutcome = Success }
