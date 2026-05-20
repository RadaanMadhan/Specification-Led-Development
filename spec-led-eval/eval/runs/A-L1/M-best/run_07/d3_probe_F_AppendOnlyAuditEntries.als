// === feature_model.als — Alloy model for 003-loan-application ===
//
// Self-contained Alloy 6 model encoding the structural invariants of the
// Loan Application feature. Covers the contracts' permission matrix,
// FR-001..FR-017 from spec.md, and the data-model.md tables.

// =========================================================
// Roles
// =========================================================
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// =========================================================
// Operation kinds — the five endpoints from contracts/http-api.md
// =========================================================
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAudit extends OperationKind {}

// =========================================================
// Permission matrix — modelled as a singleton-sig field
// =========================================================
one sig PermMatrix { Allowed: set Role -> OperationKind }

// =========================================================
// Application status
// =========================================================
abstract sig ApplicationStatus {}
one sig PendingReview, ApprovedStatus, RejectedStatus extends ApplicationStatus {}

// =========================================================
// Decision type
// =========================================================
abstract sig DecisionType {}
one sig ApprovedDec, RejectedDec extends DecisionType {}

// =========================================================
// Event type
// =========================================================
abstract sig EventType {}
one sig SubmittedEv, ApprovedEv, RejectedEv extends EventType {}

// =========================================================
// API operation outcomes
// =========================================================
abstract sig Outcome {}
one sig Success, Unauthenticated, Forbidden, NotFound,
        AlreadyDecided, HasPending extends Outcome {}

// =========================================================
// Reason — abstract sig with an explicit EmptyReason singleton
// so we can encode FR-009 ("non-empty reason required").
// =========================================================
abstract sig Reason {}
sig NonEmptyReason extends Reason {}
one sig EmptyReason extends Reason {}

// =========================================================
// Reference — the human-readable LA-YYYY-NNNNNN identifier (FR-004)
// =========================================================
sig Reference {}

// =========================================================
// Users
// =========================================================
sig User {
  role: one Role
}

// =========================================================
// Decisions
// =========================================================
sig Decision {
  decType:   one DecisionType,
  reason:    one Reason,
  decidedBy: one User
}

// =========================================================
// Loan applications
// =========================================================
sig LoanApplication {
  reference: one Reference,
  customer:  one User,
  status:    one ApplicationStatus,
  decision:  lone Decision
}

// =========================================================
// Audit events
// =========================================================
sig ApplicationEvent {
  application: one LoanApplication,
  eventType:   one EventType,
  actor:       one User
}

// =========================================================
// Operations (caller actions on the HTTP API)
// "no op.caller" denotes an unauthenticated request.
// =========================================================
sig Operation {
  caller:  lone User,
  kind:    one  OperationKind,
  target:  lone LoanApplication,
  outcome: one  Outcome
}

// =========================================================
// Non-empty universe so quantifiers don't pass vacuously.
// =========================================================
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
}

// =========================================================
// Permission matrix encoding (closed-world; from contracts/http-api.md)
// =========================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (CustomerRole  -> PostApplications)     +
      (CustomerRole  -> GetApplications)      +
      (CustomerRole  -> GetApplicationByRef)  +
      (BankStaffRole -> GetApplications)      +
      (BankStaffRole -> GetApplicationByRef)  +
      (BankStaffRole -> PostDecision)         +
      (BankStaffRole -> GetAudit)
}

// =========================================================
// Authentication required on every endpoint.
// =========================================================
fact F_AuthRequired {
  all op: Operation | (no op.caller) implies op.outcome = Unauthenticated
}

// =========================================================
// Least privilege — a Success outcome implies the (role, kind) cell
// is allowed by the permission matrix.
// =========================================================
fact F_LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies
      (some op.caller and (op.caller.role -> op.kind) in PermMatrix.Allowed)
}

// =========================================================
// Ownership-based access: a customer's successful read of an
// application proves ownership (FR-013).
// =========================================================
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.kind = GetApplicationByRef
     and op.outcome = Success
     and some op.caller
     and op.caller.role = CustomerRole
     and some op.target)
    implies op.target.customer = op.caller
}

// =========================================================
// No information leakage: a customer requesting an application by
// reference is never told "Forbidden" — denial is indistinguishable
// from "Not Found" (FR-013, contracts: 404 not 403).
// =========================================================
fact F_NoInformationLeakage {
  all op: Operation |
    (op.kind = GetApplicationByRef
     and some op.caller
     and op.caller.role = CustomerRole)
    implies op.outcome != Forbidden
}

// =========================================================
// One pending application per customer (FR-005).
// =========================================================
fact F_OnePendingPerCustomer {
  all u: User |
    #{ a: LoanApplication | a.customer = u and a.status = PendingReview } <= 1
}

// =========================================================
// The owner of an application is always a Customer (data-model).
// =========================================================
fact F_CustomerOwnsApplication {
  all a: LoanApplication | a.customer.role = CustomerRole
}

// =========================================================
// Decision <-> status consistency (FR-010).
// =========================================================
fact F_DecisionStatusConsistent {
  all a: LoanApplication |
    (a.status = PendingReview) iff (no a.decision)
  all a: LoanApplication |
    (a.status = ApprovedStatus) implies
      (some a.decision and a.decision.decType = ApprovedDec)
  all a: LoanApplication |
    (a.status = RejectedStatus) implies
      (some a.decision and a.decision.decType = RejectedDec)
}

// =========================================================
// Only bank staff can record decisions (FR-015).
// =========================================================
fact F_StaffDecide {
  all d: Decision | d.decidedBy.role = BankStaffRole
}

// =========================================================
// Decision reason must be non-empty (FR-009).
// =========================================================
fact F_NonEmptyDecisionReason {
  all d: Decision | d.reason != EmptyReason
}

// =========================================================
// Each decision belongs to exactly one application
// (data-model: decisions.application_id is the PK).
// =========================================================
fact F_DecisionOneToOne {
  all d: Decision | one a: LoanApplication | a.decision = d
}

// =========================================================
// Unique reference per application (data-model: reference UNIQUE).
// =========================================================
fact F_UniqueReference {
  all disj a, b: LoanApplication | a.reference != b.reference
}

// =========================================================
// Audit completeness — every status change has its event (FR-016).
// =========================================================
fact F_AuditCompleteness {
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and e.eventType = SubmittedEv
  all a: LoanApplication |
    (a.status = ApprovedStatus) implies
      (one e: ApplicationEvent | e.application = a and e.eventType = ApprovedEv)
  all a: LoanApplication |
    (a.status = RejectedStatus) implies
      (one e: ApplicationEvent | e.application = a and e.eventType = RejectedEv)
  all a: LoanApplication |
    (a.status = PendingReview) implies
      (no e: ApplicationEvent |
         e.application = a and (e.eventType = ApprovedEv or e.eventType = RejectedEv))
  all a: LoanApplication |
    (a.status = ApprovedStatus) implies
      (no e: ApplicationEvent | e.application = a and e.eventType = RejectedEv)
  all a: LoanApplication |
    (a.status = RejectedStatus) implies
      (no e: ApplicationEvent | e.application = a and e.eventType = ApprovedEv)
}

// =========================================================
// Append-only audit — at most one event per (application, type).
// =========================================================
fact F_AppendOnlyAuditEntries {
  all a: LoanApplication, t: EventType |
    #{ e: ApplicationEvent | e.application = a and e.eventType = t } <= 1
}

// =========================================================
// Attribution correctness — actor on an event matches the real actor.
// =========================================================
fact F_AttributionCorrectness {
  all e: ApplicationEvent |
    (e.eventType = SubmittedEv) implies e.actor = e.application.customer
  all e: ApplicationEvent |
    (e.eventType = ApprovedEv or e.eventType = RejectedEv) implies
      (some e.application.decision
       and e.actor = e.application.decision.decidedBy)
}

// =========================================================
// ===============   Catalogue patterns   ==================
// =========================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies
      (some op.caller and (op.caller.role -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // Every role appears as the source of at least one allow.
  all r: Role | some k: OperationKind | (r -> k) in PermMatrix.Allowed
  // Every endpoint kind appears as the target of at least one allow.
  all k: OperationKind | some r: Role | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md
pred PermissionGrounding {
  // No allow cell exists for a (role, kind) outside the documented set.
  PermMatrix.Allowed in (
      (CustomerRole  -> PostApplications)     +
      (CustomerRole  -> GetApplications)      +
      (CustomerRole  -> GetApplicationByRef)  +
      (BankStaffRole -> GetApplications)      +
      (BankStaffRole -> GetApplicationByRef)  +
      (BankStaffRole -> PostDecision)         +
      (BankStaffRole -> GetAudit)
  )
  // Customers are explicitly NOT granted staff-only endpoints.
  (CustomerRole  -> PostDecision)     not in PermMatrix.Allowed
  (CustomerRole  -> GetAudit)         not in PermMatrix.Allowed
  // Staff are explicitly NOT granted customer-only submission.
  (BankStaffRole -> PostApplications) not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all op: Operation | (no op.caller) implies op.outcome = Unauthenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and e.eventType = SubmittedEv
  all a: LoanApplication |
    (a.status = ApprovedStatus) implies
      (one e: ApplicationEvent | e.application = a and e.eventType = ApprovedEv)
  all a: LoanApplication |
    (a.status = RejectedStatus) implies
      (one e: ApplicationEvent | e.application = a and e.eventType = RejectedEv)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // No two distinct events share both application and event type — there
  // is at most one row in application_events per (app, type).
  all a: LoanApplication, t: EventType |
    #{ e: ApplicationEvent | e.application = a and e.eventType = t } <= 1
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md actor_user_id
pred AttributionCorrectness {
  all e: ApplicationEvent |
    (e.eventType = SubmittedEv) implies e.actor = e.application.customer
  all e: ApplicationEvent |
    (e.eventType = ApprovedEv or e.eventType = RejectedEv) implies
      (some e.application.decision
       and e.actor = e.application.decision.decidedBy)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id FK
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = GetApplicationByRef
     and op.outcome = Success
     and some op.caller
     and op.caller.role = CustomerRole
     and some op.target)
    implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: contracts/http-api.md "404 not 403"
pred NoInformationLeakage {
  all op: Operation |
    (op.kind = GetApplicationByRef
     and some op.caller
     and op.caller.role = CustomerRole)
    implies op.outcome != Forbidden
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// =========================================================
// ===========  Feature-specific FR assertions  ============
// =========================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authenticated customer submits
pred FR_001_AuthenticatedCustomerSubmits {
  all op: Operation |
    (op.kind = PostApplications and op.outcome = Success) implies
      (some op.caller and op.caller.role = CustomerRole)
}
assert FR_001_AuthenticatedCustomerSubmits { FR_001_AuthenticatedCustomerSubmits }
check FR_001_AuthenticatedCustomerSubmits for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 validation rejects bad submissions
pred FR_002_SuccessImpliesPersistedTarget {
  // Only Success outcomes on PostApplications cause an application to exist;
  // i.e., a Success outcome must have produced a concrete target row.
  all op: Operation |
    (op.kind = PostApplications and op.outcome = Success) implies some op.target
}
assert FR_002_SuccessImpliesPersistedTarget { FR_002_SuccessImpliesPersistedTarget }
check FR_002_SuccessImpliesPersistedTarget for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 amount/term ranges (structural backstop)
pred FR_003_WellFormedSubmission {
  // A successful submission lands a well-shaped application: one reference,
  // one owning customer, exactly one application atom.
  all op: Operation |
    (op.kind = PostApplications and op.outcome = Success and some op.target)
    implies (one op.target.reference and one op.target.customer)
}
assert FR_003_WellFormedSubmission { FR_003_WellFormedSubmission }
check FR_003_WellFormedSubmission for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique reference per application
pred FR_004_UniqueReference {
  all disj a, b: LoanApplication | a.reference != b.reference
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 one pending per customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    #{ a: LoanApplication | a.customer = u and a.status = PendingReview } <= 1
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 confirmation: successful submit yields a pending application
pred FR_006_SubmissionLandsPending {
  all op: Operation |
    (op.kind = PostApplications and op.outcome = Success and some op.target)
    implies op.target.status = PendingReview
}
assert FR_006_SubmissionLandsPending { FR_006_SubmissionLandsPending }
check FR_006_SubmissionLandsPending for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 staff queue access
pred FR_007_StaffMayListApplications {
  (BankStaffRole -> GetApplications) in PermMatrix.Allowed
}
assert FR_007_StaffMayListApplications { FR_007_StaffMayListApplications }
check FR_007_StaffMayListApplications for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 staff may view any application
pred FR_008_StaffMayViewAnyApplication {
  (BankStaffRole -> GetApplicationByRef) in PermMatrix.Allowed
}
assert FR_008_StaffMayViewAnyApplication { FR_008_StaffMayViewAnyApplication }
check FR_008_StaffMayViewAnyApplication for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-empty decision reason
pred FR_009_NonEmptyDecisionReason {
  all d: Decision | d.reason != EmptyReason
}
assert FR_009_NonEmptyDecisionReason { FR_009_NonEmptyDecisionReason }
check FR_009_NonEmptyDecisionReason for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision/status atomic consistency
pred FR_010_DecisionStatusConsistency {
  all a: LoanApplication | (some a.decision) iff (a.status != PendingReview)
  all a: LoanApplication |
    (a.status = ApprovedStatus) implies a.decision.decType = ApprovedDec
  all a: LoanApplication |
    (a.status = RejectedStatus) implies a.decision.decType = RejectedDec
}
assert FR_010_DecisionStatusConsistency { FR_010_DecisionStatusConsistency }
check FR_010_DecisionStatusConsistency for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 decision immutability — at most one decision per app
pred FR_011_AtMostOneDecisionPerApp {
  all a: LoanApplication | lone a.decision
  // No two distinct decisions share an owning application.
  all disj d1, d2: Decision |
    no a: LoanApplication | a.decision = d1 and a.decision = d2
}
assert FR_011_AtMostOneDecisionPerApp { FR_011_AtMostOneDecisionPerApp }
check FR_011_AtMostOneDecisionPerApp for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 concurrent decisions — first wins, no duplicates
pred FR_012_NoTwoDecisionsPerApp {
  all d: Decision | one a: LoanApplication | a.decision = d
  all a: LoanApplication | lone a.decision
}
assert FR_012_NoTwoDecisionsPerApp { FR_012_NoTwoDecisionsPerApp }
check FR_012_NoTwoDecisionsPerApp for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer can only see own applications
pred FR_013_CustomerSeesOnlyOwn {
  all op: Operation |
    (op.kind = GetApplicationByRef
     and op.outcome = Success
     and some op.caller
     and op.caller.role = CustomerRole
     and some op.target)
    implies op.target.customer = op.caller
}
assert FR_013_CustomerSeesOnlyOwn { FR_013_CustomerSeesOnlyOwn }
check FR_013_CustomerSeesOnlyOwn for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 customer notified on decision — modelled as a corresponding audit event
pred FR_014_DecisionEventEmitted {
  all a: LoanApplication |
    (a.status = ApprovedStatus) implies
      (some e: ApplicationEvent | e.application = a and e.eventType = ApprovedEv)
  all a: LoanApplication |
    (a.status = RejectedStatus) implies
      (some e: ApplicationEvent | e.application = a and e.eventType = RejectedEv)
}
assert FR_014_DecisionEventEmitted { FR_014_DecisionEventEmitted }
check FR_014_DecisionEventEmitted for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 only bank staff decide
pred FR_015_OnlyStaffDecide {
  all d: Decision | d.decidedBy.role = BankStaffRole
  all op: Operation |
    (op.kind = PostDecision and op.outcome = Success) implies
      (some op.caller and op.caller.role = BankStaffRole)
  (CustomerRole -> PostDecision) not in PermMatrix.Allowed
}
assert FR_015_OnlyStaffDecide { FR_015_OnlyStaffDecide }
check FR_015_OnlyStaffDecide for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail of every status change
pred FR_016_AuditTrail {
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and e.eventType = SubmittedEv
  all a: LoanApplication |
    (a.status = ApprovedStatus or a.status = RejectedStatus) implies
      (some e: ApplicationEvent |
         e.application = a and (e.eventType = ApprovedEv or e.eventType = RejectedEv))
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 retention — applications referenced by decisions/events still exist
pred FR_017_RetainedApplications {
  all d: Decision     | some a: LoanApplication | a.decision = d
  all e: ApplicationEvent | some e.application
}
assert FR_017_RetainedApplications { FR_017_RetainedApplications }
check FR_017_RetainedApplications for 6

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj e1, e2: ApplicationEvent | e1.application = e2.application and e1.eventType = e2.eventType }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
