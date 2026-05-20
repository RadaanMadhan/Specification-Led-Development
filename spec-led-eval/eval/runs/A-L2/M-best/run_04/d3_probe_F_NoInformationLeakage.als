// === feature_model.als — Alloy model for 004-loan-application-rbac (A-L2) ===
// Self-contained Alloy 6 model encoding the structural invariants of the
// loan-application feature: RBAC permission matrix, claim-then-decide
// workflow, append-only audit trail, and customer ownership boundaries.

// -----------------------------------------------------------------------------
// Dynamic universe: every sig the predicates quantify over must be non-empty
// so assertions are not vacuously satisfied by Alloy's empty-universe worlds.
// -----------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// -----------------------------------------------------------------------------
// Static enums (closed by one-sig partitions)
// -----------------------------------------------------------------------------
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, GetApplication,
        ClaimApplication, DecideApplication, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig Success, NotFoundOutcome, PermissionDeniedOutcome,
        ValidationFailedOutcome, ConflictOutcome extends Outcome {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// -----------------------------------------------------------------------------
// Domain sigs
// -----------------------------------------------------------------------------
sig User {
  role: one Role
}

sig Decision {
  decidedBy: one User,
  decisionType: one Status,
  hasReason: one Bool
}

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User,
  decision: lone Decision
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  prevStatus: lone Status,
  newStatus: one Status
}

sig Operation {
  kind: one OperationKind,
  caller: lone User,         // lone: unauthenticated callers have no resolved user
  target: lone LoanApplication,
  outcome: one Outcome,
  revealsOfficer: one Bool   // true iff response payload carries officer-identifier keys
}

// -----------------------------------------------------------------------------
// Permission matrix as a field on a singleton sig (Alloy 6 idiom)
// -----------------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// Closed-world encoding of contracts/http-api.md permission table.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer -> SubmitApplication) +
    (Customer -> ListApplications) +
    (Customer -> GetApplication) +
    (LoanOfficer -> ListApplications) +
    (LoanOfficer -> GetApplication) +
    (LoanOfficer -> ClaimApplication) +
    (LoanOfficer -> DecideApplication) +
    (LoanOfficer -> GetAudit) +
    (ComplianceReviewer -> ListApplications) +
    (ComplianceReviewer -> GetApplication) +
    (ComplianceReviewer -> GetAudit)
}

// -----------------------------------------------------------------------------
// Authorisation and authentication
// -----------------------------------------------------------------------------
fact F_OperationAuthorisation {
  all op: Operation |
    op.outcome = Success implies
      (some op.caller and (op.caller.role -> op.kind) in PermMatrix.Allowed)
}

fact F_AuthRequiredEverywhere {
  all op: Operation | op.outcome = Success implies some op.caller
}

// -----------------------------------------------------------------------------
// Role coherence: customer field is a customer; assigned officer is a loan
// officer; decisions are made by loan officers.
// -----------------------------------------------------------------------------
fact F_RoleConsistency {
  all app: LoanApplication {
    app.customer.role = Customer
    some app.assignedOfficer implies app.assignedOfficer.role = LoanOfficer
  }
  all d: Decision | d.decidedBy.role = LoanOfficer
}

// data-model.md CHECK: status='Submitted' iff assigned_officer_id IS NULL
fact F_StatusAssignmentCoupling {
  all app: LoanApplication | (app.status = Submitted) iff (no app.assignedOfficer)
}

// Decision exists iff application is decided.
fact F_DecisionStatusCoupling {
  all app: LoanApplication |
    (some app.decision) iff (app.status in (Approved + Rejected))
}

// Decider must be the assigned officer; decision_type tracks status.
fact F_DecisionConsistency {
  all app: LoanApplication |
    some app.decision implies
      (app.decision.decidedBy = app.assignedOfficer and
       app.decision.decisionType = app.status)
}

fact F_DecisionTypeRestricted {
  all d: Decision | d.decisionType in (Approved + Rejected)
}

// At most one decision per application (one-to-one).
fact F_DecisionUniquePerApp {
  all disj a1, a2: LoanApplication | no (a1.decision & a2.decision)
}

// FR-014: every decision carries a non-empty reason (modelled as Bool flag).
fact F_DecisionHasNonEmptyReason {
  all d: Decision | d.hasReason = BTrue
}

// FR-008: a customer cannot hold two in-flight applications simultaneously.
fact F_OneInFlightPerCustomer {
  all u: User |
    u.role = Customer implies
      (lone app: LoanApplication |
         app.customer = u and app.status in (Submitted + UnderReview))
}

// -----------------------------------------------------------------------------
// Audit trail facts (FR-017..FR-019, FR-018 append-only)
// -----------------------------------------------------------------------------

// FR-017 / FR-019: for every status the application has reached, the matching
// audit entry exists.
fact F_AuditMatchesStatus {
  all app: LoanApplication {
    (some ae: AuditEntry |
       ae.application = app and no ae.prevStatus and ae.newStatus = Submitted)
    (app.status in (UnderReview + Approved + Rejected)) iff
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
    (app.status = Approved) iff
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = Approved)
    (app.status = Rejected) iff
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = Rejected)
  }
}

// FR-018: append-only — no two distinct audit entries record the same
// (application, prevStatus, newStatus) transition.
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.prevStatus = ae2.prevStatus and
         ae1.newStatus = ae2.newStatus)
}

// Only the four legal transitions are ever recorded.
fact F_AuditLegalTransitionsOnly {
  all ae: AuditEntry {
    no ae.prevStatus implies ae.newStatus = Submitted
    ae.prevStatus = Submitted implies ae.newStatus = UnderReview
    ae.prevStatus = UnderReview implies ae.newStatus in (Approved + Rejected)
    ae.prevStatus not in (Approved + Rejected)
    some ae.prevStatus implies ae.prevStatus != ae.newStatus
  }
}

// Attribution: each audit entry's actor matches the documented actor for that
// transition (customer for initial submit; assigned officer for claim/decide).
fact F_AuditAttribution {
  all ae: AuditEntry {
    (no ae.prevStatus) implies ae.actor = ae.application.customer
    (ae.prevStatus = Submitted) implies ae.actor = ae.application.assignedOfficer
    (ae.prevStatus = UnderReview) implies ae.actor = ae.application.assignedOfficer
  }
}

// -----------------------------------------------------------------------------
// Resource ownership and access (FR-020, FR-021)
// -----------------------------------------------------------------------------

// FR-020: customer successful GetApplication implies customer owns the target.
fact F_OwnershipBasedCustomerAccess {
  all op: Operation |
    (op.outcome = Success and op.kind = GetApplication and
     some op.caller and op.caller.role = Customer and some op.target)
    implies op.target.customer = op.caller
}

// FR-020 ("no existence leak"): customer asking about another customer's
// application gets NotFound, not PermissionDenied. Byte-identical to the
// non-existent-reference case.
fact F_NoInformationLeakage {
  all op: Operation |
    (some op.caller and op.caller.role = Customer and op.kind = GetApplication and
     some op.target and op.target.customer != op.caller)
    implies op.outcome = NotFoundOutcome
}

// FR-021: officer identity never appears in a customer-bound response.
fact F_OfficerIdentityHiddenFromCustomer {
  all op: Operation |
    (some op.caller and op.caller.role = Customer)
    implies op.revealsOfficer = BFalse
}

// =============================================================================
// PATTERN-BASED ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002..FR-004
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table (every cell defined)
pred PermissionCompleteness {
  // Allows witnessed by FR-002, FR-003, FR-004
  (Customer -> SubmitApplication) in PermMatrix.Allowed
  (Customer -> GetApplication) in PermMatrix.Allowed
  (LoanOfficer -> ClaimApplication) in PermMatrix.Allowed
  (LoanOfficer -> DecideApplication) in PermMatrix.Allowed
  (LoanOfficer -> GetAudit) in PermMatrix.Allowed
  (ComplianceReviewer -> GetApplication) in PermMatrix.Allowed
  (ComplianceReviewer -> GetAudit) in PermMatrix.Allowed
  // Explicit denies (closed-world)
  (Customer -> ClaimApplication) not in PermMatrix.Allowed
  (Customer -> DecideApplication) not in PermMatrix.Allowed
  (Customer -> GetAudit) not in PermMatrix.Allowed
  (LoanOfficer -> SubmitApplication) not in PermMatrix.Allowed
  (ComplianceReviewer -> SubmitApplication) not in PermMatrix.Allowed
  (ComplianceReviewer -> ClaimApplication) not in PermMatrix.Allowed
  (ComplianceReviewer -> DecideApplication) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = Success implies some op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017,FR-019; data-model.md application_events
pred AuditCompleteness {
  all app: LoanApplication {
    (some ae: AuditEntry |
       ae.application = app and no ae.prevStatus and ae.newStatus = Submitted)
    (app.status in (UnderReview + Approved + Rejected)) implies
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
    (app.status = Approved) implies
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = Approved)
    (app.status = Rejected) implies
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = Rejected)
  }
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.prevStatus = ae2.prevStatus and
         ae1.newStatus = ae2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id semantics
pred AttributionCorrectness {
  all ae: AuditEntry {
    (no ae.prevStatus) implies ae.actor = ae.application.customer
    (ae.prevStatus = Submitted) implies ae.actor = ae.application.assignedOfficer
    (ae.prevStatus = UnderReview) implies ae.actor = ae.application.assignedOfficer
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id NOT NULL; spec.md "each application has one customer"
pred OwnershipExclusivity {
  all app: LoanApplication | one app.customer and app.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Success and op.kind = GetApplication and
     some op.caller and op.caller.role = Customer and some op.target)
    implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020 ("no existence leak"); contracts/http-api.md 404 rules
pred NoInformationLeakage {
  all op: Operation |
    (some op.caller and op.caller.role = Customer and op.kind = GetApplication and
     some op.target and op.target.customer != op.caller)
    implies op.outcome = NotFoundOutcome
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// =============================================================================
// FEATURE-SPECIFIC ASSERTIONS (one per FR)
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — every request resolves to an authenticated caller
pred FR_001_AuthRequired {
  all op: Operation | op.outcome = Success implies some op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-002 — customers limited to submit/list/get
pred FR_002_CustomerLimited {
  all op: Operation |
    (op.outcome = Success and some op.caller and op.caller.role = Customer)
    implies op.kind in (SubmitApplication + ListApplications + GetApplication)
}
assert FR_002_CustomerLimited { FR_002_CustomerLimited }
check FR_002_CustomerLimited for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-003 — loan officers limited to list/get/claim/decide/audit
pred FR_003_LoanOfficerPermissions {
  all op: Operation |
    (op.outcome = Success and some op.caller and op.caller.role = LoanOfficer)
    implies op.kind in (ListApplications + GetApplication + ClaimApplication
                        + DecideApplication + GetAudit)
}
assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-004 / FR-023 — compliance reviewer is read-only
pred FR_004_ComplianceReadOnly {
  all op: Operation |
    (op.outcome = Success and some op.caller and op.caller.role = ComplianceReviewer)
    implies op.kind in (ListApplications + GetApplication + GetAudit)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-005 — only customers can submit applications
pred FR_005_OnlyCustomersSubmit {
  all op: Operation |
    (op.outcome = Success and op.kind = SubmitApplication)
    implies (some op.caller and op.caller.role = Customer)
}
assert FR_005_OnlyCustomersSubmit { FR_005_OnlyCustomersSubmit }
check FR_005_OnlyCustomersSubmit for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-008 — at most one in-flight application per customer
pred FR_008_OneInFlight {
  all u: User |
    u.role = Customer implies
      (lone app: LoanApplication |
         app.customer = u and app.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-009 — initial submission recorded with customer as actor
pred FR_009_InitialSubmissionRecorded {
  all app: LoanApplication |
    (some ae: AuditEntry |
       ae.application = app and no ae.prevStatus and ae.newStatus = Submitted
       and ae.actor = app.customer)
}
assert FR_009_InitialSubmissionRecorded { FR_009_InitialSubmissionRecorded }
check FR_009_InitialSubmissionRecorded for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-011 — claim transition recorded with claiming officer
pred FR_011_ClaimTransitionRecorded {
  all app: LoanApplication |
    app.status in (UnderReview + Approved + Rejected) implies
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview
         and ae.actor = app.assignedOfficer and ae.actor.role = LoanOfficer)
}
assert FR_011_ClaimTransitionRecorded { FR_011_ClaimTransitionRecorded }
check FR_011_ClaimTransitionRecorded for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-012 — at most one assigned officer per application
pred FR_012_OneAssignedOfficer {
  all app: LoanApplication | lone app.assignedOfficer
}
assert FR_012_OneAssignedOfficer { FR_012_OneAssignedOfficer }
check FR_012_OneAssignedOfficer for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-013 — only the assigned officer decides
pred FR_013_OnlyAssignedDecides {
  all app: LoanApplication |
    some app.decision implies app.decision.decidedBy = app.assignedOfficer
}
assert FR_013_OnlyAssignedDecides { FR_013_OnlyAssignedDecides }
check FR_013_OnlyAssignedDecides for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-014 — every decision carries a non-empty reason
pred FR_014_DecisionHasReason {
  all d: Decision | d.hasReason = BTrue
}
assert FR_014_DecisionHasReason { FR_014_DecisionHasReason }
check FR_014_DecisionHasReason for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-015 — decision, status and audit are jointly atomic
pred FR_015_DecisionAtomic {
  all app: LoanApplication {
    (some app.decision) iff (app.status in (Approved + Rejected))
    some app.decision implies
      (one ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = app.status)
  }
}
assert FR_015_DecisionAtomic { FR_015_DecisionAtomic }
check FR_015_DecisionAtomic for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-016 — no transition out of Approved or Rejected
pred FR_016_ImmutableAfterDecision {
  all ae: AuditEntry | ae.prevStatus not in (Approved + Rejected)
}
assert FR_016_ImmutableAfterDecision { FR_016_ImmutableAfterDecision }
check FR_016_ImmutableAfterDecision for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-017 — every observed status change has an audit entry
pred FR_017_AuditPerStatusChange {
  all app: LoanApplication {
    (some ae: AuditEntry |
       ae.application = app and no ae.prevStatus and ae.newStatus = Submitted)
    (app.status in (UnderReview + Approved + Rejected)) implies
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
    (app.status in (Approved + Rejected)) implies
      (some ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = app.status)
  }
}
assert FR_017_AuditPerStatusChange { FR_017_AuditPerStatusChange }
check FR_017_AuditPerStatusChange for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-018 — audit trail is append-only
pred FR_018_AuditAppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.prevStatus = ae2.prevStatus and
         ae1.newStatus = ae2.newStatus)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-019 — exactly one audit entry per applied transition
pred FR_019_ExactlyOneAuditPerChange {
  all app: LoanApplication {
    (one ae: AuditEntry |
       ae.application = app and no ae.prevStatus and ae.newStatus = Submitted)
    (app.status in (UnderReview + Approved + Rejected)) implies
      (one ae: AuditEntry |
         ae.application = app and ae.prevStatus = Submitted and ae.newStatus = UnderReview)
    (app.status in (Approved + Rejected)) implies
      (one ae: AuditEntry |
         ae.application = app and ae.prevStatus = UnderReview and ae.newStatus = app.status)
  }
}
assert FR_019_ExactlyOneAuditPerChange { FR_019_ExactlyOneAuditPerChange }
check FR_019_ExactlyOneAuditPerChange for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-020 — customer reads only own applications
pred FR_020_CustomerOwnOnly {
  all op: Operation |
    (op.outcome = Success and op.kind = GetApplication and
     some op.caller and op.caller.role = Customer and some op.target)
    implies op.target.customer = op.caller
}
assert FR_020_CustomerOwnOnly { FR_020_CustomerOwnOnly }
check FR_020_CustomerOwnOnly for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-021 — officer identity never reaches customer responses
pred FR_021_OfficerIdentityHidden {
  all op: Operation |
    (some op.caller and op.caller.role = Customer)
    implies op.revealsOfficer = BFalse
}
assert FR_021_OfficerIdentityHidden { FR_021_OfficerIdentityHidden }
check FR_021_OfficerIdentityHidden for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// FEATURE-SPECIFIC  ANCHOR: FR-023 — compliance reviewer cannot perform any write
pred FR_023_ComplianceNoWrite {
  all op: Operation |
    (op.outcome = Success and some op.caller and op.caller.role = ComplianceReviewer)
    implies op.kind not in (SubmitApplication + ClaimApplication + DecideApplication)
}
assert FR_023_ComplianceNoWrite { FR_023_ComplianceNoWrite }
check FR_023_ComplianceNoWrite for 8 but exactly 3 Role, exactly 6 OperationKind, exactly 5 Outcome, exactly 4 Status, exactly 2 Bool

// === D3 inject_violation (validator-appended) ===
fact MUTATE_LeakageViolation { some op: Operation, c: User, app: LoanApplication | c.role = Customer and op.caller = c and op.kind = GetApplication and op.target = app and app.customer != c and op.outcome = PermissionDeniedOutcome }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
