// === feature_model.als — Alloy model for 008-task-sharing (B-L3) ===
// Multi-tenant task management with per-task sharing, cross-team isolation,
// and per-event append-only audit.

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchTaskFields, PatchTaskShare, DeleteTask, GetAudit extends OperationKind {}

abstract sig Relationship {}
one sig OutsiderRel, InTeamNoneRel, ShareeRel, AdminRel, OwnerRel extends Relationship {}

abstract sig AuditOp {}
one sig CreatedOp, EditedOp, DeletedOp, SharedOp, UnsharedOp extends AuditOp {}

sig Team {}

sig User {
  team: one Team,
  role: one Role
}

sig Task {
  taskTeam: one Team,
  owner: one User,
  sharedWith: set User
}

sig AuditEntry {
  forTask: one Task,
  actor: one User,
  actorRole: one Role,
  auditOp: one AuditOp
}

sig Operation {
  caller: one User,
  authenticated: one Bool,
  target: lone Task,
  kind: one OperationKind,
  successful: one Bool,
  producedAudit: set AuditEntry
}

// Permission matrix from contracts/http-api.md — singleton-sig field.
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// Non-empty universe so that "all x: T | P[x]" predicates don't pass vacuously.
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some Operation
}

// Encodes the closed-world (Relationship × OperationKind) allow table from
// contracts/http-api.md "Permission matrix".
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (OwnerRel -> GetTask) + (OwnerRel -> PatchTaskFields) + (OwnerRel -> PatchTaskShare) +
    (OwnerRel -> DeleteTask) + (OwnerRel -> GetAudit) +
    (AdminRel -> GetTask) + (AdminRel -> PatchTaskFields) +
    (AdminRel -> DeleteTask) + (AdminRel -> GetAudit) +
    (ShareeRel -> GetTask) + (ShareeRel -> PatchTaskFields) + (ShareeRel -> GetAudit)
}

// data-model.md: a task's team_id is denormalised from its owner's team_id
// (and both are immutable per FR-009).
fact F_OwnerInTaskTeam {
  all t: Task | t.owner.team = t.taskTeam
}

// FR-012: sharees must be in the same team as the task owner.
fact F_SharedWithSameTeam {
  all t: Task | all u: t.sharedWith | u.team = t.taskTeam
}

// Owner is implicitly in the read-set, not in sharedWith.
fact F_OwnerNotSharee {
  all t: Task | t.owner not in t.sharedWith
}

// FR-001/FR-002a: no successful operation without authentication.
fact F_AuthRequired {
  all op: Operation | op.successful = BTrue implies op.authenticated = BTrue
}

// PostTasks has no target; every other op kind references exactly one task.
fact F_TargetForTaskOps {
  all op: Operation | op.kind = PostTasks implies no op.target
  all op: Operation | op.kind != PostTasks implies one op.target
}

// Caller-to-task relationship classification (research.md action × relationship table).
pred hasRel[u: User, t: Task, r: Relationship] {
  (r = OwnerRel and u = t.owner)
  or (r = AdminRel and u != t.owner and u.role = TeamAdmin and u.team = t.taskTeam)
  or (r = ShareeRel and u != t.owner and u.role = Member and u.team = t.taskTeam and u in t.sharedWith)
  or (r = InTeamNoneRel and u != t.owner and u.role = Member and u.team = t.taskTeam and u not in t.sharedWith)
  or (r = OutsiderRel and u.team != t.taskTeam)
}

// Core LeastPrivilege fact: a task-targeted operation succeeds only if the
// caller's relationship to the target is in the allowed cells of the matrix.
fact F_OnlyAllowedSucceeds {
  all op: Operation |
    (op.successful = BTrue and op.kind != PostTasks) implies
      (some r: Relationship | hasRel[op.caller, op.target, r] and (r -> op.kind) in PermMatrix.Allowed)
}

// FR-015: every successful mutation produces at least one audit entry.
fact F_AuditCompleteness { /* MUTATED — body cleared by validator */ }

// FR-015 reverse: no orphan audit entries — every entry traces to an operation.
fact F_NoOrphanAudit {
  all ae: AuditEntry | some op: Operation | ae in op.producedAudit
}

// FR-016: audit entries record the actual caller, the caller's role at the
// time, and the actual target task.
fact F_AuditAttribution {
  all op: Operation, ae: op.producedAudit |
    ae.actor = op.caller
    and ae.actorRole = op.caller.role
    and (some op.target implies ae.forTask = op.target)
}

// FR-017: audit entries are append-only — no two distinct operations share
// an audit entry (would represent a re-used / rewritten entry).
fact F_AppendOnlyAudit {
  all disj op1, op2: Operation | no (op1.producedAudit & op2.producedAudit)
}

// FR-018: rollback semantics — a failed operation produces no audit row.
fact F_NoAuditOnFailure {
  all op: Operation | op.successful = BFalse implies no op.producedAudit
}

// =========================================================================
// PATTERN PREDICATES AND ASSERTIONS
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003..006, FR-010, FR-011
pred LeastPrivilege {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind != PostTasks) implies
      (some r: Relationship | hasRel[op.caller, op.target, r] and (r -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md authorisation table; FR-003/005/010/011
pred PermissionGrounding {
  no OutsiderRel.(PermMatrix.Allowed)
  no InTeamNoneRel.(PermMatrix.Allowed)
  PatchTaskShare in OwnerRel.(PermMatrix.Allowed)
  PatchTaskShare not in AdminRel.(PermMatrix.Allowed)
  PatchTaskShare not in ShareeRel.(PermMatrix.Allowed)
  DeleteTask not in ShareeRel.(PermMatrix.Allowed)
  DeleteTask in OwnerRel.(PermMatrix.Allowed)
  DeleteTask in AdminRel.(PermMatrix.Allowed)
  GetTask in ShareeRel.(PermMatrix.Allowed)
  GetAudit in ShareeRel.(PermMatrix.Allowed)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-002a
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.successful = BTrue implies op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md PATCH→audit-entries decomposition
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind in (PostTasks + PatchTaskFields + PatchTaskShare + DeleteTask))
      implies (some op.producedAudit)
  all ae: AuditEntry | some op: Operation | ae in op.producedAudit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  all disj op1, op2: Operation | no (op1.producedAudit & op2.producedAudit)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  some AuditEntry
  all op: Operation, ae: op.producedAudit |
    ae.actor = op.caller and ae.actorRole = op.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; spec.md FR-009
pred OwnershipExclusivity {
  some Task
  all t: Task | one t.owner and t.owner.team = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-010 (owner-only share control), SC-011
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind = PatchTaskShare and some op.target)
      implies op.caller = op.target.owner
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014 (byte-equivalent 404), SC-003
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    (op.kind != PostTasks and some op.target and op.caller.team != op.target.taskTeam)
      implies op.successful = BFalse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// =========================================================================
// FEATURE-SPECIFIC FR PREDICATES
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (OAuth required; 401 before any business logic)
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.successful = BTrue implies op.authenticated = BTrue
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a (one team and one role per user)
pred FR_002_OneTeamOneRole {
  some User
  all u: User | one u.team and one u.role
}
assert FR_002_OneTeamOneRole { FR_002_OneTeamOneRole }
check FR_002_OneTeamOneRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (member with no relationship cannot access)
pred FR_004_NonOwnerNonShareeNoAccess {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind != PostTasks and some op.target and op.caller.role = Member)
      implies (op.caller = op.target.owner or op.caller in op.target.sharedWith)
}
assert FR_004_NonOwnerNonShareeNoAccess { FR_004_NonOwnerNonShareeNoAccess }
check FR_004_NonOwnerNonShareeNoAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (team admin may NOT change shared_with even in own team)
pred FR_005_AdminBoundedByOwnerOnShare {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind = PatchTaskShare and some op.target
     and op.caller.role = TeamAdmin)
      implies op.caller = op.target.owner
}
assert FR_005_AdminBoundedByOwnerOnShare { FR_005_AdminBoundedByOwnerOnShare }
check FR_005_AdminBoundedByOwnerOnShare for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (absolute cross-team isolation)
pred FR_006_NoCrossTeam {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind != PostTasks and some op.target)
      implies op.caller.team = op.target.taskTeam
}
assert FR_006_NoCrossTeam { FR_006_NoCrossTeam }
check FR_006_NoCrossTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (owner_id and team_id immutable; owner.team = task.team)
pred FR_009_OwnerTeamConsistent {
  some Task
  all t: Task | t.owner.team = t.taskTeam
}
assert FR_009_OwnerTeamConsistent { FR_009_OwnerTeamConsistent }
check FR_009_OwnerTeamConsistent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (only the owner may change shared_with), SC-011
pred FR_010_OwnerOnlyShare {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind = PatchTaskShare and some op.target)
      implies op.caller = op.target.owner
}
assert FR_010_OwnerOnlyShare { FR_010_OwnerOnlyShare }
check FR_010_OwnerOnlyShare for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (sharee MAY NOT delete; delete is owner-or-admin)
pred FR_011_ShareeNoDelete {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind = DeleteTask and some op.target)
      implies (op.caller = op.target.owner
               or (op.caller.role = TeamAdmin and op.caller.team = op.target.taskTeam))
}
assert FR_011_ShareeNoDelete { FR_011_ShareeNoDelete }
check FR_011_ShareeNoDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (sharees must be members of the owner's team)
pred FR_012_NoCrossTeamShare {
  some Task
  all t: Task | all u: t.sharedWith | u.team = t.taskTeam
}
assert FR_012_NoCrossTeamShare { FR_012_NoCrossTeamShare }
check FR_012_NoCrossTeamShare for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (share/unshare events produce audit entries)
pred FR_013_ShareAudit {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind = PatchTaskShare and some op.target)
      implies (some op.producedAudit)
}
assert FR_013_ShareAudit { FR_013_ShareAudit }
check FR_013_ShareAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent 404 for callers outside the read-set)
pred FR_014_NoLeakage {
  some Operation
  all op: Operation |
    (op.kind != PostTasks and some op.target and op.caller.team != op.target.taskTeam)
      implies op.successful = BFalse
}
assert FR_014_NoLeakage { FR_014_NoLeakage }
check FR_014_NoLeakage for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (per-event audit: every successful mutation → audit row)
pred FR_015_PerEventAudit {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind in (PostTasks + PatchTaskFields + PatchTaskShare + DeleteTask))
      implies (some op.producedAudit)
}
assert FR_015_PerEventAudit { FR_015_PerEventAudit }
check FR_015_PerEventAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit fields: actor, role snapshot, task_id)
pred FR_016_AuditFields {
  some AuditEntry
  all op: Operation, ae: op.producedAudit |
    ae.actor = op.caller
    and ae.actorRole = op.caller.role
    and (some op.target implies ae.forTask = op.target)
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entries immutable; never re-used or rewritten)
pred FR_017_AuditImmutable {
  some AuditEntry
  all disj op1, op2: Operation | no (op1.producedAudit & op2.producedAudit)
}
assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (no observable state change without audit; rollback semantics)
pred FR_018_NoStateWithoutAudit {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind in (PostTasks + PatchTaskFields + PatchTaskShare + DeleteTask))
      implies (some op.producedAudit)
  all ae: AuditEntry | some op: Operation | ae in op.producedAudit and op.successful = BTrue
}
assert FR_018_NoStateWithoutAudit { FR_018_NoStateWithoutAudit }
check FR_018_NoStateWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (audit endpoint readable by owner/sharee/admin only)
pred FR_019_AuditReadable {
  some Operation
  all op: Operation |
    (op.successful = BTrue and op.kind = GetAudit and some op.target)
      implies (op.caller = op.target.owner
               or op.caller in op.target.sharedWith
               or (op.caller.role = TeamAdmin and op.caller.team = op.target.taskTeam))
}
assert FR_019_AuditReadable { FR_019_AuditReadable }
check FR_019_AuditReadable for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some op: Operation | op.successful = BTrue and op.kind = PatchTaskFields and one op.target and op.caller = op.target.owner and op.authenticated = BTrue and no op.producedAudit }
