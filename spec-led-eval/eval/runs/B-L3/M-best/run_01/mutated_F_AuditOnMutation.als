// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-Tenant Task Management with Per-Task Sharing and Audit.
// Self-contained Alloy 6 model.

abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig Relationship {}
one sig OutsiderRel, InTeamNoneRel, ShareeRel, TeamAdminRel, OwnerRel extends Relationship {}

abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchFields, PatchShares, DeleteTask, GetAudit extends OperationKind {}

abstract sig AuditOp {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOp {}

sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam: one Team,
  owner: one User,
  sharedWith: set User
}

sig AuditEntry {
  auditTask: one Task,
  actor: one User,
  actorRole: one Role,
  auditOp: one AuditOp
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone Task,
  authenticated: one Bool,
  succeeded: one Bool,
  emits: set AuditEntry
}

// Permission matrix encoded as a singleton-sig field.
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// ----- Non-empty universe (witnesses for every dynamic sig) ---------------

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Operation
}

// ----- Domain integrity --------------------------------------------------

// Each task's owner is in the task's team.
fact F_OwnerSameTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}

// The owner is not also listed as a sharee.
fact F_OwnerNotSharee {
  all t: Task | t.owner not in t.sharedWith
}

// FR-012: sharees must be in the same team as the task.
fact F_ShareeSameTeam {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}

// ----- Permission matrix (contracts/http-api.md) -------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (OwnerRel -> GetTask) +
    (OwnerRel -> PatchFields) +
    (OwnerRel -> PatchShares) +
    (OwnerRel -> DeleteTask) +
    (OwnerRel -> GetAudit) +
    (TeamAdminRel -> GetTask) +
    (TeamAdminRel -> PatchFields) +
    (TeamAdminRel -> DeleteTask) +
    (TeamAdminRel -> GetAudit) +
    (ShareeRel -> GetTask) +
    (ShareeRel -> PatchFields) +
    (ShareeRel -> GetAudit)
}

// ----- Relationship resolution ------------------------------------------

// rel[u, t] is the relationship of user u to task t.
// Cases are mutually exclusive; the result is a singleton.
fun rel[u: User, t: Task]: Relationship {
  { r: Relationship |
    (u = t.owner and r = OwnerRel) or
    (u != t.owner and u.userTeam != t.taskTeam and r = OutsiderRel) or
    (u != t.owner and u.userTeam = t.taskTeam and u.userRole = TeamAdmin and r = TeamAdminRel) or
    (u != t.owner and u.userTeam = t.taskTeam and u.userRole = Member and u in t.sharedWith and r = ShareeRel) or
    (u != t.owner and u.userTeam = t.taskTeam and u.userRole = Member and u not in t.sharedWith and r = InTeamNoneRel)
  }
}

// ----- Operation shape facts --------------------------------------------

// POST has no target (the task is being created); all other ops have one target.
fact F_OperationTargetShape {
  all op: Operation | op.kind = PostTasks implies (no op.target)
  all op: Operation | op.kind != PostTasks implies (one op.target)
}

// FR-001: any successful operation must be authenticated.
fact F_AuthRequired {
  all op: Operation | op.succeeded = True implies op.authenticated = True
}

// FR-006 / FR-014: cross-team and in-team-no-rel callers cannot succeed.
fact F_CrossTeamIsolation {
  all op: Operation |
    (some op.target and
     rel[op.caller, op.target] in (OutsiderRel + InTeamNoneRel))
      implies op.succeeded = False
}

// FR-011 / Q3: sharees cannot delete; their DELETE attempts must fail.
fact F_ShareeNoDelete {
  all op: Operation |
    (op.kind = DeleteTask and some op.target and
     rel[op.caller, op.target] = ShareeRel)
      implies op.succeeded = False
}

// FR-010 / Q1: only the owner can change shared_with.
fact F_OwnerOnlyShareControl {
  all op: Operation |
    (op.kind = PatchShares and op.succeeded = True and some op.target)
      implies op.caller = op.target.owner
}

// LeastPrivilege: successful targeted operations must lie in the matrix.
fact F_LeastPrivilege {
  all op: Operation |
    (op.succeeded = True and op.kind != PostTasks and some op.target)
      implies ((rel[op.caller, op.target] -> op.kind) in PermMatrix.Allowed)
}

// ----- Audit facts ------------------------------------------------------

// FR-015 / FR-018: every successful mutating op emits >=1 audit entry;
// reads emit none; failed ops emit none (validation-before-mutation).
fact F_AuditOnMutation { /* MUTATED — body cleared by validator */ }

// FR-017: each audit entry is emitted by exactly one operation
// (append-only: no aliasing / re-attribution / shared ownership).
fact F_AuditEntryUnique {
  all ae: AuditEntry | one op: Operation | ae in op.emits
}

// FR-016 / FR-002: attribution snapshot — actor and role recorded faithfully.
fact F_AuditAttribution {
  all op: Operation, ae: op.emits |
    ae.actor = op.caller and
    ae.actorRole = op.caller.userRole
}

// FR-013 / FR-015: audit-op code matches operation kind.
fact F_AuditOpKind {
  all op: Operation, ae: op.emits |
    (op.kind = PostTasks    implies ae.auditOp = Created) and
    (op.kind = DeleteTask   implies ae.auditOp = Deleted) and
    (op.kind = PatchFields  implies ae.auditOp = Edited) and
    (op.kind = PatchShares  implies ae.auditOp in (Shared + Unshared))
}

// FR-019: audit entry's task matches the operation's target for non-POST ops.
fact F_AuditTaskMatch {
  all op: Operation, ae: op.emits |
    op.kind != PostTasks implies ae.auditTask = op.target
}

// =========================================================================
// Predicates and assertions
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003 FR-005
pred LeastPrivilege {
  all op: Operation |
    (op.succeeded = True and some op.target) implies
      ((rel[op.caller, op.target] -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.succeeded = True implies op.authenticated = True
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015
pred AuditCompleteness {
  (all op: Operation |
    (op.succeeded = True and
     op.kind in (PostTasks + PatchFields + PatchShares + DeleteTask))
      implies (some op.emits)) and
  (all ae: AuditEntry | one op: Operation | ae in op.emits)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017 (audit entries are immutable, no re-attribution)
pred AppendOnly {
  all ae: AuditEntry | one op: Operation | ae in op.emits
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  all op: Operation, ae: op.emits |
    ae.actor = op.caller and ae.actorRole = op.caller.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  all t: Task | (one t.owner) and (one t.taskTeam) and t.owner.userTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-010 / Q1=A (owner-only share control)
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = PatchShares and op.succeeded = True and some op.target)
      implies op.caller = op.target.owner
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, FR-006 (byte-equivalent 404)
pred NoInformationLeakage {
  no op: Operation |
    some op.target and
    rel[op.caller, op.target] in (OutsiderRel + InTeamNoneRel) and
    op.succeeded = True
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-015, FR-018
pred ValidationBeforeMutation {
  all op: Operation | op.succeeded = False implies (no op.emits)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Outsider and in-team-no-rel are denied on every per-task action.
  all k: (GetTask + PatchFields + PatchShares + DeleteTask + GetAudit) |
    (OutsiderRel -> k) not in PermMatrix.Allowed
  all k: (GetTask + PatchFields + PatchShares + DeleteTask + GetAudit) |
    (InTeamNoneRel -> k) not in PermMatrix.Allowed
  // Sharee cannot delete and cannot change shares.
  (ShareeRel -> DeleteTask) not in PermMatrix.Allowed
  (ShareeRel -> PatchShares) not in PermMatrix.Allowed
  // Team admin cannot change shares (FR-005 / Q1=A).
  (TeamAdminRel -> PatchShares) not in PermMatrix.Allowed
  // Owner can do everything per-task.
  all k: (GetTask + PatchFields + PatchShares + DeleteTask + GetAudit) |
    (OwnerRel -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// =========================================================================
// Per-FR assertions
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | op.succeeded = True implies op.authenticated = True
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a (role comes from token, mirrored in audit actor_role)
pred FR_002_RoleFromToken {
  all op: Operation, ae: op.emits | ae.actorRole = op.caller.userRole
}
assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (members can act only via owner/sharee relationship)
pred FR_003_MemberPermissions {
  all op: Operation |
    (op.succeeded = True and some op.target and op.caller.userRole = Member) implies
      ((rel[op.caller, op.target] -> op.kind) in PermMatrix.Allowed)
}
assert FR_003_MemberPermissions { FR_003_MemberPermissions }
check FR_003_MemberPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (in-team non-owner non-sharee members blocked)
pred FR_004_NoUnauthorisedMember {
  no op: Operation |
    op.caller.userRole = Member and
    some op.target and
    rel[op.caller, op.target] = InTeamNoneRel and
    op.succeeded = True
}
assert FR_004_NoUnauthorisedMember { FR_004_NoUnauthorisedMember }
check FR_004_NoUnauthorisedMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (admin within team can act on any task except shares)
pred FR_005_AdminPermissions {
  all op: Operation |
    (op.succeeded = True and some op.target and
     op.caller.userRole = TeamAdmin and
     op.caller.userTeam = op.target.taskTeam) implies
      ((rel[op.caller, op.target] -> op.kind) in PermMatrix.Allowed)
}
assert FR_005_AdminPermissions { FR_005_AdminPermissions }
check FR_005_AdminPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (cross-team isolation invariant under role)
pred FR_006_CrossTeamIsolation {
  no op: Operation |
    op.succeeded = True and
    some op.target and
    op.caller.userTeam != op.target.taskTeam
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (owner & team immutable; owner in same team)
pred FR_009_ImmutableOwnerTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}
assert FR_009_ImmutableOwnerTeam { FR_009_ImmutableOwnerTeam }
check FR_009_ImmutableOwnerTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1=A (only owner changes shared_with)
pred FR_010_OwnerOnlyShares {
  all op: Operation |
    (op.kind = PatchShares and op.succeeded = True and some op.target)
      implies op.caller = op.target.owner
}
assert FR_010_OwnerOnlyShares { FR_010_OwnerOnlyShares }
check FR_010_OwnerOnlyShares for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B (sharee cannot delete)
pred FR_011_ShareeNoDelete {
  no op: Operation |
    op.kind = DeleteTask and
    some op.target and
    rel[op.caller, op.target] = ShareeRel and
    op.succeeded = True
}
assert FR_011_ShareeNoDelete { FR_011_ShareeNoDelete }
check FR_011_ShareeNoDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (cross-team sharing forbidden)
pred FR_012_SameTeamShare {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_SameTeamShare { FR_012_SameTeamShare }
check FR_012_SameTeamShare for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (share/unshare PATCH emits a Shared/Unshared audit entry)
pred FR_013_ShareAuditEntry {
  all op: Operation, ae: op.emits |
    op.kind = PatchShares implies ae.auditOp in (Shared + Unshared)
}
assert FR_013_ShareAuditEntry { FR_013_ShareAuditEntry }
check FR_013_ShareAuditEntry for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent 404 — no leakage of denied resources)
pred FR_014_ByteEquivalent {
  no op: Operation |
    some op.target and
    rel[op.caller, op.target] in (OutsiderRel + InTeamNoneRel) and
    op.succeeded = True
}
assert FR_014_ByteEquivalent { FR_014_ByteEquivalent }
check FR_014_ByteEquivalent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (one audit entry per logical mutation; no state without audit)
pred FR_015_AuditPerMutation {
  (all op: Operation |
    (op.succeeded = True and
     op.kind in (PostTasks + PatchFields + PatchShares + DeleteTask))
      implies (some op.emits)) and
  (all ae: AuditEntry | one op: Operation | ae in op.emits)
}
assert FR_015_AuditPerMutation { FR_015_AuditPerMutation }
check FR_015_AuditPerMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (every audit entry carries the required fields)
pred FR_016_AuditFields {
  all ae: AuditEntry |
    (one ae.auditTask) and (one ae.actor) and (one ae.actorRole) and (one ae.auditOp)
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entries are immutable; cannot be re-attributed)
pred FR_017_AuditImmutable {
  all ae: AuditEntry | one op: Operation | ae in op.emits
}
assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (no observable state change without an atomic audit entry)
pred FR_018_AuditAtomic {
  (all op: Operation | op.succeeded = False implies (no op.emits)) and
  (all op: Operation |
    (op.succeeded = True and
     op.kind in (PostTasks + PatchFields + PatchShares + DeleteTask))
      implies (some op.emits))
}
assert FR_018_AuditAtomic { FR_018_AuditAtomic }
check FR_018_AuditAtomic for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (audit reads gated to owner/sharee/admin)
pred FR_019_AuditReadAccess {
  all op: Operation |
    (op.kind = GetAudit and op.succeeded = True and some op.target) implies
      (rel[op.caller, op.target] in (OwnerRel + ShareeRel + TeamAdminRel))
}
assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MissingAudit { some op: Operation | op.succeeded = True and op.kind = PatchFields and some op.target and no op.emits }
