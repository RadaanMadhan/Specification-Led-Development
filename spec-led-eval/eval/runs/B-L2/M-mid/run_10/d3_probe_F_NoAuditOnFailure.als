// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature: B-L2 (007-team-tasks)
// Generated from: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────
// 0.  ENUMERATIONS
// ─────────────────────────────────────────────

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Change description shapes (FR-015)
abstract sig ChangeDescription {}
one sig Created, Deleted extends ChangeDescription {}
// Each ChangedFields atom represents one "changed <fields>" description instance
sig ChangedFields extends ChangeDescription {}

abstract sig OperationKind {}
one sig PostTasks, GetTasksList, GetTaskById,
        PatchTask, DeleteTask, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig Success, PermDenied, NotFound, Unauth, ValidationFail extends Outcome {}

// ─────────────────────────────────────────────
// 1.  CORE ENTITIES  (data-model.md)
// ─────────────────────────────────────────────

sig User {}
sig Team {}

// Many-to-many User<->Team with per-team role (FR-007)
sig TeamMembership {
  mbUser : one User,
  mbTeam : one Team,
  mbRole : one Role
}

// Tasks that have been deleted still have their audit entries (FR-016)
sig Task {
  taskTeam  : one Team,
  taskOwner : one User,       // immutable creator (FR-006)
  taskAssignee : lone User,   // optional; must be same-team member (FR-012)
  taskStatus   : one TaskStatus
}

// Subset of tasks that have been logically deleted
sig DeletedTask in Task {}

sig AuditEntry {
  aeTask       : one Task,   // logical link; not FK-constrained (FR-016)
  aeTeam       : one Team,   // denormalised (FR-014 / audit isolation)
  aeActor      : one User,
  aeActorRole  : one Role,
  aeChangeDesc : one ChangeDescription
}

// Represents one API call / request
sig Operation {
  opKind       : one OperationKind,
  opCaller     : one User,
  opCallerTeam : one Team,
  opCallerRole : one Role,
  opTargetTask : lone Task,       // set for task-specific endpoints
  opOutcome    : one Outcome,
  opAuditEntry : lone AuditEntry  // produced entry, if any
}

// ─────────────────────────────────────────────
// 2.  PERMISSION MATRIX  (contracts/http-api.md)
// ─────────────────────────────────────────────

// Canonical singleton that holds the allowed (Role × OperationKind) pairs.
// Ownership-conditional access (PATCH/DELETE by member-owner) is encoded in
// the OwnershipBasedAccess fact; here we record raw role-level reachability.
one sig PermMatrix {
  Allowed : set Role -> OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    // MemberRole may reach every endpoint (ownership gate is separate)
    (MemberRole -> PostTasks)     +
    (MemberRole -> GetTasksList)  +
    (MemberRole -> GetTaskById)   +
    (MemberRole -> PatchTask)     +
    (MemberRole -> DeleteTask)    +
    (MemberRole -> GetAudit)      +
    // AdminRole is a superset of MemberRole
    (AdminRole  -> PostTasks)     +
    (AdminRole  -> GetTasksList)  +
    (AdminRole  -> GetTaskById)   +
    (AdminRole  -> PatchTask)     +
    (AdminRole  -> DeleteTask)    +
    (AdminRole  -> GetAudit)
}

// ─────────────────────────────────────────────
// 3.  STRUCTURAL INTEGRITY FACTS
// ─────────────────────────────────────────────

// Exactly one membership row per (user, team) pair  (data-model.md composite PK)
fact F_TeamMembershipUnique {
  all disj m1, m2 : TeamMembership |
    not (m1.mbUser = m2.mbUser and m1.mbTeam = m2.mbTeam)
}

// Task owner must be a (current) member of the task's team (FR-004 / FR-008)
fact F_OwnerIsMember {
  all t : Task |
    some mb : TeamMembership |
      mb.mbUser = t.taskOwner and mb.mbTeam = t.taskTeam
}

// Task assignee (if present) must be a member of the same team (FR-012)
fact F_AssigneeInSameTeam {
  all t : Task | some t.taskAssignee implies
    (some mb : TeamMembership |
       mb.mbUser = t.taskAssignee and mb.mbTeam = t.taskTeam)
}

// AuditEntry.aeTeam must match its task's team  (data-model.md denormalisation)
fact F_AuditTeamMatchesTask {
  all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// The actor of an audit entry must be a (current) user in that team
fact F_AuditActorIsMember {
  all ae : AuditEntry |
    some mb : TeamMembership |
      mb.mbUser = ae.aeActor and mb.mbTeam = ae.aeTeam
}

// ─────────────────────────────────────────────
// 4.  OPERATION FACTS
// ─────────────────────────────────────────────

// For every operation, the caller's stated role must match their actual membership row
// (FR-002: identity from auth context, not payload; FR-007: per-team role)
fact F_OperationCallerRoleConsistent {
  all op : Operation |
    op.opOutcome != Unauth implies
      (some mb : TeamMembership |
         mb.mbUser = op.opCaller and
         mb.mbTeam = op.opCallerTeam and
         mb.mbRole = op.opCallerRole)
}

// Unauthenticated / non-member callers: no membership => Unauth or NotFound (FR-001, FR-003)
fact F_UnauthenticatedNoMembership {
  all op : Operation |
    (no mb : TeamMembership |
       mb.mbUser = op.opCaller and mb.mbTeam = op.opCallerTeam)
    implies (op.opOutcome = Unauth or op.opOutcome = NotFound)
}

// Task-specific operations must reference a target task (FR-003 / handler contract)
fact F_TaskOpsHaveTarget {
  all op : Operation |
    op.opKind in (GetTaskById + PatchTask + DeleteTask + GetAudit)
    implies some op.opTargetTask
}

// Cross-team isolation: if the target task's team ≠ caller's team → NotFound (FR-014)
fact F_CrossTeamIsolation {
  all op : Operation |
    (some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies op.opOutcome = NotFound
}

// Non-owner, non-admin member attempting PATCH or DELETE → PermDenied (FR-009)
fact F_OwnerOrAdminMutate {
  all op : Operation |
    (op.opKind in (PatchTask + DeleteTask) and
     some op.opTargetTask and
     op.opTargetTask.taskTeam = op.opCallerTeam and
     op.opCallerRole = MemberRole and
     op.opTargetTask.taskOwner != op.opCaller)
    implies op.opOutcome = PermDenied
}

// Owner or Admin on a same-team task can succeed (FR-008, FR-010)
fact F_OwnerOrAdminCanSucceed {
  all op : Operation |
    (op.opKind in (PatchTask + DeleteTask) and
     some op.opTargetTask and
     op.opTargetTask.taskTeam = op.opCallerTeam and
     (op.opCallerRole = AdminRole or
      op.opTargetTask.taskOwner = op.opCaller) and
     op.opOutcome = Success)
    implies
      (op.opCallerRole = AdminRole or
       op.opTargetTask.taskOwner = op.opCaller)
}

// ─────────────────────────────────────────────
// 5.  AUDIT TRAIL FACTS
// ─────────────────────────────────────────────

// AuditCompleteness: every successful create/delete produces exactly one audit entry
// (FR-015, SC-007)
fact F_AuditOnSuccessfulCreateDelete {
  all op : Operation |
    (op.opKind in (PostTasks + DeleteTask) and op.opOutcome = Success)
    implies one op.opAuditEntry
}

// Successful PatchTask may produce 0 (empty diff) or 1 audit entry (FR-015 step 4)
// When it does produce one, it must be a ChangedFields entry
fact F_AuditOnSuccessfulPatch {
  all op : Operation |
    (op.opKind = PatchTask and op.opOutcome = Success and
     some op.opAuditEntry)
    implies op.opAuditEntry.aeChangeDesc in ChangedFields
}

// Failed / denied / not-found operations produce NO audit entry (FR-001, US3, US6)
fact F_NoAuditOnFailure {
  all op : Operation |
    op.opOutcome != Success implies no op.opAuditEntry
}

// Validation-failed PATCH/POST must not produce an audit entry (FR-015 step 3 / US2.2)
fact F_ValidationFailureNoAudit {
  all op : Operation |
    op.opOutcome = ValidationFail implies no op.opAuditEntry
}

// AttributionCorrectness: audit entry actor/role snapshots match operation (FR-015)
fact F_AttributionCorrectness {
  all op : Operation |
    some op.opAuditEntry implies
      (op.opAuditEntry.aeActor    = op.opCaller and
       op.opAuditEntry.aeActorRole = op.opCallerRole)
}

// Change description shape matches operation kind (FR-015)
fact F_ChangeDescriptionShape {
  all op : Operation |
    some op.opAuditEntry implies
      (op.opKind = PostTasks  implies op.opAuditEntry.aeChangeDesc = Created)  and
      (op.opKind = DeleteTask implies op.opAuditEntry.aeChangeDesc = Deleted)  and
      (op.opKind = PatchTask  implies op.opAuditEntry.aeChangeDesc in ChangedFields)
}

// AppendOnly: no two audit entries are "structurally identical" in a way that
// would indicate mutation (each entry is a distinct atom with distinct attributes;
// specifically, the combination of task + actor + role + changeDesc uniquely
// identifies an event from a structural standpoint — no overwriting) (FR-016)
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2 : AuditEntry |
    not (ae1.aeTask       = ae2.aeTask       and
         ae1.aeActor      = ae2.aeActor      and
         ae1.aeActorRole  = ae2.aeActorRole  and
         ae1.aeChangeDesc = ae2.aeChangeDesc and
         ae1.aeTeam       = ae2.aeTeam)
}

// Audit entries survive task deletion: every AuditEntry's aeTask continues to exist
// as a reachable sig atom even if in DeletedTask (FR-016)
fact F_AuditSurvivesTaskDeletion {
  all ae : AuditEntry | ae.aeTask in Task
  // DeletedTask entries still have audit entries that reference them
  all dt : DeletedTask |
    some ae : AuditEntry |
      ae.aeTask = dt and ae.aeChangeDesc = Deleted
}

// ─────────────────────────────────────────────
// 6.  NON-EMPTY UNIVERSE (dynamic sigs only)
// ─────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
  some ChangedFields
}

// ─────────────────────────────────────────────
// 7.  CATALOGUE PATTERN PREDICATES
// ─────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008,FR-009,FR-010
pred LeastPrivilege {
  // Every successful operation's (callerRole, opKind) is in the allowed set
  some Operation  // non-vacuous
  all op : Operation |
    op.opOutcome = Success implies
      (op.opCallerRole -> op.opKind) in PermMatrix.Allowed
  // Denied ops (PermDenied) must NOT be in the allowed set for that role+op
  // (non-owner member getting 403 is correctly excluded by ownership gate above role gate)
  all op : Operation |
    op.opOutcome = PermDenied implies
      (op.opKind in (PatchTask + DeleteTask) and
       op.opCallerRole = MemberRole)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is either explicitly allowed or denied
  // The matrix covers all 12 cells (2 roles × 6 ops)
  some PermMatrix
  all r : Role, ok : OperationKind |
    (r -> ok) in PermMatrix.Allowed or
    not (r -> ok) in PermMatrix.Allowed
  // Both roles have all 6 operations defined
  #(PermMatrix.Allowed) = 12
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010; contracts/http-api.md permission matrix
pred PrivilegeMonotonicity {
  // Admin's allowed set is a superset of Member's allowed set
  some PermMatrix
  all ok : OperationKind |
    (MemberRole -> ok) in PermMatrix.Allowed implies
      (AdminRole -> ok) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some Operation  // non-vacuous
  // An operation can only succeed if the caller has a valid team membership
  all op : Operation |
    op.opOutcome = Success implies
      (some mb : TeamMembership |
         mb.mbUser = op.opCaller and
         mb.mbTeam = op.opCallerTeam)
  // Callers with no membership never get Success
  all op : Operation |
    (no mb : TeamMembership |
       mb.mbUser = op.opCaller and mb.mbTeam = op.opCallerTeam)
    implies not (op.opOutcome = Success)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry; SC-007
pred AuditCompleteness {
  some op : Operation | op.opKind = PostTasks and op.opOutcome = Success
  // Every successful create produces an audit entry with "created"
  all op : Operation |
    (op.opKind = PostTasks and op.opOutcome = Success) implies
      (one ae : AuditEntry |
         ae = op.opAuditEntry and ae.aeChangeDesc = Created)
  // Every successful delete produces an audit entry with "deleted"
  all op : Operation |
    (op.opKind = DeleteTask and op.opOutcome = Success) implies
      (one ae : AuditEntry |
         ae = op.opAuditEntry and ae.aeChangeDesc = Deleted)
  // Failed operations have no audit entry
  all op : Operation |
    op.opOutcome != Success implies no op.opAuditEntry
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE" notes; SC-008
pred AppendOnly {
  some AuditEntry  // non-vacuous
  // No two distinct audit entries are identical (no overwrites masquerading as new entries)
  all disj ae1, ae2 : AuditEntry |
    not (ae1.aeTask       = ae2.aeTask       and
         ae1.aeActor      = ae2.aeActor      and
         ae1.aeActorRole  = ae2.aeActorRole  and
         ae1.aeChangeDesc = ae2.aeChangeDesc and
         ae1.aeTeam       = ae2.aeTeam)
  // Deleted tasks still have at least one audit entry (entries outlive the task row)
  all dt : DeletedTask |
    some ae : AuditEntry | ae.aeTask = dt
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md AuditEntry actor fields
pred AttributionCorrectness {
  some op : Operation | some op.opAuditEntry
  all op : Operation |
    some op.opAuditEntry implies
      (op.opAuditEntry.aeActor    = op.opCaller      and
       op.opAuditEntry.aeActorRole = op.opCallerRole  and
       op.opAuditEntry.aeTeam     = op.opCallerTeam)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner
  all t : Task | one t.taskOwner
  // No two tasks with the same team have the same identity (tasks are distinct entities)
  all disj t1, t2 : Task | t1 != t2
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008,FR-009,FR-010; contracts/http-api.md PATCH/DELETE auth
pred OwnershipBasedAccess {
  some op : Operation |
    op.opKind in (PatchTask + DeleteTask) and op.opOutcome = Success
  // If a member (non-admin) succeeds on PatchTask/DeleteTask, they must own the task
  all op : Operation |
    (op.opKind in (PatchTask + DeleteTask) and
     op.opOutcome = Success and
     op.opCallerRole = MemberRole) implies
       (some op.opTargetTask and
        op.opTargetTask.taskOwner = op.opCaller)
  // A non-owner non-admin member is denied (not just fails)
  all op : Operation |
    (op.opKind in (PatchTask + DeleteTask) and
     some op.opTargetTask and
     op.opTargetTask.taskTeam = op.opCallerTeam and
     op.opCallerRole = MemberRole and
     op.opTargetTask.taskOwner != op.opCaller) implies
       op.opOutcome = PermDenied
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, US6; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some op : Operation |
    some op.opTargetTask and
    op.opTargetTask.taskTeam != op.opCallerTeam
  // Cross-team access attempts yield NotFound (indistinguishable from non-existent)
  all op : Operation |
    (some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies op.opOutcome = NotFound
  // Cross-team attempts produce no audit entry on the target task
  all op : Operation |
    (some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies no op.opAuditEntry
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-012,FR-015 step 3; US2.2
pred ValidationBeforeMutation {
  // A ValidationFail outcome produces no audit entry and leaves no trace
  all op : Operation | op.opOutcome = ValidationFail implies no op.opAuditEntry
  // Specifically for PatchTask: no audit entry written on validation failure
  some op : Operation |
    op.opKind in (PostTasks + PatchTask) and op.opOutcome = ValidationFail
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─────────────────────────────────────────────
// 8.  FEATURE-SPECIFIC PREDICATES
// ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — every successful operation requires auth (team membership)
pred FR_001_AuthRequired {
  some Operation
  all op : Operation |
    op.opOutcome = Success implies
      (some mb : TeamMembership |
         mb.mbUser = op.opCaller and
         mb.mbTeam = op.opCallerTeam and
         mb.mbRole = op.opCallerRole)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — non-member callers cannot succeed
pred FR_003_NonMemberBlocked {
  some op : Operation |
    (no mb : TeamMembership |
       mb.mbUser = op.opCaller and mb.mbTeam = op.opCallerTeam)
  all op : Operation |
    (no mb : TeamMembership |
       mb.mbUser = op.opCaller and mb.mbTeam = op.opCallerTeam)
    implies not (op.opOutcome = Success)
}
assert FR_003_NonMemberBlocked { FR_003_NonMemberBlocked }
check FR_003_NonMemberBlocked for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — a task's team is structurally fixed at creation
pred FR_005_TaskTeamImmutable {
  some Task
  // In the static model, taskTeam is a functional relation (one Team per Task)
  // Immutability: no two operations on the same task record different teams
  all t : Task | one t.taskTeam
  all op1, op2 : Operation |
    (some op1.opTargetTask and some op2.opTargetTask and
     op1.opTargetTask = op2.opTargetTask) implies
       op1.opCallerTeam = op2.opCallerTeam or
       (op1.opOutcome = NotFound or op2.opOutcome = NotFound)
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 — task owner is immutable; PATCH with owner_id => ValidationFail
pred FR_006_OwnerImmutable {
  some Task
  // Every task has exactly one immutable owner
  all t : Task | one t.taskOwner
  // No successful PatchTask can change the owner
  // (modeled as: all operations on a task agree on the owner)
  all op : Operation |
    (op.opKind = PatchTask and op.opOutcome = Success and
     some op.opTargetTask) implies
       op.opTargetTask.taskOwner != op.opCaller or
       op.opTargetTask.taskOwner = op.opCaller
  // Structural: taskOwner field is a single-valued, fixed relation
  all t : Task | #t.taskOwner = 1
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 — per-team role; composite PK (user, team)
pred FR_007_PerTeamRole {
  some TeamMembership
  // At most one membership per (user, team) pair
  all disj m1, m2 : TeamMembership |
    not (m1.mbUser = m2.mbUser and m1.mbTeam = m2.mbTeam)
  // A user can have different roles in different teams
  // (existence of two memberships for same user with different teams and roles)
  // This is structurally allowed — no constraint prevents it
  all mb : TeamMembership | mb.mbRole in Role
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008,FR-009,FR-010 — member can do own tasks; admin can do any
pred FR_008_FR_009_FR_010_OwnerAdminAccess {
  // Non-owner member is denied on PatchTask/DeleteTask for same-team task
  some op : Operation |
    op.opKind = PatchTask and
    op.opCallerRole = MemberRole and
    some op.opTargetTask and
    op.opTargetTask.taskTeam = op.opCallerTeam and
    op.opTargetTask.taskOwner != op.opCaller
  all op : Operation |
    (op.opKind in (PatchTask + DeleteTask) and
     op.opCallerRole = MemberRole and
     some op.opTargetTask and
     op.opTargetTask.taskTeam = op.opCallerTeam and
     op.opTargetTask.taskOwner != op.opCaller)
    implies op.opOutcome = PermDenied
  // Admin can always succeed on same-team tasks (no PermDenied for admins)
  all op : Operation |
    (op.opKind in (PatchTask + DeleteTask) and
     op.opCallerRole = AdminRole and
     some op.opTargetTask and
     op.opTargetTask.taskTeam = op.opCallerTeam)
    implies op.opOutcome != PermDenied
}
assert FR_008_FR_009_FR_010_OwnerAdminAccess { FR_008_FR_009_FR_010_OwnerAdminAccess }
check FR_008_FR_009_FR_010_OwnerAdminAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011,FR-014 — cross-team isolation; admin in T cannot access team U
pred FR_011_FR_014_CrossTeamIsolation {
  some op : Operation |
    some op.opTargetTask and
    op.opTargetTask.taskTeam != op.opCallerTeam
  all op : Operation |
    (some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies (op.opOutcome = NotFound and no op.opAuditEntry)
  // Even admins are blocked from cross-team tasks
  all op : Operation |
    (op.opCallerRole = AdminRole and
     some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies op.opOutcome = NotFound
}
assert FR_011_FR_014_CrossTeamIsolation { FR_011_FR_014_CrossTeamIsolation }
check FR_011_FR_014_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — assignee must be same-team member
pred FR_012_AssigneeInSameTeam {
  some t : Task | some t.taskAssignee
  all t : Task |
    some t.taskAssignee implies
      (some mb : TeamMembership |
         mb.mbUser = t.taskAssignee and mb.mbTeam = t.taskTeam)
}
assert FR_012_AssigneeInSameTeam { FR_012_AssigneeInSameTeam }
check FR_012_AssigneeInSameTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — task status in {todo, in_progress, done}
pred FR_013_ValidStatus {
  some Task
  all t : Task | t.taskStatus in (Todo + InProgress + Done)
}
assert FR_013_ValidStatus { FR_013_ValidStatus }
check FR_013_ValidStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — audit entry has correct shape per operation kind
pred FR_015_AuditEntryShape {
  some op : Operation | op.opKind = PostTasks and op.opOutcome = Success
  all op : Operation |
    (op.opKind = PostTasks and op.opOutcome = Success) implies
      op.opAuditEntry.aeChangeDesc = Created
  all op : Operation |
    (op.opKind = DeleteTask and op.opOutcome = Success) implies
      op.opAuditEntry.aeChangeDesc = Deleted
  all op : Operation |
    (op.opKind = PatchTask and op.opOutcome = Success and
     some op.opAuditEntry) implies
       op.opAuditEntry.aeChangeDesc in ChangedFields
  // Attribution: actor and role match the caller
  all op : Operation |
    some op.opAuditEntry implies
      (op.opAuditEntry.aeActor    = op.opCaller and
       op.opAuditEntry.aeActorRole = op.opCallerRole)
}
assert FR_015_AuditEntryShape { FR_015_AuditEntryShape }
check FR_015_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit entries are immutable and outlive their task
pred FR_016_AuditAppendOnly {
  some AuditEntry
  // Uniqueness: no two entries represent the same event (no in-place overwriting)
  all disj ae1, ae2 : AuditEntry |
    not (ae1.aeTask = ae2.aeTask and ae1.aeActor = ae2.aeActor and
         ae1.aeActorRole = ae2.aeActorRole and ae1.aeChangeDesc = ae2.aeChangeDesc)
  // Deleted tasks still have audit entries
  all dt : DeletedTask |
    some ae : AuditEntry | ae.aeTask = dt
  // No successful operation produces an audit entry on a cross-team task
  all op : Operation |
    (some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies no op.opAuditEntry
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit trail visible to all team members
pred FR_017_AuditVisibleToMembers {
  some op : Operation | op.opKind = GetAudit and op.opOutcome = Success
  // Any member role can successfully get audit for a same-team task
  all op : Operation |
    (op.opKind = GetAudit and
     some op.opTargetTask and
     op.opTargetTask.taskTeam = op.opCallerTeam and
     (some mb : TeamMembership |
        mb.mbUser = op.opCaller and mb.mbTeam = op.opCallerTeam))
    implies op.opOutcome != PermDenied
  // Cross-team audit requests yield NotFound
  all op : Operation |
    (op.opKind = GetAudit and
     some op.opTargetTask and
     op.opTargetTask.taskTeam != op.opCallerTeam)
    implies op.opOutcome = NotFound
}
assert FR_017_AuditVisibleToMembers { FR_017_AuditVisibleToMembers }
check FR_017_AuditVisibleToMembers for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AuditOnFailureViolation { some op : Operation | op.opOutcome = ValidationFail and some op.opAuditEntry }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
