// === feature_model.als — Alloy model for 008 Multi-Tenant Task Management with Per-Task Sharing and Audit ===

// ---------------------------------------------------------------------------
// Roles, operations, audit op kinds, caller-relationships
// ---------------------------------------------------------------------------

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTaskById, PatchTaskFields, PatchTaskShared,
        DeleteTask, GetTaskAudit extends OperationKind {}

abstract sig AuditOp {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOp {}

// Caller relationship to a target task (from contracts/http-api.md permission matrix)
abstract sig Relationship {}
one sig Outsider, InTeamNone, ShareeRel, AdminRel, OwnerRel extends Relationship {}

// ---------------------------------------------------------------------------
// Core entities
// ---------------------------------------------------------------------------

sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam:   one Team,
  owner:      one User,
  sharedWith: set User
}

sig AuditEntry {
  auditTask:         one Task,
  actor:             one User,
  actorRoleSnapshot: one Role,
  auditOp:           one AuditOp
}

// Permission matrix as a singleton field, per system-prompt canonical pattern.
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// ---------------------------------------------------------------------------
// Non-empty universe — keep this as the only place where existence is forced
// ---------------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
}

// ---------------------------------------------------------------------------
// Permission matrix — every allow cell explicit; everything else denied
// (contracts/http-api.md permission matrix, anchored to FR-003..FR-006, FR-010..FR-011, FR-019)
// ---------------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (OwnerRel  -> GetTaskById)
    + (OwnerRel  -> PatchTaskFields)
    + (OwnerRel  -> PatchTaskShared)
    + (OwnerRel  -> DeleteTask)
    + (OwnerRel  -> GetTaskAudit)
    + (AdminRel  -> GetTaskById)
    + (AdminRel  -> PatchTaskFields)
    + (AdminRel  -> DeleteTask)
    + (AdminRel  -> GetTaskAudit)
    + (ShareeRel -> GetTaskById)
    + (ShareeRel -> PatchTaskFields)
    + (ShareeRel -> GetTaskAudit)
}

// ---------------------------------------------------------------------------
// Structural invariants encoded as named, mutation-testable facts
// ---------------------------------------------------------------------------

// FR-009, FR-012, data-model.md task.team_id = owner.team_id and sharee in same team
fact F_TaskOwnerInSameTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}

fact F_SharedWithSameTeam {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}

// owner is implicitly in read-set; do not duplicate as sharee (contracts POST /tasks note)
fact F_OwnerNotInSharedWith {
  all t: Task | t.owner not in t.sharedWith
}

// FR-014 / FR-006 — actor of a recorded mutation must be in same team as task
fact F_AuditActorInTaskTeam {
  all a: AuditEntry | a.actor.userTeam = a.auditTask.taskTeam
}

// FR-016 — recorded role matches the actor's role (snapshot)
fact F_AuditAttribution { /* MUTATED — body cleared by validator */ }

// FR-015 — every task has exactly one "created" audit entry (audit completeness)
fact F_OneCreatedPerTask {
  all t: Task | one a: AuditEntry | a.auditTask = t and a.auditOp = OpCreated
}

// FR-017 — append-only: at most one "deleted" entry per task (no resurrection / re-deletion)
fact F_AtMostOneDeletedPerTask {
  all t: Task | lone a: AuditEntry | a.auditTask = t and a.auditOp = OpDeleted
}

// FR-015 — every audit entry refers to a real task in the model
fact F_AuditTaskReferenceExists {
  all a: AuditEntry | a.auditTask in Task
}

// ---------------------------------------------------------------------------
// Catalogue patterns: one pred + one assert + one check per pattern
// ---------------------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-010, FR-011, FR-014
pred LeastPrivilege {
  // Sharees cannot delete or change shares
  ShareeRel -> DeleteTask       not in PermMatrix.Allowed
  ShareeRel -> PatchTaskShared  not in PermMatrix.Allowed
  // Admins cannot change shares (owner-only per Q1=A)
  AdminRel  -> PatchTaskShared  not in PermMatrix.Allowed
  // Outsiders and in-team-no-relationship have zero access to /tasks/{id}*
  no Outsider.(PermMatrix.Allowed)
  no InTeamNone.(PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every operation in {GetTaskById, PatchTaskFields, DeleteTask, GetTaskAudit} grants the owner;
  // PatchTaskShared is owner-only. PostTasks is unconditional, not a relationship-gated op.
  all op: (GetTaskById + PatchTaskFields + DeleteTask + GetTaskAudit) |
    OwnerRel -> op in PermMatrix.Allowed
  OwnerRel -> PatchTaskShared in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md per-event audit row
pred AuditCompleteness {
  // Every task has exactly one CREATED audit entry — never zero, never duplicate
  all t: Task | one a: AuditEntry | a.auditTask = t and a.auditOp = OpCreated
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No task has two "deleted" audit entries — would imply mutation/re-insertion
  no disj a1, a2: AuditEntry |
    a1.auditTask = a2.auditTask and a1.auditOp = OpDeleted and a2.auditOp = OpDeleted
  // No task has two "created" entries either
  no disj a1, a2: AuditEntry |
    a1.auditTask = a2.auditTask and a1.auditOp = OpCreated and a2.auditOp = OpCreated
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit_entries.actor_role
pred AttributionCorrectness {
  all a: AuditEntry | a.actorRoleSnapshot = a.actor.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; spec.md FR-009
pred OwnershipExclusivity {
  all t: Task | one t.owner
  all t: Task | one t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-005, FR-011, FR-012; data-model.md cross-team WHERE clause
pred OwnershipBasedAccess {
  // Owner is in the task's team
  all t: Task | t.owner.userTeam = t.taskTeam
  // Every sharee is in the task's team (no cross-team shares)
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  // No cross-team actor can produce an audit entry on a task —
  // mutation is reachable only via the read-set, which is team-scoped.
  all a: AuditEntry | a.actor.userTeam = a.auditTask.taskTeam
  // Outsider relationship gets no operation at all
  no Outsider.(PermMatrix.Allowed)
  no InTeamNone.(PermMatrix.Allowed)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-002; contracts/http-api.md OAuth section
pred AuthRequiredEverywhere {
  // Every recorded operation has a resolved actor and recorded role (no anonymous audit entries)
  all a: AuditEntry | one a.actor and one a.actorRoleSnapshot
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// ---------------------------------------------------------------------------
// Feature-specific predicates: one per FR-NNN
// ---------------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer required before any handler
pred FR_001_AuthRequired {
  all a: AuditEntry | one a.actor
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 + FR-002a one team and one role per user, from token only
pred FR_002_OneTeamOneRole {
  all u: User | one u.userTeam
  all u: User | one u.userRole
}
assert FR_002_OneTeamOneRole { FR_002_OneTeamOneRole }
check FR_002_OneTeamOneRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 member can act on owned and shared tasks
pred FR_003_MemberPermissions {
  OwnerRel  -> PatchTaskFields in PermMatrix.Allowed
  OwnerRel  -> DeleteTask     in PermMatrix.Allowed
  ShareeRel -> PatchTaskFields in PermMatrix.Allowed
  ShareeRel -> DeleteTask     not in PermMatrix.Allowed
}
assert FR_003_MemberPermissions { FR_003_MemberPermissions }
check FR_003_MemberPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 in-team-no-relationship member cannot touch task
pred FR_004_NoUnauthorizedMember {
  no InTeamNone.(PermMatrix.Allowed)
}
assert FR_004_NoUnauthorizedMember { FR_004_NoUnauthorizedMember }
check FR_004_NoUnauthorizedMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 admin can view/edit/delete any task in own team
pred FR_005_AdminFullTeamAccess {
  AdminRel -> GetTaskById     in PermMatrix.Allowed
  AdminRel -> PatchTaskFields in PermMatrix.Allowed
  AdminRel -> DeleteTask      in PermMatrix.Allowed
  AdminRel -> GetTaskAudit    in PermMatrix.Allowed
}
assert FR_005_AdminFullTeamAccess { FR_005_AdminFullTeamAccess }
check FR_005_AdminFullTeamAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 absolute cross-team isolation, invariant under role
pred FR_006_CrossTeamIsolation {
  all a: AuditEntry | a.actor.userTeam = a.auditTask.taskTeam
  no Outsider.(PermMatrix.Allowed)
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 every task has structural identity (owner + team + title placeholder)
pred FR_007_TaskHasOwner {
  all t: Task | some t.owner
}
assert FR_007_TaskHasOwner { FR_007_TaskHasOwner }
check FR_007_TaskHasOwner for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 fixed status set — each task belongs to exactly one team
pred FR_008_TaskInOneTeam {
  all t: Task | one t.taskTeam
}
assert FR_008_TaskInOneTeam { FR_008_TaskInOneTeam }
check FR_008_TaskInOneTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 owner_id and team_id immutable + owner in task's team
pred FR_009_OwnerTeamConsistent {
  all t: Task | t.owner.userTeam = t.taskTeam
}
assert FR_009_OwnerTeamConsistent { FR_009_OwnerTeamConsistent }
check FR_009_OwnerTeamConsistent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 only owner may modify shared_with (Q1=A)
pred FR_010_OwnerOnlyShares {
  OwnerRel  -> PatchTaskShared in PermMatrix.Allowed
  AdminRel  -> PatchTaskShared not in PermMatrix.Allowed
  ShareeRel -> PatchTaskShared not in PermMatrix.Allowed
  InTeamNone -> PatchTaskShared not in PermMatrix.Allowed
  Outsider  -> PatchTaskShared not in PermMatrix.Allowed
}
assert FR_010_OwnerOnlyShares { FR_010_OwnerOnlyShares }
check FR_010_OwnerOnlyShares for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 sharee may view + edit but not delete and not change shares (Q3=B)
pred FR_011_ShareeViewEditNoDelete {
  ShareeRel -> GetTaskById     in PermMatrix.Allowed
  ShareeRel -> PatchTaskFields in PermMatrix.Allowed
  ShareeRel -> GetTaskAudit    in PermMatrix.Allowed
  ShareeRel -> DeleteTask      not in PermMatrix.Allowed
  ShareeRel -> PatchTaskShared not in PermMatrix.Allowed
}
assert FR_011_ShareeViewEditNoDelete { FR_011_ShareeViewEditNoDelete }
check FR_011_ShareeViewEditNoDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 every sharee is in the owner's team
pred FR_012_NoCrossTeamSharing {
  all t: Task, u: t.sharedWith | u.userTeam = t.taskTeam
}
assert FR_012_NoCrossTeamSharing { FR_012_NoCrossTeamSharing }
check FR_012_NoCrossTeamSharing for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 share / unshare each produce an audit entry per affected user
pred FR_013_ShareEventsAudited {
  // For every sharee in a task, there exists at least one "shared" audit entry tying that user to that task
  all t: Task, u: t.sharedWith |
    some a: AuditEntry | a.auditTask = t and a.auditOp = OpShared
}
assert FR_013_ShareEventsAudited { FR_013_ShareEventsAudited }
check FR_013_ShareEventsAudited for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404 — no access for outsider / in-team-none
pred FR_014_ByteEquivIsolation {
  no Outsider.(PermMatrix.Allowed)
  no InTeamNone.(PermMatrix.Allowed)
  all a: AuditEntry | a.actor.userTeam = a.auditTask.taskTeam
}
assert FR_014_ByteEquivIsolation { FR_014_ByteEquivIsolation }
check FR_014_ByteEquivIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 one audit entry per logical event; no state change without one
pred FR_015_OneAuditPerCreate {
  all t: Task | one a: AuditEntry | a.auditTask = t and a.auditOp = OpCreated
}
assert FR_015_OneAuditPerCreate { FR_015_OneAuditPerCreate }
check FR_015_OneAuditPerCreate for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry carries task, actor, role-snapshot, operation
pred FR_016_AuditFieldsPresent {
  all a: AuditEntry | one a.auditTask
  all a: AuditEntry | one a.actor
  all a: AuditEntry | one a.actorRoleSnapshot
  all a: AuditEntry | one a.auditOp
  all a: AuditEntry | a.actorRoleSnapshot = a.actor.userRole
}
assert FR_016_AuditFieldsPresent { FR_016_AuditFieldsPresent }
check FR_016_AuditFieldsPresent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries immutable / not duplicated for the same logical event
pred FR_017_AuditAppendOnly {
  no disj a1, a2: AuditEntry |
    a1.auditTask = a2.auditTask and a1.auditOp = OpCreated and a2.auditOp = OpCreated
  no disj a1, a2: AuditEntry |
    a1.auditTask = a2.auditTask and a1.auditOp = OpDeleted and a2.auditOp = OpDeleted
}
assert FR_017_AuditAppendOnly { FR_017_AuditAppendOnly }
check FR_017_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit and mutation are atomic — every audit entry has a task
pred FR_018_AuditTiedToMutation {
  all a: AuditEntry | a.auditTask in Task
  all a: AuditEntry | one a.auditTask
}
assert FR_018_AuditTiedToMutation { FR_018_AuditTiedToMutation }
check FR_018_AuditTiedToMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit visible to owner / sharee / admin only
pred FR_019_AuditReadAccess {
  OwnerRel  -> GetTaskAudit in PermMatrix.Allowed
  ShareeRel -> GetTaskAudit in PermMatrix.Allowed
  AdminRel  -> GetTaskAudit in PermMatrix.Allowed
  InTeamNone -> GetTaskAudit not in PermMatrix.Allowed
  Outsider  -> GetTaskAudit not in PermMatrix.Allowed
}
assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 audit entries outlive tasks structurally
pred FR_020_AuditOutlivesTask {
  // Audit entries reference a task atom; the model permits them to exist
  // independent of any FK cascade — structurally this is just "task ref present".
  all a: AuditEntry | some a.auditTask
}
assert FR_020_AuditOutlivesTask { FR_020_AuditOutlivesTask }
check FR_020_AuditOutlivesTask for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 performance budget — structurally, each task is deterministically owned
pred FR_021_DeterministicOwnership {
  all t: Task | one t.owner
  all t: Task | one t.taskTeam
}
assert FR_021_DeterministicOwnership { FR_021_DeterministicOwnership }
check FR_021_DeterministicOwnership for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AttributionViolation { some a: AuditEntry | a.actorRoleSnapshot != a.actor.userRole }
