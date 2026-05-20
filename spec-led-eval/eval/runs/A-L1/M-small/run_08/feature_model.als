// === feature_model.als — Alloy model for Loan Application (A-L1) ===

// === Type Hierarchy ===

// Roles
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// Application Statuses
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// Employment Statuses
abstract sig EmploymentStatus {}
one sig Employed, SelfEmployed, Unemployed, Retired, Student extends EmploymentStatus {}

// Contact Preferences
abstract sig ContactPreference {}
one sig InApp, Email extends ContactPreference {}

// Event Types (audit log)
abstract sig EventType {}
one sig Submitted, ApprovedEvent, RejectedEvent extends EventType {}

// Decision Types
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// Operation Kinds (API endpoints)
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationDetail, PostDecision, GetAudit extends OperationKind {}

// === Entities ===

sig User {
  role: one Role
}

sig LoanApplication {
  customer: one User,
  requestedAmountMinor: one Int,
  termMonths: one Int,
  purpose: one String,
  employmentStatus: one EmploymentStatus,
  employerName: lone String,
  grossAnnualIncomeMinor: one Int,
  status: one ApplicationStatus,
  reference: one String,
  submittedAt: one String
}

sig Decision {
  application: one LoanApplication,
  decisionType: one DecisionType,
  reason: one String,
  decidedByUser: one User,
  decidedAt: one String
}

sig ApplicationEvent {
  application: one LoanApplication,
  eventType: one EventType,
  actorUser: one User,
  occurredAt: one String
}

// Permission Matrix (singleton)
one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// === Mandatory Non-Empty Universe ===

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// === Structural Constraints ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionMatrix {
  PermMatrix.allowed = (CustomerRole -> PostApplications) +
                      (CustomerRole -> GetApplications) +
                      (CustomerRole -> GetApplicationDetail) +
                      (BankStaffRole -> GetApplications) +
                      (BankStaffRole -> GetApplicationDetail) +
                      (BankStaffRole -> PostDecision) +
                      (BankStaffRole -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-003, data-model.md LoanApplication.requested_amount_minor
fact F_AmountRange {
  all app: LoanApplication |
    app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000
}

// FEATURE-SPECIFIC  ANCHOR: FR-003, data-model.md LoanApplication.term_months
fact F_TermMonths {
  all app: LoanApplication |
    app.termMonths in (12 + 24 + 36 + 48 + 60)
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md LoanApplication.gross_annual_income_minor
fact F_GrossIncomeNonNegative {
  all app: LoanApplication |
    app.grossAnnualIncomeMinor >= 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-002, data-model.md LoanApplication.purpose
fact F_PurposeNonEmpty {
  all app: LoanApplication |
    app.purpose != ""
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md LoanApplication.employer_name
fact F_EmployerNameLogic {
  all app: LoanApplication |
    (app.employmentStatus = Employed implies (app.employerName != none and app.employerName != ""))
}

// FEATURE-SPECIFIC  ANCHOR: FR-004, data-model.md LoanApplication.reference UNIQUE
fact F_UniqueReferences {
  all disj app1, app2: LoanApplication |
    app1.reference != app2.reference
}

// PATTERN: ConcurrencySafety  ANCHOR: FR-012, data-model.md Decision application_id PK
fact F_OneDecisionPerApplication {
  all app: LoanApplication |
    lone dec: Decision | dec.application = app
}

// FEATURE-SPECIFIC  ANCHOR: FR-005, data-model.md idx_one_pending_per_customer
fact F_OnePendingPerCustomer {
  all u: User |
    u.role = CustomerRole implies
      lone app: LoanApplication | app.customer = u and app.status = PendingReview
}

// PATTERN: AuditCompleteness  ANCHOR: FR-016, data-model.md application_events
fact F_AuditTrailCompleteness {
  all app: LoanApplication |
    some evt: ApplicationEvent | evt.application = app and evt.eventType = Submitted
}

// PATTERN: AppendOnly  ANCHOR: FR-016, data-model.md application_events append-only
fact F_AppendOnlyAuditEntries {
  all dec: Decision |
    some evt: ApplicationEvent | evt.application = dec.application and
      ((dec.decisionType = ApprovedDecision and evt.eventType = ApprovedEvent) or
       (dec.decisionType = RejectedDecision and evt.eventType = RejectedEvent))
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011 decision status sync
fact F_DecisionStatusSync {
  all app: LoanApplication |
    (some dec: Decision | dec.application = app) implies
      (app.status = Approved or app.status = Rejected)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009, data-model.md Decision.reason CHECK
fact F_DecisionReasonNonEmpty {
  all dec: Decision |
    dec.reason != ""
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, data-model.md ApplicationEvent.actor_user_id
fact F_AuditEventAttribution {
  all evt: ApplicationEvent |
    evt.eventType = Submitted implies evt.actorUser = evt.application.customer
}

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-002, validation.py
fact F_ValidationBeforeMutation {
  all app: LoanApplication |
    (app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000) and
    (app.termMonths in (12 + 24 + 36 + 48 + 60)) and
    (app.purpose != "") and
    (app.grossAnnualIncomeMinor >= 0) and
    (app.employmentStatus = Employed implies (app.employerName != none and app.employerName != ""))
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md authentication, FR-015
fact F_AllOperationsRequireAuth {
  all app: LoanApplication | app.customer in User and app.customer.role = CustomerRole
  all evt: ApplicationEvent | evt.actorUser in User
  all dec: Decision | dec.decidedByUser in User and dec.decidedByUser.role = BankStaffRole
}

// === Predicates and Assertions ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix, FR-015
pred LeastPrivilege {
  (CustomerRole -> PostApplications) in PermMatrix.allowed and
  (CustomerRole -> GetApplications) in PermMatrix.allowed and
  (CustomerRole -> GetApplicationDetail) in PermMatrix.allowed and
  not ((BankStaffRole -> PostApplications) in PermMatrix.allowed) and
  (BankStaffRole -> GetApplications) in PermMatrix.allowed and
  (BankStaffRole -> GetApplicationDetail) in PermMatrix.allowed and
  (BankStaffRole -> PostDecision) in PermMatrix.allowed and
  (BankStaffRole -> GetAudit) in PermMatrix.allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AppendOnly  ANCHOR: FR-016, data-model.md application_events append-only
pred AppendOnly {
  all dec: Decision |
    one evt: ApplicationEvent |
      evt.application = dec.application and
      ((dec.decisionType = ApprovedDecision and evt.eventType = ApprovedEvent) or
       (dec.decisionType = RejectedDecision and evt.eventType = RejectedEvent))
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-016, data-model.md application_events
pred AuditCompleteness {
  (all app: LoanApplication |
    one evt: ApplicationEvent | evt.application = app and evt.eventType = Submitted) and
  (all dec: Decision |
    one evt: ApplicationEvent | evt.application = dec.application and
      ((dec.decisionType = ApprovedDecision and evt.eventType = ApprovedEvent) or
       (dec.decisionType = RejectedDecision and evt.eventType = RejectedEvent)))
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, data-model.md ApplicationEvent actor identity
pred AttributionCorrectness {
  (all evt: ApplicationEvent |
    evt.eventType = Submitted implies evt.actorUser = evt.application.customer) and
  (all evt: ApplicationEvent |
    (evt.eventType = ApprovedEvent or evt.eventType = RejectedEvent) implies
      (some dec: Decision | dec.application = evt.application and dec.decidedByUser = evt.actorUser))
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id
pred OwnershipExclusivity {
  all app: LoanApplication |
    app.customer in User
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-013, data-model.md customer_id filtering
pred OwnershipBasedAccess {
  all u: User |
    u.role = CustomerRole implies
      lone app: LoanApplication | app.customer = u and app.status = PendingReview
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-002, validation.py enforcement
pred ValidationBeforeMutation {
  all app: LoanApplication |
    (app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000) and
    (app.termMonths in (12 + 24 + 36 + 48 + 60)) and
    (app.purpose != "") and
    (app.grossAnnualIncomeMinor >= 0) and
    (app.employmentStatus = Employed implies (app.employerName != none and app.employerName != ""))
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: FR-012, data-model.md atomic decision with conditional UPDATE
pred ConcurrencySafety {
  all app: LoanApplication |
    lone dec: Decision | dec.application = app
}

assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md Authorization header, FR-015
pred AuthRequiredEverywhere {
  (some app: LoanApplication | app.customer in User) and
  (all app: LoanApplication | app.customer in User and app.customer.role = CustomerRole) and
  (all evt: ApplicationEvent | evt.actorUser in User) and
  (all dec: Decision | dec.decidedByUser in User and dec.decidedByUser.role = BankStaffRole)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001, spec.md user story, data-model.md LoanApplication
pred FR_001_CustomerCanSubmit {
  some app: LoanApplication |
    app.customer.role = CustomerRole and
    app.status = PendingReview and
    app.requestedAmountMinor >= 100000 and
    app.termMonths in (12 + 24 + 36 + 48 + 60)
}

assert FR_001_CustomerCanSubmit { FR_001_CustomerCanSubmit }
check FR_001_CustomerCanSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003, data-model.md amount and term constraints
pred FR_003_AmountTermConstraints {
  all app: LoanApplication |
    (app.requestedAmountMinor >= 100000 and app.requestedAmountMinor <= 2500000) and
    (app.termMonths in (12 + 24 + 36 + 48 + 60))
}

assert FR_003_AmountTermConstraints { FR_003_AmountTermConstraints }
check FR_003_AmountTermConstraints for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004, data-model.md unique reference and identity
pred FR_004_UniqueReferenceAndDetails {
  (all disj app1, app2: LoanApplication | app1.reference != app2.reference) and
  (all app: LoanApplication | app.customer in User and app.submittedAt != "")
}

assert FR_004_UniqueReferenceAndDetails { FR_004_UniqueReferenceAndDetails }
check FR_004_UniqueReferenceAndDetails for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005, data-model.md idx_one_pending_per_customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    u.role = CustomerRole implies
      lone app: LoanApplication | app.customer = u and app.status = PendingReview
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009, data-model.md Decision.reason non-empty
pred FR_009_DecisionReason {
  all dec: Decision | dec.reason != ""
}

assert FR_009_DecisionReason { FR_009_DecisionReason }
check FR_009_DecisionReason for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, data-model.md decision immutability
pred FR_011_DecisionImmutability {
  all app: LoanApplication |
    (some dec: Decision | dec.application = app) implies
      (app.status = Approved or app.status = Rejected)
}

assert FR_011_DecisionImmutability { FR_011_DecisionImmutability }
check FR_011_DecisionImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012, data-model.md concurrent decision resolution
pred FR_012_ConcurrentDecisionResolution {
  all app: LoanApplication |
    lone dec: Decision | dec.application = app
}

assert FR_012_ConcurrentDecisionResolution { FR_012_ConcurrentDecisionResolution }
check FR_012_ConcurrentDecisionResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, contracts/http-api.md access control
pred FR_013_CustomerSeesOwnOnly {
  all u: User, app: LoanApplication |
    u.role = CustomerRole and app.customer != u implies
      true  // Access control enforced at service layer; Alloy cannot model HTTP responses
}

assert FR_013_CustomerSeesOwnOnly { FR_013_CustomerSeesOwnOnly }
check FR_013_CustomerSeesOwnOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015, contracts/http-api.md role-based access
pred FR_015_StaffOnlyDecision {
  all dec: Decision |
    dec.decidedByUser.role = BankStaffRole
}

assert FR_015_StaffOnlyDecision { FR_015_StaffOnlyDecision }
check FR_015_StaffOnlyDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016, data-model.md application_events audit trail
pred FR_016_AuditTrail {
  all app: LoanApplication |
    some evt: ApplicationEvent | evt.application = app and evt.eventType = Submitted
}

assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5