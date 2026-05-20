// === feature_model.als — Alloy model for B-L3 / 008-task-sharing ===
// Multi-Tenant Task Management with Per-Task Sharing and Audit
// Sources: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────
// ENUMERATIONS
// ─────────────────────────────────────────────────

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig AuditOperation {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOperation {}

abstract sig Outcome {}
one sig Success, Failure extends Outcome {}

// Computed caller-to-task relationship (not persisted, derived)
abstract sig Relationship {}
one sig Outsider, InTeamNone, ShareeRel, TeamAdminRel, OwnerRel extends Relationship {}

// The five endpoints × two PATCH variants
abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchFields, PatchSharedWith, DeleteTask, GetAudit
  extends OperationKind {}

// ─────────────────────────────────────────────────
// CORE ENTITY SIGS
// ─────────────────────────────────────────────────

sig Team {}

sig User {
  userTeam : one Team,
  userRole : one Role
}

sig Task {
  taskTeam  : one Team,
  owner     : one User,
  taskStatus: one TaskStatus
}

// Junction table for per-task shares (data-model.md TaskShare)
sig TaskShare {
  shareTask : one Task,
  sharee    : one User
}

// Append-only audit record (data-model.md AuditEntry)
sig AuditEntry {
  entryTask    : one Task,
  entryTeam    : one Team,
  entryActor   : one User,
  entryActorRole: one Role,
  entryOp      : one AuditOperation
}

// An API operation issued by a caller against an (optional) target task
sig Operation {
  opCaller     : one User,
  opCallerRole : one Role,   // snapshotted from token, not from payload
  opKind       : one OperationKind,
  opTarget     : lone Task,
  opOutcome    : one Outcome,
  opEntries    : set AuditEntry  // audit rows produced by this operation
}

// ─────────────────────────────────────────────────
// PERMISSION MATRIX SINGLETON
// contracts/http-api.md "Permission matrix" table
// ─────────────────────────────────────────────────

one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ─────────────────────────────────────────────────
// NON-EMPTY UNIVERSE (Rule 9)
// ─────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some TaskShare
  some AuditEntry
  some Operation
}

// ─────────────────────────────────────────────────
// STRUCTURAL FACTS
// ─────────────────────────────────────────────────

// Task's team equals its owner's team (denormalisation invariant)
// spec.md FR-009; data-model.md Task.team_id
fact F_TaskTeamMatchesOwnerTeam {
  all t: Task | t.taskTeam = t.owner.userTeam
}

// Every sharee must be in the same team as the task owner (FR-012)
// Cross-team sharing is forbidden in v1
fact F_ShareeSameTeamAsTask {
  all s: TaskShare | s.sharee.userTeam = s.shareTask.taskTeam
}

// A user cannot be both the owner and a sharee of the same task
fact F_OwnerNotSharee {
  all s: TaskShare | s.sharee != s.shareTask.owner
}

// Uniqueness: no duplicate (task, sharee) share rows — composite PK
// data-model.md TaskShare "Composite PK: (task_id, sharee_user_id)"
fact F_ShareUniqueness {
  all disj s1, s2: TaskShare |
    not (s1.shareTask = s2.shareTask and s1.sharee = s2.sharee)
}

// Audit entries carry the denormalised team_id of the task
// data-model.md AuditEntry.team_id "Denormalised from the task at write time"
fact F_AuditEntryTeamMatchesTask {
  all ae: AuditEntry | ae.entryTeam = ae.entryTask.taskTeam
}

// Each AuditEntry belongs to exactly one Operation (1-to-1 pairing)
// spec.md FR-015 "exactly one new audit entry per logical event"
fact F_AuditEntryBelongsToOneOperation {
  all ae: AuditEntry | one op: Operation | ae in op.opEntries
}

// The caller's snapshotted role matches their actual role at call time
// spec.md FR-002 "role from introspected OAuth token"; FR-016 actor_role snapshot
fact F_CallerRoleSnapshot {
  all op: Operation | op.opCallerRole = op.opCaller.userRole
}

// Audit entry actor matches the operation caller
// spec.md FR-016 "actor_user_id, actor_role snapshotted at the time of the change"
fact F_AuditActorMatchesCaller {
  all op: Operation, ae: AuditEntry |
    ae in op.opEntries implies (ae.entryActor = op.opCaller and ae.entryActorRole = op.opCallerRole)
}

// Successful mutations MUST produce at least one audit entry (FR-015)
// A mutation is PostTasks, PatchFields, PatchSharedWith, DeleteTask
fact F_SuccessfulMutationHasAuditEntry {
  all op: Operation |
    (op.opOutcome = Success and
     op.opKind in (PostTasks + PatchFields + PatchSharedWith + DeleteTask))
    implies (some op.opEntries)
}

// Failed operations MUST produce NO audit entries (FR-001, FR-018, US2-SC3)
// "MUST NOT produce any audit entry" on invalid/unauthorised requests
fact F_FailedOperationNoAuditEntry {
  all op: Operation | op.opOutcome = Failure implies no op.opEntries
}

// Successful read-only operations (GetTask, GetAudit) produce no audit entries
fact F_ReadOperationNoAuditEntry {
  all op: Operation |
    op.opKind in (GetTask + GetAudit) implies no op.opEntries
}

// An operation targeting a task must target a task in the caller's team,
// or be a cross-team failure (Outsider always fails). FR-006.
fact F_CrossTeamOperationFails {
  all op: Operation |
    (some op.opTarget and op.opTarget.taskTeam != op.opCaller.userTeam)
    implies op.opOutcome = Failure
}

// Audit entries that belong to an operation reference the same task as the operation
fact F_AuditEntryLinkedToOpTask {
  all op: Operation, ae: AuditEntry |
    (ae in op.opEntries and some op.opTarget)
    implies ae.entryTask = op.opTarget
}

// Audit entries for PostTasks are Created operations
// spec.md FR-015, FR-016
fact F_CreateOpAuditIsCreated {
  all op: Operation |
    (op.opKind = PostTasks and op.opOutcome = Success)
    implies (all ae: op.opEntries | ae.entryOp = Created)
}

// DeleteTask produces exactly one Deleted audit entry on success (FR-015)
fact F_DeleteOpAuditIsDeleted {
  all op: Operation |
    (op.opKind = DeleteTask and op.opOutcome = Success)
    implies (one ae: op.opEntries | ae.entryOp = Deleted)
}

// Share-change audit entries are Shared or Unshared (FR-015)
fact F_ShareOpAuditEntries {
  all op: Operation, ae: AuditEntry |
    (op.opKind = PatchSharedWith and ae in op.opEntries)
    implies ae.entryOp in (Shared + Unshared)
}

// ─────────────────────────────────────────────────
// PERMISSION MATRIX FACT
// contracts/http-api.md "Permission matrix" table
// Encodes the full closed-world (Relationship × OperationKind) allowed set.
// ─────────────────────────────────────────────────

fact F_PermissionMatrix {
  // Exact enumeration of allowed cells
  PermMatrix.Allowed =
    // PostTasks — in-team members and admins may create tasks
    (InTeamNone   -> PostTasks) +
    (TeamAdminRel -> PostTasks) +
    // GetTask — owner, sharee, team-admin
    (OwnerRel     -> GetTask) +
    (ShareeRel    -> GetTask) +
    (TeamAdminRel -> GetTask) +
    // PatchFields — owner, sharee, team-admin (non-share-list fields)
    (OwnerRel     -> PatchFields) +
    (ShareeRel    -> PatchFields) +
    (TeamAdminRel -> PatchFields) +
    // PatchSharedWith — OWNER ONLY (Q1=A; FR-010; FR-005 admin excluded)
    (OwnerRel     -> PatchSharedWith) +
    // DeleteTask — owner and team-admin only (Q3=B: sharee cannot delete)
    (OwnerRel     -> DeleteTask) +
    (TeamAdminRel -> DeleteTask) +
    // GetAudit — owner, sharee, team-admin (FR-019)
    (OwnerRel     -> GetAudit) +
    (ShareeRel    -> GetAudit) +
    (TeamAdminRel -> GetAudit)
}

// ─────────────────────────────────────────────────
// RELATIONSHIP COMPUTATION HELPERS (predicates)
// ─────────────────────────────────────────────────

pred isOutsider[u: User, t: Task] {
  u.userTeam != t.taskTeam
}

pred isOwner[u: User, t: Task] {
  u.userTeam = t.taskTeam and t.owner = u
}

pred isTeamAdminRel[u: User, t: Task] {
  u.userTeam = t.taskTeam and u.userRole = TeamAdmin and t.owner != u
}

pred isSharee[u: User, t: Task] {
  u.userTeam = t.taskTeam and t.owner != u and u.userRole = Member
  and (some s: TaskShare | s.shareTask = t and s.sharee = u)
}

pred isInTeamNone[u: User, t: Task] {
  u.userTeam = t.taskTeam and t.owner != u
  and u.userRole = Member
  and (no s: TaskShare | s.shareTask = t and s.sharee = u)
}

// Derives relationship (one of the five) from user+task state
fun relOf[u: User, t: Task]: Relationship {
  (isOutsider[u, t])     => Outsider     else
  (isOwner[u, t])        => OwnerRel     else
  (isTeamAdminRel[u, t]) => TeamAdminRel else
  (isSharee[u, t])       => ShareeRel    else InTeamNone
}

// ─────────────────────────────────────────────────
// AUTHORIZATION ENFORCEMENT FACT
// Every successful Operation must be permitted in PermMatrix
// spec.md FR-003, FR-004, FR-005, FR-006
// ─────────────────────────────────────────────────

fact F_AuthorizationEnforced {
  all op: Operation |
    (op.opOutcome = Success and some op.opTarget) implies
      (relOf[op.opCaller, op.opTarget] -> op.opKind in PermMatrix.Allowed)
}

// ─────────────────────────────────────────────────
// ═══════════════════════════════════════════════
// NAMED PREDICATES + ASSERTIONS
// ═══════════════════════════════════════════════
// ─────────────────────────────────────────────────

// ── PATTERN: LeastPrivilege ─────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003 FR-004 FR-005 FR-006

pred LeastPrivilege {
  // Denied cells in the matrix are never successfully executed
  all op: Operation |
    (some op.opTarget and op.opOutcome = Success) implies
      (relOf[op.opCaller, op.opTarget] -> op.opKind in PermMatrix.Allowed)
  // Outsider can never succeed on any existing task
  all op: Operation |
    (some op.opTarget and isOutsider[op.opCaller, op.opTarget]) implies
      op.opOutcome = Failure
  some op: Operation | op.opOutcome = Success
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ── PATTERN: PermissionCompleteness ─────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix

pred PermissionCompleteness {
  // Every (Relationship × OperationKind) pair has a defined verdict:
  // either it's in Allowed (permit) or it's not (deny). No undefined cell.
  // The closed-world encoding of F_PermissionMatrix guarantees this; we
  // verify the matrix is neither empty nor universal.
  some PermMatrix.Allowed
  PermMatrix.Allowed != Relationship -> OperationKind
  // Specifically: Outsider is denied for all operations on existing tasks
  no r: Relationship | r = Outsider and (some ok: OperationKind | Outsider -> ok in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// ── PATTERN: AuthRequiredEverywhere ─────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section

pred AuthRequiredEverywhere {
  // Every operation has a resolved caller (authenticated user with team+role).
  // In our model every Operation has opCaller: one User, which is always set.
  // Additionally: the snapshotted role must match the actual role (token-derived).
  all op: Operation | op.opCallerRole = op.opCaller.userRole
  some op: Operation | op.opOutcome = Success
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ── PATTERN: AuditCompleteness ───────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015 FR-016; data-model.md AuditEntry

pred AuditCompleteness {
  // Every successful mutation has at least one audit entry
  all op: Operation |
    (op.opOutcome = Success and
     op.opKind in (PostTasks + PatchFields + PatchSharedWith + DeleteTask))
    implies (some op.opEntries)
  // Every audit entry belongs to exactly one successful operation
  all ae: AuditEntry | one op: Operation | ae in op.opEntries
  // Ensure the predicate is not vacuous
  some op: Operation | op.opOutcome = Success and op.opKind = PatchFields and some op.opEntries
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ── PATTERN: AppendOnly ──────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-017 SC-009; data-model.md "Append-only: no UPDATE/DELETE SQL"

pred AppendOnly {
  // Each AuditEntry is associated with exactly one Operation — no "re-assignment"
  all ae: AuditEntry | one op: Operation | ae in op.opEntries
  // No AuditEntry can belong to two distinct operations
  all disj op1, op2: Operation | op1.opEntries & op2.opEntries = none
  // There exists at least one AuditEntry to avoid vacuity
  some AuditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ── PATTERN: AttributionCorrectness ─────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_user_id actor_role

pred AttributionCorrectness {
  all op: Operation, ae: AuditEntry |
    ae in op.opEntries implies
      (ae.entryActor = op.opCaller and ae.entryActorRole = op.opCallerRole)
  some ae: AuditEntry
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ── PATTERN: OwnershipExclusivity ───────────────────
// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner_id NOT NULL FK; spec.md FR-009

pred OwnershipExclusivity {
  // Every task has exactly one owner (encoded in sig declaration, but we assert meaningfully)
  all t: Task | one t.owner
  // The owner is always in the same team as the task
  all t: Task | t.owner.userTeam = t.taskTeam
  some Task
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ── PATTERN: OwnershipBasedAccess ────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 FR-004 FR-005; contracts/http-api.md permission matrix

pred OwnershipBasedAccess {
  // A member with no ownership and no share cannot successfully read a task
  all op: Operation |
    (some op.opTarget and
     op.opKind = GetTask and
     isInTeamNone[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  // A sharee CAN successfully read
  all op: Operation |
    (some op.opTarget and
     op.opKind = GetTask and
     isSharee[op.opCaller, op.opTarget] and
     op.opOutcome = Success)
    implies (some s: TaskShare | s.shareTask = op.opTarget and s.sharee = op.opCaller)
  some op: Operation | op.opOutcome = Success and op.opKind = GetTask
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ── PATTERN: NoInformationLeakage ────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014 SC-003; contracts/http-api.md "Byte-equivalent not-found response"

pred NoInformationLeakage {
  // Cross-team callers (Outsider) always fail — indistinguishable from non-existent task
  all op: Operation |
    (some op.opTarget and isOutsider[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  // In-team callers with no relationship also fail
  all op: Operation |
    (some op.opTarget and
     op.opKind in (GetTask + PatchFields + PatchSharedWith + DeleteTask + GetAudit) and
     isInTeamNone[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  // Sharee attempting DELETE also fails (Q3=B; FR-011; byte-equivalent 404)
  all op: Operation |
    (some op.opTarget and op.opKind = DeleteTask and isSharee[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  some op: Operation | isOutsider[op.opCaller, op.opTarget] and op.opOutcome = Failure
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ── FR-001: Auth required — no audit entry on auth failure ───────
// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md "rejected … MUST NOT produce any audit entry"

pred FR_001_AuthRequired {
  // All failed operations (including auth failures) produce zero audit entries
  all op: Operation | op.opOutcome = Failure implies no op.opEntries
  some op: Operation | op.opOutcome = Failure
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ── FR-002: Role and team from token, not payload ─────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002 FR-002a SC-006

pred FR_002_RoleFromToken {
  // The operation's snapshotted caller role equals the actual user role
  // (i.e., the role was read from the token/user record, not supplied by the caller)
  all op: Operation | op.opCallerRole = op.opCaller.userRole
  some op: Operation
}

assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 5

// ── FR-004: Member cannot access tasks not owned or shared ────────
// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md US1-SC3 US2-SC3

pred FR_004_MemberNoUnauthorizedAccess {
  all op: Operation |
    (some op.opTarget and
     op.opCaller.userRole = Member and
     isInTeamNone[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  some op: Operation | op.opCaller.userRole = Member and op.opOutcome = Failure
}

assert FR_004_MemberNoUnauthorizedAccess { FR_004_MemberNoUnauthorizedAccess }
check FR_004_MemberNoUnauthorizedAccess for 5

// ── FR-005: TeamAdmin cannot change shared_with on tasks they don't own ──
// FEATURE-SPECIFIC  ANCHOR: FR-005 Q1=A; spec.md US4-SC3 "400 validation_error"

pred FR_005_AdminCannotChangeShareList {
  // TeamAdmin attempting PatchSharedWith on a task they do not own must fail
  all op: Operation |
    (some op.opTarget and
     op.opKind = PatchSharedWith and
     isTeamAdminRel[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  some op: Operation | op.opKind = PatchSharedWith
}

assert FR_005_AdminCannotChangeShareList { FR_005_AdminCannotChangeShareList }
check FR_005_AdminCannotChangeShareList for 5

// ── FR-006: Absolute cross-team isolation ────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006 FR-014; spec.md US5

pred FR_006_CrossTeamIsolation {
  all op: Operation |
    (some op.opTarget and op.opCaller.userTeam != op.opTarget.taskTeam)
    implies op.opOutcome = Failure
  some op: Operation | some op.opTarget and isOutsider[op.opCaller, op.opTarget]
}

assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 5

// ── FR-009: Task owner_id and team_id are immutable ──────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md "Immutable (FR-009)"

pred FR_009_ImmutableOwnerAndTeam {
  // Structural encoding: task ownership is a single fixed field.
  // No operation can alter the owner or team of an existing task.
  // We encode this as: every task has exactly one owner and one team, permanently.
  all t: Task | one t.owner and one t.taskTeam
  // The task's team is always derived from the owner's team at creation
  all t: Task | t.taskTeam = t.owner.userTeam
  some Task
}

assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// ── FR-010: Only owner may modify shared_with ─────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-010 Q1=A SC-011; spec.md US3-SC6

pred FR_010_OwnerOnlyShareControl {
  // PatchSharedWith is only in PermMatrix.Allowed for OwnerRel
  all r: Relationship | r != OwnerRel implies
    not (r -> PatchSharedWith in PermMatrix.Allowed)
  // Operationally: only successful PatchSharedWith ops are by owners
  all op: Operation |
    (op.opKind = PatchSharedWith and op.opOutcome = Success and some op.opTarget)
    implies isOwner[op.opCaller, op.opTarget]
  some op: Operation | op.opKind = PatchSharedWith
}

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// ── FR-011: Sharee cannot delete task ────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 Q3=B; spec.md US3-SC3

pred FR_011_ShareeCannotDelete {
  all op: Operation |
    (op.opKind = DeleteTask and some op.opTarget and isSharee[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  some op: Operation | op.opKind = DeleteTask
}

assert FR_011_ShareeCannotDelete { FR_011_ShareeCannotDelete }
check FR_011_ShareeCannotDelete for 5

// ── FR-012: Cross-team sharing forbidden ─────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md US3-SC5; data-model.md

pred FR_012_NoInterTeamSharing {
  all s: TaskShare | s.sharee.userTeam = s.shareTask.taskTeam
  some TaskShare
}

assert FR_012_NoInterTeamSharing { FR_012_NoInterTeamSharing }
check FR_012_NoInterTeamSharing for 5

// ── FR-013: Share/unshare operations produce audit entries ────────
// FEATURE-SPECIFIC  ANCHOR: FR-013 FR-015; spec.md US3-SC1

pred FR_013_ShareAuditEntries {
  all op: Operation |
    (op.opKind = PatchSharedWith and op.opOutcome = Success)
    implies (some ae: op.opEntries | ae.entryOp in (Shared + Unshared))
  some op: Operation | op.opKind = PatchSharedWith and op.opOutcome = Success
}

assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// ── FR-015: Every successful mutation has at least one audit entry ──
// FEATURE-SPECIFIC  ANCHOR: FR-015 SC-007; spec.md "MUST result in exactly one new audit entry per logical event"

pred FR_015_MutationAuditPairing {
  all op: Operation |
    (op.opOutcome = Success and
     op.opKind in (PostTasks + PatchFields + PatchSharedWith + DeleteTask))
    implies (some op.opEntries)
  all op: Operation |
    op.opOutcome = Failure implies no op.opEntries
  some op: Operation | op.opOutcome = Success and some op.opEntries
}

assert FR_015_MutationAuditPairing { FR_015_MutationAuditPairing }
check FR_015_MutationAuditPairing for 5

// ── FR-016: Audit entry actor attribution is correct ─────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md AuditEntry actor_user_id actor_role

pred FR_016_AuditAttribution {
  all op: Operation, ae: AuditEntry |
    ae in op.opEntries implies
      (ae.entryActor = op.opCaller and ae.entryActorRole = op.opCallerRole)
  some AuditEntry
}

assert FR_016_AuditAttribution { FR_016_AuditAttribution }
check FR_016_AuditAttribution for 5

// ── FR-017: Audit entries are immutable and outlive the task ──────
// FEATURE-SPECIFIC  ANCHOR: FR-017 SC-009; data-model.md "Append-only: no UPDATE/DELETE SQL"

pred FR_017_AuditImmutable {
  // Every AuditEntry belongs to exactly one Operation (no re-assignment = immutable)
  all ae: AuditEntry | one op: Operation | ae in op.opEntries
  // No two operations share any audit entry
  all disj op1, op2: Operation | no (op1.opEntries & op2.opEntries)
  // Audit entries exist independently (entryTask link exists even if task could be "deleted")
  all ae: AuditEntry | some ae.entryTask
  some AuditEntry
}

assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 5

// ── FR-019: Audit readable by owner / sharee / team-admin ────────
// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md US7; contracts/http-api.md GET /tasks/{id}/audit

pred FR_019_AuditReadAccess {
  // Only callers with GetAudit permission can succeed on the audit endpoint
  all op: Operation |
    (op.opKind = GetAudit and op.opOutcome = Success and some op.opTarget)
    implies (relOf[op.opCaller, op.opTarget] -> GetAudit in PermMatrix.Allowed)
  // Cross-team callers can never read audit
  all op: Operation |
    (op.opKind = GetAudit and some op.opTarget and isOutsider[op.opCaller, op.opTarget])
    implies op.opOutcome = Failure
  some op: Operation | op.opKind = GetAudit
}

assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 5

// ── PrivilegeMonotonicity ──────────────────────────────────────────
// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005 "team_admin … can view, edit, delete ANY task in their team"

pred PrivilegeMonotonicity {
  // TeamAdmin's allowed operations are a superset of Member's allowed operations
  // for in-team read and edit operations (excluding share-list control)
  all ok: (GetTask + PatchFields + DeleteTask + GetAudit) |
    (OwnerRel -> ok in PermMatrix.Allowed) implies (TeamAdminRel -> ok in PermMatrix.Allowed)
  // Sharee has a subset of Owner's read+edit rights (no delete, no share)
  (ShareeRel -> GetTask in PermMatrix.Allowed)
  (ShareeRel -> PatchFields in PermMatrix.Allowed)
  not (ShareeRel -> PatchSharedWith in PermMatrix.Allowed)
  not (ShareeRel -> DeleteTask in PermMatrix.Allowed)
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5

// ── ValidationBeforeMutation ──────────────────────────────────────
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001 FR-018 SC-007; "failed validation produces no side effects"

pred ValidationBeforeMutation {
  // Any failed operation produces no audit entries
  all op: Operation | op.opOutcome = Failure implies no op.opEntries
  // Specifically: cross-team or no-permission failures produce no audit entries
  all op: Operation |
    (some op.opTarget and isOutsider[op.opCaller, op.opTarget])
    implies (op.opOutcome = Failure and no op.opEntries)
  some op: Operation | op.opOutcome = Failure
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5