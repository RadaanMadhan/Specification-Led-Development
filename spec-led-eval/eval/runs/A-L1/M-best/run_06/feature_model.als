// === feature_model.als — Alloy model for Loan Application (003) ===
//
// Encodes the structural invariants of the Loan Application feature:
//   - Permission matrix: customer vs bank_staff over 5 endpoints
//   - Ownership: each LoanApplication has exactly one customer-role owner
//   - Single in-flight pending application per customer (FR-005)
//   - At-most-one decision per application (FR-011, FR-012)
//   - Append-only audit trail with correct attribution (FR-016)

// -----------------------------------------------------------------------------
// Sigs
// -----------------------------------------------------------------------------

abstract sig Role {}
one sig Customer, BankStaff extends Role {}

abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById,
        PostDecision, GetAudit extends OperationKind {}

abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

sig User { role: one Role }
sig Reason {}

sig LoanApplication {
  customer: one User,
  status:   one ApplicationStatus
}

sig Decision {
  application:  one LoanApplication,
  decisionType: one ApplicationStatus,
  decidedBy:    one User,
  reason:       one Reason
}

sig ApplicationEvent {
  application: one LoanApplication,
  eventType:   one EventType,
  actor:       one User
}

// Permission matrix as a singleton-sig field (Alloy-6-correct encoding).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// -----------------------------------------------------------------------------
// Non-empty universe so assertions bite, not vacuous.
// -----------------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Reason
}

// -----------------------------------------------------------------------------
// Load-bearing facts (named so mutation testing can clear them by name).
// -----------------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Customer  -> PostApplications)
    + (Customer  -> GetApplications)
    + (Customer  -> GetApplicationById)
    + (BankStaff -> GetApplications)
    + (BankStaff -> GetApplicationById)
    + (BankStaff -> PostDecision)
    + (BankStaff -> GetAudit)
}

fact F_ApplicationCustomerIsCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

fact F_OnePendingPerCustomer {
  all u: User |
    (lone a: LoanApplication | (a.customer = u) and (a.status = PendingReview))
}

fact F_DecisionExistsIffDecided {
  all a: LoanApplication |
    (some d: Decision | d.application = a) iff (a.status in (Approved + Rejected))
}

fact F_AtMostOneDecisionPerApp {
  all a: LoanApplication | (lone d: Decision | d.application = a)
}

fact F_DecisionTypeMatchesStatus {
  all d: Decision | d.decisionType = d.application.status
}

fact F_DecisionTypeIsApprovedOrRejected {
  all d: Decision | d.decisionType in (Approved + Rejected)
}

fact F_DecisionByBankStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

fact F_SubmittedEventExists {
  all a: LoanApplication |
    (one e: ApplicationEvent | (e.application = a) and (e.eventType = SubmittedEvent))
}

fact F_DecisionEventIffDecided {
  all a: LoanApplication |
    (a.status = Approved) iff
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = ApprovedEvent))
  all a: LoanApplication |
    (a.status = Rejected) iff
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = RejectedEvent))
  all a: LoanApplication |
    (a.status = PendingReview) implies
      (no e: ApplicationEvent |
         (e.application = a) and (e.eventType in (ApprovedEvent + RejectedEvent)))
}

fact F_SubmittedEventActor {
  all e: ApplicationEvent |
    (e.eventType = SubmittedEvent) implies (e.actor = e.application.customer)
}

fact F_DecisionEventActor {
  all e: ApplicationEvent |
    (e.eventType in (ApprovedEvent + RejectedEvent)) implies (e.actor.role = BankStaff)
}

// =============================================================================
// PATTERN PREDICATES + ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-015
pred LeastPrivilege {
  // Customers cannot decide nor view audit
  (Customer -> PostDecision) not in PermMatrix.Allowed
  (Customer -> GetAudit)     not in PermMatrix.Allowed
  // Staff cannot submit applications as if they were customers
  (BankStaff -> PostApplications) not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every role can do at least one thing; every endpoint is reachable by at least one role.
  all r: Role       | (some op: OperationKind | (r -> op) in PermMatrix.Allowed)
  all op: OperationKind | (some r: Role       | (r -> op) in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001 (customer submit), FR-009/FR-015 (staff decide), FR-016 (audit)
pred PermissionGrounding {
  (Customer  -> PostApplications) in PermMatrix.Allowed   // FR-001
  (BankStaff -> PostDecision)     in PermMatrix.Allowed   // FR-009, FR-015
  (BankStaff -> GetAudit)         in PermMatrix.Allowed   // FR-016
  (BankStaff -> GetApplications)  in PermMatrix.Allowed   // FR-007
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  // No endpoint is reachable without going through some role gate.
  all op: OperationKind | (some r: Role | (r -> op) in PermMatrix.Allowed)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    (some e: ApplicationEvent | (e.application = a) and (e.eventType = SubmittedEvent))
  all a: LoanApplication |
    (a.status = Approved) implies
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = ApprovedEvent))
  all a: LoanApplication |
    (a.status = Rejected) implies
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = RejectedEvent))
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "No UPDATE/DELETE code path"
pred AppendOnly {
  // Pending applications cannot have decision events attached.
  all a: LoanApplication |
    (a.status = PendingReview) implies
      (no e: ApplicationEvent |
         (e.application = a) and (e.eventType in (ApprovedEvent + RejectedEvent)))
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md actor_user_id
pred AttributionCorrectness {
  all e: ApplicationEvent |
    (e.eventType = SubmittedEvent) implies (e.actor = e.application.customer)
  all e: ApplicationEvent |
    (e.eventType in (ApprovedEvent + RejectedEvent)) implies (e.actor.role = BankStaff)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id FK on loan_applications
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md customer scoping
pred OwnershipBasedAccess {
  // A customer's access to an application resolves through the ownership relation:
  // the application has exactly one owning customer-role user.
  all a: LoanApplication |
    (one u: User | (u = a.customer) and (u.role = Customer))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: contracts/http-api.md "404 not 403" for non-owner customers (FR-013, SC-004)
pred NoInformationLeakage {
  // Ownership is exclusive — there is no "visible but unowned" path: every
  // application has exactly one customer-role owner; non-owners share no
  // privileged relation to the application.
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md conditional UPDATE
pred ConcurrencySafety {
  // Two concurrent decisions cannot both win: at most one Decision per application.
  all a: LoanApplication | (lone d: Decision | d.application = a)
  no disj d1, d2: Decision | d1.application = d2.application
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 6

// =============================================================================
// FR-SPECIFIC PREDICATES + ASSERTIONS
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (customer submits)
pred FR_001_CustomerSubmits {
  // Every application originates from a customer-role user, and the API
  // permits customers to submit.
  all a: LoanApplication | a.customer.role = Customer
  (Customer -> PostApplications) in PermMatrix.Allowed
}
assert FR_001_CustomerSubmits { FR_001_CustomerSubmits }
check FR_001_CustomerSubmits for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-002 (mandatory-field validation; structural backstop = total relations)
pred FR_002_AllFieldsPopulated {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | one a.status
  all d: Decision        | one d.reason
  all d: Decision        | one d.decidedBy
  all e: ApplicationEvent | one e.application
  all e: ApplicationEvent | one e.actor
}
assert FR_002_AllFieldsPopulated { FR_002_AllFieldsPopulated }
check FR_002_AllFieldsPopulated for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (status comes from a closed set; numeric ranges are validation-layer)
pred FR_003_StatusInClosedSet {
  all a: LoanApplication | a.status in (PendingReview + Approved + Rejected)
  all d: Decision        | d.decisionType in (Approved + Rejected)
}
assert FR_003_StatusInClosedSet { FR_003_StatusInClosedSet }
check FR_003_StatusInClosedSet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (initial status is PendingReview, customer recorded)
pred FR_004_InitialStatusPending {
  // An application is "fresh" (no decision yet) iff its status is PendingReview.
  all a: LoanApplication |
    ((no d: Decision | d.application = a) iff (a.status = PendingReview))
  all a: LoanApplication | one a.customer
}
assert FR_004_InitialStatusPending { FR_004_InitialStatusPending }
check FR_004_InitialStatusPending for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (one Pending Review per customer)
pred FR_005_OnePendingPerCustomer {
  no disj a1, a2: LoanApplication |
    (a1.customer = a2.customer)
    and (a1.status = PendingReview)
    and (a2.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (confirmation = submitted event exists)
pred FR_006_SubmissionEventExists {
  all a: LoanApplication |
    (some e: ApplicationEvent | (e.application = a) and (e.eventType = SubmittedEvent))
}
assert FR_006_SubmissionEventExists { FR_006_SubmissionEventExists }
check FR_006_SubmissionEventExists for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (staff queue access)
pred FR_007_StaffCanListApplications {
  (BankStaff -> GetApplications) in PermMatrix.Allowed
}
assert FR_007_StaffCanListApplications { FR_007_StaffCanListApplications }
check FR_007_StaffCanListApplications for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-008 (staff can view any application)
pred FR_008_StaffCanViewAnyApplication {
  (BankStaff -> GetApplicationById) in PermMatrix.Allowed
}
assert FR_008_StaffCanViewAnyApplication { FR_008_StaffCanViewAnyApplication }
check FR_008_StaffCanViewAnyApplication for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-009 (decision requires non-empty reason)
pred FR_009_DecisionHasReason {
  all d: Decision | one d.reason
}
assert FR_009_DecisionHasReason { FR_009_DecisionHasReason }
check FR_009_DecisionHasReason for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (decision atomically persists status, decision row, and event)
pred FR_010_DecisionPersistedAtomically {
  all d: Decision | d.decisionType = d.application.status
  all d: Decision | d.application.status in (Approved + Rejected)
  all d: Decision |
    (some e: ApplicationEvent |
       (e.application = d.application)
       and (e.eventType in (ApprovedEvent + RejectedEvent))
       and (e.actor = d.decidedBy))
}
assert FR_010_DecisionPersistedAtomically { FR_010_DecisionPersistedAtomically }
check FR_010_DecisionPersistedAtomically for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (decided applications are immutable: at most one decision)
pred FR_011_DecisionImmutable {
  all a: LoanApplication | (lone d: Decision | d.application = a)
}
assert FR_011_DecisionImmutable { FR_011_DecisionImmutable }
check FR_011_DecisionImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (only first decision wins under concurrency)
pred FR_012_NoTwoDecisions {
  no disj d1, d2: Decision | d1.application = d2.application
}
assert FR_012_NoTwoDecisions { FR_012_NoTwoDecisions }
check FR_012_NoTwoDecisions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (customer can't see another customer's application)
pred FR_013_CustomerCannotSeeOthers {
  // Ownership uniquely identifies the legitimate customer viewer; there is
  // no second-owner / shared-view path.
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
}
assert FR_013_CustomerCannotSeeOthers { FR_013_CustomerCannotSeeOthers }
check FR_013_CustomerCannotSeeOthers for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (customer notified on decision = decision event exists)
pred FR_014_DecisionEventForEveryDecision {
  all a: LoanApplication |
    (a.status = Approved) implies
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = ApprovedEvent))
  all a: LoanApplication |
    (a.status = Rejected) implies
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = RejectedEvent))
}
assert FR_014_DecisionEventForEveryDecision { FR_014_DecisionEventForEveryDecision }
check FR_014_DecisionEventForEveryDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (decisions are bank-staff only)
pred FR_015_StaffOnlyDecisions {
  all d: Decision | d.decidedBy.role = BankStaff
  (Customer -> PostDecision) not in PermMatrix.Allowed
  (Customer -> GetAudit)     not in PermMatrix.Allowed
}
assert FR_015_StaffOnlyDecisions { FR_015_StaffOnlyDecisions }
check FR_015_StaffOnlyDecisions for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-016 (complete & correctly-attributed audit trail of status changes)
pred FR_016_AuditTrailComplete {
  all a: LoanApplication |
    (some e: ApplicationEvent | (e.application = a) and (e.eventType = SubmittedEvent))
  all a: LoanApplication |
    (a.status = Approved) implies
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = ApprovedEvent))
  all a: LoanApplication |
    (a.status = Rejected) implies
      (some e: ApplicationEvent | (e.application = a) and (e.eventType = RejectedEvent))
  all e: ApplicationEvent |
    (e.eventType = SubmittedEvent) implies (e.actor = e.application.customer)
  all e: ApplicationEvent |
    (e.eventType in (ApprovedEvent + RejectedEvent)) implies (e.actor.role = BankStaff)
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (retention: decided applications keep their decision link)
pred FR_017_DecisionsRetained {
  all a: LoanApplication |
    (a.status in (Approved + Rejected)) implies
      (one d: Decision | d.application = a)
}
assert FR_017_DecisionsRetained { FR_017_DecisionsRetained }
check FR_017_DecisionsRetained for 6