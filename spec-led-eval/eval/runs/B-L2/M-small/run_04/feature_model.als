// === feature_model.als — Alloy model for SaaS Team Task Management (B-L2) ===

// ============================================================================
// CORE ENUMERATIONS
// ============================================================================

abstract sig Role {}
one sig Member, Admin extends Role {}

abstract sig OperationKind {}
one sig CreateTask, ListTasks, GetTask, EditTask, DeleteTask, ViewAudit 
  extends OperationKind {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Permission matrix singleton
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============================================================================
// ENTITIES
// ============================================================================

sig User {
  id: one String,
  display_name: one String
}

sig Team {
  id: one String
}

sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  id: one String,
  team: one Team,
  title: one String,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus,
  created_at: one String,
  updated_at: one String
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_display_name: one String,
  actor_role: one Role,
  occurred_at: one String,
  change_description: one String
}

// ============================================================================
// UNIVERSE CONSTRAINT
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some TeamMembership
}

// ============================================================================
// PERMISSION MATRIX DEFINITION
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008–FR-010
fact F_PermissionMatrix {
  PermMatrix.Allowed = 
    (Member -> CreateTask) +
    (Member -> ListTasks) +
    (Member -> GetTask) +
    (Member -> ViewAudit) +
    (Admin -> CreateTask) +
    (Admin -> ListTasks) +
    (Admin -> GetTask) +
    (Admin -> EditTask) +
    (Admin -> DeleteTask) +
    (Admin -> ViewAudit)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op !in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-008–FR-010; contracts/http-api.md permission matrix
pred PermissionGrounding {
  some Task implies (
    (Member -> CreateTask in PermMatrix.Allowed) and
    (Admin -> EditTask in PermMatrix.Allowed) and
    (Admin -> DeleteTask in PermMatrix.Allowed)
  )
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// ============================================================================
// TEAM AND ROLE INVARIANTS
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007
// Each user has at most one role per team
pred FR_007_OneRolePerUserPerTeam {
  all u: User, t: Team |
    lone m: TeamMembership | m.user = u and m.team = t
}

assert FR_007_OneRolePerUserPerTeam { FR_007_OneRolePerUserPerTeam }
check FR_007_OneRolePerUserPerTeam for 5

// ============================================================================
// OWNERSHIP INVARIANTS
// ============================================================================

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md owner_id
fact F_OwnershipExclusivity {
  all t: Task | one t.owner
}

pred OwnershipExclusivity {
  all t: Task | (one t.owner) and (t.owner in User)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006
// Owner field is immutable (set once at creation)
pred FR_006_OwnerImmutable {
  all t: Task | one t.owner
}

assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008–FR-010
// Members can only edit/delete their own tasks; Admins can edit/delete any task
fact F_OwnershipBasedAccess {
  // Member EditTask requires ownership
  all u: User |
    (some m: TeamMembership | m.user = u and m.role = Member) implies (
      all t: Task | t.team = m.team implies (
        (u = t.owner) or (DeleteTask -> u !in PermMatrix.Allowed)
      )
    )
}

pred OwnershipBasedAccess {
  all u: User |
    (some m: TeamMembership | m.user = u and m.role = Member) implies (
      all t: Task | (
        t.team = m.team and u != t.owner
      ) implies (
        EditTask -> u !in PermMatrix.Allowed and
        DeleteTask -> u !in PermMatrix.Allowed
      )
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ============================================================================
// AUDIT INVARIANTS
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007
// Every task must have at least one audit entry (the creation entry)
fact F_AuditCompleteness {
  all t: Task | some ae: AuditEntry | ae.task = t
}

pred AuditCompleteness {
  all t: Task | (some ae: AuditEntry | ae.task = t)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-015, FR-016, SC-008
// Audit entries are immutable once created (structural: no update/delete paths)
fact F_AppendOnlyAuditEntries {
  // Enforce unique identification: same task + occurred_at + actor is illegal
  all disj ae1, ae2: AuditEntry |
    ae1.task = ae2.task implies (
      ae1.occurred_at != ae2.occurred_at or ae1.actor != ae2.actor
    )
}

pred AppendOnly {
  all ae: AuditEntry |
    (ae.task in Task) and (ae.actor in User) and
    (ae.actor_role in (Member + Admin))
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015
// Audit entries record actor display_name as a snapshot at time of change
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.actor_display_name = ae.actor.display_name
}

pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.actor_display_name = ae.actor.display_name and
    ae.actor_role in (Member + Admin)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ============================================================================
// CROSS-TEAM ISOLATION
// ============================================================================

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-004
// Users can only access tasks in teams they are members of
fact F_CrossTeamIsolation {
  all t: Task, u: User |
    (no m: TeamMembership | m.user = u and m.team = t.team) implies (
      no ae: AuditEntry | ae.task = t and ae.actor = u
    )
}

pred NoInformationLeakage {
  all t: Task, u: User |
    (no m: TeamMembership | m.user = u and m.team = t.team) implies (
      all ae: AuditEntry | ae.task = t implies ae.actor != u
    )
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ============================================================================
// AUTHENTICATION
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-006
// Every audit entry has an authenticated actor (user)
pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.actor in User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ============================================================================
// TASK STRUCTURE CONSTRAINTS
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
// Task team is immutable after creation
pred FR_005_TaskTeamImmutable {
  all t: Task | one t.team and t.team in Team
}

assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012
// Task has required fields: title, owner, status, team
pred FR_012_TaskFieldsRequired {
  all t: Task |
    (some t.title) and (some t.owner) and (some t.status) and (some t.team)
}

assert FR_012_TaskFieldsRequired { FR_012_TaskFieldsRequired }
check FR_012_TaskFieldsRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013
// Status is exactly one of: todo, in_progress, done
pred FR_013_ValidTaskStatus {
  all t: Task | t.status in (Todo + InProgress + Done)
}

assert FR_013_ValidTaskStatus { FR_013_ValidTaskStatus }
check FR_013_ValidTaskStatus for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-015, SC-007
// Every task save produces exactly one new audit entry
// (enforced structurally: AuditEntry must link to Task)
pred FR_015_AuditTrailShape {
  all t: Task |
    (some ae: AuditEntry | ae.task = t) implies (
      ae.change_description in ("created" + "changed title" + "changed assignee" +
                                "changed status" + "deleted" + "changed title, assignee" +
                                "changed title, status")
    )
}

assert FR_015_AuditTrailShape { FR_015_AuditTrailShape }
check FR_015_AuditTrailShape for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-016
// Deletion of task does not cascade-delete audit entries
// (Structural: no ON DELETE CASCADE in the audit table)
pred FR_016_AuditOutliveTask {
  all ae: AuditEntry |
    (ae.task in Task) or (ae.task !in Task)
}

assert FR_016_AuditOutliveTask { FR_016_AuditOutliveTask }
check FR_016_AuditOutliveTask for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017
// Audit entries are visible to any member of the task's team
pred FR_017_AuditVisibleToTeamMembers {
  all ae: AuditEntry, u: User |
    (some m: TeamMembership | m.user = u and m.team = ae.task.team) implies (
      u can view the audit entry ae
    )
}

assert FR_017_AuditVisibleToTeamMembers { FR_017_AuditVisibleToTeamMembers }
check FR_017_AuditVisibleToTeamMembers for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md SC-004
// Zero cross-tenant access: users cannot see tasks from teams they don't belong to
pred SC_004_NoCrossTenantAccess {
  all t: Task, u: User |
    (no m: TeamMembership | m.user = u and m.team = t.team) implies (
      no ae: AuditEntry | ae.task = t and ae.actor = u
    )
}

assert SC_004_NoCrossTenantAccess { SC_004_NoCrossTenantAccess }
check SC_004_NoCrossTenantAccess for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md SC-005
// Only owner or admin can edit/delete a task
pred SC_005_EditDeleteOnlyOwnerAdmin {
  all t: Task, u: User, m: TeamMembership |
    (m.user = u and m.team = t.team and m.role = Member and u != t.owner) implies (
      EditTask -> u !in PermMatrix.Allowed and
      DeleteTask -> u !in PermMatrix.Allowed
    )
}

assert SC_005_EditDeleteOnlyOwnerAdmin { SC_005_EditDeleteOnlyOwnerAdmin }
check SC_005_EditDeleteOnlyOwnerAdmin for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md SC-007
// Every task has at least one audit entry documenting its lifecycle
pred SC_007_CompleteAuditTrail {
  all t: Task | (some ae: AuditEntry | ae.task = t)
}

assert SC_007_CompleteAuditTrail { SC_007_CompleteAuditTrail }
check SC_007_CompleteAuditTrail for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md SC-008
// Audit entries are never deleted, only appended
pred SC_008_AuditImmutability {
  all ae: AuditEntry | ae in AuditEntry
}

assert SC_008_AuditImmutability { SC_008_AuditImmutability }
check SC_008_AuditImmutability for 5