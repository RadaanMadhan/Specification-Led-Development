// === feature_model.als — Alloy model for B-L3 (Multi-Tenant Task Management with Per-Task Sharing and Audit) ===

// ---------------------------------------------------------------------------
// Non-empty universe so quantifiers don't fire on the empty world.
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some Operation
}

// ---------------------------------------------------------------------------
// Enums and discrete domains
// ---------------------------------------------------------------------------

abstract sig Role {}
one sig MemberRole, TeamAdminRole extends Role {}

abstract sig AuditOp {}
one sig CreatedOp, EditedOp, DeletedOp, SharedOp, UnsharedOp extends AuditOp {}

abstract sig OperationKind {}
one sig PostTasks, GetTaskOp, PatchFieldsOp, PatchSharedOp,
        DeleteTaskOp, GetAuditOp extends OperationKind {}

abstract sig Outcome {}
one sig Success, Unauthenticated, NotFound, ValidationError,
        AuditUnavailable extends Outcome {}

// ---------------------------------------------------------------------------
// Domain entities (data-model.md)
// ---------------------------------------------------------------------------

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
  auditTask: one Task,
  actor: one User,
  actorRoleSnap: one Role,
  auditOp: one AuditOp
}

sig Operation {
  caller: lone User,        // none ⇒ unauthenticated request
  target: lone Task,        // none ⇒ POST /tasks before creation, or failed validation
  kind: one OperationKind,
  outcome: one Outcome,
  audits: set AuditEntry    // audit rows produced by this op
}

// ---------------------------------------------------------------------------
// Helper predicates — relationship of a caller to a task
// ---------------------------------------------------------------------------

pred hasReadAccess[u: User, t: Task] {
  u = t.owner or u in t.sharedWith or
    (u.role = TeamAdminRole and u.team = t.taskTeam)
}

pred hasDeleteAccess[u: User, t: Task] {
  u = t.owner or (u.role = TeamAdminRole and u.team = t.taskTeam)
}

pred hasShareControl[u: User, t: Task] {
  u = t.owner
}

// ---------------------------------------------------------------------------
// Structural / domain facts
// ---------------------------------------------------------------------------

// data-model.md: a task's owner is a member of the task's team.
fact F_OwnerInTaskTeam {
  all t: Task | t.owner.team = t.taskTeam
}

// FR-012: sharees must belong to the same team as the task owner.
fact F_SharedWithSameTeam {
  all t: Task | all u: t.sharedWith | u.team = t.taskTeam
}

// http-api.md POST contract: owner is implicit in read-set, not in shared_with.
fact F_OwnerNotInSharedWith {
  all t: Task | t.owner not in t.sharedWith
}

// Successful task-targeted operations must have a concrete target.
fact F_TargetForActOnTask {
  all op: Operation |
    (op.outcome = Success and op.kind != PostTasks) implies some op.target
  all op: Operation |
    (op.outcome = Success and op.kind = PostTasks) implies some op.target
}

// Audit entries produced by an op reference that op's target task.
fact F_AuditTargetMatch {
  all op: Operation | all ae: op.audits | ae.auditTask = op.target
}

// Each audit entry is produced by exactly one operation.
fact F_AuditOwnedByOneOp {
  all ae: AuditEntry | (one op: Operation | ae in op.audits)
}

// FR-001 / SC-005: unauthenticated request iff no caller; never succeeds.
fact F_AuthRequired {
  all op: Operation | (op.outcome = Unauthenticated) iff (no op.caller)
}

// FR-018 / SC-007: no audit entry is produced unless the operation succeeded.
fact F_NoAuditsWithoutSuccess {
  all op: Operation | op.outcome != Success implies no op.audits
}

// FR-015: pure reads produce no audits; successful mutations produce ≥1 audit.
fact F_AuditsOnlyForMutations {
  all op: Operation |
    (op.outcome = Success and op.kind in (GetTaskOp + GetAuditOp))
      implies no op.audits
  all op: Operation |
    (op.outcome = Success and
     op.kind in (PostTasks + PatchFieldsOp + PatchSharedOp + DeleteTaskOp))
      implies some op.audits
}

// FR-014 / FR-006: GET / GET-audit success requires read access; no-read → 404.
fact F_ReadAccessForReadOps {
  all op: Operation |
    (some op.caller and op.kind in (GetTaskOp + GetAuditOp) and op.outcome = Success)
      implies hasReadAccess[op.caller, op.target]
  all op: Operation |
    (some op.caller and op.kind in (GetTaskOp + GetAuditOp) and
     some op.target and not hasReadAccess[op.caller, op.target])
      implies op.outcome = NotFound
}

// FR-003 / FR-005: PATCH-fields requires read access.
fact F_PatchFieldsAccess {
  all op: Operation |
    (op.kind = PatchFieldsOp and op.outcome = Success)
      implies hasReadAccess[op.caller, op.target]
  all op: Operation |
    (some op.caller and op.kind = PatchFieldsOp and some op.target and
     not hasReadAccess[op.caller, op.target])
      implies op.outcome = NotFound
}

// FR-011 / FR-005: DELETE only by owner or admin-of-team; sharee/outsider → 404.
fact F_DeleteAccess { /* MUTATED — body cleared by validator */ }

// FR-010 / SC-011: only the owner may change shared_with.
fact F_PatchSharedOwnerOnly {
  all op: Operation |
    (op.kind = PatchSharedOp and op.outcome = Success)
      implies hasShareControl[op.caller, op.target]
  all op: Operation |
    (some op.caller and op.kind = PatchSharedOp and some op.target and
     hasReadAccess[op.caller, op.target] and
     not hasShareControl[op.caller, op.target])
      implies op.outcome = ValidationError
  all op: Operation |
    (some op.caller and op.kind = PatchSharedOp and some op.target and
     not hasReadAccess[op.caller, op.target])
      implies op.outcome = NotFound
}

// FR-016: audit attribution snapshot.
fact F_AuditAttribution {
  all op: Operation | all ae: op.audits |
    ae.actor = op.caller and ae.actorRoleSnap = op.caller.role
}

// FR-013: a successful share-list mutation emits a shared/unshared audit.
fact F_ShareAuditEntries {
  all op: Operation |
    (op.kind = PatchSharedOp and op.outcome = Success)
      implies (some ae: op.audits | ae.auditOp in (SharedOp + UnsharedOp))
}

// ---------------------------------------------------------------------------
// PATTERN assertions (catalogue)
// ---------------------------------------------------------------------------

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  no op: Operation | no op.caller and op.outcome = Success
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003..FR-006, FR-010, FR-011
pred LeastPrivilege {
  no op: Operation |
    op.outcome = Success and op.kind = GetTaskOp and
    some op.caller and some op.target and not hasReadAccess[op.caller, op.target]
  no op: Operation |
    op.outcome = Success and op.kind = DeleteTaskOp and
    some op.caller and some op.target and not hasDeleteAccess[op.caller, op.target]
  no op: Operation |
    op.outcome = Success and op.kind = PatchSharedOp and
    some op.caller and some op.target and not hasShareControl[op.caller, op.target]
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all op: Operation | one op.outcome
  all op: Operation | one op.kind
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  no op: Operation |
    some op.caller and some op.target and
    op.kind in (GetTaskOp + GetAuditOp + PatchFieldsOp) and
    op.outcome = Success and
    not hasReadAccess[op.caller, op.target]
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all ae: AuditEntry |
    (one op: Operation |
       ae in op.audits and op.outcome = Success and
       op.kind in (PostTasks + PatchFieldsOp + PatchSharedOp + DeleteTaskOp))
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md PATCH→audit decomposition
pred AuditCompleteness {
  all op: Operation |
    (op.outcome = Success and
     op.kind in (PostTasks + PatchFieldsOp + PatchSharedOp + DeleteTaskOp))
      implies some op.audits
  all ae: AuditEntry | (one op: Operation | ae in op.audits)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  all op: Operation | all ae: op.audits |
    ae.actor = op.caller and
    ae.actorRoleSnap = op.caller.role and
    ae.auditTask = op.target
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; FR-009
pred OwnershipExclusivity {
  all t: Task | one t.owner
  all t: Task | t.owner.team = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-010 / SC-011
pred OwnershipBasedAccess {
  no op: Operation |
    op.kind = PatchSharedOp and op.outcome = Success and
    some op.caller and some op.target and op.caller != op.target.owner
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-018 (rollback on audit_unavailable)
pred ValidationBeforeMutation {
  no op: Operation | op.outcome != Success and some op.audits
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ---------------------------------------------------------------------------
// FR-specific assertions
// ---------------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer required before any handler runs
pred FR_001_AuthRequired {
  all op: Operation |
    no op.caller implies (op.outcome = Unauthenticated and no op.audits)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a one team, one role per user
pred FR_002_OneTeamOneRole {
  all u: User | one u.team and one u.role
}
assert FR_002_OneTeamOneRole { FR_002_OneTeamOneRole }
check FR_002_OneTeamOneRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 a member edits only tasks they own or are a sharee on
pred FR_003_MemberEditAccess {
  all op: Operation |
    (op.kind = PatchFieldsOp and op.outcome = Success and
     some op.caller and op.caller.role = MemberRole and some op.target)
      implies (op.caller = op.target.owner or op.caller in op.target.sharedWith)
}
assert FR_003_MemberEditAccess { FR_003_MemberEditAccess }
check FR_003_MemberEditAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 member cannot view non-owned non-shared task
pred FR_004_MemberNoForeignTask {
  all op: Operation |
    (op.kind = GetTaskOp and op.outcome = Success and
     some op.caller and op.caller.role = MemberRole and some op.target)
      implies (op.caller = op.target.owner or op.caller in op.target.sharedWith)
}
assert FR_004_MemberNoForeignTask { FR_004_MemberNoForeignTask }
check FR_004_MemberNoForeignTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 team_admin acts only within their team
pred FR_005_AdminTeamScoped {
  all op: Operation |
    (op.outcome = Success and some op.caller and op.caller.role = TeamAdminRole and
     op.kind in (GetTaskOp + PatchFieldsOp + DeleteTaskOp + GetAuditOp) and some op.target)
      implies op.caller.team = op.target.taskTeam
}
assert FR_005_AdminTeamScoped { FR_005_AdminTeamScoped }
check FR_005_AdminTeamScoped for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 cross-team isolation invariant under role
pred FR_006_CrossTeamIsolation {
  all op: Operation |
    (op.outcome = Success and some op.target and some op.caller and op.kind != PostTasks)
      implies op.caller.team = op.target.taskTeam
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 every task carries owner + team
pred FR_007_TaskShape {
  all t: Task | one t.owner and one t.taskTeam
}
assert FR_007_TaskShape { FR_007_TaskShape }
check FR_007_TaskShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 audit op type is one of the five values
pred FR_008_AuditOpEnum {
  all ae: AuditEntry |
    ae.auditOp in (CreatedOp + EditedOp + DeletedOp + SharedOp + UnsharedOp)
}
assert FR_008_AuditOpEnum { FR_008_AuditOpEnum }
check FR_008_AuditOpEnum for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 exactly one owner per task, owner in task's team
pred FR_009_OneOwnerPerTask {
  all t: Task | one t.owner
  all t: Task | t.owner.team = t.taskTeam
}
assert FR_009_OneOwnerPerTask { FR_009_OneOwnerPerTask }
check FR_009_OneOwnerPerTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 owner-only change to shared_with (Q1=A, SC-011)
pred FR_010_OwnerOnlyShareControl {
  all op: Operation |
    (op.kind = PatchSharedOp and op.outcome = Success and some op.target and some op.caller)
      implies op.caller = op.target.owner
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 sharee cannot delete (Q3=B)
pred FR_011_ShareeNoDelete {
  no op: Operation |
    op.kind = DeleteTaskOp and op.outcome = Success and
    some op.target and some op.caller and
    op.caller in op.target.sharedWith and
    op.caller != op.target.owner and
    not (op.caller.role = TeamAdminRole and op.caller.team = op.target.taskTeam)
}
assert FR_011_ShareeNoDelete { FR_011_ShareeNoDelete }
check FR_011_ShareeNoDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 cross-team sharing forbidden
pred FR_012_SameTeamSharing {
  all t: Task | all u: t.sharedWith | u.team = t.taskTeam
}
assert FR_012_SameTeamSharing { FR_012_SameTeamSharing }
check FR_012_SameTeamSharing for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 share/unshare audit entries
pred FR_013_ShareAuditEntries {
  all op: Operation |
    (op.kind = PatchSharedOp and op.outcome = Success)
      implies (some ae: op.audits | ae.auditOp in (SharedOp + UnsharedOp))
}
assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404 for callers outside the read-set
pred FR_014_ByteEquivalent404 {
  all op: Operation |
    (some op.caller and some op.target and
     op.kind in (GetTaskOp + PatchFieldsOp + GetAuditOp) and
     not hasReadAccess[op.caller, op.target])
      implies op.outcome = NotFound
  all op: Operation |
    (some op.caller and some op.target and op.kind = DeleteTaskOp and
     not hasDeleteAccess[op.caller, op.target])
      implies op.outcome = NotFound
}
assert FR_014_ByteEquivalent404 { FR_014_ByteEquivalent404 }
check FR_014_ByteEquivalent404 for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 one audit per logical event; no success without audit
pred FR_015_AuditPerEvent {
  all op: Operation |
    (op.outcome = Success and
     op.kind in (PostTasks + PatchFieldsOp + PatchSharedOp + DeleteTaskOp))
      implies some op.audits
  all ae: AuditEntry | (one op: Operation | ae in op.audits)
}
assert FR_015_AuditPerEvent { FR_015_AuditPerEvent }
check FR_015_AuditPerEvent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit record contents and snapshot semantics
pred FR_016_AuditAttribution {
  all op: Operation | all ae: op.audits |
    ae.actor = op.caller and
    ae.actorRoleSnap = op.caller.role and
    ae.auditTask = op.target
}
assert FR_016_AuditAttribution { FR_016_AuditAttribution }
check FR_016_AuditAttribution for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries immutable / append-only
pred FR_017_AuditAppendOnly {
  all ae: AuditEntry |
    (one op: Operation |
       ae in op.audits and op.outcome = Success and
       op.kind in (PostTasks + PatchFieldsOp + PatchSharedOp + DeleteTaskOp))
}
assert FR_017_AuditAppendOnly { FR_017_AuditAppendOnly }
check FR_017_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit_unavailable rolls back: no audit without success
pred FR_018_RollbackNoAudit {
  no op: Operation | op.outcome != Success and some op.audits
}
assert FR_018_RollbackNoAudit { FR_018_RollbackNoAudit }
check FR_018_RollbackNoAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit endpoint readable only to read-set
pred FR_019_AuditReadAccess {
  all op: Operation |
    (op.kind = GetAuditOp and op.outcome = Success and some op.caller and some op.target)
      implies hasReadAccess[op.caller, op.target]
}
assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 audit entries reference a task (retention proxy)
pred FR_020_AuditEntryReferencesTask {
  all ae: AuditEntry | one ae.auditTask
}
assert FR_020_AuditEntryReferencesTask { FR_020_AuditEntryReferencesTask }
check FR_020_AuditEntryReferencesTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021 performance (structural proxy: well-typed kind/outcome)
pred FR_021_OneKindOneOutcome {
  all op: Operation | one op.kind and one op.outcome
}
assert FR_021_OneKindOneOutcome { FR_021_OneKindOneOutcome }
check FR_021_OneKindOneOutcome for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ShareeCanDelete { some op: Operation | op.kind = DeleteTaskOp and op.outcome = Success and some op.target and some op.caller and op.caller in op.target.sharedWith and op.caller != op.target.owner and op.caller.role = MemberRole }
