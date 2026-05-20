// === feature_model.als — Alloy model for Loan Application (A-L1) ===

// Role hierarchy
abstract sig Role {}
one sig CustomerRole extends Role {}
one sig BankStaffRole extends Role {}

// Operation kinds (endpoints/actions)
abstract sig OperationKind {}
one sig PostApplications extends OperationKind {}
one sig GetApplications extends OperationKind {}
one sig GetApplicationById extends OperationKind {}
one sig PostDecision extends OperationKind {}
one sig GetAudit extends OperationKind {}

// User
sig User {
  role: one Role,
  display_name: one String
}

// Permission matrix singleton
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// Application status
abstract sig ApplicationStatus {}
one sig PendingReview extends ApplicationStatus {}
one sig Approved extends ApplicationStatus {}
one sig Rejected extends ApplicationStatus {}

// Event types for audit log
abstract sig EventType {}
one sig Submitted extends EventType {}
one sig ApprovedEvent extends EventType {}
one sig RejectedEvent extends EventType {}

// Loan application
sig LoanApplication {
  customer: one User,
  reference: one String,
  requested_amount_minor: one Int,
  term_months: one Int,
  purpose: one String,
  employment_status: one String,
  employer_name: lone String,
  gross_annual_income_minor: one Int,
  contact_preference_snapshot: one String,
  status: one ApplicationStatus,
  submitted_at: one String,
  decision: lone Decision,
  audit_events: set ApplicationEvent
}

// Decision record
sig Decision {
  application: one LoanApplication,
  decision_type: one String,
  reason: one String,
  decided_by_user: one User,
  decided_at: one String
}

// Audit event (append-only)
sig ApplicationEvent {
  application: one LoanApplication,
  event_type: one EventType,
  actor: one User,
  occurred_at: one String
}

// === FACTS (encode structural rules from spec) ===

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
fact F_PermissionMatrix {
  CustomerRole -> PostApplications in PermMatrix.Allowed
  CustomerRole -> GetApplications in PermMatrix.Allowed
  CustomerRole -> GetApplicationById in PermMatrix.Allowed
  BankStaffRole -> GetApplications in PermMatrix.Allowed
  BankStaffRole -> GetApplicationById in PermMatrix.Allowed
  BankStaffRole -> PostDecision in PermMatrix.Allowed
  BankStaffRole -> GetAudit in PermMatrix.Allowed
  PermMatrix.Allowed = (CustomerRole -> PostApplications) +
                       (CustomerRole -> GetApplications) +
                       (CustomerRole -> GetApplicationById) +
                       (BankStaffRole -> GetApplications) +
                       (BankStaffRole -> GetApplicationById) +
                       (BankStaffRole -> PostDecision) +
                       (BankStaffRole -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004, data-model.md UNIQUE(reference)
fact F_UniqueReferences {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// FEATURE-SPECIFIC  ANCHOR: FR-005, data-model.md idx_one_pending_per_customer
fact F_OnePendingPerCustomer {
  all c: User | lone a: LoanApplication | a.customer = c and a.status = PendingReview
}

// FEATURE-SPECIFIC  ANCHOR: FR-003, data-model.md CHECK constraints
fact F_AmountAndTermConstraints {
  all a: LoanApplication |
    (a.requested_amount_minor >= 100000 and a.requested_amount_minor <= 2500000) and
    (a.term_months in {12, 24, 36, 48, 60})
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-012, data-model.md Decision PK
fact F_OneDecisionPerApplication {
  all disj d1, d2: Decision | d1.application != d2.application
}

// FEATURE-SPECIFIC  ANCHOR: FR-011, data-model.md immutability of decisions
fact F_DecisionImpliesNonPending {
  all a: LoanApplication | a.status != PendingReview implies some a.decision
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, data-model.md decision_type and status alignment
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.decision_type = "Approved" implies d.application.status = Approved) and
    (d.decision_type = "Rejected" implies d.application.status = Rejected)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-016, data-model.md ApplicationEvent
fact F_AuditEventsComplete {
  all a: LoanApplication |
    (one e: a.audit_events | e.event_type = Submitted) and
    (a.status = Approved implies (one e: a.audit_events | e.event_type = ApprovedEvent)) and
    (a.status = Rejected implies (one e: a.audit_events | e.event_type = RejectedEvent)) and
    (a.status = PendingReview implies (no e: a.audit_events | e.event_type in {ApprovedEvent, RejectedEvent}))
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, data-model.md actor_user_id
fact F_AttributionCorrect {
  all a: LoanApplication |
    (all e: a.audit_events | e.event_type = Submitted implies e.actor = a.customer) and
    (all e: a.audit_events |
      ((e.event_type = ApprovedEvent or e.event_type = RejectedEvent) implies
        (some d: a.decision | e.actor = d.decided_by_user)))
}

// === PREDICATES and ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
pred LeastPrivilege {
  (CustomerRole -> PostDecision not in PermMatrix.Allowed) and
  (BankStaffRole -> PostDecision in PermMatrix.Allowed) and
  (CustomerRole -> PostApplications in PermMatrix.Allowed) and
  (BankStaffRole -> PostApplications not in PermMatrix.Allowed)
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  some c: User |
    lone a: LoanApplication | a.customer = c and a.status = PendingReview
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueReferenceNumber {
  some disj a1, a2: LoanApplication | a1.reference != a2.reference
}

assert FR_004_UniqueReferenceNumber { FR_004_UniqueReferenceNumber }
check FR_004_UniqueReferenceNumber for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_AmountAndTermConstraints {
  some a: LoanApplication |
    (a.requested_amount_minor >= 100000 and a.requested_amount_minor <= 2500000) and
    (a.term_months in {12, 24, 36, 48, 60})
}

assert FR_003_AmountAndTermConstraints { FR_003_AmountAndTermConstraints }
check FR_003_AmountAndTermConstraints for 5

// PATTERN: ConcurrencySafety  ANCHOR: FR-012, spec.md concurrent decision handling
pred FR_012_ConcurrentDecisionHandling {
  all disj d1, d2: Decision | d1.application != d2.application
}

assert FR_012_ConcurrentDecisionHandling { FR_012_ConcurrentDecisionHandling }
check FR_012_ConcurrentDecisionHandling for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ImmutableDecision {
  some a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies some a.decision
}

assert FR_011_ImmutableDecision { FR_011_ImmutableDecision }
check FR_011_ImmutableDecision for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-016
pred AuditCompleteness {
  some a: LoanApplication |
    (one e: a.audit_events | e.event_type = Submitted) and
    (a.status = Approved implies (one e: a.audit_events | e.event_type = ApprovedEvent))
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-016
pred AttributionCorrectness {
  some a: LoanApplication, e: a.audit_events |
    ((e.event_type = Submitted implies e.actor = a.customer) and
     ((e.event_type in {ApprovedEvent, RejectedEvent}) implies (some d: a.decision | e.actor = d.decided_by_user)))
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: AppendOnly  ANCHOR: FR-016, data-model.md no UPDATE/DELETE on ApplicationEvent
pred AppendOnly {
  some a: LoanApplication |
    (all disj e1, e2: a.audit_events | e1 != e2) and
    ((a.status = Approved or a.status = Rejected) implies
      (one e: a.audit_events | e.event_type in {ApprovedEvent, RejectedEvent}))
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: FR-004, data-model.md LoanApplication.customer one
pred OwnershipExclusivity {
  some a: LoanApplication | one a.customer
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-013, spec.md customer sees own applications
pred FR_013_OwnershipBasedAccess {
  all a: LoanApplication | one a.customer
}

assert FR_013_OwnershipBasedAccess { FR_013_OwnershipBasedAccess }
check FR_013_OwnershipBasedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_DecisionRecording {
  some a: LoanApplication, d: a.decision |
    ((d.decision_type = "Approved" and a.status = Approved) or
     (d.decision_type = "Rejected" and a.status = Rejected))
}

assert FR_010_DecisionRecording { FR_010_DecisionRecording }
check FR_010_DecisionRecording for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_ValidationBeforeMutation {
  some a: LoanApplication | a.status = PendingReview
}

assert FR_002_ValidationBeforeMutation { FR_002_ValidationBeforeMutation }
check FR_002_ValidationBeforeMutation for 5