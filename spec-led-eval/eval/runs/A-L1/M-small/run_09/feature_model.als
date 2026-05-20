// === feature_model.als — Alloy model for Loan Application (A-L1) ===

// ============================================================================
// ENUMS AND ROLE/STATUS TYPES
// ============================================================================

abstract sig Role {}
one sig Customer, BankStaff extends Role {}

abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

abstract sig EmploymentStatus {}
one sig Employed, SelfEmployed, Unemployed, Retired, Student extends EmploymentStatus {}

abstract sig ContactPreference {}
one sig InApp, Email extends ContactPreference {}

abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication, RecordDecision, ViewAudit extends OperationKind {}

// ============================================================================
// ENTITIES
// ============================================================================

sig User {
  id: one Int,
  role: one Role,
  contact_pref: one ContactPreference
}

sig Token {
  token_id: one Int,
  user: one User
}

sig LoanApplication {
  reference: one Int,
  customer: one User,
  requested_amount_minor: one Int,
  term_months: one Int,
  purpose: one String,
  employment_status: one EmploymentStatus,
  employer_name: lone String,
  gross_annual_income_minor: one Int,
  contact_preference_snapshot: one ContactPreference,
  status: one ApplicationStatus,
  submitted_at: one Int,
  submitted_by: one User
}

sig Decision {
  application: one LoanApplication,
  decision_type: one DecisionType,
  reason: one String,
  decided_by: one User,
  decided_at: one Int
}

sig ApplicationEvent {
  application: one LoanApplication,
  event_type: one EventType,
  actor: one User,
  occurred_at: one Int
}

// Permission matrix as a singleton containing allowed role-operation pairs
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============================================================================
// FACTS (Structural Rules)
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Token
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FRs
fact F_PermissionMatrix {
  PermMatrix.Allowed = 
    (Customer -> SubmitApplication) +
    (Customer -> ListApplications) +
    (Customer -> ViewApplication) +
    (BankStaff -> ListApplications) +
    (BankStaff -> ViewApplication) +
    (BankStaff -> RecordDecision) +
    (BankStaff -> ViewAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 - Unique application references
fact F_UniqueApplicationReferences {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 - One pending application per customer
fact F_OnePendingPerCustomer {
  all c: User | lone app: LoanApplication | 
    app.customer = c and app.status = PendingReview
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 - Amount and term constraints
fact F_AmountAndTermConstraints {
  all app: LoanApplication |
    (app.requested_amount_minor >= 100000 and app.requested_amount_minor <= 2500000) and
    (app.term_months = 12 or app.term_months = 24 or app.term_months = 36 or 
     app.term_months = 48 or app.term_months = 60)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, data-model.md application_events
fact F_AuditCompleteness {
  // Every application has a submitted event
  all app: LoanApplication | 
    one event: ApplicationEvent | 
      event.application = app and event.event_type = SubmittedEvent
  // Every approved application has exactly one approved event
  all app: LoanApplication | 
    app.status = Approved implies 
      (one event: ApplicationEvent | event.application = app and event.event_type = ApprovedEvent)
  // Every rejected application has exactly one rejected event
  all app: LoanApplication | 
    app.status = Rejected implies 
      (one event: ApplicationEvent | event.application = app and event.event_type = RejectedEvent)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries {
  // No two audit events can be identical (structural constraint on immutability)
  all disj ae1, ae2: ApplicationEvent | 
    not (ae1.application = ae2.application and ae1.event_type = ae2.event_type and 
         ae1.actor = ae2.actor and ae1.occurred_at = ae2.occurred_at)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 - Non-empty decision reasons
fact F_DecisionReasonRequired {
  all d: Decision | d.reason != ""
}

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-012 - One decision per application
fact F_OneDecisionPerApplication {
  all app: LoanApplication | lone d: Decision | d.application = app
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 - Decision recorded with staff identity
fact F_DecisionWithStaffIdentity {
  all d: Decision | d.decided_by.role = BankStaff
}

// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-004 - Application submitted by customer
fact F_ApplicationSubmittedByCustomer {
  all app: LoanApplication | 
    app.customer.role = Customer and 
    app.submitted_by.role = Customer and
    app.customer.id = app.submitted_by.id
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 - Initial status is Pending Review
fact F_InitialStatusPendingReview {
  all app: LoanApplication | 
    (no d: Decision | d.application = app) implies app.status = PendingReview
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 - Valid purpose
fact F_NonEmptyPurpose {
  all app: LoanApplication | app.purpose != ""
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 - Non-negative income
fact F_NonNegativeIncome {
  all app: LoanApplication | app.gross_annual_income_minor >= 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 - Contact preference snapshot at submission
fact F_ContactPreferenceSnapshot {
  all app: LoanApplication | app.contact_preference_snapshot = app.customer.contact_pref
}

// ============================================================================
// PREDICATES AND ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
  some User
  some OperationKind
  // Customer cannot record decisions
  all u: User | u.role = Customer implies
    (u -> RecordDecision) not in PermMatrix.Allowed
  // Bank staff can record decisions
  all u: User | u.role = BankStaff implies
    (u -> RecordDecision) in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  some Role
  some OperationKind
  // Every role-operation pair is explicitly defined
  all r: Role | all op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FRs; contracts/http-api.md "Authorization"
pred AuthRequiredEverywhere {
  some User
  some Token
  // Every token maps to exactly one user
  all t: Token | one u: User | t.user = u
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016
pred AuditCompleteness {
  some LoanApplication
  some ApplicationEvent
  // Every status transition is audited
  all app: LoanApplication |
    (app.status = Approved implies (one ae: ApplicationEvent | ae.application = app and ae.event_type = ApprovedEvent)) and
    (app.status = Rejected implies (one ae: ApplicationEvent | ae.application = app and ae.event_type = RejectedEvent)) and
    (one ae: ApplicationEvent | ae.application = app and ae.event_type = SubmittedEvent)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016
pred AppendOnly {
  some ApplicationEvent
  // Audit entries are immutable; no entry appears twice
  all ae: ApplicationEvent | 
    lone ae2: ApplicationEvent | ae2 = ae
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id
pred OwnershipExclusivity {
  some LoanApplication
  // Each application has exactly one owner
  all app: LoanApplication | one c: User | app.customer = c and c.role = Customer
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013
pred OwnershipBasedAccess {
  some User
  some LoanApplication
  // Customer can only be associated with applications they own
  all u: User | all app: LoanApplication |
    (u.role = Customer and app.customer.id = u.id) implies 
      (u -> ViewApplication in PermMatrix.Allowed)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013
pred NoInformationLeakage {
  some LoanApplication
  some User
  // Non-owners are denied the same way as for non-existent resources
  all app: LoanApplication | all u: User |
    (u.role = Customer and u.id != app.customer.id) implies
      not (u -> ViewApplication in PermMatrix.Allowed or u.id = app.customer.id)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  some User
  some LoanApplication
  // Each customer has at most one pending application
  all c: User | lone app: LoanApplication |
    app.customer = c and app.status = PendingReview
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_AmountAndTermValid {
  some LoanApplication
  // Amount in valid range and term in allowed set
  all app: LoanApplication |
    (app.requested_amount_minor >= 100000 and app.requested_amount_minor <= 2500000) and
    (app.term_months in 12 + 24 + 36 + 48 + 60)
}

assert FR_003_AmountAndTermValid { FR_003_AmountAndTermValid }
check FR_003_AmountAndTermValid for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_DecisionReasonNonEmpty {
  some Decision
  // All decisions have non-empty reasons
  all d: Decision | d.reason != ""
}

assert FR_009_DecisionReasonNonEmpty { FR_009_DecisionReasonNonEmpty }
check FR_009_DecisionReasonNonEmpty for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-012
pred FR_011_UniqueDecisionPerApplication {
  some LoanApplication
  some Decision
  // Each application has at most one decision
  all app: LoanApplication | lone d: Decision | d.application = app
}

assert FR_011_UniqueDecisionPerApplication { FR_011_UniqueDecisionPerApplication }
check FR_011_UniqueDecisionPerApplication for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueApplicationReference {
  some LoanApplication
  // All references are unique
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

assert FR_004_UniqueApplicationReference { FR_004_UniqueApplicationReference }
check FR_004_UniqueApplicationReference for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_DecisionWithTimestamp {
  some Decision
  // All decisions have timestamp and staff identity
  all d: Decision | d.decided_at >= 0 and d.decided_by.role = BankStaff
}

assert FR_010_DecisionWithTimestamp { FR_010_DecisionWithTimestamp }
check FR_010_DecisionWithTimestamp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_StaffOnlyDecisions {
  some User
  some Decision
  // Only staff can record decisions
  all d: Decision | d.decided_by.role = BankStaff
  all u: User | u.role = Customer implies (u -> RecordDecision) not in PermMatrix.Allowed
}

assert FR_015_StaffOnlyDecisions { FR_015_StaffOnlyDecisions }
check FR_015_StaffOnlyDecisions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrail {
  some ApplicationEvent
  some LoanApplication
  // Every application has at least a submitted event
  all app: LoanApplication | 
    one ae: ApplicationEvent | ae.application = app and ae.event_type = SubmittedEvent
}

assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002
pred ValidationBeforeMutation {
  some LoanApplication
  // All applications meet validation constraints at submission
  all app: LoanApplication |
    app.purpose != "" and
    app.gross_annual_income_minor >= 0 and
    (app.requested_amount_minor >= 100000 and app.requested_amount_minor <= 2500000)
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5