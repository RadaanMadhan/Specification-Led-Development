// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature folder: A-L3  (branch 005-fca-loan-applications)
// Artefacts: spec.md, data-model.md, contracts/http-api.md
// Alloy 6 — standalone, no external imports

// ────────────────────────────────────────────────────────────────────────────
// ROLES
// ────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

// ────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (the four public endpoints)
// ────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById,
        PatchApplicationStatus, GetApplicationAudit extends OperationKind {}

// ────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (unconditional base grants; conditional access is
// modelled by separate predicates)
// ────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ────────────────────────────────────────────────────────────────────────────
abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ────────────────────────────────────────────────────────────────────────────
// RESULT (success / failure of an Operation)
// ────────────────────────────────────────────────────────────────────────────
abstract sig Result {}
one sig Succeeded, Failed extends Result {}

// ────────────────────────────────────────────────────────────────────────────
// USER  (may hold multiple roles; officer ∩ auditor must be ∅ — FR-002)
// ────────────────────────────────────────────────────────────────────────────
sig User { uRoles: set Role }

// ────────────────────────────────────────────────────────────────────────────
// LOAN APPLICATION
// ────────────────────────────────────────────────────────────────────────────
sig LoanApplication {
  lApplicant : one User,
  lOfficer   : lone User,   // nullable — "no eligible officer" edge case (FR-011)
  lStatus    : one AppStatus
}

// ────────────────────────────────────────────────────────────────────────────
// AUDIT ENTRY  (append-only, one per state transition — FR-016/FR-017/FR-018)
// ────────────────────────────────────────────────────────────────────────────
sig AuditEntry {
  eApp       : one LoanApplication,
  eActor     : one User,
  eActorRole : one Role,
  ePrev      : lone AppStatus,   // lone = nullable (null only for initial entry)
  eNew       : one AppStatus
}

// ────────────────────────────────────────────────────────────────────────────
// OPERATION  (represents one API call; may succeed or fail)
// ────────────────────────────────────────────────────────────────────────────
sig Operation {
  oCaller     : one User,
  oCallerRole : one Role,   // the role token under which the call is made
  oKind       : one OperationKind,
  oApp        : lone LoanApplication,
  oResult     : one Result
}

// ════════════════════════════════════════════════════════════════════════════
// NON-EMPTY UNIVERSE
// ════════════════════════════════════════════════════════════════════════════
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ════════════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX  (from contracts/http-api.md permission table)
// RApplicant  → PostApplications        (FR-003, US1)
// RAuditor    → GetApplicationById      (FR-005, US3)
// ROfficer    → PatchApplicationStatus  (FR-004, US2 — conditional guards
//                                        modelled separately)
// RAuditor    → GetApplicationAudit     (FR-005, FR-023, US3)
// All other (role, op) pairs are denied.
// ════════════════════════════════════════════════════════════════════════════
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RApplicant -> PostApplications)      +
    (RAuditor   -> GetApplicationById)    +
    (ROfficer   -> PatchApplicationStatus)+
    (RAuditor   -> GetApplicationAudit)
}

// ════════════════════════════════════════════════════════════════════════════
// ROLE MULTIPLICITY CONSTRAINTS  (FR-002, data-model.md)
// ════════════════════════════════════════════════════════════════════════════
fact F_NoOfficerAuditorCombo {
  // No user may simultaneously hold officer and auditor roles.
  no u: User | ROfficer in u.uRoles and RAuditor in u.uRoles
}

fact F_SystemRoleNotAssignedToUsers {
  // RSystem is used only as an actor_role in audit entries; never in uRoles.
  no u: User | RSystem in u.uRoles
}

fact F_CallerRoleIsHeld {
  // Every operation's caller role must be a role the caller actually holds.
  all op: Operation | op.oCallerRole in op.oCaller.uRoles
}

// ════════════════════════════════════════════════════════════════════════════
// APPLICATION STRUCTURAL CONSTRAINTS
// ════════════════════════════════════════════════════════════════════════════
fact F_ApplicantMustHoldApplicantRole {
  // The applicant on every application must hold the applicant role (FR-006).
  all a: LoanApplication | RApplicant in a.lApplicant.uRoles
}

fact F_OfficerMustHoldOfficerRole {
  // If an officer is assigned, they must hold the officer role.
  all a: LoanApplication |
    some a.lOfficer implies ROfficer in a.lOfficer.uRoles
}

fact F_NoSelfAssignment {
  // The assigned officer must differ from the applicant (FR-011,
  // data-model.md CHECK assigned_officer_id != applicant_id).
  all a: LoanApplication |
    some a.lOfficer implies a.lOfficer != a.lApplicant
}

fact F_OneInFlightPerApplicant {
  // No applicant may have two applications simultaneously in status
  // pending or under_review (FR-008,
  // data-model.md UNIQUE INDEX idx_one_in_flight_per_applicant).
  all disj a1, a2: LoanApplication |
    a1.lApplicant = a2.lApplicant implies
      not (a1.lStatus in (Pending + UnderReview) and
           a2.lStatus in (Pending + UnderReview))
}

// ════════════════════════════════════════════════════════════════════════════
// VALID STATUS TRANSITION CONSTRAINTS  (FR-009, data-model.md state machine)
// ════════════════════════════════════════════════════════════════════════════
fact F_ValidAuditTransitions {
  // The only legal (prev → new) pairs for audit entries are exactly those
  // in the state machine:
  //   null → pending  (initial submission)
  //   pending → under_review
  //   under_review → approved
  //   under_review → rejected
  // (no self-loops, no skipped stages)
  all e: AuditEntry | {
    // Initial entry: prev is null, new must be pending.
    (no e.ePrev) implies e.eNew = Pending
    // Non-initial entries: prev must be non-null and the pair legal.
    (some e.ePrev) implies (
      (e.ePrev = Pending     and e.eNew = UnderReview) or
      (e.ePrev = UnderReview and e.eNew = Approved)    or
      (e.ePrev = UnderReview and e.eNew = Rejected)
    )
  }
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT COMPLETENESS  (FR-016, FR-017)
// Every application must have at least one audit entry (the initial one).
// The initial entry has null prev and new = pending.
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditCompleteness {
  // Every application has at least one audit entry.
  all a: LoanApplication | some e: AuditEntry | e.eApp = a
  // Every application has exactly one initial audit entry
  // (prev = null, new = pending).
  all a: LoanApplication |
    one e: AuditEntry | e.eApp = a and no e.ePrev and e.eNew = Pending
}

// ════════════════════════════════════════════════════════════════════════════
// APPEND-ONLY AUDIT LOG  (FR-018, data-model.md "no UPDATE/DELETE")
// In the static model: no two distinct audit entries for the same application
// may record the same (prev, new) transition — each observable transition
// is unique within an application.  (Multiple entries only possible if they
// differ in at least one field.)
// ════════════════════════════════════════════════════════════════════════════
fact F_AppendOnlyAuditEntries {
  // Within one application, no two audit entries share the same
  // (ePrev, eNew) pair — each transition along the chain is distinct.
  all disj e1, e2: AuditEntry |
    e1.eApp = e2.eApp implies
      not (e1.ePrev = e2.ePrev and e1.eNew = e2.eNew)
}

// ════════════════════════════════════════════════════════════════════════════
// ATTRIBUTION CORRECTNESS  (FR-016, data-model.md actor_role column)
// The actor_role recorded in each audit entry must be a role the actor holds.
// ════════════════════════════════════════════════════════════════════════════
fact F_AttributionCorrectness {
  all e: AuditEntry |
    e.eActorRole != RSystem implies e.eActorRole in e.eActor.uRoles
}

// ════════════════════════════════════════════════════════════════════════════
// TERMINAL STATES ARE FINAL  (FR-015)
// An application at approved or rejected must not have any further
// audit entries that start from those statuses.
// ════════════════════════════════════════════════════════════════════════════
fact F_TerminalStateFinal {
  // No audit entry may have ePrev = Approved or ePrev = Rejected.
  no e: AuditEntry | e.ePrev = Approved or e.ePrev = Rejected
}

// ════════════════════════════════════════════════════════════════════════════
// NO SELF-APPROVAL  (FR-013, defence-in-depth)
// An officer who is also the applicant on an application must not
// be the actor on any non-initial audit entry for that application.
// ════════════════════════════════════════════════════════════════════════════
fact F_NoSelfApproval {
  all e: AuditEntry |
    (some e.ePrev) implies e.eActor != e.eApp.lApplicant
}

// ════════════════════════════════════════════════════════════════════════════
// ONLY ASSIGNED OFFICER MAY MAKE NON-INITIAL TRANSITIONS  (FR-012)
// ════════════════════════════════════════════════════════════════════════════
fact F_OnlyAssignedOfficerTransitions {
  all e: AuditEntry |
    (some e.ePrev and e.eActorRole = ROfficer) implies
      e.eActor = e.eApp.lOfficer
}

// ════════════════════════════════════════════════════════════════════════════
// AUDITOR IS READ-ONLY  (FR-005)
// No audit entry may be authored by a caller holding only the auditor role.
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditorReadOnly {
  all e: AuditEntry | e.eActorRole != RAuditor
}

// ════════════════════════════════════════════════════════════════════════════
// OPERATION AUTH CONSTRAINT  (FR-001)
// Every Operation that succeeds must have a caller who holds at least one role.
// (In practice: the caller's role set is non-empty, i.e. authenticated.)
// ════════════════════════════════════════════════════════════════════════════
fact F_AuthRequiredConstraint {
  all op: Operation | op.oResult = Succeeded implies some op.oCaller.uRoles
}

// ════════════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX BINDING FOR OPERATIONS
// A successful Operation is only possible if (callerRole, kind) is in Allowed,
// OR the operation is a conditional read (GetApplicationById for an owner or
// assigned officer — handled by ownership access facts).
// ════════════════════════════════════════════════════════════════════════════
fact F_PermissionBinding {
  all op: Operation |
    op.oResult = Succeeded implies (
      // Either the base permission exists in the matrix …
      (op.oCallerRole -> op.oKind) in PermMatrix.Allowed
      or
      // … or it's a conditional read where the caller is the app's applicant
      (op.oKind = GetApplicationById and some op.oApp and
       op.oCallerRole = RApplicant and op.oCaller = op.oApp.lApplicant)
      or
      // … or it's the assigned officer reading their own application
      (op.oKind = GetApplicationById and some op.oApp and
       op.oCallerRole = ROfficer and op.oCaller = op.oApp.lOfficer)
    )
}

// ════════════════════════════════════════════════════════════════════════════
// NO INFORMATION LEAKAGE — UNIFORM UNAUTHORISED RESPONSE  (FR-020, FR-021)
// Modelled structurally: any two (caller, application) pairs where the caller
// lacks access are indistinguishable — both produce Failed with no application
// data exposed.  We capture this by requiring that a Failed GET on an
// existing application looks the same as a Failed GET on a non-existent one:
// the Operation's oApp link must be absent (null) when the call fails.
// ════════════════════════════════════════════════════════════════════════════
fact F_NoInfoLeakageOnFailedRead {
  // A failed GET /applications/{id} must not carry a reference to the
  // application atom (i.e., the system must not disclose whether the
  // application exists).
  all op: Operation |
    (op.oKind = GetApplicationById and op.oResult = Failed)
    implies no op.oApp
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT ENDPOINT AUDITOR-ONLY  (FR-023)
// A successful GetApplicationAudit operation must have callerRole = RAuditor.
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditEndpointAuditorOnly { /* MUTATED — body cleared by validator */ }

// ════════════════════════════════════════════════════════════════════════════
// VALIDATION BEFORE MUTATION  (FR-001, FR-014, FR-017)
// A failed operation (due to validation) must not produce an audit entry.
// Modelled as: if an operation failed, no audit entry is linked to the app
// via that same actor in a way that could only come from that operation.
// We use the cleaner structural form: every AuditEntry must correspond to
// a succeeded operation by the same actor on the same application.
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditEntryOnlyOnSuccess {
  all e: AuditEntry |
    some op: Operation |
      op.oResult = Succeeded and
      op.oCaller = e.eActor and
      op.oApp = e.eApp
}

// ════════════════════════════════════════════════════════════════════════════
// POST /applications CALLER MUST HOLD APPLICANT ROLE  (FR-003)
// ════════════════════════════════════════════════════════════════════════════
fact F_PostRequiresApplicantRole {
  all op: Operation |
    (op.oKind = PostApplications and op.oResult = Succeeded)
    implies RApplicant in op.oCaller.uRoles
}

// ════════════════════════════════════════════════════════════════════════════
// PATCH requires officer role and the caller must be the assigned officer
// and must NOT be the applicant (FR-012, FR-013)
// ════════════════════════════════════════════════════════════════════════════
fact F_PatchRequiresAssignedOfficer {
  all op: Operation |
    (op.oKind = PatchApplicationStatus and op.oResult = Succeeded)
    implies (
      ROfficer in op.oCaller.uRoles and
      some op.oApp and
      op.oCaller = op.oApp.lOfficer and
      op.oCaller != op.oApp.lApplicant
    )
}

// ════════════════════════════════════════════════════════════════════════════
// INITIAL AUDIT ENTRY ACTOR ROLE  (FR-016)
// The initial audit entry (ePrev = null) must be authored by the applicant
// or by the system (when no eligible officer exists).
// ════════════════════════════════════════════════════════════════════════════
fact F_InitialAuditActorRole {
  all e: AuditEntry |
    no e.ePrev implies
      (e.eActorRole = RApplicant or e.eActorRole = RSystem)
}

// ════════════════════════════════════════════════════════════════════════════
// APPLICANT CANNOT MODIFY APPLICATION AFTER SUBMISSION  (FR-024)
// No non-initial audit entry is authored by an applicant-role actor.
// ════════════════════════════════════════════════════════════════════════════
fact F_ApplicantNoPostSubmissionMutation {
  all e: AuditEntry |
    (some e.ePrev) implies e.eActorRole != RApplicant
}

// ════════════════════════════════════════════════════════════════════════════
// APPLICATION STATUS CONSISTENCY
// The current status of an application must be reachable from the initial
// pending status through the allowed transitions recorded in audit entries.
// ════════════════════════════════════════════════════════════════════════════
fact F_StatusConsistencyWithAudit {
  // The current status of every application equals the eNew of its
  // most-terminal audit entry.  We approximate: if the application is
  // approved or rejected, there must be an audit entry recording that.
  all a: LoanApplication |
    (a.lStatus = Approved  implies
      (some e: AuditEntry | e.eApp = a and e.eNew = Approved))
  all a: LoanApplication |
    (a.lStatus = Rejected  implies
      (some e: AuditEntry | e.eApp = a and e.eNew = Rejected))
  all a: LoanApplication |
    (a.lStatus = UnderReview implies
      (some e: AuditEntry | e.eApp = a and e.eNew = UnderReview))
}

// ════════════════════════════════════════════════════════════════════════════
// PRIVILEGE MONOTONICITY — Auditor can read anything officer or applicant can
// (FR-005 supersedes FR-003/FR-004 on reads)
// ════════════════════════════════════════════════════════════════════════════
fact F_AuditorSupersetsReadAccess {
  // RAuditor is in Allowed for both read endpoints; any (role, read-op) pair
  // for non-auditor roles that is NOT in Allowed must not succeed unless
  // the conditional ownership path allows it (already modelled in F_PermissionBinding).
  // This fact encodes: ROfficer and RApplicant are NOT in Allowed for GetApplicationAudit.
  (ROfficer -> GetApplicationAudit) not in PermMatrix.Allowed
  (RApplicant -> GetApplicationAudit) not in PermMatrix.Allowed
  (RSystem -> GetApplicationAudit) not in PermMatrix.Allowed
}

// ════════════════════════════════════════════════════════════════════════════
//
//  P R E D I C A T E S   &   A S S E R T I O N S
//
// ════════════════════════════════════════════════════════════════════════════

// ── Catalogue pattern: LeastPrivilege ────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-003,FR-004,FR-005
pred LeastPrivilege {
  some User and some LoanApplication and some Operation
  // Denied cells: a succeeded operation never has a (role, kind) pair absent
  // from the Allowed relation (modulo conditional reads).
  all op: Operation |
    op.oResult = Succeeded implies (
      (op.oCallerRole -> op.oKind) in PermMatrix.Allowed
      or
      (op.oKind = GetApplicationById and some op.oApp and
        (op.oCaller = op.oApp.lApplicant or op.oCaller = op.oApp.lOfficer))
    )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// ── Catalogue pattern: PermissionCompleteness ────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either explicitly allowed or implicitly denied.
  // The Allowed relation is total over the domain — no undefined cells.
  // We verify the matrix has the correct cardinality: exactly 4 allowed cells.
  #(PermMatrix.Allowed) = 4
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// ── Catalogue pattern: AuthRequiredEverywhere ─────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some op: Operation | op.oResult = Succeeded
  // Every successful operation has a caller with a non-empty role set
  // (i.e., the caller was authenticated and resolved to a role).
  all op: Operation |
    op.oResult = Succeeded implies some op.oCaller.uRoles
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// ── Catalogue pattern: AuditCompleteness ─────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016,FR-017; data-model.md AuditEntry
pred AuditCompleteness {
  some LoanApplication and some AuditEntry
  // Every application has at least one audit entry.
  all a: LoanApplication | some e: AuditEntry | e.eApp = a
  // Every application has exactly one initial audit entry.
  all a: LoanApplication |
    one e: AuditEntry | e.eApp = a and no e.ePrev and e.eNew = Pending
  // Approved/Rejected applications have a corresponding terminal audit entry.
  all a: LoanApplication |
    a.lStatus = Approved implies (some e: AuditEntry | e.eApp = a and e.eNew = Approved)
  all a: LoanApplication |
    a.lStatus = Rejected implies (some e: AuditEntry | e.eApp = a and e.eNew = Rejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// ── Catalogue pattern: AppendOnly ─────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018,FR-019; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  // No two audit entries for the same application record the same transition.
  // This encodes immutability: a "mutation" would create a new entry with
  // the same (app, prev, new) as an existing one, which is disallowed.
  all disj e1, e2: AuditEntry |
    e1.eApp = e2.eApp implies
      not (e1.ePrev = e2.ePrev and e1.eNew = e2.eNew)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// ── Catalogue pattern: AttributionCorrectness ─────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_role
pred AttributionCorrectness {
  some AuditEntry
  // For non-system audit entries, the actor must hold the recorded role.
  all e: AuditEntry |
    e.eActorRole != RSystem implies e.eActorRole in e.eActor.uRoles
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// ── Catalogue pattern: OwnershipBasedAccess ───────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003,FR-004; contracts/http-api.md GET permission table
pred OwnershipBasedAccess {
  some op: Operation | op.oKind = GetApplicationById and op.oResult = Succeeded
  // For a successful GET /applications/{id} by an applicant-role caller,
  // the caller must be the application's applicant.
  all op: Operation |
    (op.oKind = GetApplicationById and op.oResult = Succeeded and
     op.oCallerRole = RApplicant and (op.oCallerRole -> GetApplicationById) not in PermMatrix.Allowed)
    implies (some op.oApp and op.oCaller = op.oApp.lApplicant)
  // For a successful GET by an officer-role caller (not auditor),
  // the caller must be the assigned officer.
  all op: Operation |
    (op.oKind = GetApplicationById and op.oResult = Succeeded and
     op.oCallerRole = ROfficer)
    implies (some op.oApp and op.oCaller = op.oApp.lOfficer)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// ── Catalogue pattern: NoInformationLeakage ───────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020,FR-021,FR-022; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some op: Operation | op.oKind = GetApplicationById and op.oResult = Failed
  // Failed GET operations carry no reference to the application —
  // the caller cannot tell "exists but forbidden" from "does not exist".
  all op: Operation |
    (op.oKind = GetApplicationById and op.oResult = Failed)
    implies no op.oApp
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ── Catalogue pattern: NoSelfMutation (NoSelfApproval) ────────────────────────
// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK applicant_id != assigned_officer_id
pred NoSelfMutation {
  some AuditEntry
  some LoanApplication
  // No non-initial audit entry's actor is the applicant of the same application.
  all e: AuditEntry |
    (some e.ePrev) implies e.eActor != e.eApp.lApplicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// ── Catalogue pattern: ValidationBeforeMutation ───────────────────────────────
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001,FR-014,FR-017; contracts/http-api.md 400/401 responses
pred ValidationBeforeMutation {
  some AuditEntry
  // Every audit entry has a corresponding succeeded operation by the same actor
  // on the same application — meaning failed (invalid) calls produce no audit entries.
  all e: AuditEntry |
    some op: Operation |
      op.oResult = Succeeded and op.oCaller = e.eActor and op.oApp = e.eApp
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ── FR-001: All endpoints require authentication ───────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md "unauthenticated → 401 before any business logic"
pred FR_001_AuthRequired {
  some op: Operation | op.oResult = Succeeded
  all op: Operation |
    op.oResult = Succeeded implies some op.oCaller.uRoles
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// ── FR-002: No user holds officer + auditor simultaneously ─────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md users.roles CHECK constraint
pred FR_002_RoleMultiplicity {
  some User
  no u: User | ROfficer in u.uRoles and RAuditor in u.uRoles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 6

// ── FR-003: Applicant cannot PATCH status ──────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003; contracts/http-api.md permission table row "PATCH /applications/{id}/status"
pred FR_003_ApplicantCannotPatch {
  some op: Operation | op.oKind = PatchApplicationStatus
  no op: Operation |
    op.oKind = PatchApplicationStatus and
    op.oResult = Succeeded and
    op.oCallerRole = RApplicant
}
assert FR_003_ApplicantCannotPatch { FR_003_ApplicantCannotPatch }
check FR_003_ApplicantCannotPatch for 6

// ── FR-004: Officer cannot POST a new application ──────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004; contracts/http-api.md permission table row "POST /applications"
pred FR_004_OfficerCannotPost {
  // A pure-officer caller (no applicant role) cannot succeed at PostApplications.
  no op: Operation |
    op.oKind = PostApplications and
    op.oResult = Succeeded and
    op.oCallerRole = ROfficer and
    RApplicant not in op.oCaller.uRoles
}
assert FR_004_OfficerCannotPost { FR_004_OfficerCannotPost }
check FR_004_OfficerCannotPost for 6

// ── FR-005: Auditor cannot POST or PATCH ──────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005; contracts/http-api.md permission table; spec.md US3
pred FR_005_AuditorReadOnly {
  some User and some Operation
  no op: Operation |
    op.oResult = Succeeded and
    op.oCallerRole = RAuditor and
    op.oKind in (PostApplications + PatchApplicationStatus)
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 6

// ── FR-008: One in-flight application per applicant ────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md UNIQUE INDEX idx_one_in_flight_per_applicant
pred FR_008_OneInFlight {
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.lApplicant = a2.lApplicant implies
      not (a1.lStatus in (Pending + UnderReview) and
           a2.lStatus in (Pending + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// ── FR-009: Only allowed status transitions are represented in the audit log ────
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md ApplicationStatus transitions
pred FR_009_ValidTransitions {
  some AuditEntry
  all e: AuditEntry | {
    (no e.ePrev) implies e.eNew = Pending
    (some e.ePrev) implies (
      (e.ePrev = Pending     and e.eNew = UnderReview) or
      (e.ePrev = UnderReview and e.eNew = Approved)    or
      (e.ePrev = UnderReview and e.eNew = Rejected)
    )
  }
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 6

// ── FR-011: No self-assignment ─────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md CHECK assigned_officer_id != applicant_id
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all a: LoanApplication | some a.lOfficer implies a.lOfficer != a.lApplicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// ── FR-012: Only assigned officer can PATCH status ─────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md SC-005; data-model.md conditional UPDATE
pred FR_012_OnlyAssignedOfficerCanPatch {
  some op: Operation | op.oKind = PatchApplicationStatus and op.oResult = Succeeded
  all op: Operation |
    (op.oKind = PatchApplicationStatus and op.oResult = Succeeded) implies
      (some op.oApp and op.oCaller = op.oApp.lOfficer)
}
assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 6

// ── FR-013: No self-approval ───────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md SC-006; contracts/http-api.md self_decision_forbidden
pred FR_013_NoSelfApproval {
  some AuditEntry
  // No officer-role audit entry on a transition is authored by the application's applicant.
  all e: AuditEntry |
    (some e.ePrev and e.eActorRole = ROfficer) implies
      e.eActor != e.eApp.lApplicant
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 6

// ── FR-015: Terminal states are immutable ──────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015; spec.md "already_decided"; contracts/http-api.md 409
pred FR_015_TerminalStateFinal {
  some AuditEntry
  no e: AuditEntry | e.ePrev = Approved or e.ePrev = Rejected
}
assert FR_015_TerminalStateFinal { FR_015_TerminalStateFinal }
check FR_015_TerminalStateFinal for 6

// ── FR-016: Audit entries have valid actor-role attribution ────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md AuditEntry schema; spec.md SC-003
pred FR_016_AuditAttribution {
  some AuditEntry
  all e: AuditEntry |
    e.eActorRole != RSystem implies e.eActorRole in e.eActor.uRoles
}
assert FR_016_AuditAttribution { FR_016_AuditAttribution }
check FR_016_AuditAttribution for 6

// ── FR-018: Audit log entries are structurally immutable (append-only) ─────────
// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on audit_entries"; spec.md SC-009
pred FR_018_AuditImmutable {
  some AuditEntry
  // Uniqueness of (app, prev, new) tuples within one application is the
  // Alloy-expressible proxy for "no entry was overwritten."
  all disj e1, e2: AuditEntry |
    e1.eApp = e2.eApp implies
      not (e1.ePrev = e2.ePrev and e1.eNew = e2.eNew)
}
assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 6

// ── FR-020 / FR-021: Byte-equivalent unauthorised response ────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-020,FR-021; contracts/http-api.md "byte-equivalent not-found response"; spec.md SC-004
pred FR_020_ByteEquivalentUnauthorized {
  some op: Operation | op.oKind = GetApplicationById and op.oResult = Failed
  // A failed GET carries no application reference — indistinguishable from
  // a request for a non-existent id.
  all op: Operation |
    (op.oKind = GetApplicationById and op.oResult = Failed) implies no op.oApp
}
assert FR_020_ByteEquivalentUnauthorized { FR_020_ByteEquivalentUnauthorized }
check FR_020_ByteEquivalentUnauthorized for 6

// ── FR-023: Audit endpoint is auditor-only ─────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-023; contracts/http-api.md GET /applications/{id}/audit authorisation; spec.md US3
pred FR_023_AuditEndpointAuditorOnly {
  some op: Operation | op.oKind = GetApplicationAudit
  all op: Operation |
    (op.oKind = GetApplicationAudit and op.oResult = Succeeded) implies
      op.oCallerRole = RAuditor
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 6

// ── FR-024: Applicant cannot modify application after submission ───────────────
// FEATURE-SPECIFIC  ANCHOR: FR-024; spec.md "applicant cannot modify any of its fields"; contracts/http-api.md
pred FR_024_ApplicantNoPostSubmissionMutation {
  some AuditEntry
  // Non-initial audit entries (state transitions) must not be authored by applicants.
  all e: AuditEntry |
    (some e.ePrev) implies e.eActorRole != RApplicant
}
assert FR_024_ApplicantNoPostSubmissionMutation { FR_024_ApplicantNoPostSubmissionMutation }
check FR_024_ApplicantNoPostSubmissionMutation for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditEndpointViolation { some op: Operation | op.oKind = GetApplicationAudit and op.oResult = Succeeded and op.oCallerRole = ROfficer }
