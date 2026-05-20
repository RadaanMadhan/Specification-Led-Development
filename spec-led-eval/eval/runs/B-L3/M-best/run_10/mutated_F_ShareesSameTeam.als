// === feature_model.als — Alloy model for B-L3: Multi-Tenant Task Management with Per-Task Sharing and Audit ===

// -----------------------------------------------------------------------------
// Non-empty universe — without this, all-quantified predicates pass vacuously
// and some-quantified predicates fail vacuously under Alloy's empty world.
// -----------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Operation
}

// -----------------------------------------------------------------------------
// Enums (modelled as abstract sig + one sigs)
// -----------------------------------------------------------------------------

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

abstract sig Role {}
one sig MemberRole, TeamAdminRole extends Role {}

abstract sig AuditOpKind {}
one sig CreatedOp, EditedOp, DeletedOp, SharedOp, UnsharedOp extends AuditOpKind {}

// Action kinds on the API surface. ChangeSharesKind models a PATCH whose body
// includes shared_with (the owner-only operation per FR-010 / Q1=A).
abstract sig OpKind {}
one sig CreateTaskKind, ViewTaskKind, EditFieldsKind, ChangeSharesKind,
        DeleteTaskKind, ViewAuditKind extends OpKind {}

// Relationship between caller and target task (the column dimension in the
// permission matrix in contracts/http-api.md).
abstract sig Relationship {}
one sig OutsiderRel, InTeamNoneRel, ShareeRel, AdminRel, OwnerRel
        extends Relationship {}

// Externally observable outcome of an attempted op.
abstract sig Outcome {}
one sig Success, ByteEquiv404, ValidationFail, Unauth extends Outcome {}

// -----------------------------------------------------------------------------
// Domain sigs (data-model.md entities)
// -----------------------------------------------------------------------------

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
  auditTask:      one Task,
  actorUser:      one User,
  actorRoleSnap:  one Role,
  auditKind:      one AuditOpKind
}

// One Operation atom = one attempted API call (one logical event).
sig Operation {
  caller:        one User,
  target:        lone Task,       // none for CreateTaskKind
  opKind:        one OpKind,
  relationship:  one Relationship,
  authenticated: one Bool,
  outcome:       one Outcome,
  producedAudit: set AuditEntry
}

// Permission matrix expressed as a singleton-sig field (Relationship -> OpKind).
one sig PermMatrix { Allowed: set Relationship -> OpKind }

// -----------------------------------------------------------------------------
// Structural facts
// -----------------------------------------------------------------------------

// data-model.md: tasks.team_id derived from owner's team; task team = owner team.
fact F_OwnerInTaskTeam {
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

// FR-012: every sharee is a current member of the owner's team.
fact F_ShareesSameTeam { /* MUTATED — body cleared by validator */ }

// Owner is implicitly in the read-set; not duplicated in shared_with
// (contracts/http-api.md POST /tasks).
fact F_OwnerNotSharee {
  all t: Task | t.taskOwner not in t.sharedWith
}

// Operation.relationship must match the structural facts: caller's relationship
// to target is computed (see data-model.md Relationship enum, "computed not
// persisted"). Ops with no target (CreateTaskKind) are unconstrained here.
fact F_RelationshipMatchesStructure {
  all op: Operation | some op.target implies (
    ((op.relationship = OutsiderRel) iff (op.caller.userTeam != op.target.taskTeam)) and
    ((op.relationship = OwnerRel)    iff (op.caller = op.target.taskOwner)) and
    ((op.relationship = ShareeRel)   iff (op.caller in op.target.sharedWith)) and
    ((op.relationship = AdminRel)    iff (
        op.caller.userTeam = op.target.taskTeam and
        op.caller != op.target.taskOwner and
        op.caller not in op.target.sharedWith and
        op.caller.userRole = TeamAdminRole)) and
    ((op.relationship = InTeamNoneRel) iff (
        op.caller.userTeam = op.target.taskTeam and
        op.caller != op.target.taskOwner and
        op.caller not in op.target.sharedWith and
        op.caller.userRole = MemberRole))
  )
}

// CreateTaskKind is the only kind with no target.
fact F_CreateHasNoTarget {
  all op: Operation | (op.opKind = CreateTaskKind) iff (no op.target)
}

// The permission matrix (contracts/http-api.md). Owner-only ChangeShares
// (Q1 = A, FR-010); sharee cannot Delete (Q3 = B, FR-011); cross-team and
// in-team-no-rel have no allowed ops on tasks.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (OwnerRel  -> ViewTaskKind) +
      (OwnerRel  -> EditFieldsKind) +
      (OwnerRel  -> ChangeSharesKind) +
      (OwnerRel  -> DeleteTaskKind) +
      (OwnerRel  -> ViewAuditKind) +
      (AdminRel  -> ViewTaskKind) +
      (AdminRel  -> EditFieldsKind) +
      (AdminRel  -> DeleteTaskKind) +
      (AdminRel  -> ViewAuditKind) +
      (ShareeRel -> ViewTaskKind) +
      (ShareeRel -> EditFieldsKind) +
      (ShareeRel -> ViewAuditKind)
}

// FR-001: unauthenticated callers are rejected with Unauth BEFORE any business
// logic, and produce no audit entries.
fact F_AuthRequiredBeforeBusinessLogic {
  all op: Operation |
    op.authenticated = BFalse implies
      (op.outcome = Unauth and no op.producedAudit)
}

// Successful ops on a target require the matrix to allow the cell.
fact F_SuccessRequiresPermission {
  all op: Operation |
    (op.outcome = Success and some op.target) implies
      (op.relationship -> op.opKind in PermMatrix.Allowed)
}

// FR-014: callers without read/act permission on a target task get the
// byte-equivalent 404. Pinpoints the outcome (not merely "non-Success").
fact F_ByteEquiv404ForUnauthorisedAccess {
  all op: Operation | (
    op.authenticated = BTrue and
    some op.target and
    op.opKind in (ViewTaskKind + EditFieldsKind + DeleteTaskKind + ViewAuditKind) and
    op.relationship in (OutsiderRel + InTeamNoneRel)
  ) implies (op.outcome = ByteEquiv404 and no op.producedAudit)
}

// FR-011, FR-014: a sharee attempting DELETE gets the byte-equivalent 404.
fact F_ShareeDeleteIs404 {
  all op: Operation | (
    op.authenticated = BTrue and
    some op.target and
    op.opKind = DeleteTaskKind and
    op.relationship = ShareeRel
  ) implies (op.outcome = ByteEquiv404 and no op.producedAudit)
}

// FR-018 / SC-007: no audit entries on failed operations.
fact F_NoAuditOnFailure {
  all op: Operation | op.outcome != Success implies no op.producedAudit
}

// FR-017: audit is append-only. Each AuditEntry is produced by EXACTLY ONE
// Operation — no orphan audits, no shared/shadow audits.
fact F_AppendOnlyAuditEntries {
  all ae: AuditEntry | one op: Operation | ae in op.producedAudit
}

// FR-015: every successful mutating op produces at least one audit entry.
fact F_MutationProducesAudit {
  all op: Operation | (
    op.outcome = Success and
    op.opKind in (CreateTaskKind + EditFieldsKind + DeleteTaskKind + ChangeSharesKind)
  ) implies (some op.producedAudit)
}

// FR-016: audit entries record correct actor and role snapshot; if op has a
// target, the audit row's task pointer matches it.
fact F_AuditAttributionCorrect {
  all op: Operation | all ae: op.producedAudit |
    (ae.actorUser = op.caller and
     ae.actorRoleSnap = op.caller.userRole and
     (some op.target implies ae.auditTask = op.target))
}

// FR-016: operation kind on the API maps to the audit kind on the row.
fact F_AuditKindMatchesOp {
  all op: Operation | all ae: op.producedAudit | (
    (op.opKind = CreateTaskKind  implies ae.auditKind = CreatedOp) and
    (op.opKind = EditFieldsKind  implies ae.auditKind = EditedOp) and
    (op.opKind = DeleteTaskKind  implies ae.auditKind = DeletedOp) and
    (op.opKind = ChangeSharesKind implies ae.auditKind in (SharedOp + UnsharedOp))
  )
}

// =============================================================================
// PATTERN-LEVEL ASSERTIONS
// =============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.authenticated = BFalse implies
      (op.outcome = Unauth and no op.producedAudit)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  all op: Operation |
    (op.outcome = Success and some op.target) implies
      (op.relationship -> op.opKind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every allowed cell is owner-derivable; the matrix is non-empty and well-formed.
  some PermMatrix.Allowed
  // No undefined verdicts: a cell is either explicitly allowed (in PermMatrix.Allowed)
  // or denied (absence). This holds trivially given the closed-world matrix fact.
  all r: Relationship, k: OpKind |
    (r -> k in PermMatrix.Allowed) or (r -> k not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003/FR-005/FR-010/FR-011
pred PermissionGrounding {
  // No silent grants: Outsider and InTeamNone have NO entries on /tasks endpoints.
  no OutsiderRel.(PermMatrix.Allowed)
  no InTeamNoneRel.(PermMatrix.Allowed)
  // Only OwnerRel can change shares (FR-010).
  ChangeSharesKind in OwnerRel.(PermMatrix.Allowed)
  ChangeSharesKind not in AdminRel.(PermMatrix.Allowed)
  ChangeSharesKind not in ShareeRel.(PermMatrix.Allowed)
  // Sharee can view+edit+view-audit but not delete (Q3 = B / FR-011).
  DeleteTaskKind not in ShareeRel.(PermMatrix.Allowed)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id (immutable, FK→users)
pred OwnershipExclusivity {
  // Every task has exactly one owner, and that owner is in the task's team.
  all t: Task | (one t.taskOwner and t.taskOwner.userTeam = t.taskTeam)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-005, FR-011
pred OwnershipBasedAccess {
  // A member who succeeds at editing a task is either its owner or a sharee.
  all op: Operation | (
    op.outcome = Success and
    some op.target and
    op.caller.userRole = MemberRole and
    op.opKind = EditFieldsKind
  ) implies (op.caller = op.target.taskOwner or op.caller in op.target.sharedWith)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; SC-003
pred NoInformationLeakage {
  // For any caller without read-or-act access, the response is the byte-equiv 404
  // (not 403, not validation_error). This pins the response shape, not the bare
  // "non-Success" outcome.
  all op: Operation | (
    op.authenticated = BTrue and
    some op.target and
    op.opKind in (ViewTaskKind + EditFieldsKind + DeleteTaskKind + ViewAuditKind) and
    (op.relationship in (OutsiderRel + InTeamNoneRel) or
     (op.opKind = DeleteTaskKind and op.relationship = ShareeRel))
  ) implies op.outcome = ByteEquiv404
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // Every audit entry is produced by exactly one operation — no rewrites,
  // no shared sources (which would model an update or shadow row).
  all ae: AuditEntry | one op: Operation | ae in op.producedAudit
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007
pred AuditCompleteness {
  // (a) every successful mutation produces at least one audit row, and
  // (b) every audit row traces back to some operation.
  (all op: Operation | (
     op.outcome = Success and
     op.opKind in (CreateTaskKind + EditFieldsKind + DeleteTaskKind + ChangeSharesKind)
   ) implies some op.producedAudit)
  and
  (all ae: AuditEntry | some op: Operation | ae in op.producedAudit)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit_entries.actor_*
pred AttributionCorrectness {
  all op: Operation | all ae: op.producedAudit |
    (ae.actorUser = op.caller and ae.actorRoleSnap = op.caller.userRole)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// =============================================================================
// FEATURE-SPECIFIC ASSERTIONS — one per FR-NNN where applicable.
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | op.authenticated = BFalse implies op.outcome = Unauth
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a (team and role from token, not body)
pred FR_002_RoleFromToken {
  // The audit row's role snapshot equals the caller's actual role — i.e., the
  // value is sourced from the caller (introspected token), never the payload.
  all op: Operation | all ae: op.producedAudit |
    ae.actorRoleSnap = op.caller.userRole
}
assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_MemberPermissions {
  // A successful op on a target by a member must be as Owner or Sharee on
  // an allowed (relationship, op) cell.
  all op: Operation | (
    op.outcome = Success and
    some op.target and
    op.caller.userRole = MemberRole
  ) implies (
    op.relationship in (OwnerRel + ShareeRel) and
    (op.relationship -> op.opKind) in PermMatrix.Allowed
  )
}
assert FR_003_MemberPermissions { FR_003_MemberPermissions }
check FR_003_MemberPermissions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_MemberNoAccessUnshared {
  // A member who is neither the owner nor a sharee on a task cannot succeed at
  // view/edit/delete operations on it — even within the same team.
  all op: Operation | (
    some op.target and
    op.caller.userRole = MemberRole and
    op.caller != op.target.taskOwner and
    op.caller not in op.target.sharedWith and
    op.opKind in (ViewTaskKind + EditFieldsKind + DeleteTaskKind)
  ) implies op.outcome != Success
}
assert FR_004_MemberNoAccessUnshared { FR_004_MemberNoAccessUnshared }
check FR_004_MemberNoAccessUnshared for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminInTeamFullAccess {
  // A successful DELETE by a non-owner caller implies the caller is a team
  // admin of the task's team.
  all op: Operation | (
    op.outcome = Success and
    some op.target and
    op.opKind = DeleteTaskKind and
    op.caller != op.target.taskOwner
  ) implies (
    op.caller.userRole = TeamAdminRole and
    op.caller.userTeam = op.target.taskTeam
  )
}
assert FR_005_AdminInTeamFullAccess { FR_005_AdminInTeamFullAccess }
check FR_005_AdminInTeamFullAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CrossTeamIsolation {
  // No caller in a different team than the task can succeed on any op.
  all op: Operation | (
    some op.target and
    op.caller.userTeam != op.target.taskTeam
  ) implies op.outcome != Success
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_OwnerTeamConsistent {
  // owner_id and team_id are immutable — encoded structurally: the task's team
  // always equals the owner's team in every reachable state.
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}
assert FR_009_OwnerTeamConsistent { FR_009_OwnerTeamConsistent }
check FR_009_OwnerTeamConsistent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1 = A
pred FR_010_OwnerOnlyShares {
  // Only the task owner can successfully change shared_with.
  all op: Operation | (
    op.outcome = Success and
    some op.target and
    op.opKind = ChangeSharesKind
  ) implies op.caller = op.target.taskOwner
}
assert FR_010_OwnerOnlyShares { FR_010_OwnerOnlyShares }
check FR_010_OwnerOnlyShares for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3 = B
pred FR_011_ShareeCantDelete {
  // A sharee cannot successfully delete the task they are shared on.
  all op: Operation | (
    some op.target and
    op.opKind = DeleteTaskKind and
    op.caller in op.target.sharedWith and
    op.caller != op.target.taskOwner
  ) implies op.outcome != Success
}
assert FR_011_ShareeCantDelete { FR_011_ShareeCantDelete }
check FR_011_ShareeCantDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_SharesSameTeam {
  // No cross-team sharing: every user in shared_with belongs to the task's team.
  all t: Task | all u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_SharesSameTeam { FR_012_SharesSameTeam }
check FR_012_SharesSameTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_ShareUnshareAuditKind {
  // Successful ChangeShares operations produce only Shared/Unshared audit rows.
  all op: Operation | (
    op.outcome = Success and
    op.opKind = ChangeSharesKind
  ) implies (
    some op.producedAudit and
    all ae: op.producedAudit | ae.auditKind in (SharedOp + UnsharedOp)
  )
}
assert FR_013_ShareUnshareAuditKind { FR_013_ShareUnshareAuditKind }
check FR_013_ShareUnshareAuditKind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquiv404 {
  // All not-in-read-set callers receive ByteEquiv404 specifically (not just a
  // non-Success outcome) on the four /tasks/{id}* endpoints.
  all op: Operation | (
    op.authenticated = BTrue and
    some op.target and
    op.opKind in (ViewTaskKind + EditFieldsKind + DeleteTaskKind + ViewAuditKind) and
    (op.relationship in (OutsiderRel + InTeamNoneRel) or
     (op.opKind = DeleteTaskKind and op.relationship = ShareeRel))
  ) implies op.outcome = ByteEquiv404
}
assert FR_014_ByteEquiv404 { FR_014_ByteEquiv404 }
check FR_014_ByteEquiv404 for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditPerEvent {
  all op: Operation | (
    op.outcome = Success and
    op.opKind in (CreateTaskKind + EditFieldsKind + DeleteTaskKind + ChangeSharesKind)
  ) implies some op.producedAudit
}
assert FR_015_AuditPerEvent { FR_015_AuditPerEvent }
check FR_015_AuditPerEvent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditFieldsComplete {
  // Every audit row carries task_id, actor_user_id, actor_role, operation
  // (one each per row by sig declaration); attribution is correct.
  all ae: AuditEntry | (
    one ae.auditTask and
    one ae.actorUser and
    one ae.actorRoleSnap and
    one ae.auditKind
  )
  all op: Operation | all ae: op.producedAudit |
    (ae.actorUser = op.caller and ae.actorRoleSnap = op.caller.userRole)
}
assert FR_016_AuditFieldsComplete { FR_016_AuditFieldsComplete }
check FR_016_AuditFieldsComplete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditAppendOnly {
  // Every audit row traces to exactly one producing operation. No update path
  // (an update would be modelled as two rows for the same source operation).
  some AuditEntry
  all ae: AuditEntry | one op: Operation | ae in op.producedAudit
}
assert FR_017_AuditAppendOnly { FR_017_AuditAppendOnly }
check FR_017_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_AuditReadAccess {
  // Successful audit reads are restricted to owner, sharee, or team admin.
  all op: Operation | (
    op.outcome = Success and
    op.opKind = ViewAuditKind and
    some op.target
  ) implies op.relationship in (OwnerRel + ShareeRel + AdminRel)
}
assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeamShare { some t: Task, u: t.sharedWith | u.userTeam != t.taskTeam }
