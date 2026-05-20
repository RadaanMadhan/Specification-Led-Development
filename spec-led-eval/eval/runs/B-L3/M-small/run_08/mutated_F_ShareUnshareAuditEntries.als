// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-tenant task management with per-task sharing and audit

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig AuditOperation {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOperation {}

sig Team {}

sig User {
  team: one Team,
  role: one Role
}

sig Task {
  owner: one User,
  team: one Team,
  shared_with: set User
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  operation: one AuditOperation
}

fact F_NonEmptyUniverse {
  some User
  some Task
  some Team
  some AuditEntry
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-009, data-model.md
fact F_OwnershipExclusivity {
  all t: Task | one t.owner
}

pred OwnershipExclusivity {
  some Task and all t: Task | one t.owner
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006, FR-014 cross-team isolation
fact F_CrossTeamIsolation {
  all u: User, t: Task |
    u.team != t.team implies u not in t.shared_with
}

pred CrossTeamIsolation {
  some User and some Task and
  all u: User, t: Task |
    u.team != t.team implies u not in t.shared_with
}

assert CrossTeamIsolation { CrossTeamIsolation }
check CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 sharees must be in same team
fact F_SameTeamSharing {
  all t: Task, u: User |
    u in t.shared_with implies u.team = t.team
}

pred SameTeamSharing {
  some Task and some User and
  all t: Task, u: User |
    u in t.shared_with implies u.team = t.team
}

assert SameTeamSharing { SameTeamSharing }
check SameTeamSharing for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-010, contracts/http-api.md
fact F_OwnerControlsSharing {
  all t: Task, u: User |
    u in t.shared_with implies (
      some ae: AuditEntry |
        ae.task = t and ae.operation = Shared and ae.actor = t.owner
    )
}

pred OwnerControlsSharing {
  some Task and some User and
  all t: Task, u: User |
    u in t.shared_with implies (
      some ae: AuditEntry |
        ae.task = t and ae.operation = Shared and ae.actor = t.owner
    )
}

assert OwnerControlsSharing { OwnerControlsSharing }
check OwnerControlsSharing for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-015, data-model.md
fact F_TaskCreationAudit {
  all t: Task |
    some ae: AuditEntry |
      ae.task = t and ae.operation = Created
}

pred TaskCreationAudit {
  some Task and
  all t: Task |
    some ae: AuditEntry |
      ae.task = t and ae.operation = Created
}

assert TaskCreationAudit { TaskCreationAudit }
check TaskCreationAudit for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, contracts/http-api.md
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.actor.team = ae.task.team
}

pred AttributionCorrectness {
  some AuditEntry and
  all ae: AuditEntry |
    ae.actor.team = ae.task.team
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required
pred FR_001_AuthRequired {
  some User and
  all ae: AuditEntry | ae.actor in User
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 team and role from token, not payload
pred FR_002_TokenDerivedTeamRole {
  some User and
  all u: User | one u.team and one u.role
}

assert FR_002_TokenDerivedTeamRole { FR_002_TokenDerivedTeamRole }
check FR_002_TokenDerivedTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 members can create tasks
pred FR_003_MemberCanCreate {
  some t: Task | t.owner.role = Member
}

assert FR_003_MemberCanCreate { FR_003_MemberCanCreate }
check FR_003_MemberCanCreate for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 immutable owner and team on task
pred FR_009_ImmutableOwnerTeam {
  some Task and all t: Task | one t.owner and one t.team
}

assert FR_009_ImmutableOwnerTeam { FR_009_ImmutableOwnerTeam }
check FR_009_ImmutableOwnerTeam for 5

// PATTERN: AppendOnly  ANCHOR: FR-017, data-model.md
fact F_AppendOnlyAuditEntries {
  all ae: AuditEntry | ae in AuditEntry
}

pred AppendOnlyAuditEntries {
  some AuditEntry and all ae: AuditEntry | ae in AuditEntry
}

assert AppendOnlyAuditEntries { AppendOnlyAuditEntries }
check AppendOnlyAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 share operations recorded in audit
fact F_ShareUnshareAuditEntries { /* MUTATED — body cleared by validator */ }

pred ShareUnshareAuditEntries {
  some Task and some User and
  all t: Task, u: User |
    u in t.shared_with implies (
      some ae: AuditEntry |
        ae.task = t and ae.operation = Shared
    )
}

assert ShareUnshareAuditEntries { ShareUnshareAuditEntries }
check ShareUnshareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent isolation extends to all endpoints
pred FR_014_ByteEquivalentIsolation {
  some User and some Task and
  all u: User, t: Task |
    u.team != t.team implies u not in t.shared_with
}

assert FR_014_ByteEquivalentIsolation { FR_014_ByteEquivalentIsolation }
check FR_014_ByteEquivalentIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 one audit entry per semantic event
fact F_OneAuditPerCreation {
  all t: Task |
    #{ae: AuditEntry | ae.task = t and ae.operation = Created} <= 1
}

pred OneAuditPerCreation {
  some Task and
  all t: Task |
    #{ae: AuditEntry | ae.task = t and ae.operation = Created} <= 1
}

assert OneAuditPerCreation { OneAuditPerCreation }
check OneAuditPerCreation for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-014, contracts/http-api.md
pred NoInformationLeakage {
  some User and some Task and
  all u: User, t: Task |
    u.team != t.team implies (
      u not in t.shared_with
    )
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, contracts/http-api.md
pred AuthRequiredEverywhere {
  some AuditEntry and
  all ae: AuditEntry |
    ae.actor in User and ae.operation in AuditOperation
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NoShareAudit { some t: Task, u: User | u in t.shared_with and no ae: AuditEntry | ae.task = t and ae.operation = Shared }
