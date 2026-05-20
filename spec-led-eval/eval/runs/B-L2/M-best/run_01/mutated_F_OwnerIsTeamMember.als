// === feature_model.als — Alloy model for B-L2: SaaS Team Task Management with Audit Trail ===
//
// Encodes structural invariants for the 007-team-tasks feature:
//   - per-team role (member / admin), multi-team users via TeamMembership
//   - tasks owned by exactly one user, scoped to exactly one team
//   - per-edit-event append-only audit trail
//   - cross-team isolation (byte-equivalent 404, admin does NOT override)
//   - owner-or-admin edit/delete

// ---------- Static enumerations ----------

abstract sig Role {}
one sig Member, Admin extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById,
        PatchOwnTask, PatchAnyTask,
        DeleteOwnTask, DeleteAnyTask,
        GetAudit extends OperationKind {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig Created, Changed, Deleted extends ChangeKind {}

abstract sig Outcome {}
one sig Success, Denied extends Outcome {}

// ---------- Dynamic entities ----------

sig User {}
sig Team {}

sig Membership {
  user:  one User,
  team:  one Team,
  mRole: one Role
}

sig Task {
  team:     one Team,
  owner:    one User,
  assignee: lone User,
  status:   one TaskStatus
}

sig AuditEntry {
  ofTask:    one Task,
  inTeam:    one Team,
  actor:     one User,
  actorRole: one Role,
  kind:      one ChangeKind
}

sig Operation {
  caller:      one User,
  contextTeam: one Team,
  callerRole:  one Role,
  opKind:      one OperationKind,
  target:      lone Task,
  outcome:     one Outcome
}

// Permission matrix as a singleton-sig field (per rule 7).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe (rule 9) ----------

fact F_NonEmptyUniverse {
  some User
  some Team
  some Membership
  some Task
  some AuditEntry
  some Operation
}

// ---------- Permission matrix (closed-world from contracts/http-api.md) ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Member -> PostTasks)
    + (Member -> GetTasks)
    + (Member -> GetTaskById)
    + (Member -> PatchOwnTask)
    + (Member -> DeleteOwnTask)
    + (Member -> GetAudit)
    + (Admin  -> PostTasks)
    + (Admin  -> GetTasks)
    + (Admin  -> GetTaskById)
    + (Admin  -> PatchOwnTask)
    + (Admin  -> DeleteOwnTask)
    + (Admin  -> PatchAnyTask)
    + (Admin  -> DeleteAnyTask)
    + (Admin  -> GetAudit)
}

// ---------- Structural facts ----------

// data-model.md: composite PK (user_id, team_id) on team_memberships.
fact F_MembershipUnique {
  all disj m1, m2: Membership | not (m1.user = m2.user and m1.team = m2.team)
}

// data-model.md: tasks.owner_id FK→users.id; spec FR-006 owner is the creator who must be a team member.
fact F_OwnerIsTeamMember { /* MUTATED — body cleared by validator */ }

// spec FR-012: assignee MUST be a current member of the same team.
fact F_AssigneeIsTeamMember {
  all t: Task | (some t.assignee) implies
    (some m: Membership | m.user = t.assignee and m.team = t.team)
}

// data-model.md: audit_entries.team_id denormalised to == task's team.
fact F_AuditTeamMatchesTask {
  all ae: AuditEntry | ae.inTeam = ae.ofTask.team
}

// spec FR-015: actor display name & role snapshotted from a real membership at change time.
fact F_AuditActorIsMemberWithRole {
  all ae: AuditEntry |
    (some m: Membership | m.user = ae.actor and m.team = ae.inTeam and m.mRole = ae.actorRole)
}

// contracts/http-api.md: only single-task endpoints carry a target; list/create do not.
fact F_OpTargetShape {
  all op: Operation |
    op.opKind in (GetTaskById + PatchOwnTask + PatchAnyTask + DeleteOwnTask + DeleteAnyTask + GetAudit)
      implies (some op.target)
  all op: Operation |
    op.opKind in (PostTasks + GetTasks) implies (no op.target)
}

// spec FR-001 / FR-003 / FR-004: successful op requires caller to be a member of contextTeam with the recorded role.
fact F_AuthAndTeamContext {
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller and m.team = op.contextTeam and m.mRole = op.callerRole)
}

// contracts/http-api.md permission matrix: success requires (role, opKind) in Allowed.
fact F_SuccessRequiresPermission {
  all op: Operation | op.outcome = Success implies
    ((op.callerRole -> op.opKind) in PermMatrix.Allowed)
}

// spec FR-011 / FR-014: target task must belong to caller's contextTeam.
fact F_CrossTeamIsolation {
  all op: Operation |
    (op.outcome = Success and some op.target) implies
    (op.target.team = op.contextTeam)
}

// spec FR-008/9: for own-task ops, target's owner must equal the caller.
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Success and op.opKind in (PatchOwnTask + DeleteOwnTask)) implies
    (op.target.owner = op.caller)
}

// spec FR-015 / FR-016: every task has a `created` audit entry.
fact F_EveryTaskHasCreatedAudit {
  all t: Task | some ae: AuditEntry | (ae.ofTask = t and ae.kind = Created)
}

// spec FR-016: audit trail append-only: at most one `created` and at most one `deleted` entry per task.
fact F_AppendOnlyAuditEntries {
  all t: Task | lone ae: AuditEntry | (ae.ofTask = t and ae.kind = Created)
  all t: Task | lone ae: AuditEntry | (ae.ofTask = t and ae.kind = Deleted)
}

// ============================================================
// Pattern predicates
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008..FR-011
pred LeastPrivilege {
  some Operation
  all op: Operation | op.outcome = Success implies
    ((op.callerRole -> op.opKind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 (admin ⊇ member); contracts/http-api.md matrix
pred PrivilegeMonotonicity {
  all ok: OperationKind |
    (Member -> ok) in PermMatrix.Allowed implies (Admin -> ok) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-003, FR-004
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller and m.team = op.contextTeam and m.mRole = op.callerRole)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md audit_entries schema
pred AuditCompleteness {
  some Task
  all t: Task | (one ae: AuditEntry | ae.ofTask = t and ae.kind = Created)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  all t: Task | lone ae: AuditEntry | (ae.ofTask = t and ae.kind = Created)
  all t: Task | lone ae: AuditEntry | (ae.ofTask = t and ae.kind = Deleted)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 (snapshot actor + role)
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    (some m: Membership | m.user = ae.actor and m.team = ae.inTeam and m.mRole = ae.actorRole)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-006; data-model.md tasks.owner_id NOT NULL, immutable
pred OwnershipExclusivity {
  some Task
  all t: Task |
    (some m: Membership | m.user = t.owner and m.team = t.team)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009; contracts/http-api.md owner-or-admin rule
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Success and op.opKind in (PatchOwnTask + DeleteOwnTask)) implies
    (op.target.owner = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-011, FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  all op: Operation |
    (op.outcome = Success and some op.target) implies
    (op.target.team = op.contextTeam)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// ============================================================
// Feature-specific FR predicates (one per FR-NNN where structurally meaningful)
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authenticated user required before business logic)
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-002 (actor identity from auth context; recorded role tied to a real membership)
pred FR_002_ActorFromAuthContext {
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller and m.team = op.contextTeam and m.mRole = op.callerRole)
}
assert FR_002_ActorFromAuthContext { FR_002_ActorFromAuthContext }
check FR_002_ActorFromAuthContext for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-003 (X-Team-Id resolves to a team the caller is a current member of)
pred FR_003_TeamContextResolved {
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller and m.team = op.contextTeam)
}
assert FR_003_TeamContextResolved { FR_003_TeamContextResolved }
check FR_003_TeamContextResolved for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-004 (caller MUST be a current member of the resolved team)
pred FR_004_CallerIsTeamMember {
  all op: Operation | op.outcome = Success implies
    (some m: Membership | m.user = op.caller and m.team = op.contextTeam and m.mRole = op.callerRole)
}
assert FR_004_CallerIsTeamMember { FR_004_CallerIsTeamMember }
check FR_004_CallerIsTeamMember for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-005 (a task belongs to exactly one team, recorded at creation)
pred FR_005_TaskHasOneTeam {
  some Task
  all t: Task | one t.team
}
assert FR_005_TaskHasOneTeam { FR_005_TaskHasOneTeam }
check FR_005_TaskHasOneTeam for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-006 (every task has exactly one owner; owner immutable in v1)
pred FR_006_TaskHasOneOwner {
  some Task
  all t: Task | one t.owner
  all t: Task | (some m: Membership | m.user = t.owner and m.team = t.team)
}
assert FR_006_TaskHasOneOwner { FR_006_TaskHasOneOwner }
check FR_006_TaskHasOneOwner for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-007 (per-team role; at most one membership row per (user, team))
pred FR_007_PerTeamRole {
  all disj m1, m2: Membership | not (m1.user = m2.user and m1.team = m2.team)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-008 (a member edits/deletes tasks they own)
pred FR_008_MemberEditsOwnTask {
  all op: Operation |
    (op.outcome = Success and op.callerRole = Member
       and op.opKind in (PatchOwnTask + DeleteOwnTask)) implies
    (op.target.owner = op.caller)
}
assert FR_008_MemberEditsOwnTask { FR_008_MemberEditsOwnTask }
check FR_008_MemberEditsOwnTask for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-009 (non-owner non-admin member CANNOT edit/delete via "AnyTask" ops)
pred FR_009_NonOwnerMemberDenied {
  no op: Operation |
    op.outcome = Success and op.callerRole = Member
    and op.opKind in (PatchAnyTask + DeleteAnyTask)
}
assert FR_009_NonOwnerMemberDenied { FR_009_NonOwnerMemberDenied }
check FR_009_NonOwnerMemberDenied for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-010 (admin can edit/delete ANY task in their team)
pred FR_010_AdminEditAnyInTeam {
  (Admin -> PatchAnyTask) in PermMatrix.Allowed
  (Admin -> DeleteAnyTask) in PermMatrix.Allowed
}
assert FR_010_AdminEditAnyInTeam { FR_010_AdminEditAnyInTeam }
check FR_010_AdminEditAnyInTeam for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-011 (no role in team T grants access to team U; admin does NOT override)
pred FR_011_AdminCannotCrossTeam {
  all op: Operation |
    (op.outcome = Success and op.callerRole = Admin and some op.target) implies
    (op.target.team = op.contextTeam)
}
assert FR_011_AdminCannotCrossTeam { FR_011_AdminCannotCrossTeam }
check FR_011_AdminCannotCrossTeam for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-012 (assignee, if any, must be a member of the task's team)
pred FR_012_AssigneeIsTeamMember {
  all t: Task | (some t.assignee) implies
    (some m: Membership | m.user = t.assignee and m.team = t.team)
}
assert FR_012_AssigneeIsTeamMember { FR_012_AssigneeIsTeamMember }
check FR_012_AssigneeIsTeamMember for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-013 (status set is exactly {todo, in_progress, done})
pred FR_013_StatusIsLegal {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_013_StatusIsLegal { FR_013_StatusIsLegal }
check FR_013_StatusIsLegal for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent 404: cross-team target ⇒ no success)
pred FR_014_CrossTeamByteEquivalent {
  all op: Operation |
    (op.outcome = Success and some op.target) implies
    (op.target.team = op.contextTeam)
}
assert FR_014_CrossTeamByteEquivalent { FR_014_CrossTeamByteEquivalent }
check FR_014_CrossTeamByteEquivalent for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-015 (every audit entry carries actor + role + team consistent with a real membership)
pred FR_015_AuditEntryShape {
  some AuditEntry
  all ae: AuditEntry |
    (some m: Membership | m.user = ae.actor and m.team = ae.inTeam and m.mRole = ae.actorRole)
  all ae: AuditEntry | ae.inTeam = ae.ofTask.team
}
assert FR_015_AuditEntryShape { FR_015_AuditEntryShape }
check FR_015_AuditEntryShape for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit trail append-only: ≤1 Created and ≤1 Deleted per task)
pred FR_016_AuditAppendOnly {
  some AuditEntry
  all t: Task | lone ae: AuditEntry | (ae.ofTask = t and ae.kind = Created)
  all t: Task | lone ae: AuditEntry | (ae.ofTask = t and ae.kind = Deleted)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit readable by any current member of the team — and by admins)
pred FR_017_AuditReadableByMember {
  (Member -> GetAudit) in PermMatrix.Allowed
  (Admin  -> GetAudit) in PermMatrix.Allowed
}
assert FR_017_AuditReadableByMember { FR_017_AuditReadableByMember }
check FR_017_AuditReadableByMember for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit retained — no row vanishes; modelled as: each task retains its Created entry)
pred FR_018_AuditRetained {
  some AuditEntry
  all t: Task | some ae: AuditEntry | (ae.ofTask = t and ae.kind = Created)
}
assert FR_018_AuditRetained { FR_018_AuditRetained }
check FR_018_AuditRetained for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-019 (list endpoint is allowed for team members + admins)
pred FR_019_ListAllowedForTeamMembers {
  (Member -> GetTasks) in PermMatrix.Allowed
  (Admin  -> GetTasks) in PermMatrix.Allowed
}
assert FR_019_ListAllowedForTeamMembers { FR_019_ListAllowedForTeamMembers }
check FR_019_ListAllowedForTeamMembers for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// FEATURE-SPECIFIC  ANCHOR: FR-020 (filter combinations operate against the per-team list — caller must be a team member)
pred FR_020_ListScopedToTeam {
  all op: Operation |
    (op.outcome = Success and op.opKind = GetTasks) implies
    (some m: Membership | m.user = op.caller and m.team = op.contextTeam)
}
assert FR_020_ListScopedToTeam { FR_020_ListScopedToTeam }
check FR_020_ListScopedToTeam for 6 but exactly 2 Role, exactly 8 OperationKind, exactly 3 TaskStatus, exactly 3 ChangeKind, exactly 2 Outcome

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OwnershipExclusivityViolation { some t: Task | no m: Membership | m.user = t.owner and m.team = t.team }
