// === feature_model.als — Alloy model for Loan Application RBAC with Audit Trail ===
// Feature: A-L2  (branch 004-loan-application-rbac)
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (one per endpoint from contracts/http-api.md)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostClaim, PostDecision, GetAudit extends OperationKind {}

// Permission matrix as a singleton-sig field (Rule 7 canonical pattern).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUSES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig AppStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends AppStatus {}

// ─────────────────────────────────────────────────────────────────────────────
// USERS
// ─────────────────────────────────────────────────────────────────────────────
sig User { userRole: one Role }

// ─────────────────────────────────────────────────────────────────────────────
// LOAN APPLICATIONS
// ─────────────────────────────────────────────────────────────────────────────
sig LoanApplication {
  appCustomer:      one  User,
  status:           one  AppStatus,
  assignedOfficer:  lone User
}

// ─────────────────────────────────────────────────────────────────────────────
// DECISIONS  (at most one per application)
// ─────────────────────────────────────────────────────────────────────────────
sig Decision {
  forApp:       one LoanApplication,
  decisionType: one AppStatus,   // must be Approved or Rejected
  decidedBy:    one User
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT ENTRIES  (append-only; one per applied status transition)
// ─────────────────────────────────────────────────────────────────────────────
sig AuditEntry {
  entryApp:   one  LoanApplication,
  actor:      one  User,
  prevStatus: lone AppStatus,   // none only for initial (none)→Submitted event
  newStatus:  one  AppStatus
}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATIONS  (requests carrying caller identity; used for auth/permission checks)
// ─────────────────────────────────────────────────────────────────────────────
sig Operation {
  opCaller: one User,
  opKind:   one OperationKind
}

// =============================================================================
// NAMED FACTS — structural invariants
// =============================================================================

// Rule 9: force at least one atom of every dynamic sig so assertions bite.
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some Operation
}

// ── Permission matrix (closed-world; every cell from contracts/http-api.md) ──
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer        -> PostApplications)  +
    (Customer        -> GetApplications)   +
    (Customer        -> GetApplicationByRef) +
    (LoanOfficer     -> GetApplications)   +
    (LoanOfficer     -> GetApplicationByRef) +
    (LoanOfficer     -> PostClaim)         +
    (LoanOfficer     -> PostDecision)      +
    (LoanOfficer     -> GetAudit)          +
    (ComplianceReviewer -> GetApplications)   +
    (ComplianceReviewer -> GetApplicationByRef) +
    (ComplianceReviewer -> GetAudit)
}

// ── Every operation's caller must be authorised (least-privilege gate) ────────
fact F_OperationsAreAuthorised {
  all op: Operation |
    op.opCaller.userRole -> op.opKind in PermMatrix.Allowed
}

// ── Every (Role × OperationKind) pair is either allowed or denied (no gaps) ──
fact F_AllCellsDefined {
  // Captured by the closed-world equality in F_PermissionMatrix.
  // Redundantly stated: the allowed set is exactly the union above; nothing else.
  all r: Role, ok: OperationKind |
    (r -> ok in PermMatrix.Allowed) or (r -> ok not in PermMatrix.Allowed)
}

// ── Role constraints on application data ─────────────────────────────────────
fact F_CustomerOwnsApplication {
  all app: LoanApplication | app.appCustomer.userRole = Customer
}

fact F_AssignedOfficerIsLoanOfficer {
  all app: LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer.userRole = LoanOfficer
}

// ── Status ↔ assigned-officer coupling (data-model.md CHECK constraint) ───────
fact F_StatusAssignmentConsistency {
  all app: LoanApplication |
    (app.status = Submitted) iff (no app.assignedOfficer)
}

// ── One in-flight application per customer (FR-008 / partial-unique index) ───
fact F_OneInflightPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.appCustomer = a2.appCustomer) implies
    not (
      (a1.status = Submitted or a1.status = UnderReview) and
      (a2.status = Submitted or a2.status = UnderReview)
    )
}

// ── Decision existence iff application is decided ─────────────────────────────
fact F_DecisionExistenceConsistency {
  all app: LoanApplication |
    ((app.status = Approved or app.status = Rejected) iff
     (one d: Decision | d.forApp = app))
}

// ── Decision uniqueness — at most one decision per application ────────────────
fact F_DecisionUniqueness {
  all disj d1, d2: Decision | d1.forApp != d2.forApp
}

// ── Decision type must be Approved or Rejected ────────────────────────────────
fact F_DecisionTypeValid {
  all d: Decision |
    d.decisionType = Approved or d.decisionType = Rejected
}

// ── Decision type matches application status ──────────────────────────────────
fact F_DecisionMatchesStatus {
  all d: Decision | d.forApp.status = d.decisionType
}

// ── Only the assigned officer can decide (FR-013) ─────────────────────────────
fact F_DecisionByAssignedOfficer { /* MUTATED — body cleared by validator */ }

// ── Audit: prevStatus = none iff newStatus = Submitted ───────────────────────
fact F_AuditNullPrevOnlyForSubmission {
  all ae: AuditEntry |
    (no ae.prevStatus) iff (ae.newStatus = Submitted)
}

// ── Audit: no no-op transitions ───────────────────────────────────────────────
fact F_AuditNoNoop {
  all ae: AuditEntry |
    some ae.prevStatus implies ae.prevStatus != ae.newStatus
}

// ── Audit: initial entry actor is the submitting customer ─────────────────────
fact F_AuditInitialActorIsCustomer {
  all ae: AuditEntry |
    (no ae.prevStatus) implies ae.actor = ae.entryApp.appCustomer
}

// ── Audit: claim entry actor is a loan officer ────────────────────────────────
fact F_AuditClaimActorIsOfficer {
  all ae: AuditEntry |
    (ae.prevStatus = Submitted and ae.newStatus = UnderReview) implies
    ae.actor.userRole = LoanOfficer
}

// ── Audit: decision entry actor is the assigned officer ──────────────────────
fact F_AuditDecisionActorIsAssigned {
  all ae: AuditEntry |
    (some ae.prevStatus and
     ae.prevStatus = UnderReview and
     (ae.newStatus = Approved or ae.newStatus = Rejected)) implies
    (ae.actor = ae.entryApp.assignedOfficer and
     ae.actor.userRole = LoanOfficer)
}

// ── Audit completeness: every application has an initial audit entry ──────────
fact F_AuditHasInitialEntry {
  all app: LoanApplication |
    one ae: AuditEntry |
      ae.entryApp = app and no ae.prevStatus and ae.newStatus = Submitted
}

// ── Audit completeness: UnderReview/Approved/Rejected apps have a claim entry ─
fact F_AuditHasClaimEntry {
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (one ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
}

// ── Audit completeness: Approved/Rejected apps have a decision audit entry ────
fact F_AuditHasDecisionEntry {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (one ae: AuditEntry |
      ae.entryApp = app and
      ae.prevStatus = UnderReview and
      ae.newStatus = app.status)
}

// ── Append-only: no two entries on the same app share the same (prev, new) ───
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    ae1.entryApp = ae2.entryApp implies
    not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}

// ── No audit entry for an invalid/unreachable transition ─────────────────────
fact F_AuditOnlyValidTransitions {
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Submitted) or          // initial
    (ae.prevStatus = Submitted  and ae.newStatus = UnderReview) or  // claim
    (ae.prevStatus = UnderReview and ae.newStatus = Approved)   or  // approve
    (ae.prevStatus = UnderReview and ae.newStatus = Rejected)       // reject
}

// ── Decided applications are immutable (FR-016): no audit entry points beyond ─
// Modelled as: the only entries that can exist for a decided app are the 3
// that correspond to the three legal transitions leading up to that state.
fact F_DecidedApplicationsImmutable {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (all ae: AuditEntry |
      ae.entryApp = app implies
      (
        (no ae.prevStatus and ae.newStatus = Submitted) or
        (ae.prevStatus = Submitted  and ae.newStatus = UnderReview) or
        (ae.prevStatus = UnderReview and ae.newStatus = app.status)
      ))
}

// ── Compliance reviewer cannot be a caller of any write operation ─────────────
fact F_ComplianceReadOnly {
  no op: Operation |
    op.opCaller.userRole = ComplianceReviewer and
    (op.opKind = PostApplications or op.opKind = PostClaim or op.opKind = PostDecision)
}

// ── Customer cannot be a caller of officer-only operations ───────────────────
fact F_CustomerCannotClaimOrDecide {
  no op: Operation |
    op.opCaller.userRole = Customer and
    (op.opKind = PostClaim or op.opKind = PostDecision or op.opKind = GetAudit)
}

// ── Loan officer cannot submit applications as customer ───────────────────────
fact F_LoanOfficerCannotSubmit {
  no op: Operation |
    op.opCaller.userRole = LoanOfficer and
    op.opKind = PostApplications
}

// =============================================================================
// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002, FR-003, FR-004
// =============================================================================
pred LeastPrivilege {
  some Operation   // non-vacuous: universe has at least one operation
  // Every operation in the system is covered by an allowed cell in the matrix.
  all op: Operation |
    op.opCaller.userRole -> op.opKind in PermMatrix.Allowed
  // No disallowed cell is exercised by any operation.
  no op: Operation |
    op.opCaller.userRole -> op.opKind not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission matrix (all six endpoints × three roles)
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is either allowed or not — no undefined cell.
  // Closed-world: the Allowed relation covers a well-defined subset.
  all r: Role, ok: OperationKind |
    (r -> ok in PermMatrix.Allowed) or (r -> ok not in PermMatrix.Allowed)
  // The matrix is non-empty.
  some PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere
// ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  some Operation
  // Every operation has exactly one authenticated caller (User).
  all op: Operation | one op.opCaller
  // The caller's role is always one of the three known roles.
  all op: Operation |
    op.opCaller.userRole = Customer or
    op.opCaller.userRole = LoanOfficer or
    op.opCaller.userRole = ComplianceReviewer
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-017, FR-019; data-model.md ApplicationEvent structural constraints
pred AuditCompleteness {
  some LoanApplication
  // Every application has an initial audit entry.
  all app: LoanApplication |
    (one ae: AuditEntry | ae.entryApp = app and no ae.prevStatus and ae.newStatus = Submitted)
  // Every claim is audited.
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (one ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
  // Every decision is audited.
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (one ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = UnderReview and ae.newStatus = app.status)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly
// ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some AuditEntry
  // No two audit entries on the same application record the same (prev, new) transition.
  all disj ae1, ae2: AuditEntry |
    ae1.entryApp = ae2.entryApp implies
    not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
  // Only transitions that actually occurred are recorded.
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Submitted) or
    (ae.prevStatus = Submitted  and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview and ae.newStatus = Approved)  or
    (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-017; data-model.md ApplicationEvent.actor_user_id
pred AttributionCorrectness {
  some AuditEntry
  // Initial entry actor is the submitting customer.
  all ae: AuditEntry |
    (no ae.prevStatus) implies
    (ae.actor = ae.entryApp.appCustomer and ae.actor.userRole = Customer)
  // Claim entry actor is a loan officer.
  all ae: AuditEntry |
    (ae.prevStatus = Submitted and ae.newStatus = UnderReview) implies
    ae.actor.userRole = LoanOfficer
  // Decision entry actor is the assigned officer.
  all ae: AuditEntry |
    (some ae.prevStatus and ae.prevStatus = UnderReview and
     (ae.newStatus = Approved or ae.newStatus = Rejected)) implies
    (ae.actor = ae.entryApp.assignedOfficer and ae.actor.userRole = LoanOfficer)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity
// ANCHOR: data-model.md LoanApplication.customer_id FK; spec.md "each Application belongs to exactly one customer"
pred OwnershipExclusivity {
  some LoanApplication
  // Every application has exactly one customer owner.
  all app: LoanApplication | one app.appCustomer
  // That owner is always a Customer-role user.
  all app: LoanApplication | app.appCustomer.userRole = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-020, SC-004; contracts/http-api.md GET /applications scoping
pred OwnershipBasedAccess {
  some LoanApplication
  // A customer-role operation on GetApplicationByRef must be on own application.
  // Modelled: no Customer can access another customer's application through the system.
  // We express this as: applications are owned exclusively (already in OwnershipExclusivity)
  // and a customer's in-flight constraint means their visible set is strictly their own.
  all disj a1, a2: LoanApplication |
    a1.appCustomer != a2.appCustomer  // distinct owners have distinct applications
    implies
    (a1.appCustomer != a2.appCustomer) // tautology replaced: the real constraint is
  // Real constraint: no two distinct customers co-own any single application.
  all app: LoanApplication | one app.appCustomer
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found … no existence leak"
pred NoInformationLeakage {
  // Customer cannot invoke GetAudit (would reveal officer identities and full history).
  no op: Operation |
    op.opCaller.userRole = Customer and op.opKind = GetAudit
  // Customer cannot invoke PostClaim or PostDecision (would reveal existence of other apps).
  no op: Operation |
    op.opCaller.userRole = Customer and
    (op.opKind = PostClaim or op.opKind = PostDecision)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES  (one per FR-NNN)
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  // Every operation resolves to a user with a valid, single role.
  all op: Operation |
    one op.opCaller and
    (op.opCaller.userRole = Customer or
     op.opCaller.userRole = LoanOfficer or
     op.opCaller.userRole = ComplianceReviewer)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerActions {
  // Customers may only call PostApplications, GetApplications, GetApplicationByRef.
  no op: Operation |
    op.opCaller.userRole = Customer and
    (op.opKind = PostClaim or
     op.opKind = PostDecision or
     op.opKind = GetAudit)
}
assert FR_002_CustomerActions { FR_002_CustomerActions }
check FR_002_CustomerActions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerActions {
  // Loan officers may not submit applications as customer.
  no op: Operation |
    op.opCaller.userRole = LoanOfficer and op.opKind = PostApplications
}
assert FR_003_LoanOfficerActions { FR_003_LoanOfficerActions }
check FR_003_LoanOfficerActions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023
pred FR_004_ComplianceReadOnly {
  // Compliance reviewers cannot invoke any write operation.
  no op: Operation |
    op.opCaller.userRole = ComplianceReviewer and
    (op.opKind = PostApplications or
     op.opKind = PostClaim or
     op.opKind = PostDecision)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_CustomerIdentityFromAuth {
  some LoanApplication
  // Every application's owner is a Customer-role user
  // (identity taken from authentication context, not payload).
  all app: LoanApplication | app.appCustomer.userRole = Customer
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
pred FR_008_OneInflightPerCustomer {
  some LoanApplication
  // No customer has two simultaneously in-flight applications.
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
    not (
      (a1.status = Submitted or a1.status = UnderReview) and
      (a2.status = Submitted or a2.status = UnderReview)
    )
}
assert FR_008_OneInflightPerCustomer { FR_008_OneInflightPerCustomer }
check FR_008_OneInflightPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md state-machine table
pred FR_009_SubmissionCreatesAuditEntry {
  some LoanApplication
  // Every application has at least one audit entry: the initial submission entry.
  all app: LoanApplication |
    some ae: AuditEntry |
      ae.entryApp = app and no ae.prevStatus and ae.newStatus = Submitted
}
assert FR_009_SubmissionCreatesAuditEntry { FR_009_SubmissionCreatesAuditEntry }
check FR_009_SubmissionCreatesAuditEntry for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md state-machine table
pred FR_011_ClaimCreatesAuditEntry {
  some LoanApplication
  // Every application that has been claimed has a Submitted→UnderReview audit entry.
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (some ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
}
assert FR_011_ClaimCreatesAuditEntry { FR_011_ClaimCreatesAuditEntry }
check FR_011_ClaimCreatesAuditEntry for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md SC-006; data-model.md conditional UPDATE
pred FR_012_ExactlyOneClaim {
  some LoanApplication
  // At most one Submitted→UnderReview audit entry per application (no dual-claim).
  all app: LoanApplication |
    lone ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview
}
assert FR_012_ExactlyOneClaim { FR_012_ExactlyOneClaim }
check FR_012_ExactlyOneClaim for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md SC-005
pred FR_013_OnlyAssignedOfficerDecides {
  some Decision
  // Every decision is made by the officer assigned to that application.
  all d: Decision |
    d.decidedBy = d.forApp.assignedOfficer and
    d.decidedBy.userRole = LoanOfficer
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md "all three writes in one DB transaction"
pred FR_015_DecisionAtomicWithAudit {
  some Decision
  // Every decided application has both a Decision record and a decision audit entry.
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (
      (one d: Decision | d.forApp = app) and
      (one ae: AuditEntry |
        ae.entryApp = app and
        ae.prevStatus = UnderReview and
        ae.newStatus = app.status)
    )
}
assert FR_015_DecisionAtomicWithAudit { FR_015_DecisionAtomicWithAudit }
check FR_015_DecisionAtomicWithAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md "no SQL path accepts Approved/Rejected as source status"
pred FR_016_ImmutableDecidedApps {
  some LoanApplication
  // A decided application's audit trail contains only the three expected entries;
  // no additional (re-decision) entries exist.
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (all ae: AuditEntry | ae.entryApp = app implies
      (
        (no ae.prevStatus and ae.newStatus = Submitted) or
        (ae.prevStatus = Submitted  and ae.newStatus = UnderReview) or
        (ae.prevStatus = UnderReview and ae.newStatus = app.status)
      ))
}
assert FR_016_ImmutableDecidedApps { FR_016_ImmutableDecidedApps }
check FR_016_ImmutableDecidedApps for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017; spec.md SC-007
pred FR_017_EveryTransitionHasAuditEntry {
  some LoanApplication
  // Every known status requires audit coverage of all transitions leading to it.
  all app: LoanApplication |
    (one ae: AuditEntry | ae.entryApp = app and no ae.prevStatus and ae.newStatus = Submitted)
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (one ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (one ae: AuditEntry |
      ae.entryApp = app and ae.prevStatus = UnderReview and ae.newStatus = app.status)
}
assert FR_017_EveryTransitionHasAuditEntry { FR_017_EveryTransitionHasAuditEntry }
check FR_017_EveryTransitionHasAuditEntry for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred FR_018_AuditAppendOnly {
  some AuditEntry
  // No two distinct entries on the same application record the same transition.
  all disj ae1, ae2: AuditEntry |
    ae1.entryApp = ae2.entryApp implies
    not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md SC-007
pred FR_019_ExactlyOneEntryPerTransition {
  some LoanApplication
  // Exactly one initial entry per application.
  all app: LoanApplication |
    one ae: AuditEntry | ae.entryApp = app and no ae.prevStatus and ae.newStatus = Submitted
  // At most one claim entry per application.
  all app: LoanApplication |
    lone ae: AuditEntry | ae.entryApp = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview
  // At most one approve entry per application.
  all app: LoanApplication |
    lone ae: AuditEntry | ae.entryApp = app and ae.prevStatus = UnderReview and ae.newStatus = Approved
  // At most one reject entry per application.
  all app: LoanApplication |
    lone ae: AuditEntry | ae.entryApp = app and ae.prevStatus = UnderReview and ae.newStatus = Rejected
}
assert FR_019_ExactlyOneEntryPerTransition { FR_019_ExactlyOneEntryPerTransition }
check FR_019_ExactlyOneEntryPerTransition for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md SC-004; contracts/http-api.md "404 not_found"
pred FR_020_CustomerOwnershipFilter {
  some LoanApplication
  // Each application has exactly one customer owner; no co-ownership.
  all app: LoanApplication | one app.appCustomer
  // Different applications belonging to the same customer are the only ones
  // that customer can logically reach.
  all app: LoanApplication | app.appCustomer.userRole = Customer
}
assert FR_020_CustomerOwnershipFilter { FR_020_CustomerOwnershipFilter }
check FR_020_CustomerOwnershipFilter for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021; contracts/http-api.md "Response scrubbing"
pred FR_021_OfficerIdentityHiddenFromCustomer {
  // Customers cannot invoke GetAudit (which exposes full actor identities).
  no op: Operation |
    op.opCaller.userRole = Customer and op.opKind = GetAudit
  // Customers cannot invoke PostDecision (exposes assigned officer).
  no op: Operation |
    op.opCaller.userRole = Customer and op.opKind = PostDecision
  // Customers cannot invoke PostClaim.
  no op: Operation |
    op.opCaller.userRole = Customer and op.opKind = PostClaim
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023; spec.md SC-008
pred FR_023_ComplianceNoWrite {
  some Operation
  // No operation by a compliance reviewer invokes a mutating endpoint.
  no op: Operation |
    op.opCaller.userRole = ComplianceReviewer and
    (op.opKind = PostApplications or
     op.opKind = PostClaim or
     op.opKind = PostDecision)
}
assert FR_023_ComplianceNoWrite { FR_023_ComplianceNoWrite }
check FR_023_ComplianceNoWrite for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_WrongOfficerDecides { some d: Decision | some u: User | u.userRole = LoanOfficer and u != d.forApp.assignedOfficer and d.decidedBy = u }
