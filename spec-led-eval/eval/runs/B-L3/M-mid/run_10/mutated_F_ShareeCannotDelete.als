// === feature_model.als — Alloy model for Multi-Tenant Task Management with Per-Task Sharing and Audit ===
// Feature: B-L3 / 008-task-sharing
// Spec: spec.md, data-model.md, contracts/http-api.md

// ─── Role enumeration ────────────────────────────────────────────────────────

abstract sig Role {}
one sig MemberRole, TeamAdminRole extends Role {}

// ─── Audit operation enumeration ─────────────────────────────────────────────

abstract sig AuditOp {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOp {}

// ─── Operation-kind enumeration (actions callers invoke on tasks) ─────────────

abstract sig OperationKind {}
one sig KCreateTask, KViewTask, KEditFields, KChangeSharedWith,
        KDeleteTask, KViewAudit extends OperationKind {}

// ─── Caller-relationship enumeration ─────────────────────────────────────────

abstract sig Relationship {}
one sig RelOutsider, RelInTeamNone, RelSharee, RelTeamAdmin, RelOwner
  extends Relationship {}

// ─── Permission outcome ───────────────────────────────────────────────────────

abstract sig PermOutcome {}
one sig POAllowed, PODenied extends PermOutcome {}

// Permission matrix — keyed by Relationship × OperationKind
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// ─── Domain entities ──────────────────────────────────────────────────────────

sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam : one Team,
  taskOwner: one User,
  sharedWith: set User
}

sig AuditEntry {
  auditTask     : one Task,
  auditTeam     : one Team,
  auditActor    : one User,
  auditActorRole: one Role,
  auditOp       : one AuditOp
}

// An Operation is a single request by a caller against a task.
// opAuditEntries captures audit rows produced when the operation succeeds.
sig Operation {
  opCaller       : one User,
  opTask         : one Task,
  opKind         : one OperationKind,
  opRel          : one Relationship,
  opOutcome      : one PermOutcome,
  opAuditEntries : set AuditEntry
}

// ─── Non-empty universe (Rule 9) ──────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Operation
}

// ─── Structural / data-model facts ───────────────────────────────────────────

// A task's team is always the owner's team (denormalised but consistent).
fact F_TaskTeamMatchesOwner {
  all t: Task | t.taskTeam = t.taskOwner.userTeam
}

// FR-012: every sharee must be in the same team as the task.
fact F_ShareeTeamMembership {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}

// Owners are not listed as their own sharee (structural tidiness; owner access
// is authoritative from RelOwner, not RelSharee).
fact F_OwnerNotInSharedWith {
  all t: Task | t.taskOwner not in t.sharedWith
}

// AuditEntry carries a denormalised team_id equal to the task's team (data-model.md).
fact F_AuditTeamMatchesTaskTeam {
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}

// AuditEntry actor must be a member of the entry's team (attribution sanity).
fact F_AuditActorInTeam {
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
}

// FR-016: actor_role in every audit entry is a snapshot of the actor's role
// at the time of the change (in this static model: must equal the actor's role).
fact F_AuditActorRoleSnapshot {
  all ae: AuditEntry | ae.auditActorRole = ae.auditActor.userRole
}

// ─── Relationship derivation ──────────────────────────────────────────────────

// op.opRel is fully determined by (caller, task).  Priority: Owner > TeamAdmin >
// Sharee > InTeamNone > Outsider (consistent with contracts/http-api.md matrix).
fact F_RelationshipDerivation {
  all op: Operation |
    let u = op.opCaller, t = op.opTask | {
      (u.userTeam != t.taskTeam)
        => op.opRel = RelOutsider
      (u.userTeam = t.taskTeam and u = t.taskOwner)
        => op.opRel = RelOwner
      (u.userTeam = t.taskTeam and u != t.taskOwner
       and u.userRole = TeamAdminRole)
        => op.opRel = RelTeamAdmin
      (u.userTeam = t.taskTeam and u != t.taskOwner
       and u.userRole = MemberRole and u in t.sharedWith)
        => op.opRel = RelSharee
      (u.userTeam = t.taskTeam and u != t.taskOwner
       and u.userRole = MemberRole and u not in t.sharedWith)
        => op.opRel = RelInTeamNone
    }
}

// ─── Permission matrix ────────────────────────────────────────────────────────

// contracts/http-api.md permission table, translated to (Relationship × OperationKind).
// KCreateTask is available to any in-team user (they become the owner).
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RelOwner      -> KCreateTask)      +
    (RelTeamAdmin  -> KCreateTask)      +
    (RelInTeamNone -> KCreateTask)      +
    (RelOwner      -> KViewTask)        +
    (RelSharee     -> KViewTask)        +
    (RelTeamAdmin  -> KViewTask)        +
    (RelOwner      -> KEditFields)      +
    (RelSharee     -> KEditFields)      +
    (RelTeamAdmin  -> KEditFields)      +
    (RelOwner      -> KChangeSharedWith)+
    (RelOwner      -> KDeleteTask)      +
    (RelTeamAdmin  -> KDeleteTask)      +
    (RelOwner      -> KViewAudit)       +
    (RelSharee     -> KViewAudit)       +
    (RelTeamAdmin  -> KViewAudit)
}

// Operation outcome is completely determined by the permission matrix.
fact F_OutcomeFromPermission {
  all op: Operation |
    op.opOutcome = POAllowed <=>
      (op.opRel -> op.opKind) in PermMatrix.Allowed
}

// ─── Access-control enforcement facts ────────────────────────────────────────

// FR-006 / FR-014: cross-team callers are always denied.
fact F_CrossTeamIsolation {
  all op: Operation |
    op.opRel = RelOutsider => op.opOutcome = PODenied
}

// FR-004: in-team callers with no ownership/share/admin relationship are denied
// on every task-specific action.
fact F_InTeamNoRelDenied {
  all op: Operation |
    (op.opRel = RelInTeamNone and
     op.opKind in (KViewTask + KEditFields + KChangeSharedWith
                   + KDeleteTask + KViewAudit))
      => op.opOutcome = PODenied
}

// FR-010 / Q1=A: only the task owner may change shared_with.
fact F_OwnerOnlyShareControl {
  all op: Operation |
    op.opKind = KChangeSharedWith =>
      (op.opOutcome = POAllowed <=> op.opRel = RelOwner)
}

// FR-011 / Q3=B: a sharee attempting DELETE is denied (byte-equivalent 404).
fact F_ShareeCannotDelete { /* MUTATED — body cleared by validator */ }

// ─── Audit facts ──────────────────────────────────────────────────────────────

// FR-015: every allowed mutation produces at least one audit entry.
fact F_AuditCompleteness {
  all op: Operation |
    (op.opOutcome = POAllowed and
     op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask))
      => some op.opAuditEntries
}

// FR-015: denied operations produce no audit entries.
fact F_NoAuditOnDeniedOp {
  all op: Operation |
    op.opOutcome = PODenied => no op.opAuditEntries
}

// FR-015: audit entries reference the same task as the operation that produced them.
fact F_AuditEntriesReferenceOpTask {
  all op: Operation, ae: op.opAuditEntries |
    ae.auditTask = op.opTask
}

// FR-016: audit entries record the caller as the actor.
fact F_AuditEntriesRecordActor {
  all op: Operation, ae: op.opAuditEntries |
    ae.auditActor = op.opCaller
}

// FR-017 / AppendOnly: each AuditEntry is produced by exactly one operation.
// Entries are never deleted or re-attributed — the one-to-one ownership
// structurally prevents any "update/delete" path.
fact F_AppendOnlyAuditEntries {
  all ae: AuditEntry | one op: Operation | ae in op.opAuditEntries
}

// ─────────────────────────────────────────────────────────────────────────────
// PREDICATE + ASSERTION BLOCK
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003/FR-004/FR-005
pred LeastPrivilege {
  // No denied cell in the matrix grants an allowed operation outcome,
  // and no operation with an allowed outcome lacks a matrix entry.
  some Operation  // force non-vacuous scope
  all op: Operation |
    (op.opOutcome = POAllowed) => (op.opRel -> op.opKind) in PermMatrix.Allowed
  all op: Operation |
    (op.opRel -> op.opKind) not in PermMatrix.Allowed => op.opOutcome = PODenied
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every (Relationship × OperationKind) pair resolves to exactly one outcome;
  // since POAllowed and PODenied cover all outcomes, completeness is guaranteed
  // when PermMatrix.Allowed is the authoritative set and F_OutcomeFromPermission holds.
  some Operation
  all op: Operation | op.opOutcome = POAllowed or op.opOutcome = PODenied
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every Operation has a caller with a valid team and role (no anonymous callers).
  // All users carry exactly one userTeam and one userRole (enforced by sig fields).
  some Operation
  all op: Operation | one op.opCaller.userTeam and one op.opCaller.userRole
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry; SC-007
pred AuditCompleteness {
  some op: Operation |
    op.opOutcome = POAllowed and
    op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask)
  all op: Operation |
    (op.opOutcome = POAllowed and
     op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask))
      => some op.opAuditEntries
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"; SC-009
pred AppendOnly {
  // Each AuditEntry is owned by exactly one operation and is never absent
  // (no "remove" relation exists in the model).
  some AuditEntry
  all ae: AuditEntry | one op: Operation | ae in op.opAuditEntries
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    // The actor recorded in the entry matches the caller of the generating operation.
    (one op: Operation | ae in op.opAuditEntries and ae.auditActor = op.opCaller)
  all ae: AuditEntry |
    // The actor_role snapshot equals the actor's actual role (FR-016 snapshot semantics).
    ae.auditActorRole = ae.auditActor.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task.owner_id immutable
pred OwnershipExclusivity {
  some Task
  // Each task has exactly one owner (enforced by the `one` multiplicity on taskOwner).
  all t: Task | one t.taskOwner
  // The owner is always a member of the task's team.
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-004/FR-005; contracts/http-api.md matrix
pred OwnershipBasedAccess {
  some Operation
  // A member who is neither owner nor sharee nor admin cannot view a task.
  all op: Operation |
    (op.opRel = RelInTeamNone and op.opKind = KViewTask) =>
      op.opOutcome = PODenied
  // An owner can always view their own task.
  all op: Operation |
    (op.opRel = RelOwner and op.opKind = KViewTask) =>
      op.opOutcome = POAllowed
  // A sharee can view but not delete.
  all op: Operation |
    (op.opRel = RelSharee and op.opKind = KDeleteTask) =>
      op.opOutcome = PODenied
  all op: Operation |
    (op.opRel = RelSharee and op.opKind = KViewTask) =>
      op.opOutcome = POAllowed
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some Operation
  // Cross-team callers and in-team-no-rel callers are ALWAYS denied on task-specific ops —
  // there is no distinguishing difference between "task exists in another team" and
  // "task does not exist": both produce PODenied.
  all op: Operation |
    op.opRel = RelOutsider => op.opOutcome = PODenied
  all op: Operation |
    (op.opRel = RelInTeamNone and
     op.opKind in (KViewTask + KEditFields + KChangeSharedWith + KDeleteTask + KViewAudit))
      => op.opOutcome = PODenied
  // A sharee's DELETE attempt is also denied (byte-equivalent 404, FR-014).
  all op: Operation |
    (op.opRel = RelSharee and op.opKind = KDeleteTask) =>
      op.opOutcome = PODenied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ─── Feature-specific predicates ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneTeamOneRolePerUser {
  some User
  all u: User | one u.userTeam and one u.userRole
}
assert FR_002_OneTeamOneRolePerUser { FR_002_OneTeamOneRolePerUser }
check FR_002_OneTeamOneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003/FR-004 — member access governed by ownership+sharing
pred FR_003_MemberAccessBoundedByOwnershipAndSharing {
  some Operation
  all op: Operation |
    (op.opCaller.userRole = MemberRole and op.opKind = KViewTask) =>
      (op.opRel in (RelOwner + RelSharee) <=> op.opOutcome = POAllowed)
}
assert FR_003_MemberAccessBoundedByOwnershipAndSharing {
  FR_003_MemberAccessBoundedByOwnershipAndSharing
}
check FR_003_MemberAccessBoundedByOwnershipAndSharing for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — team admin can view/edit/delete any in-team task
pred FR_005_AdminCanActOnAnyTeamTask {
  some Operation
  all op: Operation |
    (op.opRel = RelTeamAdmin and
     op.opKind in (KViewTask + KEditFields + KDeleteTask))
      => op.opOutcome = POAllowed
}
assert FR_005_AdminCanActOnAnyTeamTask { FR_005_AdminCanActOnAnyTeamTask }
check FR_005_AdminCanActOnAnyTeamTask for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 — cross-team isolation is absolute
pred FR_006_CrossTeamIsolationAbsolute {
  some Operation
  all op: Operation |
    op.opCaller.userTeam != op.opTask.taskTeam => op.opOutcome = PODenied
}
assert FR_006_CrossTeamIsolationAbsolute { FR_006_CrossTeamIsolationAbsolute }
check FR_006_CrossTeamIsolationAbsolute for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 — owner_id and team_id are immutable (structural: one owner per task)
pred FR_009_ImmutableOwnership {
  some Task
  all t: Task | one t.taskOwner and one t.taskTeam
}
assert FR_009_ImmutableOwnership { FR_009_ImmutableOwnership }
check FR_009_ImmutableOwnership for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 / Q1=A — only the task owner may change shared_with
pred FR_010_OwnerOnlyShareControl {
  some op: Operation | op.opKind = KChangeSharedWith
  all op: Operation |
    op.opKind = KChangeSharedWith =>
      (op.opOutcome = POAllowed <=> op.opRel = RelOwner)
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 / Q3=B — sharee may view and edit but not delete
pred FR_011_ShareePermissions {
  some op: Operation | op.opRel = RelSharee
  all op: Operation |
    op.opRel = RelSharee => {
      op.opKind = KViewTask => op.opOutcome = POAllowed
      op.opKind = KEditFields => op.opOutcome = POAllowed
      op.opKind = KDeleteTask => op.opOutcome = PODenied
      op.opKind = KChangeSharedWith => op.opOutcome = PODenied
    }
}
assert FR_011_ShareePermissions { FR_011_ShareePermissions }
check FR_011_ShareePermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 — sharees must be in the same team as the task
pred FR_012_ShareeTeamMembership {
  some Task
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_ShareeTeamMembership { FR_012_ShareeTeamMembership }
check FR_012_ShareeTeamMembership for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 — share/unshare events produce audit entries
pred FR_013_ShareEventAudited {
  some op: Operation | op.opKind = KChangeSharedWith and op.opOutcome = POAllowed
  all op: Operation |
    (op.opKind = KChangeSharedWith and op.opOutcome = POAllowed) =>
      some op.opAuditEntries
}
assert FR_013_ShareEventAudited { FR_013_ShareEventAudited }
check FR_013_ShareEventAudited for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 — byte-equivalent denial for outsider/in-team-no-rel/sharee-delete
pred FR_014_ByteEquivalentDenial {
  some Operation
  all op: Operation |
    (op.opRel = RelOutsider or
     (op.opRel = RelInTeamNone and
      op.opKind in (KViewTask + KEditFields + KChangeSharedWith + KDeleteTask + KViewAudit)) or
     (op.opRel = RelSharee and op.opKind = KDeleteTask))
      => op.opOutcome = PODenied
}
assert FR_014_ByteEquivalentDenial { FR_014_ByteEquivalentDenial }
check FR_014_ByteEquivalentDenial for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — every allowed mutation produces at least one audit entry
pred FR_015_AuditPerEvent {
  some op: Operation |
    op.opOutcome = POAllowed and
    op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask)
  all op: Operation |
    (op.opOutcome = POAllowed and
     op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask))
      => some op.opAuditEntries
}
assert FR_015_AuditPerEvent { FR_015_AuditPerEvent }
check FR_015_AuditPerEvent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — denied operations produce no audit entries
pred FR_015_NoDeniedOpAudit {
  some Operation
  all op: Operation |
    op.opOutcome = PODenied => no op.opAuditEntries
}
assert FR_015_NoDeniedOpAudit { FR_015_NoDeniedOpAudit }
check FR_015_NoDeniedOpAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit entry actor attribution is correct
pred FR_016_AuditAttribution {
  some AuditEntry
  all ae: AuditEntry |
    (one op: Operation | ae in op.opAuditEntries and ae.auditActor = op.opCaller)
}
assert FR_016_AuditAttribution { FR_016_AuditAttribution }
check FR_016_AuditAttribution for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit entries are append-only and outlive the task
pred FR_017_AuditAppendOnly {
  some AuditEntry
  // Every audit entry belongs to exactly one producing operation — no entry
  // is shared between operations (no reuse/mutation) and no entry is orphaned.
  all ae: AuditEntry | one op: Operation | ae in op.opAuditEntries
}
assert FR_017_AuditAppendOnly { FR_017_AuditAppendOnly }
check FR_017_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 — no state change without matching audit entry
pred FR_018_NoStateChangeWithoutAudit {
  some op: Operation |
    op.opOutcome = POAllowed and
    op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask)
  all op: Operation |
    (op.opOutcome = POAllowed and
     op.opKind in (KCreateTask + KEditFields + KChangeSharedWith + KDeleteTask))
      => some op.opAuditEntries
  all op: Operation |
    op.opOutcome = PODenied => no op.opAuditEntries
}
assert FR_018_NoStateChangeWithoutAudit { FR_018_NoStateChangeWithoutAudit }
check FR_018_NoStateChangeWithoutAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 — audit endpoint access follows read-access rules
pred FR_019_AuditAccessMatchesReadAccess {
  some Operation
  all op: Operation |
    op.opKind = KViewAudit => {
      op.opRel in (RelOwner + RelSharee + RelTeamAdmin) <=>
        op.opOutcome = POAllowed
    }
}
assert FR_019_AuditAccessMatchesReadAccess { FR_019_AuditAccessMatchesReadAccess }
check FR_019_AuditAccessMatchesReadAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — team admin cannot change shared_with unless they are the owner
pred FR_005_AdminCannotChangeShareList {
  some op: Operation |
    op.opRel = RelTeamAdmin and op.opKind = KChangeSharedWith
  all op: Operation |
    (op.opRel = RelTeamAdmin and op.opKind = KChangeSharedWith) =>
      op.opOutcome = PODenied
}
assert FR_005_AdminCannotChangeShareList { FR_005_AdminCannotChangeShareList }
check FR_005_AdminCannotChangeShareList for 8

// FEATURE-SPECIFIC  ANCHOR: SC-011 — only owner ever gets POAllowed on KChangeSharedWith
pred SC_011_OnlyOwnerChangesShareList {
  some op: Operation | op.opKind = KChangeSharedWith
  all op: Operation |
    (op.opKind = KChangeSharedWith and op.opOutcome = POAllowed) =>
      op.opRel = RelOwner
}
assert SC_011_OnlyOwnerChangesShareList { SC_011_OnlyOwnerChangesShareList }
check SC_011_OnlyOwnerChangesShareList for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005; contracts/http-api.md — admin ⊇ owner read-side
pred PrivilegeMonotonicity {
  some Operation
  // For every action that an owner is permitted, a team-admin is also permitted
  // (admin supersedes owner on all ops except KChangeSharedWith for non-owned tasks,
  //  which is enforced separately by FR-010).
  all k: OperationKind |
    (RelOwner -> k) in PermMatrix.Allowed and k != KChangeSharedWith =>
      (RelTeamAdmin -> k) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ShareeDeleteViolation { some op: Operation | op.opRel = RelSharee and op.opKind = KDeleteTask and op.opOutcome = POAllowed }
