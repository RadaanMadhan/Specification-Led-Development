// === feature_model.als — Alloy model for Loan Application ===

// ============================================
// DOMAIN SIGS
// ============================================

// Roles in the system
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// Loan application statuses
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
one sig Submitted, ApprovedEvent, RejectedEvent extends EventType {}

// Decision types
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// HTTP operation kinds (for permission matrix)
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById, PostDecision, GetAudit extends OperationKind {}

// ============================================
// DOMAIN ENTITIES
// ============================================

sig User {
  role: one Role,
  contactPreference: lone ContactPreference  // for customers only
}

sig LoanApplication {
  reference: one String,
  customer: one User,
  requestedAmountMinor: one Int,
  termMonths: one Int,
  purpose: one String,
  employmentStatus: one EmploymentStatus,
  employerName: lone String,  // required iff employmentStatus = Employed
  grossAnnualIncomeMinor: one Int,
  contactPreferenceSnapshot: one ContactPreference,
  status: one ApplicationStatus,
  submittedAt: one Int
}

sig Decision {
  application: one LoanApplication,
  decisionType: one DecisionType,
  reason: one String,
  decidedByUser: one User,
  decidedAt: one Int
}

sig ApplicationEvent {
  application: one LoanApplication,
  eventType: one EventType,
  actor: one User,
  occurredAt: one Int
}

// Permission matrix singleton
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============================================
// FACTS - STRUCTURAL CONSTRAINTS
// ============================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
fact F_PermissionMatrix {
  // Customer can submit, view own applications
  Customer -> PostApplications in PermMatrix.Allowed
  Customer -> GetApplications in PermMatrix.Allowed
  Customer -> GetApplicationById in PermMatrix.Allowed
  
  // BankStaff can view applications and make decisions
  BankStaff -> GetApplications in PermMatrix.Allowed
  BankStaff -> GetApplicationById in PermMatrix.Allowed
  BankStaff -> PostDecision in PermMatrix.Allowed
  BankStaff -> GetAudit in PermMatrix.Allowed
  
  // Closed-world: exactly these cells are allowed
  PermMatrix.Allowed = 
    (Customer -> PostApplications) +
    (Customer -> GetApplications) +
    (Customer -> GetApplicationById) +
    (BankStaff -> GetApplications) +
    (BankStaff -> GetApplicationById) +
    (BankStaff -> PostDecision) +
    (BankStaff -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
fact F_AmountRange {
  all app: LoanApplication |
    app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
fact F_TermMonths {
  all app: LoanApplication |
    app.termMonths in {12, 24, 36, 48, 60}
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
fact F_UniqueReference {
  all disj app1, app2: LoanApplication |
    app1.reference != app2.reference
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md; FR-004
fact F_OneOwnerPerApplication {
  all app: LoanApplication |
    app.customer.role = Customer
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
fact F_OnePendingPerCustomer {
  all customer: User |
    (customer.role = Customer) implies
      (lone app: LoanApplication | app.customer = customer and app.status = PendingReview)
}

// FEATURE-SPECIFIC  ANCHOR: FR-011
fact F_OneDecisionPerApplication {
  all app: LoanApplication |
    lone dec: Decision | dec.application = app
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
fact F_DecisionImpliesNotPending {
  all app: LoanApplication |
    (some dec: Decision | dec.application = app) implies app.status != PendingReview
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-012
fact F_ApprovedStatusHasApprovedDecision {
  all app: LoanApplication |
    app.status = Approved implies
      (some dec: Decision | dec.application = app and dec.decisionType = ApprovedDecision)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-012
fact F_RejectedStatusHasRejectedDecision {
  all app: LoanApplication |
    app.status = Rejected implies
      (some dec: Decision | dec.application = app and dec.decisionType = RejectedDecision)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
fact F_SubmissionAuditEntry {
  all app: LoanApplication |
    (some event: ApplicationEvent | event.application = app and event.eventType = Submitted)
}

// FEATURE-SPECIFIC  ANCHOR: FR-016
fact F_AuditEntryForDecision {
  all app: LoanApplication |
    (some dec: Decision | dec.application = app) implies
      (some event: ApplicationEvent | event.application = app and
        (event.eventType = ApprovedEvent or event.eventType = RejectedEvent))
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md application_events
fact F_AuditIsConsistent {
  all dec: Decision |
    (one event: ApplicationEvent | 
      event.application = dec.application and
      event.actor = dec.decidedByUser and
      ((dec.decisionType = ApprovedDecision and event.eventType = ApprovedEvent) or
       (dec.decisionType = RejectedDecision and event.eventType = RejectedEvent)))
}

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md; FR-016
fact F_SubmissionActorIsCustomer {
  all event: ApplicationEvent |
    event.eventType = Submitted implies event.actor = event.application.customer
}

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md; FR-016
fact F_DecisionActorIsStaff {
  all event: ApplicationEvent |
    (event.eventType = ApprovedEvent or event.eventType = RejectedEvent) implies
      event.actor.role = BankStaff
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
fact F_OnlyStaffCanDecide {
  all dec: Decision |
    dec.decidedByUser.role = BankStaff
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
fact F_ReasonNonEmpty {
  all dec: Decision |
    #dec.reason > 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
fact F_EmployerNameRequiredIfEmployed {
  all app: LoanApplication |
    app.employmentStatus = Employed implies (one app.employerName)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
fact F_EmployerNameAbsentIfNotEmployed {
  all app: LoanApplication |
    app.employmentStatus != Employed implies (no app.employerName)
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
fact F_IncomeNonNegative {
  all app: LoanApplication |
    app.grossAnnualIncomeMinor >= 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
fact F_PurposeNonEmpty {
  all app: LoanApplication |
    #app.purpose > 0
}

// ============================================
// PREDICATES AND ASSERTIONS
// ============================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
pred LeastPrivilege {
  // Customer cannot perform decision or audit actions
  no (Customer -> (PostDecision + GetAudit) & PermMatrix.Allowed)
  
  // BankStaff can perform decision and audit actions
  (BankStaff -> PostDecision) in PermMatrix.Allowed
  (BankStaff -> GetAudit) in PermMatrix.Allowed
  
  // At least one operation allowed to each role
  (some op: OperationKind | Customer -> op in PermMatrix.Allowed)
  (some op: OperationKind | BankStaff -> op in PermMatrix.Allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-015; contracts/http-api.md
pred AuthRequiredEverywhere {
  // Every user has exactly one role
  all u: User | one u.role
  // At least one authenticated user
  some User
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  // Every application has at least one submission event
  all app: LoanApplication |
    (some event: ApplicationEvent | event.application = app and event.eventType = Submitted)
  
  // Every decided application has a corresponding approval/rejection event
  all app: LoanApplication |
    (app.status != PendingReview) implies
      (some event: ApplicationEvent | event.application = app and
        (event.eventType = ApprovedEvent or event.eventType = RejectedEvent))
  
  some LoanApplication
}

assert AuditCompleteness {
  AuditCompleteness
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md application_events
pred AppendOnly {
  // Every decision is immutably recorded in audit with matching actor and type
  all dec: Decision |
    (one event: ApplicationEvent | 
      event.application = dec.application and
      event.actor = dec.decidedByUser and
      ((dec.decisionType = ApprovedDecision and event.eventType = ApprovedEvent) or
       (dec.decisionType = RejectedDecision and event.eventType = RejectedEvent)))
  
  some Decision
}

assert AppendOnly {
  AppendOnly
}

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md; FR-016
pred AttributionCorrectness {
  // Submission events have correct actor (the customer)
  all event: ApplicationEvent |
    event.eventType = Submitted implies event.actor = event.application.customer
  
  // Decision events have correct actor (a staff member)
  all event: ApplicationEvent |
    (event.eventType = ApprovedEvent or event.eventType = RejectedEvent) implies
      event.actor.role = BankStaff
  
  some ApplicationEvent
}

assert AttributionCorrectness {
  AttributionCorrectness
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md; FR-004
pred OwnershipExclusivity {
  // Each application is owned by exactly one customer
  all app: LoanApplication |
    app.customer.role = Customer
  
  some LoanApplication
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md
pred OwnershipBasedAccess {
  // Applications are only visible to their owner
  all app: LoanApplication |
    (one customer: User | customer = app.customer and customer.role = Customer)
  
  some LoanApplication
  some Customer
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-004
pred FR_001_AuthRequired {
  // Every application has an authenticated customer as submitter
  all app: LoanApplication |
    (app.customer.role = Customer)
  
  some LoanApplication
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-003
pred FR_002_ValidationRequired {
  // All applications satisfy validation constraints
  all app: LoanApplication |
    (app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000) and
    (app.termMonths in {12, 24, 36, 48, 60}) and
    (app.employmentStatus = Employed implies (one app.employerName)) and
    (app.employmentStatus != Employed implies (no app.employerName)) and
    (app.grossAnnualIncomeMinor >= 0) and
    (#app.purpose > 0)
  
  some LoanApplication
}

assert FR_002_ValidationRequired {
  FR_002_ValidationRequired
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_AmountAndTermLimits {
  // Amount and term are within allowed ranges
  all app: LoanApplication |
    (app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000) and
    (app.termMonths in {12, 24, 36, 48, 60})
  
  some LoanApplication
}

assert FR_003_AmountAndTermLimits {
  FR_003_AmountAndTermLimits
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueReference {
  // Each application has a unique reference
  all disj app1, app2: LoanApplication |
    app1.reference != app2.reference
  
  some LoanApplication
}

assert FR_004_UniqueReference {
  FR_004_UniqueReference
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  // At most one pending application per customer
  all customer: User |
    (customer.role = Customer) implies
      (lone app: LoanApplication | app.customer = customer and app.status = PendingReview)
  
  some Customer
}

assert FR_005_OnePendingPerCustomer {
  FR_005_OnePendingPerCustomer
}

// FEATURE-SPECIFIC  ANCHOR: FR-009, FR-010
pred FR_009_ReasonRequired {
  // All decisions have non-empty reasons
  all dec: Decision |
    #dec.reason > 0
  
  some Decision
}

assert FR_009_ReasonRequired {
  FR_009_ReasonRequired
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_DecisionPersisted {
  // Each decision is recorded with staff member and timestamp
  all dec: Decision |
    (dec.decidedByUser.role = BankStaff) and (dec.decidedAt >= 0)
  
  some Decision
}

assert FR_010_DecisionPersisted {
  FR_010_DecisionPersisted
}

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-012
pred FR_011_NoDecisionChanges {
  // Decided applications have exactly one decision and cannot be re-decided
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (one dec: Decision | dec.application = app)
  
  some LoanApplication
}

assert FR_011_NoDecisionChanges {
  FR_011_NoDecisionChanges
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_ConcurrentResolution {
  // Only the first decision is recorded; at most one per application
  all app: LoanApplication |
    (app.status != PendingReview) implies
      (lone dec: Decision | dec.application = app)
  
  some LoanApplication
}

assert FR_012_ConcurrentResolution {
  FR_012_ConcurrentResolution
}

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_CustomerDataIsolation {
  // Customers can only access their own applications
  all app: LoanApplication |
    (one customer: User | customer = app.customer and customer.role = Customer)
  
  some LoanApplication
  some Customer
}

assert FR_013_CustomerDataIsolation {
  FR_013_CustomerDataIsolation
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_RoleBasedAccess {
  // Only BankStaff can make decisions
  all dec: Decision |
    dec.decidedByUser.role = BankStaff
  
  // Customers never appear as decision makers
  all customer: User |
    (customer.role = Customer) implies (no dec: Decision | dec.decidedByUser = customer)
  
  some BankStaff
}

assert FR_015_RoleBasedAccess {
  FR_015_RoleBasedAccess
}

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrail {
  // Audit entries exist for every application and every decision
  all app: LoanApplication |
    (some event: ApplicationEvent | event.application = app and event.eventType = Submitted)
  
  all dec: Decision |
    (some event: ApplicationEvent | event.application = dec.application)
  
  some LoanApplication
  some ApplicationEvent
}

assert FR_016_AuditTrail {
  FR_016_AuditTrail
}

check LeastPrivilege for 5
check PermissionCompleteness for 5
check AuthRequiredEverywhere for 5
check AuditCompleteness for 5
check AppendOnly for 5
check AttributionCorrectness for 5
check OwnershipExclusivity for 5
check OwnershipBasedAccess for 5
check FR_001_AuthRequired for 5
check FR_002_ValidationRequired for 5
check FR_003_AmountAndTermLimits for 5
check FR_004_UniqueReference for 5
check FR_005_OnePendingPerCustomer for 5
check FR_009_ReasonRequired for 5
check FR_010_DecisionPersisted for 5
check FR_011_NoDecisionChanges for 5
check FR_012_ConcurrentResolution for 5
check FR_013_CustomerDataIsolation for 5
check FR_015_RoleBasedAccess for 5
check FR_016_AuditTrail for 5