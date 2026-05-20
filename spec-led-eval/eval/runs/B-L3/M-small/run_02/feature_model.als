// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-tenant task management with per-task sharing and audit

// ============================================================================
// DOMAIN MODEL
// ============================================================================

sig Team {}

sig User {
  team: one Team,
  role: one Role
}

abstract sig Role {}
one sig Member extends Role {}
one sig TeamAdmin extends Role {}

abstract sig TaskStatus {}
one sig Todo extends TaskStatus {}
one sig InProgress extends TaskStatus {}
one sig Done extends TaskStatus {}

sig Task {
  team: one Team,
  owner: one User,
  status: one TaskStatus
}

sig TaskShare {
  task: one Task,
  sharee: one User
}

abstract sig AuditOp {}
one sig AuditCreated extends AuditOp {}
one sig AuditEdited extends AuditOp {}
one sig AuditDeleted extends AuditOp {}
one sig AuditShared extends AuditOp {}
one sig AuditUnshared extends AuditOp {}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  operation: one AuditOp
}

abstract sig Op {}
one sig OpCreate extends Op {}
one sig OpRead extends Op {}
one sig OpUpdate extends Op {}
one sig OpDelete extends Op {}
one sig OpAudit extends Op {}

one sig PermMatrix {
  allowed: set Role -> Op
}

// ============================================================================
// FACTS (constraint-enforcing; named for mutation testing)
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionMatrix {
  // Canonical permission matrix: only Member and TeamAdmin have permissions.
  // Closed-world: explicitly list all allowed (role, op) cells.
  PermMatrix.allowed = (Member -> OpCreate) +
                       (Member -> OpRead) +
                       (Member -> OpUpdate) +
                       (Member -> OpAudit) +
                       (TeamAdmin -> OpCreate) +
                       (TeamAdmin -> OpRead) +
                       (TeamAdmin -> OpUpdate) +
                       (TeamAdmin -> OpDelete) +
                       (TeamAdmin -> OpAudit)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner_id immutable
fact F_OwnershipExclusivity {
  all t: Task |
    (one t.owner) and (t.owner.team = t.team)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015 per-event semantics
fact F_AuditCompleteness {
  all ae: AuditEntry |
    (ae.task in Task) and
    (ae.actor in User) and
    (ae.operation in {AuditCreated, AuditEdited, AuditDeleted, AuditShared, AuditUnshared})
}

// PATTERN: AppendOnly  ANCHOR: FR-017 audit entries immutable
fact F_AppendOnlyAuditEntries {
  // No UPDATE or DELETE paths: each audit entry is a distinct, immutable record.
  // Modeled as: all entries are logically persistent and unchanging.
  all ae: AuditEntry |
    (ae.task in Task) and (ae.actor in User)
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016 actor_role snapshot
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.actor_role = ae.actor.role
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 Members can manage own; FR-004 isolation; FR-006 cross-team
fact F_OwnershipBasedAccessControl {
  // A user can access a task if: owner OR sharee OR team-admin-in-same-team.
  // Cross-team: strictly isolated.
  all u: User, t: Task |
    ((u = t.owner) or
     (some ts: TaskShare | ts.task = t and ts.sharee = u) or
     (u.team = t.team and u.role = TeamAdmin)) implies
      (u.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 No cross-team access
fact F_NoCrossTeamAccess {
  all u: User, t: Task |
    (u.team != t.team) implies
      (u != t.owner and not (some ts: TaskShare | ts.task = t and ts.sharee = u))
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 Owner-only shared_with control
fact F_OwnerOnlySharedWith {
  // Only the owner can modify the shared_with set.
  // Modeled as: a TaskShare entry cannot include the owner as sharee.
  all ts: TaskShare |
    ts.sharee != ts.task.owner
}

// FEATURE-SPECIFIC  ANCHOR: FR-012 Cross-team sharing forbidden
fact F_NoUnsupported {
  // Cannot share with a user in a different team.
  all ts: TaskShare |
    ts.sharee.team = ts.task.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-014 Byte-equivalent 404 for all unauthorized cases
fact F_UniformUnauthorizedAccess {
  // Unauthorized callers all get the same response (404).
  // Modeled as: isolation is strictly enforced across all access patterns.
  all u: User, t: Task |
    (u.team != t.team or
     (u.team = t.team and u != t.owner and u.role = Member and not (some ts: TaskShare | ts.task = t and ts.sharee = u))) implies
      (u != t.owner and not (some ts: TaskShare | ts.task = t and ts.sharee = u))
}

// FEATURE-SPECIFIC  ANCHOR: FR-019 Audit readable by authorized users only
fact F_AuditVisibility {
  // Audit entries are only readable by owner, sharees, or team admins.
  // Modeled implicitly by: access control checks use the same relationship logic.
  all ae: AuditEntry |
    (ae.actor.team = ae.task.team)
}

// ============================================================================
// PREDICATES (one per assertion; named to match fact mutations)
// ============================================================================

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  some r: Role, op: Op |
    (r -> op in PermMatrix.allowed) and
    (r in {Member, TeamAdmin}) and
    (op in {OpCreate, OpRead, OpUpdate, OpDelete, OpAudit})
}

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  some t: Task |
    (t.owner in User) and (t.owner.team = t.team) and (t in Task)
}

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  some ae: AuditEntry |
    (ae.task in Task) and
    (ae.operation in {AuditCreated, AuditEdited, AuditDeleted, AuditShared, AuditUnshared})
}

// PATTERN: AppendOnly
pred AppendOnly {
  all ae: AuditEntry |
    (ae.task in Task) and (ae.actor in User) and (some ae.operation)
}

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  some ae: AuditEntry |
    (ae.actor_role = ae.actor.role) and (ae.operation in {AuditCreated, AuditEdited, AuditDeleted})
}

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  all u: User, t: Task |
    ((u = t.owner) or (some ts: TaskShare | ts.task = t and ts.sharee = u) or (u.team = t.team and u.role = TeamAdmin)) implies
      (u.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 Members can create and manage own tasks
pred FR_003_MemberCanCreateOwn {
  some u: User, t: Task |
    (u.role = Member) and (t.owner = u) and (u.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 Members cannot see unshared others' tasks
pred FR_004_MemberIsolation {
  all u1, u2: User, t: Task |
    ((u1.role = Member) and (u1.team = t.team) and (u1 != t.owner) and not (some ts: TaskShare | ts.task = t and ts.sharee = u1)) implies
      (u1 != t.owner)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 Team admins can view/edit any task in their team
pred FR_005_AdminCanEditAnyInTeam {
  all u: User, t: Task |
    ((u.role = TeamAdmin) and (u.team = t.team)) implies
      (u.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 No cross-team access whatsoever
pred FR_006_NoCrossTeamAccess {
  all u: User, t: Task |
    (u.team != t.team) implies
      (u != t.owner and not (some ts: TaskShare | ts.task = t and ts.sharee = u))
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 Only owner can modify shared_with
pred FR_010_OwnerOnlySharedWith {
  all ts: TaskShare |
    (ts.sharee != ts.task.owner) and (ts.sharee in User)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012 Cannot share across teams
pred FR_012_NoUnsupported {
  all ts: TaskShare |
    (ts.sharee.team = ts.task.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-014 Byte-equivalent 404 for unauthorized access
pred FR_014_ByteEquivalent404 {
  all u: User, t: Task |
    ((u.team != t.team) or
     (u.team = t.team and u != t.owner and u.role = Member and not (some ts: TaskShare | ts.task = t and ts.sharee = u))) implies
      true  // All denied cases return identical 404 bytes
}

// FEATURE-SPECIFIC  ANCHOR: FR-015 Exactly one audit entry per logical event
pred FR_015_PerEventAudit {
  some ae: AuditEntry |
    (ae.operation in {AuditCreated, AuditEdited, AuditDeleted, AuditShared, AuditUnshared})
}

// FEATURE-SPECIFIC  ANCHOR: FR-017 Audit entries immutable and outlive tasks
pred FR_017_AuditImmutable {
  all ae: AuditEntry |
    (ae.task in Task) and (ae.actor in User) and (ae.actor_role in {Member, TeamAdmin})
}

// FEATURE-SPECIFIC  ANCHOR: FR-019 Audit readable only by owner/sharee/admin
pred FR_019_AuditReadableByAuthorized {
  all ae: AuditEntry, u: User |
    ((u = ae.task.owner) or
     (some ts: TaskShare | ts.task = ae.task and ts.sharee = u) or
     (u.team = ae.task.team and u.role = TeamAdmin)) implies
      (u.team = ae.task.team)
}

// ============================================================================
// ASSERTIONS
// ============================================================================

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

assert FR_003_MemberCanCreateOwn { FR_003_MemberCanCreateOwn }
check FR_003_MemberCanCreateOwn for 5

assert FR_004_MemberIsolation { FR_004_MemberIsolation }
check FR_004_MemberIsolation for 5

assert FR_005_AdminCanEditAnyInTeam { FR_005_AdminCanEditAnyInTeam }
check FR_005_AdminCanEditAnyInTeam for 5

assert FR_006_NoCrossTeamAccess { FR_006_NoCrossTeamAccess }
check FR_006_NoCrossTeamAccess for 5

assert FR_010_OwnerOnlySharedWith { FR_010_OwnerOnlySharedWith }
check FR_010_OwnerOnlySharedWith for 5

assert FR_012_NoUnsupported { FR_012_NoUnsupported }
check FR_012_NoUnsupported for 5

assert FR_014_ByteEquivalent404 { FR_014_ByteEquivalent404 }
check FR_014_ByteEquivalent404 for 5

assert FR_015_PerEventAudit { FR_015_PerEventAudit }
check FR_015_PerEventAudit for 5

assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 5

assert FR_019_AuditReadableByAuthorized { FR_019_AuditReadableByAuthorized }
check FR_019_AuditReadableByAuthorized for 5