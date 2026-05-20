// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature branch: 005-fca-loan-applications
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────
// SECTION 1: Base sigs (enums, status, roles, operations)
// ─────────────────────────────────────────────────────────────

abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

abstract sig OperationKind {}
one sig PostApp, GetApp, PatchStatus, GetAuditLog extends OperationKind {}

// Permission matrix as a singleton field (canonical pattern)
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────
// SECTION 2: Dynamic entity sigs
// ─────────────────────────────────────────────────────────────

sig User {
  userRoles: set Role   // a user holds one or more base roles
}

sig LoanApplication {
  applicant       : one  User,
  status          : one  AppStatus,
  assignedOfficer : lone User       // lone: may be null (no-eligible-officer edge case)
}

// Immutable, append-only state-transition record
sig AuditEntry {
  forApp      : one  LoanApplication,
  actor       : one  User,
  actorRole   : one  Role,
  prevStatus  : lone AppStatus,     // lone: absent for initial (none → pending) entry
  newStatus   : one  AppStatus
}

// Represents an authenticated API call in the model universe
sig ApiCall {
  caller     : one  User,
  callRole   : one  Role,           // effective role the caller presents
  opKind     : one  OperationKind,
  targetApp  : lone LoanApplication
}

// ─────────────────────────────────────────────────────────────
// SECTION 3: Non-empty universe fact
// ─────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some ApiCall
}

// ─────────────────────────────────────────────────────────────
// SECTION 4: Structural facts
// ─────────────────────────────────────────────────────────────

// FR-002: officer and auditor roles are mutually exclusive on one user
fact F_RoleMutualExclusion {
  no u: User | (ROfficer in u.userRoles and RAuditor in u.userRoles)
  // RSystem is never assigned to a human user
  no u: User | RSystem in u.userRoles
  // Every user holds at least one human role
  all u: User | some u.userRoles
}

// FR-001: every API call's callRole must actually be held by the caller
fact F_AuthCallRoleValid {
  all c: ApiCall | c.callRole in c.caller.userRoles
}

// Permission matrix (contracts/http-api.md — base role grants, closed-world)
// Applicant → PostApp, GetApp
// Officer   → GetApp (assigned, handled by predicate), PatchStatus
// Auditor   → GetApp, GetAuditLog
// System    → no API-surface permissions
fact F_PermissionMatrix {
  PermMatrix.Allowed = (RApplicant -> PostApp) +
                       (RApplicant -> GetApp)  +
                       (ROfficer   -> GetApp)  +
                       (ROfficer   -> PatchStatus) +
                       (RAuditor   -> GetApp)  +
                       (RAuditor   -> GetAuditLog)
}

// FR-011 / data-model.md CHECK constraint: assigned officer ≠ applicant
fact F_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

// Assigned officer must have the officer role (data-model.md, FR-010)
fact F_AssignedOfficerHasRole {
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.userRoles
}

// Applicant must have the applicant role
fact F_ApplicantHasRole {
  all a: LoanApplication | RApplicant in a.applicant.userRoles
}

// FR-009: Valid status transitions encoded in AuditEntry prev→new pairs
fact F_ValidStatusTransitions {
  all e: AuditEntry | {
    // Initial entry: no prevStatus, newStatus must be Pending
    (no e.prevStatus implies e.newStatus = Pending)
    // If prevStatus present: only valid forward transitions allowed
    (e.prevStatus = Pending      implies e.newStatus = UnderReview)
    (e.prevStatus = UnderReview  implies (e.newStatus = Approved or e.newStatus = Rejected))
    // Terminal statuses cannot be a prevStatus
    e.prevStatus != Approved
    e.prevStatus != Rejected
  }
}

// FR-016: actorRole on AuditEntry must be a role the actor actually holds,
// or RSystem for system-initiated entries (no-eligible-officer edge case)
fact F_AuditActorRoleMatchesUser {
  all e: AuditEntry | {
    e.actorRole != RSystem implies e.actorRole in e.actor.userRoles
  }
}

// FR-016: Initial audit entry (no prevStatus) must have actorRole = RApplicant or RSystem
fact F_InitialAuditActorRole {
  all e: AuditEntry |
    no e.prevStatus implies (e.actorRole = RApplicant or e.actorRole = RSystem)
}

// FR-016: Non-initial audit entries on status transitions must be authored by an officer
fact F_TransitionAuditActorIsOfficer {
  all e: AuditEntry |
    some e.prevStatus implies e.actorRole = ROfficer
}

// FR-017 / AuditCompleteness: every application has at least one audit entry
// and exactly one initial entry (prevStatus absent, newStatus = Pending)
fact F_EachApplicationHasInitialAuditEntry {
  all a: LoanApplication | one e: AuditEntry |
    e.forApp = a and no e.prevStatus and e.newStatus = Pending
}

// FR-018 (AppendOnly structural side): no two distinct AuditEntry atoms for
// the same application share the same (prevStatus, newStatus) pair —
// this encodes that the log is a linear chain with no duplicate transitions
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// FR-008: An applicant has at most one in-flight application
// (in-flight = Pending or UnderReview)
fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview) and
           a2.status in (Pending + UnderReview))
}

// FR-015: Terminal statuses are final — no audit entry has Approved or Rejected as prevStatus
// (already encoded in F_ValidStatusTransitions above, this makes it explicit for mutation testing)
fact F_TerminalStatusFinal {
  all e: AuditEntry | e.prevStatus != Approved and e.prevStatus != Rejected
}

// FR-013 / NoSelfMutation: The actor of a non-initial audit entry must not be
// the same user as the application's applicant (no self-approval)
fact F_NoSelfDecision {
  all e: AuditEntry |
    some e.prevStatus implies e.actor != e.forApp.applicant
}

// FR-023: GetAuditLog calls must use RAuditor role
fact F_AuditEndpointAuditorOnly {
  all c: ApiCall | c.opKind = GetAuditLog implies c.callRole = RAuditor
}

// FR-012: PatchStatus calls must use ROfficer role AND the caller must be the assigned officer
fact F_PatchOnlyByAssignedOfficer {
  all c: ApiCall |
    c.opKind = PatchStatus implies {
      c.callRole = ROfficer
      some c.targetApp
      c.caller = c.targetApp.assignedOfficer
    }
}

// FR-013 (defence-in-depth on ApiCall level): PatchStatus caller must not be the applicant
fact F_NoPatchSelfDecisionCall {
  all c: ApiCall |
    c.opKind = PatchStatus implies {
      some c.targetApp
      c.caller != c.targetApp.applicant
    }
}

// FR-003 / FR-005: PostApp may only be called by applicant role
fact F_PostAppApplicantOnly {
  all c: ApiCall | c.opKind = PostApp implies c.callRole = RApplicant
}

// ─────────────────────────────────────────────────────────────
// SECTION 5: Pattern predicates + assertions
// ─────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001 through FR-005
pred LeastPrivilege {
  // Every ApiCall's (callRole, opKind) pair must be in the allowed matrix
  some ApiCall
  all c: ApiCall | c.callRole -> c.opKind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix (all four endpoints defined)
pred PermissionCompleteness {
  // Every OperationKind has at least one Role that is allowed to call it
  all ok: OperationKind | some r: Role | r -> ok in PermMatrix.Allowed
  // RSystem has no allowed API operations
  no ok: OperationKind | RSystem -> ok in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Every ApiCall has a caller whose userRoles include the callRole
  some ApiCall
  all c: ApiCall | c.callRole in c.caller.userRoles
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017; data-model.md AuditEntry; SC-002, SC-008
pred AuditCompleteness {
  // Every application has at least one initial audit entry
  some LoanApplication
  all a: LoanApplication | some e: AuditEntry |
    e.forApp = a and no e.prevStatus and e.newStatus = Pending
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, FR-019; data-model.md "no UPDATE/DELETE"; SC-009
pred AppendOnly {
  // No two audit entries for the same application share (prevStatus, newStatus)
  // This encodes that each position in the chain is unique and immutable
  some AuditEntry
  all disj e1, e2: AuditEntry |
    e1.forApp = e2.forApp implies
      not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry actor_id/actor_role
pred AttributionCorrectness {
  // For non-system audit entries, the actorRole must be in the actor's userRoles
  some AuditEntry
  all e: AuditEntry |
    e.actorRole != RSystem implies e.actorRole in e.actor.userRoles
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id NOT NULL FK; spec.md FR-006
pred OwnershipExclusivity {
  // Every application has exactly one applicant with applicant role
  some LoanApplication
  all a: LoanApplication | {
    one a.applicant
    RApplicant in a.applicant.userRoles
  }
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012; contracts/http-api.md PATCH authorisation
pred OwnershipBasedAccess {
  // Every PatchStatus call must target an application the caller is assigned to
  some ApiCall
  all c: ApiCall |
    c.opKind = PatchStatus implies
      (some c.targetApp and c.caller = c.targetApp.assignedOfficer)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022, FR-023; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // GetAuditLog calls may only be made with auditor role
  some c: ApiCall | c.opKind = GetAuditLog
  all c: ApiCall | c.opKind = GetAuditLog implies c.callRole = RAuditor
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK applicant_id != assigned_officer_id; SC-006
pred NoSelfMutation {
  // No audit entry's actor is the same user as the application's applicant (for non-initial entries)
  some e: AuditEntry | some e.prevStatus
  all e: AuditEntry | some e.prevStatus implies e.actor != e.forApp.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// ─────────────────────────────────────────────────────────────
// SECTION 6: Feature-specific predicates (FR-by-FR)
// ─────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // All API calls carry a callRole that the caller actually holds
  some ApiCall
  all c: ApiCall | c.callRole in c.caller.userRoles
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMutualExclusion {
  // No user simultaneously holds both officer and auditor
  some User
  no u: User | (ROfficer in u.userRoles and RAuditor in u.userRoles)
}
assert FR_002_RoleMutualExclusion { FR_002_RoleMutualExclusion }
check FR_002_RoleMutualExclusion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantLimitedAccess {
  // An applicant-role caller cannot use PatchStatus or GetAuditLog
  some c: ApiCall | c.callRole = RApplicant
  all c: ApiCall |
    c.callRole = RApplicant implies
      c.opKind != PatchStatus and c.opKind != GetAuditLog
}
assert FR_003_ApplicantLimitedAccess { FR_003_ApplicantLimitedAccess }
check FR_003_ApplicantLimitedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerLimitedAccess {
  // An officer-role caller cannot use PostApp or GetAuditLog
  some c: ApiCall | c.callRole = ROfficer
  all c: ApiCall |
    c.callRole = ROfficer implies
      c.opKind != PostApp and c.opKind != GetAuditLog
}
assert FR_004_OfficerLimitedAccess { FR_004_OfficerLimitedAccess }
check FR_004_OfficerLimitedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  // An auditor-role caller cannot use PostApp or PatchStatus
  some c: ApiCall | c.callRole = RAuditor
  all c: ApiCall |
    c.callRole = RAuditor implies
      c.opKind != PostApp and c.opKind != PatchStatus
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_applicant
pred FR_008_OneInFlightPerApplicant {
  // No two distinct applications for the same applicant are both in-flight
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview) and
           a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md ApplicationStatus state machine
pred FR_009_ValidTransitions {
  // Every audit entry encodes a valid status transition
  some AuditEntry
  all e: AuditEntry | {
    no e.prevStatus implies e.newStatus = Pending
    e.prevStatus = Pending     implies e.newStatus = UnderReview
    e.prevStatus = UnderReview implies (e.newStatus = Approved or e.newStatus = Rejected)
    e.prevStatus != Approved
    e.prevStatus != Rejected
  }
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011; data-model.md CHECK assigned_officer_id != applicant_id
pred FR_011_NoSelfAssignment {
  // The assigned officer (if any) is never the same person as the applicant
  some a: LoanApplication | some a.assignedOfficer
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md SC-005
pred FR_012_OnlyAssignedOfficerCanPatch {
  // PatchStatus calls must come from the assigned officer of the target application
  some c: ApiCall | c.opKind = PatchStatus
  all c: ApiCall |
    c.opKind = PatchStatus implies
      (some c.targetApp and c.caller = c.targetApp.assignedOfficer)
}
assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md SC-006
pred FR_013_NoSelfApproval {
  // An officer cannot act as deciding officer on their own application
  // (checked at both the AuditEntry level and ApiCall level)
  some e: AuditEntry | some e.prevStatus
  all e: AuditEntry | some e.prevStatus implies e.actor != e.forApp.applicant
  all c: ApiCall |
    c.opKind = PatchStatus implies
      (some c.targetApp and c.caller != c.targetApp.applicant)
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md "no other transitions reachable"
pred FR_015_TerminalStatusFinal {
  // No audit entry has an Approved or Rejected prevStatus
  some AuditEntry
  all e: AuditEntry | e.prevStatus != Approved and e.prevStatus != Rejected
}
assert FR_015_TerminalStatusFinal { FR_015_TerminalStatusFinal }
check FR_015_TerminalStatusFinal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md AuditEntry schema; spec.md SC-003
pred FR_016_AuditEntryCompleteness {
  // Every application has at least one initial audit entry with correct actor role
  some LoanApplication
  all a: LoanApplication | (some e: AuditEntry |
    e.forApp = a and no e.prevStatus and e.newStatus = Pending and
    (e.actorRole = RApplicant or e.actorRole = RSystem))
}
assert FR_016_AuditEntryCompleteness { FR_016_AuditEntryCompleteness }
check FR_016_AuditEntryCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md append-only invariant; SC-009
pred FR_018_AuditImmutability {
  // No two audit entries for the same application encode the same transition
  // (structural proxy for append-only: each chain position is unique)
  some AuditEntry
  all disj e1, e2: AuditEntry |
    e1.forApp = e2.forApp implies
      not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
}
assert FR_018_AuditImmutability { FR_018_AuditImmutability }
check FR_018_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023; contracts/http-api.md GET /applications/{id}/audit authorisation
pred FR_023_AuditEndpointAuditorOnly {
  // Every GetAuditLog call must carry the auditor role
  some c: ApiCall | c.opKind = GetAuditLog
  all c: ApiCall | c.opKind = GetAuditLog implies c.callRole = RAuditor
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024; spec.md "applicant cannot modify after submission"
pred FR_024_ApplicantCannotModify {
  // No ApiCall with applicant role targets a PatchStatus operation
  some c: ApiCall | c.callRole = RApplicant
  all c: ApiCall | c.callRole = RApplicant implies c.opKind != PatchStatus
}
assert FR_024_ApplicantCannotModify { FR_024_ApplicantCannotModify }
check FR_024_ApplicantCannotModify for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj e1, e2: AuditEntry | e1.forApp = e2.forApp and e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus }
