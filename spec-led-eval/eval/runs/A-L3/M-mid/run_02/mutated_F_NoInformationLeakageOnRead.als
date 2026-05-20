// === feature_model.als — Alloy model for FCA-Regulated Loan Application ===
// Feature folder : A-L3  (branch 005-fca-loan-applications)
// Sources        : spec.md, data-model.md, contracts/http-api.md

// ──────────────────────────────────────────────────────────────────────────────
// ROLE LABELS
// ──────────────────────────────────────────────────────────────────────────────

abstract sig RoleLabel {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends RoleLabel {}

// ──────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ──────────────────────────────────────────────────────────────────────────────

abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ──────────────────────────────────────────────────────────────────────────────
// USERS  (dynamic)
// SystemUser is the singleton actor for system-initiated audit entries (FR-011).
// ──────────────────────────────────────────────────────────────────────────────

sig User {
  roleSet : set RoleLabel
}

one sig SystemUser extends User {}

// ──────────────────────────────────────────────────────────────────────────────
// LOAN APPLICATIONS  (dynamic)
// ──────────────────────────────────────────────────────────────────────────────

sig LoanApplication {
  applicant        : one User,
  status           : one AppStatus,
  assignedOfficer  : lone User      // lone: NULL in "no eligible officer" case (FR-011)
}

// ──────────────────────────────────────────────────────────────────────────────
// AUDIT ENTRIES  (dynamic, append-only)
// ──────────────────────────────────────────────────────────────────────────────

sig AuditEntry {
  forApp     : one LoanApplication,
  actorUser  : one User,
  actorRole  : one RoleLabel,
  prevStat   : lone AppStatus,      // lone: NULL only for the initial submission entry
  newStat    : one AppStatus
}

// ──────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS & PERMISSION MATRIX
// ──────────────────────────────────────────────────────────────────────────────

abstract sig OperationKind {}
one sig OpPost, OpGet, OpPatch, OpGetAudit extends OperationKind {}

// Permission matrix as a singleton-sig field (canonical pattern from prompt).
// Structural (role-level) allowed set; ownership-conditional checks live in
// separate facts/predicates below.
one sig PermMatrix {
  Allowed : set RoleLabel -> OperationKind
}

// ──────────────────────────────────────────────────────────────────────────────
// OPERATIONS  (dynamic — models API call instances)
// ──────────────────────────────────────────────────────────────────────────────

sig Operation {
  kind        : one OperationKind,
  callerUser  : one User,
  callerRole  : one RoleLabel,
  outcome     : one OpOutcome,
  targetApp   : lone LoanApplication   // lone: POST has no pre-existing target
}

abstract sig OpOutcome {}
one sig OpSuccess, OpDenied extends OpOutcome {}

// ──────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse  — ensures no vacuous truth under for-5 scope
// ──────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ──────────────────────────────────────────────────────────────────────────────
// F_SystemUserRoleSet — SystemUser holds only the System role label
// ──────────────────────────────────────────────────────────────────────────────

fact F_SystemUserRoleSet {
  SystemUser.roleSet = RSystem
}

// ──────────────────────────────────────────────────────────────────────────────
// F_RoleMultiplicity — FR-002: officer and auditor are mutually exclusive;
// applicant may combine with either; system never appears on a human user.
// data-model.md users.roles CHECK constraint.
// ──────────────────────────────────────────────────────────────────────────────

fact F_RoleMultiplicity {
  all u : User - SystemUser |
    // not both officer and auditor
    not (ROfficer in u.roleSet and RAuditor in u.roleSet)
    // must hold at least one human role
    and (RApplicant in u.roleSet or ROfficer in u.roleSet or RAuditor in u.roleSet)
    // system role never assigned to a human user
    and RSystem not in u.roleSet
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AssignedOfficerIsOfficer — if an assigned officer is set, they hold ROfficer
// data-model.md: "assigned_officer_id must reference a user whose role set
// includes officer (enforced at insert time in service.py)"
// ──────────────────────────────────────────────────────────────────────────────

fact F_AssignedOfficerIsOfficer {
  all app : LoanApplication |
    some app.assignedOfficer implies ROfficer in app.assignedOfficer.roleSet
}

// ──────────────────────────────────────────────────────────────────────────────
// F_ApplicantIsApplicant — the applicant of every application holds RApplicant
// data-model.md: "applicant_id must reference a user whose role set includes applicant"
// ──────────────────────────────────────────────────────────────────────────────

fact F_ApplicantIsApplicant {
  all app : LoanApplication | RApplicant in app.applicant.roleSet
}

// ──────────────────────────────────────────────────────────────────────────────
// F_NoSelfAssignment — assigned officer must differ from the applicant (FR-011)
// data-model.md: CHECK (assigned_officer_id IS NULL OR assigned_officer_id != applicant_id)
// ──────────────────────────────────────────────────────────────────────────────

fact F_NoSelfAssignment {
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}

// ──────────────────────────────────────────────────────────────────────────────
// F_StateMachine — FR-009: the only valid status values are the four defined
// and transitions follow the documented state machine.
// The current status of an application is consistent with its audit history:
//   Pending      → exactly 1 audit entry (none→pending)
//   UnderReview  → exactly 2 audit entries
//   Approved     → exactly 3 audit entries
//   Rejected     → exactly 3 audit entries
// ──────────────────────────────────────────────────────────────────────────────

fact F_StateMachine {
  // The initial audit entry for every application: prevStat=none, newStat=Pending
  all app : LoanApplication |
    one ae : AuditEntry | ae.forApp = app and no ae.prevStat and ae.newStat = Pending

  // An application at UnderReview must have a Pending→UnderReview entry
  all app : LoanApplication |
    app.status = UnderReview implies
      (one ae : AuditEntry | ae.forApp = app and ae.prevStat = Pending and ae.newStat = UnderReview)

  // An application at Approved must have an UnderReview→Approved entry
  all app : LoanApplication |
    app.status = Approved implies
      (one ae : AuditEntry | ae.forApp = app and ae.prevStat = UnderReview and ae.newStat = Approved)

  // An application at Rejected must have an UnderReview→Rejected entry
  all app : LoanApplication |
    app.status = Rejected implies
      (one ae : AuditEntry | ae.forApp = app and ae.prevStat = UnderReview and ae.newStat = Rejected)

  // No audit entry for a transition that is not in the allowed set
  all ae : AuditEntry |
    (no ae.prevStat and ae.newStat = Pending)
    or (ae.prevStat = Pending and ae.newStat = UnderReview)
    or (ae.prevStat = UnderReview and ae.newStat = Approved)
    or (ae.prevStat = UnderReview and ae.newStat = Rejected)

  // No no-op transitions (previous_status != new_status; FR-009 + data-model CHECK)
  all ae : AuditEntry | some ae.prevStat implies ae.prevStat != ae.newStat
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AuditCountMatchesStatus — FR-016/FR-017: the exact count of audit entries
// per application must equal the number of transitions that have occurred,
// which is determined by the application's current status.
// ──────────────────────────────────────────────────────────────────────────────

fact F_AuditCountMatchesStatus {
  all app : LoanApplication | {
    app.status = Pending     implies (#{ ae : AuditEntry | ae.forApp = app } = 1)
    app.status = UnderReview implies (#{ ae : AuditEntry | ae.forApp = app } = 2)
    app.status = Approved    implies (#{ ae : AuditEntry | ae.forApp = app } = 3)
    app.status = Rejected    implies (#{ ae : AuditEntry | ae.forApp = app } = 3)
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AppendOnlyAuditEntries — FR-018/FR-019: no UPDATE or DELETE on audit_entries.
// In the static model: each (forApp × prevStat × newStat) pair appears at most
// once, which captures "no mutation creates a duplicate / replaces an entry".
// ──────────────────────────────────────────────────────────────────────────────

fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2 : AuditEntry |
    not (ae1.forApp = ae2.forApp
         and ae1.prevStat = ae2.prevStat
         and ae1.newStat = ae2.newStat)
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AuditAttribution — FR-016: actorRole in each audit entry matches the
// actual role set of the actor, and only valid actor roles appear.
// data-model.md: actor_role CHECK IN ('applicant','officer','auditor','system')
// ──────────────────────────────────────────────────────────────────────────────

fact F_AuditAttribution {
  all ae : AuditEntry | {
    // actor role must be a member of the actor's actual role set
    ae.actorRole in ae.actorUser.roleSet
    // only the four valid actor roles appear
    ae.actorRole in (RApplicant + ROfficer + RAuditor + RSystem)
    // system role is used only by the SystemUser
    ae.actorRole = RSystem implies ae.actorUser = SystemUser
    // initial submission by a human is attributed to the applicant role
    (no ae.prevStat and ae.actorUser != SystemUser) implies
      ae.actorRole = RApplicant
    // officer transitions attributed to officer role
    (some ae.prevStat) implies ae.actorRole = ROfficer
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// F_OneInFlightPerApplicant — FR-008: an applicant may have at most one
// application in status Pending or UnderReview at any time.
// data-model.md: idx_one_in_flight_per_applicant UNIQUE partial index.
// ──────────────────────────────────────────────────────────────────────────────

fact F_OneInFlightPerApplicant {
  all disj a1, a2 : LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}

// ──────────────────────────────────────────────────────────────────────────────
// F_NoSelfApproval — FR-013: an officer cannot act as deciding officer on an
// application where they are also the applicant.
// Every officer-attributed audit entry (prevStat != none) must have
// actorUser != app.applicant.
// data-model.md: CHECK applicant_id != ? in conditional UPDATE.
// ──────────────────────────────────────────────────────────────────────────────

fact F_NoSelfApproval {
  all ae : AuditEntry |
    (some ae.prevStat and ae.actorRole = ROfficer) implies
      ae.actorUser != ae.forApp.applicant
}

// ──────────────────────────────────────────────────────────────────────────────
// F_OnlyAssignedOfficerCanTransition — FR-012: only the assigned officer may
// produce a non-initial audit entry on an application.
// ──────────────────────────────────────────────────────────────────────────────

fact F_OnlyAssignedOfficerCanTransition {
  all ae : AuditEntry |
    (some ae.prevStat and ae.actorRole = ROfficer) implies
      ae.actorUser = ae.forApp.assignedOfficer
}

// ──────────────────────────────────────────────────────────────────────────────
// F_TerminalStatusImmutable — FR-015: once an application reaches
// Approved or Rejected, no further status changes are permitted.
// Encoded as: no audit entry has prevStat = Approved or prevStat = Rejected.
// ──────────────────────────────────────────────────────────────────────────────

fact F_TerminalStatusImmutable {
  all ae : AuditEntry |
    ae.prevStat not in (Approved + Rejected)
}

// ──────────────────────────────────────────────────────────────────────────────
// F_PermissionMatrix — contracts/http-api.md permission table (structural,
// role-level, ownership-independent cells).
// Allowed cells per spec:
//   RApplicant  → OpPost         (FR-003)
//   RApplicant  → OpGet          (FR-003, ownership-conditional; structural allow)
//   ROfficer    → OpGet          (FR-004, assignment-conditional; structural allow)
//   ROfficer    → OpPatch        (FR-004, assignment-conditional; structural allow)
//   RAuditor    → OpGet          (FR-005)
//   RAuditor    → OpGetAudit     (FR-005, FR-023)
// All other (Role × Operation) cells are denied.
// ──────────────────────────────────────────────────────────────────────────────

fact F_PermissionMatrix {
  PermMatrix.Allowed = (RApplicant -> OpPost)
                     + (RApplicant -> OpGet)
                     + (ROfficer   -> OpGet)
                     + (ROfficer   -> OpPatch)
                     + (RAuditor   -> OpGet)
                     + (RAuditor   -> OpGetAudit)
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AuthRequired — FR-001: every Operation has a callerRole that is a member
// of the callerUser's actual roleSet, and that role is never RSystem
// (system is never an API caller).
// Operations by unauthenticated callers (no valid token) are not represented
// in the model: they never reach business logic.
// ──────────────────────────────────────────────────────────────────────────────

fact F_AuthRequired {
  all op : Operation | {
    op.callerRole in op.callerUser.roleSet
    op.callerRole != RSystem
    op.callerUser != SystemUser
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// F_LeastPrivilege — operations succeed only when the caller's role is
// permitted for that operation kind in the permission matrix.
// ──────────────────────────────────────────────────────────────────────────────

fact F_LeastPrivilege {
  all op : Operation |
    op.outcome = OpSuccess implies
      (op.callerRole -> op.kind) in PermMatrix.Allowed
}

// ──────────────────────────────────────────────────────────────────────────────
// F_OwnershipBasedAccess — FR-003/FR-004: ownership-conditional read access.
// A GET succeeds only when the caller is: the app's applicant, its assigned
// officer, or an auditor.
// ──────────────────────────────────────────────────────────────────────────────

fact F_OwnershipBasedAccess {
  all op : Operation |
    (op.kind = OpGet and op.outcome = OpSuccess) implies (
      some op.targetApp and (
        op.callerUser = op.targetApp.applicant
        or op.callerUser = op.targetApp.assignedOfficer
        or op.callerRole = RAuditor
      )
    )
}

// ──────────────────────────────────────────────────────────────────────────────
// F_PatchOwnershipAndNonSelf — FR-012/FR-013: a PATCH succeeds only when the
// caller is the assigned officer AND is not the application's applicant.
// ──────────────────────────────────────────────────────────────────────────────

fact F_PatchOwnershipAndNonSelf {
  all op : Operation |
    (op.kind = OpPatch and op.outcome = OpSuccess) implies (
      some op.targetApp
      and op.callerUser = op.targetApp.assignedOfficer
      and op.callerUser != op.targetApp.applicant
    )
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AuditEndpointAuditorOnly — FR-023: GetAudit succeeds only for auditors.
// Any non-auditor GET-audit gets the byte-equivalent not-found response
// (modelled as OpDenied).
// ──────────────────────────────────────────────────────────────────────────────

fact F_AuditEndpointAuditorOnly {
  all op : Operation |
    (op.kind = OpGetAudit and op.outcome = OpSuccess) implies op.callerRole = RAuditor
}

// ──────────────────────────────────────────────────────────────────────────────
// F_AuditorReadOnly — FR-005: an auditor-role operation never successfully
// writes (POST or PATCH).
// ──────────────────────────────────────────────────────────────────────────────

fact F_AuditorReadOnly {
  all op : Operation |
    op.callerRole = RAuditor implies op.kind not in (OpPost + OpPatch)
}

// ──────────────────────────────────────────────────────────────────────────────
// F_OfficerCannotPost — FR-004: an officer-only caller (not also applicant)
// cannot POST a new application.  Encoded structurally: an OpPost success
// requires the caller to hold RApplicant.
// ──────────────────────────────────────────────────────────────────────────────

fact F_OfficerCannotPost {
  all op : Operation |
    (op.kind = OpPost and op.outcome = OpSuccess) implies RApplicant in op.callerUser.roleSet
}

// ──────────────────────────────────────────────────────────────────────────────
// F_NoLeakageThroughPost — FR-022: the POST response for a duplicate-detection
// error exposes only the requesting applicant's own in-flight application id,
// never another applicant's.  Modelled as: any OpPost denial that involves
// an in-flight-conflict does not allow the callerUser to learn about
// applications belonging to other applicants.
// In structural terms: every successful OpPost is associated with the
// caller's own application (applicant = callerUser).
// ──────────────────────────────────────────────────────────────────────────────

fact F_NoLeakageThroughPost {
  all op : Operation |
    (op.kind = OpPost and op.outcome = OpSuccess) implies
      (some op.targetApp and op.targetApp.applicant = op.callerUser)
}

// ──────────────────────────────────────────────────────────────────────────────
// F_NoInformationLeakageOnRead — FR-020/FR-021: for any caller without
// legitimate access, the outcome for GET is identical whether the application
// exists or not.  Modelled as: OpDenied outcomes on OpGet and OpGetAudit
// are indistinguishable (same OpDenied outcome) regardless of whether the
// targetApp exists.  The structural invariant: no GET denial carries a
// non-null targetApp that the caller legitimately cannot see (i.e. the
// system never attaches extra information to the denied response).
// ──────────────────────────────────────────────────────────────────────────────

fact F_NoInformationLeakageOnRead { /* MUTATED — body cleared by validator */ }

// ──────────────────────────────────────────────────────────────────────────────
// F_ValidationBeforeMutation — FR-017: a failed (denied) operation produces
// no audit entry.  Structurally: every AuditEntry corresponds to a successful
// operation, i.e. for each AuditEntry there exists an OpSuccess operation
// whose targetApp is the same application.
// ──────────────────────────────────────────────────────────────────────────────

fact F_ValidationBeforeMutation {
  all ae : AuditEntry |
    some op : Operation |
      op.outcome = OpSuccess and op.targetApp = ae.forApp
}

// ══════════════════════════════════════════════════════════════════════════════
// PATTERN PREDICATES AND ASSERTIONS
// ══════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003, FR-004, FR-005
pred LeastPrivilege {
  some op : Operation |
    op.outcome = OpSuccess  // universe is non-trivial
  all op : Operation |
    op.outcome = OpSuccess implies (op.callerRole -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (RoleLabel × OperationKind) cell is either allowed or denied —
  // the Allowed relation defines exactly the allowed set; anything outside is denied.
  // Completeness: the Allowed set is exactly the six cells from the matrix.
  PermMatrix.Allowed =
    (RApplicant -> OpPost)
    + (RApplicant -> OpGet)
    + (ROfficer   -> OpGet)
    + (ROfficer   -> OpPatch)
    + (RAuditor   -> OpGet)
    + (RAuditor   -> OpGetAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  some op : Operation | op.outcome = OpSuccess
  // No operation belongs to SystemUser (system never calls the API)
  all op : Operation | op.callerUser != SystemUser
  // Every caller's role is drawn from their actual role set
  all op : Operation | op.callerRole in op.callerUser.roleSet
  // System role never appears as a caller role
  all op : Operation | op.callerRole != RSystem
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017; data-model.md AuditEntry
pred AuditCompleteness {
  some LoanApplication
  // Every application at Pending has exactly one audit entry
  all app : LoanApplication |
    app.status = Pending implies (#{ ae : AuditEntry | ae.forApp = app } = 1)
  // Every application at UnderReview has exactly two audit entries
  all app : LoanApplication |
    app.status = UnderReview implies (#{ ae : AuditEntry | ae.forApp = app } = 2)
  // Every application at Approved or Rejected has exactly three
  all app : LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (#{ ae : AuditEntry | ae.forApp = app } = 3)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, FR-019; data-model.md "no UPDATE/DELETE" notes
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries for the same application share the same
  // (prevStat, newStat) pair — mutation would produce an indistinguishable duplicate.
  all disj ae1, ae2 : AuditEntry |
    ae1.forApp = ae2.forApp implies
      not (ae1.prevStat = ae2.prevStat and ae1.newStat = ae2.newStat)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some AuditEntry
  all ae : AuditEntry | {
    // Actor role must be from the actor's actual role set
    ae.actorRole in ae.actorUser.roleSet
    // System role appears only on the SystemUser
    ae.actorRole = RSystem iff ae.actorUser = SystemUser
    // Initial entries by humans are attributed to applicant role
    (no ae.prevStat and ae.actorUser != SystemUser) implies ae.actorRole = RApplicant
    // Officer-transition entries are attributed to officer role
    some ae.prevStat implies ae.actorRole = ROfficer
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id (NOT NULL)
pred OwnershipExclusivity {
  some LoanApplication
  // Each application has exactly one applicant (encoded by `one` multiplicity,
  // asserted here dynamically to ensure it holds in all populated worlds)
  all app : LoanApplication | one app.applicant
  // No two applications share the same applicant-at-in-flight-status (FR-008)
  all disj a1, a2 : LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-012; contracts/http-api.md access table
pred OwnershipBasedAccess {
  some op : Operation | op.kind = OpPatch and op.outcome = OpSuccess
  // A successful PATCH requires the caller to be the assigned officer and
  // not the application's own applicant
  all op : Operation |
    (op.kind = OpPatch and op.outcome = OpSuccess) implies (
      some op.targetApp
      and op.callerUser = op.targetApp.assignedOfficer
      and op.callerUser != op.targetApp.applicant
    )
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022, FR-023; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some op : Operation | op.kind = OpGet and op.outcome = OpDenied
  // A denied GET or GetAudit response carries no application reference
  // (byte-equivalent: the response does not distinguish exist-but-no-access
  //  from does-not-exist)
  all op : Operation |
    (op.kind in (OpGet + OpGetAudit) and op.outcome = OpDenied) implies no op.targetApp
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013, FR-011; data-model.md CHECK assigned_officer_id != applicant_id
pred NoSelfMutation {
  some LoanApplication
  // No application is self-assigned (FR-011)
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
  // No officer-attributed audit entry has the officer as the application's applicant (FR-013)
  all ae : AuditEntry |
    (some ae.prevStat and ae.actorRole = ROfficer) implies
      ae.actorUser != ae.forApp.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-017; data-model.md atomicity contract
pred ValidationBeforeMutation {
  some AuditEntry
  // Every audit entry is backed by a successful operation on the same application
  all ae : AuditEntry |
    some op : Operation | op.outcome = OpSuccess and op.targetApp = ae.forApp
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ══════════════════════════════════════════════════════════════════════════════
// FEATURE-SPECIFIC PREDICATES
// ══════════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated requests rejected before business logic
pred FR_001_AuthRequired {
  // All operations have a valid caller with a role from their roleSet
  all op : Operation | op.callerRole in op.callerUser.roleSet
  // No system-user API caller
  all op : Operation | op.callerUser != SystemUser and op.callerRole != RSystem
  // At least one operation exists to prevent vacuity
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — officer and auditor mutually exclusive; system not on human users
pred FR_002_RoleMutualExclusivity {
  some u : User - SystemUser | ROfficer in u.roleSet or RAuditor in u.roleSet
  all u : User - SystemUser | not (ROfficer in u.roleSet and RAuditor in u.roleSet)
  all u : User - SystemUser | RSystem not in u.roleSet
}
assert FR_002_RoleMutualExclusivity { FR_002_RoleMutualExclusivity }
check FR_002_RoleMutualExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — applicant cannot PATCH status
pred FR_003_ApplicantCannotPatch {
  some op : Operation | op.callerRole = RApplicant
  all op : Operation |
    (op.callerRole = RApplicant and op.kind = OpPatch) implies op.outcome = OpDenied
}
assert FR_003_ApplicantCannotPatch { FR_003_ApplicantCannotPatch }
check FR_003_ApplicantCannotPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — auditor cannot POST or PATCH
pred FR_005_AuditorReadOnly {
  some op : Operation | op.callerRole = RAuditor
  all op : Operation |
    op.callerRole = RAuditor implies op.kind not in (OpPost + OpPatch)
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 — one in-flight application per applicant
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication
  all disj a1, a2 : LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview) and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — only allowed state-machine transitions exist in audit log
pred FR_009_ValidTransitions {
  some AuditEntry
  all ae : AuditEntry |
    (no ae.prevStat and ae.newStat = Pending)
    or (ae.prevStat = Pending    and ae.newStat = UnderReview)
    or (ae.prevStat = UnderReview and ae.newStat = Approved)
    or (ae.prevStat = UnderReview and ae.newStat = Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — no self-assignment; assigned officer != applicant
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all app : LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — only the assigned officer can change status
pred FR_012_OnlyAssignedOfficerCanPatch {
  some ae : AuditEntry | some ae.prevStat
  all ae : AuditEntry |
    (some ae.prevStat and ae.actorRole = ROfficer) implies
      ae.actorUser = ae.forApp.assignedOfficer
}
assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — no self-approval (officer cannot decide own application)
pred FR_013_NoSelfApproval {
  some ae : AuditEntry | some ae.prevStat and ae.actorRole = ROfficer
  all ae : AuditEntry |
    (some ae.prevStat and ae.actorRole = ROfficer) implies
      ae.actorUser != ae.forApp.applicant
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — terminal statuses (Approved/Rejected) cannot be transitioned further
pred FR_015_TerminalStatusImmutable {
  some AuditEntry
  all ae : AuditEntry | ae.prevStat not in (Approved + Rejected)
}
assert FR_015_TerminalStatusImmutable { FR_015_TerminalStatusImmutable }
check FR_015_TerminalStatusImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016/FR-017 — every state transition has exactly one audit entry
pred FR_016_AuditEntryPerTransition {
  some LoanApplication
  // Initial entry exists for every application
  all app : LoanApplication |
    one ae : AuditEntry | ae.forApp = app and no ae.prevStat and ae.newStat = Pending
  // Officer-transition entries exist for applications past Pending
  all app : LoanApplication |
    app.status != Pending implies
      (some ae : AuditEntry | ae.forApp = app and some ae.prevStat)
}
assert FR_016_AuditEntryPerTransition { FR_016_AuditEntryPerTransition }
check FR_016_AuditEntryPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — audit log is immutable; no duplicate (app×prevStat×newStat) triples
pred FR_018_AuditImmutable {
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    ae1.forApp = ae2.forApp implies
      not (ae1.prevStat = ae2.prevStat and ae1.newStat = ae2.newStat)
}
assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020/FR-021 — byte-equivalent unauthorised GET response
pred FR_020_ByteEquivalentUnauthorisedGet {
  some op : Operation | op.kind = OpGet and op.outcome = OpDenied
  // Denied GET carries no targetApp reference (no information leakage)
  all op : Operation |
    (op.kind = OpGet and op.outcome = OpDenied) implies no op.targetApp
}
assert FR_020_ByteEquivalentUnauthorisedGet { FR_020_ByteEquivalentUnauthorisedGet }
check FR_020_ByteEquivalentUnauthorisedGet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023 — GET /applications/{id}/audit is auditor-only
pred FR_023_AuditEndpointAuditorOnly {
  some op : Operation | op.kind = OpGetAudit
  all op : Operation |
    op.kind = OpGetAudit implies (
      op.outcome = OpSuccess iff op.callerRole = RAuditor
    )
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024 — applicant cannot modify application fields post-submission
pred FR_024_ApplicantCannotModifyAfterSubmission {
  some op : Operation | op.callerRole = RApplicant
  // Applicants may only POST (create) or GET (read own application)
  all op : Operation |
    op.callerRole = RApplicant implies op.kind in (OpPost + OpGet)
}
assert FR_024_ApplicantCannotModifyAfterSubmission { FR_024_ApplicantCannotModifyAfterSubmission }
check FR_024_ApplicantCannotModifyAfterSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-022 — POST response never leaks other applicants' data
pred FR_022_PostNoLeakage {
  some op : Operation | op.kind = OpPost and op.outcome = OpSuccess
  all op : Operation |
    (op.kind = OpPost and op.outcome = OpSuccess) implies
      (some op.targetApp and op.targetApp.applicant = op.callerUser)
}
assert FR_022_PostNoLeakage { FR_022_PostNoLeakage }
check FR_022_PostNoLeakage for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_InformationLeakageViolation { some op : Operation | op.kind = OpGet and op.outcome = OpDenied and some op.targetApp }
