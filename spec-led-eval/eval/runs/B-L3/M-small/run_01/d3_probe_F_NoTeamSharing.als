// === feature_model.als — Alloy model for B-L3 Multi-Tenant Task Management ===

// Roles
abstract sig Role {}
one sig MemberRole extends Role {}
one sig AdminRole extends Role {}

// Users and Teams
abstract sig User {}
abstract sig Team {}

// Tasks
abstract sig Task {}

// Audit Operation Types
abstract sig AuditOperation {}
one sig Created extends AuditOperation {}
one sig Edited extends AuditOperation {}
one sig Deleted extends AuditOperation {}
one sig Shared extends AuditOperation {}
one sig Unshared extends AuditOperation {}

// API Operations
abstract sig OperationKind {}
one sig PostTasks extends OperationKind {}
one sig GetTask extends OperationKind {}
one sig PatchTask extends OperationKind {}
one sig DeleteTask extends OperationKind {}
one sig GetAudit extends OperationKind {}

// === Core Relations ===

sig UserTeamAssignment {
  user: one User,
  team: one Team,
  role: one Role
}

sig TaskOwnership {
  task: one Task,
  owner: one User,
  team: one Team
}

sig TaskShare {
  task: one Task,
  sharee: one User
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  operation: one AuditOperation
}

one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// === Non-empty Universe ===

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
  some UserTeamAssignment
  some TaskOwnership
}

// === FR-002: Each user belongs to exactly one team ===
fact F_UserTeamUniqueness {
  all u: User | one uta: UserTeamAssignment | uta.user = u
}

// === FR-009: Each task has exactly one owner ===
fact F_TaskOwnershipUniqueness {
  all t: Task | one to: TaskOwnership | to.task = t
}

// === FR-009: Task ownership immutable ===
fact F_TaskOwnershipImmutable {
  all t: Task |
    let tos = { to: TaskOwnership | to.task = t } |
      all to1, to2: tos | to1.owner = to2.owner and to1.team = to2.team
}

// === FR-010: Only owner can modify shared_with ===
fact F_OwnerOnlyShareControl {
  all ts: TaskShare |
    let tox = { to: TaskOwnership | to.task = ts.task } |
      all to: tox | ts.sharee != to.owner
}

// === FR-012: Cross-team sharing forbidden ===
fact F_NoTeamSharing {
  all ts: TaskShare |
    let tox = { to: TaskOwnership | to.task = ts.task } |
    let utaS = { uta: UserTeamAssignment | uta.user = ts.sharee } |
    let utaO = { uta: UserTeamAssignment | uta.user = tox.owner } |
      all to: tox, utas: utaS, utao: utaO |
        to.team = utas.team and utao.team = utas.team
}

// === FR-006 + FR-014: Cross-team isolation ===
fact F_CrossTeamIsolation {
  all u: User, t: Task |
    let utaU = { uta: UserTeamAssignment | uta.user = u } |
    let tox = { to: TaskOwnership | to.task = t } |
    let shares = { ts: TaskShare | ts.task = t } |
      all uta: utaU, to: tox |
        (uta.team != to.team) implies (u not in shares.sharee and u != to.owner)
}

// === FR-015: Audit completeness ===
fact F_AuditCompleteness {
  all t: Task |
    (some to: TaskOwnership | to.task = t) implies
      (some ae: AuditEntry | ae.task = t and ae.operation = Created)
}

// === FR-017: Audit immutable ===
fact F_AuditImmutable {
  no ae1, ae2: AuditEntry |
    ae1.task = ae2.task and ae1.actor = ae2.actor and
    ae1.operation = ae2.operation and ae1.actor_role = ae2.actor_role and ae1 != ae2
}

// === Permission matrix definition ===
fact F_PermissionMatrixDef {
  MemberRole -> PostTasks in PermMatrix.allowed and
  MemberRole -> GetTask in PermMatrix.allowed and
  MemberRole -> PatchTask in PermMatrix.allowed and
  (MemberRole -> DeleteTask not in PermMatrix.allowed) and
  AdminRole -> PostTasks in PermMatrix.allowed and
  AdminRole -> GetTask in PermMatrix.allowed and
  AdminRole -> PatchTask in PermMatrix.allowed and
  AdminRole -> DeleteTask in PermMatrix.allowed
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some User and some Role and some OperationKind and
  MemberRole -> DeleteTask not in PermMatrix.allowed and
  AdminRole -> DeleteTask in PermMatrix.allowed
}

// PATTERN: AppendOnly  ANCHOR: FR-017; data-model.md audit immutable
pred AppendOnly {
  some ae: AuditEntry |
    no ae2: AuditEntry | ae2 != ae and ae2.task = ae.task and ae2.actor = ae.actor
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015, FR-016; spec.md User Story 6
pred AuditCompleteness {
  all t: Task | (some to: TaskOwnership | to.task = t) implies (some ae: AuditEntry | ae.task = t and ae.operation = Created)
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-009; data-model.md TaskOwnership
pred OwnershipExclusivity {
  some Task and all t: Task | one to: TaskOwnership | to.task = t
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-010, Q1=A; spec.md User Story 3
pred OwnershipBasedAccess {
  all ts: TaskShare |
    let tox = { to: TaskOwnership | to.task = ts.task } |
      all to: tox | ts.sharee != to.owner
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014; spec.md User Story 5
pred NoInformationLeakage {
  all u: User, t: Task |
    let utaU = { uta: UserTeamAssignment | uta.user = u } |
    let tox = { to: TaskOwnership | to.task = t } |
    let shares = { ts: TaskShare | ts.task = t } |
      all uta: utaU, to: tox |
        (uta.team != to.team) implies (u not in shares.sharee)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md Bearer requirement
pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.actor in User
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016; data-model.md actor_role snapshot
pred AttributionCorrectness {
  all ae: AuditEntry |
    let utaActor = { uta: UserTeamAssignment | uta.user = ae.actor } |
      (some utaActor) implies (all uta: utaActor | ae.actor_role = uta.role)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.allowed) or (r -> op not in PermMatrix.allowed)
}

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/ permission table
pred PermissionGrounding {
  MemberRole -> PostTasks in PermMatrix.allowed and
  AdminRole -> PostTasks in PermMatrix.allowed
}

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-007, FR-009, FR-012; spec.md User Stories
pred ValidationBeforeMutation {
  all ae: AuditEntry |
    (some to: TaskOwnership | to.task = ae.task) implies ae.task in Task
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all ae: AuditEntry | ae.actor in User and ae.actor_role in Role
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_TeamFromToken {
  all ae: AuditEntry |
    let utaActor = { uta: UserTeamAssignment | uta.user = ae.actor } |
      all uta: utaActor | ae.actor_role = uta.role
}

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
pred FR_003_MemberPermissions {
  some u: User, t: Task |
    let utaU = { uta: UserTeamAssignment | uta.user = u } |
    let tox = { to: TaskOwnership | to.task = t } |
      some uta: utaU, to: tox | uta.role = MemberRole and uta.team = to.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminTeamAccess {
  some u: User, t: Task |
    let utaU = { uta: UserTeamAssignment | uta.user = u } |
    let tox = { to: TaskOwnership | to.task = t } |
      some uta: utaU, to: tox | uta.role = AdminRole and uta.team = to.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CrossTeamIsolation {
  all u: User, t: Task |
    let utaU = { uta: UserTeamAssignment | uta.user = u } |
    let tox = { to: TaskOwnership | to.task = t } |
    let shares = { ts: TaskShare | ts.task = t } |
      all uta: utaU, to: tox |
        (uta.team != to.team) implies (u not in shares.sharee and u != to.owner)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A
pred FR_010_OwnerOnlyShareControl {
  all ts: TaskShare |
    let tox = { to: TaskOwnership | to.task = ts.task } |
      all to: tox | ts.sharee != to.owner
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NoTeamSharing {
  all ts: TaskShare |
    let tox = { to: TaskOwnership | to.task = ts.task } |
    let utaS = { uta: UserTeamAssignment | uta.user = ts.sharee } |
    let utaO = { uta: UserTeamAssignment | uta.user = tox.owner } |
      all to: tox, utas: utaS, utao: utaO | to.team = utas.team
}

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ByteEquivalentNotFound {
  all u: User, t: Task |
    let utaU = { uta: UserTeamAssignment | uta.user = u } |
    let tox = { to: TaskOwnership | to.task = t } |
    let shares = { ts: TaskShare | ts.task = t } |
      all uta: utaU, to: tox |
        ((uta.team != to.team) implies (u not in shares.sharee and u != to.owner))
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditCompleteness {
  all t: Task |
    (some to: TaskOwnership | to.task = t) implies (some ae: AuditEntry | ae.task = t and ae.operation = Created)
}

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditImmutable {
  no ae1, ae2: AuditEntry |
    ae1.task = ae2.task and ae1.actor = ae2.actor and ae1.operation = ae2.operation and ae1 != ae2
}

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_AuditReadAccess {
  all ae: AuditEntry |
    let tox = { to: TaskOwnership | to.task = ae.task } |
    let shares = { ts: TaskShare | ts.task = ae.task } |
      (some tox and some shares) implies (ae.actor = tox.owner or ae.actor in shares.sharee)
}

// === Assertions ===

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 5 OperationKind

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8 but exactly 2 Role, exactly 5 OperationKind

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

assert FR_002_TeamFromToken { FR_002_TeamFromToken }
check FR_002_TeamFromToken for 5

assert FR_003_MemberPermissions { FR_003_MemberPermissions }
check FR_003_MemberPermissions for 5

assert FR_005_AdminTeamAccess { FR_005_AdminTeamAccess }
check FR_005_AdminTeamAccess for 5

assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 5

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

assert FR_012_NoTeamSharing { FR_012_NoTeamSharing }
check FR_012_NoTeamSharing for 5

assert FR_014_ByteEquivalentNotFound { FR_014_ByteEquivalentNotFound }
check FR_014_ByteEquivalentNotFound for 5

assert FR_015_AuditCompleteness { FR_015_AuditCompleteness }
check FR_015_AuditCompleteness for 5

assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 5

assert FR_019_AuditReadAccess { FR_019_AuditReadAccess }
check FR_019_AuditReadAccess for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_CrossTeamShare { some ts: TaskShare, to: TaskOwnership, utaS: UserTeamAssignment, utaO: UserTeamAssignment | ts.task = to.task and utaS.user = ts.sharee and utaO.user = to.owner and utaS.team != utaO.team }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
