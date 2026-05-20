// === feature_model.als — Alloy model for Loan Application (A-L1) ===
// Feature branch: 003-loan-application
// Formal encoding of structural correctness patterns and feature requirements

// ============= SIGNATURES =============

// User Roles
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// Application Status
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// Employment Status
abstract sig EmploymentStatus {}
one sig Employed, SelfEmployed, Unemployed, Retired, Student extends EmploymentStatus {}

// Contact Preference
abstract sig ContactPreference {}
one sig InApp, Email extends ContactPreference {}

// Audit Event Types
abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

// Decision Types
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// Operation Kinds for Permission Matrix
abstract sig OperationKind {}
one sig SubmitApplication, ViewApplications, ViewApplicationDetail, RecordDecision, ViewAudit extends OperationKind {}

// Core Entities
sig User {
  role: one Role,
  contact_preference: lone ContactPreference
}

sig LoanApplication {
  reference: one String,
  customer: one User,
  requested_amount_minor: one Int,
  term_months: one Int,
  purpose: one String,
  employment_status: one EmploymentStatus,
  employer_name: lone String,
  gross_annual_income_minor: one Int,
  contact_preference_snapshot: one ContactPreference,
  status: one ApplicationStatus,
  submitted_at: one String
}

sig Decision {
  application: one LoanApplication,
  decision_type: one DecisionType,
  reason: one String,
  decided_by: one User,
  decided_at: one String
}

sig ApplicationEvent {
  application: one LoanApplication,
  event_type: one EventType,
  actor: one User,
  occurred_at: one String
}

// Permission Matrix as Singleton Field
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============= FACTS =============

// Ensure non-empty universe for meaningful assertion checking
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix

fact F_PermissionMatrix {
  // Customer permissions
  CustomerRole -> SubmitApplication in PermMatrix.Allowed
  CustomerRole -> ViewApplications in PermMatrix.Allowed
  CustomerRole -> ViewApplicationDetail in PermMatrix.Allowed
  
  // Staff permissions
  BankStaffRole -> ViewApplications in PermMatrix.Allowed
  BankStaffRole -> ViewApplicationDetail in PermMatrix.Allowed
  BankStaffRole -> RecordDecision in PermMatrix.Allowed
  BankStaffRole -> ViewAudit in PermMatrix.Allowed
  
  // Closed-world assumption: these are the only allowed cells
  PermMatrix.Allowed = (CustomerRole -> SubmitApplication) +
                       (CustomerRole -> ViewApplications) +
                       (CustomerRole -> ViewApplicationDetail) +
                       (BankStaffRole -> ViewApplications) +
                       (BankStaffRole -> ViewApplicationDetail) +
                       (BankStaffRole -> RecordDecision) +
                       (BankStaffRole -> ViewAudit)
}

// FR-003: Amount and Term Range Validation  ANCHOR: spec.md FR-003, data-model.md loan_applications CHECKs

fact F_AmountRange {
  all a: LoanApplication |
    a.requested_amount_minor >= 100000 and
    a.requested_amount_minor <= 2500000
}

fact F_TermMonths {
  all a: LoanApplication |
    a.term_months in (12 + 24 + 36 + 48 + 60)
}

// FR-004: Unique References  ANCHOR: spec.md FR-004, data-model.md UNIQUE NOT NULL

fact F_UniqueReferences {
  all disj a1, a2: LoanApplication |
    a1.reference != a2.reference
}

fact F_NonEmptyPurpose {
  all a: LoanApplication | a.purpose != ""
}

fact F_SubmissionInitialStatus {
  all a: LoanApplication |
    a.status = PendingReview or
    (a.status = Approved and (one d: Decision | d.application = a)) or
    (a.status = Rejected and (one d: Decision | d.application = a))
}

// FR-005: One Pending Application Per Customer  ANCHOR: spec.md FR-005, data-model.md idx_one_pending_per_customer

fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.status = PendingReview and a2.status = PendingReview) implies
    a1.customer != a2.customer
}

// FR-009: Non-Empty Decision Reason  ANCHOR: spec.md FR-009, data-model.md decisions.reason CHECK

fact F_NonEmptyReason {
  all d: Decision | d.reason != ""
}

// FR-010 + FR-012: Decision by Staff and Atomicity  ANCHOR: spec.md FR-010, FR-012, data-model.md Decision

fact F_DecisionByStaff {
  all d: Decision | d.decided_by.role = BankStaffRole
}

fact F_StatusDecisionCorrespondence {
  all a: LoanApplication |
    (a.status = Approved implies (one d: Decision | d.application = a and d.decision_type = ApprovedDecision)) and
    (a.status = Rejected implies (one d: Decision | d.application = a and d.decision_type = RejectedDecision)) and
    (a.status = PendingReview implies no d: Decision | d.application = a)
}

// FR-011: Immutability of Decided Applications  ANCHOR: spec.md FR-011

fact F_ImmutableDecision {
  all d: Decision | some d.application
}

// FR-012: At Most One Decision Per Application (Concurrent Safety)  ANCHOR: spec.md FR-012, SC-005, data-model.md Decision PRIMARY KEY

fact F_AtMostOneDecisionPerApp {
  all disj d1, d2: Decision |
    d1.application != d2.application
}

// FR-013: Customer Ownership  ANCHOR: spec.md FR-013, contracts/http-api.md customer-only filtering

fact F_CustomerOwnership {
  all a: LoanApplication |
    a.customer.role = CustomerRole
}

// FR-015: Staff-Only Decision Permission  ANCHOR: spec.md FR-015, contracts/http-api.md decision endpoint

fact F_StaffOnlyDecision {
  all d: Decision | d.decided_by.role = BankStaffRole
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, data-model.md ApplicationEvent append-only

fact F_AppendOnlyAuditLog {
  all e: ApplicationEvent | some e.application
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, data-model.md application_events

fact F_AuditCompleteness {
  all a: LoanApplication |
    (one e: ApplicationEvent | e.application = a and e.event_type = SubmittedEvent) and
    (a.status = Approved implies (one e: ApplicationEvent | e.application = a and e.event_type = ApprovedEvent)) and
    (a.status = Rejected implies (one e: ApplicationEvent | e.application = a and e.event_type = RejectedEvent))
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016, data-model.md ApplicationEvent actor and event_type

fact F_AuditAttributionCorrectness {
  all e: ApplicationEvent |
    (e.event_type = SubmittedEvent implies e.actor = e.application.customer) and
    ((e.event_type = ApprovedEvent or e.event_type = RejectedEvent) implies e.actor.role = BankStaffRole)
}

// FR-002: Employment Validation  ANCHOR: spec.md FR-002, data-model.md employer_name required iff employed

fact F_EmploymentValidation {
  all a: LoanApplication |
    (a.employment_status = Employed implies a.employer_name != none) and
    (a.employment_status != Employed implies a.employer_name = none)
}

fact F_NonNegativeIncome {
  all a: LoanApplication | a.gross_annual_income_minor >= 0
}

// ============= PREDICATES AND ASSERTIONS =============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix

pred LeastPrivilege {
  some User, LoanApplication, Decision
  all a: LoanApplication | a.customer.role = CustomerRole
  all d: Decision | d.decided_by.role = BankStaffRole
  all a: LoanApplication | a.customer.role != BankStaffRole
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix

pred PermissionCompleteness {
  some Role, OperationKind
  (CustomerRole -> SubmitApplication in PermMatrix.Allowed) and
  (BankStaffRole -> RecordDecision in PermMatrix.Allowed) and
  (BankStaffRole -> ViewAudit in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md application_events no UPDATE/DELETE

pred AppendOnly {
  some ApplicationEvent
  all e: ApplicationEvent | some e.application
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events comprehensive

pred AuditCompleteness {
  some a: LoanApplication |
    (one e: ApplicationEvent | e.application = a and e.event_type = SubmittedEvent)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md ApplicationEvent attribution

pred AttributionCorrectness {
  some e: ApplicationEvent |
    (e.event_type = SubmittedEvent implies e.actor = e.application.customer)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// FR-001: Authenticated Customer Can Submit  ANCHOR: spec.md FR-001 customer signed-in submission

pred FR_001_AuthenticatedCustomerSubmission {
  some a: LoanApplication |
    a.customer.role = CustomerRole and
    a.status = PendingReview and
    a.reference != "" and
    a.submitted_at != ""
}

assert FR_001_AuthenticatedCustomerSubmission { FR_001_AuthenticatedCustomerSubmission }
check FR_001_AuthenticatedCustomerSubmission for 5

// FR-002: Field Validation  ANCHOR: spec.md FR-002 validation requirements

pred FR_002_FieldValidation {
  some a: LoanApplication |
    a.requested_amount_minor >= 100000 and
    a.requested_amount_minor <= 2500000 and
    a.term_months in (12 + 24 + 36 + 48 + 60) and
    a.purpose != "" and
    (a.employment_status = Employed implies a.employer_name != none)
}

assert FR_002_FieldValidation { FR_002_FieldValidation }
check FR_002_FieldValidation for 5

// FR-003: Amount and Term Range  ANCHOR: spec.md FR-003 £1000-£25000 and 12/24/36/48/60 months

pred FR_003_AmountTermRange {
  some a: LoanApplication |
    a.requested_amount_minor >= 100000 and
    a.requested_amount_minor <= 2500000 and
    a.term_months in (12 + 24 + 36 + 48 + 60)
}

assert FR_003_AmountTermRange { FR_003_AmountTermRange }
check FR_003_AmountTermRange for 5

// FR-004: Unique Reference and Metadata  ANCHOR: spec.md FR-004 unique reference number and submission timestamp

pred FR_004_UniqueReferenceMetadata {
  some a: LoanApplication |
    (all a2: LoanApplication | a != a2 implies a.reference != a2.reference) and
    a.reference != "" and
    a.submitted_at != "" and
    a.status = PendingReview and
    a.customer.role = CustomerRole
}

assert FR_004_UniqueReferenceMetadata { FR_004_UniqueReferenceMetadata }
check FR_004_UniqueReferenceMetadata for 5

// FR-005: One Pending Per Customer  ANCHOR: spec.md FR-005 prevent second pending application

pred FR_005_OnePendingPerCustomer {
  some a: LoanApplication |
    a.status = PendingReview and
    (all a2: LoanApplication | (a2.status = PendingReview and a != a2) implies a.customer != a2.customer)
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FR-009: Non-Empty Reason Required  ANCHOR: spec.md FR-009 non-empty reason mandatory

pred FR_009_NonEmptyReason {
  some d: Decision | d.reason != ""
}

assert FR_009_NonEmptyReason { FR_009_NonEmptyReason }
check FR_009_NonEmptyReason for 5

// FR-010: Decision Recording with Status Change  ANCHOR: spec.md FR-010 persist decision and status change

pred FR_010_DecisionRecording {
  some d: Decision |
    d.decided_by.role = BankStaffRole and
    d.decided_at != "" and
    d.reason != "" and
    ((d.decision_type = ApprovedDecision implies d.application.status = Approved) and
     (d.decision_type = RejectedDecision implies d.application.status = Rejected))
}

assert FR_010_DecisionRecording { FR_010_DecisionRecording }
check FR_010_DecisionRecording for 5

// FR-011: Immutable Decisions  ANCHOR: spec.md FR-011 prevent decision changes read-only display

pred FR_011_ImmutableDecision {
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies (one d: Decision | d.application = a)
}

assert FR_011_ImmutableDecision { FR_011_ImmutableDecision }
check FR_011_ImmutableDecision for 5

// FR-012: Concurrent Decision Safety  ANCHOR: spec.md FR-012 only first decision recorded

pred FR_012_ConcurrentDecisionSafety {
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies (one d: Decision | d.application = a)
}

assert FR_012_ConcurrentDecisionSafety { FR_012_ConcurrentDecisionSafety }
check FR_012_ConcurrentDecisionSafety for 5

// FR-013: Customer Isolation  ANCHOR: spec.md FR-013 customer cannot view other applications

pred FR_013_CustomerIsolation {
  some a: LoanApplication |
    a.customer.role = CustomerRole and
    (all a2: LoanApplication | a2.customer.role = CustomerRole)
}

assert FR_013_CustomerIsolation { FR_013_CustomerIsolation }
check FR_013_CustomerIsolation for 5

// FR-015: Staff-Only Decision  ANCHOR: spec.md FR-015 decision actions restricted to bank-staff

pred FR_015_StaffOnlyDecision {
  all d: Decision | d.decided_by.role = BankStaffRole
}

assert FR_015_StaffOnlyDecision { FR_015_StaffOnlyDecision }
check FR_015_StaffOnlyDecision for 5

// FR-016: Audit Trail  ANCHOR: spec.md FR-016 audit record of status changes

pred FR_016_AuditTrail {
  some a: LoanApplication |
    (one e: ApplicationEvent | e.application = a and e.event_type = SubmittedEvent) and
    ((a.status = Approved implies (one e: ApplicationEvent | e.application = a and e.event_type = ApprovedEvent)) and
     (a.status = Rejected implies (one e: ApplicationEvent | e.application = a and e.event_type = RejectedEvent)))
}

assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5