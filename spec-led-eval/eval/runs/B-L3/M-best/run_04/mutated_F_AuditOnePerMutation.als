// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-tenant task management with per-task sharing and per-mutation
// audit log. Models the relationship-based access matrix, the byte-equivalent
// 404 isolation rule, owner-only share control, sharee permissions
// (view + edit, not delete, not re-share), and the append-only audit
// trail with attribution.

// ----- Roles ----------------------------------------------------------------
abstract sig Role {}
one sig MemberRole, TeamAdminRole extends Role {}

// ----- Caller-to-Task relationship (computed per request) -------------------
abstract sig Relationship {}
one sig OwnerRel, AdminRel, ShareeRel, InTeamNoneRel, OutsiderRel extends Relationship {}

// ----- HTTP operation kinds -------------------------------------------------
abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchFields, PatchShares, DeleteTask, GetAudit extends OperationKind {}

// ----- Audit-event tags -----------------------------------------------------
abstract sig AuditOpKind {}
one sig CreatedOp, EditedOp, DeletedOp, SharedOp, UnsharedOp extends AuditOpKind {}

// ----- Operation outcome ----------------------------------------------------
abstract sig Outcome {}
one sig SuccessOutcome, FailureOutcome extends Outcome {}

// ----- Authentication state -------------------------------------------------
abstract sig AuthState {}
one sig Authenticated, Unauthenticated extends AuthState {}

// ----- Domain entities ------------------------------------------------------
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

sig Operation {
  opKind: one OperationKind,
  caller: one User,
  callerRoleSnapshot: one Role,
  callerTeamSnapshot: one Team,
  targetTask: lone Task,
  outcome: one Outcome,
  auth: one AuthState
}

sig AuditEntry {
  forOperation: one Operation,
  recordedTask: one Task,
  recordedActor: one User,
  recordedRole: one Role,
  recordedAuditOp: one AuditOpKind
}

// ----- Permission matrix: Relationship x OperationKind -> Allowed -----------
one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ============================================================
// Universe / structural facts
// ============================================================

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some Operation
  some AuditEntry
}

// Permission matrix taken straight from contracts/http-api.md.
// Closed-world: this is the complete set of allowed cells.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (OwnerRel  -> GetTask)     + (AdminRel -> GetTask)     + (ShareeRel -> GetTask)
    + (OwnerRel  -> PatchFields) + (AdminRel -> PatchFields) + (ShareeRel -> PatchFields)
    + (OwnerRel  -> PatchShares)
    + (OwnerRel  -> DeleteTask)  + (AdminRel -> DeleteTask)
    + (OwnerRel  -> GetAudit)    + (AdminRel -> GetAudit)    + (ShareeRel -> GetAudit)
    + (OwnerRel  -> PostTasks)
}

fact F_OwnerInTaskTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}

fact F_OwnerNotInSharedWith {
  all t: Task | t.owner not in t.sharedWith
}

// FR-012: every sharee must be in the task's team.
fact F_SharedWithSameTeam {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}

// FR-002 / FR-002a: caller's effective role and team come from the token,
// which the model identifies with the user's record.
fact F_CallerSnapshotFromToken {
  all op: Operation |
    op.callerRoleSnapshot = op.caller.userRole and
    op.callerTeamSnapshot = op.caller.userTeam
}

// FR-001: unauthenticated requests never succeed.
fact F_UnauthenticatedRejected {
  all op: Operation | op.outcome = SuccessOutcome implies op.auth = Authenticated
}

// Computed relationship between caller and a task.
fun relOf[u: User, t: Task]: one Relationship {
  { r: Relationship |
      (u = t.owner and r = OwnerRel)
   or (u != t.owner and u.userTeam = t.taskTeam and u.userRole = TeamAdminRole and r = AdminRel)
   or (u != t.owner and u.userTeam = t.taskTeam and u.userRole != TeamAdminRole and u in t.sharedWith and r = ShareeRel)
   or (u != t.owner and u.userTeam = t.taskTeam and u.userRole != TeamAdminRole and u not in t.sharedWith and r = InTeamNoneRel)
   or (u.userTeam != t.taskTeam and r = OutsiderRel)
  }
}

// FR-003, FR-005, FR-010, FR-011, FR-014: a successful targeted operation
// must be authorised by the relationship-based permission matrix.
fact F_AccessControl {
  all op: Operation |
    (op.outcome = SuccessOutcome and some op.targetTask) implies
      (relOf[op.caller, op.targetTask] -> op.opKind) in PermMatrix.Allowed
}

// A successful POST /tasks makes the caller the owner of the new task.
fact F_PostTaskOwnership {
  all op: Operation |
    (op.opKind = PostTasks and op.outcome = SuccessOutcome) implies
      (some op.targetTask and op.caller = op.targetTask.owner)
}

// FR-015: every successful mutating op produces exactly one audit entry.
fact F_AuditOnePerMutation { /* MUTATED — body cleared by validator */ }

// No audit entry for read operations, no audit entry for failed operations.
fact F_NoAuditForNonMutations {
  all ae: AuditEntry |
    ae.forOperation.outcome = SuccessOutcome and
    ae.forOperation.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask)
}

// FR-017: append-only — no two audit entries describe the same logical event.
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.forOperation != ae2.forOperation
}

// FR-016: audit-entry fields faithfully attribute to the operation.
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.recordedActor = ae.forOperation.caller and
    ae.recordedRole  = ae.forOperation.callerRoleSnapshot and
    ae.recordedTask  = ae.forOperation.targetTask
}

// FR-016: audit-op tag matches the kind of operation it records.
fact F_AuditOpKindMatches {
  all ae: AuditEntry | {
    ae.forOperation.opKind = PostTasks    implies ae.recordedAuditOp = CreatedOp
    ae.forOperation.opKind = PatchFields  implies ae.recordedAuditOp = EditedOp
    ae.forOperation.opKind = DeleteTask   implies ae.recordedAuditOp = DeletedOp
    ae.forOperation.opKind = PatchShares  implies ae.recordedAuditOp in (SharedOp + UnsharedOp)
  }
}

// ============================================================
// Pattern-based assertions
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003,005,010,011,014
pred LeastPrivilege {
  all op: Operation |
    (op.outcome = SuccessOutcome and some op.targetTask) implies
      (relOf[op.caller, op.targetTask] -> op.opKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every cell that any operation reaches has an in/out verdict via the matrix.
  // Concretely: no successful targeted op exists for which the (rel,kind)
  // verdict is "undefined" — every reachable cell is explicitly in or out.
  all op: Operation |
    (op.outcome = SuccessOutcome and some op.targetTask) implies
      ((relOf[op.caller, op.targetTask] -> op.opKind) in PermMatrix.Allowed
       or (relOf[op.caller, op.targetTask] -> op.opKind) not in PermMatrix.Allowed)
  // And the matrix is non-empty (sanity).
  some PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md per-event decomposition
pred AuditCompleteness {
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask)) implies
      (one ae: AuditEntry | ae.forOperation = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.forOperation != ae2.forOperation
  all ae: AuditEntry | ae.forOperation.outcome = SuccessOutcome
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016 audit fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.recordedActor = ae.forOperation.caller and
    ae.recordedRole  = ae.forOperation.callerRoleSnapshot and
    ae.recordedTask  = ae.forOperation.targetTask
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md owner_id, team_id immutable; FR-009
pred OwnershipExclusivity {
  all t: Task | one t.owner and one t.taskTeam
  all t: Task | t.owner.userTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-005, FR-011
pred OwnershipBasedAccess {
  // A successful targeted op is justified by a documented relationship
  // (Owner, Admin, or Sharee). Outsider / InTeamNone never succeed.
  all op: Operation |
    (op.outcome = SuccessOutcome and some op.targetTask) implies
      relOf[op.caller, op.targetTask] in (OwnerRel + AdminRel + ShareeRel)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; SC-003 byte-equivalent 404
pred NoInformationLeakage {
  no op: Operation |
    op.outcome = SuccessOutcome and some op.targetTask and
    relOf[op.caller, op.targetTask] in (OutsiderRel + InTeamNoneRel)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = SuccessOutcome implies op.auth = Authenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001, FR-018
pred ValidationBeforeMutation {
  // A failed operation produces no audit entry / no observable state change.
  no ae: AuditEntry | ae.forOperation.outcome != SuccessOutcome
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ============================================================
// FR-specific assertions (one per FR-NNN with structural content)
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer required
pred FR_001_AuthRequired {
  all op: Operation | op.outcome = SuccessOutcome implies op.auth = Authenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a team_id and role from token only
pred FR_002_RoleFromToken {
  all op: Operation |
    op.callerRoleSnapshot = op.caller.userRole and
    op.callerTeamSnapshot = op.caller.userTeam
}
assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 member permissions
pred FR_003_MemberPermissions {
  all op: Operation |
    (op.outcome = SuccessOutcome and some op.targetTask and op.caller.userRole = MemberRole) implies
      (op.caller = op.targetTask.owner or op.caller in op.targetTask.sharedWith)
}
assert FR_003_MemberPermissions { FR_003_MemberPermissions }
check FR_003_MemberPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 member cannot access non-owned non-shared
pred FR_004_MemberCannotAccessUnowned {
  no op: Operation |
    op.outcome = SuccessOutcome and some op.targetTask and
    op.caller.userRole = MemberRole and
    op.caller != op.targetTask.owner and
    op.caller not in op.targetTask.sharedWith
}
assert FR_004_MemberCannotAccessUnowned { FR_004_MemberCannotAccessUnowned }
check FR_004_MemberCannotAccessUnowned for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 admin team-wide access; admin cannot change shared_with
pred FR_005_AdminTeamAccess {
  // An admin succeeding on PatchShares must be the owner (Q1=A).
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind = PatchShares and some op.targetTask
     and op.caller.userRole = TeamAdminRole) implies
       op.caller = op.targetTask.owner
}
assert FR_005_AdminTeamAccess { FR_005_AdminTeamAccess }
check FR_005_AdminTeamAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 cross-team isolation under role
pred FR_006_NoCrossTeamAccess {
  all op: Operation |
    (op.outcome = SuccessOutcome and some op.targetTask) implies
      op.caller.userTeam = op.targetTask.taskTeam
}
assert FR_006_NoCrossTeamAccess { FR_006_NoCrossTeamAccess }
check FR_006_NoCrossTeamAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 owner_id / team_id immutable, exactly one owner per task
pred FR_009_OwnerTeamImmutable {
  all t: Task | one t.owner and one t.taskTeam and t.owner.userTeam = t.taskTeam
}
assert FR_009_OwnerTeamImmutable { FR_009_OwnerTeamImmutable }
check FR_009_OwnerTeamImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 only the task owner may change shared_with
pred FR_010_OwnerOnlySharesChange {
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind = PatchShares and some op.targetTask) implies
      op.caller = op.targetTask.owner
}
assert FR_010_OwnerOnlySharesChange { FR_010_OwnerOnlySharesChange }
check FR_010_OwnerOnlySharesChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 sharee may view+edit, never delete
pred FR_011_ShareeCannotDelete {
  no op: Operation |
    op.outcome = SuccessOutcome and op.opKind = DeleteTask and some op.targetTask and
    op.caller in op.targetTask.sharedWith and
    op.caller != op.targetTask.owner and
    op.caller.userRole != TeamAdminRole
}
assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 cross-team sharing forbidden
pred FR_012_NoCrossTeamSharing {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_NoCrossTeamSharing { FR_012_NoCrossTeamSharing }
check FR_012_NoCrossTeamSharing for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 share/unshare audit entries
pred FR_013_ShareAuditEntries {
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind = PatchShares) implies
      (one ae: AuditEntry | ae.forOperation = op and ae.recordedAuditOp in (SharedOp + UnsharedOp))
}
assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404
pred FR_014_ByteEquivalent404 {
  no op: Operation |
    op.outcome = SuccessOutcome and some op.targetTask and
    relOf[op.caller, op.targetTask] in (OutsiderRel + InTeamNoneRel)
}
assert FR_014_ByteEquivalent404 { FR_014_ByteEquivalent404 }
check FR_014_ByteEquivalent404 for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 per-event audit
pred FR_015_PerEventAudit {
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask)) implies
      (one ae: AuditEntry | ae.forOperation = op)
}
assert FR_015_PerEventAudit { FR_015_PerEventAudit }
check FR_015_PerEventAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit-entry fields are faithful to the operation
pred FR_016_AuditFields {
  all ae: AuditEntry | {
    ae.recordedActor = ae.forOperation.caller
    ae.recordedRole  = ae.forOperation.callerRoleSnapshot
    ae.recordedTask  = ae.forOperation.targetTask
    ae.forOperation.opKind = PostTasks    implies ae.recordedAuditOp = CreatedOp
    ae.forOperation.opKind = PatchFields  implies ae.recordedAuditOp = EditedOp
    ae.forOperation.opKind = DeleteTask   implies ae.recordedAuditOp = DeletedOp
    ae.forOperation.opKind = PatchShares  implies ae.recordedAuditOp in (SharedOp + UnsharedOp)
  }
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit immutable / append-only
pred FR_017_AuditAppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.forOperation != ae2.forOperation
  all ae: AuditEntry | ae.forOperation.outcome = SuccessOutcome
}
assert FR_017_AuditAppendOnly { FR_017_AuditAppendOnly }
check FR_017_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 no observable state change without audit entry
pred FR_018_NoOrphanStateChange {
  // For every successful mutating operation there exists exactly one audit entry.
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PostTasks + PatchFields + PatchShares + DeleteTask)) implies
      (one ae: AuditEntry | ae.forOperation = op)
}
assert FR_018_NoOrphanStateChange { FR_018_NoOrphanStateChange }
check FR_018_NoOrphanStateChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit readable by owner / sharee / admin only
pred FR_019_AuditAccess {
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind = GetAudit and some op.targetTask) implies
      relOf[op.caller, op.targetTask] in (OwnerRel + AdminRel + ShareeRel)
}
assert FR_019_AuditAccess { FR_019_AuditAccess }
check FR_019_AuditAccess for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OrphanMutation { some op: Operation | op.outcome = SuccessOutcome and op.opKind = PatchFields and (no ae: AuditEntry | ae.forOperation = op) }
