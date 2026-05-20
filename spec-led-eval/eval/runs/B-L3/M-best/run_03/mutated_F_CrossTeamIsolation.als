// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-Tenant Task Management with Per-Task Sharing and Audit.
// Structural invariants over Users, Teams, Tasks, AuditEntries and Operations.

// ----- Roles -----
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// ----- Operation kinds (the five endpoints, with PATCH split by body shape) -----
abstract sig OperationKind {}
one sig PostTasks, GetTaskOp, PatchFieldsOp, PatchSharedWithOp, DeleteTaskOp, GetAuditOp
  extends OperationKind {}

// ----- Outcomes -----
abstract sig Outcome {}
one sig Success, NotFoundOut, ValidationErrorOut, UnauthenticatedOut, AuditUnavailableOut
  extends Outcome {}

// ----- Audit event flavours -----
abstract sig AuditOp {}
one sig CreatedEv, EditedEv, DeletedEv, SharedEv, UnsharedEv extends AuditOp {}

// ----- Task status enum -----
abstract sig TaskStatus {}
one sig TodoSt, InProgressSt, DoneSt extends TaskStatus {}

// ----- Core entities -----
sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam: one Team,
  owner:    one User,
  sharedWith: set User,
  status:   one TaskStatus
}

sig AuditEntry {
  auditTask:   one Task,
  auditTeam:   one Team,
  actor:       one User,
  actorRole:   one Role,
  auditOpKind: one AuditOp
}

sig Operation {
  caller:   one User,
  kind:     one OperationKind,
  target:   lone Task,
  outcome:  one Outcome,
  produces: set AuditEntry
}

// AuthenticatedOp marks the subset of operations whose bearer token introspection succeeded.
sig AuthenticatedOp in Operation {}

// ----- Permission matrix (role × kind: "this role is eligible to attempt this op") -----
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Member    -> PostTasks)        + (Member    -> GetTaskOp)
  + (Member    -> PatchFieldsOp)    + (Member    -> PatchSharedWithOp)
  + (Member    -> DeleteTaskOp)     + (Member    -> GetAuditOp)
  + (TeamAdmin -> PostTasks)        + (TeamAdmin -> GetTaskOp)
  + (TeamAdmin -> PatchFieldsOp)    + (TeamAdmin -> PatchSharedWithOp)
  + (TeamAdmin -> DeleteTaskOp)     + (TeamAdmin -> GetAuditOp)
}

// ----- Non-empty universe (so quantifiers bite) -----
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some Operation
}

// ===== Structural facts =====

// data-model.md: task.team = task.owner.team
fact F_OwnerInTaskTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}

// FR-012: every sharee is a current member of the same team as the task owner
fact F_SharedWithSameTeam {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}

// Owner is implicitly in the read-set; should not appear in sharedWith
fact F_OwnerNotInSharedWith {
  all t: Task | t.owner not in t.sharedWith
}

// data-model.md: audit entries carry a denormalised team_id taken from the task
fact F_AuditTeamMatchesTaskTeam {
  all a: AuditEntry | a.auditTeam = a.auditTask.taskTeam
}

// FR-016: recorded actor_role is the actor's actual role (snapshot consistency)
fact F_AttributionRoleConsistent {
  all a: AuditEntry | a.actorRole = a.actor.userRole
}

// FR-016 + FR-015: every audit entry produced by an op references that op's target task
fact F_AuditTargetsOperationTask {
  all op: Operation | all a: op.produces | a.auditTask = op.target
}

// FR-016: actor on the audit row is the operation's caller (no misattribution)
fact F_AuditActorIsCaller {
  all op: Operation | all a: op.produces | a.actor = op.caller
}

// Every non-POST endpoint identifies a specific {id}
fact F_OperationTargetRequired {
  all op: Operation | op.kind != PostTasks implies some op.target
}

// FR-001: requests without a valid bearer token are rejected as Unauthenticated
fact F_AuthRequired {
  all op: Operation | op not in AuthenticatedOp implies op.outcome = UnauthenticatedOut
}

// FR-001: unauthenticated requests produce no audit entries
fact F_UnauthNoAudit {
  all op: Operation | op.outcome = UnauthenticatedOut implies no op.produces
}

// FR-018: AuditUnavailable rollback leaves no partial audit visible
fact F_AuditUnavailableNoEntries {
  all op: Operation | op.outcome = AuditUnavailableOut implies no op.produces
}

// FR-015 (no audit without state change): every audit entry is produced by some successful op
fact F_NoOrphanAuditEntries {
  all a: AuditEntry | some op: Operation | a in op.produces and op.outcome = Success
}

// FR-015 (no state change without audit): every successful task mutation produces some audit
fact F_AuditPerMutation {
  all op: Operation |
    (op.outcome = Success and
     op.kind in (PostTasks + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp))
      implies some op.produces
}

// FR-017: audit entries are append-only — no two distinct ops produce the same audit row
fact F_AppendOnlyAuditEntries {
  all disj op1, op2: Operation | no (op1.produces & op2.produces)
}

// FR-010 / SC-011: only the task's owner can successfully change shared_with
fact F_OwnerOnlySharedWith {
  all op: Operation |
    (op.kind = PatchSharedWithOp and op.outcome = Success)
      implies op.caller = op.target.owner
}

// FR-003/FR-004 read access for GetTaskOp: owner, active sharee, or same-team team_admin
fact F_GetTaskAccessRule {
  all op: Operation |
    (op.kind = GetTaskOp and op.outcome = Success)
      implies (op.caller = op.target.owner
            or op.caller in op.target.sharedWith
            or (op.caller.userRole = TeamAdmin and op.caller.userTeam = op.target.taskTeam))
}

// FR-011 delete authorisation: owner or same-team team_admin only (sharees blocked)
fact F_DeleteAccessRule {
  all op: Operation |
    (op.kind = DeleteTaskOp and op.outcome = Success)
      implies (op.caller = op.target.owner
            or (op.caller.userRole = TeamAdmin and op.caller.userTeam = op.target.taskTeam))
}

// FR-019: audit visibility tracks task read-access
fact F_AuditAccessRule {
  all op: Operation |
    (op.kind = GetAuditOp and op.outcome = Success)
      implies (op.caller = op.target.owner
            or op.caller in op.target.sharedWith
            or (op.caller.userRole = TeamAdmin and op.caller.userTeam = op.target.taskTeam))
}

// FR-006 / FR-014: cross-team callers never get Success on any /tasks/{id}* endpoint
fact F_CrossTeamIsolation { /* MUTATED — body cleared by validator */ }

// ===== Predicates + assertions (one per pattern, one per FR) =====

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, k: OperationKind | r -> k in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // No operation that bypasses auth can succeed or emit audit
  no op: Operation | op not in AuthenticatedOp
                     and (op.outcome = Success or some op.produces)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md (tasks.owner_id NOT NULL, one owner)
pred OwnershipExclusivity {
  all t: Task | one t.owner and one t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-004/FR-005
pred OwnershipBasedAccess {
  // Nobody outside (owner ∪ sharees ∪ same-team admin) can successfully GET the task
  no op: Operation |
    op.kind = GetTaskOp and op.outcome = Success and some op.target
    and op.caller != op.target.owner
    and op.caller not in op.target.sharedWith
    and not (op.caller.userRole = TeamAdmin and op.caller.userTeam = op.target.taskTeam)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-010, SC-011 (owner-only share control)
pred LeastPrivilege {
  no op: Operation |
    op.kind = PatchSharedWithOp and op.outcome = Success
    and some op.target and op.caller != op.target.owner
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017, data-model.md (no UPDATE/DELETE on audit_entries)
pred AppendOnly {
  // Each audit entry is the product of exactly one operation — no rewriting, no aliasing
  all a: AuditEntry | one op: Operation | a in op.produces
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, FR-018
pred AuditCompleteness {
  // Every successful task mutation leaves a corresponding audit trail entry
  all op: Operation |
    (op.outcome = Success and
     op.kind in (PostTasks + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp))
      implies some op.produces
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  all op: Operation, a: op.produces |
    a.actor = op.caller and a.auditTask = op.target and a.actorRole = op.caller.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-003
pred NoInformationLeakage {
  // Cross-team callers cannot obtain a Success — only the byte-equivalent NotFound
  no op: Operation |
    some op.target and op.caller.userTeam != op.target.taskTeam
    and op.kind in (GetTaskOp + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp + GetAuditOp)
    and op.outcome = Success
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth before business logic)
pred FR_001_AuthRequired {
  all op: Operation | op not in AuthenticatedOp implies op.outcome = UnauthenticatedOut
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-002a (team_id and role from token, one team per user)
pred FR_002_OneTeamOneRole {
  all u: User | one u.userTeam and one u.userRole
}
assert FR_002_OneTeamOneRole { FR_002_OneTeamOneRole }
check FR_002_OneTeamOneRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (member of team T can only own tasks in team T)
pred FR_003_OwnerInOwnTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}
assert FR_003_OwnerInOwnTeam { FR_003_OwnerInOwnTeam }
check FR_003_OwnerInOwnTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (in-team non-owner non-sharee non-admin cannot access)
pred FR_004_InTeamNoRelBlocked {
  no op: Operation |
    op.kind in (GetTaskOp + PatchFieldsOp + DeleteTaskOp + GetAuditOp)
    and op.outcome = Success and some op.target
    and op.caller.userTeam = op.target.taskTeam
    and op.caller != op.target.owner
    and op.caller not in op.target.sharedWith
    and op.caller.userRole != TeamAdmin
}
assert FR_004_InTeamNoRelBlocked { FR_004_InTeamNoRelBlocked }
check FR_004_InTeamNoRelBlocked for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (team admin can edit any task in own team, except shared_with)
pred FR_005_AdminTeamScope {
  all op: Operation |
    (op.caller.userRole = TeamAdmin and op.outcome = Success and some op.target
     and op.kind in (GetTaskOp + PatchFieldsOp + DeleteTaskOp + GetAuditOp))
      implies op.caller.userTeam = op.target.taskTeam
}
assert FR_005_AdminTeamScope { FR_005_AdminTeamScope }
check FR_005_AdminTeamScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (cross-team admin has no access — isolation invariant under role)
pred FR_006_CrossTeamBlocked {
  no op: Operation |
    op.outcome = Success and some op.target
    and op.caller.userTeam != op.target.taskTeam
    and op.kind in (GetTaskOp + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp + GetAuditOp)
}
assert FR_006_CrossTeamBlocked { FR_006_CrossTeamBlocked }
check FR_006_CrossTeamBlocked for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (task must have owner; title content rules are non-structural)
pred FR_007_TaskWellFormed {
  all t: Task | one t.owner and one t.taskTeam and one t.status
}
assert FR_007_TaskWellFormed { FR_007_TaskWellFormed }
check FR_007_TaskWellFormed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 (status from the fixed enum set)
pred FR_008_StatusEnum {
  all t: Task | t.status in (TodoSt + InProgressSt + DoneSt)
}
assert FR_008_StatusEnum { FR_008_StatusEnum }
check FR_008_StatusEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (owner_id and team_id immutable — modelled as exactly-one binding)
pred FR_009_ImmutableOwnerTeam {
  all t: Task | one t.owner and one t.taskTeam
}
assert FR_009_ImmutableOwnerTeam { FR_009_ImmutableOwnerTeam }
check FR_009_ImmutableOwnerTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, SC-011 (only owner changes shared_with)
pred FR_010_OwnerOnlyShareControl {
  all op: Operation |
    (op.kind = PatchSharedWithOp and op.outcome = Success)
      implies (some op.target and op.caller = op.target.owner)
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 (sharee may not delete — owner or admin only)
pred FR_011_ShareeNoDelete {
  all op: Operation |
    (op.kind = DeleteTaskOp and op.outcome = Success)
      implies (op.caller = op.target.owner
            or (op.caller.userRole = TeamAdmin and op.caller.userTeam = op.target.taskTeam))
}
assert FR_011_ShareeNoDelete { FR_011_ShareeNoDelete }
check FR_011_ShareeNoDelete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (no cross-team sharing)
pred FR_012_NoCrossTeamSharing {
  all t: Task | all u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_NoCrossTeamSharing { FR_012_NoCrossTeamSharing }
check FR_012_NoCrossTeamSharing for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (successful share/unshare emits audit entries)
pred FR_013_ShareAudit {
  all op: Operation |
    (op.kind = PatchSharedWithOp and op.outcome = Success) implies some op.produces
}
assert FR_013_ShareAudit { FR_013_ShareAudit }
check FR_013_ShareAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent not-found — no Success leaks cross-team)
pred FR_014_CrossTeamByteEquiv {
  no op: Operation |
    op.outcome = Success and some op.target
    and op.caller.userTeam != op.target.taskTeam
    and op.kind in (GetTaskOp + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp + GetAuditOp)
}
assert FR_014_CrossTeamByteEquiv { FR_014_CrossTeamByteEquiv }
check FR_014_CrossTeamByteEquiv for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (no audit without state change, no state change without audit)
pred FR_015_NoOrphanAudit {
  (all a: AuditEntry | some op: Operation | a in op.produces and op.outcome = Success)
  and
  (all op: Operation |
     (op.outcome = Success and
      op.kind in (PostTasks + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp))
       implies some op.produces)
}
assert FR_015_NoOrphanAudit { FR_015_NoOrphanAudit }
check FR_015_NoOrphanAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit entry fields: task, actor, actor_role snapshot, team)
pred FR_016_AuditFieldsConsistent {
  all a: AuditEntry |
    a.auditTeam = a.auditTask.taskTeam
    and a.actorRole = a.actor.userRole
}
assert FR_016_AuditFieldsConsistent { FR_016_AuditFieldsConsistent }
check FR_016_AuditFieldsConsistent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entries immutable / append-only)
pred FR_017_AuditImmutable {
  all a: AuditEntry | one op: Operation | a in op.produces
}
assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit-write atomicity; rollback leaves no partial audit)
pred FR_018_AuditAtomicity {
  all op: Operation |
    (op.outcome = AuditUnavailableOut implies no op.produces)
    and
    ((op.outcome = Success and
      op.kind in (PostTasks + PatchFieldsOp + PatchSharedWithOp + DeleteTaskOp))
        implies some op.produces)
}
assert FR_018_AuditAtomicity { FR_018_AuditAtomicity }
check FR_018_AuditAtomicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 (audit visible only to read-set: owner / sharee / same-team admin)
pred FR_019_AuditAccess {
  all op: Operation |
    (op.kind = GetAuditOp and op.outcome = Success)
      implies (op.caller = op.target.owner
            or op.caller in op.target.sharedWith
            or (op.caller.userRole = TeamAdmin and op.caller.userTeam = op.target.taskTeam))
}
assert FR_019_AuditAccess { FR_019_AuditAccess }
check FR_019_AuditAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020 (audit retention — structural: every audit entry has a fixed task)
pred FR_020_AuditRetained {
  all a: AuditEntry | one a.auditTask and one a.auditTeam and one a.actor
}
assert FR_020_AuditRetained { FR_020_AuditRetained }
check FR_020_AuditRetained for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021 (performance — out of structural scope; well-formedness placeholder)
pred FR_021_OperationWellFormed {
  all op: Operation | one op.caller and one op.kind and one op.outcome
}
assert FR_021_OperationWellFormed { FR_021_OperationWellFormed }
check FR_021_OperationWellFormed for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeamSuccess { some op: Operation | op.kind = PatchFieldsOp and op.outcome = Success and some op.target and op.caller.userTeam != op.target.taskTeam }
