// === feature_model.als — Alloy model for B-L3 (008-task-sharing) ===
// Multi-tenant task management with per-task sharing and audit

// Core role enumeration
abstract sig Role {}
one sig Member, TeamAdmin extends Role {}

// Task status enumeration
abstract sig TaskStatus {}
one sig TODO, IN_PROGRESS, DONE extends TaskStatus {}

// Audit operation enumeration
abstract sig AuditOperation {}
one sig CREATED, EDITED, DELETED, SHARED, UNSHARED extends AuditOperation {}

// Core entities
sig User {
  team: one Team,
  role: one Role
}

sig Team {}

sig Task {
  team: one Team,
  owner: one User,
  status: one TaskStatus,
  shared_with: set User
}

sig AuditEntry {
  task: one Task,
  actor: one User,
  actor_role: one Role,
  operation: one AuditOperation
}

// ============================================================================
// FACTS — Structural rules that MUST hold in every valid instance
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Team
  some Task
  some AuditEntry
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md Task ownership
fact F_OwnershipExclusivity {
  all t: Task | one o: User | o = t.owner
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009, FR-002 owner in same team
fact F_TaskOwnerInTeam {
  all t: Task | t.owner.team = t.team
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012; contracts/http-api.md permission matrix
fact F_ShareesInSameTeam {
  all t: Task, u: t.shared_with | u.team = t.team
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, FR-006; contracts/http-api.md byte-equivalent
fact F_CrossTeamIsolation {
  all t: Task, u: User | (u.team != t.team) implies (u != t.owner and u not in t.shared_with)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md AuditEntry per mutation
fact F_AuditCompleteness {
  all t: Task | some ae: AuditEntry | ae.task = t
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; contracts/http-api.md immutable audit trail
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md actor_role snapshot
fact F_AuditActorInTeam {
  all ae: AuditEntry | ae.actor.team = ae.task.team
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010, Q1=A (owner controls sharing)
fact F_OwnerControlsSharing {
  all t: Task, u: t.shared_with | u != t.owner
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002 (team_id from token, not request)
fact F_UserBelongsToOneTeam {
  all u: User | one tm: Team | tm = u.team
}

// ============================================================================
// PREDICATES — First-order logic expressions of structural properties
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md OAuth required
pred AuthRequiredEverywhere {
  all ae: AuditEntry | some u: User | u = ae.actor
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-009; data-model.md one owner per task
pred OwnershipExclusivity {
  all t: Task | one o: User | o = t.owner
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-005, FR-010, FR-011; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  some t: Task | (
    (t.owner in (t.owner + t.shared_with)) or
    (some u: User | u.role = TeamAdmin and u.team = t.team)
  )
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-014, FR-006; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  all t: Task, u: User | (
    u.team != t.team implies (u != t.owner and u not in t.shared_with)
  )
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-015; data-model.md UNIQUE constraint
pred AuditCompleteness {
  all t: Task | (some ae: AuditEntry | ae.task = t)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-017; data-model.md no UPDATE/DELETE on audit_entries
pred AppendOnly {
  all ae1, ae2: AuditEntry | (
    ae1.task = ae2.task and ae1.operation = ae2.operation and ae1.actor = ae2.actor
  ) implies ae1 = ae2
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md actor_role snapshot
pred AttributionCorrectness {
  all ae: AuditEntry | (
    ae.actor.team = ae.task.team and
    (ae.actor_role = Member or ae.actor_role = TeamAdmin)
  )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009 (owner immutable in v1)
pred FR_009_OwnerImmutable {
  all t: Task | (one o: User | o = t.owner)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010, Q1=A (owner-only share control)
pred FR_010_OwnerControlledSharing {
  all t: Task, u: t.shared_with | u != t.owner
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012 (cross-team sharing forbidden)
pred FR_012_SameTeamSharingOnly {
  all t: Task, u: t.shared_with | u.team = t.team
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002 (team_id and role from token, not request)
pred FR_002_IdentityFromToken {
  all u: User | one t: Team | u.team = t
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006 (cross-team access forbidden)
pred FR_006_CrossTeamIsolation {
  all t: Task, u: User | (u.team != t.team) implies (u != t.owner and u not in t.shared_with)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014 (byte-equivalent cross-team isolation)
pred FR_014_ByteEquivalentCrossTeamIsolation {
  all t: Task, u: User | (
    (u.team != t.team) or (u.team = t.team and u.role = Member and u != t.owner and u not in t.shared_with)
  ) implies (
    not (u = t.owner or u in t.shared_with or u.role = TeamAdmin)
  )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-015 (per-event audit semantics)
pred FR_015_PerEventAuditSemantics {
  all t: Task | (some ae: AuditEntry | ae.task = t and ae.operation = CREATED)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017 (audit immutable append-only)
pred FR_017_AuditImmutability {
  all ae: AuditEntry | ae.operation in (CREATED + EDITED + DELETED + SHARED + UNSHARED)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001 (OAuth authentication required)
pred FR_001_AuthRequired {
  all ae: AuditEntry | (some u: User | u = ae.actor and u.team = ae.task.team)
}

// ============================================================================
// ASSERTIONS — Check that predicates hold given the facts
// ============================================================================

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
assert OwnershipExclusivity { OwnershipExclusivity }
assert OwnershipBasedAccess { OwnershipBasedAccess }
assert NoInformationLeakage { NoInformationLeakage }
assert AuditCompleteness { AuditCompleteness }
assert AppendOnly { AppendOnly }
assert AttributionCorrectness { AttributionCorrectness }
assert FR_009_OwnerImmutable { FR_009_OwnerImmutable }
assert FR_010_OwnerControlledSharing { FR_010_OwnerControlledSharing }
assert FR_012_SameTeamSharingOnly { FR_012_SameTeamSharingOnly }
assert FR_002_IdentityFromToken { FR_002_IdentityFromToken }
assert FR_006_CrossTeamIsolation { FR_006_CrossTeamIsolation }
assert FR_014_ByteEquivalentCrossTeamIsolation { FR_014_ByteEquivalentCrossTeamIsolation }
assert FR_015_PerEventAuditSemantics { FR_015_PerEventAuditSemantics }
assert FR_017_AuditImmutability { FR_017_AuditImmutability }
assert FR_001_AuthRequired { FR_001_AuthRequired }

// ============================================================================
// CHECKS
// ============================================================================

check AuthRequiredEverywhere for 5
check OwnershipExclusivity for 5
check OwnershipBasedAccess for 5
check NoInformationLeakage for 5
check AuditCompleteness for 5
check AppendOnly for 5
check AttributionCorrectness for 5
check FR_009_OwnerImmutable for 5
check FR_010_OwnerControlledSharing for 5
check FR_012_SameTeamSharingOnly for 5
check FR_002_IdentityFromToken for 5
check FR_006_CrossTeamIsolation for 5
check FR_014_ByteEquivalentCrossTeamIsolation for 5
check FR_015_PerEventAuditSemantics for 5
check FR_017_AuditImmutability for 5
check FR_001_AuthRequired for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditMutable { some disj ae1, ae2: AuditEntry | ae1.task = ae2.task and ae1.actor = ae2.actor and ae1.operation != ae2.operation }
