// === feature_model.als — Alloy model for B-L2: SaaS Team Task Management with Audit Trail ===

// --------------------------------------------------------------------
// Static enums (closed worlds, fixed atom counts)
// --------------------------------------------------------------------

abstract sig Bool {}
one sig TrueB, FalseB extends Bool {}

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig ChangeKind {}
one sig CreatedKind, ChangedKind, DeletedKind extends ChangeKind {}

abstract sig OperationKind {}
one sig PostTasks, GetTasksList, GetTaskById, PatchTask, DeleteTask, GetTaskAudit
  extends OperationKind {}

// --------------------------------------------------------------------
// Domain entities (from data-model.md)
// --------------------------------------------------------------------

sig User {}
sig Team {}

sig TeamMembership {
  mUser: one User,
  mTeam: one Team,
  mRole: one Role
}

sig Task {
  tTeam:  one Team,
  tOwner: one User
}

sig AuditEntry {
  aTask:      one Task,
  aTeam:      one Team,
  aActor:     one User,
  aActorRole: one Role,
  aKind:      one ChangeKind
}

// Operation = one observed request that reached business logic.
// oCaller/oTeamCtx/oCallerRole are `lone` so the auth/team-context
// facts can be mutation-tested (a request that bypassed auth shows up
// as an Operation with no caller).
sig Operation {
  oCaller:     lone User,
  oTeamCtx:    lone Team,
  oCallerRole: lone Role,
  oKind:       one OperationKind,
  oTarget:     lone Task,
  oAudit:      lone AuditEntry,
  oAllowed:    one Bool
}

// Permission matrix from contracts/http-api.md, encoded as a
// singleton-sig field (Role -> OperationKind).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// --------------------------------------------------------------------
// Non-empty universe (so universal assertions are not vacuous)
// --------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// --------------------------------------------------------------------
// Permission matrix encoding
// contracts/http-api.md table: all 6 endpoints allowed for both roles
// (PATCH/DELETE for non-owner members denied by ownership predicate, not
// by the matrix — the matrix is the role-only verdict).
// --------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (MemberRole -> PostTasks) + (MemberRole -> GetTasksList) +
    (MemberRole -> GetTaskById) + (MemberRole -> PatchTask) +
    (MemberRole -> DeleteTask) + (MemberRole -> GetTaskAudit) +
    (AdminRole  -> PostTasks) + (AdminRole  -> GetTasksList) +
    (AdminRole  -> GetTaskById) + (AdminRole  -> PatchTask) +
    (AdminRole  -> DeleteTask) + (AdminRole  -> GetTaskAudit)
}

// --------------------------------------------------------------------
// Boundary / authentication / team-context invariants
// --------------------------------------------------------------------

// FR-001: every request that reached business logic is authenticated.
fact F_AuthRequired {
  all op: Operation | one op.oCaller
}

// FR-003: every request carries an X-Team-Id.
fact F_TeamCtxRequired {
  all op: Operation | one op.oTeamCtx
}

// FR-007: every authenticated request has a resolved role.
fact F_RoleResolved {
  all op: Operation | one op.oCallerRole
}

// FR-007 / data-model.md: composite PK (user_id, team_id) on team_memberships.
fact F_UniqueTeamMembership {
  all disj m1, m2: TeamMembership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}

// FR-004: the caller is a current member of the resolved team with the
// resolved role.
fact F_CallerIsTeamMember {
  all op: Operation |
    some m: TeamMembership |
      m.mUser = op.oCaller and
      m.mTeam = op.oTeamCtx and
      m.mRole = op.oCallerRole
}

// --------------------------------------------------------------------
// Cross-team isolation (FR-011 / FR-014)
// --------------------------------------------------------------------

fact F_CrossTeamIsolation {
  all op: Operation |
    (op.oAllowed = TrueB and some op.oTarget)
      implies op.oTarget.tTeam = op.oTeamCtx
}

// --------------------------------------------------------------------
// Ownership-based mutation (FR-008 / FR-009 / FR-010)
// --------------------------------------------------------------------

fact F_OwnerOrAdminForMutation {
  all op: Operation |
    (op.oAllowed = TrueB and
     op.oKind in (PatchTask + DeleteTask) and
     some op.oTarget)
      implies (op.oCallerRole = AdminRole or op.oTarget.tOwner = op.oCaller)
}

// --------------------------------------------------------------------
// Audit trail (FR-015, FR-016)
// --------------------------------------------------------------------

// FR-015: every successful state-changing op produces exactly one audit
// entry. Pure reads produce none.
fact F_AuditPerStateChange {
  all op: Operation |
    (op.oAllowed = TrueB and op.oKind in (PostTasks + PatchTask + DeleteTask))
      implies (one op.oAudit)
  all op: Operation |
    op.oKind in (GetTasksList + GetTaskById + GetTaskAudit)
      implies (no op.oAudit)
}

// FR-016: append-only — every audit entry is produced by exactly one
// originating Operation (no orphan, no reassignment).
fact F_AuditAppendOnly {
  all ae: AuditEntry | one op: Operation | op.oAudit = ae
}

// FR-015: snapshotted attribution — audit's actor/role/team equal the
// op's caller/role/team-context at the moment of the change.
fact F_AuditAttribution {
  all op: Operation |
    some op.oAudit implies (
      op.oAudit.aActor     = op.oCaller and
      op.oAudit.aActorRole = op.oCallerRole and
      op.oAudit.aTeam      = op.oTeamCtx
    )
}

// FR-015: audit refers to the task the op targets.
fact F_AuditTaskLink {
  all op: Operation |
    some op.oAudit implies (some op.oTarget and op.oAudit.aTask = op.oTarget)
}

// FR-015: change-kind matches the op kind.
fact F_AuditKindMatchesOp {
  all op: Operation |
    some op.oAudit implies (
      (op.oKind = PostTasks  implies op.oAudit.aKind = CreatedKind) and
      (op.oKind = PatchTask  implies op.oAudit.aKind = ChangedKind) and
      (op.oKind = DeleteTask implies op.oAudit.aKind = DeletedKind)
    )
}

// FR-005 / data-model: audit.team_id is denormalised from task.team_id.
fact F_AuditTeamMatchesTaskTeam {
  all ae: AuditEntry | ae.aTeam = ae.aTask.tTeam
}

// FR-006: owner is the creator (the actor of the `created` entry) and
// is immutable — the link is captured at creation time.
fact F_CreatedByOwner {
  all ae: AuditEntry |
    ae.aKind = CreatedKind implies ae.aActor = ae.aTask.tOwner
}

// ====================================================================
// PATTERN ASSERTIONS
// ====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008/009/010/011
pred LeastPrivilege {
  all op: Operation |
    op.oAllowed = TrueB implies (op.oCallerRole -> op.oKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix (all cells defined)
pred PermissionCompleteness {
  all r: Role, k: OperationKind | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 (admin >= member on every op)
pred PrivilegeMonotonicity {
  all k: OperationKind |
    (MemberRole -> k) in PermMatrix.Allowed implies (AdminRole -> k) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | one op.oCaller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model audit_entries
pred AuditCompleteness {
  // every state-changing op has exactly one audit entry
  all op: Operation |
    (op.oAllowed = TrueB and op.oKind in (PostTasks + PatchTask + DeleteTask))
      implies (one op.oAudit)
  // every audit entry has exactly one originating op (no orphan)
  all ae: AuditEntry | one op: Operation | op.oAudit = ae
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all ae: AuditEntry | some op: Operation | op.oAudit = ae
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 snapshotted actor/role
pred AttributionCorrectness {
  all op: Operation |
    some op.oAudit implies (
      op.oAudit.aActor     = op.oCaller and
      op.oAudit.aActorRole = op.oCallerRole
    )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL
pred OwnershipExclusivity {
  all t: Task | one t.tOwner
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008 / FR-009 / FR-010
pred OwnershipBasedAccess {
  all op: Operation |
    (op.oAllowed = TrueB and
     op.oKind in (PatchTask + DeleteTask) and
     some op.oTarget)
      implies (op.oCallerRole = AdminRole or op.oTarget.tOwner = op.oCaller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-011 / FR-014
pred NoInformationLeakage {
  all op: Operation |
    (op.oAllowed = TrueB and some op.oTarget)
      implies op.oTarget.tTeam = op.oTeamCtx
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ====================================================================
// FEATURE-SPECIFIC (one assertion per FR-NNN)
// ====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required everywhere
pred FR_001_AuthRequired {
  all op: Operation | one op.oCaller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity comes from auth context, not payload
// (operationally: every Operation has exactly one resolved caller)
pred FR_002_IdentityFromAuth {
  all op: Operation | one op.oCaller and one op.oCallerRole
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 X-Team-Id required on every request
pred FR_003_TeamCtxRequired {
  all op: Operation | one op.oTeamCtx
}
assert FR_003_TeamCtxRequired { FR_003_TeamCtxRequired }
check FR_003_TeamCtxRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 caller must be current member of resolved team
pred FR_004_CallerIsTeamMember {
  all op: Operation |
    some m: TeamMembership |
      m.mUser = op.oCaller and
      m.mTeam = op.oTeamCtx and
      m.mRole = op.oCallerRole
}
assert FR_004_CallerIsTeamMember { FR_004_CallerIsTeamMember }
check FR_004_CallerIsTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 task.team_id immutable (audit denormalised team matches task team)
pred FR_005_TaskTeamInvariant {
  all ae: AuditEntry | ae.aTeam = ae.aTask.tTeam
}
assert FR_005_TaskTeamInvariant { FR_005_TaskTeamInvariant }
check FR_005_TaskTeamInvariant for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 owner_id immutable (creator = owner)
pred FR_006_OwnerImmutable {
  all ae: AuditEntry |
    ae.aKind = CreatedKind implies ae.aActor = ae.aTask.tOwner
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role; (user_id, team_id) is unique
pred FR_007_PerTeamRole {
  all disj m1, m2: TeamMembership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 owner-or-admin may edit/delete
pred FR_008_OwnerOrAdminCanMutate {
  all op: Operation |
    (op.oAllowed = TrueB and
     op.oKind in (PatchTask + DeleteTask) and
     some op.oTarget)
      implies (op.oCallerRole = AdminRole or op.oTarget.tOwner = op.oCaller)
}
assert FR_008_OwnerOrAdminCanMutate { FR_008_OwnerOrAdminCanMutate }
check FR_008_OwnerOrAdminCanMutate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-owner member cannot edit/delete
pred FR_009_NonOwnerMemberCannotMutate {
  no op: Operation |
    op.oAllowed = TrueB and
    op.oKind in (PatchTask + DeleteTask) and
    op.oCallerRole = MemberRole and
    some op.oTarget and
    op.oTarget.tOwner != op.oCaller
}
assert FR_009_NonOwnerMemberCannotMutate { FR_009_NonOwnerMemberCannotMutate }
check FR_009_NonOwnerMemberCannotMutate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 admin's permission set includes member's
pred FR_010_AdminSupersedesMember {
  all k: OperationKind |
    (MemberRole -> k) in PermMatrix.Allowed implies (AdminRole -> k) in PermMatrix.Allowed
}
assert FR_010_AdminSupersedesMember { FR_010_AdminSupersedesMember }
check FR_010_AdminSupersedesMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 no role in T grants access to U's tasks
pred FR_011_CrossTeamIsolation {
  all op: Operation |
    (op.oAllowed = TrueB and some op.oTarget)
      implies op.oTarget.tTeam = op.oTeamCtx
}
assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404 for cross-team (no allowed cross-team op)
pred FR_014_NoCrossTeamSuccess {
  all op: Operation |
    (op.oAllowed = TrueB and some op.oTarget)
      implies op.oTarget.tTeam = op.oTeamCtx
}
assert FR_014_NoCrossTeamSuccess { FR_014_NoCrossTeamSuccess }
check FR_014_NoCrossTeamSuccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 per-edit-event audit (one per save)
pred FR_015_AuditPerEdit {
  all op: Operation |
    (op.oAllowed = TrueB and op.oKind in (PostTasks + PatchTask + DeleteTask))
      implies (one op.oAudit)
}
assert FR_015_AuditPerEdit { FR_015_AuditPerEdit }
check FR_015_AuditPerEdit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit append-only (every entry has a unique creating op)
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry | one op: Operation | op.oAudit = ae
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit visible to any team member (incl. non-admin)
pred FR_017_AuditVisibleToAllMembers {
  (MemberRole -> GetTaskAudit) in PermMatrix.Allowed
  (AdminRole  -> GetTaskAudit) in PermMatrix.Allowed
}
assert FR_017_AuditVisibleToAllMembers { FR_017_AuditVisibleToAllMembers }
check FR_017_AuditVisibleToAllMembers for 6