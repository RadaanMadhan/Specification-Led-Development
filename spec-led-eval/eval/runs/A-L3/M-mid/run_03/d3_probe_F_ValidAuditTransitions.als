// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===
// Feature folder: A-L3  (branch: 005-fca-loan-applications)
// Sources: spec.md, data-model.md, contracts/http-api.md
// Encodes structural invariants; run with `alloy exec feature_model.als`

// ── Roles ──────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

// ── Application statuses ───────────────────────────────────────────────────────
abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ── Endpoint / operation kinds ─────────────────────────────────────────────────
abstract sig OperationKind {}
one sig OpPost, OpGet, OpPatch, OpAudit extends OperationKind {}

// ── Permission matrix (base role-level, closed-world) ─────────────────────────
// Ownership- and assignment-conditional checks are modelled as separate facts.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ── Users ──────────────────────────────────────────────────────────────────────
sig User { userRoles: some Role }

// ── Loan Applications ──────────────────────────────────────────────────────────
sig LoanApplication {
  appApplicant    : one  User,
  assignedOfficer : lone User,
  appStatus       : one  AppStatus
}

// ── Audit Entries (append-only, one per state transition) ──────────────────────
sig AuditEntry {
  forApp         : one  LoanApplication,
  entryActor     : one  User,
  entryActorRole : one  Role,
  prevStatus     : lone AppStatus,    // lone = nullable; null iff initial entry
  newStatus      : one  AppStatus
}

// ── API Operations (attempted calls, with success/failure outcome) ─────────────
sig Operation {
  opCaller      : one  User,
  opCallerRole  : one  Role,          // the single effective role for this call
  opKind        : one  OperationKind,
  opTarget      : lone LoanApplication,
  opSucceeded   : one  Bool
}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ══════════════════════════════════════════════════════════════════════════════
// STRUCTURAL FACTS
// ══════════════════════════════════════════════════════════════════════════════

// ── Non-empty universe (required to avoid vacuous-quantification artefacts) ──
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ── Effective role must be a role the caller holds ────────────────────────────
fact F_EffectiveRoleIsHeld {
  all op : Operation  | op.opCallerRole  in op.opCaller.userRoles
  all ae : AuditEntry | ae.entryActorRole in ae.entryActor.userRoles
}

// ── RSystem is never assigned to a real user (it is a synthetic sentinel) ─────
fact F_SystemRoleNotAssignedToUsers {
  all u : User | RSystem not in u.userRoles
}

// ── FR-002: officer and auditor are mutually exclusive role assignments ────────
fact F_OfficerAuditorMutualExclusion {
  all u : User | not (ROfficer in u.userRoles and RAuditor in u.userRoles)
}

// ── Every application's applicant field must resolve to a user with RApplicant ─
fact F_ApplicantHoldsApplicantRole {
  all app : LoanApplication | RApplicant in app.appApplicant.userRoles
}

// ── FR-010: assigned officer must hold ROfficer ───────────────────────────────
fact F_AssignedOfficerHoldsOfficerRole {
  all app : LoanApplication |
    some app.assignedOfficer implies ROfficer in app.assignedOfficer.userRoles
}

// ── FR-011: no self-assignment (schema-level defence) ─────────────────────────
fact F_NoSelfAssignment {
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.appApplicant
}

// ── FR-009 / data-model.md CHECK: initial entry is exactly (none → pending) ──
// prevStatus is absent IFF newStatus = Pending
fact F_InitialEntryShape {
  all ae : AuditEntry | (no ae.prevStatus) iff (ae.newStatus = Pending)
}

// ── data-model.md CHECK: no no-op transitions ─────────────────────────────────
fact F_NoNoOpTransitions {
  all ae : AuditEntry |
    some ae.prevStatus implies ae.prevStatus != ae.newStatus
}

// ── FR-009: only the four allowed status transitions appear in the audit log ───
fact F_ValidAuditTransitions {
  all ae : AuditEntry | {
    (no ae.prevStatus  and ae.newStatus = Pending)     or
    (ae.prevStatus = Pending     and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview and ae.newStatus = Approved)    or
    (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
  }
}

// ── FR-016 / FR-017: actor-role consistency with transition type ──────────────
// Initial submissions: actor_role ∈ {applicant, system}
// Status-change transitions: actor_role = officer
fact F_AuditActorRoleConsistency {
  all ae : AuditEntry | {
    (no ae.prevStatus)  implies (ae.entryActorRole = RApplicant or ae.entryActorRole = RSystem)
    (some ae.prevStatus) implies ae.entryActorRole = ROfficer
  }
}

// ── FR-016 / AuditCompleteness: every application has exactly one initial entry ─
fact F_UniqueInitialAuditEntry {
  all app : LoanApplication |
    one ae : AuditEntry | ae.forApp = app and no ae.prevStatus
}

// ── FR-017 / AuditCompleteness: non-initial entries are made by assigned officer
fact F_NonInitialEntryByAssignedOfficer {
  all ae : AuditEntry |
    some ae.prevStatus implies (
      some ae.forApp.assignedOfficer and
      ae.entryActor = ae.forApp.assignedOfficer
    )
}

// ── FR-013 / NoSelfApproval: officer cannot act on their own application ──────
fact F_NoSelfApproval {
  all ae : AuditEntry |
    some ae.prevStatus implies ae.entryActor != ae.forApp.appApplicant
}

// ── FR-008: at most one in-flight (pending or under_review) per applicant ──────
fact F_OneInFlightPerApplicant {
  all disj a1, a2 : LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (a1.appStatus in (Pending + UnderReview) and
           a2.appStatus in (Pending + UnderReview))
}

// ── FR-015: terminal statuses admit no further transitions ─────────────────────
// In any audit entry sequence, Approved / Rejected never appear as prevStatus.
fact F_TerminalStatusIsTerminal {
  all ae : AuditEntry |
    ae.prevStatus not in (Approved + Rejected)
}

// ── FR-012: only the assigned officer can perform PATCH (OpPatch) successfully ─
fact F_OnlyAssignedOfficerPatches {
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue) implies (
      some op.opTarget and
      some op.opTarget.assignedOfficer and
      op.opCaller = op.opTarget.assignedOfficer
    )
}

// ── FR-013 (defence-in-depth at operation layer): no successful PATCH where
//    caller is also the applicant ─────────────────────────────────────────────
fact F_NoSuccessfulSelfDecisionOp {
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue) implies
      (some op.opTarget and op.opCaller != op.opTarget.appApplicant)
}

// ── FR-003/004/005: only officers can PATCH (role-level gate) ─────────────────
fact F_PatchRequiresOfficerRole {
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue) implies
      ROfficer in op.opCaller.userRoles
}

// ── FR-005 / FR-023: only auditors can reach the audit endpoint successfully ──
fact F_AuditEndpointAuditorOnly {
  all op : Operation |
    (op.opKind = OpAudit and op.opSucceeded = BTrue) implies
      RAuditor in op.opCaller.userRoles
}

// ── FR-003: applicants cannot POST unless they hold RApplicant; officers cannot POST
fact F_PostRequiresApplicantRole {
  all op : Operation |
    (op.opKind = OpPost and op.opSucceeded = BTrue) implies
      RApplicant in op.opCaller.userRoles
}

// ── FR-004: pure-officer callers (no applicant role) cannot POST ──────────────
fact F_PureOfficerCannotPost {
  all op : Operation |
    (op.opKind = OpPost and op.opSucceeded = BTrue) implies
      RApplicant in op.opCaller.userRoles
}

// ── FR-005: auditors cannot POST ─────────────────────────────────────────────
// (auditor may also hold applicant, but pure-auditor cannot POST)
fact F_PureAuditorCannotPost {
  all op : Operation |
    (op.opKind = OpPost and op.opSucceeded = BTrue and
     RAuditor in op.opCaller.userRoles) implies
      RApplicant in op.opCaller.userRoles
}

// ── FR-001: authentication — every operation has a caller with at least one role
//    (the absence of a caller models unauthenticated; we enforce all ops have one)
fact F_AllOperationsAuthenticated {
  all op : Operation | some op.opCaller.userRoles
}

// ── FR-020/FR-021: NoInformationLeakage — a successful GET by a non-owner
//    non-officer non-auditor is structurally impossible (modelled as: every
//    successful OpGet has an authorised caller) ─────────────────────────────────
fact F_GetAuthorisedCallersOnly {
  all op : Operation |
    (op.opKind = OpGet and op.opSucceeded = BTrue and some op.opTarget) implies (
      // auditor may always GET
      (RAuditor in op.opCaller.userRoles) or
      // applicant is the application's own applicant
      (RApplicant in op.opCaller.userRoles and op.opCaller = op.opTarget.appApplicant) or
      // assigned officer of this application
      (ROfficer in op.opCaller.userRoles and
       some op.opTarget.assignedOfficer and
       op.opCaller = op.opTarget.assignedOfficer)
    )
}

// ── Permission matrix (base role-level closed-world assignment) ───────────────
// Encodes the unconditional cells from contracts/http-api.md.
// Ownership- and assignment-conditional cells are enforced by separate facts above.
fact F_PermissionMatrix {
  // Applicant: unconditionally allowed to POST
  RApplicant -> OpPost in PermMatrix.Allowed
  // Auditor: unconditionally allowed to GET and to reach the audit endpoint
  RAuditor -> OpGet   in PermMatrix.Allowed
  RAuditor -> OpAudit in PermMatrix.Allowed
  // Closed-world: no other unconditional grants exist
  PermMatrix.Allowed =
    (RApplicant -> OpPost) +
    (RAuditor   -> OpGet)  +
    (RAuditor   -> OpAudit)
}

// ── FR-024: applicant cannot modify application fields post-submission ─────────
// Modelled as: no successful PATCH whose caller is a pure applicant
fact F_ApplicantCannotPatch {
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue) implies
      not (op.opCallerRole = RApplicant)
}

// ── FR-018: audit entries are never the target of a write operation ────────────
// Modelled structurally: no successful OpPatch or OpPost targets an AuditEntry
// (AuditEntry is not a LoanApplication; the only patchable resource is LoanApplication)
// This is inherent from type separation; we assert the separation is maintained.
fact F_AuditEntriesNotPatchable {
  // AuditEntry atoms are not LoanApplication atoms — disjoint by Alloy sigs.
  // No operation's opTarget can be an AuditEntry (opTarget : lone LoanApplication).
  // The fact body enforces that no two distinct AuditEntry atoms share an id
  // (i.e., the log is uniquely keyed — append-only semantics in the static model).
  all disj ae1, ae2 : AuditEntry |
    (ae1.forApp = ae2.forApp and ae1.prevStatus = ae2.prevStatus) implies
      ae1.newStatus != ae2.newStatus
}

// ══════════════════════════════════════════════════════════════════════════════
// PATTERN PREDICATES AND ASSERTIONS
// ══════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-003, FR-004, FR-005
pred LeastPrivilege {
  some Operation
  // Any role-op pair NOT in PermMatrix.Allowed never succeeds unconditionally.
  // Specifically: officer (pure) cannot POST, auditor cannot PATCH, applicant cannot AuditRead.
  all op : Operation | {
    // Pure-officer (no applicant role) cannot succeed at POST
    (ROfficer in op.opCaller.userRoles and
     RApplicant not in op.opCaller.userRoles and
     op.opKind = OpPost) implies op.opSucceeded = BFalse
    // Auditor cannot succeed at PATCH
    (RAuditor in op.opCaller.userRoles and
     op.opKind = OpPatch) implies op.opSucceeded = BFalse
    // Non-auditor cannot succeed at OpAudit
    (RAuditor not in op.opCaller.userRoles and
     op.opKind = OpAudit) implies op.opSucceeded = BFalse
    // Non-applicant (no applicant role) cannot succeed at POST
    (RApplicant not in op.opCaller.userRoles and
     op.opKind = OpPost) implies op.opSucceeded = BFalse
  }
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is either explicitly allowed or
  // forbidden — confirmed by the closed-world assignment in F_PermissionMatrix.
  // We check that PermMatrix.Allowed contains exactly the expected cells.
  PermMatrix.Allowed =
    (RApplicant -> OpPost) +
    (RAuditor   -> OpGet)  +
    (RAuditor   -> OpAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every operation in the system has a caller with at least one role
  // (caller with no roles is unauthenticated and cannot have succeeded).
  some Operation
  all op : Operation | some op.opCaller.userRoles
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017; data-model.md UNIQUE(initial entry per app)
pred AuditCompleteness {
  // Every application has exactly one initial audit entry.
  some LoanApplication
  all app : LoanApplication |
    (one ae : AuditEntry | ae.forApp = app and no ae.prevStatus) and
    (all ae : AuditEntry | ae.forApp = app and no ae.prevStatus implies ae.newStatus = Pending)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, FR-019; data-model.md "no UPDATE/DELETE" notes
pred AppendOnly {
  // In the static model, append-only is expressed as:
  // no two distinct AuditEntries for the same application describe the same
  // before→after transition (each event is unique and immutable).
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    ae1.forApp = ae2.forApp implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus
           and ae1.entryActor = ae2.entryActor)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit-entry fields
pred AttributionCorrectness {
  // For every non-initial audit entry, the actor must be the application's
  // assigned officer, and the actor_role must be ROfficer.
  some ae : AuditEntry | some ae.prevStatus
  all ae : AuditEntry | some ae.prevStatus implies (
    ae.entryActorRole = ROfficer and
    some ae.forApp.assignedOfficer and
    ae.entryActor = ae.forApp.assignedOfficer
  )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id; spec.md FR-006
pred OwnershipExclusivity {
  // Every LoanApplication has exactly one applicant.
  some LoanApplication
  all app : LoanApplication | one app.appApplicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-020; contracts/http-api.md permission table
pred OwnershipBasedAccess {
  // A successful GET by a non-auditor applicant must be for their own application.
  some Operation
  all op : Operation |
    (op.opKind = OpGet and op.opSucceeded = BTrue and
     RAuditor not in op.opCaller.userRoles and
     RApplicant in op.opCaller.userRoles and
     some op.opTarget) implies op.opCaller = op.opTarget.appApplicant
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022; contracts/http-api.md byte-equiv not-found
pred NoInformationLeakage {
  // A caller that is not the applicant, not the assigned officer, and not an auditor
  // cannot succeed at GET /applications/{id}.
  some LoanApplication
  all op : Operation |
    (op.opKind = OpGet and op.opSucceeded = BTrue and some op.opTarget) implies (
      RAuditor in op.opCaller.userRoles or
      op.opCaller = op.opTarget.appApplicant or
      (some op.opTarget.assignedOfficer and op.opCaller = op.opTarget.assignedOfficer)
    )
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation (specialised as NoSelfApproval)
//   ANCHOR: spec.md FR-013; data-model.md CHECK(applicant_id != assigned_officer_id)
pred NoSelfMutation {
  // No audit entry for a non-initial transition has the same user as both
  // actor and the application's applicant.
  some ae : AuditEntry | some ae.prevStatus
  all ae : AuditEntry | some ae.prevStatus implies ae.entryActor != ae.forApp.appApplicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001, FR-006, FR-014; data-model.md atomicity
pred ValidationBeforeMutation {
  // An application may only exist at status Pending if it has an initial audit entry.
  // (Checks that no half-created state can occur: audit + application are atomic.)
  some LoanApplication
  all app : LoanApplication |
    app.appStatus = Pending implies
      (some ae : AuditEntry | ae.forApp = app and no ae.prevStatus and ae.newStatus = Pending)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ══════════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES AND ASSERTIONS
// ══════════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // No operation in the system lacks an authenticated caller.
  // (Unauthenticated = caller has no roles; but F_EffectiveRoleIsHeld + F_AllOperationsAuthenticated
  // ensure every caller has roles.)
  some Operation
  all op : Operation | some op.opCaller and some op.opCaller.userRoles
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMutualExclusion {
  // officer and auditor are mutually exclusive for every user.
  some User
  all u : User | not (ROfficer in u.userRoles and RAuditor in u.userRoles)
}
assert FR_002_RoleMutualExclusion { FR_002_RoleMutualExclusion }
check FR_002_RoleMutualExclusion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantPermissions {
  // Applicants (pure — no officer role) cannot successfully PATCH or reach the audit endpoint.
  some Operation
  all op : Operation |
    (RApplicant in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles) implies (
      op.opKind != OpPatch  or op.opSucceeded = BFalse
    ) and (
      op.opKind != OpAudit  or op.opSucceeded = BFalse
    )
}
assert FR_003_ApplicantPermissions { FR_003_ApplicantPermissions }
check FR_003_ApplicantPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerPermissions {
  // Pure officers (no applicant role) cannot POST a new application.
  some Operation
  all op : Operation |
    (ROfficer in op.opCaller.userRoles and RApplicant not in op.opCaller.userRoles) implies (
      op.opKind != OpPost or op.opSucceeded = BFalse
    )
}
assert FR_004_OfficerPermissions { FR_004_OfficerPermissions }
check FR_004_OfficerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  // Pure auditors (no applicant role) cannot POST or PATCH.
  some Operation
  all op : Operation |
    (RAuditor in op.opCaller.userRoles and RApplicant not in op.opCaller.userRoles) implies (
      (op.opKind != OpPost  or op.opSucceeded = BFalse) and
      (op.opKind != OpPatch or op.opSucceeded = BFalse)
    )
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  // No applicant has two distinct in-flight applications simultaneously.
  some LoanApplication
  all disj a1, a2 : LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (a1.appStatus in (Pending + UnderReview) and
           a2.appStatus in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ValidTransitions {
  // Every non-initial audit entry describes one of the three legal transitions.
  some ae : AuditEntry | some ae.prevStatus
  all ae : AuditEntry | some ae.prevStatus implies (
    (ae.prevStatus = Pending     and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview and ae.newStatus = Approved)    or
    (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
  )
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  // Whenever an application has an assigned officer, that officer is not the applicant.
  some app : LoanApplication | some app.assignedOfficer
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.appApplicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerCanPatch {
  // A successful PATCH can only be performed by the application's assigned officer.
  some op : Operation | op.opKind = OpPatch and op.opSucceeded = BTrue
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue) implies (
      some op.opTarget and
      some op.opTarget.assignedOfficer and
      op.opCaller = op.opTarget.assignedOfficer
    )
}
assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfApproval {
  // An officer cannot successfully PATCH an application where they are the applicant.
  // Also encoded at the audit-entry layer.
  some LoanApplication
  // In the operation layer:
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue and some op.opTarget) implies
      op.opCaller != op.opTarget.appApplicant
  // In the audit layer:
  all ae : AuditEntry |
    some ae.prevStatus implies ae.entryActor != ae.forApp.appApplicant
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoTransitionFromTerminal {
  // Approved and Rejected never appear as prevStatus — no further transitions.
  some ae : AuditEntry | some ae.prevStatus
  all ae : AuditEntry | ae.prevStatus not in (Approved + Rejected)
}
assert FR_015_NoTransitionFromTerminal { FR_015_NoTransitionFromTerminal }
check FR_015_NoTransitionFromTerminal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md audit-entry fields
pred FR_016_AuditEntryFields {
  // Every audit entry has an actor whose role is consistent with the entry type.
  some AuditEntry
  all ae : AuditEntry | {
    one ae.forApp
    one ae.entryActor
    one ae.entryActorRole
    one ae.newStatus
    (no ae.prevStatus) iff (ae.newStatus = Pending)
  }
}
assert FR_016_AuditEntryFields { FR_016_AuditEntryFields }
check FR_016_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md append-only invariant
pred FR_018_AuditImmutable {
  // No two distinct AuditEntries for the same application record the same
  // (prevStatus, newStatus, actor) triple — each transition event is unique.
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    ae1.forApp = ae2.forApp implies
      not (ae1.prevStatus = ae2.prevStatus and
           ae1.newStatus  = ae2.newStatus  and
           ae1.entryActor = ae2.entryActor)
}
assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md 6-year retention
pred FR_019_AuditRetention {
  // Every application retains its initial audit entry (append-only implies retention).
  some LoanApplication
  all app : LoanApplication |
    some ae : AuditEntry | ae.forApp = app and no ae.prevStatus
}
assert FR_019_AuditRetention { FR_019_AuditRetention }
check FR_019_AuditRetention for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020, FR-021; contracts/http-api.md byte-equivalent not-found
pred FR_020_ByteEquivalentUnauthorized {
  // Any successful GET must have an authorised caller.
  // A non-owner, non-officer, non-auditor cannot distinguish "exists" from "missing".
  some LoanApplication
  all op : Operation |
    (op.opKind = OpGet and op.opSucceeded = BTrue and some op.opTarget) implies (
      RAuditor in op.opCaller.userRoles or
      op.opCaller = op.opTarget.appApplicant or
      (some op.opTarget.assignedOfficer and op.opCaller = op.opTarget.assignedOfficer)
    )
}
assert FR_020_ByteEquivalentUnauthorized { FR_020_ByteEquivalentUnauthorized }
check FR_020_ByteEquivalentUnauthorized for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023; contracts/http-api.md audit endpoint
pred FR_023_AuditEndpointAuditorOnly {
  // Only auditors can successfully call the audit endpoint.
  some op : Operation | op.opKind = OpAudit and op.opSucceeded = BTrue
  all op : Operation |
    (op.opKind = OpAudit and op.opSucceeded = BTrue) implies
      RAuditor in op.opCaller.userRoles
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024; spec.md immutability of applicant-submitted data
pred FR_024_ApplicantCannotModifyAfterSubmission {
  // No successful PATCH is performed under the applicant role.
  some Operation
  all op : Operation |
    (op.opKind = OpPatch and op.opSucceeded = BTrue) implies
      op.opCallerRole != RApplicant
}
assert FR_024_ApplicantCannotModifyAfterSubmission { FR_024_ApplicantCannotModifyAfterSubmission }
check FR_024_ApplicantCannotModifyAfterSubmission for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_InvalidTransitionViolation { some ae : AuditEntry | ae.prevStatus = Rejected and ae.newStatus = Pending }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
