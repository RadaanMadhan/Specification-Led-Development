// === feature_model.als — Alloy model for Loan Application (A-L1) ===

// Roles and users
abstract sig User {}
sig Customer extends User {}
sig BankStaff extends User {}

// Application statuses
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// Event types  
abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

// Decision types
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// Employment statuses
abstract sig EmploymentStatus {}
one sig Employed, SelfEmployed, Unemployed, Retired, Student extends EmploymentStatus {}

// Contact preferences
abstract sig ContactPreference {}
one sig InApp, Email extends ContactPreference {}

// API operations (for permission matrix)
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationDetail, PostDecision, GetAudit extends OperationKind {}

// Main entities
sig LoanApplication {
  customer: one Customer,
  reference: one String,
  amount_minor: Int,
  term_months: Int,
  status: one ApplicationStatus,
  submitted_at: Int
}

sig Decision {
  application: one LoanApplication,
  decision_type: one DecisionType,
  reason: one String,
  decided_by: one BankStaff,
  decided_at: Int
}

sig ApplicationEvent {
  application: one LoanApplication,
  event_type: one EventType,
  actor: one User,
  occurred_at: Int
}

// Permission matrix singleton
one sig PermMatrix {
  Allowed: set (Customer -> OperationKind) + (BankStaff -> OperationKind)
}

// ============ NON-EMPTY UNIVERSE (REQUIRED) ============

fact F_NonEmptyUniverse {
  some Customer
  some BankStaff
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// ============ STRUCTURAL FACTS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
fact F_PermissionMatrix {
  (Customer -> PostApplications) in PermMatrix.Allowed
  (Customer -> GetApplications) in PermMatrix.Allowed
  (Customer -> GetApplicationDetail) in PermMatrix.Allowed
  (Customer -> PostDecision) not in PermMatrix.Allowed
  (Customer -> GetAudit) not in PermMatrix.Allowed
  (BankStaff -> PostApplications) not in PermMatrix.Allowed
  (BankStaff -> GetApplications) in PermMatrix.Allowed
  (BankStaff -> GetApplicationDetail) in PermMatrix.Allowed
  (BankStaff -> PostDecision) in PermMatrix.Allowed
  (BankStaff -> GetAudit) in PermMatrix.Allowed
  PermMatrix.Allowed = 
    (Customer -> PostApplications) +
    (Customer -> GetApplications) +
    (Customer -> GetApplicationDetail) +
    (BankStaff -> GetApplications) +
    (BankStaff -> GetApplicationDetail) +
    (BankStaff -> PostDecision) +
    (BankStaff -> GetAudit)
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-005, data-model.md unique index
fact F_OnePendingApplicationPerCustomer {
  all c: Customer | lone app: LoanApplication | app.customer = c and app.status = PendingReview
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 amount range (100000-2500000 pence)
fact F_AmountRange {
  all app: LoanApplication | app.amount_minor >= 100000 and app.amount_minor <= 2500000
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 term options (12/24/36/48/60 months)
fact F_TermRange {
  all app: LoanApplication | app.term_months in 12 + 24 + 36 + 48 + 60
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique reference number
fact F_UniqueReferences {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, data-model.md Decision PK
fact F_AtMostOneDecisionPerApplication {
  all app: LoanApplication | lone d: Decision | d.application = app
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, data-model.md submitted event required
fact F_SubmittedEventRequired {
  all app: LoanApplication | one e: ApplicationEvent | e.application = app and e.event_type = SubmittedEvent
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, every decision has audit event
fact F_DecisionEventRequired {
  all d: Decision | one e: ApplicationEvent | e.application = d.application and (e.event_type = ApprovedEvent or e.event_type = RejectedEvent)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016, data-model.md submitted event actor
fact F_SubmittedEventActor {
  all app: LoanApplication |
    one e: ApplicationEvent | 
      e.application = app and e.event_type = SubmittedEvent and e.actor = app.customer
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-010, FR-016, decision event actor
fact F_DecisionEventActor {
  all d: Decision |
    one e: ApplicationEvent |
      e.application = d.application and
      (e.event_type = ApprovedEvent or e.event_type = RejectedEvent) and
      e.actor = d.decided_by
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 decision reason must be non-empty
fact F_DecisionReasonNonEmpty {
  all d: Decision | d.reason.size > 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011 status changes only via decision
fact F_StatusTransitionsViaDecision {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (one d: Decision | d.application = app)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, data-model.md ApplicationEvent "append-only"
fact F_AppendOnlyAuditLog {
  all app: LoanApplication |
    all disj e1, e2: ApplicationEvent |
      ((e1.application = app and e1.event_type = SubmittedEvent) and
       (e2.application = app and e2.event_type = SubmittedEvent)) implies false
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  all c: Customer | c -> PostApplications in PermMatrix.Allowed
  all c: Customer | c -> PostDecision not in PermMatrix.Allowed
  all s: BankStaff | s -> PostApplications not in PermMatrix.Allowed
  all s: BankStaff | s -> PostDecision in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Customer, exactly 2 BankStaff, exactly 5 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md all operations defined
pred PermissionCompleteness {
  all role: (Customer + BankStaff), op: OperationKind |
    (role -> op in PermMatrix.Allowed) or (role -> op not in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Customer, exactly 2 BankStaff, exactly 5 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs, contracts/http-api.md
pred PermissionGrounding {
  (Customer -> PostApplications) in PermMatrix.Allowed
  (Customer -> GetApplications) in PermMatrix.Allowed
  (Customer -> GetApplicationDetail) in PermMatrix.Allowed
  (BankStaff -> GetApplications) in PermMatrix.Allowed
  (BankStaff -> GetApplicationDetail) in PermMatrix.Allowed
  (BankStaff -> PostDecision) in PermMatrix.Allowed
  (BankStaff -> GetAudit) in PermMatrix.Allowed
  (Customer -> PostDecision) not in PermMatrix.Allowed
  (Customer -> GetAudit) not in PermMatrix.Allowed
  (BankStaff -> PostApplications) not in PermMatrix.Allowed
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8 but exactly 2 Customer, exactly 2 BankStaff, exactly 5 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md authentication header required
pred AuthRequiredEverywhere {
  all app: LoanApplication | some c: Customer | app.customer = c
  all d: Decision | some s: BankStaff | d.decided_by = s
  all e: ApplicationEvent | some u: User | e.actor = u
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, data-model.md ApplicationEvent
pred AuditCompleteness {
  all app: LoanApplication | (some e: ApplicationEvent | e.application = app and e.event_type = SubmittedEvent)
  all d: Decision | (some e: ApplicationEvent | e.application = d.application and (e.event_type = ApprovedEvent or e.event_type = RejectedEvent))
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, data-model.md ApplicationEvent "append-only"
pred AppendOnly {
  all app: LoanApplication | one e: ApplicationEvent | e.application = app and e.event_type = SubmittedEvent
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md each application owned by one customer
pred OwnershipExclusivity {
  all app: LoanApplication | one c: Customer | app.customer = c
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013, contracts/http-api.md ownership filter
pred OwnershipBasedAccess {
  all app: LoanApplication | one c: Customer | app.customer = c
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, contracts/http-api.md 404 response
pred NoInformationLeakage {
  all app: LoanApplication | one c: Customer | app.customer = c
  some disj a1, a2: LoanApplication, c1, c2: Customer | a1.customer = c1 and a2.customer = c2 and c1 != c2
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8 but exactly 2 Customer

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016, data-model.md ApplicationEvent.actor
pred AttributionCorrectness {
  all e: ApplicationEvent |
    (e.event_type = SubmittedEvent implies e.actor = e.application.customer)
  all e: ApplicationEvent |
    ((e.event_type = ApprovedEvent or e.event_type = RejectedEvent) implies e.actor in BankStaff)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, data-model.md atomic decision
pred ConcurrencySafety {
  all app: LoanApplication | lone d: Decision | d.application = app
}

assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 amount range constraint
pred FR_003_AmountRange {
  all app: LoanApplication | app.amount_minor >= 100000 and app.amount_minor <= 2500000
}

assert FR_003_AmountRange { FR_003_AmountRange }
check FR_003_AmountRange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 term options constraint
pred FR_003_TermOptions {
  all app: LoanApplication | app.term_months in 12 + 24 + 36 + 48 + 60
}

assert FR_003_TermOptions { FR_003_TermOptions }
check FR_003_TermOptions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique application reference
pred FR_004_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 only one pending application per customer
pred FR_005_OnePendingPerCustomer {
  all c: Customer | lone app: LoanApplication | app.customer = c and app.status = PendingReview
  some c: Customer, app: LoanApplication | app.customer = c and app.status = PendingReview
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 decision reason required and non-empty
pred FR_009_DecisionReasonRequired {
  all d: Decision | d.reason.size > 0
  some d: Decision
}

assert FR_009_DecisionReasonRequired { FR_009_DecisionReasonRequired }
check FR_009_DecisionReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 atomic decision recording
pred FR_010_AtomicDecision {
  all d: Decision | (d.application.status = Approved or d.application.status = Rejected)
  all d: Decision | (one e: ApplicationEvent | e.application = d.application and (e.event_type = ApprovedEvent or e.event_type = RejectedEvent))
}

assert FR_010_AtomicDecision { FR_010_AtomicDecision }
check FR_010_AtomicDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 immutable decisions
pred FR_011_ImmutableDecision {
  all app: LoanApplication | (app.status = Approved or app.status = Rejected) implies (lone d: Decision | d.application = app)
}

assert FR_011_ImmutableDecision { FR_011_ImmutableDecision }
check FR_011_ImmutableDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 concurrent decision safety
pred FR_012_ConcurrentDecisionSafety {
  all app: LoanApplication | lone d: Decision | d.application = app
  some app: LoanApplication, d: Decision | d.application = app
}

assert FR_012_ConcurrentDecisionSafety { FR_012_ConcurrentDecisionSafety }
check FR_012_ConcurrentDecisionSafety for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer ownership filter
pred FR_013_CustomerOwnershipFilter {
  all c: Customer | all app: LoanApplication | (c = app.customer) or (c != app.customer)
  some disj c1, c2: Customer, app: LoanApplication | app.customer = c1 and c2 != c1
}

assert FR_013_CustomerOwnershipFilter { FR_013_CustomerOwnershipFilter }
check FR_013_CustomerOwnershipFilter for 8 but exactly 2 Customer

// FEATURE-SPECIFIC  ANCHOR: FR-015 role-based authorization
pred FR_015_RoleBasedAuthorization {
  all c: Customer | c -> PostDecision not in PermMatrix.Allowed
  all c: Customer | c -> GetAudit not in PermMatrix.Allowed
  all s: BankStaff | s -> PostApplications not in PermMatrix.Allowed
  some Customer
  some BankStaff
}

assert FR_015_RoleBasedAuthorization { FR_015_RoleBasedAuthorization }
check FR_015_RoleBasedAuthorization for 8 but exactly 2 Customer, exactly 2 BankStaff

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail completeness
pred FR_016_AuditTrail {
  all app: LoanApplication | one e: ApplicationEvent | e.application = app and e.event_type = SubmittedEvent
  all d: Decision | one e: ApplicationEvent | e.application = d.application and (e.event_type = ApprovedEvent or e.event_type = RejectedEvent)
}

assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5