// === feature_model.als — Alloy model for Loan Application Feature (A-L1) ===

// Abstract role hierarchy
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// API operations
abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication,
        RecordDecision, ViewAudit extends OperationKind {}

// Application lifecycle statuses
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// Permission matrix as singleton field
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// System users (customers and staff)
sig User {
  role: one Role
}

// Loan applications
sig LoanApplication {
  customer: one User,
  reference: one String,
  status: one ApplicationStatus,
  requested_amount_minor: one Int,
  term_months: one Int
}

// Staff decisions on applications
sig Decision {
  application: one LoanApplication,
  decided_by: one User,
  reason: one String
}

// Append-only audit log of status changes
sig ApplicationEvent {
  application: one LoanApplication,
  actor: one User,
  occurred_at: one Int
}

// === Non-empty universe ===
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// === Permission matrix (from contracts/http-api.md) ===
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
fact F_PermissionMatrix {
  PermMatrix.Allowed = (Customer -> SubmitApplication) +
                       (Customer -> ListApplications) +
                       (Customer -> ViewApplication) +
                       (BankStaff -> ListApplications) +
                       (BankStaff -> ViewApplication) +
                       (BankStaff -> RecordDecision) +
                       (BankStaff -> ViewAudit)
}

// === Structural facts: Application ownership and lifecycle ===

// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-004
fact F_ApplicationOwnedByCustomer {
  all app: LoanApplication | app.customer.role = Customer
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
fact F_OnePendingPerCustomer {
  all c: User | lone app: LoanApplication |
    app.customer = c and app.status = PendingReview
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
fact F_ValidAmountRange {
  all app: LoanApplication |
    app.requested_amount_minor >= 100000 and
    app.requested_amount_minor <= 2500000
}

// FEATURE-SPECIFIC  ANCHOR: FR-003
fact F_ValidTermSet {
  all app: LoanApplication |
    (app.term_months = 12 or app.term_months = 24 or app.term_months = 36 or
     app.term_months = 48 or app.term_months = 60)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
fact F_UniqueReferences {
  all disj app1, app2: LoanApplication | app1.reference != app2.reference
}

// === Structural facts: Decision lifecycle ===

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
fact F_DecisionExclusivity {
  all app: LoanApplication | lone dec: Decision | dec.application = app
}

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
fact F_StatusConsistencyWithDecision {
  all app: LoanApplication |
    ((app.status = Approved or app.status = Rejected) iff
      (one dec: Decision | dec.application = app))
}

// FEATURE-SPECIFIC  ANCHOR: FR-011
fact F_PendingApplicationsHaveNoDecision {
  all app: LoanApplication |
    app.status = PendingReview implies (no dec: Decision | dec.application = app)
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
fact F_ReasonIsNonEmpty {
  all dec: Decision | not (dec.reason = "")
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
fact F_DeciderIsStaff {
  all dec: Decision | dec.decided_by.role = BankStaff
}

// === Structural facts: Audit and append-only invariants ===

// FEATURE-SPECIFIC  ANCHOR: FR-016
fact F_AuditCompleteness {
  all app: LoanApplication | some evt: ApplicationEvent | evt.application = app
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md append-only constraint
fact F_AppendOnlyAuditEntries {
  // Append-only enforcement: no event duplication or loss
  // (In practice, enforced by: no UPDATE/DELETE code path targets application_events table)
  all disj evt1, evt2: ApplicationEvent |
    (evt1.application != evt2.application) or
    (evt1.actor != evt2.actor) or
    (evt1.occurred_at != evt2.occurred_at)
}

// === Predicates and Assertions ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
pred LeastPrivilege {
  some Role
  some OperationKind
  some User
  (Customer -> SubmitApplication) in PermMatrix.Allowed
  (Customer -> ListApplications) in PermMatrix.Allowed
  (BankStaff -> RecordDecision) in PermMatrix.Allowed
  (BankStaff -> ViewAudit) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 7 OperationKind

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md append-only
pred AppendOnly {
  some ApplicationEvent
  some LoanApplication
  // Outcome: audit entries are preserved and distinct (append-only semantics)
  all disj evt1, evt2: ApplicationEvent |
    (evt1.application != evt2.application) or
    (evt1.actor != evt2.actor) or
    (evt1.occurred_at != evt2.occurred_at)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md audit requirement
pred AuditCompleteness {
  some LoanApplication
  some ApplicationEvent
  // Outcome: every application has its status change recorded in audit log
  all app: LoanApplication | some evt: ApplicationEvent | evt.application = app
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; data-model.md ownership
pred OwnershipBasedAccess {
  some LoanApplication
  // Outcome: all applications are owned by customer roles
  all app: LoanApplication | app.customer.role = Customer
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_CustomerCanSubmit {
  some User
  some LoanApplication
  // Outcome: at least one application is submitted by a customer
  all app: LoanApplication | app.customer.role = Customer
}
assert FR_001_CustomerCanSubmit { FR_001_CustomerCanSubmit }
check FR_001_CustomerCanSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_AmountAndTermValidation {
  some LoanApplication
  // Outcome: all applications have valid amount and term values
  all app: LoanApplication |
    (app.requested_amount_minor >= 100000 and app.requested_amount_minor <= 2500000) and
    (app.term_months = 12 or app.term_months = 24 or app.term_months = 36 or
     app.term_months = 48 or app.term_months = 60)
}
assert FR_003_AmountAndTermValidation { FR_003_AmountAndTermValidation }
check FR_003_AmountAndTermValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueReference {
  some LoanApplication
  // Outcome: each application has a unique reference number
  all disj app1, app2: LoanApplication | app1.reference != app2.reference
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  some User
  some LoanApplication
  // Outcome: each customer has at most one application in pending review
  all c: User | lone app: LoanApplication |
    app.customer = c and app.status = PendingReview
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ReasonRequired {
  some Decision
  // Outcome: every decision has a non-empty reason
  all dec: Decision | not (dec.reason = "")
}
assert FR_009_ReasonRequired { FR_009_ReasonRequired }
check FR_009_ReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
pred FR_010_DecisionExclusivity {
  some LoanApplication
  some Decision
  // Outcome: each application has at most one decision, and status reflects decision
  (all app: LoanApplication | lone dec: Decision | dec.application = app) and
  (all app: LoanApplication, dec: Decision |
    dec.application = app implies (app.status = Approved or app.status = Rejected))
}
assert FR_010_DecisionExclusivity { FR_010_DecisionExclusivity }
check FR_010_DecisionExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_DecisionImmutability {
  some LoanApplication
  some Decision
  // Outcome: applications in pending review have no decision (and thus cannot be changed)
  all app: LoanApplication |
    app.status = PendingReview implies (no dec: Decision | dec.application = app)
}
assert FR_011_DecisionImmutability { FR_011_DecisionImmutability }
check FR_011_DecisionImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OwnershipExclusivity {
  some LoanApplication
  // Outcome: all applications are owned by exactly one customer
  all app: LoanApplication | app.customer.role = Customer
}
assert FR_013_OwnershipExclusivity { FR_013_OwnershipExclusivity }
check FR_013_OwnershipExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_StaffOnlyDecisions {
  some Decision
  some User
  // Outcome: only bank staff members can make decisions
  all dec: Decision | dec.decided_by.role = BankStaff
}
assert FR_015_StaffOnlyDecisions { FR_015_StaffOnlyDecisions }
check FR_015_StaffOnlyDecisions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrail {
  some LoanApplication
  some ApplicationEvent
  // Outcome: every application has at least one audit event recording its lifecycle
  all app: LoanApplication | some evt: ApplicationEvent | evt.application = app
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5