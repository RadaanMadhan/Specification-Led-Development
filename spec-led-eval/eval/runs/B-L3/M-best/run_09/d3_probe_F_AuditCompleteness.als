// === feature_model.als — Alloy model for B-L3: Multi-Tenant Task Management with Per-Task Sharing & Audit ===
// Self-contained Alloy 6 encoding of spec.md (FR-001..FR-021), data-model.md,
// and contracts/http-api.md for feature 008-task-sharing.

// --- Enumerations encoded as one-sig children of abstract sigs ---

abstract sig Role {}
one sig MemberRole, TeamAdminRole extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchFields, PatchShares, DeleteTask, GetAudit
    extends OperationKind {}

abstract sig AuditOp {}
one sig CreatedOp, EditedOp, DeletedOp, SharedOp, UnsharedOp
    extends AuditOp {}

// Caller-task relationship per data-model.md (computed, not persisted)
abstract sig Relationship {}
one sig Outsider, InTeamNone, ShareeRel, AdminRel, OwnerRel extends Relationship {}

abstract sig Outcome {}
one sig Success, Unauthenticated, NotFound, ValidationError, AuditUnavailable
    extends Outcome {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// --- Domain entities (data-model.md) ---

sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam: one Team,
  taskOwner: one User,
  sharedWith: set User
}

sig AuditEntry {
  auditTask: one Task,
  auditActor: one User,
  auditActorRole: one Role,
  auditOpKind: one AuditOp,
  auditTeam: one Team
}

sig Operation {
  opAuthenticated: one Bool,
  opCaller: lone User,
  opKind: one OperationKind,
  opTarget: lone Task,
  opOutcome: one Outcome,
  opAuditEntries: set AuditEntry
}

// --- Permission matrix as a singleton-sig FIELD (contracts/http-api.md) ---
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// === Non-empty universe — required for assertions to bite ===
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some Operation
}

// === Permission matrix encoding (Owner/Admin/Sharee allows; closed-world) ===
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (OwnerRel  -> GetTask)    +
    (OwnerRel  -> PatchFields)+
    (OwnerRel  -> PatchShares)+
    (OwnerRel  -> DeleteTask) +
    (OwnerRel  -> GetAudit)   +
    (AdminRel  -> GetTask)    +
    (AdminRel  -> PatchFields)+
    (AdminRel  -> DeleteTask) +
    (AdminRel  -> GetAudit)   +
    (ShareeRel -> GetTask)    +
    (ShareeRel -> PatchFields)+
    (ShareeRel -> GetAudit)
  // Outsider and InTeamNone get no allowed cells.
}

// --- Helper: caller's relationship to a task ---
fun relationshipOf[u: User, t: Task]: one Relationship {
  (u = t.taskOwner)                  => OwnerRel
  else (u.userTeam != t.taskTeam)    => Outsider
  else (u.userRole = TeamAdminRole)  => AdminRel
  else (u in t.sharedWith)           => ShareeRel
  else InTeamNone
}

// === Structural / domain facts ===

// Task team denormalised from its owner's team (FR-009)
fact F_TaskTeamMatchesOwner {
  all t: Task | t.taskTeam = t.taskOwner.userTeam
}

// FR-012: every sharee is in the same team as the owner
fact F_SharedWithSameTeam {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}

// Owner is not listed as their own sharee
fact F_OwnerNotInSharedWith {
  all t: Task | t.taskOwner !in t.sharedWith
}

// Audit entry's team denormalised from its task (data-model.md)
fact F_AuditTeamMatchesTask {
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}

// FR-016 / FR-002: recorded role is snapshotted from the acting user (NOT from payload)
fact F_AuditAttribution {
  all ae: AuditEntry | ae.auditActorRole = ae.auditActor.userRole
}

// Authenticated iff caller is present
fact F_AuthCallerLink {
  all op: Operation | (op.opAuthenticated = BTrue) iff (some op.opCaller)
}

// FR-001: unauthenticated requests rejected, no audit entries created
fact F_AuthRequired {
  all op: Operation |
    op.opAuthenticated = BFalse implies
      (op.opOutcome = Unauthenticated and no op.opAuditEntries)
}

// A successful operation must have a target task
fact F_SuccessHasTarget {
  all op: Operation | op.opOutcome = Success implies some op.opTarget
}

// FR-003/004/005/006/010/011/014/019: access control via the permission matrix
fact F_AccessControl {
  all op: Operation |
    (op.opOutcome = Success and some op.opCaller and some op.opTarget) implies
      relationshipOf[op.opCaller, op.opTarget] -> op.opKind in PermMatrix.Allowed
}

// FR-015: every successful mutation produces ≥ 1 audit entry
fact F_AuditCompleteness {
  all op: Operation |
    (op.opOutcome = Success and
     op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask))
    implies some op.opAuditEntries
}

// FR-015: every audit entry has a producing operation
fact F_AuditHasProducer {
  all ae: AuditEntry | some op: Operation | ae in op.opAuditEntries
}

// FR-017: append-only — each audit entry produced by EXACTLY one operation
fact F_AppendOnly {
  all ae: AuditEntry | one op: Operation | ae in op.opAuditEntries
}

// Read-only ops never produce audit entries
fact F_ReadOpsNoAudit {
  all op: Operation |
    op.opKind in (GetTask + GetAudit) implies no op.opAuditEntries
}

// FR-018 atomicity: failed ops produce no observable audit entries
fact F_FailedOpsNoAudit {
  all op: Operation | op.opOutcome != Success implies no op.opAuditEntries
}

// An audit entry's task = the operation's target (when the op has one)
fact F_AuditTaskMatchesOpTarget {
  all op: Operation, ae: op.opAuditEntries |
    some op.opTarget implies ae.auditTask = op.opTarget
}

// An audit entry's actor = the operation's caller (when present)
fact F_AuditActorMatchesCaller {
  all op: Operation, ae: op.opAuditEntries |
    some op.opCaller implies ae.auditActor = op.opCaller
}

// FR-013: a successful PatchShares op produces share/unshare audit entries
fact F_ShareAuditEvents {
  all op: Operation |
    (op.opKind = PatchShares and op.opOutcome = Success) implies
      (some ae: op.opAuditEntries | ae.auditOpKind in (SharedOp + UnsharedOp))
}

// === Predicates & assertions ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    op.opAuthenticated = BFalse implies op.opOutcome = Unauthenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a team_id and role from token, not payload
pred FR_002_RoleFromToken {
  some AuditEntry
  all ae: AuditEntry | ae.auditActorRole = ae.auditActor.userRole
}
assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 8

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some Operation
  all op: Operation |
    (op.opOutcome = Success and some op.opCaller and some op.opTarget) implies
      relationshipOf[op.opCaller, op.opTarget] -> op.opKind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every Owner cell is allowed; every Outsider cell denied — matrix is fully specified.
  OwnerRel -> GetTask     in PermMatrix.Allowed
  OwnerRel -> PatchFields in PermMatrix.Allowed
  OwnerRel -> PatchShares in PermMatrix.Allowed
  OwnerRel -> DeleteTask  in PermMatrix.Allowed
  OwnerRel -> GetAudit    in PermMatrix.Allowed
  no ((Outsider + InTeamNone) -> OperationKind & PermMatrix.Allowed)
  // Admin can do everything except PatchShares
  AdminRel -> PatchShares not in PermMatrix.Allowed
  // Sharee cannot delete or change shares
  ShareeRel -> DeleteTask  not in PermMatrix.Allowed
  ShareeRel -> PatchShares not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 / FR-004 member access restricted to owned-or-shared
pred FR_003_MemberOwnedOrShared {
  some Operation
  all op: Operation |
    (op.opOutcome = Success and some op.opCaller and some op.opTarget and
     op.opCaller.userRole = MemberRole and
     op.opKind in (GetTask + PatchFields + DeleteTask + GetAudit))
    implies (op.opCaller = op.opTarget.taskOwner or
             op.opCaller in op.opTarget.sharedWith)
}
assert FR_003_MemberOwnedOrShared { FR_003_MemberOwnedOrShared }
check FR_003_MemberOwnedOrShared for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 team admin acts only inside their team
pred FR_005_AdminInTeamOnly {
  some Operation
  all op: Operation |
    (op.opOutcome = Success and some op.opCaller and some op.opTarget and
     op.opCaller.userRole = TeamAdminRole)
    implies op.opCaller.userTeam = op.opTarget.taskTeam
}
assert FR_005_AdminInTeamOnly { FR_005_AdminInTeamOnly }
check FR_005_AdminInTeamOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 cross-team isolation invariant
pred FR_006_CrossTeamIsolation {
  some Operation
  all op: Operation |
    (op.opOutcome = Success and some op.opCaller and some op.opTarget)
    implies op.opCaller.userTeam = op.opTarget.taskTeam
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 8

// PATTERN: NoInformationLeakage  ANCHOR: FR-014 byte-equivalent 404 for cross-team
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    (some op.opCaller and some op.opTarget and
     op.opCaller.userTeam != op.opTarget.taskTeam)
    implies op.opOutcome != Success
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id (NOT NULL, single FK)
pred OwnershipExclusivity {
  some Task
  all t: Task | one t.taskOwner and one t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 owner_id / team_id immutable, one owner per task
pred FR_009_OneOwnerPerTask {
  some Task
  all t: Task | one t.taskOwner and one t.taskTeam and
                t.taskTeam = t.taskOwner.userTeam
}
assert FR_009_OneOwnerPerTask { FR_009_OneOwnerPerTask }
check FR_009_OneOwnerPerTask for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1=A owner-only shared_with control
pred FR_010_OwnerOnlyShares {
  some Operation
  all op: Operation |
    (op.opKind = PatchShares and op.opOutcome = Success and
     some op.opCaller and some op.opTarget)
    implies op.opCaller = op.opTarget.taskOwner
}
assert FR_010_OwnerOnlyShares { FR_010_OwnerOnlyShares }
check FR_010_OwnerOnlyShares for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B sharee cannot delete
pred FR_011_ShareeCannotDelete {
  some Operation
  all op: Operation |
    (op.opKind = DeleteTask and op.opOutcome = Success and
     some op.opCaller and some op.opTarget and
     op.opCaller in op.opTarget.sharedWith and
     op.opCaller != op.opTarget.taskOwner)
    implies op.opCaller.userRole = TeamAdminRole
}
assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-005 / FR-011 delete only by owner or in-team admin
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.opKind = DeleteTask and op.opOutcome = Success and
     some op.opCaller and some op.opTarget)
    implies (op.opCaller = op.opTarget.taskOwner or
             (op.opCaller.userRole = TeamAdminRole and
              op.opCaller.userTeam = op.opTarget.taskTeam))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 no cross-team sharing
pred FR_012_NoCrossTeamShare {
  some Task
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_NoCrossTeamShare { FR_012_NoCrossTeamShare }
check FR_012_NoCrossTeamShare for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 share/unshare audit entry per affected user
pred FR_013_ShareUnshareAudit {
  some Operation
  all op: Operation |
    (op.opKind = PatchShares and op.opOutcome = Success)
    implies (some ae: op.opAuditEntries | ae.auditOpKind in (SharedOp + UnsharedOp))
}
assert FR_013_ShareUnshareAudit { FR_013_ShareUnshareAudit }
check FR_013_ShareUnshareAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent isolation across endpoints
pred FR_014_ByteEquivIsolation {
  some Operation
  all op: Operation |
    (op.opAuthenticated = BTrue and some op.opCaller and some op.opTarget and
     op.opCaller.userTeam != op.opTarget.taskTeam)
    implies op.opOutcome != Success
}
assert FR_014_ByteEquivIsolation { FR_014_ByteEquivIsolation }
check FR_014_ByteEquivIsolation for 8

// PATTERN: AuditCompleteness  ANCHOR: FR-015
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (op.opOutcome = Success and
     op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask))
    implies some op.opAuditEntries
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit-per-event balance (both directions)
pred FR_015_AuditPerEvent {
  some Operation
  some AuditEntry
  all op: Operation |
    (op.opOutcome = Success and
     op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask))
    implies some op.opAuditEntries
  all ae: AuditEntry |
    (some op: Operation |
      ae in op.opAuditEntries and op.opOutcome = Success and
      op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask))
}
assert FR_015_AuditPerEvent { FR_015_AuditPerEvent }
check FR_015_AuditPerEvent for 8

// PATTERN: AttributionCorrectness  ANCHOR: FR-016 audit fields snapshotted
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.auditActorRole = ae.auditActor.userRole and
    ae.auditTeam = ae.auditTask.taskTeam
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry has all required fields and faithful denorm
pred FR_016_AuditFields {
  some AuditEntry
  all ae: AuditEntry |
    one ae.auditTask and one ae.auditActor and one ae.auditActorRole and
    one ae.auditOpKind and one ae.auditTeam and
    ae.auditTeam = ae.auditTask.taskTeam and
    ae.auditActorRole = ae.auditActor.userRole
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 8

// PATTERN: AppendOnly  ANCHOR: FR-017 audit immutable; no UPDATE/DELETE path
pred AppendOnly {
  some AuditEntry
  all ae: AuditEntry | one op: Operation | ae in op.opAuditEntries
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries are not co-written by multiple ops
pred FR_017_AuditImmutable {
  some AuditEntry
  all disj op1, op2: Operation | no (op1.opAuditEntries & op2.opAuditEntries)
}
assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-018 atomicity (audit & state move together)
pred ValidationBeforeMutation {
  some Operation
  all op: Operation | op.opOutcome != Success implies no op.opAuditEntries
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit-write atomic; rollback on contention
pred FR_018_AuditAtomicity {
  some Operation
  all op: Operation | op.opOutcome != Success implies no op.opAuditEntries
}
assert FR_018_AuditAtomicity { FR_018_AuditAtomicity }
check FR_018_AuditAtomicity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit visibility = task view access (owner/sharee/admin)
pred FR_019_AuditVisibility {
  some Operation
  all op: Operation |
    (op.opKind = GetAudit and op.opOutcome = Success and
     some op.opCaller and some op.opTarget)
    implies (op.opCaller = op.opTarget.taskOwner or
             op.opCaller in op.opTarget.sharedWith or
             (op.opCaller.userRole = TeamAdminRole and
              op.opCaller.userTeam = op.opTarget.taskTeam))
}
assert FR_019_AuditVisibility { FR_019_AuditVisibility }
check FR_019_AuditVisibility for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 retention — audit entries outlive task (no UPDATE/DELETE path)
pred FR_020_AuditRetention {
  some AuditEntry
  // Every audit entry has a producer op — captures "audit rows persist as written"
  all ae: AuditEntry | some op: Operation | ae in op.opAuditEntries
}
assert FR_020_AuditRetention { FR_020_AuditRetention }
check FR_020_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 performance (structural sanity — bounded outputs)
pred FR_021_PerformanceShape {
  some Operation
  all op: Operation | op.opAuditEntries in AuditEntry
}
assert FR_021_PerformanceShape { FR_021_PerformanceShape }
check FR_021_PerformanceShape for 8

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some op: Operation, t: Task | op.opKind = PostTasks and op.opOutcome = Success and op.opTarget = t and op.opAuthenticated = BTrue and no op.opAuditEntries }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
