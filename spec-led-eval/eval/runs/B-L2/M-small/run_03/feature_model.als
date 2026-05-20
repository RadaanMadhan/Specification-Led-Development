// === feature_model.als — Alloy model for 007-team-tasks ===
// SaaS Team Task Management with Audit Trail

// === SIGNATURES ===

// Core entity sigs
abstract sig User {}
abstract sig Team {}

// Role enum
abstract sig Role {}
one sig Member, Admin extends Role {}

// Task status enum
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Change description type
abstract sig ChangeType {}
one sig Created, Modified, Deleted extends ChangeType {}

// Dynamic sigs (require non-empty universe witness)
sig TeamMembership {
  user: one User,
  team: one Team,
  role: one Role
}

sig Task {
  id: one Int,
  team: one Team,
  title: one String,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus,
  created_at: one Int,
  updated_at: one Int
}

sig AuditEntry {
  taskId: one Int,
  team: one Team,
  task: lone Task,
  actor: one User,
  actorRole: one Role,
  changeType: one ChangeType,
  occurredAt: one Int
}

// Permission matrix singleton
one sig PermMatrix {
  allowed: set Role -> String
}

// === FACTS ===

// F_NonEmptyUniverse: At least one of each dynamic sig must exist
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008, FR-009, FR-010
fact F_PermissionMatrix {
  // Allowed operations per role
  Member -> "POST_tasks" in PermMatrix.allowed
  Admin -> "POST_tasks" in PermMatrix.allowed
  Member -> "GET_tasks_list" in PermMatrix.allowed
  Admin -> "GET_tasks_list" in PermMatrix.allowed
  Member -> "GET_task_by_id" in PermMatrix.allowed
  Admin -> "GET_task_by_id" in PermMatrix.allowed
  Admin -> "PATCH_tasks" in PermMatrix.allowed
  Admin -> "DELETE_tasks" in PermMatrix.allowed
  Member -> "GET_audit" in PermMatrix.allowed
  Admin -> "GET_audit" in PermMatrix.allowed
  
  // Closed-world assumption: only these cells are allowed
  PermMatrix.allowed = (Member -> "POST_tasks") + (Admin -> "POST_tasks") +
                       (Member -> "GET_tasks_list") + (Admin -> "GET_tasks_list") +
                       (Member -> "GET_task_by_id") + (Admin -> "GET_task_by_id") +
                       (Admin -> "PATCH_tasks") + (Admin -> "DELETE_tasks") +
                       (Member -> "GET_audit") + (Admin -> "GET_audit")
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md authentication
fact F_AuthenticationRequired {
  all a: AuditEntry | some u: User | a.actor = u
  all t: Task | some u: User | t.owner = u
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015; data-model.md AuditEntry
fact F_AuditCompleteness {
  all t: Task | one a: AuditEntry | a.task = t and a.changeType = Created
}

// PATTERN: AppendOnly  ANCHOR: FR-016, FR-018; contracts/http-api.md audit immutability
fact F_AppendOnlyAuditEntries {
  all disj a1, a2: AuditEntry | a1.taskId = a2.taskId implies (a1.occurredAt != a2.occurredAt)
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-015; data-model.md actor snapshot
fact F_AttributionCorrectness {
  all a: AuditEntry | (some u: User | a.actor = u) and (some r: Role | a.actorRole = r)
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006; data-model.md owner column
fact F_OwnershipExclusivity {
  all t: Task | one u: User | t.owner = u
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008, FR-009, FR-010; contracts/http-api.md permission matrix
fact F_OwnershipBasedAccess {
  all t: Task | all tm: TeamMembership | (
    tm.team = t.team
  ) implies (
    (tm.user = t.owner and tm.role = Member) implies (
      tm.user in editableBy[t] and tm.user in deletableBy[t]
    )
  ) and (
    tm.role = Admin implies (tm.user in editableBy[t] and tm.user in deletableBy[t])
  )
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014; contracts/http-api.md byte-equivalent 404
fact F_NoInformationLeakage {
  all t: Task | all u: User | (
    (no tm: TeamMembership | tm.user = u and tm.team = t.team)
  ) implies (
    u not in viewableBy[t]
  )
}

// FEATURE-SPECIFIC  ANCHOR: FR-005; data-model.md task.team_id immutable
fact F_TaskTeamImmutable {
  all t: Task | all a: AuditEntry | (
    a.task = t and a.changeType = Created
  ) implies (a.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006; data-model.md owner_id immutable
fact F_OwnerImmutable {
  all t: Task | all a: AuditEntry | (
    a.task = t and a.changeType = Created
  ) implies (a.actor = t.owner)
}

// FEATURE-SPECIFIC  ANCHOR: FR-007; data-model.md TeamMembership composite key
fact F_RolePerTeam {
  all disj tm1, tm2: TeamMembership | (
    tm1.user = tm2.user and tm1.team = tm2.team
  ) implies (tm1 = tm2)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md assignee_id FK constraint
fact F_AssigneeTeamMembership {
  all t: Task | (some a: t.assignee) implies (
    some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team
  )
}

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md status CHECK constraint
fact F_StatusSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004; contracts/http-api.md team context
fact F_TeamContextRequired {
  all t: Task | some tm: TeamMembership | tm.user = t.owner and tm.team = t.team
}

// === PREDICATES & ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
  some Role
  (some r: Role | some op: String | (r -> op in PermMatrix.allowed))
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  all r: Role | all op: String | (
    (r -> op in PermMatrix.allowed) or (r -> op not in PermMatrix.allowed)
  )
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  some Task
  some AuditEntry
  all t: Task | (some a: AuditEntry | a.task = t and a.changeType = Created and (some u: User | a.actor = u))
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-015
pred AuditCompleteness {
  some Task
  some AuditEntry
  all t: Task | (one a: AuditEntry | a.task = t and a.changeType = Created)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-016, FR-018
pred AppendOnly {
  some AuditEntry
  all disj a1, a2: AuditEntry | a1.taskId = a2.taskId implies (a1.occurredAt != a2.occurredAt)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-015
pred AttributionCorrectness {
  some AuditEntry
  all a: AuditEntry | ((some u: User | a.actor = u) and (some r: Role | a.actorRole = r))
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-006
pred OwnershipExclusivity {
  some Task
  all t: Task | (one u: User | t.owner = u)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-008, FR-009, FR-010
pred OwnershipBasedAccess {
  some Task
  some TeamMembership
  all t: Task | all tm: TeamMembership | (
    tm.team = t.team and tm.user = t.owner
  ) implies (tm.user in editableBy[t])
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-014
pred NoInformationLeakage {
  some Task
  some User
  all t: Task | all u: User | (
    (no tm: TeamMembership | tm.user = u and tm.team = t.team)
  ) implies (u not in viewableBy[t])
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TaskTeamImmutable {
  some Task
  some AuditEntry
  all t: Task | all a: AuditEntry | (
    a.task = t and a.changeType = Created
  ) implies (a.team = t.team)
}

assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_OwnerImmutable {
  some Task
  some AuditEntry
  all t: Task | all a: AuditEntry | (
    a.task = t and a.changeType = Created
  ) implies (a.actor = t.owner)
}

assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_RolePerTeam {
  some TeamMembership
  all u: User | all tm: Team | (lone tm2: TeamMembership | tm2.user = u and tm2.team = tm)
}

assert FR_007_RolePerTeam { FR_007_RolePerTeam }
check FR_007_RolePerTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, FR-009, FR-010
pred FR_008_009_010_EditDeletePermissions {
  some Task
  some TeamMembership
  all t: Task | all tm: TeamMembership | (
    tm.team = t.team and tm.role = Member and tm.user != t.owner
  ) implies (
    (tm.user not in editableBy[t]) and (tm.user not in deletableBy[t])
  )
}

assert FR_008_009_010_EditDeletePermissions { FR_008_009_010_EditDeletePermissions }
check FR_008_009_010_EditDeletePermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-014
pred FR_011_CrossTeamIsolation {
  some Task
  some User
  all t: Task | all u: User | (
    (no tm: TeamMembership | tm.user = u and tm.team = t.team)
  ) implies (u not in accessibleBy[t])
}

assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_TaskValidation {
  some Task
  all t: Task | ((some a: t.assignee) implies (
    some tm: TeamMembership | tm.user = t.assignee and tm.team = t.team
  ))
}

assert FR_012_TaskValidation { FR_012_TaskValidation }
check FR_012_TaskValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_StatusSet {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}

assert FR_013_StatusSet { FR_013_StatusSet }
check FR_013_StatusSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalent404 {
  some Task
  some User
  all t: Task | all u: User | (
    (no tm: TeamMembership | tm.user = u and tm.team = t.team)
  ) implies (u not in viewableBy[t])
}

assert FR_014_ByteEquivalent404 { FR_014_ByteEquivalent404 }
check FR_014_ByteEquivalent404 for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditTrailPerEditEvent {
  some Task
  some AuditEntry
  all t: Task | (one a: AuditEntry | a.task = t and a.changeType = Created)
}

assert FR_015_AuditTrailPerEditEvent { FR_015_AuditTrailPerEditEvent }
check FR_015_AuditTrailPerEditEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditImmutable {
  some AuditEntry
  all disj a1, a2: AuditEntry | a1.taskId = a2.taskId implies (a1.occurredAt != a2.occurredAt)
}

assert FR_016_AuditImmutable { FR_016_AuditImmutable }
check FR_016_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditVisibility {
  some AuditEntry
  some TeamMembership
  all a: AuditEntry | all tm: TeamMembership | (
    tm.team = a.team
  ) implies (tm.user in auditViewableBy[a])
}

assert FR_017_AuditVisibility { FR_017_AuditVisibility }
check FR_017_AuditVisibility for 5

// === HELPER FUNCTIONS ===

fun editableBy[t: Task]: set User {
  {u: User | u = t.owner or (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Admin)}
}

fun deletableBy[t: Task]: set User {
  {u: User | u = t.owner or (some tm: TeamMembership | tm.user = u and tm.team = t.team and tm.role = Admin)}
}

fun viewableBy[t: Task]: set User {
  {u: User | some tm: TeamMembership | tm.user = u and tm.team = t.team}
}

fun accessibleBy[t: Task]: set User {
  {u: User | some tm: TeamMembership | tm.user = u and tm.team = t.team}
}

fun auditViewableBy[a: AuditEntry]: set User {
  {u: User | some tm: TeamMembership | tm.user = u and tm.team = a.team}
}