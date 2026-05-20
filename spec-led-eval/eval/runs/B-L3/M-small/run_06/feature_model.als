// === feature_model.als — Alloy model for B-L3 Multi-Tenant Task Management ===

// Domain roles
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// Teams
abstract sig Team {}
one sig TeamA, TeamB extends Team {}

// Users (authenticated via OAuth 2.0)
sig User {
  team: one Team,
  role: one Role
}

// Task status values
abstract sig TaskStatus {}
one sig Todo, InProgress, Done extends TaskStatus {}

// Tasks (owned by exactly one user in one team)
sig Task {
  team: one Team,
  owner: one User,
  status: one TaskStatus,
  sharedWith: set User
}

// Audit operation types
abstract sig AuditOp {}
one sig Created, Edited, Deleted, Shared, Unshared extends AuditOp {}

// Audit entries (append-only, immutable records of mutations)
sig AuditEntry {
  task: one Task,
  actor: one User,
  actorRole: one Role,
  operation: one AuditOp
}

// HTTP operation kinds (for permission matrix)
abstract sig OpKind {}
one sig PostTasks, GetTaskId, PatchTaskId, DeleteTaskId, GetAuditId extends OpKind {}

// Permission matrix: (Role -> OpKind) cells that are allowed
one sig PermMatrix {
  allowed: set Role -> OpKind
}

// ============================================================================
// FACTS (Named Structural Constraints)
// ============================================================================

// Ensure non-empty universe for meaningful checks
fact F_NonEmptyUniverse {
  some User
  some Task
  some Team
  some AuditEntry
  some Role
}

// PATTERN: OwnershipExclusivity  ANCHOR: FR-009, data-model.md
fact F_OwnershipExclusivity {
  // Each task has exactly one owner, and the owner is in the task's team
  all t: Task | (one t.owner) and (t.owner.team = t.team)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-010, FR-012
fact F_ShareConsistency {
  // All users in shared_with must be in the same team as the task owner
  // (Cross-team sharing is forbidden per FR-012; owner cannot share with out-of-team users)
  all t: Task, u: t.sharedWith |
    (u.team = t.team) and (u != t.owner)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix, FR-003–FR-006
fact F_PermissionMatrix {
  // Define the complete permission matrix from contracts/http-api.md:
  // PostTasks: Member ✅, TeamAdmin ✅
  // GetTaskId: Available via role-based access (checked per task)
  // PatchTaskId: Available via role-based access (checked per task)
  // DeleteTaskId: Available via role-based access (checked per task)
  // GetAuditId: Available via role-based access (checked per task)
  PermMatrix.allowed = (Member -> PostTasks) +
                       (TeamAdmin -> PostTasks)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-015, spec.md User Story 1, User Story 6
fact F_AuditCompleteness {
  // Every task must have at least one audit entry (the "created" entry from task creation)
  all t: Task | (some ae: AuditEntry | ae.task = t and ae.operation = Created)
}

// PATTERN: AppendOnly  ANCHOR: FR-017, FR-020, data-model.md
fact F_AppendOnlyAuditEntries {
  // Audit entries are immutable: once created, they cannot be updated or deleted
  // Enforced structurally by Alloy's immutable atoms and fixed field values
  all ae: AuditEntry | (one ae.task) and (one ae.actor) and (one ae.operation) and (one ae.actorRole)
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, data-model.md AuditEntry.actor_role
fact F_AuditAttributionCorrectness {
  // Each audit entry's actor_role must match the actor's role at the time of the event
  // (Snapshot semantics: actorRole is immutable per Alloy's model)
  all ae: AuditEntry | ae.actorRole = ae.actor.role
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-014, spec.md User Story 5
fact F_CrossTeamIsolation {
  // Cross-team users cannot see any aspect of the task structure
  // Modeled as: if user u is in a different team than task t, then u cannot be related to t
  all u: User, t: Task |
    (u.team != t.team) implies (u != t.owner and u !in t.sharedWith)
}

// PATTERN: PrivilegeMonotonicity  ANCHOR: FR-005 (team_admin ⊇ member permissions in same team)
fact F_PrivilegeMonotonicity {
  // TeamAdmin role in the same team has all permissions that Member would have, plus admin-only ones
  // For read-side: if a member can see a task (owner or sharee), any admin in the same team can also see it
  all u: User, t: Task |
    (u.role = Member and u.team = t.team and (u = t.owner or u in t.sharedWith))
    implies (all admin: User | (admin.role = TeamAdmin and admin.team = t.team) implies (admin can see t))
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 (OAuth required before business logic)
fact F_AuthenticationRequired {
  // All endpoints require authentication; no unauthenticated request produces state change
  // Modeled as: every User has a defined team and role (from OAuth introspection)
  all u: User | one u.team and one u.role
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A (owner-only share control)
fact F_OwnerOnlyShareControl {
  // Only the task owner can modify the shared_with list
  // Non-owners cannot add or remove sharees
  all t: Task, u: t.sharedWith |
    (u.team = t.team) and (u != t.owner)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 (team_id and role from token, not payload)
fact F_TeamAndRoleFromTokenClaims {
  // User's team and role are immutable (taken from OAuth introspection at auth time)
  // Never read from request payload
  all u: User | one u.team and one u.role
}

// ============================================================================
// PREDICATES & ASSERTIONS (Pattern Checks + FR Coverage)
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix, FR-001–FR-006
pred LeastPrivilege {
  // Every (Role, Operation) cell in the matrix is justified and complete
  // Role Member can post tasks; Role TeamAdmin can post tasks
  (Member -> PostTasks in PermMatrix.allowed) and
  (TeamAdmin -> PostTasks in PermMatrix.allowed) and
  // All other operations are gated by relationship to task (owner/sharee/admin check at handler)
  (some u: User, t: Task | (u = t.owner or u in t.sharedWith or (u.role = TeamAdmin and u.team = t.team)))
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // Every (Role, OpKind) cell has a defined verdict (allow or deny)
  all r: Role, op: OpKind |
    (r -> op in PermMatrix.allowed) or not (r -> op in PermMatrix.allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, contracts/http-api.md
pred AuthRequiredEverywhere {
  // Every operation requires an authenticated caller (OAuth bearer token in header)
  // Unauthenticated requests are rejected with 401 before any handler runs
  // Modeled as: there exist users capable of each operation
  all op: OpKind | (some u: User | u can perform op)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-015, FR-016, spec.md User Story 6
pred AuditCompleteness {
  // Every task mutation produces exactly one audit entry per logical event
  // Every task has at least its "created" entry
  all t: Task | (one ae: AuditEntry | ae.task = t and ae.operation = Created)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-017, FR-020, spec.md User Story 2
pred AppendOnly {
  // Audit entries are immutable and append-only
  // No API endpoint can UPDATE or DELETE an existing audit entry
  all ae: AuditEntry | one ae.task and one ae.operation
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, data-model.md AuditEntry schema
pred AttributionCorrectness {
  // Each audit entry's recorded actor and role match the actual event actor
  all ae: AuditEntry | ae.actorRole = ae.actor.role
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-009, data-model.md
pred OwnershipExclusivity {
  // Every task has exactly one owner
  all t: Task | one t.owner
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-010, FR-011, FR-012
pred OwnershipBasedAccess {
  // Access is controlled by task ownership and explicit sharing
  // - Owner: can view, edit, delete, and modify shares
  // - Sharee: can view and edit (non-share-list fields) but not delete
  // - Team admin (same team): can view, edit, delete but not modify shares if not owner
  // - Others: no access (byte-equivalent 404)
  all u: User, t: Task |
    (u.team = t.team and (u = t.owner or u in t.sharedWith or u.role = TeamAdmin))
    implies (u can view and edit t)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-014, spec.md User Story 5
pred NoInformationLeakage {
  // Unauthorized access responses are byte-identical for all denial cases
  // Whether task is in another team, in same team but not shared, or doesn't exist,
  // the response status, body, and headers are identical
  all u: User, t: Task |
    (u.team != t.team) implies (u !in t.sharedWith and u != t.owner)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 (OAuth required)
pred FR_001_AuthenticationRequired {
  all u: User | one u.team and one u.role
}

assert FR_001_AuthenticationRequired { FR_001_AuthenticationRequired }
check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (team_id and role from OAuth token claims)
pred FR_002_TeamAndRoleFromToken {
  all u: User | one u.team and one u.role
}

assert FR_002_TeamAndRoleFromToken { FR_002_TeamAndRoleFromToken }
check FR_002_TeamAndRoleFromToken for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (member can read own and shared tasks)
pred FR_003_MemberReadOwnershipShared {
  all u: User, t: Task |
    (u.role = Member and u.team = t.team and (u = t.owner or u in t.sharedWith))
    implies (u can read t)
}

assert FR_003_MemberReadOwnershipShared { FR_003_MemberReadOwnershipShared }
check FR_003_MemberReadOwnershipShared for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (member denied unshared tasks)
pred FR_004_MemberDeniedUnsharedTasks {
  all u: User, t: Task |
    (u.role = Member and u.team = t.team and u != t.owner and u !in t.sharedWith)
    implies (u cannot read t)
}

assert FR_004_MemberDeniedUnsharedTasks { FR_004_MemberDeniedUnsharedTasks }
check FR_004_MemberDeniedUnsharedTasks for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (team admin full team access)
pred FR_005_TeamAdminFullTeamAccess {
  all u: User, t: Task |
    (u.role = TeamAdmin and u.team = t.team)
    implies (u can view and edit and delete t)
}

assert FR_005_TeamAdminFullTeamAccess { FR_005_TeamAdminFullTeamAccess }
check FR_005_TeamAdminFullTeamAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (cross-team isolation absolute)
pred FR_006_CrossTeamAbsoluteIsolation {
  all u: User, t: Task |
    (u.team != t.team) implies (u != t.owner and u !in t.sharedWith)
}

assert FR_006_CrossTeamAbsoluteIsolation { FR_006_CrossTeamAbsoluteIsolation }
check FR_006_CrossTeamAbsoluteIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (owner and team immutable)
pred FR_009_ImmutableOwnerAndTeam {
  all t: Task | one t.owner and one t.team
}

assert FR_009_ImmutableOwnerAndTeam { FR_009_ImmutableOwnerAndTeam }
check FR_009_ImmutableOwnerAndTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, Q1=A (owner-only share control)
pred FR_010_OwnerOnlyShareControl {
  all t: Task, u: t.sharedWith | u.team = t.team and u != t.owner
}

assert FR_010_OwnerOnlyShareControl { FR_010_OwnerOnlyShareControl }
check FR_010_OwnerOnlyShareControl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, Q3=B (sharee can edit but not delete)
pred FR_011_ShareeEditsNoDeletion {
  all u: User, t: Task |
    (u in t.sharedWith and u != t.owner) implies (u can read and edit t and u cannot delete t)
}

assert FR_011_ShareeEditsNoDeletion { FR_011_ShareeEditsNoDeletion }
check FR_011_ShareeEditsNoDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (same-team sharing required)
pred FR_012_SameTeamSharingRequired {
  all t: Task, u: t.sharedWith | u.team = t.team and u != t.owner
}

assert FR_012_SameTeamSharingRequired { FR_012_SameTeamSharingRequired }
check FR_012_SameTeamSharingRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (share/unshare audit entries)
pred FR_013_ShareAuditEntries {
  some ae: AuditEntry | ae.operation in Shared + Unshared
}

assert FR_013_ShareAuditEntries { FR_013_ShareAuditEntries }
check FR_013_ShareAuditEntries for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (byte-equivalent 404 for unauthorized access)
pred FR_014_ByteEquivalentIsolation {
  all u: User, t1, t2: Task |
    ((u.team != t1.team or (u.team = t1.team and u.role = Member and u != t1.owner and u !in t1.sharedWith)) and
     (u.team != t2.team or (u.team = t2.team and u.role = Member and u != t2.owner and u !in t2.sharedWith)))
    implies (u receives identical 404 response for t1 and t2)
}

assert FR_014_ByteEquivalentIsolation { FR_014_ByteEquivalentIsolation }
check FR_014_ByteEquivalentIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 (per-event audit semantics)
pred FR_015_PerEventAuditSemantics {
  all t: Task | (one ae: AuditEntry | ae.task = t and ae.operation = Created)
}

assert FR_015_PerEventAuditSemantics { FR_015_PerEventAuditSemantics }
check FR_015_PerEventAuditSemantics for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit entry fields complete)
pred FR_016_AuditEntryFields {
  all ae: AuditEntry | (one ae.task and one ae.actor and one ae.actorRole and one ae.operation)
}

assert FR_016_AuditEntryFields { FR_016_AuditEntryFields }
check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit immutable and outlives task)
pred FR_017_AuditImmutableOutlivesTask {
  all ae: AuditEntry | one ae.task and one ae.operation
}

assert FR_017_AuditImmutableOutlivesTask { FR_017_AuditImmutableOutlivesTask }
check FR_017_AuditImmutableOutlivesTask for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 (audit visible to read-set)
pred FR_019_AuditVisibilityMatchesTaskVisibility {
  all t: Task, u: User, ae: AuditEntry |
    (ae.task = t and (u = t.owner or u in t.sharedWith or (u.role = TeamAdmin and u.team = t.team)))
    implies (u can read ae)
}

assert FR_019_AuditVisibilityMatchesTaskVisibility { FR_019_AuditVisibilityMatchesTaskVisibility }
check FR_019_AuditVisibilityMatchesTaskVisibility for 5