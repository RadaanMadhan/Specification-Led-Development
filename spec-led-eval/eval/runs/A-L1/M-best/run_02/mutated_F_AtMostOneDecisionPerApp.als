// === feature_model.als — Alloy model for 003-loan-application ===
// Self-contained Alloy 6 model encoding structural invariants for the
// Loan Application feature (customer submits; bank staff decides; audit append-only).

// ---------- Booleans ----------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Roles (data-model.md: Role enum) ----------
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ---------- Operation kinds (the five endpoints in contracts/http-api.md) ----------
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById, PostDecision, GetAudit extends OperationKind {}

// ---------- Application status (data-model.md: ApplicationStatus enum) ----------
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// ---------- Decision type (data-model.md: DecisionType enum) ----------
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// ---------- Audit event type (data-model.md: EventType enum) ----------
abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

// ---------- Outcome of an operation (HTTP status family, contracts/http-api.md) ----------
abstract sig Outcome {}
one sig Success, NotFound, Forbidden, Unauthenticated, Conflict, Invalid extends Outcome {}

// ---------- Permission matrix as a singleton-sig field (per the system-prompt convention) ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Dynamic sigs ----------
sig User { role: one Role }
sig Reference {}
sig Reason {}

sig LoanApplication {
  customer:  one User,
  status:    one ApplicationStatus,
  reference: one Reference
}

sig Decision {
  application:  one LoanApplication,
  decisionType: one DecisionType,
  reason:       one Reason,
  decidedBy:    one User
}

sig ApplicationEvent {
  app:       one LoanApplication,
  eventType: one EventType,
  actor:     one User
}

// Operation = a single endpoint invocation we reason about.
sig Operation {
  kind:          one OperationKind,
  caller:        one User,
  target:        lone LoanApplication,
  authenticated: one Bool,
  outcome:       one Outcome
}

// =========================================================
// Witnesses (non-empty universe so quantified assertions bite)
// =========================================================
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
  some Operation
  some Reference
}

// =========================================================
// Permission matrix (closed-world) — contracts/http-api.md "Permission matrix"
// =========================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer  -> PostApplications) +
    (Customer  -> GetApplications) +
    (Customer  -> GetApplicationById) +
    (BankStaff -> GetApplications) +
    (BankStaff -> GetApplicationById) +
    (BankStaff -> PostDecision) +
    (BankStaff -> GetAudit)
}

// =========================================================
// Ownership: a loan application's customer is a User with the Customer role
// data-model.md: loan_applications.customer_id FK; only customers submit.
// =========================================================
fact F_ApplicationCustomerIsCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

// =========================================================
// Unique reference per application — data-model.md "reference TEXT UNIQUE NOT NULL"
// =========================================================
fact F_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// =========================================================
// FR-005: at most one Pending-Review application per customer
// data-model.md idx_one_pending_per_customer (partial UNIQUE index)
// =========================================================
fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.status = PendingReview and a2.status = PendingReview)
      implies a1.customer != a2.customer
}

// =========================================================
// FR-010/FR-011/FR-012: at most one Decision per LoanApplication
// data-model.md: decisions.application_id is PK (one-to-one)
// =========================================================
fact F_AtMostOneDecisionPerApp { /* MUTATED — body cleared by validator */ }

// =========================================================
// FR-010: decided applications must have a Decision; pending must not
// =========================================================
fact F_DecisionRequiredIffDecided {
  all a: LoanApplication |
    a.status = Approved  implies (some d: Decision | d.application = a)
  all a: LoanApplication |
    a.status = Rejected  implies (some d: Decision | d.application = a)
  all a: LoanApplication |
    a.status = PendingReview implies (no d: Decision | d.application = a)
}

// =========================================================
// Decision type must match the application's terminal status
// =========================================================
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.decisionType = ApprovedDecision implies d.application.status = Approved) and
    (d.decisionType = RejectedDecision implies d.application.status = Rejected)
}

// =========================================================
// FR-009: Decision has a non-empty reason — modeled as Decision.reason being a singleton.
// =========================================================
fact F_DecisionHasReason {
  all d: Decision | one d.reason
}

// =========================================================
// FR-016: audit-event existence for every status that has been reached
// (existence only; uniqueness is encoded in F_AppendOnlyEvents)
// =========================================================
fact F_AuditCompleteness {
  all a: LoanApplication |
    some e: ApplicationEvent | e.app = a and e.eventType = SubmittedEvent
  all a: LoanApplication |
    a.status = Approved implies (some e: ApplicationEvent | e.app = a and e.eventType = ApprovedEvent)
  all a: LoanApplication |
    a.status = Rejected implies (some e: ApplicationEvent | e.app = a and e.eventType = RejectedEvent)
  // Terminal events only exist if the app actually reached that status
  all e: ApplicationEvent |
    e.eventType = ApprovedEvent implies e.app.status = Approved
  all e: ApplicationEvent |
    e.eventType = RejectedEvent implies e.app.status = Rejected
}

// =========================================================
// FR-016: append-only audit log — no two events with the same (app, type)
// data-model.md: "No UPDATE/DELETE code path targets application_events"
// =========================================================
fact F_AppendOnlyEvents {
  all disj e1, e2: ApplicationEvent |
    not (e1.app = e2.app and e1.eventType = e2.eventType)
}

// =========================================================
// FR-016: attribution correctness — actor on each event matches reality
// =========================================================
fact F_AttributionCorrect {
  all e: ApplicationEvent |
    e.eventType = SubmittedEvent implies e.actor = e.app.customer
  all e: ApplicationEvent |
    e.eventType in (ApprovedEvent + RejectedEvent) implies e.actor.role = BankStaff
  all d: Decision | d.decidedBy.role = BankStaff
}

// =========================================================
// FR-001 + contracts/http-api.md: every endpoint requires authentication
// Unauthenticated → Unauthenticated outcome (no business outcome).
// =========================================================
fact F_AuthenticationRequired {
  all op: Operation |
    op.authenticated = BFalse implies op.outcome = Unauthenticated
}

// =========================================================
// FR-015 + contracts/http-api.md: least privilege — only permitted (role, op) cells succeed
// =========================================================
fact F_LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}

// =========================================================
// FR-013: ownership-based access — a customer success on GetApplicationById
// requires that the target application is theirs.
// =========================================================
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById and op.outcome = Success)
      implies (some op.target and op.target.customer = op.caller)
}

// =========================================================
// FR-013 + contracts/http-api.md: no information leakage —
// customer requesting another customer's existing application gets NotFound,
// not Forbidden (a Forbidden response would reveal "exists but not yours").
// =========================================================
fact F_NoInformationLeakage {
  all op: Operation |
    (op.caller.role = Customer and
     op.kind = GetApplicationById and
     op.authenticated = BTrue and
     some op.target and
     op.target.customer != op.caller)
      implies op.outcome = NotFound
}


// =========================================================
//                 PREDICATES + ASSERTIONS
// =========================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md "Permission matrix"; spec.md FR-015
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md "Permission matrix"
pred PermissionCompleteness {
  // Every endpoint is reachable by at least one role (no orphan endpoint).
  all k: OperationKind | some r: Role | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md "Authentication (all endpoints)"; spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.outcome = Success implies op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  (all a: LoanApplication |
     some e: ApplicationEvent | e.app = a and e.eventType = SubmittedEvent) and
  (all a: LoanApplication |
     a.status = Approved implies (some e: ApplicationEvent | e.app = a and e.eventType = ApprovedEvent)) and
  (all a: LoanApplication |
     a.status = Rejected implies (some e: ApplicationEvent | e.app = a and e.eventType = RejectedEvent))
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE targets application_events"
pred AppendOnly {
  some ApplicationEvent
  all disj e1, e2: ApplicationEvent |
    not (e1.app = e2.app and e1.eventType = e2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  some ApplicationEvent
  (all e: ApplicationEvent |
     e.eventType = SubmittedEvent implies e.actor = e.app.customer) and
  (all e: ApplicationEvent |
     e.eventType in (ApprovedEvent + RejectedEvent) implies e.actor.role = BankStaff)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id NOT NULL
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.customer and a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md customer scoping
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById and op.outcome = Success)
      implies (some op.target and op.target.customer = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md "we do not distinguish 'not yours' from 'doesn't exist'"
pred NoInformationLeakage {
  all op: Operation |
    (op.caller.role = Customer and
     op.kind = GetApplicationById and
     op.authenticated = BTrue and
     some op.target and
     op.target.customer != op.caller)
      implies op.outcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6


// --- FR-specific assertions ---

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authenticated customer submits)
pred FR_001_AuthRequired {
  all op: Operation |
    (op.kind = PostApplications and op.outcome = Success) implies op.authenticated = BTrue
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (unique reference)
pred FR_004_UniqueReference {
  some LoanApplication
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (one Pending-Review per customer)
pred FR_005_OnePendingPerCustomer {
  all u: User | lone a: LoanApplication | (a.customer = u and a.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (decision reason mandatory)
pred FR_009_DecisionHasReason {
  all d: Decision | one d.reason
}
assert FR_009_DecisionHasReason { FR_009_DecisionHasReason }
check FR_009_DecisionHasReason for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (decided apps have a persisted Decision)
pred FR_010_DecisionPersistedOnDecided {
  (all a: LoanApplication |
     a.status = Approved implies (some d: Decision | d.application = a and d.decisionType = ApprovedDecision)) and
  (all a: LoanApplication |
     a.status = Rejected implies (some d: Decision | d.application = a and d.decisionType = RejectedDecision))
}
assert FR_010_DecisionPersistedOnDecided { FR_010_DecisionPersistedOnDecided }
check FR_010_DecisionPersistedOnDecided for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (decided applications immutable: no second decision)
pred FR_011_AtMostOneDecision {
  all a: LoanApplication | lone d: Decision | d.application = a
}
assert FR_011_AtMostOneDecision { FR_011_AtMostOneDecision }
check FR_011_AtMostOneDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (concurrency: only first decision wins; never two)
pred FR_012_NoDualDecision {
  all disj d1, d2: Decision | d1.application != d2.application
}
assert FR_012_NoDualDecision { FR_012_NoDualDecision }
check FR_012_NoDualDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (customer scoping; no cross-customer visibility)
pred FR_013_CustomerScoping {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById and op.outcome = Success)
      implies (some op.target and op.target.customer = op.caller)
}
assert FR_013_CustomerScoping { FR_013_CustomerScoping }
check FR_013_CustomerScoping for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (decision/audit actions restricted to bank-staff)
pred FR_015_StaffOnlyDecisionAndAudit {
  (all op: Operation |
     (op.kind = PostDecision and op.outcome = Success) implies op.caller.role = BankStaff) and
  (all op: Operation |
     (op.kind = GetAudit and op.outcome = Success) implies op.caller.role = BankStaff)
}
assert FR_015_StaffOnlyDecisionAndAudit { FR_015_StaffOnlyDecisionAndAudit }
check FR_015_StaffOnlyDecisionAndAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit append-only; no duplicate (app, event_type))
pred FR_016_AuditAppendOnly {
  some ApplicationEvent
  all disj e1, e2: ApplicationEvent |
    not (e1.app = e2.app and e1.eventType = e2.eventType)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_TwoDecisionsSameApp { some disj d1, d2: Decision | d1.application = d2.application }
