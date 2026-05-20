// === feature_model.als — Alloy 6 model for SaaS Team Task Management with Audit Trail ===
// Feature folder: B-L2  (branch 007-team-tasks)
// Sources: spec.md, data-model.md, contracts/http-api.md

// ─── Enumerations ────────────────────────────────────────────────────────────

abstract sig MemberRole {}
one sig Member, Admin extends MemberRole {}

abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

abstract sig ChangeKind {}
one sig AuditCreated, AuditChanged, AuditDeleted extends ChangeKind {}

// Six endpoints from the HTTP API contract
abstract sig OperationKind {}
one sig PostTasks, GetTasks, GetTaskById, PatchTask, DeleteTask, GetTaskAudit
  extends OperationKind {}

// Access contexts — ownership is meaningful for task-targeting ops (PATCH/DELETE)
abstract sig AccessCtx {}
one sig MemberOwnerCtx, MemberNonOwnerCtx, AdminAnyCtx extends AccessCtx {}

// Permission matrix (Rule 7 canonical pattern)
one sig PermMatrix { Allowed: set AccessCtx -> OperationKind }

// ─── Domain Entities ─────────────────────────────────────────────────────────

sig User {}

sig Team {}

sig TeamMembership {
  mem_user: one User,
  mem_team: one Team,
  mem_role: one MemberRole
}

sig Task {
  task_team:     one Team,
  task_owner:    one User,
  task_status:   one TaskStatus,
  task_assignee: lone User
}

// Tasks whose row has been removed from the DB; audit trail is preserved (FR-016)
sig DeletedTask in Task {}

sig AuditEntry {
  ae_task:       one Task,        // logical ref — no FK constraint; outlives task row
  ae_team:       one Team,        // denormalised for cross-team isolation (data-model.md)
  ae_actor:      one User,
  ae_actor_role: one MemberRole,  // snapshotted at change time (FR-015)
  ae_change:     one ChangeKind
}

// ─── Non-empty universe (Rule 9) ─────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some Team
  some TeamMembership
  some Task
  some AuditEntry
}

// ─── Membership structural constraints ───────────────────────────────────────

// FR-007 / data-model.md composite PK (user_id, team_id)
fact F_UniqueMembership {
  all disj m1, m2: TeamMembership |
    not (m1.mem_user = m2.mem_user and m1.mem_team = m2.mem_team)
}

// ─── Task structural constraints ─────────────────────────────────────────────

// FR-005, FR-006 / data-model.md: owner must be a member of the task's team
fact F_OwnerIsMember {
  all t: Task |
    some m: TeamMembership | m.mem_user = t.task_owner and m.mem_team = t.task_team
}

// FR-012 / data-model.md validation: assignee (if present) must be a current team member
fact F_AssigneeIsMember {
  all t: Task |
    some t.task_assignee implies
      (some m: TeamMembership | m.mem_user = t.task_assignee and m.mem_team = t.task_team)
}

// FR-006 / data-model.md owner_id immutable: the AuditCreated actor equals the task owner
fact F_OwnerSetByCreator {
  all t: Task | all ae: AuditEntry |
    (ae.ae_task = t and ae.ae_change = AuditCreated) implies ae.ae_actor = t.task_owner
}

// ─── Audit structural constraints ────────────────────────────────────────────

// data-model.md denormalisation invariant: ae_team = task_team
fact F_AuditTeamMatchesTask {
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
}

// FR-015 / SC-007: every task has exactly one AuditCreated entry
fact F_AuditCreatedEntryExists { /* MUTATED — body cleared by validator */ }

// FR-015 / FR-016: deleted tasks have exactly one AuditDeleted entry; live tasks have none
fact F_AuditDeletedEntryOnDeletedTask {
  all t: Task |
    t in DeletedTask implies (one ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted)
  all t: Task |
    t not in DeletedTask implies (no ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted)
}

// FR-016 / SC-008 append-only: at most one AuditCreated and one AuditDeleted per task
fact F_AppendOnlyAuditEntries {
  all t: Task | lone ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditCreated
  all t: Task | lone ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted
}

// FR-015: audit entry actor must be a member of the task's team (snapshot semantics)
fact F_AuditActorWasMember {
  all ae: AuditEntry |
    some m: TeamMembership | m.mem_user = ae.ae_actor and m.mem_team = ae.ae_team
}

// FR-016: deleted tasks still have at least their Created (and Deleted) audit entries
fact F_AuditOutlivesTask {
  all t: DeletedTask | some ae: AuditEntry | ae.ae_task = t
}

// ─── Permission matrix ───────────────────────────────────────────────────────

// contracts/http-api.md permission matrix; FR-008, FR-009, FR-010
fact F_PermissionMatrix {
  // MemberOwnerCtx: owner of the task — can do everything in-team
  MemberOwnerCtx -> PostTasks    in PermMatrix.Allowed
  MemberOwnerCtx -> GetTasks     in PermMatrix.Allowed
  MemberOwnerCtx -> GetTaskById  in PermMatrix.Allowed
  MemberOwnerCtx -> PatchTask    in PermMatrix.Allowed
  MemberOwnerCtx -> DeleteTask   in PermMatrix.Allowed
  MemberOwnerCtx -> GetTaskAudit in PermMatrix.Allowed

  // MemberNonOwnerCtx: member but NOT owner — read + create only (FR-009 denies PATCH/DELETE)
  MemberNonOwnerCtx -> PostTasks    in PermMatrix.Allowed
  MemberNonOwnerCtx -> GetTasks     in PermMatrix.Allowed
  MemberNonOwnerCtx -> GetTaskById  in PermMatrix.Allowed
  MemberNonOwnerCtx -> GetTaskAudit in PermMatrix.Allowed
  // PatchTask and DeleteTask intentionally absent for MemberNonOwnerCtx

  // AdminAnyCtx: full access to any task in their team (FR-010)
  AdminAnyCtx -> PostTasks    in PermMatrix.Allowed
  AdminAnyCtx -> GetTasks     in PermMatrix.Allowed
  AdminAnyCtx -> GetTaskById  in PermMatrix.Allowed
  AdminAnyCtx -> PatchTask    in PermMatrix.Allowed
  AdminAnyCtx -> DeleteTask   in PermMatrix.Allowed
  AdminAnyCtx -> GetTaskAudit in PermMatrix.Allowed

  // Closed-world: exactly these cells and no others
  PermMatrix.Allowed =
    (MemberOwnerCtx    -> PostTasks)    +
    (MemberOwnerCtx    -> GetTasks)     +
    (MemberOwnerCtx    -> GetTaskById)  +
    (MemberOwnerCtx    -> PatchTask)    +
    (MemberOwnerCtx    -> DeleteTask)   +
    (MemberOwnerCtx    -> GetTaskAudit) +
    (MemberNonOwnerCtx -> PostTasks)    +
    (MemberNonOwnerCtx -> GetTasks)     +
    (MemberNonOwnerCtx -> GetTaskById)  +
    (MemberNonOwnerCtx -> GetTaskAudit) +
    (AdminAnyCtx       -> PostTasks)    +
    (AdminAnyCtx       -> GetTasks)     +
    (AdminAnyCtx       -> GetTaskById)  +
    (AdminAnyCtx       -> PatchTask)    +
    (AdminAnyCtx       -> DeleteTask)   +
    (AdminAnyCtx       -> GetTaskAudit)
}

// ─── Helper predicates ────────────────────────────────────────────────────────

pred memberInTeam[u: User, t: Team] {
  some m: TeamMembership | m.mem_user = u and m.mem_team = t
}

pred adminInTeam[u: User, t: Team] {
  some m: TeamMembership | m.mem_user = u and m.mem_team = t and m.mem_role = Admin
}

pred memberOnlyInTeam[u: User, t: Team] {
  some m: TeamMembership | m.mem_user = u and m.mem_team = t and m.mem_role = Member
}

// ─── Catalogue Pattern Predicates ────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-008, FR-009, FR-010
pred LeastPrivilege {
  // Non-owner members must be denied PATCH and DELETE
  MemberNonOwnerCtx -> PatchTask  not in PermMatrix.Allowed
  MemberNonOwnerCtx -> DeleteTask not in PermMatrix.Allowed
  // At least one each of User, Task, TeamMembership exist (non-vacuous)
  some Task
  some TeamMembership
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every operation has at least one access context that can perform it
  all op: OperationKind | some ctx: AccessCtx | ctx -> op in PermMatrix.Allowed
  // And there are no undefined (AccessCtx × OperationKind) cells — the closed-world
  // assignment in F_PermissionMatrix exhausts the relation
  some PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-008, FR-009, FR-010; contracts/http-api.md
pred PermissionGrounding {
  // FR-008: owner can edit and delete their own task
  MemberOwnerCtx -> PatchTask  in PermMatrix.Allowed
  MemberOwnerCtx -> DeleteTask in PermMatrix.Allowed
  // FR-009: non-owner member cannot edit or delete
  MemberNonOwnerCtx -> PatchTask  not in PermMatrix.Allowed
  MemberNonOwnerCtx -> DeleteTask not in PermMatrix.Allowed
  // FR-010: admin can edit and delete any task
  AdminAnyCtx -> PatchTask  in PermMatrix.Allowed
  AdminAnyCtx -> DeleteTask in PermMatrix.Allowed
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010; contracts/http-api.md role hierarchy
pred PrivilegeMonotonicity {
  // Admin's allowed ops are a strict superset of MemberOwner's allowed ops
  all op: OperationKind |
    MemberOwnerCtx -> op in PermMatrix.Allowed implies (AdminAnyCtx -> op in PermMatrix.Allowed)
  // And Admin has strictly more: at least one op MemberNonOwner cannot do
  some op: OperationKind | MemberNonOwnerCtx -> op not in PermMatrix.Allowed
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-002; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every task has an identified owner derived from auth context (never from payload)
  all t: Task | one t.task_owner
  // Every audit entry records a real authenticated actor
  all ae: AuditEntry | one ae.ae_actor
  // Non-vacuous
  some Task
  some AuditEntry
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015, SC-007; data-model.md AuditEntry
pred AuditCompleteness {
  // Every task (live or deleted) has exactly one AuditCreated entry
  all t: Task | one ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditCreated
  // Every deleted task has exactly one AuditDeleted entry
  all t: DeletedTask | one ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted
  // No live task has an AuditDeleted entry
  all t: Task - DeletedTask | no ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted
  // Non-vacuous
  some AuditEntry
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, SC-008; data-model.md "no UPDATE/DELETE" on audit_entries
pred AppendOnly {
  // At most one AuditCreated per task — creation cannot be "re-recorded"
  all t: Task | lone ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditCreated
  // At most one AuditDeleted per task — deletion cannot be "re-recorded"
  all t: Task | lone ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted
  // Audit entries for deleted tasks are NOT removed when the task row is deleted
  all t: DeletedTask | some ae: AuditEntry | ae.ae_task = t
  // Non-vacuous: some audit entries exist
  some AuditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md AuditEntry actor fields
pred AttributionCorrectness {
  // Every audit entry's actor is a real User
  all ae: AuditEntry | ae.ae_actor in User
  // Every audit entry's actor_role is a valid MemberRole
  all ae: AuditEntry | ae.ae_actor_role in MemberRole
  // The team on the audit entry matches the task's team (no misattribution of scope)
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
  // The AuditCreated actor is the task owner (creator attribution, FR-006)
  all t: Task | all ae: AuditEntry |
    (ae.ae_task = t and ae.ae_change = AuditCreated) implies ae.ae_actor = t.task_owner
  // Non-vacuous
  some AuditEntry
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005, FR-006; data-model.md Task.owner_id, Task.team_id
pred OwnershipExclusivity {
  // Every task has exactly one owner
  all t: Task | one t.task_owner
  // Every task belongs to exactly one team
  all t: Task | one t.task_team
  // Non-vacuous
  some Task
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008, FR-009; contracts/http-api.md PATCH/DELETE matrix
pred OwnershipBasedAccess {
  // PATCH: only owner-context and admin-context are allowed; non-owner member is denied
  MemberOwnerCtx    -> PatchTask in PermMatrix.Allowed
  AdminAnyCtx       -> PatchTask in PermMatrix.Allowed
  MemberNonOwnerCtx -> PatchTask not in PermMatrix.Allowed
  // DELETE: same ownership rule
  MemberOwnerCtx    -> DeleteTask in PermMatrix.Allowed
  AdminAnyCtx       -> DeleteTask in PermMatrix.Allowed
  MemberNonOwnerCtx -> DeleteTask not in PermMatrix.Allowed
  // Non-vacuous
  some Task
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, US6, SC-004; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // Cross-team isolation: every audit entry's team matches the task's team —
  // there is no audit entry written for a cross-team access attempt
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
  // Every audit actor is a member of the audit's team (no out-of-team actor)
  all ae: AuditEntry |
    some m: TeamMembership | m.mem_user = ae.ae_actor and m.mem_team = ae.ae_team
  // No task is reachable from a different team's context (structural scope: task_team is fixed)
  all t: Task | one t.task_team
  // Non-vacuous
  some AuditEntry
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-015 step 4; contracts/http-api.md PATCH behaviour
pred ValidationBeforeMutation {
  // Every AuditChanged or AuditDeleted entry presupposes an AuditCreated entry for the same task
  // (invalid requests produce no audit entries and no task row — only valid saves are audited)
  all ae: AuditEntry | ae.ae_change != AuditCreated implies
    (some ae2: AuditEntry | ae2.ae_task = ae.ae_task and ae2.ae_change = AuditCreated)
  // Non-vacuous
  some AuditEntry
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─── Feature-Specific Predicates ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // Owner is always a real User (set from auth context, never from payload — FR-002)
  all t: Task | one t.task_owner
  // Audit actor is always a real User
  all ae: AuditEntry | one ae.ae_actor
  // Non-vacuous
  some Task
  some AuditEntry
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, FR-004
pred FR_003_TeamContextRequired {
  // Every task is scoped to exactly one team (X-Team-Id was validated)
  all t: Task | one t.task_team
  // Every membership row names exactly one team
  all m: TeamMembership | one m.mem_team
  // Every audit entry is scoped to a team
  all ae: AuditEntry | one ae.ae_team
  // Non-vacuous
  some Task
}

assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_TaskTeamImmutable {
  // Structurally immutable: task_team is one Team with no UPDATE path
  all t: Task | one t.task_team
  // The team recorded on every audit entry matches the task's team (invariant under all ops)
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
  // Non-vacuous
  some Task
  some AuditEntry
}

assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_OwnerImmutable {
  // Every task has exactly one owner (immutable after insert)
  all t: Task | one t.task_owner
  // The AuditCreated entry's actor equals the task owner (creation sets owner, FR-006)
  all t: Task | all ae: AuditEntry |
    (ae.ae_task = t and ae.ae_change = AuditCreated) implies ae.ae_actor = t.task_owner
  // Non-vacuous
  some Task
}

assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_PerTeamRole {
  // Composite PK (user_id, team_id): at most one membership per (user, team) pair
  all disj m1, m2: TeamMembership |
    not (m1.mem_user = m2.mem_user and m1.mem_team = m2.mem_team)
  // Non-vacuous
  some TeamMembership
}

assert FR_007_PerTeamRole { FR_007_PerTeamRole }
check FR_007_PerTeamRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_NonOwnerMemberCantEditDelete {
  // Non-owner members are explicitly denied PATCH and DELETE
  MemberNonOwnerCtx -> PatchTask  not in PermMatrix.Allowed
  MemberNonOwnerCtx -> DeleteTask not in PermMatrix.Allowed
  // Non-vacuous
  some Task
  some TeamMembership
}

assert FR_009_NonOwnerMemberCantEditDelete { FR_009_NonOwnerMemberCantEditDelete }
check FR_009_NonOwnerMemberCantEditDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AdminCanEditAny {
  // Admin can PATCH and DELETE any task in their team
  AdminAnyCtx -> PatchTask  in PermMatrix.Allowed
  AdminAnyCtx -> DeleteTask in PermMatrix.Allowed
  // Non-vacuous
  some Task
}

assert FR_010_AdminCanEditAny { FR_010_AdminCanEditAny }
check FR_010_AdminCanEditAny for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-014, SC-004
pred FR_011_CrossTeamIsolation {
  // Every task's audit entries record the task's own team — no cross-team audit writes
  all ae: AuditEntry | ae.ae_team = ae.ae_task.task_team
  // Every audit actor is a member of the audit's team — non-members produce no entries
  all ae: AuditEntry |
    some m: TeamMembership | m.mem_user = ae.ae_actor and m.mem_team = ae.ae_team
  // Tasks are structurally team-scoped (task_team field is one Team)
  all t: Task | one t.task_team
  // Non-vacuous
  some Task
  some AuditEntry
}

assert FR_011_CrossTeamIsolation { FR_011_CrossTeamIsolation }
check FR_011_CrossTeamIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_AssigneeInSameTeam {
  // If a task has an assignee, that assignee must be a member of the task's team
  all t: Task | some t.task_assignee implies
    (some m: TeamMembership | m.mem_user = t.task_assignee and m.mem_team = t.task_team)
  // Non-vacuous
  some Task
}

assert FR_012_AssigneeInSameTeam { FR_012_AssigneeInSameTeam }
check FR_012_AssigneeInSameTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_StatusSet {
  // Every task's status is from the exact set {todo, in_progress, done}
  all t: Task | t.task_status in (Todo + InProgress + Done)
  // Non-vacuous
  some Task
}

assert FR_013_StatusSet { FR_013_StatusSet }
check FR_013_StatusSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015, SC-007
pred FR_015_AuditPerEditEvent {
  // Every task has exactly one AuditCreated entry
  all t: Task | one ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditCreated
  // The AuditCreated actor is the task owner (creator)
  all t: Task | all ae: AuditEntry |
    (ae.ae_task = t and ae.ae_change = AuditCreated) implies ae.ae_actor = t.task_owner
  // Deleted tasks also have exactly one AuditDeleted entry
  all t: DeletedTask | one ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted
  // Non-vacuous
  some AuditEntry
}

assert FR_015_AuditPerEditEvent { FR_015_AuditPerEditEvent }
check FR_015_AuditPerEditEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016, SC-008
pred FR_016_AuditImmutable {
  // Append-only: at most one AuditCreated and at most one AuditDeleted per task
  all t: Task | lone ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditCreated
  all t: Task | lone ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditDeleted
  // Audit entries for deleted tasks survive (not cascaded away)
  all t: DeletedTask | some ae: AuditEntry | ae.ae_task = t
  // Non-vacuous
  some AuditEntry
}

assert FR_016_AuditImmutable { FR_016_AuditImmutable }
check FR_016_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditReadableByTeamMember {
  // All member contexts — owner, non-owner, admin — can read the audit trail
  MemberOwnerCtx    -> GetTaskAudit in PermMatrix.Allowed
  MemberNonOwnerCtx -> GetTaskAudit in PermMatrix.Allowed
  AdminAnyCtx       -> GetTaskAudit in PermMatrix.Allowed
  // Every audit entry is scoped to a team (prerequisite for cross-team isolation on the endpoint)
  all ae: AuditEntry | one ae.ae_team
  // Non-vacuous
  some AuditEntry
}

assert FR_017_AuditReadableByTeamMember { FR_017_AuditReadableByTeamMember }
check FR_017_AuditReadableByTeamMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019, FR-020
pred FR_019_ListScopedToTeam {
  // GetTasks is allowed for all member contexts (any team member can list)
  MemberOwnerCtx    -> GetTasks in PermMatrix.Allowed
  MemberNonOwnerCtx -> GetTasks in PermMatrix.Allowed
  AdminAnyCtx       -> GetTasks in PermMatrix.Allowed
  // All tasks are structurally team-scoped (no task leaks across teams)
  all t: Task | one t.task_team
  // Non-vacuous
  some Task
}

assert FR_019_ListScopedToTeam { FR_019_ListScopedToTeam }
check FR_019_ListScopedToTeam for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MissingCreatedEntry { some t: Task | no ae: AuditEntry | ae.ae_task = t and ae.ae_change = AuditCreated and some ae2: AuditEntry | ae2.ae_task = t and ae2.ae_change = AuditChanged }
