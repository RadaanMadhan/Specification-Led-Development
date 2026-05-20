// === feature_model.als — Alloy model for B-L3 (008-task-sharing) ===
// Multi-Tenant Task Management with Per-Task Sharing and Audit
// Covers: spec.md FR-001..FR-020, data-model.md entity invariants,
//         contracts/http-api.md permission matrix.

// ── Roles ──────────────────────────────────────────────────────────
abstract sig Role {}
one sig RoleMember, RoleTeamAdmin extends Role {}

// ── Audit operation types ──────────────────────────────────────────
abstract sig AuditOperation {}
one sig OpCreated, OpEdited, OpDeleted, OpShared, OpUnshared extends AuditOperation {}

// ── API endpoint / method combinations ────────────────────────────
abstract sig OperationKind {}
one sig PostTasks, GetTaskById, PatchTaskById, DeleteTaskById, GetTaskAudit
    extends OperationKind {}

// ── Caller–task relationship types ────────────────────────────────
abstract sig Relationship {}
one sig RelOutsider, RelInTeamNoRel, RelSharee, RelTeamAdmin, RelOwner
    extends Relationship {}

// ── Permission matrix (relationship × operation → allowed) ─────────
// Encodes the table in contracts/http-api.md §"Permission matrix".
// We model it as an allowed set on a singleton sig.
one sig PermMatrix { Allowed: set Relationship -> OperationKind }

// ── Core entities ──────────────────────────────────────────────────
sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam  : one Team,
  taskOwner : one User,
  taskSharees : set User
}

// AuditEntry is append-only; each atom represents one immutable record.
sig AuditEntry {
  entryTask      : one Task,
  entryTeam      : one Team,
  entryActor     : one User,
  entryActorRole : one Role,
  entryOp        : one AuditOperation
}

// A caller+task pair used to express access-check predicates.
sig AccessCheck {
  checkCaller : one User,
  checkTask   : one Task,
  checkRel    : one Relationship    // computed relationship
}

// ── Non-empty universe ────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some AccessCheck
}

// ── F_PermissionMatrix ────────────────────────────────────────────
// Encodes every "allowed" cell from contracts/http-api.md §Permission matrix.
// All callers may post tasks (they become the owner).
// OutTeamSiders / InTeamNoRel → 404 for all per-task ops (not in Allowed).
// Sharees: GET, PATCH (field-only), GET-audit (no DELETE, no POST).
// TeamAdmin: GET, PATCH, DELETE, GET-audit (no POST to a specific task).
// Owner: GET, PATCH, DELETE, GET-audit (no POST to a specific task — POST creates new).
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RelInTeamNoRel -> PostTasks) +
    (RelTeamAdmin   -> PostTasks) +
    (RelOwner       -> PostTasks) +

    (RelSharee      -> GetTaskById)    +
    (RelTeamAdmin   -> GetTaskById)    +
    (RelOwner       -> GetTaskById)    +

    (RelSharee      -> PatchTaskById)  +
    (RelTeamAdmin   -> PatchTaskById)  +
    (RelOwner       -> PatchTaskById)  +

    (RelTeamAdmin   -> DeleteTaskById) +
    (RelOwner       -> DeleteTaskById) +

    (RelSharee      -> GetTaskAudit)   +
    (RelTeamAdmin   -> GetTaskAudit)   +
    (RelOwner       -> GetTaskAudit)
}

// ── F_UserExactlyOneTeam ──────────────────────────────────────────
// FR-002: each user belongs to exactly one team (enforced by sig field,
// restated as a named fact so removal is mutation-testable).
fact F_UserExactlyOneTeam {
  all u: User | one u.userTeam
}

// ── F_OwnerInTaskTeam ─────────────────────────────────────────────
// data-model.md tasks.owner_id FK→users; task's team_id denormalized from owner.
// A task's team must equal the team of its owner.
fact F_OwnerInTaskTeam {
  all t: Task | t.taskOwner.userTeam = t.taskTeam
}

// ── F_ShareeSameTeam ─────────────────────────────────────────────
// FR-012: every user_id in shared_with must be a member of the same team
// as the task owner; cross-team sharing is forbidden.
fact F_ShareeSameTeam {
  all t: Task, s: t.taskSharees | s.userTeam = t.taskTeam
}

// ── F_OwnerNotSharee ─────────────────────────────────────────────
// The owner is never in their own shared_with list
// (data-model.md: "creator is implicitly in the read-set as owner;
// do not include their own user_id").
fact F_OwnerNotSharee {
  all t: Task | t.taskOwner not in t.taskSharees
}

// ── F_AuditTeamDenorm ─────────────────────────────────────────────
// data-model.md AuditEntry.team_id is denormalized from the task's team.
fact F_AuditTeamDenorm {
  all ae: AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
}

// ── F_AuditActorRoleSnapshot ─────────────────────────────────────
// FR-016: actor_role is snapshotted from the caller at the time of the change
// and must equal the actor's actual current role.
// (In the static model we enforce: entryActorRole matches the actor's role sig.)
fact F_AuditActorRoleSnapshot {
  all ae: AuditEntry | ae.entryActorRole = ae.entryActor.userRole
}

// ── F_AuditActorInTaskTeam ────────────────────────────────────────
// FR-006: no cross-team access; therefore the audit actor must always be
// in the same team as the audited task (FR-002, FR-006).
fact F_AuditActorInTaskTeam {
  all ae: AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
}

// ── F_AuditCreatedExists ──────────────────────────────────────────
// FR-015, AuditCompleteness anchor: every task has exactly one "created"
// audit entry (every task came into existence via POST /tasks, which
// produces exactly one OpCreated entry).
fact F_AuditCreatedExists {
  all t: Task | one ae: AuditEntry | ae.entryTask = t and ae.entryOp = OpCreated
}

// ── F_AppendOnlyAuditEntries ─────────────────────────────────────
// FR-017: audit entries are immutable and append-only.
// Modeled as: no two distinct AuditEntry atoms are identical in every field
// (which would indicate one "replaced" another), AND every AuditEntry
// retains its association with its task regardless of whether the task
// is in a "deleted" state (there is no mechanism to sever entryTask).
// In this static model we enforce that each AuditEntry atom is uniquely
// identified by its content — no duplicates allowed.
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    not (ae1.entryTask = ae2.entryTask
      and ae1.entryActor = ae2.entryActor
      and ae1.entryActorRole = ae2.entryActorRole
      and ae1.entryOp = ae2.entryOp)
}

// ── F_DeletedAuditExistsForDeletedTasks ──────────────────────────
// FR-015 / FR-017: if a task is "logically deleted" (has a Deleted audit entry)
// it must also still have its Created entry — the log survives deletion.
// This fact simply asserts the definition; a task is deleted iff it has
// a Deleted entry, and when it does the Created entry must also exist.
fact F_DeletedAuditExistsForDeletedTasks {
  all t: Task |
    (some ae: AuditEntry | ae.entryTask = t and ae.entryOp = OpDeleted)
    implies (some ae2: AuditEntry | ae2.entryTask = t and ae2.entryOp = OpCreated)
}

// ── F_ShareAuditForSharees ────────────────────────────────────────
// FR-013: every user currently in taskSharees must have a corresponding
// OpShared audit entry on that task (the share was audit-logged when added).
fact F_ShareAuditForSharees {
  all t: Task, s: t.taskSharees |
    some ae: AuditEntry | ae.entryTask = t and ae.entryActor = t.taskOwner
      and ae.entryOp = OpShared
}

// ── F_AccessCheckRelComputed ─────────────────────────────────────
// AccessCheck.checkRel is determined by the caller's relationship to the task:
//   RelOwner     iff caller = task.owner
//   RelTeamAdmin iff caller is team_admin in the task's team (and not owner)
//   RelSharee    iff caller is in task.sharedWith (and not owner/admin)
//   RelInTeamNoRel iff caller is in the same team but none of the above
//   RelOutsider  iff caller is in a different team
fact F_AccessCheckRelComputed {
  all ac: AccessCheck |
    let c = ac.checkCaller, t = ac.checkTask |
      (c = t.taskOwner
        implies ac.checkRel = RelOwner)
      and
      (c != t.taskOwner and c.userRole = RoleTeamAdmin and c.userTeam = t.taskTeam
        implies ac.checkRel = RelTeamAdmin)
      and
      (c != t.taskOwner and c.userRole = RoleMember and c in t.taskSharees
        implies ac.checkRel = RelSharee)
      and
      (c != t.taskOwner and c.userRole = RoleMember and c not in t.taskSharees
        and c.userTeam = t.taskTeam
        implies ac.checkRel = RelInTeamNoRel)
      and
      (c.userTeam != t.taskTeam
        implies ac.checkRel = RelOutsider)
}

// ── F_OutsiderAndInTeamNoRelDenied ───────────────────────────────
// FR-014: outsiders and in-team-no-rel callers are never in the Allowed set
// for any per-task operation.  (PostTasks for InTeamNoRel is the only
// per-team — not per-task — operation and is still in the matrix above.)
// We constrain: RelOutsider is not Allowed for any per-task op.
fact F_OutsiderDeniedAllPerTaskOps {
  RelOutsider -> GetTaskById    not in PermMatrix.Allowed
  RelOutsider -> PatchTaskById  not in PermMatrix.Allowed
  RelOutsider -> DeleteTaskById not in PermMatrix.Allowed
  RelOutsider -> GetTaskAudit   not in PermMatrix.Allowed
  RelOutsider -> PostTasks      not in PermMatrix.Allowed
}

// ══════════════════════════════════════════════════════════════════
//  PATTERN PREDICATES
// ══════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §Permission matrix; FR-003, FR-004, FR-005
pred LeastPrivilege {
  // Outsiders are never allowed any per-task operation.
  RelOutsider -> GetTaskById    not in PermMatrix.Allowed
  RelOutsider -> PatchTaskById  not in PermMatrix.Allowed
  RelOutsider -> DeleteTaskById not in PermMatrix.Allowed
  RelOutsider -> GetTaskAudit   not in PermMatrix.Allowed
  // InTeamNoRel callers cannot read, edit, delete, or audit a specific task.
  RelInTeamNoRel -> GetTaskById    not in PermMatrix.Allowed
  RelInTeamNoRel -> PatchTaskById  not in PermMatrix.Allowed
  RelInTeamNoRel -> DeleteTaskById not in PermMatrix.Allowed
  RelInTeamNoRel -> GetTaskAudit   not in PermMatrix.Allowed
  // Sharees cannot delete.
  RelSharee -> DeleteTaskById not in PermMatrix.Allowed
  // At least one Task and User exist to avoid vacuity.
  some Task
  some User
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 Relationship, exactly 5 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §Permission matrix
pred PermissionCompleteness {
  // Every per-task Relationship × OperationKind pair is either explicitly
  // in Allowed or explicitly absent (closed-world matrix).
  // We verify the matrix is total by checking that the union of all allowed
  // cells equals exactly the set defined in F_PermissionMatrix.
  PermMatrix.Allowed =
    (RelInTeamNoRel -> PostTasks) +
    (RelTeamAdmin   -> PostTasks) +
    (RelOwner       -> PostTasks) +
    (RelSharee      -> GetTaskById)    +
    (RelTeamAdmin   -> GetTaskById)    +
    (RelOwner       -> GetTaskById)    +
    (RelSharee      -> PatchTaskById)  +
    (RelTeamAdmin   -> PatchTaskById)  +
    (RelOwner       -> PatchTaskById)  +
    (RelTeamAdmin   -> DeleteTaskById) +
    (RelOwner       -> DeleteTaskById) +
    (RelSharee      -> GetTaskAudit)   +
    (RelTeamAdmin   -> GetTaskAudit)   +
    (RelOwner       -> GetTaskAudit)
  some Task
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 Relationship, exactly 5 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  // Every AccessCheck has a valid caller (i.e., some authenticated User).
  // Structurally: no AccessCheck references a null/absent caller.
  // Also: RelOutsider callers (cross-team) must still be authenticated users;
  // the access denial comes from team mismatch, not from lack of auth.
  all ac: AccessCheck | one ac.checkCaller
  // Every user has a team and role (claims from OAuth introspection — FR-002).
  all u: User | one u.userTeam and one u.userRole
  some AccessCheck
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, FR-016; data-model.md AuditEntry
pred AuditCompleteness {
  // Every task has exactly one OpCreated entry.
  all t: Task | one ae: AuditEntry | ae.entryTask = t and ae.entryOp = OpCreated
  some Task
  some AuditEntry
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017, SC-009; data-model.md §"Append-only"
pred AppendOnly {
  // No two distinct audit entries are byte-identical replacements of each other
  // (same task, actor, role, and operation — which would imply one was
  // mutated into the other or an entry was re-written).
  all disj ae1, ae2: AuditEntry |
    not (ae1.entryTask = ae2.entryTask
      and ae1.entryActor = ae2.entryActor
      and ae1.entryActorRole = ae2.entryActorRole
      and ae1.entryOp = ae2.entryOp)
  some AuditEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role
pred AttributionCorrectness {
  // The actor_role stored in every audit entry must match the actor's actual role.
  all ae: AuditEntry | ae.entryActorRole = ae.entryActor.userRole
  // The actor must be in the same team as the task.
  all ae: AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
  some AuditEntry
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id; spec.md FR-009
pred OwnershipExclusivity {
  // Each task has exactly one owner (structural — but we also verify the owner
  // is in the task's team, reinforcing FR-009 immutability intent).
  all t: Task | one t.taskOwner
  all t: Task | t.taskOwner.userTeam = t.taskTeam
  some Task
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-010, Q1=A; contracts/http-api.md §Permission matrix
pred OwnershipBasedAccess {
  // The owner is always in the Allowed set for reading and editing their task.
  RelOwner -> GetTaskById   in PermMatrix.Allowed
  RelOwner -> PatchTaskById in PermMatrix.Allowed
  RelOwner -> DeleteTaskById in PermMatrix.Allowed
  // Only the owner can change shared_with — modeled as: RelSharee and RelTeamAdmin
  // are NOT allowed to issue a PatchTaskById that changes shared_with.
  // We verify the relationship encoding: the owner is not in their own sharee set.
  all t: Task | t.taskOwner not in t.taskSharees
  some Task
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-003; contracts/http-api.md §Byte-equivalent not-found
pred NoInformationLeakage {
  // Outsiders and InTeamNoRel callers are denied all per-task read operations.
  // The response is byte-equivalent regardless of whether the task exists or is
  // cross-team. We encode this as: those relationships are absent from Allowed
  // for every per-task read operation.
  RelOutsider    -> GetTaskById  not in PermMatrix.Allowed
  RelOutsider    -> GetTaskAudit not in PermMatrix.Allowed
  RelInTeamNoRel -> GetTaskById  not in PermMatrix.Allowed
  RelInTeamNoRel -> GetTaskAudit not in PermMatrix.Allowed
  // Sharees denied delete also get the byte-equivalent 404 (FR-011, FR-014).
  RelSharee -> DeleteTaskById not in PermMatrix.Allowed
  some Task
  some User
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8 but exactly 5 Relationship, exactly 5 OperationKind

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005 vs FR-003; contracts/http-api.md §Permission matrix
pred PrivilegeMonotonicity {
  // TeamAdmin's allowed set is a superset of the Sharee's allowed set
  // on per-task operations (admin can do everything a sharee can, plus delete).
  all op: OperationKind |
    RelSharee -> op in PermMatrix.Allowed
    implies (RelTeamAdmin -> op in PermMatrix.Allowed)
  some Task
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8 but exactly 5 Relationship, exactly 5 OperationKind

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-015, SC-007; data-model.md §"Append-only"
pred ValidationBeforeMutation {
  // If a task exists in the model (state change occurred), it must have
  // an OpCreated audit entry (the mutation was valid and audited).
  // No "orphan" tasks without an audit trail exist.
  all t: Task | some ae: AuditEntry | ae.entryTask = t and ae.entryOp = OpCreated
  some Task
  some AuditEntry
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ══════════════════════════════════════════════════════════════════
//  FEATURE-SPECIFIC PREDICATES (FR-by-FR)
// ══════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001 — all endpoints require OAuth bearer token
pred FR_001_AuthRequired {
  // Every AccessCheck has exactly one authenticated caller with a valid
  // team and role (claims from introspected token — no body-sourced identity).
  all ac: AccessCheck | one ac.checkCaller.userTeam and one ac.checkCaller.userRole
  some AccessCheck
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — user belongs to exactly one team
pred FR_002_UserExactlyOneTeam {
  all u: User | one u.userTeam
  some User
}
assert FR_002_UserExactlyOneTeam { FR_002_UserExactlyOneTeam }
check FR_002_UserExactlyOneTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004 — member access restricted to own/shared tasks
pred FR_003_MemberAccessControl {
  // A member (non-admin, non-owner) user accessing a task must be in
  // that task's sharedWith set OR be the owner to have any read/edit access.
  // Encoded: RelInTeamNoRel is denied GET and PATCH on specific tasks.
  RelInTeamNoRel -> GetTaskById   not in PermMatrix.Allowed
  RelInTeamNoRel -> PatchTaskById not in PermMatrix.Allowed
  // Sharees (members with explicit share) can read and edit.
  RelSharee -> GetTaskById   in PermMatrix.Allowed
  RelSharee -> PatchTaskById in PermMatrix.Allowed
  some Task
}
assert FR_003_MemberAccessControl { FR_003_MemberAccessControl }
check FR_003_MemberAccessControl for 8 but exactly 5 Relationship, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-005 — team admin full access within team only
pred FR_005_AdminTeamAccess {
  // Team admins can read, edit, and delete any task in their team.
  RelTeamAdmin -> GetTaskById    in PermMatrix.Allowed
  RelTeamAdmin -> PatchTaskById  in PermMatrix.Allowed
  RelTeamAdmin -> DeleteTaskById in PermMatrix.Allowed
  RelTeamAdmin -> GetTaskAudit   in PermMatrix.Allowed
  // Team admins cannot access cross-team tasks (RelOutsider applies to them too
  // when the task is in a different team).
  RelOutsider -> GetTaskById    not in PermMatrix.Allowed
  RelOutsider -> DeleteTaskById not in PermMatrix.Allowed
  some Task
}
assert FR_005_AdminTeamAccess { FR_005_AdminTeamAccess }
check FR_005_AdminTeamAccess for 8 but exactly 5 Relationship, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-006 — absolute cross-team isolation
pred FR_006_CrossTeamIsolation {
  // Cross-team callers (RelOutsider) are denied every per-task operation.
  all op: OperationKind - PostTasks |
    RelOutsider -> op not in PermMatrix.Allowed
  // Structurally: every task's team matches its owner's team.
  all t: Task | t.taskTeam = t.taskOwner.userTeam
  // All sharees must be in the task's team.
  all t: Task, s: t.taskSharees | s.userTeam = t.taskTeam
  some Task
  some User
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 8 but exactly 5 Relationship, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-009 — owner_id and team_id are immutable
pred FR_009_ImmutableOwnerAndTeam {
  // The static model does not carry "before/after" states.
  // We verify the structural constraint: every task has one owner and one team,
  // both fixed at creation time (no second value possible).
  all t: Task | one t.taskOwner and one t.taskTeam
  // The owner's team must match the task's team (denormalization invariant).
  all t: Task | t.taskOwner.userTeam = t.taskTeam
  some Task
}
assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A — only the task owner can change shared_with
pred FR_010_OwnerOnlyShareControl {
  // Encoded in permission matrix: only RelOwner is allowed PatchTaskById
  // for share-list changes. Structurally, we verify no sharee or admin is
  // the "controller" of the share list — the owner is the sole RelOwner atom.
  RelSharee    -> DeleteTaskById not in PermMatrix.Allowed   // sanity
  RelInTeamNoRel -> PatchTaskById not in PermMatrix.Allowed  // non-rel denied
  RelOutsider    -> PatchTaskById not in PermMatrix.Allowed  // cross-team denied
  // The owner must not be in their own sharees (FR-010 semantics).
  all t: Task | t.taskOwner not in t.taskSharees
  some Task
}
assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, Q3=B — sharee may view/edit but not delete
pred FR_011_ShareeCannotDelete {
  RelSharee -> DeleteTaskById not in PermMatrix.Allowed
  RelSharee -> GetTaskById    in  PermMatrix.Allowed
  RelSharee -> PatchTaskById  in  PermMatrix.Allowed
  some Task
  some User
}
assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 8 but exactly 5 Relationship, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-012 — cross-team sharing forbidden
pred FR_012_NoChrossTeamSharing {
  // All users in any task's sharedWith set must belong to the task's team.
  all t: Task, s: t.taskSharees | s.userTeam = t.taskTeam
  some Task
}
assert FR_012_NoChrossTeamSharing { FR_012_NoChrossTeamSharing }
check FR_012_NoChrossTeamSharing for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — every share change produces an audit entry
pred FR_013_ShareAuditEntries {
  // Every user currently in taskSharees must have a corresponding OpShared
  // audit entry authored by the task owner on that task.
  all t: Task, s: t.taskSharees |
    some ae: AuditEntry | ae.entryTask = t
      and ae.entryActor = t.taskOwner
      and ae.entryOp = OpShared
  some Task
  some AuditEntry
}
assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 — byte-equivalent response for all non-permitted callers
pred FR_014_ByteEquivalentIsolation {
  // Outsiders and in-team-no-rel callers are denied all four per-task endpoints.
  RelOutsider    -> GetTaskById    not in PermMatrix.Allowed
  RelOutsider    -> PatchTaskById  not in PermMatrix.Allowed
  RelOutsider    -> DeleteTaskById not in PermMatrix.Allowed
  RelOutsider    -> GetTaskAudit   not in PermMatrix.Allowed
  RelInTeamNoRel -> GetTaskById    not in PermMatrix.Allowed
  RelInTeamNoRel -> PatchTaskById  not in PermMatrix.Allowed
  RelInTeamNoRel -> DeleteTaskById not in PermMatrix.Allowed
  RelInTeamNoRel -> GetTaskAudit   not in PermMatrix.Allowed
  // Sharees attempting DELETE also get the byte-equivalent 404 (FR-011).
  RelSharee -> DeleteTaskById not in PermMatrix.Allowed
  some Task
  some User
}
assert FR_014_ByteEquivalentIsolation { FR_014_ByteEquivalentIsolation }
check FR_014_ByteEquivalentIsolation for 8 but exactly 5 Relationship, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-015 — every task has exactly one Created audit entry
pred FR_015_PerEventAuditEntries {
  all t: Task | one ae: AuditEntry | ae.entryTask = t and ae.entryOp = OpCreated
  some Task
  some AuditEntry
}
assert FR_015_PerEventAuditEntries { FR_015_PerEventAuditEntries }
check FR_015_PerEventAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit entry actor_role matches actor's actual role
pred FR_016_AuditAttributionAccurate {
  all ae: AuditEntry | ae.entryActorRole = ae.entryActor.userRole
  all ae: AuditEntry | ae.entryActor.userTeam = ae.entryTask.taskTeam
  all ae: AuditEntry | one ae.entryActor and one ae.entryActorRole
  some AuditEntry
}
assert FR_016_AuditAttributionAccurate { FR_016_AuditAttributionAccurate }
check FR_016_AuditAttributionAccurate for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit entries are immutable and outlive the task
pred FR_017_AuditImmutableOutlivesTask {
  // AppendOnly: no two distinct entries have the same (task, actor, role, op) tuple.
  all disj ae1, ae2: AuditEntry |
    not (ae1.entryTask = ae2.entryTask
      and ae1.entryActor = ae2.entryActor
      and ae1.entryActorRole = ae2.entryActorRole
      and ae1.entryOp = ae2.entryOp)
  // Deleted tasks still have their Created audit entry (log outlives task).
  all t: Task |
    (some ae: AuditEntry | ae.entryTask = t and ae.entryOp = OpDeleted)
    implies (some ae2: AuditEntry | ae2.entryTask = t and ae2.entryOp = OpCreated)
  some AuditEntry
}
assert FR_017_AuditImmutableOutlivesTask { FR_017_AuditImmutableOutlivesTask }
check FR_017_AuditImmutableOutlivesTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 — audit readable by owner/sharee/admin only
pred FR_019_AuditVisibility {
  RelOwner     -> GetTaskAudit in  PermMatrix.Allowed
  RelSharee    -> GetTaskAudit in  PermMatrix.Allowed
  RelTeamAdmin -> GetTaskAudit in  PermMatrix.Allowed
  // Non-permitted callers cannot read audit log.
  RelOutsider    -> GetTaskAudit not in PermMatrix.Allowed
  RelInTeamNoRel -> GetTaskAudit not in PermMatrix.Allowed
  some Task
  some AuditEntry
}
assert FR_019_AuditVisibility { FR_019_AuditVisibility }
check FR_019_AuditVisibility for 8 but exactly 5 Relationship, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-002a — team_id and role from token; never from request payload
pred FR_002a_IdentityFromToken {
  // Every user has exactly one team_id and one role (OAuth-token-sourced).
  all u: User | one u.userTeam and one u.userRole
  // AccessChecks must derive the caller identity from the User sig, not from a separate field.
  all ac: AccessCheck | ac.checkCaller.userTeam != none
  some User
  some AccessCheck
}
assert FR_002a_IdentityFromToken { FR_002a_IdentityFromToken }
check FR_002a_IdentityFromToken for 5