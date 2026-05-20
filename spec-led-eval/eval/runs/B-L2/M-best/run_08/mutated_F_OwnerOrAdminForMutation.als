// === feature_model.als — Alloy model for B-L2 SaaS Team Task Management ===
// Feature: SaaS Team Task Management with Audit Trail (007-team-tasks)
// Encodes: authentication, X-Team-Id team context, per-team roles (member/admin),
// owner-or-admin mutation, cross-team isolation (byte-equivalent 404), per-edit
// audit entries with append-only and snapshotted attribution.

// ---------- Closed enumerations ----------

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig OperationKind {}
one sig CreateTask, ListTasks, ViewTask, EditTask, DeleteTaskOp, ViewAudit extends OperationKind {}

abstract sig ChangeKind {}
one sig CreatedC, ModifiedC, DeletedC extends ChangeKind {}

abstract sig Outcome {}
one sig Success, Unauthenticated, MissingTeam, NotFound, PermDenied, ValidationError extends Outcome {}

// ---------- Dynamic sigs ----------

sig User {}
sig Team {}

sig Membership {
  mUser: one User,
  mTeam: one Team,
  mRole: one Role
}

sig Task {
  tTeam: one Team,
  tOwner: one User,
  tAssignee: lone User
}

sig AuditEntry {
  aTask: one Task,
  aTeam: one Team,
  aActor: one User,
  aActorRole: one Role,
  aKind: one ChangeKind
}

// One "attempted operation" atom per request reaching the boundary.
// opCaller empty => unauthenticated. opTeam empty => no X-Team-Id header.
// opTask empty => endpoint with no task id (POST /tasks, GET /tasks list).
// opAudit empty => no audit entry produced by this op.
sig Operation {
  opCaller:  lone User,
  opTeam:    lone Team,
  opKind:    one OperationKind,
  opTask:    lone Task,
  opOutcome: one Outcome,
  opAudit:   lone AuditEntry
}

// ---------- Permission matrix as singleton-sig field (Role x OperationKind) ----------

one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe ----------

fact F_NonEmptyUniverse {
  some User
  some Team
  some Membership
  some Task
  some AuditEntry
  some Operation
}

// ---------- Permission matrix population (closed-world) ----------
// contracts/http-api.md permission table: both members and admins may attempt
// every endpoint within their team; ownership constraints on PATCH/DELETE are
// enforced separately by F_OwnerOrAdminForMutation.
fact F_PermissionMatrix {
  AdminRole  -> CreateTask    in PermMatrix.Allowed
  AdminRole  -> ListTasks     in PermMatrix.Allowed
  AdminRole  -> ViewTask      in PermMatrix.Allowed
  AdminRole  -> EditTask      in PermMatrix.Allowed
  AdminRole  -> DeleteTaskOp  in PermMatrix.Allowed
  AdminRole  -> ViewAudit     in PermMatrix.Allowed
  MemberRole -> CreateTask    in PermMatrix.Allowed
  MemberRole -> ListTasks     in PermMatrix.Allowed
  MemberRole -> ViewTask      in PermMatrix.Allowed
  MemberRole -> EditTask      in PermMatrix.Allowed
  MemberRole -> DeleteTaskOp  in PermMatrix.Allowed
  MemberRole -> ViewAudit     in PermMatrix.Allowed
  PermMatrix.Allowed =
       (AdminRole  -> CreateTask)   + (AdminRole  -> ListTasks)
     + (AdminRole  -> ViewTask)     + (AdminRole  -> EditTask)
     + (AdminRole  -> DeleteTaskOp) + (AdminRole  -> ViewAudit)
     + (MemberRole -> CreateTask)   + (MemberRole -> ListTasks)
     + (MemberRole -> ViewTask)     + (MemberRole -> EditTask)
     + (MemberRole -> DeleteTaskOp) + (MemberRole -> ViewAudit)
}

// ---------- Structural facts (each named for mutation targeting) ----------

// FR-007 / data-model.md team_memberships composite PK
fact F_MembershipUnique {
  all disj m1, m2: Membership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}

// FR-001 / SC-006: unauthenticated requests are rejected before any handler runs.
fact F_AuthRequired {
  all op: Operation | no op.opCaller implies op.opOutcome = Unauthenticated
}

// FR-003: missing X-Team-Id => 400 missing_team_context.
fact F_TeamContextRequired {
  all op: Operation |
    (some op.opCaller and no op.opTeam) implies op.opOutcome = MissingTeam
}

// FR-004 / FR-014: caller must be a current member of the resolved team;
// non-membership is byte-equivalent to "no such team" (NotFound).
fact F_NonMemberIsNotFound {
  all op: Operation |
    (some op.opCaller and some op.opTeam and
     (no m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeam))
    implies op.opOutcome = NotFound
}

// FR-011 / FR-014: cross-team task access => byte-equivalent 404.
fact F_CrossTeamIsolation {
  all op: Operation |
    (some op.opTask and some op.opTeam and op.opTask.tTeam != op.opTeam)
    implies op.opOutcome = NotFound
}

// FR-008 / FR-009 / FR-010: edit/delete success requires owner or team-admin role.
fact F_OwnerOrAdminForMutation { /* MUTATED — body cleared by validator */ }

// FR-015 / SC-007: every successful mutating op writes exactly one audit entry;
// read-only ops never write one; failed ops never write one.
fact F_AuditCompleteness {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (CreateTask + EditTask + DeleteTaskOp))
    implies (one op.opAudit)
  all op: Operation |
    op.opKind in (ListTasks + ViewTask + ViewAudit) implies (no op.opAudit)
  all op: Operation |
    op.opOutcome != Success implies (no op.opAudit)
}

// FR-016 / SC-008: each audit entry is produced by exactly one operation
// (no rewrite, no orphan; "append-only" at the structural level).
fact F_AppendOnlyOneSource {
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

// FR-015: audit entry attribution matches the operation that produced it.
fact F_AttributionCorrectness {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aActor = op.opCaller and
    op.opAudit.aTask  = op.opTask   and
    op.opAudit.aTeam  = op.opTeam
  )
}

// data-model.md: audit_entries.team_id is denormalised from the task's team.
fact F_AuditTeamMatchesTaskTeam {
  all ae: AuditEntry | ae.aTeam = ae.aTask.tTeam
}

// FR-015: audit kind matches operation kind.
fact F_AuditKindMatchesOp {
  all op: Operation | some op.opAudit implies (
    (op.opKind = CreateTask    implies op.opAudit.aKind = CreatedC)  and
    (op.opKind = EditTask      implies op.opAudit.aKind = ModifiedC) and
    (op.opKind = DeleteTaskOp  implies op.opAudit.aKind = DeletedC)
  )
}

// FR-015: snapshotted actor role equals caller's role for the resolved team.
fact F_ActorRoleSnapshot {
  all op: Operation | some op.opAudit implies (
    some m: Membership |
      m.mUser = op.opCaller and m.mTeam = op.opTeam and
      m.mRole = op.opAudit.aActorRole
  )
}

// FR-012: a task's assignee must be a current member of the task's team.
fact F_AssigneeInSameTeam {
  all t: Task | some t.tAssignee implies (
    some m: Membership | m.mUser = t.tAssignee and m.mTeam = t.tTeam
  )
}

// =================== PATTERN PREDICATES ===================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-011
pred LeastPrivilege {
  all op: Operation | op.opOutcome = Success implies (
    some m: Membership |
      m.mUser = op.opCaller and m.mTeam = op.opTeam and
      m.mRole -> op.opKind in PermMatrix.Allowed
  )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix (all cells defined)
pred PermissionCompleteness {
  all r: Role, k: OperationKind | r -> k in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-006
pred AuthRequiredEverywhere {
  all op: Operation | no op.opCaller implies op.opOutcome = Unauthenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007
pred AuditCompleteness {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (CreateTask + EditTask + DeleteTaskOp))
    implies (one op.opAudit)
  all op: Operation |
    op.opKind in (ListTasks + ViewTask + ViewAudit) implies (no op.opAudit)
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 (actor/role/timestamp recorded)
pred AttributionCorrectness {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aActor = op.opCaller and
    op.opAudit.aTask  = op.opTask   and
    op.opAudit.aTeam  = op.opTeam
  )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; team_memberships PK
pred OwnershipExclusivity {
  all t: Task | one t.tOwner
  all disj m1, m2: Membership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009, FR-010
pred OwnershipBasedAccess {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (EditTask + DeleteTaskOp) and some op.opTask)
    implies
      (op.opCaller = op.opTask.tOwner or
       (some m: Membership |
          m.mUser = op.opCaller and m.mTeam = op.opTeam and m.mRole = AdminRole))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  all op: Operation |
    (some op.opTask and some op.opTeam and op.opTask.tTeam != op.opTeam)
    implies op.opOutcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// =================== FEATURE-SPECIFIC PREDICATES (one per relevant FR) ===================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | no op.opCaller implies op.opOutcome = Unauthenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (missing X-Team-Id)
pred FR_003_TeamContextRequired {
  all op: Operation |
    (some op.opCaller and no op.opTeam) implies op.opOutcome = MissingTeam
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (caller must be a current member of resolved team)
pred FR_004_CallerIsMember {
  all op: Operation | op.opOutcome = Success implies (
    some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeam
  )
}
assert FR_004_CallerIsMember { FR_004_CallerIsMember }
check FR_004_CallerIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (per-team role; one membership row per user-team pair)
pred FR_007_OneRolePerUserPerTeam {
  all disj m1, m2: Membership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}
assert FR_007_OneRolePerUserPerTeam { FR_007_OneRolePerUserPerTeam }
check FR_007_OneRolePerUserPerTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (non-owner non-admin members cannot mutate)
pred FR_009_NonOwnerNonAdminCannotMutate {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (EditTask + DeleteTaskOp) and some op.opTask)
    implies
      (op.opCaller = op.opTask.tOwner or
       (some m: Membership |
          m.mUser = op.opCaller and m.mTeam = op.opTeam and m.mRole = AdminRole))
}
assert FR_009_NonOwnerNonAdminCannotMutate { FR_009_NonOwnerNonAdminCannotMutate }
check FR_009_NonOwnerNonAdminCannotMutate for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 / FR-014 (cross-team isolation, byte-equivalent 404)
pred FR_011_CrossTeamIsolation {
  all op: Operation |
    (some op.opTask and some op.opTeam and op.opTask.tTeam != op.opTeam)
    implies op.opOutcome = NotFound
}
assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (assignee must be in the task's team)
pred FR_012_AssigneeSameTeam {
  all t: Task | some t.tAssignee implies (
    some m: Membership | m.mUser = t.tAssignee and m.mTeam = t.tTeam
  )
}
assert FR_012_AssigneeSameTeam { FR_012_AssigneeSameTeam }
check FR_012_AssigneeSameTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit attribution + role snapshot + team consistency)
pred FR_015_AuditAttribution {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aActor = op.opCaller and
    op.opAudit.aTask  = op.opTask   and
    op.opAudit.aTeam  = op.opTeam   and
    op.opAudit.aTeam  = op.opAudit.aTask.tTeam
  )
  all op: Operation | some op.opAudit implies (
    some m: Membership |
      m.mUser = op.opCaller and m.mTeam = op.opTeam and
      m.mRole = op.opAudit.aActorRole
  )
}
assert FR_015_AuditAttribution { FR_015_AuditAttribution }
check FR_015_AuditAttribution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit trail append-only, no UPDATE/DELETE path)
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit endpoint readable only to current team members)
pred FR_017_AuditReadableByMembers {
  all op: Operation |
    (op.opKind = ViewAudit and op.opOutcome = Success) implies
      (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeam)
}
assert FR_017_AuditReadableByMembers { FR_017_AuditReadableByMembers }
check FR_017_AuditReadableByMembers for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NonOwnerEdit { some op: Operation | op.opKind = EditTask and op.opOutcome = Success and some op.opTask and op.opCaller != op.opTask.tOwner and (no m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeam and m.mRole = AdminRole) }
