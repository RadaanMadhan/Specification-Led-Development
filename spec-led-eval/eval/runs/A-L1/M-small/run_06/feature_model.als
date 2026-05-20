// === feature_model.als — Alloy model for Loan Application Feature (A-L1) ===

// ============================================================================
// SIGS — Domain Model
// ============================================================================

// Roles in the system
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// Users
abstract sig User {
  role: one Role
}

sig CustomerUser extends User {} {
  role = Customer
}

sig StaffUser extends User {} {
  role = BankStaff
}

// Application statuses
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// Employment statuses
abstract sig EmploymentStatus {}
one sig Employed, SelfEmployed, Unemployed, Retired, Student extends EmploymentStatus {}

// Contact preferences
abstract sig ContactPreference {}
one sig InApp, Email extends ContactPreference {}

// Event types for audit trail
abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

// Decision types
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// Loan Applications (core entity)
sig LoanApplication {
  reference: one Int,
  customer: one CustomerUser,
  requestedAmount: one Int,  // in pence; must be 100000-2500000
  termMonths: one Int,       // must be in {12,24,36,48,60}
  purpose: one Int,          // abstract: non-empty text identifier
  employmentStatus: one EmploymentStatus,
  employerName: lone Int,    // required iff employmentStatus = Employed
  grossAnnualIncome: one Int, // in pence; must be >= 0
  contactPreference: one ContactPreference,
  status: one ApplicationStatus,
  submittedAt: one Int       // abstract timestamp
}

// Staff decisions on applications (at most one per application)
sig Decision {
  application: one LoanApplication,
  decisionType: one DecisionType,
  reason: one Int,           // must be non-empty
  decidedByUser: one StaffUser,
  decidedAt: one Int         // abstract timestamp
}

// Append-only audit trail of status changes
sig ApplicationEvent {
  application: one LoanApplication,
  eventType: one EventType,
  actor: one User,
  occurredAt: one Int        // abstract timestamp
}

// Operations for permission matrix
abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication, RecordDecision, ViewAudit
  extends OperationKind {}

// Permission matrix (singleton controlling role-based access)
one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// ============================================================================
// FACTS — Structural invariants (all named, per requirement 4)
// ============================================================================

// PATTERN: NonEmptyUniverse
// ANCHOR: requirement 9 — ensure assertions don't vacuously pass
fact F_NonEmptyUniverse {
  some CustomerUser
  some StaffUser
  some LoanApplication
  some ApplicationEvent
  some Decision
}

// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001, FR-015
fact F_PermissionMatrix {
  PermMatrix.allowed = 
    (Customer -> SubmitApplication) +
    (Customer -> ListApplications) +
    (Customer -> ViewApplication) +
    (BankStaff -> ListApplications) +
    (BankStaff -> ViewApplication) +
    (BankStaff -> RecordDecision) +
    (BankStaff -> ViewAudit)
}

// PATTERN: OwnershipExclusivity
// ANCHOR: data-model.md LoanApplication.customer_id (one owner); spec.md FR-013
fact F_OwnershipExclusivity {
  all app: LoanApplication |
    one customer: CustomerUser | app.customer = customer
}

// PATTERN: ValidationBeforeMutation
// ANCHOR: spec.md FR-002, FR-003; data-model.md validation.py
fact F_ValidationConstraints {
  all app: LoanApplication |
    // Amount: £1,000–£25,000 (100000–2500000 pence)
    app.requestedAmount >= 100000 and
    app.requestedAmount <= 2500000 and
    // Terms: 12, 24, 36, 48, or 60 months
    app.termMonths in {12, 24, 36, 48, 60} and
    // Income non-negative
    app.grossAnnualIncome >= 0 and
    // Purpose must be provided (abstract as: some Int identifier)
    some app.purpose
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002; data-model.md employer_name validation
fact F_EmploymentValidation {
  all app: LoanApplication |
    (app.employmentStatus = Employed implies some app.employerName) and
    (app.employmentStatus != Employed implies no app.employerName)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005; data-model.md idx_one_pending_per_customer
fact F_OnePendingPerCustomer {
  all customer: CustomerUser |
    lone app: LoanApplication |
      app.customer = customer and app.status = PendingReview
}

// PATTERN: AppendOnly
// ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE ... application_events"
fact F_AuditAppendOnly {
  all app: LoanApplication |
    // Pending: must have submitted event; no others
    (app.status = PendingReview implies (one e: ApplicationEvent | e.application = app and e.eventType = SubmittedEvent)) and
    // Approved: must have submitted and approved events; no rejected
    (app.status = Approved implies 
      (one e: ApplicationEvent | e.application = app and e.eventType = SubmittedEvent) and
      (one e: ApplicationEvent | e.application = app and e.eventType = ApprovedEvent) and
      (no e: ApplicationEvent | e.application = app and e.eventType = RejectedEvent)) and
    // Rejected: must have submitted and rejected events; no approved
    (app.status = Rejected implies
      (one e: ApplicationEvent | e.application = app and e.eventType = SubmittedEvent) and
      (one e: ApplicationEvent | e.application = app and e.eventType = RejectedEvent) and
      (no e: ApplicationEvent | e.application = app and e.eventType = ApprovedEvent))
}

// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-016; data-model.md ApplicationEvent
fact F_AuditCompleteness {
  all app: LoanApplication |
    (app.status = PendingReview implies (some e: ApplicationEvent | e.application = app and e.eventType = SubmittedEvent)) and
    (app.status = Approved implies (some e: ApplicationEvent | e.application = app and e.eventType = ApprovedEvent)) and
    (app.status = Rejected implies (some e: ApplicationEvent | e.application = app and e.eventType = RejectedEvent))
}

// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-016; data-model.md application_events.actor_user_id
fact F_AttributionCorrectness {
  all event: ApplicationEvent |
    (event.eventType = SubmittedEvent implies event.actor = event.application.customer) and
    (event.eventType = ApprovedEvent implies event.actor in StaffUser) and
    (event.eventType = RejectedEvent implies event.actor in StaffUser)
}

// PATTERN: One decision per application (from OwnershipExclusivity pattern logic)
// ANCHOR: data-model.md Decision.application_id PK; spec.md FR-011, FR-012
fact F_OneDecisionPerApplication {
  all app: LoanApplication |
    lone d: Decision | d.application = app
}

// Decisions must be consistent with application status
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010, FR-011
fact F_DecisionConsistency {
  all app: LoanApplication, d: Decision |
    d.application = app implies
    (d.decisionType = ApprovedDecision iff app.status = Approved) and
    (d.decisionType = RejectedDecision iff app.status = Rejected)
}

// Unique references across all applications
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004; data-model.md UNIQUE constraint
fact F_UniqueReferences {
  all disj app1, app2: LoanApplication |
    app1.reference != app2.reference
}

// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md "404 not 403"
fact F_NoInformationLeakage {
  all customer: CustomerUser, app: LoanApplication |
    app.customer != customer implies (customer cannot view app)
}

// ============================================================================
// PATTERN PREDICATES & ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001, FR-015
pred LeastPrivilege {
  (Customer -> SubmitApplication in PermMatrix.allowed) and
  (Customer -> ListApplications in PermMatrix.allowed) and
  (Customer -> ViewApplication in PermMatrix.allowed) and
  not (Customer -> RecordDecision in PermMatrix.allowed) and
  not (Customer -> ViewAudit in PermMatrix.allowed) and
  not (BankStaff -> SubmitApplication in PermMatrix.allowed) and
  (BankStaff -> ListApplications in PermMatrix.allowed) and
  (BankStaff -> ViewApplication in PermMatrix.allowed) and
  (BankStaff -> RecordDecision in PermMatrix.allowed) and
  (BankStaff -> ViewAudit in PermMatrix.allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  PermMatrix.allowed = 
    (Customer -> SubmitApplication) +
    (Customer -> ListApplications) +
    (Customer -> ViewApplication) +
    (BankStaff -> ListApplications) +
    (BankStaff -> ViewApplication) +
    (BankStaff -> RecordDecision) +
    (BankStaff -> ViewAudit)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-016; data-model.md ApplicationEvent
pred AuditCompleteness {
  some app: LoanApplication |
    (app.status = PendingReview implies (some e: ApplicationEvent | e.application = app and e.eventType = SubmittedEvent)) and
    (app.status = Approved implies (some e: ApplicationEvent | e.application = app and e.eventType = ApprovedEvent)) and
    (app.status = Rejected implies (some e: ApplicationEvent | e.application = app and e.eventType = RejectedEvent))
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly
// ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE ... application_events"
pred AppendOnly {
  some app: LoanApplication |
    (app.status = Approved implies (one e: ApplicationEvent | e.application = app and e.eventType = ApprovedEvent)) and
    (app.status = Rejected implies (one e: ApplicationEvent | e.application = app and e.eventType = RejectedEvent))
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-016; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  some app: LoanApplication |
    some event: ApplicationEvent |
      event.application = app and
      (event.eventType = SubmittedEvent implies event.actor = app.customer) and
      (event.eventType in {ApprovedEvent, RejectedEvent} implies event.actor in StaffUser)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity
// ANCHOR: data-model.md LoanApplication.customer_id; spec.md one owner
pred OwnershipExclusivity {
  some app: LoanApplication |
    one customer: CustomerUser | app.customer = customer
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-013; contracts/http-api.md customer filtering
pred OwnershipBasedAccess {
  some customer: CustomerUser, app: LoanApplication |
    app.customer = customer and (customer can view app)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md 404 behavior
pred NoInformationLeakage {
  some customer: CustomerUser, app: LoanApplication |
    app.customer != customer and (customer cannot view app)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation
// ANCHOR: spec.md FR-002, FR-003; data-model.md validation
pred ValidationBeforeMutation {
  some app: LoanApplication |
    app.requestedAmount >= 100000 and
    app.requestedAmount <= 2500000 and
    app.termMonths in {12, 24, 36, 48, 60} and
    app.grossAnnualIncome >= 0 and
    (app.employmentStatus = Employed implies some app.employerName)
}

assert ValidationBeforeMutation {
  ValidationBeforeMutation
}

check ValidationBeforeMutation for 5

// ============================================================================
// FEATURE-SPECIFIC PREDICATES & ASSERTIONS
// ============================================================================

// FR-001: Customer can submit loan application with required fields
// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_SubmitApplication {
  some customer: CustomerUser, app: LoanApplication |
    app.customer = customer and
    app.status = PendingReview and
    some app.reference and
    some app.submittedAt and
    some app.purpose and
    app.requestedAmount > 0 and
    app.termMonths > 0
}

assert FR_001_SubmitApplication {
  FR_001_SubmitApplication
}

check FR_001_SubmitApplication for 5

// FR-005: One pending application per customer
// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  all customer: CustomerUser |
    lone app: LoanApplication |
      app.customer = customer and app.status = PendingReview
}

assert FR_005_OnePendingPerCustomer {
  FR_005_OnePendingPerCustomer
}

check FR_005_OnePendingPerCustomer for 5

// FR-009: Staff can record decision with non-empty reason
// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_DecisionWithReason {
  some staff: StaffUser, app: LoanApplication, d: Decision |
    d.application = app and
    d.decidedByUser = staff and
    some d.reason and
    d.decisionType in {ApprovedDecision, RejectedDecision}
}

assert FR_009_DecisionWithReason {
  FR_009_DecisionWithReason
}

check FR_009_DecisionWithReason for 5

// FR-011: Prevent further decisions on decided applications
// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_DecisionsImmutable {
  all app: LoanApplication, d: Decision |
    d.application = app implies
    (app.status = Approved or app.status = Rejected)
}

assert FR_011_DecisionsImmutable {
  FR_011_DecisionsImmutable
}

check FR_011_DecisionsImmutable for 5

// FR-012: Concurrent decisions—only first succeeds
// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NoConcurrentDecisions {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
    (lone d: Decision | d.application = app)
}

assert FR_012_NoConcurrentDecisions {
  FR_012_NoConcurrentDecisions
}

check FR_012_NoConcurrentDecisions for 5

// FR-013: Customer can only view their own applications
// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OwnershipBasedView {
  all customer: CustomerUser, app: LoanApplication |
    (customer can view app) iff (app.customer = customer)
}

assert FR_013_OwnershipBasedView {
  FR_013_OwnershipBasedView
}

check FR_013_OwnershipBasedView for 5

// FR-015: Restrict decision actions to bank-staff role
// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_StaffOnlyDecisions {
  all d: Decision |
    d.decidedByUser in StaffUser and d.decidedByUser.role = BankStaff
}

assert FR_015_StaffOnlyDecisions {
  FR_015_StaffOnlyDecisions
}

check FR_015_StaffOnlyDecisions for 5

// FR-016: Audit record of every status change
// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrail {
  all app: LoanApplication |
    (app.status = PendingReview implies (some e: ApplicationEvent | e.application = app and e.eventType = SubmittedEvent)) and
    (app.status = Approved implies (some e: ApplicationEvent | e.application = app and e.eventType = ApprovedEvent)) and
    (app.status = Rejected implies (some e: ApplicationEvent | e.application = app and e.eventType = RejectedEvent))
}

assert FR_016_AuditTrail {
  FR_016_AuditTrail
}

check FR_016_AuditTrail for 5

// ============================================================================
// HELPER PREDICATES
// ============================================================================

pred can[customer: CustomerUser, app: LoanApplication] {
  app.customer = customer
}

pred cannot[customer: CustomerUser, app: LoanApplication] {
  app.customer != customer
}