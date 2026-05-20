// === feature_model.als — Alloy model for 003-loan-application ===
//
// Structural model of the Loan Application feature. Covers role-based
// permissions, status lifecycle, decision uniqueness, append-only audit,
// and customer-ownership-based access. Each named fact carries the
// invariant a corresponding predicate/assertion checks.

// ---- Non-empty universe (single fact, no inline witnesses) ----
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
  some Operation
  some Decision
}

// ---- Roles ----
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// ---- Operation kinds (the five HTTP endpoints) ----
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById,
        PostDecision, GetAudit extends OperationKind {}

// ---- Application status lifecycle ----
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// ---- Audit event types ----
abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

// ---- Decision verdict types ----
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// ---- Users ----
sig User { role: one Role }

// ---- Reason (marker for non-empty decision reason) ----
sig Reason {}

// ---- Decision ----
sig Decision {
  decType:   one DecisionType,
  reason:    lone Reason,
  decidedBy: one User
}

// ---- LoanApplication ----
sig LoanApplication {
  customer: one User,
  status:   one ApplicationStatus,
  decision: lone Decision
}

// ---- Audit event (append-only journal entries) ----
sig ApplicationEvent {
  eventType: one EventType,
  actor:     one User,
  app:       one LoanApplication
}

// ---- Operation = one API call into the system ----
sig Operation {
  caller: one User,
  kind:   one OperationKind,
  target: lone LoanApplication
}

// ---- Permission matrix (Role × OperationKind) ----
one sig PermMatrix { Allowed: set Role -> OperationKind }

// Anchor: contracts/http-api.md "Permission matrix"
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole   -> PostApplications) +
    (CustomerRole   -> GetApplications) +
    (CustomerRole   -> GetApplicationById) +
    (BankStaffRole  -> GetApplications) +
    (BankStaffRole  -> GetApplicationById) +
    (BankStaffRole  -> PostDecision) +
    (BankStaffRole  -> GetAudit)
}

// ============================================================
// Named, mutation-testable facts
// ============================================================

// Anchor: spec.md FR-001/FR-015; contracts/http-api.md permission matrix
fact F_LeastPrivilege {
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}

// Anchor: data-model.md User.role NOT NULL; loan_applications.customer_id FK
fact F_CustomerHasCustomerRole {
  all la: LoanApplication | la.customer.role = CustomerRole
}

// Anchor: spec.md FR-015; data-model.md decisions.decided_by_user_id is staff
fact F_DeciderIsStaff {
  all d: Decision | d.decidedBy.role = BankStaffRole
}

// Anchor: spec.md FR-009; data-model.md decisions.reason CHECK(length>0)
fact F_DecisionReasonNonEmpty { /* MUTATED — body cleared by validator */ }

// Anchor: spec.md FR-010/FR-011; data-model.md status lifecycle
fact F_StatusMatchesDecision {
  all la: LoanApplication | (la.status = PendingReview) iff (no la.decision)
  all la: LoanApplication | (some la.decision) implies
    ((la.decision.decType = DecApproved) iff (la.status = Approved))
  all la: LoanApplication | (some la.decision) implies
    ((la.decision.decType = DecRejected) iff (la.status = Rejected))
}

// Anchor: spec.md FR-012; data-model.md decisions.application_id PK
fact F_OneDecisionPerApp {
  all disj la1, la2: LoanApplication |
    (some la1.decision and some la2.decision)
      implies la1.decision != la2.decision
}

// Anchor: spec.md FR-005; data-model.md idx_one_pending_per_customer
fact F_OnePendingPerCustomer {
  all u: User |
    (lone la: LoanApplication | la.customer = u and la.status = PendingReview)
}

// Anchor: spec.md FR-016; data-model.md application_events on submission
fact F_OneSubmittedEventPerApp {
  all la: LoanApplication |
    (one e: ApplicationEvent | e.app = la and e.eventType = SubmittedEvent)
}

// Anchor: spec.md FR-016; data-model.md application_events on decision
fact F_DecisionEventForDecidedApp {
  all la: LoanApplication | la.status = Approved implies
    (one e: ApplicationEvent | e.app = la and e.eventType = ApprovedEvent)
  all la: LoanApplication | la.status = Rejected implies
    (one e: ApplicationEvent | e.app = la and e.eventType = RejectedEvent)
  all la: LoanApplication | la.status = PendingReview implies
    (no e: ApplicationEvent | e.app = la and
       e.eventType in (ApprovedEvent + RejectedEvent))
}

// Anchor: spec.md FR-016; data-model.md application_events.actor_user_id
fact F_SubmittedEventAttribution {
  all e: ApplicationEvent | e.eventType = SubmittedEvent implies
    e.actor = e.app.customer
}

// Anchor: spec.md FR-016; data-model.md application_events.actor_user_id
fact F_DecisionEventAttribution {
  all e: ApplicationEvent |
    e.eventType in (ApprovedEvent + RejectedEvent) implies
      (e.actor.role = BankStaffRole
       and some e.app.decision
       and e.actor = e.app.decision.decidedBy)
}

// Anchor: spec.md FR-013; contracts/http-api.md "customer sees only own"
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = CustomerRole
     and op.kind = GetApplicationById
     and some op.target)
      implies op.target.customer = op.caller
}

// ============================================================
// Catalogue patterns: predicate + assertion + check
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  some Operation
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // every endpoint is reachable by at least one role
  all opk: OperationKind | some r: Role | r -> opk in PermMatrix.Allowed
  // every role can perform at least one operation
  all r: Role | some opk: OperationKind | r -> opk in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001, FR-013, FR-015
pred PermissionGrounding {
  // only customers may submit applications (FR-001)
  all r: Role | r -> PostApplications in PermMatrix.Allowed implies r = CustomerRole
  // only staff may record a decision (FR-015)
  all r: Role | r -> PostDecision in PermMatrix.Allowed implies r = BankStaffRole
  // only staff may inspect the audit log (FR-015)
  all r: Role | r -> GetAudit in PermMatrix.Allowed implies r = BankStaffRole
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  all la: LoanApplication |
    (one e: ApplicationEvent | e.app = la and e.eventType = SubmittedEvent)
  all la: LoanApplication | la.status = Approved implies
    (one e: ApplicationEvent | e.app = la and e.eventType = ApprovedEvent)
  all la: LoanApplication | la.status = Rejected implies
    (one e: ApplicationEvent | e.app = la and e.eventType = RejectedEvent)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  // no duplicate submitted events per application
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.app = la and e.eventType = SubmittedEvent)
  // no duplicate approved events per application
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.app = la and e.eventType = ApprovedEvent)
  // no duplicate rejected events per application
  all la: LoanApplication |
    (lone e: ApplicationEvent | e.app = la and e.eventType = RejectedEvent)
  // no orphan events
  all e: ApplicationEvent | some e.app
  // decision events only exist alongside a real decision
  all e: ApplicationEvent |
    e.eventType in (ApprovedEvent + RejectedEvent) implies some e.app.decision
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  some ApplicationEvent
  all e: ApplicationEvent | e.eventType = SubmittedEvent implies
    e.actor = e.app.customer
  all e: ApplicationEvent |
    e.eventType in (ApprovedEvent + RejectedEvent) implies
      (e.actor.role = BankStaffRole
       and some e.app.decision
       and e.actor = e.app.decision.decidedBy)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id NOT NULL
pred OwnershipExclusivity {
  some LoanApplication
  all la: LoanApplication | one la.customer
  all la: LoanApplication | la.customer.role = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md customer→404 on non-owner
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = CustomerRole
     and op.kind = GetApplicationById
     and some op.target)
      implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// ============================================================
// Feature-specific predicates (one per FR-NNN)
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 every endpoint is authenticated
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | one op.caller and one op.caller.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 structural field presence as backstop to validation
pred FR_002_StructuralFieldsPresent {
  all la: LoanApplication | one la.customer and one la.status
}
assert FR_002_StructuralFieldsPresent { FR_002_StructuralFieldsPresent }
check FR_002_StructuralFieldsPresent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 submission recorded with status, identity, audit event
pred FR_004_SubmissionRecorded {
  some LoanApplication
  all la: LoanApplication | some la.customer and one la.status
  all la: LoanApplication |
    (some e: ApplicationEvent | e.app = la and e.eventType = SubmittedEvent)
}
assert FR_004_SubmissionRecorded { FR_004_SubmissionRecorded }
check FR_004_SubmissionRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 one Pending Review per customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    (lone la: LoanApplication | la.customer = u and la.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-empty reason on every decision
pred FR_009_DecisionReasonRequired {
  all d: Decision | some d.reason
}
assert FR_009_DecisionReasonRequired { FR_009_DecisionReasonRequired }
check FR_009_DecisionReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision persisted with decider identity, status flipped
pred FR_010_DecisionPersisted {
  all la: LoanApplication | la.status != PendingReview implies
    (some la.decision and one la.decision.decidedBy)
  all la: LoanApplication | some la.decision implies
    la.decision.decidedBy.role = BankStaffRole
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 decided applications are immutable
pred FR_011_DecidedImmutable {
  all la: LoanApplication | some la.decision implies la.status != PendingReview
  all la: LoanApplication | lone la.decision
}
assert FR_011_DecidedImmutable { FR_011_DecidedImmutable }
check FR_011_DecidedImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 at most one decision per application (concurrency)
pred FR_012_NoTwoDecisions {
  all la: LoanApplication | lone la.decision
  all disj la1, la2: LoanApplication |
    (some la1.decision and some la2.decision)
      implies la1.decision != la2.decision
}
assert FR_012_NoTwoDecisions { FR_012_NoTwoDecisions }
check FR_012_NoTwoDecisions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer access scoped to own applications
pred FR_013_CustomerOwnAccess {
  all op: Operation |
    (op.caller.role = CustomerRole
     and op.kind = GetApplicationById
     and some op.target)
      implies op.target.customer = op.caller
}
assert FR_013_CustomerOwnAccess { FR_013_CustomerOwnAccess }
check FR_013_CustomerOwnAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 status change is observable (decision-event side effect)
pred FR_014_StatusChangeObservable {
  all la: LoanApplication | la.status != PendingReview implies
    (some e: ApplicationEvent | e.app = la
       and e.eventType in (ApprovedEvent + RejectedEvent))
}
assert FR_014_StatusChangeObservable { FR_014_StatusChangeObservable }
check FR_014_StatusChangeObservable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 decision & audit endpoints are staff-only
pred FR_015_OnlyStaffDecides {
  all d: Decision | d.decidedBy.role = BankStaffRole
  all op: Operation | op.kind = PostDecision implies op.caller.role = BankStaffRole
  all op: Operation | op.kind = GetAudit     implies op.caller.role = BankStaffRole
}
assert FR_015_OnlyStaffDecides { FR_015_OnlyStaffDecides }
check FR_015_OnlyStaffDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail for every status change
pred FR_016_AuditTrail {
  some LoanApplication
  all la: LoanApplication |
    (one e: ApplicationEvent | e.app = la and e.eventType = SubmittedEvent)
  all la: LoanApplication | la.status = Approved implies
    (one e: ApplicationEvent | e.app = la and e.eventType = ApprovedEvent)
  all la: LoanApplication | la.status = Rejected implies
    (one e: ApplicationEvent | e.app = la and e.eventType = RejectedEvent)
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 retention — no orphan events or decisions
pred FR_017_RetentionOrphanFreedom {
  all e: ApplicationEvent | some e.app
  all d: Decision | some la: LoanApplication | la.decision = d
}
assert FR_017_RetentionOrphanFreedom { FR_017_RetentionOrphanFreedom }
check FR_017_RetentionOrphanFreedom for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_EmptyReason { some d: Decision | no d.reason }
