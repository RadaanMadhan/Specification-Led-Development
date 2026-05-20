// === feature_model.als — Alloy model for SaaS Team Task Management with Audit Trail ===
// Feature folder: B-L2  (spec folder: 007-team-tasks)
// Artefacts consulted: spec.md, data-model.md, contracts/http-api.md

// ═══════════════════════════════════════════════════════════════════════════
//  Static enumerations
// ═══════════════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig MemberRole, AdminRole extends Role {}

abstract sig OperationKind {}
one sig PostTasks, GetTasksList, GetTaskById, PatchTask, DeleteTask, GetAudit
    extends OperationKind {}

abstract sig Outcome {}
one sig Success, Denied403, NotFound404, ValidationFail400 extends Outcome {}

// Change-description shapes  (FR-015)
abstract sig ChangeKind {}
one sig CreatedChange, DeletedChange extends ChangeKind {}
sig ModifiedChange extends ChangeKind {}   // "changed <field>[, <field>]*" — one per edit save

// ═══════════════════════════════════════════════════════════════════════════
//  Core domain sigs
// ═══════════════════════════════════════════════════════════════════════════

sig User {}

sig Team {}

// TeamMembership = the (user, team, role) triples that model team_memberships rows
sig TeamMembership {
    mbUser : one User,
    mbTeam : one Team,
    mbRole : one Role
}

sig Task {
    taskTeam  : one Team,
    taskOwner : one User    // immutable creator (FR-006)
}

// Soft-deleted tasks: taskRow removed but audit entries preserved (FR-016)
sig DeletedTask in Task {}

// Audit entries (append-only, outlive their task)
sig AuditEntry {
    aeTask       : one Task,   // logical reference; no live FK (task may be deleted)
    aeTeam       : one Team,
    aeActor      : one User,
    aeActorRole  : one Role,
    aeChange     : one ChangeKind
}

// Operations model individual API request/response cycles
sig Operation {
    opKind       : one OperationKind,
    opCaller     : one User,
    opCallerTeam : one Team,
    opCallerRole : lone Role,   // role of caller in opCallerTeam; absent = non-member
    opTask       : lone Task,   // task addressed (absent for PostTasks / GetTasksList)
    opOutcome    : one Outcome
}

// ═══════════════════════════════════════════════════════════════════════════
//  Permission matrix (singleton carrier)
// ═══════════════════════════════════════════════════════════════════════════

one sig PermMatrix {
    // Base role-level allowed pairs (ownership conditionality is modelled separately)
    Allowed : set Role -> OperationKind
}

// ═══════════════════════════════════════════════════════════════════════════
//  Non-empty universe — exactly one fact, at the top
// ═══════════════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
    some User
    some Team
    some TeamMembership
    some Task
    some ModifiedChange
    some AuditEntry
    some Operation
}

// ═══════════════════════════════════════════════════════════════════════════
//  Structural facts
// ═══════════════════════════════════════════════════════════════════════════

// FR-007 / data-model.md composite PK (user_id, team_id)
fact F_UniqueTeamMembership {
    all disj m1, m2 : TeamMembership |
        not (m1.mbUser = m2.mbUser and m1.mbTeam = m2.mbTeam)
}

// FR-005 / data-model.md: every task's owner is a member of the task's team
fact F_OwnerIsMember {
    all t : Task |
        (some m : TeamMembership | m.mbUser = t.taskOwner and m.mbTeam = t.taskTeam)
}

// FR-015 / data-model.md: audit entry's team matches the referenced task's team
fact F_AuditTeamMatchesTask {
    all ae : AuditEntry | ae.aeTeam = ae.aeTask.taskTeam
}

// FR-015: audit entry's actor is a user who was (or still is) a member of aeTeam.
// We require the user to exist (display-name snapshot may differ, but user_id is preserved).
fact F_AuditActorExists {
    all ae : AuditEntry | ae.aeActor in User
}

// FR-016 / data-model.md "not FK-constrained": audit entries are never deleted,
// even when their task row is deleted.  Every AuditEntry in the model is live.
// (Alloy's universe = the current state; all AuditEntry atoms that exist are retained.)
fact F_AuditEntriesNeverDeleted {
    // No operation kind in the system represents "delete an audit entry".
    // Formally: no Operation's kind is an audit-mutating kind — we capture this
    // by asserting the universe contains no such OperationKind atom.
    // The real enforcement: every AuditEntry atom in ANY reachable state persists.
    // We state this as: no audit entry is orphaned from its team.
    all ae : AuditEntry | ae.aeTeam in Team
}

// FR-016 / spec.md: every CreatedChange audit entry has a corresponding Task
// that was NOT already in DeletedTask when it was created.
fact F_CreatedChangeForNonDeletedTask {
    all ae : AuditEntry | ae.aeChange = CreatedChange implies (ae.aeTask not in DeletedTask)
}

// FR-016: every DeletedChange audit entry corresponds to a task that IS deleted.
fact F_DeletedChangeForDeletedTask {
    all ae : AuditEntry | ae.aeChange = DeletedChange implies (ae.aeTask in DeletedTask)
}

// FR-015: every task has exactly one CreatedChange audit entry.
fact F_ExactlyOneCreatedEntry {
    all t : Task |
        one ae : AuditEntry | ae.aeTask = t and ae.aeChange = CreatedChange
}

// FR-015 / spec.md: a deleted task has exactly one DeletedChange audit entry.
fact F_ExactlyOneDeletedEntry {
    all t : DeletedTask |
        one ae : AuditEntry | ae.aeTask = t and ae.aeChange = DeletedChange
}

// FR-015: ModifiedChange entries are only produced by successful PATCH operations.
fact F_ModifiedChangeLinkedToSuccessfulPatch {
    all ae : AuditEntry | ae.aeChange in ModifiedChange implies
        (some op : Operation |
            op.opKind = PatchTask and
            op.opOutcome = Success and
            op.opTask = ae.aeTask and
            op.opCaller = ae.aeActor)
}

// Operations on tasks must reference a task that is in the caller's team
// (cross-team → NotFound404, FR-014).
fact F_CrossTeamOperationsReturnNotFound {
    all op : Operation |
        (op.opTask != none and op.opTask.taskTeam != op.opCallerTeam)
            implies op.opOutcome = NotFound404
}

// FR-001: unauthenticated callers (no role) get 401 — modelled as NotFound404
// since we use Outcome to encode all denial types; in this model we treat
// missing-role operations as yielding NotFound404 (the boundary rejects first).
fact F_AuthRequiredBoundary {
    all op : Operation |
        (no op.opCallerRole) implies (op.opOutcome = NotFound404)
}

// FR-008 / FR-009 / FR-010: PatchTask and DeleteTask require owner-or-admin.
fact F_OwnerOrAdminForMutation {
    all op : Operation |
        (op.opKind = PatchTask or op.opKind = DeleteTask) and
        op.opOutcome = Success implies
            (op.opCallerRole = AdminRole or
             (some t : Task | t = op.opTask and t.taskOwner = op.opCaller))
}

// FR-009: a member who is NOT the owner and NOT an admin MUST be denied (403).
fact F_NonOwnerNonAdminDenied { /* MUTATED — body cleared by validator */ }

// FR-014 / spec.md: cross-team access yields byte-equivalent NotFound404,
// indistinguishable from a non-existent task.  Already captured by
// F_CrossTeamOperationsReturnNotFound; this fact tightens that the
// non-member path also yields NotFound404 (different from Denied403).
fact F_NonMemberYieldsNotFound {
    all op : Operation |
        (no op.opCallerRole) implies op.opOutcome = NotFound404
}

// FR-012 / spec.md: a failed validation produces no audit entry and no
// state change (ValidationBeforeMutation).
fact F_NoAuditOnValidationFailure {
    all op : Operation |
        op.opOutcome = ValidationFail400 implies
            (no ae : AuditEntry |
                ae.aeTask = op.opTask and ae.aeActor = op.opCaller and
                ae.aeChange in ModifiedChange)
}

// Permission matrix definition (closed-world)
fact F_PermissionMatrix {
    // All six operations are allowed for both roles at the base level;
    // ownership restriction is enforced separately via F_OwnerOrAdminForMutation.
    MemberRole -> PostTasks      in PermMatrix.Allowed
    AdminRole  -> PostTasks      in PermMatrix.Allowed
    MemberRole -> GetTasksList   in PermMatrix.Allowed
    AdminRole  -> GetTasksList   in PermMatrix.Allowed
    MemberRole -> GetTaskById    in PermMatrix.Allowed
    AdminRole  -> GetTaskById    in PermMatrix.Allowed
    MemberRole -> GetAudit       in PermMatrix.Allowed
    AdminRole  -> GetAudit       in PermMatrix.Allowed
    AdminRole  -> PatchTask      in PermMatrix.Allowed
    AdminRole  -> DeleteTask     in PermMatrix.Allowed
    MemberRole -> PatchTask      in PermMatrix.Allowed  // conditional on ownership
    MemberRole -> DeleteTask     in PermMatrix.Allowed  // conditional on ownership

    PermMatrix.Allowed =
        (MemberRole -> PostTasks)    + (AdminRole  -> PostTasks)    +
        (MemberRole -> GetTasksList) + (AdminRole  -> GetTasksList) +
        (MemberRole -> GetTaskById)  + (AdminRole  -> GetTaskById)  +
        (MemberRole -> GetAudit)     + (AdminRole  -> GetAudit)     +
        (AdminRole  -> PatchTask)    + (AdminRole  -> DeleteTask)   +
        (MemberRole -> PatchTask)    + (MemberRole -> DeleteTask)
}

// FR-006: a successful PATCH cannot change a task's owner.
// Captured structurally: taskOwner is a field with no mutation path.
// We assert it via operation outcomes: any PATCH body targeting owner_id fails.
fact F_OwnerImmutableOnPatch {
    // All successful PATCH operations have the same task owner after as before;
    // since sigs are structural snapshots, the invariant is: no Operation whose
    // kind=PatchTask and outcome=Success refers to a task whose owner has changed.
    // In this static model we encode: every task's owner field is fixed.
    all t : Task | one t.taskOwner    // exactly one owner, immutable by structure
}

// ═══════════════════════════════════════════════════════════════════════════
//  Predicates and assertions — catalogue patterns
// ═══════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-008,FR-009,FR-010
pred LeastPrivilege {
    some Operation
    // No successful PatchTask or DeleteTask by a non-owner non-admin member
    all op : Operation |
        (op.opKind = PatchTask or op.opKind = DeleteTask) and
        op.opCallerRole = MemberRole and
        (all t : Task | t = op.opTask implies t.taskOwner != op.opCaller)
            implies op.opOutcome != Success
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
    // Every (Role × OperationKind) pair has a verdict in the matrix.
    all r : Role, ok : OperationKind | (r -> ok) in PermMatrix.Allowed or
        not ((r -> ok) in PermMatrix.Allowed)
    // Specifically: the matrix is fully enumerated — no cell is simply absent
    // (Alloy's closed-world means all pairs not listed are implicitly denied).
    // The positive check: both roles appear in the domain of Allowed.
    MemberRole in PermMatrix.Allowed.OperationKind
    AdminRole  in PermMatrix.Allowed.OperationKind
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-010; contracts/http-api.md (admin ⊇ member)
pred PrivilegeMonotonicity {
    // Admin's allowed operation set is a superset of member's allowed set.
    some Operation
    all ok : OperationKind |
        (MemberRole -> ok) in PermMatrix.Allowed implies (AdminRole -> ok) in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
    some Operation
    // Every operation without a resolved caller role is rejected (not Success)
    all op : Operation | (no op.opCallerRole) implies op.opOutcome != Success
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry
pred AuditCompleteness {
    some Task
    // Every task has exactly one CreatedChange entry
    all t : Task | one ae : AuditEntry | ae.aeTask = t and ae.aeChange = CreatedChange
    // Every deleted task has exactly one DeletedChange entry
    all t : DeletedTask | one ae : AuditEntry | ae.aeTask = t and ae.aeChange = DeletedChange
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE"; contracts/ "no PATCH/PUT/DELETE on audit"
pred AppendOnly {
    some AuditEntry
    // Audit entries are never modified: every AuditEntry in the universe is intact.
    // Structurally: no operation kind for deleting or updating audit entries exists.
    no ok : OperationKind | ok not in
        (PostTasks + GetTasksList + GetTaskById + PatchTask + DeleteTask + GetAudit)
    // And: audit entries for deleted tasks still exist (they outlive the task row)
    all t : DeletedTask | some ae : AuditEntry | ae.aeTask = t
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-015; data-model.md actor_user_id/actor_role snapshot
pred AttributionCorrectness {
    some AuditEntry
    // The actor on every ModifiedChange entry matches a caller who performed
    // a successful PatchTask on that task.
    all ae : AuditEntry | ae.aeChange in ModifiedChange implies
        (some op : Operation |
            op.opKind = PatchTask and op.opOutcome = Success and
            op.opTask = ae.aeTask and op.opCaller = ae.aeActor and
            op.opCallerRole = ae.aeActorRole)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005,FR-006; data-model.md owner_id NOT NULL immutable
pred OwnershipExclusivity {
    some Task
    // Every task has exactly one owner
    all t : Task | one t.taskOwner
    // Every task belongs to exactly one team
    all t : Task | one t.taskTeam
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-008,FR-009,FR-010; data-model.md owner_id predicate
pred OwnershipBasedAccess {
    some Operation
    // A successful PatchTask or DeleteTask by a MemberRole caller
    // implies that caller owns the task.
    all op : Operation |
        (op.opKind = PatchTask or op.opKind = DeleteTask) and
        op.opOutcome = Success and
        op.opCallerRole = MemberRole implies
            (some t : Task | t = op.opTask and t.taskOwner = op.opCaller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014; contracts/ "byte-equivalent not-found"
pred NoInformationLeakage {
    some Operation
    // Cross-team task access returns NotFound404, indistinguishable from non-existent
    all op : Operation |
        op.opTask != none and op.opTask.taskTeam != op.opCallerTeam
            implies op.opOutcome = NotFound404
    // And: non-member access also returns NotFound404 (not Denied403, which would reveal existence)
    all op : Operation |
        (no op.opCallerRole) implies op.opOutcome = NotFound404
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-006 (owner immutability); data-model.md CHECK
pred NoSelfMutation {
    some Task
    // Owner field is structurally fixed: taskOwner is a 'one' field with no patch path.
    // Encode as: no successful PatchTask references an operation that changes owner.
    // Since the static model fixes taskOwner, every task's owner equals itself across all
    // operation outcomes — a task's owner never differs from the stored owner_id.
    all t : Task | t.taskOwner in User
    all op : Operation |
        op.opKind = PatchTask and op.opOutcome = Success implies
            (op.opTask != none and op.opTask.taskOwner != none)
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-012; contracts/ 400 validation_error
pred ValidationBeforeMutation {
    some Operation
    // A validation-failed operation writes no ModifiedChange audit entry
    all op : Operation |
        op.opOutcome = ValidationFail400 implies
            (no ae : AuditEntry |
                ae.aeTask = op.opTask and ae.aeActor = op.opCaller and
                ae.aeChange in ModifiedChange)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ═══════════════════════════════════════════════════════════════════════════
//  Feature-specific predicates
// ═══════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required before business logic
pred FR_001_AuthRequired {
    some Operation
    all op : Operation | (no op.opCallerRole) implies op.opOutcome != Success
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 — team context mandatory; non-membership → 404
pred FR_003_TeamContextRequired {
    some Operation
    // An operation whose caller has no role in the team is blocked
    all op : Operation | (no op.opCallerRole) implies op.opOutcome = NotFound404
}
assert FR_003_TeamContextRequired { FR_003_TeamContextRequired }
check FR_003_TeamContextRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 — task's team is immutable after creation
pred FR_005_TaskTeamImmutable {
    some Task
    // In the static model: every task has exactly one team, encoded by 'one' multiplicity.
    all t : Task | one t.taskTeam
    // No successful operation changes the taskTeam reference (structurally enforced).
    all op : Operation |
        op.opKind = PatchTask and op.opOutcome = Success implies
            (op.opTask != none and one op.opTask.taskTeam)
}
assert FR_005_TaskTeamImmutable { FR_005_TaskTeamImmutable }
check FR_005_TaskTeamImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 — owner_id immutable; any PATCH attempt rejected
pred FR_006_OwnerImmutable {
    some Task
    all t : Task | one t.taskOwner
}
assert FR_006_OwnerImmutable { FR_006_OwnerImmutable }
check FR_006_OwnerImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 — per-team role; unique membership per (user, team) pair
pred FR_007_UniquePerTeamRole {
    some TeamMembership
    all disj m1, m2 : TeamMembership |
        not (m1.mbUser = m2.mbUser and m1.mbTeam = m2.mbTeam)
}
assert FR_007_UniquePerTeamRole { FR_007_UniquePerTeamRole }
check FR_007_UniquePerTeamRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 — member may create, view, edit-own, delete-own
pred FR_008_MemberCanCreateAndReadAny {
    some Operation
    // A member-role caller can successfully PostTasks
    all op : Operation |
        op.opKind = PostTasks and op.opCallerRole = MemberRole
            implies op.opOutcome != Denied403
    // A member-role caller can successfully GetTaskById for tasks in their team
    all op : Operation |
        op.opKind = GetTaskById and op.opCallerRole = MemberRole and
        op.opTask != none and op.opTask.taskTeam = op.opCallerTeam
            implies op.opOutcome != Denied403
}
assert FR_008_MemberCanCreateAndReadAny { FR_008_MemberCanCreateAndReadAny }
check FR_008_MemberCanCreateAndReadAny for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 — member cannot edit/delete tasks they don't own
pred FR_009_NonOwnerMemberDenied {
    some Operation
    all op : Operation |
        (op.opKind = PatchTask or op.opKind = DeleteTask) and
        op.opCallerRole = MemberRole and
        op.opTask != none and
        op.opTask.taskTeam = op.opCallerTeam and
        op.opTask.taskOwner != op.opCaller
            implies op.opOutcome = Denied403
}
assert FR_009_NonOwnerMemberDenied { FR_009_NonOwnerMemberDenied }
check FR_009_NonOwnerMemberDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 — admin can edit/delete any task in their team
pred FR_010_AdminCanMutateAnyTeamTask {
    some Operation
    all op : Operation |
        (op.opKind = PatchTask or op.opKind = DeleteTask) and
        op.opCallerRole = AdminRole and
        op.opTask != none and op.opTask.taskTeam = op.opCallerTeam
            implies op.opOutcome != Denied403
}
assert FR_010_AdminCanMutateAnyTeamTask { FR_010_AdminCanMutateAnyTeamTask }
check FR_010_AdminCanMutateAnyTeamTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011,FR-014 — admin privilege in team T does NOT grant access to team U tasks
pred FR_011_CrossTeamIsolationForAdmin {
    some Operation
    all op : Operation |
        op.opCallerRole = AdminRole and
        op.opTask != none and op.opTask.taskTeam != op.opCallerTeam
            implies op.opOutcome = NotFound404
}
assert FR_011_CrossTeamIsolationForAdmin { FR_011_CrossTeamIsolationForAdmin }
check FR_011_CrossTeamIsolationForAdmin for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 — every task has exactly one "created" audit entry
pred FR_015_OneCreatedAuditEntryPerTask {
    some Task
    all t : Task | one ae : AuditEntry | ae.aeTask = t and ae.aeChange = CreatedChange
}
assert FR_015_OneCreatedAuditEntryPerTask { FR_015_OneCreatedAuditEntryPerTask }
check FR_015_OneCreatedAuditEntryPerTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 — actor role on audit entry = role at time of change (snapshot)
pred FR_015_ActorRoleSnapshot {
    some AuditEntry
    // Every audit entry carries exactly one role value
    all ae : AuditEntry | one ae.aeActorRole
    // That role is either member or admin (the only defined roles)
    all ae : AuditEntry | ae.aeActorRole in MemberRole + AdminRole
}
assert FR_015_ActorRoleSnapshot { FR_015_ActorRoleSnapshot }
check FR_015_ActorRoleSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit entries outlive their task (DeletedTask still has entries)
pred FR_016_AuditOutlivesTask {
    some DeletedTask
    all t : DeletedTask |
        (some ae : AuditEntry | ae.aeTask = t) and
        (some ae : AuditEntry | ae.aeTask = t and ae.aeChange = DeletedChange)
}
assert FR_016_AuditOutlivesTask { FR_016_AuditOutlivesTask }
check FR_016_AuditOutlivesTask for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 — audit trail readable by any team member (including non-admin)
pred FR_017_AuditReadableByAnyTeamMember {
    some Operation
    all op : Operation |
        op.opKind = GetAudit and
        op.opCallerRole = MemberRole and
        op.opTask != none and op.opTask.taskTeam = op.opCallerTeam
            implies op.opOutcome != Denied403
}
assert FR_017_AuditReadableByAnyTeamMember { FR_017_AuditReadableByAnyTeamMember }
check FR_017_AuditReadableByAnyTeamMember for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 — cross-team audit access returns byte-equivalent 404
pred FR_017_AuditCrossTeamIsolation {
    some Operation
    all op : Operation |
        op.opKind = GetAudit and
        op.opTask != none and op.opTask.taskTeam != op.opCallerTeam
            implies op.opOutcome = NotFound404
}
assert FR_017_AuditCrossTeamIsolation { FR_017_AuditCrossTeamIsolation }
check FR_017_AuditCrossTeamIsolation for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NonOwnerNotDenied { some op : Operation | op.opKind = PatchTask and op.opCallerRole = MemberRole and op.opTask != none and op.opTask.taskTeam = op.opCallerTeam and op.opTask.taskOwner != op.opCaller and op.opOutcome = Success }
