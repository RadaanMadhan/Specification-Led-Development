// === feature_model.als — Alloy model for 003-loan-application ===
//
// Structural model of the personal-loan application feature: customers
// submit applications, bank staff decide, audit entries record lifecycle
// events. Encodes the permission matrix from contracts/http-api.md and
// the invariants from spec.md (FR-001…FR-017) and data-model.md.

// ---------------- Roles ----------------
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ---------------- Operation kinds (the 5 endpoints) ----------------
abstract sig OperationKind {}
one sig SubmitApp, ListApps, ViewApp, DecideApp, ViewAudit extends OperationKind {}

// ---------------- Application status ----------------
abstract sig Status {}
one sig PendingReview, Approved, Rejected extends Status {}

// ---------------- Decision types ----------------
abstract sig DecisionTypeKind {}
one sig DTApproved, DTRejected extends DecisionTypeKind {}

// ---------------- Audit event types ----------------
abstract sig EventTypeKind {}
one sig EvSubmitted, EvApproved, EvRejected extends EventTypeKind {}

// ---------------- HTTP-shape responses ----------------
abstract sig Response {}
one sig OkResponse, NotFoundResponse, ForbiddenResponse,
        UnauthenticatedResponse, ConflictResponse extends Response {}

// ---------------- Authorization outcomes ----------------
abstract sig Outcome {}
one sig OpAllowed, OpDenied extends Outcome {}

// ---------------- Marker singletons ----------------
one sig AuthFlag {}             // presence ⇒ caller is authenticated
one sig NonEmptyReasonFlag {}   // presence ⇒ decision reason is non-empty

// ---------------- Dynamic entities ----------------
sig User {
  role: one Role
}

sig LoanApplication {
  customer: one User,
  status:   one Status
}

sig Decision {
  application:    one LoanApplication,
  decisionType:   one DecisionTypeKind,
  decidedBy:      one User,
  reasonNonEmpty: lone NonEmptyReasonFlag
}

sig AuditEntry {
  application: one LoanApplication,
  eventType:   one EventTypeKind,
  actor:       one User
}

sig Operation {
  kind:          one OperationKind,
  caller:        one User,
  target:        lone LoanApplication,
  authenticated: lone AuthFlag,
  outcome:       one Outcome,
  response:      one Response
}

// ---------------- Permission matrix (singleton-sig field) ----------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ============================================================
// FACTS (all named — every constraint is mutation-testable)
// ============================================================

// Force a non-empty universe so quantifiers bite. Top-level only.
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Operation
}

// Permission matrix from contracts/http-api.md "Permission matrix" table.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Customer  -> SubmitApp)
    + (Customer  -> ListApps)
    + (Customer  -> ViewApp)
    + (BankStaff -> ListApps)
    + (BankStaff -> ViewApp)
    + (BankStaff -> DecideApp)
    + (BankStaff -> ViewAudit)
}

// Every loan application is owned by a user whose role is Customer.
// (data-model.md: customer_id FK→users.id, plus role discrimination)
fact F_CustomerRoleConsistency {
  all a: LoanApplication | a.customer.role = Customer
}

// Decisions are made by staff. (data-model.md: decided_by_user_id; FR-015)
fact F_DecisionByStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

// At most one Decision per LoanApplication.
// (data-model.md: decisions.application_id PRIMARY KEY; FR-011, FR-012)
fact F_DecisionApplicationCoupling {
  all a: LoanApplication | (lone d: Decision | d.application = a)
}

// Decision reasons are non-empty. (FR-009; decisions.reason CHECK length>0)
fact F_DecisionRequiresNonEmptyReason {
  all d: Decision | some d.reasonNonEmpty
}

// At most one Pending Review application per customer.
// (data-model.md: partial UNIQUE idx_one_pending_per_customer; FR-005)
fact F_OnePendingPerCustomer {
  all u: User |
    (lone a: LoanApplication | a.customer = u and a.status = PendingReview)
}

// Application status mirrors decision presence/type. (FR-004, FR-010, FR-011)
fact F_StatusReflectsDecision {
  all a: LoanApplication |
    (some d: Decision | d.application = a) iff a.status != PendingReview
  all d: Decision |
    d.decisionType = DTApproved implies d.application.status = Approved
  all d: Decision |
    d.decisionType = DTRejected implies d.application.status = Rejected
}

// Every status-changing lifecycle event produces exactly one matching audit
// entry, with the correct actor. (FR-016; data-model.md application_events)
fact F_AuditEntriesReflectLifecycle {
  // Every application has exactly one 'submitted' event by its customer.
  all a: LoanApplication |
    (one ae: AuditEntry |
       ae.application = a and ae.eventType = EvSubmitted and ae.actor = a.customer)
  // Approved → exactly one 'approved' event by the deciding staff.
  all a: LoanApplication |
    a.status = Approved implies
      (one ae: AuditEntry |
         ae.application = a and ae.eventType = EvApproved and
         (some d: Decision | d.application = a and ae.actor = d.decidedBy))
  // Rejected → exactly one 'rejected' event by the deciding staff.
  all a: LoanApplication |
    a.status = Rejected implies
      (one ae: AuditEntry |
         ae.application = a and ae.eventType = EvRejected and
         (some d: Decision | d.application = a and ae.actor = d.decidedBy))
  // No decision events on still-pending applications.
  all ae: AuditEntry |
    ae.eventType = EvApproved implies ae.application.status = Approved
  all ae: AuditEntry |
    ae.eventType = EvRejected implies ae.application.status = Rejected
  // No duplicate event types per application (append-only ≈ no fabrication).
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.eventType != ae2.eventType
}

// Operations have well-typed targets.
fact F_OperationTargetShape {
  all op: Operation | op.kind = SubmitApp implies no op.target
  all op: Operation | op.kind = ListApps  implies no op.target
  all op: Operation |
    op.kind in (ViewApp + DecideApp + ViewAudit) implies (one op.target)
}

// Authorization semantics: OpAllowed iff authenticated AND role-kind in
// matrix AND (if customer ViewApp, caller owns the target).
fact F_AuthorizationSemantics { /* MUTATED — body cleared by validator */ }

// Externally visible response shape — including the FR-013 no-leakage rule
// that a customer asking about a non-owned application gets 404, not 403.
fact F_ResponseSemantics {
  // Unauthenticated → 401.
  all op: Operation |
    no op.authenticated implies op.response = UnauthenticatedResponse
  // Customer + ViewApp + non-owned target → 404 (no existence leak).
  all op: Operation |
    (some op.authenticated and op.caller.role = Customer and op.kind = ViewApp
     and some op.target and op.target.customer != op.caller)
       implies op.response = NotFoundResponse
  // Customer trying staff-only operations → 403.
  all op: Operation |
    (some op.authenticated and op.caller.role = Customer
     and op.kind in (DecideApp + ViewAudit))
       implies op.response = ForbiddenResponse
  // Staff trying customer-only submit → 403.
  all op: Operation |
    (some op.authenticated and op.caller.role = BankStaff and op.kind = SubmitApp)
       implies op.response = ForbiddenResponse
  // Allowed → 200.
  all op: Operation | op.outcome = OpAllowed implies op.response = OkResponse
}

// ============================================================
// CATALOGUE PATTERNS
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  // Customers cannot succeed at staff-only endpoints.
  all op: Operation |
    (op.caller.role = Customer and op.kind in (DecideApp + ViewAudit))
      implies op.outcome != OpAllowed
  // Staff cannot succeed at the customer-only submit endpoint.
  all op: Operation |
    (op.caller.role = BankStaff and op.kind = SubmitApp)
      implies op.outcome != OpAllowed
  // Successful ops always have a matching matrix cell.
  all op: Operation |
    op.outcome = OpAllowed implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every documented allow cell is present.
  (Customer  -> SubmitApp)  in PermMatrix.Allowed
  (Customer  -> ListApps)   in PermMatrix.Allowed
  (Customer  -> ViewApp)    in PermMatrix.Allowed
  (BankStaff -> ListApps)   in PermMatrix.Allowed
  (BankStaff -> ViewApp)    in PermMatrix.Allowed
  (BankStaff -> DecideApp)  in PermMatrix.Allowed
  (BankStaff -> ViewAudit)  in PermMatrix.Allowed
  // Every documented deny cell is absent.
  (Customer  -> DecideApp) not in PermMatrix.Allowed
  (Customer  -> ViewAudit) not in PermMatrix.Allowed
  (BankStaff -> SubmitApp) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001/008/009/015; contracts/http-api.md
pred PermissionGrounding {
  // Every allow cell in the matrix is one of the seven we can ground in an FR.
  PermMatrix.Allowed in (
      (Customer  -> SubmitApp)   // FR-001
    + (Customer  -> ListApps)    // FR-013
    + (Customer  -> ViewApp)     // FR-013
    + (BankStaff -> ListApps)    // FR-007
    + (BankStaff -> ViewApp)     // FR-008
    + (BankStaff -> DecideApp)   // FR-009, FR-015
    + (BankStaff -> ViewAudit)   // FR-016
  )
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  all op: Operation | no op.authenticated implies op.outcome = OpDenied
  all op: Operation | no op.authenticated implies op.response = UnauthenticatedResponse
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  // Every application has a submission audit entry.
  all a: LoanApplication |
    (some ae: AuditEntry | ae.application = a and ae.eventType = EvSubmitted)
  // Every decided application has a matching decision audit entry.
  all a: LoanApplication |
    a.status = Approved implies
      (some ae: AuditEntry | ae.application = a and ae.eventType = EvApproved)
  all a: LoanApplication |
    a.status = Rejected implies
      (some ae: AuditEntry | ae.application = a and ae.eventType = EvRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: data-model.md "No UPDATE/DELETE code path… application_events"; FR-016
pred AppendOnly {
  // No duplicate event-type rows for the same application (mutation-as-duplicate).
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.eventType != ae2.eventType
  // No audit entry can carry a state-incompatible event (mutation-as-falsification).
  all ae: AuditEntry |
    ae.eventType = EvApproved implies ae.application.status = Approved
  all ae: AuditEntry |
    ae.eventType = EvRejected implies ae.application.status = Rejected
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md actor_user_id; spec.md FR-016
pred AttributionCorrectness {
  // Submission events are attributed to the actual application customer.
  all ae: AuditEntry |
    ae.eventType = EvSubmitted implies ae.actor = ae.application.customer
  // Decision events are attributed to staff, and specifically to the decider.
  all ae: AuditEntry |
    ae.eventType in (EvApproved + EvRejected) implies ae.actor.role = BankStaff
  all ae: AuditEntry, d: Decision |
    (ae.application = d.application and ae.eventType in (EvApproved + EvRejected))
      implies ae.actor = d.decidedBy
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id FK; spec.md "Loan Application" entity
pred OwnershipExclusivity {
  // Every application has exactly one owner, and that owner is a Customer.
  all a: LoanApplication | one a.customer and a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
  // A customer's view-of-application succeeds only against an application they own.
  all op: Operation |
    (op.caller.role = Customer and op.kind = ViewApp and op.outcome = OpAllowed)
      implies (some op.target and op.target.customer = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md "404, not 403"
pred NoInformationLeakage {
  // A customer asking about an application that exists but isn't theirs
  // receives 404, not 403 — indistinguishable from "doesn't exist".
  all op: Operation |
    (some op.authenticated and op.caller.role = Customer and op.kind = ViewApp
     and some op.target and op.target.customer != op.caller)
      implies op.response = NotFoundResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ============================================================
// FEATURE-SPECIFIC FR ASSERTIONS
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 customer can submit
pred FR_001_CustomerCanSubmit {
  // Customers (the documented submitter role) are the only role authorised
  // to submit, and every recorded application is owned by a Customer.
  (Customer -> SubmitApp) in PermMatrix.Allowed
  (BankStaff -> SubmitApp) not in PermMatrix.Allowed
  all a: LoanApplication | a.customer.role = Customer
}
assert FR_001_CustomerCanSubmit { FR_001_CustomerCanSubmit }
check FR_001_CustomerCanSubmit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 validation rejects bad submissions structurally
pred FR_002_ValidationBeforeMutation {
  // A successful state-changing operation must be OpAllowed.
  // Conversely, all denied operations leave no Decision or AuditEntry trace
  // attributable to their attempt. We capture this here as: every Decision
  // has a non-empty reason and a staff decider — preconditions enforced
  // before the row exists. (Submission's analogue is FR-004.)
  all d: Decision | some d.reasonNonEmpty and d.decidedBy.role = BankStaff
}
assert FR_002_ValidationBeforeMutation { FR_002_ValidationBeforeMutation }
check FR_002_ValidationBeforeMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 amount range and term set — structurally bracketed by enums
pred FR_003_StatusEnumClosed {
  // Status is one of the three documented enum values — closed-world.
  Status = PendingReview + Approved + Rejected
  // Decision type is one of the two documented enum values.
  DecisionTypeKind = DTApproved + DTRejected
}
assert FR_003_StatusEnumClosed { FR_003_StatusEnumClosed }
check FR_003_StatusEnumClosed for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 newly submitted applications start in Pending Review
pred FR_004_NewAppPendingReview {
  // An application has status != PendingReview iff a Decision exists for it.
  all a: LoanApplication |
    (a.status = PendingReview) iff (no d: Decision | d.application = a)
}
assert FR_004_NewAppPendingReview { FR_004_NewAppPendingReview }
check FR_004_NewAppPendingReview for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 at most one Pending Review per customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    (lone a: LoanApplication | a.customer = u and a.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 staff can view any application (no ownership filter)
pred FR_008_StaffViewAny {
  (BankStaff -> ViewApp) in PermMatrix.Allowed
  // Authenticated staff viewing any existing application succeeds.
  all op: Operation |
    (some op.authenticated and op.caller.role = BankStaff and op.kind = ViewApp
     and some op.target) implies op.outcome = OpAllowed
}
assert FR_008_StaffViewAny { FR_008_StaffViewAny }
check FR_008_StaffViewAny for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 decision requires non-empty reason
pred FR_009_NonEmptyReason {
  all d: Decision | some d.reasonNonEmpty
}
assert FR_009_NonEmptyReason { FR_009_NonEmptyReason }
check FR_009_NonEmptyReason for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision persists status, decider, type
pred FR_010_DecisionChangesStatus {
  all d: Decision |
    d.decisionType = DTApproved implies d.application.status = Approved
  all d: Decision |
    d.decisionType = DTRejected implies d.application.status = Rejected
  // A decided application is no longer pending.
  all d: Decision | d.application.status != PendingReview
}
assert FR_010_DecisionChangesStatus { FR_010_DecisionChangesStatus }
check FR_010_DecisionChangesStatus for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 decided applications are immutable
pred FR_011_DecidedImmutable {
  // Any non-pending application has exactly one decision attached (no overwrites).
  all a: LoanApplication |
    a.status != PendingReview implies (one d: Decision | d.application = a)
  // Pending applications have no decision.
  all a: LoanApplication |
    a.status = PendingReview implies (no d: Decision | d.application = a)
}
assert FR_011_DecidedImmutable { FR_011_DecidedImmutable }
check FR_011_DecidedImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 concurrent decisions — at most one recorded
pred FR_012_AtMostOneDecision {
  all a: LoanApplication | (lone d: Decision | d.application = a)
}
assert FR_012_AtMostOneDecision { FR_012_AtMostOneDecision }
check FR_012_AtMostOneDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer only sees own; no leakage
pred FR_013_CustomerSeesOwnOnly {
  // A successful customer ViewApp is always against an owned application.
  all op: Operation |
    (op.caller.role = Customer and op.kind = ViewApp and op.outcome = OpAllowed)
      implies op.target.customer = op.caller
  // Customer viewing a non-owned application gets 404, indistinguishable from non-existent.
  all op: Operation |
    (some op.authenticated and op.caller.role = Customer and op.kind = ViewApp
     and some op.target and op.target.customer != op.caller)
      implies op.response = NotFoundResponse
}
assert FR_013_CustomerSeesOwnOnly { FR_013_CustomerSeesOwnOnly }
check FR_013_CustomerSeesOwnOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 decision actions restricted to staff
pred FR_015_DecisionsStaffOnly {
  // All recorded decisions are by staff.
  all d: Decision | d.decidedBy.role = BankStaff
  // Customer attempts at DecideApp / ViewAudit cannot succeed.
  all op: Operation |
    (op.caller.role = Customer and op.kind in (DecideApp + ViewAudit))
      implies op.outcome != OpAllowed
  // Matrix denies these to customer.
  (Customer -> DecideApp) not in PermMatrix.Allowed
  (Customer -> ViewAudit) not in PermMatrix.Allowed
}
assert FR_015_DecisionsStaffOnly { FR_015_DecisionsStaffOnly }
check FR_015_DecisionsStaffOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail of status changes
pred FR_016_AuditTrail {
  // Every application has a submitted audit entry by its customer.
  all a: LoanApplication |
    (some ae: AuditEntry |
       ae.application = a and ae.eventType = EvSubmitted and ae.actor = a.customer)
  // Approved/Rejected applications have the matching decision audit entry by staff.
  all a: LoanApplication |
    a.status = Approved implies
      (some ae: AuditEntry |
         ae.application = a and ae.eventType = EvApproved and ae.actor.role = BankStaff)
  all a: LoanApplication |
    a.status = Rejected implies
      (some ae: AuditEntry |
         ae.application = a and ae.eventType = EvRejected and ae.actor.role = BankStaff)
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 retention — no audit entries are removed
pred FR_017_AuditRetention {
  // Each event type appears at most once per application — i.e., never deleted-and-rewritten.
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies ae1.eventType != ae2.eventType
  // Every existing application retains its submission record.
  all a: LoanApplication |
    (some ae: AuditEntry | ae.application = a and ae.eventType = EvSubmitted)
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuthSemantics { some op: Operation, u: User, a: LoanApplication | u.role = Customer and op.caller = u and op.kind = ViewApp and op.target = a and a.customer != u and no op.authenticated and op.outcome = OpAllowed }
