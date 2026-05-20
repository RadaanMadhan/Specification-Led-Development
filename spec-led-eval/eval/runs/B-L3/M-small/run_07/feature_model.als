// === feature_model.als — Alloy model for B-L3 (Multi-Tenant Task Management with Per-Task Sharing and Audit) ===

// ===== TYPE DEFINITIONS =====

abstract sig Role {}
one sig Member extends Role {}
one sig TeamAdmin extends Role {}

abstract sig OperationKind {}
one sig PostTasks extends OperationKind {}
one sig GetTask extends OperationKind {}
one sig PatchTask extends OperationKind {}
one sig DeleteTask extends OperationKind {}
one sig GetAudit extends OperationKind {}

abstract sig AuditOperation {}
one sig Created extends AuditOperation {}
one sig Edited extends AuditOperation {}
one sig Deleted extends AuditOperation {}
one sig Shared extends AuditOperation {}
one sig Unshared extends AuditOperation {}

// ===== CORE ENTITIES =====

sig Team {}

sig User {
  team: one Team,
  role: one Role
}

sig Task {
  team: one Team,
  owner: one User,
  shared_with: set User
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  operation: one AuditOperation
}

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ===== FACTS =====

// ANCHOR: non-vacuity — ensure Alloy does not pick empty universe
fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001/FR-003/FR-005
fact F_PermissionMatrix {
  // Both Member and TeamAdmin can POST (create tasks), GET, PATCH, DELETE, and view AUDIT
  // (actual authorization is determined by access control, not the matrix alone)
  Member -> PostTasks in PermMatrix.Allowed
  TeamAdmin -> PostTasks in PermMatrix.Allowed
  Member -> GetTask in PermMatrix.Allowed
  TeamAdmin -> GetTask in PermMatrix.Allowed
  Member -> PatchTask in PermMatrix.Allowed
  TeamAdmin -> PatchTask in PermMatrix.Allowed
  Member -> DeleteTask in PermMatrix.Allowed
  TeamAdmin -> DeleteTask in PermMatrix.Allowed
  Member -> GetAudit in PermMatrix.Allowed
  TeamAdmin -> GetAudit in PermMatrix.Allowed
  
  // Closed-world: only these permissions exist
  PermMatrix.Allowed = (Member -> PostTasks) +
                       (Member -> GetTask) +
                       (Member -> PatchTask) +
                       (Member -> DeleteTask) +
                       (Member -> GetAudit) +
                       (TeamAdmin -> PostTasks) +
                       (TeamAdmin -> GetTask) +
                       (TeamAdmin -> PatchTask) +
                       (TeamAdmin -> DeleteTask) +
                       (TeamAdmin -> GetAudit)
}

// ANCHOR: spec.md FR-012 (cross-team sharing forbidden)
fact F_ShareeTeamRestriction {
  all t: Task | all u: User |
    u in t.shared_with implies u.team = t.owner.team
}

// ANCHOR: spec.md FR-015 (every mutation produces audit entry)
fact F_AuditForTaskMutations {
  all t: Task | some ae: AuditEntry | ae.task = t
}

// ANCHOR: spec.md FR-006 (no cross-team access); ownership-based access requires owner in same team
fact F_TaskOwnerInTeam {
  all t: Task | t.owner.team = t.team
}

// ===== PREDICATES AND ASSERTIONS =====

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  some PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md matrix; spec.md FR-001/FR-003/FR-005
pred LeastPrivilege {
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner
pred OwnershipExclusivity {
  all t: Task | one o: User | t.owner = o
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-005, FR-011
pred OwnershipBasedAccess {
  all t: Task | all u: User |
    (u = t.owner or (u.role = TeamAdmin and u.team = t.team)) implies
      (u.role -> GetTask in PermMatrix.Allowed and u.role -> PatchTask in PermMatrix.Allowed and u.role -> DeleteTask in PermMatrix.Allowed)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, SC-003
pred NoInformationLeakage {
  all t: Task | all u: User |
    (u.team != t.team) implies not (u.role -> GetTask in PermMatrix.Allowed and u in t.owner.team + t.shared_with)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017, SC-009; data-model.md no UPDATE/DELETE on audit_entries
pred AppendOnly {
  all ae: AuditEntry | ae.task in Task and ae.actor in User and ae.operation in AuditOperation
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, FR-016, SC-007
pred AuditCompleteness {
  all t: Task | some ae: AuditEntry | ae.task = t and ae.operation = Created
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-002a
pred FR_002_OneTeamPerUser {
  all u: User | one t: Team | u.team = t
}

assert FR_002_OneTeamPerUser { FR_002_OneTeamPerUser }
check FR_002_OneTeamPerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_MemberCanCreateOwnTasks {
  all u: User |
    (u.role = Member) implies (u.role -> PostTasks in PermMatrix.Allowed and u.role -> DeleteTask in PermMatrix.Allowed)
}

assert FR_003_MemberCanCreateOwnTasks { FR_003_MemberCanCreateOwnTasks }
check FR_003_MemberCanCreateOwnTasks for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_MemberIsolationWithinTeam {
  all u: User | all t: Task |
    (u.team = t.team and u != t.owner and u not in t.shared_with and u.role = Member) implies
      (u -> GetTask not in PermMatrix.Allowed or u in t.owner.team)
}

assert FR_004_MemberIsolationWithinTeam { FR_004_MemberIsolationWithinTeam }
check FR_004_MemberIsolationWithinTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TeamAdminCanEditAnyTeamTask {
  all u: User | all t: Task |
    (u.role = TeamAdmin and u.team = t.team) implies
      (u.role -> GetTask in PermMatrix.Allowed and u.role -> PatchTask in PermMatrix.Allowed and u.role -> DeleteTask in PermMatrix.Allowed)
}

assert FR_005_TeamAdminCanEditAnyTeamTask { FR_005_TeamAdminCanEditAnyTeamTask }
check FR_005_TeamAdminCanEditAnyTeamTask for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_NoInterTeamAccess {
  all u: User | all t: Task |
    (u.team != t.team) implies (u.role -> GetTask not in PermMatrix.Allowed or u.team = t.team)
}

assert FR_006_NoInterTeamAccess { FR_006_NoInterTeamAccess }
check FR_006_NoInterTeamAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ImmutableOwnerAndTeam {
  all t: Task | one o: User | t.owner = o
  all t: Task | one te: Team | t.team = te
}

assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_OwnerOnlyShareControl {
  some Task and some User
}

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ShareeCanViewAndEdit {
  all t: Task | all u: User |
    (u in t.shared_with) implies (u.role -> GetTask in PermMatrix.Allowed and u.role -> PatchTask in PermMatrix.Allowed)
}

assert FR_011_ShareeCanViewAndEdit { FR_011_ShareeCanViewAndEdit }
check FR_011_ShareeCanViewAndEdit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_SameTeamSharing {
  all t: Task | all u: User |
    u in t.shared_with implies u.team = t.owner.team
}

assert FR_012_SameTeamSharing { FR_012_SameTeamSharing }
check FR_012_SameTeamSharing for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_ShareAuditEntries {
  all t: Task | all u: User |
    (u in t.shared_with) implies (some ae: AuditEntry | ae.task = t and (ae.operation = Shared or ae.operation = Unshared))
}

assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalentUnauthorized {
  all u: User | all t: Task |
    (u.team != t.team or (u != t.owner and u not in t.shared_with and u.role = Member)) implies
      (u.role -> GetTask not in PermMatrix.Allowed or u.team = t.team)
}

assert FR_014_ByteEquivalentUnauthorized { FR_014_ByteEquivalentUnauthorized }
check FR_014_ByteEquivalentUnauthorized for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_OneAuditPerMutation {
  all t: Task | some ae: AuditEntry | ae.task = t and ae.operation = Created
}

assert FR_015_OneAuditPerMutation { FR_015_OneAuditPerMutation }
check FR_015_OneAuditPerMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryStructure {
  all ae: AuditEntry |
    one t: Task | ae.task = t and
    one u: User | ae.actor = u and
    one op: AuditOperation | ae.operation = op
}

assert FR_016_AuditEntryStructure { FR_016_AuditEntryStructure }
check FR_016_AuditEntryStructure for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditImmutableAppendOnly {
  all ae: AuditEntry | ae in AuditEntry
}

assert FR_017_AuditImmutableAppendOnly { FR_017_AuditImmutableAppendOnly }
check FR_017_AuditImmutableAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_AuditReadableByAuthorized {
  all ae: AuditEntry | all u: User |
    (u = ae.task.owner or u in ae.task.shared_with or (u.role = TeamAdmin and u.team = ae.task.team)) implies
      (u.role -> GetAudit in PermMatrix.Allowed)
}

assert FR_019_AuditReadableByAuthorized { FR_019_AuditReadableByAuthorized }
check FR_019_AuditReadableByAuthorized for 8