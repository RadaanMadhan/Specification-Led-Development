// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-Tenant Task Management with Per-Task Sharing and Audit
// Feature branch: B-L3 / 008-task-sharing
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─── Roles ────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Member    extends Role {}
one sig TeamAdmin extends Role {}

// ─── Teams ────────────────────────────────────────────────────────────────────
sig Team {}

// ─── Users ────────────────────────────────────────────────────────────────────
sig User {
  userTeam : one Team,
  userRole : one Role
}

// ─── Tasks ────────────────────────────────────────────────────────────────────
sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  sharedWith: set User
}

// ─── Audit operations (one value per logical event; FR-015, FR-016) ───────────
abstract sig AuditOperation {}
one sig Created  extends AuditOperation {}
one sig Edited   extends AuditOperation {}
one sig Deleted  extends AuditOperation {}
one sig Shared   extends AuditOperation {}
one sig Unshared extends AuditOperation {}

// ─── Audit entries (append-only; FR-017) ──────────────────────────────────────
sig AuditEntry {
  auditTask : one Task,
  auditTeam : one Team,       // denormalized from task at write time (data-model.md)
  auditActor: one User,
  auditRole : one Role,       // snapshotted at write time (FR-016)
  auditOp   : one AuditOperation
}

// ─── Caller–task relationships (computed, not persisted; data-model.md) ───────
abstract sig Relationship {}
one sig Outsider     extends Relationship {}  // cross-team caller
one sig InTeamNone   extends Relationship {}  // in-team, not owner/sharee/admin
one sig ShareeRel    extends Relationship {}
one sig TeamAdminRel extends Relationship {}
one sig OwnerRel     extends Relationship {}

// ─── API operation kinds ───────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig OpPostTasks         extends OperationKind {}
one sig OpGetTask           extends OperationKind {}
one sig OpPatchFields       extends OperationKind {}  // PATCH without shared_with
one sig OpPatchShareList    extends OperationKind {}  // PATCH including shared_with
one sig OpDeleteTask        extends OperationKind {}
one sig OpGetAudit          extends OperationKind {}
one sig OpDeleteAuditEntry  extends OperationKind {}  // must remain universally forbidden
one sig OpUpdateAuditEntry  extends OperationKind {}  // must remain universally forbidden

// ─── Permission matrix: Relationship × OperationKind ─────────────────────────
// (contracts/http-api.md permission table; FR-003/FR-005/FR-010/FR-011)
one sig RelPermMatrix {
  relAllowed: set Relationship -> OperationKind
}

// ─── Role-level permission matrix for context-free operations ─────────────────
// (PostTasks is role-level; it does not depend on a pre-existing task)
one sig RolePermMatrix {
  roleAllowed: set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — guarantees at least one atom of every dynamic sig so
// that universally-quantified assertions are non-vacuous under `for 5`.
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OwnerInSameTeam
// spec.md FR-009, data-model.md Task.team_id FK
// The task owner must belong to the task's team; owner_id is set to the
// creator whose team is the task's team.
// ─────────────────────────────────────────────────────────────────────────────
fact F_OwnerInSameTeam {
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ShareeInSameTeam
// spec.md FR-012; every sharee must be in the same team as the task owner.
// Cross-team sharing is forbidden in v1.
// ─────────────────────────────────────────────────────────────────────────────
fact F_ShareeInSameTeam {
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OwnerNotSharee
// spec.md FR-010; the owner is implicitly in the read-set; they must not
// also appear as a sharee (contracts/http-api.md POST /tasks body note).
// ─────────────────────────────────────────────────────────────────────────────
fact F_OwnerNotSharee {
  all t: Task | t.taskOwner not in t.sharedWith
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditTeamDenormalized
// data-model.md AuditEntry.team_id — denormalized from task at write time so
// cross-team isolation on the audit endpoint works without joining a deleted task.
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditTeamDenormalized {
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditActorInSameTeam
// spec.md FR-006, FR-002; the actor recorded in an audit entry must belong to
// the same team as the task being audited.
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditActorInSameTeam {
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditRoleSnapshot
// spec.md FR-016; the actor_role is snapshotted from the caller at the
// time of the mutation. In this static model we assert that the snapshotted
// role is the actor's actual role (no misattribution in a single-snapshot
// world; the property becomes non-trivial when we enforce it structurally).
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditRoleSnapshot {
  all ae: AuditEntry | ae.auditRole = ae.auditActor.userRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditExistsForEveryMutation
// spec.md FR-015; every task has at least one audit entry (Created), and every
// delete operation on a task is recorded. We encode this as: each task has at
// least one AuditEntry with auditOp = Created, and if any AuditEntry for a
// task carries auditOp = Deleted the task's audit entries include a Created one.
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditExistsForEveryMutation {
  // Every task has at least one Created audit entry (POST /tasks always writes one)
  all t: Task | some ae: AuditEntry | ae.auditTask = t and ae.auditOp = Created
  // Every deleted task has a Deleted audit entry authored by an authorised actor
  // (owner or team_admin can delete; FR-005)
  all ae: AuditEntry |
    ae.auditOp = Deleted implies
      (ae.auditActor = ae.auditTask.taskOwner or ae.auditActor.userRole = TeamAdmin)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ShareAuditEntries
// spec.md FR-013; every share/unshare event must have an audit entry authored
// by the task owner (only the owner can change shared_with; FR-010).
// ─────────────────────────────────────────────────────────────────────────────
fact F_ShareAuditEntries {
  all ae: AuditEntry |
    (ae.auditOp = Shared or ae.auditOp = Unshared) implies
      ae.auditActor = ae.auditTask.taskOwner
}

// ─────────────────────────────────────────────────────────────────────────────
// F_RelPermissionMatrix
// contracts/http-api.md permission table; spec.md FR-003/FR-005/FR-010/FR-011.
// The matrix assigns relationship-level access to each OperationKind.
// ─────────────────────────────────────────────────────────────────────────────
fact F_RelPermissionMatrix {
  // OwnerRel: full access except the two forbidden audit-mutation ops
  OwnerRel     -> OpGetTask        in RelPermMatrix.relAllowed
  OwnerRel     -> OpPatchFields    in RelPermMatrix.relAllowed
  OwnerRel     -> OpPatchShareList in RelPermMatrix.relAllowed
  OwnerRel     -> OpDeleteTask     in RelPermMatrix.relAllowed
  OwnerRel     -> OpGetAudit       in RelPermMatrix.relAllowed

  // ShareeRel: view/edit fields/audit; NOT delete, NOT change share list (FR-011, Q3=B)
  ShareeRel    -> OpGetTask        in RelPermMatrix.relAllowed
  ShareeRel    -> OpPatchFields    in RelPermMatrix.relAllowed
  ShareeRel    -> OpGetAudit       in RelPermMatrix.relAllowed

  // TeamAdminRel: full task access except share-list control (FR-005, Q1=A)
  TeamAdminRel -> OpGetTask        in RelPermMatrix.relAllowed
  TeamAdminRel -> OpPatchFields    in RelPermMatrix.relAllowed
  TeamAdminRel -> OpDeleteTask     in RelPermMatrix.relAllowed
  TeamAdminRel -> OpGetAudit       in RelPermMatrix.relAllowed

  // InTeamNone and Outsider: no access (byte-equivalent 404; FR-004, FR-006, FR-014)
  // (no entries for InTeamNone or Outsider)

  // Closed-world: exactly these cells are allowed
  RelPermMatrix.relAllowed =
    (OwnerRel     -> OpGetTask)        +
    (OwnerRel     -> OpPatchFields)    +
    (OwnerRel     -> OpPatchShareList) +
    (OwnerRel     -> OpDeleteTask)     +
    (OwnerRel     -> OpGetAudit)       +
    (ShareeRel    -> OpGetTask)        +
    (ShareeRel    -> OpPatchFields)    +
    (ShareeRel    -> OpGetAudit)       +
    (TeamAdminRel -> OpGetTask)        +
    (TeamAdminRel -> OpPatchFields)    +
    (TeamAdminRel -> OpDeleteTask)     +
    (TeamAdminRel -> OpGetAudit)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_RolePermissionMatrix
// contracts/http-api.md; POST /tasks is role-level (not task-specific).
// Both Member and TeamAdmin may create tasks.
// OpDeleteAuditEntry and OpUpdateAuditEntry are universally forbidden (FR-017).
// ─────────────────────────────────────────────────────────────────────────────
fact F_RolePermissionMatrix { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// Helper: compute the relationship of a user to a task
// ─────────────────────────────────────────────────────────────────────────────
fun relationship[u: User, t: Task]: one Relationship {
  (u.userTeam != t.taskTeam)         => Outsider     else
  (u = t.taskOwner)                  => OwnerRel     else
  (u in t.sharedWith)                => ShareeRel    else
  (u.userRole = TeamAdmin)           => TeamAdminRel else
                                        InTeamNone
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: can a user perform an operation on a task?
// ─────────────────────────────────────────────────────────────────────────────
pred canPerform[u: User, t: Task, op: OperationKind] {
  relationship[u, t] -> op in RelPermMatrix.relAllowed
}

// ═════════════════════════════════════════════════════════════════════════════
// PATTERN PREDICATES
// ═════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-003/FR-004/FR-005/FR-006
pred LeastPrivilege {
  some Task
  // InTeamNone callers have no access to any task operation
  no op: OperationKind | InTeamNone -> op in RelPermMatrix.relAllowed
  // Outsider callers have no access to any task operation
  no op: OperationKind | Outsider -> op in RelPermMatrix.relAllowed
  // Sharees cannot delete tasks (Q3 = B)
  ShareeRel -> OpDeleteTask not in RelPermMatrix.relAllowed
  // Sharees cannot modify the share list (FR-010)
  ShareeRel -> OpPatchShareList not in RelPermMatrix.relAllowed
  // TeamAdmins cannot modify the share list of tasks they don't own (Q1 = A)
  TeamAdminRel -> OpPatchShareList not in RelPermMatrix.relAllowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table; spec.md FR-003/FR-005
pred PermissionCompleteness {
  some Task
  // Every Relationship has a defined verdict for every task OperationKind.
  // Denied is encoded as absence; presence of a cell means allowed.
  // Completeness: the matrix covers all cells (none are undefined / undecided).
  // We assert that the matrix is exactly the closed-world set — no extra cells sneak in.
  RelPermMatrix.relAllowed =
    (OwnerRel     -> OpGetTask)        +
    (OwnerRel     -> OpPatchFields)    +
    (OwnerRel     -> OpPatchShareList) +
    (OwnerRel     -> OpDeleteTask)     +
    (OwnerRel     -> OpGetAudit)       +
    (ShareeRel    -> OpGetTask)        +
    (ShareeRel    -> OpPatchFields)    +
    (ShareeRel    -> OpGetAudit)       +
    (TeamAdminRel -> OpGetTask)        +
    (TeamAdminRel -> OpPatchFields)    +
    (TeamAdminRel -> OpDeleteTask)     +
    (TeamAdminRel -> OpGetAudit)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md "no UPDATE/DELETE on audit_entries"; contracts/ "no PATCH/PUT/DELETE" on audit
pred AppendOnly {
  some AuditEntry
  // No relationship has permission to delete or update audit entries
  no rel: Relationship | rel -> OpDeleteAuditEntry in RelPermMatrix.relAllowed
  no rel: Relationship | rel -> OpUpdateAuditEntry in RelPermMatrix.relAllowed
  // No role has permission to delete or update audit entries
  no r: Role | r -> OpDeleteAuditEntry in RolePermMatrix.roleAllowed
  no r: Role | r -> OpUpdateAuditEntry in RolePermMatrix.roleAllowed
}

assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md UNIQUE constraints on audit_entries
pred AuditCompleteness {
  some AuditEntry
  // Every task has at least one audit entry (the Created entry from POST /tasks)
  all t: Task | some ae: AuditEntry | ae.auditTask = t and ae.auditOp = Created
  // Every audit entry is associated with a task in the same team
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
  // Every actor in an audit entry belongs to the same team as the task
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  // The snapshotted role in every audit entry matches the actual role of the actor
  all ae: AuditEntry | ae.auditRole = ae.auditActor.userRole
  // The actor in every audit entry belongs to the task's team
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTask.taskTeam
  // Share/Unshare entries are only authored by the task owner
  all ae: AuditEntry |
    (ae.auditOp = Shared or ae.auditOp = Unshared) implies
      ae.auditActor = ae.auditTask.taskOwner
  // Deleted entries are only authored by the owner or a team admin
  all ae: AuditEntry |
    ae.auditOp = Deleted implies
      (ae.auditActor = ae.auditTask.taskOwner or ae.auditActor.userRole = TeamAdmin)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner_id FK; spec.md FR-009
pred OwnershipExclusivity {
  some Task
  // Every task has exactly one owner (enforced by `one` multiplicity on taskOwner)
  all t: Task | one t.taskOwner
  // No task is without a team
  all t: Task | one t.taskTeam
  // Owner belongs to the task's team
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-004/FR-010/FR-011; data-model.md Relationship computation
pred OwnershipBasedAccess {
  some Task
  // An in-team user's access follows from the documented chain: caller → relationship → task
  // Owner can always get/patch/delete their own task
  all t: Task | canPerform[t.taskOwner, t, OpGetTask]
  all t: Task | canPerform[t.taskOwner, t, OpDeleteTask]
  all t: Task | canPerform[t.taskOwner, t, OpPatchShareList]
  // Sharees can view but not delete (Q3 = B)
  all t: Task, s: t.sharedWith |
    canPerform[s, t, OpGetTask] and not canPerform[s, t, OpDeleteTask]
  // Sharees cannot change the share list (FR-010)
  all t: Task, s: t.sharedWith |
    not canPerform[s, t, OpPatchShareList]
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some Task
  // Callers outside the task's team receive no access (byte-equivalent 404)
  all t: Task, u: User |
    u.userTeam != t.taskTeam implies
      not canPerform[u, t, OpGetTask]
  // In-team callers with no relationship receive no access (byte-equivalent 404)
  all t: Task, u: User |
    (u.userTeam = t.taskTeam and
     u != t.taskOwner and
     u not in t.sharedWith and
     u.userRole = Member) implies
      not canPerform[u, t, OpGetTask]
  // Sharees attempting DELETE get byte-equivalent 404 (FR-011)
  all t: Task, s: t.sharedWith |
    not canPerform[s, t, OpDeleteTask]
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001; contracts/http-api.md 401 before handler
pred ValidationBeforeMutation {
  some Task
  // Auth required: every audit entry has a valid actor (not an anonymous user).
  // In our model, every User is authenticated (anonymous callers can't create entries).
  // We assert that every AuditEntry's actor is in the system (not a ghost user).
  all ae: AuditEntry | ae.auditActor in User
  // Only tasks in the actor's team generate audit entries
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ═════════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES
// ═════════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every operation requires authentication. No anonymous callers reach business logic.
// Modeled as: every AuditEntry (a side-effect of a mutation) has a non-null actor in User.
pred FR_001_AuthRequired {
  some AuditEntry
  all ae: AuditEntry | one ae.auditActor
  all ae: AuditEntry | ae.auditActor in User
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a
// team_id and role are taken from the OAuth token's claims, never from the
// request payload. In the model: AuditEntry.auditRole is the actor's actual
// role (from userRole), not some externally supplied value.
pred FR_002_RoleFromToken {
  some AuditEntry
  all ae: AuditEntry | ae.auditRole = ae.auditActor.userRole
  // Each user belongs to exactly one team (one-team-per-user invariant)
  all u: User | one u.userTeam
}

assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003/FR-004
// Members can only access tasks they own or are sharees on within their team.
// They have no access to tasks of other in-team users they are not shared with.
pred FR_003_MemberVisibilityBoundary {
  some Task
  all t: Task, u: User |
    (u.userRole = Member and
     u.userTeam = t.taskTeam and
     u != t.taskOwner and
     u not in t.sharedWith) implies
      not canPerform[u, t, OpGetTask]
}

assert FR_003_MemberVisibilityBoundary { FR_003_MemberVisibilityBoundary }
check FR_003_MemberVisibilityBoundary for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
// Team admins can view, edit, and delete any task in their own team.
pred FR_005_TeamAdminInTeamAccess {
  some Task
  // Any TeamAdmin can get and delete any task in their own team
  all t: Task, u: User |
    (u.userRole = TeamAdmin and u.userTeam = t.taskTeam) implies
      (canPerform[u, t, OpGetTask] and canPerform[u, t, OpDeleteTask])
}

assert FR_005_TeamAdminInTeamAccess { FR_005_TeamAdminInTeamAccess }
check FR_005_TeamAdminInTeamAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
// Cross-team isolation is absolute: no user can access tasks in a different team.
pred FR_006_CrossTeamIsolation {
  some Task
  all t: Task, u: User |
    u.userTeam != t.taskTeam implies
      (not canPerform[u, t, OpGetTask]     and
       not canPerform[u, t, OpPatchFields] and
       not canPerform[u, t, OpDeleteTask]  and
       not canPerform[u, t, OpGetAudit])
}

assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
// owner_id and team_id are immutable. Modeled as: no audit entry records
// a change to these fields; they are set at creation and never altered.
// In the static model: every task's owner is always in the task's team.
pred FR_009_ImmutableOwnerAndTeam {
  some Task
  // The structural invariant: team and owner are fixed at creation
  all t: Task | t.taskOwner.userTeam = t.taskTeam
  // Owner is always a single, defined user
  all t: Task | one t.taskOwner
  all t: Task | one t.taskTeam
}

assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; Q1=A
// Only the task owner may modify the shared_with list.
// No other relationship — including TeamAdmin — has this permission.
pred FR_010_OwnerOnlyShareControl {
  some Task
  // Only OwnerRel can invoke OpPatchShareList
  OwnerRel -> OpPatchShareList in RelPermMatrix.relAllowed
  ShareeRel -> OpPatchShareList not in RelPermMatrix.relAllowed
  TeamAdminRel -> OpPatchShareList not in RelPermMatrix.relAllowed
  InTeamNone -> OpPatchShareList not in RelPermMatrix.relAllowed
  Outsider -> OpPatchShareList not in RelPermMatrix.relAllowed
}

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011; Q3=B
// A sharee may view and edit the task but may NOT delete it and may NOT
// modify the share list. Sharee DELETE returns byte-equivalent 404.
pred FR_011_ShareePermissions {
  some Task
  // Sharee has view and edit-fields access
  ShareeRel -> OpGetTask     in RelPermMatrix.relAllowed
  ShareeRel -> OpPatchFields in RelPermMatrix.relAllowed
  ShareeRel -> OpGetAudit    in RelPermMatrix.relAllowed
  // Sharee does NOT have delete or share-list access
  ShareeRel -> OpDeleteTask     not in RelPermMatrix.relAllowed
  ShareeRel -> OpPatchShareList not in RelPermMatrix.relAllowed
}

assert FR_011_ShareePermissions { FR_011_ShareePermissions }
check FR_011_ShareePermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012
// Every sharee in a task's shared_with list must be a member of the same team.
// Cross-team sharing is forbidden in v1.
pred FR_012_CrossTeamSharingForbidden {
  some Task
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
}

assert FR_012_CrossTeamSharingForbidden { FR_012_CrossTeamSharingForbidden }
check FR_012_CrossTeamSharingForbidden for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
// Every share/unshare change produces an audit entry authored by the task owner.
pred FR_013_ShareAuditEntries {
  some AuditEntry
  all ae: AuditEntry |
    (ae.auditOp = Shared or ae.auditOp = Unshared) implies
      ae.auditActor = ae.auditTask.taskOwner
}

assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; SC-007
// Every task has at least one audit entry. No successful state change exists
// without a corresponding audit entry.
pred FR_015_MutationAuditCompleteness {
  some AuditEntry
  all t: Task | some ae: AuditEntry | ae.auditTask = t and ae.auditOp = Created
}

assert FR_015_MutationAuditCompleteness { FR_015_MutationAuditCompleteness }
check FR_015_MutationAuditCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; Q2=A
// Each audit entry records the actor's role as snapshotted at mutation time.
// The actor must belong to the task's team.
pred FR_016_AuditEntryFields {
  some AuditEntry
  all ae: AuditEntry | ae.auditRole = ae.auditActor.userRole
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
  all ae: AuditEntry | ae.auditActor.userTeam = ae.auditTeam
}

assert FR_016_AuditEntryFields { FR_016_AuditEntryFields }
check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017; SC-009
// Audit entries are immutable. No role or relationship has permission to
// delete or update an existing audit entry. This is the primary AppendOnly
// enforcement point.
pred FR_017_AuditImmutable {
  some AuditEntry
  // No relationship may delete or update audit entries
  no rel: Relationship | rel -> OpDeleteAuditEntry in RelPermMatrix.relAllowed
  no rel: Relationship | rel -> OpUpdateAuditEntry in RelPermMatrix.relAllowed
  // No role may delete or update audit entries
  no r: Role | r -> OpDeleteAuditEntry in RolePermMatrix.roleAllowed
  no r: Role | r -> OpUpdateAuditEntry in RolePermMatrix.roleAllowed
}

assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019
// Audit entries are readable only by users with read access to the task
// (owner, active sharee, or team admin of the task's team).
pred FR_019_AuditVisibility {
  some AuditEntry
  // Callers with OpGetAudit access are exactly: owner, sharee, team-admin
  all t: Task, u: User |
    canPerform[u, t, OpGetAudit] implies
      (u = t.taskOwner or
       u in t.sharedWith or
       (u.userRole = TeamAdmin and u.userTeam = t.taskTeam))
  // Cross-team callers cannot read audit
  all t: Task, u: User |
    u.userTeam != t.taskTeam implies not canPerform[u, t, OpGetAudit]
}

assert FR_019_AuditVisibility { FR_019_AuditVisibility }
check FR_019_AuditVisibility for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditMutationViolation { TeamAdmin -> OpDeleteAuditEntry in RolePermMatrix.roleAllowed  TeamAdmin -> OpUpdateAuditEntry in RolePermMatrix.roleAllowed }
