// === feature_model.als — Alloy model for 008 Multi-Tenant Task Management ===
// Self-contained Alloy 6 model. Encodes the per-task sharing, cross-team
// isolation, and audit invariants for feature 008 (B-L3).

// ---------- Booleans ----------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Domain enums (data-model.md) ----------
abstract sig Role {}
one sig Member, TeamAdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig AuditOp {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOp {}

// ---------- API surface (contracts/http-api.md endpoints) ----------
abstract sig OperationKind {}
one sig PostTasks, GetTaskById, PatchFields, PatchSharedWith,
        DeleteTaskKind, GetTaskAudit extends OperationKind {}

// ---------- Caller-to-task relationships (research / permission matrix) ----
abstract sig Relationship {}
one sig RelOutsider, RelInTeamNone, RelSharee, RelTeamAdmin, RelOwner
        extends Relationship {}

// ---------- Response shapes (FR-014 byte-equivalence) ----------
abstract sig ResponseShape {}
one sig RespOk, RespNotFound, RespValidationError,
        RespUnauthenticated, RespAuditUnavailable extends ResponseShape {}

// ---------- Concrete dynamic entities ----------
sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam: one Team,
  owner: one User,
  status: one TaskStatus,
  sharedWith: set User
}

sig AuditEntry {
  auditTask: one Task,
  actor: one User,
  actorRole: one Role,
  auditOp: one AuditOp,
  recordedBy: one Operation,
  affectedSharee: lone User
}

sig Operation {
  caller: one User,
  authenticated: one Bool,
  kind: one OperationKind,
  target: one Task,
  includesSharedWith: one Bool,
  successful: one Bool,
  response: one ResponseShape,
  effectiveRel: one Relationship
}

// ---------- Permission matrix as a singleton-sig field (Hard Rule 7) -------
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// ===========================================================================
// FACTS  (named so they can be cleared by the mutation tester)
// ===========================================================================

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Operation
}

// Permission matrix encoding contracts/http-api.md
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (RelOwner     -> GetTaskById)
    + (RelSharee    -> GetTaskById)
    + (RelTeamAdmin -> GetTaskById)
    + (RelOwner     -> PatchFields)
    + (RelSharee    -> PatchFields)
    + (RelTeamAdmin -> PatchFields)
    + (RelOwner     -> PatchSharedWith)
    + (RelOwner     -> DeleteTaskKind)
    + (RelTeamAdmin -> DeleteTaskKind)
    + (RelOwner     -> GetTaskAudit)
    + (RelSharee    -> GetTaskAudit)
    + (RelTeamAdmin -> GetTaskAudit)
}

// Structural: owner's team equals task's team (data-model.md).
fact F_OwnerInTaskTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}

// FR-012: shared_with users live in the owner's team.
fact F_SharedWithSameTeam {
  all t: Task | all u: t.sharedWith | u.userTeam = t.taskTeam
}

// Owner is implicitly in the read-set and is not duplicated into sharedWith.
fact F_OwnerNotInOwnSharedWith {
  all t: Task | t.owner not in t.sharedWith
}

// Derive Operation.effectiveRel from (caller, target) structurally.
// Precedence: Outsider > Owner > TeamAdmin > Sharee > InTeamNone.
fact F_RelationshipComputation {
  all op: Operation |
    ((op.caller.userTeam != op.target.taskTeam)
        implies op.effectiveRel = RelOutsider)
    and
    ((op.caller.userTeam = op.target.taskTeam and op.caller = op.target.owner)
        implies op.effectiveRel = RelOwner)
    and
    ((op.caller.userTeam = op.target.taskTeam
        and op.caller != op.target.owner
        and op.caller.userRole = TeamAdminRole)
        implies op.effectiveRel = RelTeamAdmin)
    and
    ((op.caller.userTeam = op.target.taskTeam
        and op.caller != op.target.owner
        and op.caller.userRole = Member
        and op.caller in op.target.sharedWith)
        implies op.effectiveRel = RelSharee)
    and
    ((op.caller.userTeam = op.target.taskTeam
        and op.caller != op.target.owner
        and op.caller.userRole = Member
        and op.caller not in op.target.sharedWith)
        implies op.effectiveRel = RelInTeamNone)
}

// FR-001: unauthenticated requests cannot succeed and yield 401.
fact F_AuthRequiredEverywhere {
  all op: Operation |
    op.authenticated = BFalse
      implies (op.successful = BFalse and op.response = RespUnauthenticated)
}

// FR-003..FR-006: every successful operation is in the permission matrix.
fact F_PermissionEnforced {
  all op: Operation |
    op.successful = BTrue
      implies (op.effectiveRel -> op.kind) in PermMatrix.Allowed
}

// FR-010 / Q1=A: only the owner can change shared_with.
fact F_OwnerOnlyShares {
  all op: Operation |
    (op.kind = PatchSharedWith and op.successful = BTrue)
      implies op.effectiveRel = RelOwner
}

// FR-011 / Q3=B: a sharee attempting DELETE receives the byte-equivalent 404.
fact F_ShareeCannotDelete {
  all op: Operation |
    (op.authenticated = BTrue
     and op.effectiveRel = RelSharee
     and op.kind = DeleteTaskKind)
      implies (op.successful = BFalse and op.response = RespNotFound)
}

// FR-014 / SC-003: callers outside the read-set get byte-equivalent 404.
fact F_ByteEquivalent404 { /* MUTATED — body cleared by validator */ }

// FR-015 / SC-007: every successful mutation produces audit; no audit without mutation.
fact F_AuditPerSuccessfulMutation {
  all op: Operation |
    (op.successful = BTrue
     and op.kind in (PatchFields + PatchSharedWith + DeleteTaskKind))
      implies (some ae: AuditEntry | ae.recordedBy = op)
  all ae: AuditEntry |
    ae.recordedBy.successful = BTrue
    and ae.recordedBy.kind in (PatchFields + PatchSharedWith + DeleteTaskKind)
}

// FR-016: actor/actor_role/task_id snapshotted from the recording Operation.
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.actor = ae.recordedBy.caller
    and ae.actorRole = ae.recordedBy.caller.userRole
    and ae.auditTask = ae.recordedBy.target
}

// FR-016: audit operation matches the Operation kind that produced it.
fact F_AuditOpMatchesKind {
  all ae: AuditEntry |
    (ae.recordedBy.kind = DeleteTaskKind implies ae.auditOp = OpDeleted)
    and (ae.recordedBy.kind = PatchFields implies ae.auditOp = OpEdited)
    and (ae.recordedBy.kind = PatchSharedWith
            implies ae.auditOp in (OpShared + OpUnshared))
}

// Share/unshare carry an affectedSharee; other audit ops do not.
fact F_AuditAffectedShareePresence {
  all ae: AuditEntry |
    (ae.auditOp in (OpShared + OpUnshared)) iff some ae.affectedSharee
}

// FR-017: append-only — no two AuditEntries are stealth-duplicates of the
// same logical event (same operation, same audit op, same affected sharee).
fact F_AppendOnlyUniqueEvents {
  all disj ae1, ae2: AuditEntry |
    not (ae1.recordedBy = ae2.recordedBy
         and ae1.auditOp = ae2.auditOp
         and ae1.affectedSharee = ae2.affectedSharee)
}

// ===========================================================================
// PATTERN PREDICATES + ASSERTIONS
// ===========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003..FR-006
pred LeastPrivilege {
  all op: Operation |
    op.successful = BTrue
      implies (op.effectiveRel -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (relationship, kind) cell has a verdict — present in or absent from Allowed.
  all r: Relationship, k: OperationKind |
    (r -> k) in PermMatrix.Allowed or (r -> k) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: contracts/http-api.md (Owner ⊇ TeamAdmin ⊇ Sharee in shared dimensions)
pred PrivilegeMonotonicity {
  all k: OperationKind |
    (RelTeamAdmin -> k) in PermMatrix.Allowed
      implies (RelOwner -> k) in PermMatrix.Allowed
  all k: OperationKind |
    (RelSharee -> k) in PermMatrix.Allowed
      implies (RelTeamAdmin -> k) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation |
    op.successful = BTrue implies op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007
pred AuditCompleteness {
  all op: Operation |
    (op.successful = BTrue
     and op.kind in (PatchFields + PatchSharedWith + DeleteTaskKind))
      implies (some ae: AuditEntry | ae.recordedBy = op)
  all ae: AuditEntry | ae.recordedBy.successful = BTrue
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.recordedBy = ae2.recordedBy
         and ae1.auditOp = ae2.auditOp
         and ae1.affectedSharee = ae2.affectedSharee)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.actor = ae.recordedBy.caller
    and ae.actorRole = ae.recordedBy.caller.userRole
    and ae.auditTask = ae.recordedBy.target
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner_id NOT NULL FK
pred OwnershipExclusivity {
  all t: Task | one t.owner
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-010 (owner has full access incl. share control)
pred OwnershipBasedAccess {
  // Whenever the caller is the owner, every task-scoped action is permitted.
  all op: Operation |
    (op.effectiveRel = RelOwner
     and op.kind in (GetTaskById + PatchFields + PatchSharedWith
                     + DeleteTaskKind + GetTaskAudit))
      implies (op.effectiveRel -> op.kind) in PermMatrix.Allowed
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-003 (byte-equivalent 404)
pred NoInformationLeakage {
  all op: Operation |
    (op.authenticated = BTrue
     and op.effectiveRel in (RelOutsider + RelInTeamNone))
      implies op.response = RespNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-018 (rollback if audit fails); SC-007
pred ValidationBeforeMutation {
  // Failed operations leave no audit residue.
  all op: Operation |
    op.successful = BFalse implies (no ae: AuditEntry | ae.recordedBy = op)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ===========================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// ===========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (OAuth 401 before any business logic)
pred FR_001_AuthRequired {
  all op: Operation |
    op.authenticated = BFalse
      implies (op.successful = BFalse and op.response = RespUnauthenticated)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (single team_id and role per user, from token)
pred FR_002_UserSingleTeamRole {
  all u: User | one u.userTeam and one u.userRole
}
assert FR_002_UserSingleTeamRole { FR_002_UserSingleTeamRole }
check FR_002_UserSingleTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (in-team non-owner non-admin non-sharee cannot reach the task)
pred FR_004_InTeamNonRelDenied {
  all op: Operation |
    (op.authenticated = BTrue and op.effectiveRel = RelInTeamNone)
      implies op.successful = BFalse
}
assert FR_004_InTeamNonRelDenied { FR_004_InTeamNonRelDenied }
check FR_004_InTeamNonRelDenied for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (team admin can act on any task in their team, except shared_with)
pred FR_005_AdminCanActInTeam {
  all op: Operation |
    (op.effectiveRel = RelTeamAdmin
     and op.kind in (GetTaskById + PatchFields + DeleteTaskKind + GetTaskAudit))
      implies (op.effectiveRel -> op.kind) in PermMatrix.Allowed
}
assert FR_005_AdminCanActInTeam { FR_005_AdminCanActInTeam }
check FR_005_AdminCanActInTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (no cross-team access)
pred FR_006_CrossTeamForbidden {
  all op: Operation |
    op.effectiveRel = RelOutsider implies op.successful = BFalse
}
assert FR_006_CrossTeamForbidden { FR_006_CrossTeamForbidden }
check FR_006_CrossTeamForbidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (each task has one team and one owner; immutable in v1)
pred FR_009_TaskTeamOwnerSingle {
  all t: Task | one t.taskTeam and one t.owner
}
assert FR_009_TaskTeamOwnerSingle { FR_009_TaskTeamOwnerSingle }
check FR_009_TaskTeamOwnerSingle for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1=A (owner-only shared_with change)
pred FR_010_OwnerOnlyShares {
  all op: Operation |
    (op.kind = PatchSharedWith and op.successful = BTrue)
      implies op.effectiveRel = RelOwner
}
assert FR_010_OwnerOnlyShares { FR_010_OwnerOnlyShares }
check FR_010_OwnerOnlyShares for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B (sharee cannot delete → byte-equivalent 404)
pred FR_011_ShareeCannotDelete {
  all op: Operation |
    (op.effectiveRel = RelSharee and op.kind = DeleteTaskKind)
      implies (op.successful = BFalse and op.response = RespNotFound)
}
assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (cross-team sharing forbidden)
pred FR_012_SameTeamSharing {
  all t: Task | all u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_SameTeamSharing { FR_012_SameTeamSharing }
check FR_012_SameTeamSharing for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (every share/unshare event yields an audit entry)
pred FR_013_ShareAuditEntries {
  all op: Operation |
    (op.successful = BTrue and op.kind = PatchSharedWith)
      implies (some ae: AuditEntry
                 | ae.recordedBy = op and ae.auditOp in (OpShared + OpUnshared))
}
assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent 404 for cross-team / in-team-no-rel)
pred FR_014_ByteEquivalent404 {
  all op: Operation |
    (op.authenticated = BTrue
     and op.effectiveRel in (RelOutsider + RelInTeamNone))
      implies op.response = RespNotFound
}
assert FR_014_ByteEquivalent404 { FR_014_ByteEquivalent404 }
check FR_014_ByteEquivalent404 for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (every successful mutation ↔ audit entry)
pred FR_015_AuditPerMutation {
  all op: Operation |
    (op.successful = BTrue
     and op.kind in (PatchFields + PatchSharedWith + DeleteTaskKind))
      implies (some ae: AuditEntry | ae.recordedBy = op)
  all ae: AuditEntry | ae.recordedBy.successful = BTrue
}
assert FR_015_AuditPerMutation { FR_015_AuditPerMutation }
check FR_015_AuditPerMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit fields: task_id, actor_user_id, actor_role snapshot)
pred FR_016_AuditFieldsConsistent {
  all ae: AuditEntry |
    ae.actor = ae.recordedBy.caller
    and ae.actorRole = ae.recordedBy.caller.userRole
    and ae.auditTask = ae.recordedBy.target
}
assert FR_016_AuditFieldsConsistent { FR_016_AuditFieldsConsistent }
check FR_016_AuditFieldsConsistent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entries are append-only / immutable)
pred FR_017_AuditAppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.recordedBy = ae2.recordedBy
         and ae1.auditOp = ae2.auditOp
         and ae1.affectedSharee = ae2.affectedSharee)
}
assert FR_017_AuditAppendOnly { FR_017_AuditAppendOnly }
check FR_017_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (audit visible to owner / sharee / team admin only)
pred FR_019_AuditVisibility {
  all op: Operation |
    (op.kind = GetTaskAudit and op.successful = BTrue)
      implies op.effectiveRel in (RelOwner + RelSharee + RelTeamAdmin)
}
assert FR_019_AuditVisibility { FR_019_AuditVisibility }
check FR_019_AuditVisibility for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeakageViolation { some op: Operation | op.authenticated = BTrue and op.effectiveRel = RelOutsider and op.response != RespNotFound }
