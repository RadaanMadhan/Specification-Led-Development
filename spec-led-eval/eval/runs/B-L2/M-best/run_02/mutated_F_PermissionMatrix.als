// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail (B-L2 / 007-team-tasks) ===

// ---- Roles ----
abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

// ---- Task status enum ----
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// ---- Audit change kind ----
abstract sig ChangeKind {}
one sig CreatedChange, ModifiedChange, DeletedChange extends ChangeKind {}

// ---- HTTP endpoints ----
abstract sig OperationKind {}
one sig PostTasks, GetTasksList, GetTaskById, PatchTask, DeleteTask, GetAudit
  extends OperationKind {}

// ---- Outcomes ----
abstract sig Outcome {}
one sig SuccessOutcome, UnauthenticatedOutcome, MissingTeamContextOutcome,
        NotFoundOutcome, PermissionDeniedOutcome, ValidationErrorOutcome
  extends Outcome {}

// ---- Dynamic entities ----
sig User {}
sig Team {}

sig TeamMembership {
  tmUser: one User,
  tmTeam: one Team,
  tmRole: one Role
}

sig Task {
  taskTeam: one Team,
  owner: one User,
  assignee: lone User,
  status: one TaskStatus
}

sig AuditEntry {
  auditTask: one Task,
  auditTeam: one Team,
  auditActor: one User,
  auditActorRole: one Role,
  auditKind: one ChangeKind
}

sig Operation {
  caller: lone User,
  callerTeam: lone Team,
  callerRole: lone Role,
  opKind: one OperationKind,
  target: lone Task,
  outcome: one Outcome,
  producesAudit: lone AuditEntry
}

// ---- Permission matrix as a singleton-sig field ----
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---- Non-empty universe so universal claims aren't vacuous ----
fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
  some Operation
}

// ---- Permission matrix (closed-world, per contracts/http-api.md) ----
fact F_PermissionMatrix { /* MUTATED — body cleared by validator */ }

// ---- TeamMembership uniqueness on (user, team), per data-model.md composite PK ----
fact F_UniqueMembership {
  all disj m1, m2: TeamMembership |
    not (m1.tmUser = m2.tmUser and m1.tmTeam = m2.tmTeam)
}

// ---- Authentication boundary (FR-001) ----
fact F_AuthRequired {
  all op: Operation |
    no op.caller implies op.outcome = UnauthenticatedOutcome
}

// ---- Team context boundary (FR-003) ----
fact F_TeamContextRequired {
  all op: Operation |
    (some op.caller and no op.callerTeam)
      implies op.outcome = MissingTeamContextOutcome
}

// ---- callerRole is derived from the (caller, callerTeam) team_memberships row ----
fact F_CallerRoleFromMembership {
  all op: Operation, r: Role |
    op.callerRole = r iff
      (some m: TeamMembership |
        m.tmUser = op.caller and m.tmTeam = op.callerTeam and m.tmRole = r)
}

// ---- Non-member of the resolved team → byte-equivalent 404 (FR-003 / FR-004) ----
fact F_MembershipRequired {
  all op: Operation |
    (some op.caller and some op.callerTeam and no op.callerRole)
      implies op.outcome = NotFoundOutcome
}

// ---- Cross-team isolation (FR-011 / FR-014): target in a different team → 404 ----
fact F_CrossTeamIsolation {
  all op: Operation |
    (some op.target and some op.callerTeam
     and op.target.taskTeam != op.callerTeam)
      implies op.outcome = NotFoundOutcome
}

// ---- Ownership-conditional edit/delete for members (FR-008 / FR-009 / FR-010) ----
fact F_OwnershipBasedEditDelete {
  all op: Operation |
    (op.opKind in (PatchTask + DeleteTask)
     and op.callerRole = MemberRole
     and some op.target
     and op.target.owner != op.caller)
      implies op.outcome != SuccessOutcome
}

// ---- Success implies the (role, op) cell is in the documented matrix ----
fact F_AllowedByMatrix {
  all op: Operation |
    op.outcome = SuccessOutcome implies
      (some op.callerRole and (op.callerRole -> op.opKind) in PermMatrix.Allowed)
}

// ---- One audit entry per save (FR-015); reads/failures produce no audit ----
fact F_AuditOneToOne {
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PostTasks + PatchTask + DeleteTask))
      implies one op.producesAudit
  all op: Operation |
    op.opKind in (GetTasksList + GetTaskById + GetAudit)
      implies no op.producesAudit
  all op: Operation |
    op.outcome != SuccessOutcome implies no op.producesAudit
}

// ---- Audit trail is append-only (FR-016): every entry has exactly one creator op ----
fact F_AppendOnlyAuditEntries {
  all ae: AuditEntry | (one op: Operation | op.producesAudit = ae)
  all disj op1, op2: Operation | no (op1.producesAudit & op2.producesAudit)
}

// ---- Audit attribution snapshots actor/role/team/task/kind (FR-015) ----
fact F_AuditAttribution {
  all op: Operation |
    some op.producesAudit implies (
      op.producesAudit.auditActor = op.caller and
      op.producesAudit.auditActorRole = op.callerRole and
      op.producesAudit.auditTask = op.target and
      op.producesAudit.auditTeam = op.callerTeam
    )
  all op: Operation |
    (some op.producesAudit and op.opKind = PostTasks)
      implies op.producesAudit.auditKind = CreatedChange
  all op: Operation |
    (some op.producesAudit and op.opKind = PatchTask)
      implies op.producesAudit.auditKind = ModifiedChange
  all op: Operation |
    (some op.producesAudit and op.opKind = DeleteTask)
      implies op.producesAudit.auditKind = DeletedChange
}

// ---- Owner == creator (FR-006); owner is captured by the Created audit entry ----
fact F_OwnerIsCreator {
  all ae: AuditEntry |
    ae.auditKind = CreatedChange implies ae.auditActor = ae.auditTask.owner
}

// ---- Audit entry's team matches the task's team (denormalised, FR-014/FR-017) ----
fact F_TaskTeamMatchesAudit {
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}

// ---- Assignee must be a current member of the same team (FR-012) ----
fact F_AssigneeSameTeam {
  all t: Task |
    some t.assignee implies
      (some m: TeamMembership |
        m.tmUser = t.assignee and m.tmTeam = t.taskTeam)
}

// ---- Owner is a current member of the task's team (data-model.md FK + membership) ----
fact F_OwnerInTeam {
  all t: Task |
    some m: TeamMembership | m.tmUser = t.owner and m.tmTeam = t.taskTeam
}

// ---- Operations on a specific task carry a target ----
fact F_OpTargetShape {
  all op: Operation |
    (op.opKind = PostTasks and op.outcome = SuccessOutcome) implies some op.target
  all op: Operation |
    op.opKind in (GetTaskById + PatchTask + DeleteTask + GetAudit)
      implies some op.target
}

// ====================================================================
// PATTERNS
// ====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008/009/010/011
pred LeastPrivilege {
  some Operation
  // Successful operation: caller must have a resolved role (i.e., is a member)
  all op: Operation | op.outcome = SuccessOutcome implies some op.callerRole
  // Member-role PATCH/DELETE only succeeds when the caller owns the target
  all op: Operation |
    (op.outcome = SuccessOutcome
     and op.opKind in (PatchTask + DeleteTask)
     and op.callerRole = MemberRole)
      implies op.target.owner = op.caller
  // Every successful (role, op) pair lies in the documented matrix
  all op: Operation |
    op.outcome = SuccessOutcome
      implies (op.callerRole -> op.opKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  MemberRole -> PostTasks      in PermMatrix.Allowed
  MemberRole -> GetTasksList   in PermMatrix.Allowed
  MemberRole -> GetTaskById    in PermMatrix.Allowed
  MemberRole -> PatchTask      in PermMatrix.Allowed
  MemberRole -> DeleteTask     in PermMatrix.Allowed
  MemberRole -> GetAudit       in PermMatrix.Allowed
  AdminRole  -> PostTasks      in PermMatrix.Allowed
  AdminRole  -> GetTasksList   in PermMatrix.Allowed
  AdminRole  -> GetTaskById    in PermMatrix.Allowed
  AdminRole  -> PatchTask      in PermMatrix.Allowed
  AdminRole  -> DeleteTask     in PermMatrix.Allowed
  AdminRole  -> GetAudit       in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-008/010/017 grant each matrix cell
pred PermissionGrounding {
  // Every cell traces back to a spec-granted permission: matrix is exactly the
  // 12 cells we documented, no silent grants.
  PermMatrix.Allowed in
    (MemberRole -> PostTasks) + (MemberRole -> GetTasksList) +
    (MemberRole -> GetTaskById) + (MemberRole -> PatchTask) +
    (MemberRole -> DeleteTask) + (MemberRole -> GetAudit) +
    (AdminRole  -> PostTasks) + (AdminRole  -> GetTasksList) +
    (AdminRole  -> GetTaskById) + (AdminRole  -> PatchTask) +
    (AdminRole  -> DeleteTask) + (AdminRole  -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010 admin ⊇ member
pred PrivilegeMonotonicity {
  all k: OperationKind |
    (MemberRole -> k) in PermMatrix.Allowed
      implies (AdminRole -> k) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts auth section
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | no op.caller implies op.outcome = UnauthenticatedOutcome
  all op: Operation | op.outcome = SuccessOutcome implies some op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md audit_entries 1:1 with save
pred AuditCompleteness {
  some AuditEntry
  // Every mutating success has exactly one audit entry
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PostTasks + PatchTask + DeleteTask))
      implies one op.producesAudit
  // Every audit entry is produced by exactly one operation
  all ae: AuditEntry | (one op: Operation | op.producesAudit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md no UPDATE/DELETE on audit_entries
pred AppendOnly {
  some AuditEntry
  // No two distinct ops share an audit entry (no overwrite)
  all disj op1, op2: Operation | no (op1.producesAudit & op2.producesAudit)
  // Every audit entry has a single creating operation
  all ae: AuditEntry | (one op: Operation | op.producesAudit = ae)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015 actor identity + role snapshot
pred AttributionCorrectness {
  some AuditEntry
  all op: Operation |
    some op.producesAudit implies (
      op.producesAudit.auditActor = op.caller and
      op.producesAudit.auditActorRole = op.callerRole and
      op.producesAudit.auditTask = op.target and
      op.producesAudit.auditTeam = op.callerTeam
    )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md tasks.owner_id NOT NULL; FR-006
pred OwnershipExclusivity {
  some Task
  all t: Task | one t.owner
  // Every task's owner is a current member of the task's team
  all t: Task |
    (some m: TeamMembership | m.tmUser = t.owner and m.tmTeam = t.taskTeam)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008/009/010; contracts permission matrix
pred OwnershipBasedAccess {
  some Operation
  // A member can only PATCH/DELETE tasks they own
  all op: Operation |
    (op.outcome = SuccessOutcome
     and op.opKind in (PatchTask + DeleteTask)
     and op.callerRole = MemberRole)
      implies op.target.owner = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-011/FR-014; contracts byte-equiv 404
pred NoInformationLeakage {
  some Operation
  // Any reference to a task in a different team than callerTeam yields NotFound,
  // not Success — preserving byte-equivalence with "no such task".
  all op: Operation |
    (some op.target and some op.callerTeam
     and op.target.taskTeam != op.callerTeam)
      implies op.outcome = NotFoundOutcome
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ====================================================================
// FEATURE-SPECIFIC FR-level assertions
// ====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 every request authenticated
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | no op.caller implies op.outcome = UnauthenticatedOutcome
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity resolved from auth, not payload
pred FR_002_IdentityFromAuth {
  some Operation
  // Successful operations always have a server-resolved caller identity
  all op: Operation | op.outcome = SuccessOutcome implies some op.caller
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 X-Team-Id required on every request
pred FR_003_TeamContextRequired {
  some Operation
  all op: Operation |
    (some op.caller and no op.callerTeam)
      implies op.outcome = MissingTeamContextOutcome
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 caller must be a current member of the resolved team
pred FR_004_MemberRequired {
  some Operation
  all op: Operation |
    (some op.caller and some op.callerTeam
     and (no m: TeamMembership | m.tmUser = op.caller and m.tmTeam = op.callerTeam))
      implies op.outcome = NotFoundOutcome
}
assert FR_004_MemberRequired { FR_004_MemberRequired }
check FR_004_MemberRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 task's team set at creation, exactly one
pred FR_005_TaskTeamSingleton {
  some Task
  all t: Task | one t.taskTeam
  // Audit entries for a task carry the task's team (denormalised, never drifts)
  all ae: AuditEntry | ae.auditTeam = ae.auditTask.taskTeam
}
assert FR_005_TaskTeamSingleton { FR_005_TaskTeamSingleton }
check FR_005_TaskTeamSingleton for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 owner is the creator, exactly one, immutable
pred FR_006_OwnerIsCreator {
  some Task
  some AuditEntry
  all t: Task | one t.owner
  all ae: AuditEntry |
    ae.auditKind = CreatedChange implies ae.auditActor = ae.auditTask.owner
}
assert FR_006_OwnerIsCreator { FR_006_OwnerIsCreator }
check FR_006_OwnerIsCreator for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 per-team role: at most one membership per (user, team)
pred FR_007_PerTeamRole {
  some TeamMembership
  all disj m1, m2: TeamMembership |
    not (m1.tmUser = m2.tmUser and m1.tmTeam = m2.tmTeam)
}
assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008/009/010 owner-or-admin edit/delete
pred FR_008_009_010_OwnerOrAdminEditDelete {
  some Operation
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PatchTask + DeleteTask))
      implies (op.callerRole = AdminRole or op.target.owner = op.caller)
}
assert FR_008_009_010_OwnerOrAdminEditDelete { FR_008_009_010_OwnerOrAdminEditDelete }
check FR_008_009_010_OwnerOrAdminEditDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011/FR-014 cross-team isolation invariant
pred FR_011_014_CrossTeamIsolation {
  some Operation
  all op: Operation |
    (some op.target and some op.callerTeam
     and op.target.taskTeam != op.callerTeam)
      implies op.outcome = NotFoundOutcome
}
assert FR_011_014_CrossTeamIsolation { FR_011_014_CrossTeamIsolation }
check FR_011_014_CrossTeamIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 assignee must be member of the same team
pred FR_012_AssigneeSameTeam {
  some Task
  all t: Task |
    some t.assignee implies
      (some m: TeamMembership |
        m.tmUser = t.assignee and m.tmTeam = t.taskTeam)
}
assert FR_012_AssigneeSameTeam { FR_012_AssigneeSameTeam }
check FR_012_AssigneeSameTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 status set is exactly {todo, in_progress, done}
pred FR_013_StatusSet {
  some Task
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_013_StatusSet { FR_013_StatusSet }
check FR_013_StatusSet for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 one audit entry per save (per-edit-event granularity)
pred FR_015_AuditPerEvent {
  some Operation
  all op: Operation |
    (op.outcome = SuccessOutcome and op.opKind in (PostTasks + PatchTask + DeleteTask))
      implies one op.producesAudit
  // Reads never produce audit
  all op: Operation |
    op.opKind in (GetTasksList + GetTaskById + GetAudit)
      implies no op.producesAudit
}
assert FR_015_AuditPerEvent { FR_015_AuditPerEvent }
check FR_015_AuditPerEvent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit append-only
pred FR_016_AuditAppendOnly {
  some AuditEntry
  all disj op1, op2: Operation | no (op1.producesAudit & op2.producesAudit)
  all ae: AuditEntry | (one op: Operation | op.producesAudit = ae)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit endpoint readable by any team member
pred FR_017_AuditReadableByMember {
  MemberRole -> GetAudit in PermMatrix.Allowed
  AdminRole  -> GetAudit in PermMatrix.Allowed
}
assert FR_017_AuditReadableByMember { FR_017_AuditReadableByMember }
check FR_017_AuditReadableByMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 retention (audit not deleted) — code-path absence
pred FR_018_AuditRetention {
  some AuditEntry
  // Operationally: deletion of a task does not delete its audit entries.
  // Structurally: every AuditEntry persists with a single producer; there is
  // no operation kind in the model that removes or modifies audit entries.
  all ae: AuditEntry | (one op: Operation | op.producesAudit = ae)
}
assert FR_018_AuditRetention { FR_018_AuditRetention }
check FR_018_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 list scoped to current team
pred FR_019_ListScopedToTeam {
  some Operation
  // A successful GetTasksList only returns within the caller's team — at the
  // operation level this is encoded as "list ops require caller in callerTeam".
  all op: Operation |
    (op.opKind = GetTasksList and op.outcome = SuccessOutcome)
      implies (some op.callerTeam and some op.callerRole)
}
assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 filters are team-scoped (subset of FR-019)
pred FR_020_FilterTeamScoped {
  some Operation
  all op: Operation |
    (op.opKind = GetTasksList and op.outcome = SuccessOutcome)
      implies (op.callerRole -> GetTasksList) in PermMatrix.Allowed
}
assert FR_020_FilterTeamScoped { FR_020_FilterTeamScoped }
check FR_020_FilterTeamScoped for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MatrixHole { MemberRole -> GetAudit not in PermMatrix.Allowed }
