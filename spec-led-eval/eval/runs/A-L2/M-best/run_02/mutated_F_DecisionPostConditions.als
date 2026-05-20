// === feature_model.als — Alloy model for Loan Application with Role-Based Workflow and Audit Trail ===
// Feature: 004-loan-application-rbac (A-L2)
// Encodes the permission matrix, application state machine, audit-trail completeness,
// ownership-based read access, and one-in-flight-per-customer invariants.

// -----------------------------------------------------------------------------
// Universe must be non-empty so quantified assertions actually bite.
// -----------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
  some Decision
}

// -----------------------------------------------------------------------------
// Roles, statuses, operation kinds
// -----------------------------------------------------------------------------
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig OperationKind {}
one sig SubmitApp, ListApps, GetApp, ClaimApp, DecideApp, GetAuditOp extends OperationKind {}

// -----------------------------------------------------------------------------
// Entities (mirroring data-model.md)
// -----------------------------------------------------------------------------
sig User {
  role: one Role
}

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User
}

sig Decision {
  application: one LoanApplication,
  decidedBy: one User
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  prevStatus: lone Status,
  newStatus: one Status
}

// An Operation atom represents a successfully authenticated request reaching
// the service. caller is the resolved (User, Role); kind is the endpoint;
// target is the application addressed (lone — POST /applications has no target
// before insert, GET /applications has no single target).
sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication
}

// -----------------------------------------------------------------------------
// Permission matrix as a singleton-sig field (per system-prompt rule 7).
// Reference cells with `Role -> OperationKind in PermMatrix.Allowed`.
// -----------------------------------------------------------------------------
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

fact F_PermissionMatrix {
  // Closed-world: exactly these cells are allowed. Matches contracts/http-api.md.
  PermMatrix.Allowed =
    (Customer -> SubmitApp) +
    (Customer -> ListApps) +
    (Customer -> GetApp) +
    (LoanOfficer -> ListApps) +
    (LoanOfficer -> GetApp) +
    (LoanOfficer -> ClaimApp) +
    (LoanOfficer -> DecideApp) +
    (LoanOfficer -> GetAuditOp) +
    (ComplianceReviewer -> ListApps) +
    (ComplianceReviewer -> GetApp) +
    (ComplianceReviewer -> GetAuditOp)
}

// -----------------------------------------------------------------------------
// Structural / domain facts
// -----------------------------------------------------------------------------

fact F_CustomerOwnsApp {
  // data-model.md: customer_id FK references a user whose role is `customer`
  all a: LoanApplication | a.customer.role = Customer
}

fact F_OfficerRole {
  // data-model.md: assigned_officer FK references a user with role `loan_officer`
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

fact F_StatusAssignmentCouple {
  // data-model.md CHECK ((status='Submitted') = (assigned_officer_id IS NULL))
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

fact F_DecisionExistence {
  // A Decision row exists iff the application has reached Approved or Rejected.
  all a: LoanApplication |
    (a.status in (Approved + Rejected)) iff (some d: Decision | d.application = a)
}

fact F_DecisionPostConditions { /* MUTATED — body cleared by validator */ }

fact F_LeastPrivilegeOperations {
  // FR-002/FR-003/FR-004: every reachable Operation's (role, kind) is in the matrix.
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}

fact F_OwnershipBasedAccess {
  // FR-020: customer-role callers can only target their own applications.
  all op: Operation |
    (op.caller.role = Customer and some op.target) implies op.target.customer = op.caller
}

fact F_OneInFlightPerCustomer {
  // FR-008: partial unique index over status IN ('Submitted','Under Review')
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
      not (a1.status in (Submitted + UnderReview) and a2.status in (Submitted + UnderReview))
}

fact F_AuditEntryWellFormed {
  // data-model.md CHECKs on application_events
  all e: AuditEntry |
    (no e.prevStatus iff e.newStatus = Submitted)
    and (some e.prevStatus implies e.prevStatus != e.newStatus)
}

fact F_AuditAppendOnlyNoDup {
  // FR-018: append-only ⇒ no two audit rows record the same applied transition.
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and e1.newStatus = e2.newStatus)
}

fact F_AuditCompleteness {
  // FR-017 + FR-019: exactly one audit entry per applied transition.
  all a: LoanApplication |
    (one e: AuditEntry | e.application = a and e.newStatus = Submitted)
    and (a.status in (UnderReview + Approved + Rejected) implies
         (one e: AuditEntry | e.application = a and e.newStatus = UnderReview))
    and (a.status not in (UnderReview + Approved + Rejected) implies
         (no e: AuditEntry | e.application = a and e.newStatus = UnderReview))
    and (a.status = Approved implies
         (one e: AuditEntry | e.application = a and e.newStatus = Approved))
    and (a.status != Approved implies
         (no e: AuditEntry | e.application = a and e.newStatus = Approved))
    and (a.status = Rejected implies
         (one e: AuditEntry | e.application = a and e.newStatus = Rejected))
    and (a.status != Rejected implies
         (no e: AuditEntry | e.application = a and e.newStatus = Rejected))
}

fact F_AuditActorAttribution {
  // FR-017: actor_user_id matches the principal who caused the transition.
  all e: AuditEntry |
    (e.newStatus = Submitted implies e.actor = e.application.customer)
    and (e.newStatus = UnderReview implies e.actor = e.application.assignedOfficer)
    and (e.newStatus in (Approved + Rejected) implies e.actor = e.application.assignedOfficer)
}

fact F_AuditTransitionLegality {
  // Only the four legal transitions are reachable (data-model.md state machine).
  all e: AuditEntry | some e.prevStatus implies
    ((e.prevStatus = Submitted and e.newStatus = UnderReview) or
     (e.prevStatus = UnderReview and e.newStatus = Approved) or
     (e.prevStatus = UnderReview and e.newStatus = Rejected))
}

// =============================================================================
// CATALOGUE PATTERNS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002, FR-003, FR-004
pred LeastPrivilege {
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role, OperationKind) cell is decided (closed-world) and matches the published matrix.
  PermMatrix.Allowed =
    (Customer -> SubmitApp) +
    (Customer -> ListApps) +
    (Customer -> GetApp) +
    (LoanOfficer -> ListApps) +
    (LoanOfficer -> GetApp) +
    (LoanOfficer -> ClaimApp) +
    (LoanOfficer -> DecideApp) +
    (LoanOfficer -> GetAuditOp) +
    (ComplianceReviewer -> ListApps) +
    (ComplianceReviewer -> GetApp) +
    (ComplianceReviewer -> GetAuditOp)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and e1.newStatus = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017/FR-019; data-model.md "one INSERT per UPDATE"
pred AuditCompleteness {
  all a: LoanApplication |
    (one e: AuditEntry | e.application = a and e.newStatus = Submitted)
    and (a.status in (UnderReview + Approved + Rejected) implies
         (one e: AuditEntry | e.application = a and e.newStatus = UnderReview))
    and (a.status = Approved implies
         (one e: AuditEntry | e.application = a and e.newStatus = Approved))
    and (a.status = Rejected implies
         (one e: AuditEntry | e.application = a and e.newStatus = Rejected))
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  all e: AuditEntry |
    (e.newStatus = Submitted implies e.actor = e.application.customer)
    and (e.newStatus = UnderReview implies e.actor = e.application.assignedOfficer)
    and (e.newStatus in (Approved + Rejected) implies e.actor = e.application.assignedOfficer)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id (NOT NULL, single FK)
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer and a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications customer scope
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and some op.target) implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authorization on every endpoint"
pred AuthRequiredEverywhere {
  // Every reachable Operation has a resolved principal whose role is in the allowed matrix
  // for the operation's kind (no operation reaches business logic without auth+role check).
  all op: Operation |
    one op.caller.role
    and op.caller.role -> op.kind in PermMatrix.Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// =============================================================================
// FR-ANCHORED ASSERTIONS
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authenticated caller + exactly one role on every request)
pred FR_001_AuthRequired {
  all op: Operation |
    op.caller.role in (Customer + LoanOfficer + ComplianceReviewer)
    and op.caller.role -> op.kind in PermMatrix.Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (customer scope: submit + view-own only)
pred FR_002_CustomerScope {
  all op: Operation | op.caller.role = Customer implies
    op.kind in (SubmitApp + ListApps + GetApp)
}
assert FR_002_CustomerScope { FR_002_CustomerScope }
check FR_002_CustomerScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (officer cannot submit applications as a customer)
pred FR_003_OfficerScope {
  all op: Operation | op.caller.role = LoanOfficer implies
    op.kind in (ListApps + GetApp + ClaimApp + DecideApp + GetAuditOp)
}
assert FR_003_OfficerScope { FR_003_OfficerScope }
check FR_003_OfficerScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023 (compliance reviewer cannot submit/claim/decide)
pred FR_004_ComplianceReadOnly {
  all op: Operation | op.caller.role = ComplianceReviewer implies
    op.kind not in (SubmitApp + ClaimApp + DecideApp)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (customer identity comes from auth, never the payload)
pred FR_005_CustomerIdentityFromAuth {
  // Every SubmitApp targeting an application is performed by the customer who owns it.
  all op: Operation |
    (op.kind = SubmitApp and some op.target) implies
      (op.caller.role = Customer and op.target.customer = op.caller)
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (one in-flight application per customer)
pred FR_008_OneInFlight {
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
      not (a1.status in (Submitted + UnderReview) and a2.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (submission writes an audit entry attributed to the customer)
pred FR_009_SubmissionAudited {
  all a: LoanApplication |
    (one e: AuditEntry |
        e.application = a
        and e.newStatus = Submitted
        and no e.prevStatus
        and e.actor = a.customer)
}
assert FR_009_SubmissionAudited { FR_009_SubmissionAudited }
check FR_009_SubmissionAudited for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (claim sets assigned officer; status moves Submitted→UnderReview)
pred FR_011_ClaimSetsOfficer {
  all a: LoanApplication |
    (a.status in (UnderReview + Approved + Rejected)) implies
      (some a.assignedOfficer and a.assignedOfficer.role = LoanOfficer)
}
assert FR_011_ClaimSetsOfficer { FR_011_ClaimSetsOfficer }
check FR_011_ClaimSetsOfficer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (at most one assigned officer per application)
pred FR_012_OneAssignedOfficer {
  all a: LoanApplication |
    a.status = Submitted implies no a.assignedOfficer
  all a: LoanApplication |
    a.status != Submitted implies one a.assignedOfficer
}
assert FR_012_OneAssignedOfficer { FR_012_OneAssignedOfficer }
check FR_012_OneAssignedOfficer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (only the assigned officer can decide)
pred FR_013_AssignedOfficerDecides {
  all d: Decision | d.decidedBy = d.application.assignedOfficer
}
assert FR_013_AssignedOfficerDecides { FR_013_AssignedOfficerDecides }
check FR_013_AssignedOfficerDecides for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (atomic decision: status, decision row, audit entry together)
pred FR_015_DecisionAtomic {
  all a: LoanApplication |
    (a.status in (Approved + Rejected)) iff (some d: Decision | d.application = a)
  all a: LoanApplication |
    a.status = Approved implies
      (one e: AuditEntry | e.application = a and e.newStatus = Approved and e.prevStatus = UnderReview)
  all a: LoanApplication |
    a.status = Rejected implies
      (one e: AuditEntry | e.application = a and e.newStatus = Rejected and e.prevStatus = UnderReview)
}
assert FR_015_DecisionAtomic { FR_015_DecisionAtomic }
check FR_015_DecisionAtomic for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (no further changes once Approved or Rejected)
pred FR_016_TerminalImmutability {
  // No audit entry records a transition leaving a terminal status — the four
  // legal transitions all originate from {(none), Submitted, UnderReview}.
  no e: AuditEntry | e.prevStatus in (Approved + Rejected)
}
assert FR_016_TerminalImmutability { FR_016_TerminalImmutability }
check FR_016_TerminalImmutability for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entry for every status change with attribution)
pred FR_017_AuditMandatory {
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and e.newStatus = Submitted)
    and (a.status in (UnderReview + Approved + Rejected) implies
         (some e: AuditEntry | e.application = a and e.newStatus = UnderReview))
    and (a.status = Approved implies
         (some e: AuditEntry | e.application = a and e.newStatus = Approved))
    and (a.status = Rejected implies
         (some e: AuditEntry | e.application = a and e.newStatus = Rejected))
}
assert FR_017_AuditMandatory { FR_017_AuditMandatory }
check FR_017_AuditMandatory for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit trail append-only — no duplicate entries per transition)
pred FR_018_AppendOnly {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and e1.newStatus = e2.newStatus)
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (exactly one audit entry per applied transition — no duplicates, none missing)
pred FR_019_OnePerTransition {
  all a: LoanApplication |
    (one e: AuditEntry | e.application = a and e.newStatus = Submitted)
    and (a.status in (UnderReview + Approved + Rejected) implies
         (one e: AuditEntry | e.application = a and e.newStatus = UnderReview))
    and (a.status = Approved implies
         (one e: AuditEntry | e.application = a and e.newStatus = Approved))
    and (a.status = Rejected implies
         (one e: AuditEntry | e.application = a and e.newStatus = Rejected))
    and (a.status not in (UnderReview + Approved + Rejected) implies
         (no e: AuditEntry | e.application = a and e.newStatus = UnderReview))
    and (a.status != Approved implies
         (no e: AuditEntry | e.application = a and e.newStatus = Approved))
    and (a.status != Rejected implies
         (no e: AuditEntry | e.application = a and e.newStatus = Rejected))
}
assert FR_019_OnePerTransition { FR_019_OnePerTransition }
check FR_019_OnePerTransition for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 (customer can only see own applications)
pred FR_020_CustomerOwnOnly {
  all op: Operation |
    (op.caller.role = Customer and op.kind in (GetApp + ListApps) and some op.target) implies
      op.target.customer = op.caller
}
assert FR_020_CustomerOwnOnly { FR_020_CustomerOwnOnly }
check FR_020_CustomerOwnOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023 (compliance reviewer cannot write — enforced at action level)
pred FR_023_ComplianceNoWrite {
  all op: Operation |
    op.caller.role = ComplianceReviewer implies
      op.kind not in (SubmitApp + ClaimApp + DecideApp)
}
assert FR_023_ComplianceNoWrite { FR_023_ComplianceNoWrite }
check FR_023_ComplianceNoWrite for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AssignedOfficerViolation { some d: Decision | d.decidedBy != d.application.assignedOfficer }
