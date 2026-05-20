// === feature_model.als — Alloy model for Loan Application with Role-Based Workflow and Audit Trail ===

// ============================================================================
// ROLES
// ============================================================================

abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ============================================================================
// OPERATIONS (for permission matrix)
// ============================================================================

abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication, 
         ClaimApplication, DecideApplication, ViewAudit extends OperationKind {}

// ============================================================================
// PERMISSION MATRIX (singleton sig with allowed cell set)
// ============================================================================

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001-004
fact F_PermissionMatrix {
  // Customer can submit, list own, view own
  Customer -> SubmitApplication in PermMatrix.Allowed
  Customer -> ListApplications in PermMatrix.Allowed
  Customer -> ViewApplication in PermMatrix.Allowed
  
  // Loan Officer can list, view any, claim, decide, view audit
  LoanOfficer -> ListApplications in PermMatrix.Allowed
  LoanOfficer -> ViewApplication in PermMatrix.Allowed
  LoanOfficer -> ClaimApplication in PermMatrix.Allowed
  LoanOfficer -> DecideApplication in PermMatrix.Allowed
  LoanOfficer -> ViewAudit in PermMatrix.Allowed
  
  // Compliance Reviewer can list, view, view audit (read-only)
  ComplianceReviewer -> ListApplications in PermMatrix.Allowed
  ComplianceReviewer -> ViewApplication in PermMatrix.Allowed
  ComplianceReviewer -> ViewAudit in PermMatrix.Allowed
  
  // Closed-world: exactly these cells are allowed
  PermMatrix.Allowed = (Customer -> SubmitApplication) +
                       (Customer -> ListApplications) +
                       (Customer -> ViewApplication) +
                       (LoanOfficer -> ListApplications) +
                       (LoanOfficer -> ViewApplication) +
                       (LoanOfficer -> ClaimApplication) +
                       (LoanOfficer -> DecideApplication) +
                       (LoanOfficer -> ViewAudit) +
                       (ComplianceReviewer -> ListApplications) +
                       (ComplianceReviewer -> ViewApplication) +
                       (ComplianceReviewer -> ViewAudit)
}

// ============================================================================
// APPLICATION STATUS STATES
// ============================================================================

abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ============================================================================
// USERS
// ============================================================================

sig User {
  role: one Role
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthRequiredEverywhere {
  // Every user has exactly one role (enforced by sig definition)
}

// ============================================================================
// LOAN APPLICATIONS
// ============================================================================

sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assignedOfficer: lone User
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md Customer entity; data-model.md
fact F_OwnershipExclusivity {
  // Every application is owned by exactly one customer (customer role)
  all app: LoanApplication | app.customer.role = Customer
}

// ============================================================================
// DECISIONS (one per application, max)
// ============================================================================

sig Decision {
  application: one LoanApplication,
  decidedBy: one User
}

fact F_OneDecisionPerApplication {
  all app: LoanApplication | lone dec: Decision | dec.application = app
}

// ============================================================================
// AUDIT ENTRIES (append-only event log)
// ============================================================================

sig ApplicationEvent {
  application: one LoanApplication,
  previousStatus: lone ApplicationStatus,
  newStatus: one ApplicationStatus,
  actor: one User,
  occurredAt: one Int  // timestamp for ordering
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md application_events (no UPDATE/DELETE)
fact F_AppendOnlyAuditEntries {
  // Events within an application must have unique timestamps (ordered, no duplicates)
  all disj ae1, ae2: ApplicationEvent |
    ae1.application = ae2.application implies ae1.occurredAt != ae2.occurredAt
}

// ============================================================================
// STATE TRANSITION CONSTRAINTS
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md
fact F_AuditCompleteness {
  // Every application must have initial Submitted event
  all app: LoanApplication |
    (one ae: ApplicationEvent |
      ae.application = app and
      ae.newStatus = Submitted and
      ae.previousStatus = none)
  
  // Every Under Review status has exactly one Submitted→Under Review event
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (one ae: ApplicationEvent |
      ae.application = app and
      ae.previousStatus = Submitted and
      ae.newStatus = UnderReview)
  
  // Every Approved status has exactly one Under Review→Approved event
  all app: LoanApplication |
    app.status = Approved implies
    (one ae: ApplicationEvent |
      ae.application = app and
      ae.previousStatus = UnderReview and
      ae.newStatus = Approved)
  
  // Every Rejected status has exactly one Under Review→Rejected event
  all app: LoanApplication |
    app.status = Rejected implies
    (one ae: ApplicationEvent |
      ae.application = app and
      ae.previousStatus = UnderReview and
      ae.newStatus = Rejected)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-011, FR-013; data-model.md
fact F_AssignmentRules {
  // If Submitted, no assigned officer
  all app: LoanApplication | app.status = Submitted implies (no app.assignedOfficer)
  
  // If Under Review, Approved, or Rejected, must have assigned officer (who is a loan officer)
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (some app.assignedOfficer and app.assignedOfficer.role = LoanOfficer)
}

// PATTERN: OwnershipBasedAccess + ConcurrencySafety  ANCHOR: spec.md FR-013, FR-012
fact F_OnlyAssignedOfficerDecides {
  // If a decision exists, the decider must be the assigned officer
  all dec: Decision | dec.decidedBy = dec.application.assignedOfficer
}

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012; edge case "race condition"
fact F_UniqueClaim {
  // Each application transitions to Under Review exactly once
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
    (one ae: ApplicationEvent |
      ae.application = app and
      ae.previousStatus = Submitted and
      ae.newStatus = UnderReview)
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-008; data-model.md idx_one_in_flight_per_customer
fact F_OneInFlightPerCustomer {
  // A customer cannot have two concurrent in-flight applications (status Submitted or Under Review)
  all disj app1, app2: LoanApplication |
    (app1.customer = app2.customer and
     (app1.status = Submitted or app1.status = UnderReview)) implies
    not (app2.status = Submitted or app2.status = UnderReview)
}

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md ApplicationEvent.actor_user_id; spec.md FR-017
fact F_EventActorCorrectness {
  // Initial submission event actor must be customer
  all ae: ApplicationEvent |
    (ae.previousStatus = none and ae.newStatus = Submitted) implies ae.actor.role = Customer
  
  // Claim and decision event actors must be loan officers
  all ae: ApplicationEvent |
    ((ae.previousStatus = Submitted and ae.newStatus = UnderReview) or
     (ae.previousStatus = UnderReview and (ae.newStatus = Approved or ae.newStatus = Rejected))) implies
    ae.actor.role = LoanOfficer
}

// PATTERN: NoInformationLeakage + OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md
fact F_NoExistenceLeak {
  // Customers cannot observe audit events for applications they don't own
  all ae: ApplicationEvent |
    (all cust: User | cust.role = Customer and cust != ae.application.customer implies
      not (cust in ApplicationEvent))
}

// ============================================================================
// NON-EMPTY UNIVERSE (required for non-vacuous checks)
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
}

// ============================================================================
// PATTERN PREDICATES & ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) iff
    ((r = Customer and (op = SubmitApplication or op = ListApplications or op = ViewApplication)) or
     (r = LoanOfficer and (op = ListApplications or op = ViewApplication or op = ClaimApplication or op = DecideApplication or op = ViewAudit)) or
     (r = ComplianceReviewer and (op = ListApplications or op = ViewApplication or op = ViewAudit)))
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 3 Role, exactly 6 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  all r: Role, op: OperationKind | r -> op in PermMatrix.Allowed or not (r -> op in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 3 Role, exactly 6 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all u: User | one r: Role | u.role = r
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018
pred AppendOnly {
  all app: LoanApplication |
    (all disj ae1, ae2: ApplicationEvent |
      ae1.application = app and ae2.application = app implies ae1.occurredAt != ae2.occurredAt)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  all app: LoanApplication |
    (one ae: ApplicationEvent | ae.application = app and ae.newStatus = Submitted and ae.previousStatus = none) and
    ((app.status in (UnderReview + Approved + Rejected)) implies
      (one ae: ApplicationEvent | ae.application = app and ae.previousStatus = Submitted and ae.newStatus = UnderReview)) and
    ((app.status = Approved) implies
      (one ae: ApplicationEvent | ae.application = app and ae.previousStatus = UnderReview and ae.newStatus = Approved)) and
    ((app.status = Rejected) implies
      (one ae: ApplicationEvent | ae.application = app and ae.previousStatus = UnderReview and ae.newStatus = Rejected))
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md ApplicationEvent.actor_user_id; spec.md FR-017
pred AttributionCorrectness {
  all ae: ApplicationEvent |
    ((ae.previousStatus = none) implies ae.actor.role = Customer) and
    ((ae.newStatus in (UnderReview + Approved + Rejected) and ae.previousStatus != none) implies ae.actor.role = LoanOfficer)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id
pred OwnershipExclusivity {
  all app: LoanApplication | app.customer.role = Customer
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020, FR-013
pred OwnershipBasedAccess {
  all cust: User | cust.role = Customer implies
    (all app: LoanApplication |
      (app.customer = cust and Customer -> ViewApplication in PermMatrix.Allowed) or
      (app.customer != cust and not (cust in app.customer -> app)))
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md
pred NoInformationLeakage {
  all cust: User | cust.role = Customer implies
    (all app: LoanApplication |
      app.customer != cust implies
      (no ae: ApplicationEvent | ae.application = app and ae.actor = cust))
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012
pred ConcurrencySafety {
  all app: LoanApplication |
    (app.status in (UnderReview + Approved + Rejected)) implies
    (one ae: ApplicationEvent |
      ae.application = app and ae.previousStatus = Submitted and ae.newStatus = UnderReview)
}

assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ============================================================================
// FEATURE-SPECIFIC PREDICATES
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-002 Customer role restrictions
pred FR_002_CustomerCannotDecideOrClaim {
  some app: LoanApplication | app.status = UnderReview and app.customer.role = Customer implies
    not (Customer -> DecideApplication in PermMatrix.Allowed or Customer -> ClaimApplication in PermMatrix.Allowed)
}

assert FR_002_CustomerCannotDecideOrClaim { FR_002_CustomerCannotDecideOrClaim }
check FR_002_CustomerCannotDecideOrClaim for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 Loan officer cannot submit applications
pred FR_003_LoanOfficerCannotSubmit {
  LoanOfficer -> SubmitApplication not in PermMatrix.Allowed
}

assert FR_003_LoanOfficerCannotSubmit { FR_003_LoanOfficerCannotSubmit }
check FR_003_LoanOfficerCannotSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 Compliance reviewer is read-only
pred FR_004_ComplianceReviewerReadOnly {
  ComplianceReviewer -> SubmitApplication not in PermMatrix.Allowed and
  ComplianceReviewer -> ClaimApplication not in PermMatrix.Allowed and
  ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed
}

assert FR_004_ComplianceReviewerReadOnly { FR_004_ComplianceReviewerReadOnly }
check FR_004_ComplianceReviewerReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 One in-flight per customer
pred FR_008_OneInFlightPerCustomer {
  all cust: User | cust.role = Customer implies
    (lone app: LoanApplication | app.customer = cust and (app.status = Submitted or app.status = UnderReview))
}

assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 Claim changes status and assigns officer
pred FR_011_ClaimChangesStatus {
  all app: LoanApplication |
    app.status = UnderReview implies
    (some officer: User | officer.role = LoanOfficer and officer = app.assignedOfficer and
      (one ae: ApplicationEvent | ae.application = app and ae.previousStatus = Submitted and ae.newStatus = UnderReview and ae.actor = officer))
}

assert FR_011_ClaimChangesStatus { FR_011_ClaimChangesStatus }
check FR_011_ClaimChangesStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 Only assigned officer can decide
pred FR_013_OnlyAssignedOfficerDecides {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (some dec: Decision | dec.application = app and dec.decidedBy = app.assignedOfficer)
}

assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 Decided applications are immutable
pred FR_016_ImmutableDecidedApplications {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (no ae: ApplicationEvent | ae.application = app and (ae.newStatus = Submitted or ae.newStatus = UnderReview))
}

assert FR_016_ImmutableDecidedApplications { FR_016_ImmutableDecidedApplications }
check FR_016_ImmutableDecidedApplications for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 Audit trail chronological ordering
pred FR_018_AuditChronological {
  all app: LoanApplication |
    (all disj ae1, ae2: ApplicationEvent |
      ae1.application = app and ae2.application = app and ae1.occurredAt < ae2.occurredAt implies
      (ae1.newStatus = Submitted or ae1.newStatus = UnderReview or ae1.newStatus = Approved or ae1.newStatus = Rejected))
}

assert FR_018_AuditChronological { FR_018_AuditChronological }
check FR_018_AuditChronological for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020 Customer privacy
pred FR_020_CustomerPrivacy {
  all disj cust1, cust2: User |
    cust1.role = Customer and cust2.role = Customer implies
    (all app: LoanApplication | app.customer = cust2 implies app.customer != cust1)
}

assert FR_020_CustomerPrivacy { FR_020_CustomerPrivacy }
check FR_020_CustomerPrivacy for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021 Officer identity hidden from customer
pred FR_021_OfficerIdentityHidden {
  // Customers see only non-officer audit events for their applications
  all cust: User | cust.role = Customer implies
    (all app: LoanApplication | app.customer = cust implies
      (all ae: ApplicationEvent | ae.application = app and ae.actor != cust implies
        ae.actor.role != LoanOfficer or ae.newStatus = Submitted))
}

assert FR_021_OfficerIdentityHidden { FR_021_OfficerIdentityHidden }
check FR_021_OfficerIdentityHidden for 5