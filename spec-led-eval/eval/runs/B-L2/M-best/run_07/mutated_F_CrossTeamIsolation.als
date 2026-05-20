// === feature_model.als — Alloy model for 007-team-tasks (SaaS Team Tasks + Audit) ===

// =========================
// Roles (data-model.md TeamMembership.role)
// =========================
abstract sig Role {}
one sig Member, Admin extends Role {}

// =========================
// Operation kinds (contracts/http-api.md endpoints)
// =========================
abstract sig OperationKind {}
one sig CreateTask, ListTasks, ReadTask, EditTask, DeleteTaskOp, ReadAudit extends OperationKind {}

// =========================
// Distinct outcome shapes — required for byte-equivalence reasoning
// =========================
abstract sig Outcome {}
one sig Success,
        AuthFailure,
        TeamContextMissing,
        NotMember404,
        NotFound404,
        PermissionDenied403,
        ValidationError extends Outcome {}

// =========================
// Bool helper
// =========================
abstract sig Bool {}
one sig True, False extends Bool {}

// =========================
// Closed status enum (FR-013)
// =========================
abstract sig Status {}
one sig Todo, InProgress, Done extends Status {}

// =========================
// Audit change kinds (FR-015 three shapes)
// =========================
abstract sig ChangeKind {}
one sig CreatedChg, ModifiedChg, DeletedChg extends ChangeKind {}

// =========================
// Core entities (data-model.md)
// =========================
sig User {}

sig Team {}

sig Membership {
  mUser: one User,
  mTeam: one Team,
  mRole: one Role
}

sig Task {
  taskTeam: one Team,
  ownerUser: one User,
  taskStatus: one Status
}

sig AuditEntry {
  aeTask: one Task,
  aeTeam: one Team,
  aeActor: one User,
  aeRole: one Role,
  aeChange: one ChangeKind
}

// =========================
// HTTP-level operation envelope
// =========================
sig Operation {
  opCaller:        lone User,       // empty ⇒ unauthenticated
  opTeamHeader:    lone Team,       // empty ⇒ X-Team-Id missing
  opKind:          one OperationKind,
  opTarget:        lone Task,
  opTitleValid:    one Bool,        // validation outcome for body fields
  opTriedSetOwner: one Bool,        // body attempted to mutate owner_id
  opOutcome:       one Outcome,
  opAudit:         lone AuditEntry
}

// =========================
// Permission matrix as a singleton-sig field (per system-prompt canonical pattern)
// =========================
one sig PermMatrix {
  Unconditional:    set Role -> OperationKind,
  OwnerConditional: set Role -> OperationKind
}

// =========================
// Non-empty universe — prevents vacuous truth in `all` predicates
// =========================
fact F_NonEmptyUniverse {
  some User
  some Team
  some Membership
  some Task
  some AuditEntry
  some Operation
}

// =========================
// Closed-world permission matrix (contracts/http-api.md table)
// =========================
fact F_PermissionMatrix {
  PermMatrix.Unconditional =
      (Member -> CreateTask) + (Member -> ListTasks) + (Member -> ReadTask) + (Member -> ReadAudit) +
      (Admin  -> CreateTask) + (Admin  -> ListTasks) + (Admin  -> ReadTask) + (Admin  -> ReadAudit) +
      (Admin  -> EditTask)   + (Admin  -> DeleteTaskOp)
  PermMatrix.OwnerConditional =
      (Member -> EditTask) + (Member -> DeleteTaskOp)
  no (PermMatrix.Unconditional & PermMatrix.OwnerConditional)
}

// =========================
// FR-007: at most one membership per (user, team)
// =========================
fact F_OneMembershipPerUserTeam {
  all disj m1, m2: Membership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}

// =========================
// FR-006/FR-008: a task's owner is a current member of the task's team
// =========================
fact F_TaskOwnerIsTeamMember {
  all t: Task | some m: Membership |
    m.mUser = t.ownerUser and m.mTeam = t.taskTeam
}

// =========================
// FR-001: authentication required before any business logic
// =========================
fact F_AuthRequired {
  all op: Operation |
    (no op.opCaller) implies (op.opOutcome = AuthFailure and no op.opAudit)
}

// =========================
// FR-003: X-Team-Id required after auth
// =========================
fact F_TeamContextRequired {
  all op: Operation |
    (some op.opCaller and no op.opTeamHeader)
      implies (op.opOutcome = TeamContextMissing and no op.opAudit)
}

// =========================
// FR-003/FR-004: caller's team header must resolve to a membership
// =========================
fact F_NonMemberRejected {
  all op: Operation |
    (some op.opCaller and some op.opTeamHeader and
     (no m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamHeader))
      implies (op.opOutcome = NotMember404 and no op.opAudit)
}

// =========================
// FR-011/FR-014: cross-team target on success is forbidden
// =========================
fact F_CrossTeamIsolation { /* MUTATED — body cleared by validator */ }

// =========================
// FR-014: cross-team requests where caller is a legitimate member of their own
//          team but the target lives elsewhere must look like NotFound404 (byte-equiv)
// =========================
fact F_CrossTeamReturnsNotFound {
  all op: Operation |
    (some op.opCaller and some op.opTeamHeader and some op.opTarget and
     (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamHeader) and
     op.opTarget.taskTeam != op.opTeamHeader)
      implies (op.opOutcome = NotFound404 and no op.opAudit)
}

// =========================
// FR-008/FR-009/FR-010: permission-matrix enforcement on success
// =========================
fact F_PermissionEnforcement {
  all op: Operation |
    op.opOutcome = Success implies (
      some op.opCaller and some op.opTeamHeader and
      (some m: Membership |
        m.mUser = op.opCaller and m.mTeam = op.opTeamHeader and
        (m.mRole -> op.opKind in PermMatrix.Unconditional or
         (m.mRole -> op.opKind in PermMatrix.OwnerConditional and
          some op.opTarget and op.opTarget.ownerUser = op.opCaller)))
    )
}

// =========================
// FR-006: owner_id immutable in v1; any PATCH touching it is a validation_error
// =========================
fact F_OwnerImmutable {
  all op: Operation |
    (op.opKind = EditTask and op.opTriedSetOwner = True)
      implies (op.opOutcome = ValidationError and no op.opAudit)
}

// =========================
// FR-012: validation before mutation — invalid input ⇒ no success, no audit
// =========================
fact F_ValidationBeforeMutation {
  all op: Operation |
    (op.opKind in (CreateTask + EditTask) and op.opTitleValid = False)
      implies (op.opOutcome = ValidationError and no op.opAudit)
}

// =========================
// FR-015 / SC-007: every successful mutating op writes exactly one audit;
//                  reads write none; failures write none.
// =========================
fact F_AuditCompleteness {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (CreateTask + EditTask + DeleteTaskOp))
      implies (one op.opAudit)
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (ListTasks + ReadTask + ReadAudit))
      implies no op.opAudit
  all op: Operation |
    op.opOutcome != Success implies no op.opAudit
}

// =========================
// FR-016 / FR-018: audit append-only — every entry has exactly one originating op
// =========================
fact F_AppendOnly {
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}

// =========================
// FR-002 / FR-015: audit entries snapshot the actor & role of the authenticating op
// =========================
fact F_AttributionCorrectness {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aeActor = op.opCaller and
    op.opAudit.aeTeam = op.opTeamHeader and
    (some op.opTarget implies op.opAudit.aeTask = op.opTarget) and
    (some m: Membership |
       m.mUser = op.opCaller and m.mTeam = op.opTeamHeader and
       m.mRole = op.opAudit.aeRole)
  )
}

// =========================
// FR-015: audit change-kind matches the operation that wrote it
// =========================
fact F_AuditChangeKindMatch {
  all op: Operation | some op.opAudit implies (
    (op.opKind = CreateTask   implies op.opAudit.aeChange = CreatedChg) and
    (op.opKind = EditTask     implies op.opAudit.aeChange = ModifiedChg) and
    (op.opKind = DeleteTaskOp implies op.opAudit.aeChange = DeletedChg)
  )
}

// =========================================================================
// PATTERN PREDICATES
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008/009/010
pred LeastPrivilege {
  all op: Operation | op.opOutcome = Success implies (
    some m: Membership |
      m.mUser = op.opCaller and m.mTeam = op.opTeamHeader and
      (m.mRole -> op.opKind in PermMatrix.Unconditional or
       (m.mRole -> op.opKind in PermMatrix.OwnerConditional and
        some op.opTarget and op.opTarget.ownerUser = op.opCaller))
  )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table (closed-world)
pred PermissionCompleteness {
  // Each load-bearing cell appears in exactly one verdict relation
  Admin  -> CreateTask    in PermMatrix.Unconditional
  Admin  -> ListTasks     in PermMatrix.Unconditional
  Admin  -> ReadTask      in PermMatrix.Unconditional
  Admin  -> EditTask      in PermMatrix.Unconditional
  Admin  -> DeleteTaskOp  in PermMatrix.Unconditional
  Admin  -> ReadAudit     in PermMatrix.Unconditional
  Member -> CreateTask    in PermMatrix.Unconditional
  Member -> ListTasks     in PermMatrix.Unconditional
  Member -> ReadTask      in PermMatrix.Unconditional
  Member -> ReadAudit     in PermMatrix.Unconditional
  Member -> EditTask      in PermMatrix.OwnerConditional
  Member -> DeleteTaskOp  in PermMatrix.OwnerConditional
  no (PermMatrix.Unconditional & PermMatrix.OwnerConditional)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 (admin ⊇ member)
pred PrivilegeMonotonicity {
  all k: OperationKind |
    (Member -> k in (PermMatrix.Unconditional + PermMatrix.OwnerConditional))
      implies (Admin -> k in PermMatrix.Unconditional)
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001 / SC-006
pred AuthRequiredEverywhere {
  all op: Operation | (no op.opCaller) implies op.opOutcome = AuthFailure
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015 / SC-007
pred AuditCompleteness {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (CreateTask + EditTask + DeleteTaskOp))
      implies (one op.opAudit)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016 / data-model.md "no UPDATE/DELETE path"
pred AppendOnly {
  // No orphan audit rows and no two ops share the same audit row
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 actor & role snapshot
pred AttributionCorrectness {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aeActor = op.opCaller and
    op.opAudit.aeTeam = op.opTeamHeader and
    (some op.opTarget implies op.opAudit.aeTask = op.opTarget)
  )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Task.owner_id NOT NULL; FR-006
pred OwnershipExclusivity {
  all t: Task | (one t.ownerUser and
                 (some m: Membership |
                    m.mUser = t.ownerUser and m.mTeam = t.taskTeam))
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/FR-009
pred OwnershipBasedAccess {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (EditTask + DeleteTaskOp))
      implies (
        (some m: Membership |
           m.mUser = op.opCaller and m.mTeam = op.opTeamHeader and m.mRole = Admin)
        or
        (some op.opTarget and op.opTarget.ownerUser = op.opCaller)
      )
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014 byte-equivalent 404
pred NoInformationLeakage {
  all op: Operation |
    (some op.opCaller and some op.opTeamHeader and some op.opTarget and
     (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamHeader) and
     op.opTarget.taskTeam != op.opTeamHeader)
      implies op.opOutcome = NotFound404
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-012
pred ValidationBeforeMutation {
  all op: Operation |
    (op.opKind in (CreateTask + EditTask) and op.opTitleValid = False)
      implies (op.opOutcome != Success and no op.opAudit)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// =========================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR)
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required
pred FR_001_AuthRequired {
  all op: Operation |
    (no op.opCaller) implies (op.opOutcome = AuthFailure and no op.opAudit)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity from auth context
pred FR_002_IdentityFromAuth {
  all op: Operation | some op.opAudit implies op.opAudit.aeActor = op.opCaller
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 X-Team-Id required
pred FR_003_TeamContextRequired {
  all op: Operation |
    (some op.opCaller and no op.opTeamHeader)
      implies op.opOutcome = TeamContextMissing
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 caller must be current member of resolved team
pred FR_004_CallerMustBeMember {
  all op: Operation | op.opOutcome = Success implies (
    some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamHeader
  )
}
assert FR_004_CallerMustBeMember { FR_004_CallerMustBeMember }
check FR_004_CallerMustBeMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 task team set at creation, immutable
pred FR_005_TaskHasOneTeam {
  all t: Task | one t.taskTeam
}
assert FR_005_TaskHasOneTeam { FR_005_TaskHasOneTeam }
check FR_005_TaskHasOneTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 owner_id immutable in v1
pred FR_006_OwnerImmutable {
  all op: Operation |
    (op.opKind = EditTask and op.opTriedSetOwner = True)
      implies op.opOutcome != Success
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role; user can have different roles in different teams
pred FR_007_PerTeamRole {
  all disj m1, m2: Membership |
    not (m1.mUser = m2.mUser and m1.mTeam = m2.mTeam)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 member may create / view / edit-own / delete-own in their team
pred FR_008_MemberCRUDOwn {
  Member -> CreateTask in PermMatrix.Unconditional
  Member -> ReadTask in PermMatrix.Unconditional
  Member -> EditTask in PermMatrix.OwnerConditional
  Member -> DeleteTaskOp in PermMatrix.OwnerConditional
}
assert FR_008_MemberCRUDOwn { FR_008_MemberCRUDOwn }
check FR_008_MemberCRUDOwn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-owner member cannot edit/delete
pred FR_009_NonOwnerMemberCannotEdit {
  all op: Operation |
    (op.opOutcome = Success and op.opKind in (EditTask + DeleteTaskOp) and
     (some m: Membership |
        m.mUser = op.opCaller and m.mTeam = op.opTeamHeader and m.mRole = Member))
      implies (some op.opTarget and op.opTarget.ownerUser = op.opCaller)
}
assert FR_009_NonOwnerMemberCannotEdit { FR_009_NonOwnerMemberCannotEdit }
check FR_009_NonOwnerMemberCannotEdit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 admin can edit/delete any task in team
pred FR_010_AdminFullAccess {
  Admin -> EditTask in PermMatrix.Unconditional
  Admin -> DeleteTaskOp in PermMatrix.Unconditional
  Admin -> ReadAudit in PermMatrix.Unconditional
}
assert FR_010_AdminFullAccess { FR_010_AdminFullAccess }
check FR_010_AdminFullAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 no role grants cross-team access (overrides admin)
pred FR_011_NoCrossTeamRegardlessOfRole {
  all op: Operation |
    (op.opOutcome = Success and some op.opTarget)
      implies op.opTarget.taskTeam = op.opTeamHeader
}
assert FR_011_NoCrossTeamRegardlessOfRole { FR_011_NoCrossTeamRegardlessOfRole }
check FR_011_NoCrossTeamRegardlessOfRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 validation rules
pred FR_012_ValidationRules {
  all op: Operation |
    (op.opKind in (CreateTask + EditTask) and op.opTitleValid = False)
      implies op.opOutcome != Success
}
assert FR_012_ValidationRules { FR_012_ValidationRules }
check FR_012_ValidationRules for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 closed status set { todo, in_progress, done }
pred FR_013_StatusSet {
  all t: Task | one t.taskStatus
  Status = Todo + InProgress + Done
}
assert FR_013_StatusSet { FR_013_StatusSet }
check FR_013_StatusSet for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 cross-team byte-equivalent 404
pred FR_014_ByteEquivalentNotFound {
  all op: Operation |
    (some op.opCaller and some op.opTeamHeader and some op.opTarget and
     (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamHeader) and
     op.opTarget.taskTeam != op.opTeamHeader)
      implies op.opOutcome = NotFound404
}
assert FR_014_ByteEquivalentNotFound { FR_014_ByteEquivalentNotFound }
check FR_014_ByteEquivalentNotFound for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit entry shape & role snapshot
pred FR_015_AuditAttribution {
  all op: Operation | some op.opAudit implies (
    op.opAudit.aeActor = op.opCaller and
    op.opAudit.aeTeam = op.opTeamHeader and
    (some m: Membership |
       m.mUser = op.opCaller and m.mTeam = op.opTeamHeader and
       m.mRole = op.opAudit.aeRole)
  )
}
assert FR_015_AuditAttribution { FR_015_AuditAttribution }
check FR_015_AuditAttribution for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit immutability (no UPDATE/DELETE path)
pred FR_016_AuditAppendOnly {
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit readable by any current team member
pred FR_017_AuditVisibleToMembers {
  Member -> ReadAudit in PermMatrix.Unconditional
  Admin  -> ReadAudit in PermMatrix.Unconditional
}
assert FR_017_AuditVisibleToMembers { FR_017_AuditVisibleToMembers }
check FR_017_AuditVisibleToMembers for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 ≥12-month retention via absence of deletion path
pred FR_018_AuditRetention {
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert FR_018_AuditRetention { FR_018_AuditRetention }
check FR_018_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 listing available to team members
pred FR_019_ListAccessibleToMembers {
  Member -> ListTasks in PermMatrix.Unconditional
  Admin  -> ListTasks in PermMatrix.Unconditional
}
assert FR_019_ListAccessibleToMembers { FR_019_ListAccessibleToMembers }
check FR_019_ListAccessibleToMembers for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 filtering — listing remains scoped to caller's team
pred FR_020_ListScopedToTeam {
  all op: Operation |
    (op.opKind = ListTasks and op.opOutcome = Success)
      implies (some m: Membership |
                  m.mUser = op.opCaller and m.mTeam = op.opTeamHeader)
}
assert FR_020_ListScopedToTeam { FR_020_ListScopedToTeam }
check FR_020_ListScopedToTeam for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CrossTeamViolation { some op: Operation | op.opOutcome = Success and some op.opTarget and some op.opTeamHeader and op.opTarget.taskTeam != op.opTeamHeader and (some m: Membership | m.mUser = op.opCaller and m.mTeam = op.opTeamHeader) }
