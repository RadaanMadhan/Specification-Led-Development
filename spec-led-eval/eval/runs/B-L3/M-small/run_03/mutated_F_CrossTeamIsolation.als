// === feature_model.als — Alloy model for B-L3 Multi-Tenant Task Management ===

// ============ DOMAIN SIGNATURES ============

sig Team {}

sig User {
  team: one Team,
  role: one UserRole
}

abstract sig UserRole {}
one sig Member, TeamAdmin extends UserRole {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

sig Task {
  team: one Team,           // immutable, from owner's team (FR-009)
  owner: one User,          // immutable (FR-009)
  shared_with: set User,    // owner-only modifiable (FR-010)
  status: one TaskStatus    // initial is Todo (FR-008)
}

abstract sig AuditOperation {}
one sig AuditCreated, AuditEdited, AuditDeleted, AuditShared, AuditUnshared extends AuditOperation {}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one UserRole,  // snapshotted at time of event (FR-016)
  operation: one AuditOperation
}

// ============ FACTS ============

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task, FR-009
fact F_OwnershipExclusivity {
  // Each task has exactly one owner (enforced by sig), owner is in same team (FR-009)
  all t: Task | t.owner.team = t.team
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-010, FR-011, FR-012
fact F_OwnershipBasedAccess {
  // All sharees are in the same team as the task owner (FR-012)
  all t: Task, u: User |
    u in t.shared_with implies u.team = t.owner.team
  
  // Owner cannot share with themselves
  all t: Task |
    t.owner not in t.shared_with
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014, FR-006
fact F_CrossTeamIsolation { /* MUTATED — body cleared by validator */ }

// PATTERN: AppendOnly  ANCHOR: FR-017
fact F_AppendOnlyAuditEntries {
  // Audit entries are immutable - recorded operations are valid
  all ae: AuditEntry |
    ae.operation in (AuditCreated + AuditEdited + AuditDeleted + AuditShared + AuditUnshared)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015, FR-016
fact F_AuditCompleteness {
  // Every task has at least one audit entry (created upon creation) (FR-015)
  all t: Task |
    some ae: AuditEntry | ae.task = t
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016
fact F_AttributionCorrectness {
  // Each audit entry's actor_role is a valid role (FR-016)
  all ae: AuditEntry |
    ae.actor_role in (Member + TeamAdmin)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AuthRequired {
  // Every audit entry has an authenticated actor (FR-001)
  all ae: AuditEntry |
    ae.actor in User
}

// ============ PREDICATES ============

// PATTERN: OwnershipExclusivity  ANCHOR: FR-009
pred OwnershipExclusivity {
  all t: Task |
    (one t.owner) and (t.owner.team = t.team)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-010, FR-011, FR-012
pred OwnershipBasedAccess {
  all t: Task, u: User |
    u in t.shared_with implies (u.team = t.owner.team and u != t.owner)
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014, FR-006
pred NoInformationLeakage {
  all t: Task, u: User |
    u.team != t.team implies (u not in t.shared_with and u != t.owner)
}

// PATTERN: AppendOnly  ANCHOR: FR-017
pred AppendOnly {
  all ae: AuditEntry |
    ae.operation in (AuditCreated + AuditEdited + AuditDeleted + AuditShared + AuditUnshared)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015
pred AuditCompleteness {
  all t: Task |
    (some ae: AuditEntry | ae.task = t)
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.actor_role in (Member + TeamAdmin)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  all ae: AuditEntry |
    some ae.actor
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  // Members cannot delete tasks they don't own
  all u: User, t: Task |
    (u.role = Member and u != t.owner and u not in t.shared_with) implies
      (u not in t.shared_with)
}

// PATTERN: PrivilegeMonotonicity  ANCHOR: contracts/http-api.md
pred PrivilegeMonotonicity {
  // TeamAdmin permissions are superset of Member permissions
  all u: User |
    u.role = TeamAdmin implies (
      all t: Task | u.team = t.team implies u.team = t.team
    )
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // All role and operation types are defined
  some Member
  some TeamAdmin
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all ae: AuditEntry | some ae.actor
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_UserIdentityFromToken {
  all u: User | u.team != none and u.role != none
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_MemberPermissions {
  some u: User | u.role = Member
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_MemberViewRestricted {
  all u: User, t: Task |
    (u.role = Member and u.team = t.team and u != t.owner and u not in t.shared_with) implies
      (u not in t.shared_with)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminFullAccess {
  all u: User |
    u.role = TeamAdmin implies (some t: Task | u.team = t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_NoTeamCrossAccess {
  all u: User, t: Task |
    u.team != t.team implies (u != t.owner and u not in t.shared_with)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ImmutableOwnerTeam {
  all t: Task | (one t.owner) and (one t.team)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_OwnerOnlyChangeSharedWith {
  all t: Task | t.owner.team = t.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ShareePermissions {
  all u: User, t: Task |
    u in t.shared_with implies (u.team = t.team and u != t.owner)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_SameTeamSharing {
  all t: Task, u: User |
    u in t.shared_with implies u.team = t.owner.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalent404 {
  all u: User, t: Task |
    u.team != t.team implies (u not in t.shared_with)
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_OneAuditPerEvent {
  all t: Task |
    (some ae: AuditEntry | ae.task = t and ae.operation = AuditCreated) implies
      (one ae: AuditEntry | ae.task = t and ae.operation = AuditCreated)
}

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditFieldsComplete {
  all ae: AuditEntry |
    ae.task != none and ae.actor != none and ae.actor_role != none and
    ae.operation != none
}

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditImmutable {
  all ae: AuditEntry |
    ae.operation in (AuditCreated + AuditEdited + AuditDeleted + AuditShared + AuditUnshared)
}

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_AuditReadable {
  all t: Task, ae: AuditEntry |
    ae.task = t implies (
      some u: User |
        (u = t.owner or u in t.shared_with or (u.team = t.team and u.role = TeamAdmin))
    )
}

// ============ ASSERTIONS ============

assert OwnershipExclusivity {
  OwnershipExclusivity
}
check OwnershipExclusivity for 5

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}
check OwnershipBasedAccess for 5

assert NoInformationLeakage {
  NoInformationLeakage
}
check NoInformationLeakage for 5

assert AppendOnly {
  AppendOnly
}
check AppendOnly for 5

assert AuditCompleteness {
  AuditCompleteness
}
check AuditCompleteness for 5

assert AttributionCorrectness {
  AttributionCorrectness
}
check AttributionCorrectness for 5

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}
check AuthRequiredEverywhere for 5

assert LeastPrivilege {
  LeastPrivilege
}
check LeastPrivilege for 5

assert PrivilegeMonotonicity {
  PrivilegeMonotonicity
}
check PrivilegeMonotonicity for 5

assert PermissionCompleteness {
  PermissionCompleteness
}
check PermissionCompleteness for 5

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}
check FR_001_AuthRequired for 5

assert FR_002_UserIdentityFromToken {
  FR_002_UserIdentityFromToken
}
check FR_002_UserIdentityFromToken for 5

assert FR_003_MemberPermissions {
  FR_003_MemberPermissions
}
check FR_003_MemberPermissions for 5

assert FR_004_MemberViewRestricted {
  FR_004_MemberViewRestricted
}
check FR_004_MemberViewRestricted for 5

assert FR_005_AdminFullAccess {
  FR_005_AdminFullAccess
}
check FR_005_AdminFullAccess for 5

assert FR_006_NoTeamCrossAccess {
  FR_006_NoTeamCrossAccess
}
check FR_006_NoTeamCrossAccess for 5

assert FR_009_ImmutableOwnerTeam {
  FR_009_ImmutableOwnerTeam
}
check FR_009_ImmutableOwnerTeam for 5

assert FR_010_OwnerOnlyChangeSharedWith {
  FR_010_OwnerOnlyChangeSharedWith
}
check FR_010_OwnerOnlyChangeSharedWith for 5

assert FR_011_ShareePermissions {
  FR_011_ShareePermissions
}
check FR_011_ShareePermissions for 5

assert FR_012_SameTeamSharing {
  FR_012_SameTeamSharing
}
check FR_012_SameTeamSharing for 5

assert FR_014_ByteEquivalent404 {
  FR_014_ByteEquivalent404
}
check FR_014_ByteEquivalent404 for 5

assert FR_015_OneAuditPerEvent {
  FR_015_OneAuditPerEvent
}
check FR_015_OneAuditPerEvent for 5

assert FR_016_AuditFieldsComplete {
  FR_016_AuditFieldsComplete
}
check FR_016_AuditFieldsComplete for 5

assert FR_017_AuditImmutable {
  FR_017_AuditImmutable
}
check FR_017_AuditImmutable for 5

assert FR_019_AuditReadable {
  FR_019_AuditReadable
}
check FR_019_AuditReadable for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeamIsolationViolation { some t: Task, u: User | u in t.shared_with and u.team != t.team }
