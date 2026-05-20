// === feature_model.als — Alloy model for 008-task-sharing ===
// Multi-Tenant Task Management with Per-Task Sharing and Audit
//
// Sigs encode the data-model.md entities (User, Team, Task, AuditEntry)
// plus an Action sig that models a single API call (caller, target,
// kind, outcome, produced audit entries). The (Relationship × OperationKind)
// access matrix from contracts/http-api.md is held as a field on a
// singleton sig.

// ---------- Roles, operations, audit ops, relationships, outcomes ----------

abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTask, PatchTaskFields, PatchTaskShare, DeleteTask, GetAudit
  extends OperationKind {}

abstract sig AuditOp {}
one sig CreatedOp, EditedOp, DeletedOp, SharedOp, UnsharedOp extends AuditOp {}

abstract sig Relationship {}
one sig OwnerRel, ShareeRel, TeamAdminRel, InTeamNoneRel, OutsiderRel
  extends Relationship {}

abstract sig Outcome {}
one sig OK, Denied404, Denied400Share, Denied401, Denied503 extends Outcome {}

one sig AuthOK {}

// Permission matrices held as fields on singleton sigs (per rule 7).
one sig AccessMatrix { CanAct: set Relationship -> OperationKind }
one sig RoleMatrix   { RoleAllowed: set Role -> OperationKind }

// ---------- Domain entities ----------

sig Team {}

sig User {
  userTeam: one Team,
  userRole: one Role
}

sig Task {
  taskTeam: one Team,
  owner: one User,
  sharedWith: set User
}

sig AuditEntry {
  auditTask: one Task,
  auditActor: one User,
  auditActorRole: one Role,
  auditOp: one AuditOp
}

sig Action {
  caller: one User,
  authValid: lone AuthOK,
  kind: one OperationKind,
  target: one Task,
  outcome: one Outcome,
  produces: set AuditEntry
}

// ---------- Non-empty universe (rule 9) ----------

fact F_NonEmptyUniverse {
  some Team
  some User
  some Task
  some AuditEntry
  some Action
}

// ---------- Derived relationship lookup ----------

fun rel[u: User, t: Task]: Relationship {
  u = t.owner => OwnerRel
  else u in t.sharedWith => ShareeRel
  else (u.userRole = TeamAdmin and u.userTeam = t.taskTeam) => TeamAdminRel
  else u.userTeam = t.taskTeam => InTeamNoneRel
  else OutsiderRel
}

// ---------- Structural facts ----------

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md (every role can attempt every endpoint; relationship gate runs after)
fact F_RoleMatrixComplete {
  RoleMatrix.RoleAllowed = Role -> OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix (Action × Relationship grid)
fact F_AccessMatrix {
  AccessMatrix.CanAct =
    (OwnerRel    -> GetTask)         + (ShareeRel    -> GetTask)         + (TeamAdminRel -> GetTask)         +
    (OwnerRel    -> PatchTaskFields) + (ShareeRel    -> PatchTaskFields) + (TeamAdminRel -> PatchTaskFields) +
    (OwnerRel    -> PatchTaskShare)                                                                          +
    (OwnerRel    -> DeleteTask)                                          + (TeamAdminRel -> DeleteTask)      +
    (OwnerRel    -> GetAudit)        + (ShareeRel    -> GetAudit)        + (TeamAdminRel -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md tasks.team_id = users(owner).team_id
fact F_OwnerInTaskTeam {
  all t: Task | t.owner.userTeam = t.taskTeam
}

// FEATURE-SPECIFIC  ANCHOR: FR-012 sharee must be in same team as owner
fact F_SharedWithSameTeam {
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
}

// FEATURE-SPECIFIC  ANCHOR: spec.md POST /tasks contract — creator not listed in own shared_with
fact F_OwnerNotSelfSharee {
  all t: Task | t.owner not in t.sharedWith
}

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit actor_role is snapshotted from the actor's persisted role
fact F_AuditActorRoleSnapshot {
  all a: AuditEntry | a.auditActorRole = a.auditActor.userRole
}

// FEATURE-SPECIFIC  ANCHOR: FR-014/FR-019 audit entries belong to the task's team via the actor's team
fact F_AuditActorInTaskTeam {
  all a: AuditEntry | a.auditActor.userTeam = a.auditTask.taskTeam
}

// FEATURE-SPECIFIC  ANCHOR: FR-006/FR-014 no successful action crosses team boundary
fact F_NoCrossTeamAccess { /* MUTATED — body cleared by validator */ }

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth required before any business logic
fact F_AuthRequiredForSuccess {
  all act: Action | act.outcome = OK implies some act.authValid
  all act: Action | (no act.authValid) implies act.outcome = Denied401
}

// FEATURE-SPECIFIC  ANCHOR: POST /tasks — caller becomes owner of new task
fact F_PostCreatorIsOwner {
  all act: Action |
    (act.kind = PostTasks and act.outcome = OK) implies act.caller = act.target.owner
}

// FEATURE-SPECIFIC  ANCHOR: FR-015 successful action that touches state produces audit entry/entries
fact F_AuditCompletenessFact {
  all act: Action |
    (act.outcome = OK and act.kind in (PostTasks + PatchTaskFields + PatchTaskShare + DeleteTask))
      implies some act.produces
  all act: Action |
    (act.kind in (GetTask + GetAudit)) implies no act.produces
  all act: Action | act.outcome != OK implies no act.produces
}

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries are append-only and trace to exactly one producing action
fact F_AuditOriginatesFromAction {
  all ae: AuditEntry | one act: Action | ae in act.produces
}

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry's task/actor must equal producing action's target/caller
fact F_AuditAttribution {
  all act: Action | all ae: act.produces |
    ae.auditTask = act.target and ae.auditActor = act.caller
}

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404 for outsider / in-team-no-rel
fact F_ByteEquiv404 {
  all act: Action |
    (some act.authValid and rel[act.caller, act.target] in (OutsiderRel + InTeamNoneRel))
      implies act.outcome = Denied404
  // FR-011: sharee attempting DELETE also gets byte-equivalent 404
  all act: Action |
    (some act.authValid and act.kind = DeleteTask and rel[act.caller, act.target] = ShareeRel)
      implies act.outcome = Denied404
}

// FEATURE-SPECIFIC  ANCHOR: FR-005/FR-010 only OWNER can change shared_with; admin/sharee included in body → 400
fact F_OnlyOwnerChangesShareList {
  all act: Action |
    (act.outcome = OK and act.kind = PatchTaskShare)
      implies rel[act.caller, act.target] = OwnerRel
}

// FEATURE-SPECIFIC  ANCHOR: FR-013 PatchTaskShare success emits a shared/unshared audit entry
fact F_ShareAuditEntryEmitted {
  all act: Action |
    (act.outcome = OK and act.kind = PatchTaskShare)
      implies (some ae: act.produces | ae.auditOp in (SharedOp + UnsharedOp))
}

// =========================================================================
// PATTERN PREDICATES & ASSERTIONS
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  // Owners have full access to their tasks
  (OwnerRel -> GetTask)         in AccessMatrix.CanAct
  (OwnerRel -> PatchTaskFields) in AccessMatrix.CanAct
  (OwnerRel -> PatchTaskShare)  in AccessMatrix.CanAct
  (OwnerRel -> DeleteTask)      in AccessMatrix.CanAct
  (OwnerRel -> GetAudit)        in AccessMatrix.CanAct
  // Sharees can view/edit non-share fields and read audit, but not delete and not change share list
  (ShareeRel -> GetTask)         in AccessMatrix.CanAct
  (ShareeRel -> PatchTaskFields) in AccessMatrix.CanAct
  (ShareeRel -> GetAudit)        in AccessMatrix.CanAct
  (ShareeRel -> PatchTaskShare)  not in AccessMatrix.CanAct
  (ShareeRel -> DeleteTask)      not in AccessMatrix.CanAct
  // Team admins: all except share-list changes
  (TeamAdminRel -> GetTask)         in AccessMatrix.CanAct
  (TeamAdminRel -> PatchTaskFields) in AccessMatrix.CanAct
  (TeamAdminRel -> DeleteTask)      in AccessMatrix.CanAct
  (TeamAdminRel -> GetAudit)        in AccessMatrix.CanAct
  (TeamAdminRel -> PatchTaskShare)  not in AccessMatrix.CanAct
  // Outsider and in-team-no-rel cannot do anything
  no (OutsiderRel.(AccessMatrix.CanAct))
  no (InTeamNoneRel.(AccessMatrix.CanAct))
  // And successful non-POST actions go through the matrix
  all act: Action |
    (act.outcome = OK and act.kind != PostTasks) implies
      ((rel[act.caller, act.target] -> act.kind) in AccessMatrix.CanAct)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md (every role × endpoint cell has a verdict)
pred PermissionCompleteness {
  RoleMatrix.RoleAllowed = Role -> OperationKind
  some Action
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  all act: Action | act.outcome = OK implies some act.authValid
  all act: Action | (no act.authValid) implies act.outcome = Denied401
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: FR-015 / SC-007
pred AuditCompleteness {
  all act: Action |
    (act.outcome = OK and act.kind in (PostTasks + PatchTaskFields + PatchTaskShare + DeleteTask))
      implies some act.produces
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: FR-017 (audit immutable; every audit row originates from a single action)
pred AppendOnly {
  all ae: AuditEntry | one act: Action | ae in act.produces
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: FR-016
pred AttributionCorrectness {
  all act: Action | all ae: act.produces |
    ae.auditActor = act.caller and ae.auditTask = act.target
  all a: AuditEntry | a.auditActorRole = a.auditActor.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL (one owner per task)
pred OwnershipExclusivity {
  all t: Task | one t.owner
  some Task
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003/FR-005/FR-014 owner's team = task's team
pred OwnershipBasedAccess {
  all t: Task | t.owner.userTeam = t.taskTeam
  all t: Task | rel[t.owner, t] = OwnerRel
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: FR-014 / SC-003 byte-equivalent 404
pred NoInformationLeakage {
  // No OK action crosses team boundary (would leak existence)
  all act: Action |
    act.outcome = OK implies act.caller.userTeam = act.target.taskTeam
  // Outsider/InTeamNone callers (authenticated) get exactly Denied404, never any other denial code
  all act: Action |
    (some act.authValid and rel[act.caller, act.target] in (OutsiderRel + InTeamNoneRel))
      implies act.outcome = Denied404
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md (creator implicitly in read-set; not in own shared_with)
pred NoSelfMutation {
  all t: Task | t.owner not in t.sharedWith
  some Task
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-018 (rollback on validation/SLA failure; no partial audit)
pred ValidationBeforeMutation {
  all act: Action | act.outcome != OK implies no act.produces
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// =========================================================================
// FR-LEVEL ASSERTIONS
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer required on every endpoint
pred FR_001_AuthRequired {
  all act: Action | act.outcome = OK implies some act.authValid
  all act: Action | (no act.authValid) implies (act.outcome = Denied401 and no act.produces)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 / FR-002a — team_id and role taken from token (user record), never body
pred FR_002_RoleFromToken {
  all a: AuditEntry | a.auditActorRole = a.auditActor.userRole
  all act: Action | all ae: act.produces | ae.auditActor = act.caller
}
assert FR_002_RoleFromToken { FR_002_RoleFromToken }
check FR_002_RoleFromToken for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 member access constrained to owner/sharee relationship
pred FR_003_MemberPermissions {
  all act: Action |
    (act.outcome = OK and act.kind != PostTasks and act.caller.userRole = Member) implies
      rel[act.caller, act.target] in (OwnerRel + ShareeRel)
}
assert FR_003_MemberPermissions { FR_003_MemberPermissions }
check FR_003_MemberPermissions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 members cannot access non-owned non-shared tasks
pred FR_004_NoAccessToOthersTasks {
  all act: Action |
    (act.outcome = OK and act.kind != PostTasks and
     act.caller.userRole = Member and
     act.caller != act.target.owner and
     act.caller not in act.target.sharedWith)
    implies act.kind in (PostTasks)  // i.e., never reachable for member non-owner non-sharee
}
assert FR_004_NoAccessToOthersTasks { FR_004_NoAccessToOthersTasks }
check FR_004_NoAccessToOthersTasks for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 team admin can act on any task in own team, EXCEPT change shared_with
pred FR_005_AdminCantChangeShare {
  (TeamAdminRel -> PatchTaskShare) not in AccessMatrix.CanAct
  all act: Action |
    (act.outcome = OK and act.kind = PatchTaskShare) implies act.caller = act.target.owner
}
assert FR_005_AdminCantChangeShare { FR_005_AdminCantChangeShare }
check FR_005_AdminCantChangeShare for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 absolute cross-team isolation
pred FR_006_CrossTeamIsolation {
  all act: Action |
    act.outcome = OK implies act.caller.userTeam = act.target.taskTeam
}
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
check FR_006_CrossTeamIsolation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 task non-empty title (modelled structurally as Task exists; content lengths are validation)
pred FR_007_TaskHasOwnerAndTeam {
  all t: Task | one t.owner and one t.taskTeam
  some Task
}
assert FR_007_TaskHasOwnerAndTeam { FR_007_TaskHasOwnerAndTeam }
check FR_007_TaskHasOwnerAndTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 status set fixed (modelled by enum-style sigs not used here; check task structure)
pred FR_008_TaskOwnerStable {
  // Each task has exactly one owner; no co-ownership
  all t: Task | one t.owner
  // Owner is consistently a member of the task's team
  all t: Task | t.owner.userTeam = t.taskTeam
}
assert FR_008_TaskOwnerStable { FR_008_TaskOwnerStable }
check FR_008_TaskOwnerStable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 owner_id and team_id immutable; one owner per task
pred FR_009_OwnerImmutable {
  all t: Task | one t.owner
  all t: Task | t.owner.userTeam = t.taskTeam
}
assert FR_009_OwnerImmutable { FR_009_OwnerImmutable }
check FR_009_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 only the owner may modify shared_with
pred FR_010_OnlyOwnerChangesShares {
  all act: Action |
    (act.outcome = OK and act.kind = PatchTaskShare)
      implies rel[act.caller, act.target] = OwnerRel
  (ShareeRel    -> PatchTaskShare) not in AccessMatrix.CanAct
  (TeamAdminRel -> PatchTaskShare) not in AccessMatrix.CanAct
}
assert FR_010_OnlyOwnerChangesShares { FR_010_OnlyOwnerChangesShares }
check FR_010_OnlyOwnerChangesShares for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 sharee cannot DELETE the task
pred FR_011_ShareeNoDelete {
  all act: Action |
    (act.outcome = OK and act.kind = DeleteTask)
      implies rel[act.caller, act.target] in (OwnerRel + TeamAdminRel)
  (ShareeRel -> DeleteTask) not in AccessMatrix.CanAct
}
assert FR_011_ShareeNoDelete { FR_011_ShareeNoDelete }
check FR_011_ShareeNoDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 cross-team sharing forbidden
pred FR_012_NoCrossTeamSharing {
  all t: Task | all s: t.sharedWith | s.userTeam = t.taskTeam
}
assert FR_012_NoCrossTeamSharing { FR_012_NoCrossTeamSharing }
check FR_012_NoCrossTeamSharing for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 share/unshare changes produce audit entries with operation in {shared, unshared}
pred FR_013_ShareAuditEntry {
  all act: Action |
    (act.outcome = OK and act.kind = PatchTaskShare)
      implies (some ae: act.produces | ae.auditOp in (SharedOp + UnsharedOp))
}
assert FR_013_ShareAuditEntry { FR_013_ShareAuditEntry }
check FR_013_ShareAuditEntry for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 byte-equivalent 404 to outsider / in-team-no-rel / sharee-on-delete
pred FR_014_ByteEquiv404 {
  all act: Action |
    (some act.authValid and rel[act.caller, act.target] in (OutsiderRel + InTeamNoneRel))
      implies act.outcome = Denied404
  all act: Action |
    (some act.authValid and act.kind = DeleteTask and rel[act.caller, act.target] = ShareeRel)
      implies act.outcome = Denied404
}
assert FR_014_ByteEquiv404 { FR_014_ByteEquiv404 }
check FR_014_ByteEquiv404 for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 per-event audit; every mutation success has ≥1 entry; non-mutations have none
pred FR_015_AuditPerEvent {
  all act: Action |
    (act.outcome = OK and act.kind in (PostTasks + PatchTaskFields + PatchTaskShare + DeleteTask))
      implies some act.produces
  all act: Action |
    (act.kind in (GetTask + GetAudit)) implies no act.produces
}
assert FR_015_AuditPerEvent { FR_015_AuditPerEvent }
check FR_015_AuditPerEvent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry carries task/actor/role snapshot consistent with the action
pred FR_016_AuditFields {
  all act: Action | all ae: act.produces |
    ae.auditTask = act.target and
    ae.auditActor = act.caller and
    ae.auditActorRole = act.caller.userRole
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit entries immutable; each AuditEntry produced by exactly one action
pred FR_017_AuditImmutable {
  all ae: AuditEntry | one act: Action | ae in act.produces
}
assert FR_017_AuditImmutable { FR_017_AuditImmutable }
check FR_017_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 1-second SLA — failures roll back; no partial audit on non-OK outcomes
pred FR_018_AuditAtomic {
  all act: Action | act.outcome != OK implies no act.produces
  all ae: AuditEntry | some act: Action | (ae in act.produces and act.outcome = OK)
}
assert FR_018_AuditAtomic { FR_018_AuditAtomic }
check FR_018_AuditAtomic for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 audit visibility = task visibility (owner / sharee / team admin)
pred FR_019_AuditVisibility {
  all act: Action |
    (act.outcome = OK and act.kind = GetAudit)
      implies rel[act.caller, act.target] in (OwnerRel + ShareeRel + TeamAdminRel)
}
assert FR_019_AuditVisibility { FR_019_AuditVisibility }
check FR_019_AuditVisibility for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 retention — no code path deletes audit entries (each entry has originator)
pred FR_020_AuditRetention {
  all ae: AuditEntry | some act: Action | ae in act.produces
}
assert FR_020_AuditRetention { FR_020_AuditRetention }
check FR_020_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021 performance is non-structural; assert model produces well-formed actions
pred FR_021_WellFormedActions {
  all act: Action | one act.kind and one act.outcome and one act.target and one act.caller
  some Action
}
assert FR_021_WellFormedActions { FR_021_WellFormedActions }
check FR_021_WellFormedActions for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeamAccess { some act: Action | act.outcome = OK and act.caller.userTeam != act.target.taskTeam }
