// === feature_model.als — Alloy model for 003-loan-application ===
// Self-contained Alloy 6 model. Encodes the loan-application feature's
// structural invariants: per-role permissions, one-pending-per-customer,
// one-decision-per-application, audit completeness/append-only, and
// customer-vs-other-customer information leakage.

// ---------------------------------------------------------------------
// Non-empty universe: exactly one named fact, asserts some-witness for
// every dynamic sig the predicates touch. Keeps `for N` from collapsing
// into the empty-universe corner case.
// ---------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some Operation
}

// ---------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ---------------------------------------------------------------------
// Operation kinds (1 per HTTP contract endpoint that has authz)
// ---------------------------------------------------------------------
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById,
        PostDecision, GetAudit extends OperationKind {}

// ---------------------------------------------------------------------
// Permission matrix as a singleton-sig field (Role x OperationKind).
// ---------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer -> PostApplications) +
    (Customer -> GetApplications) +
    (Customer -> GetApplicationById) +
    (BankStaff -> GetApplications) +
    (BankStaff -> GetApplicationById) +
    (BankStaff -> PostDecision) +
    (BankStaff -> GetAudit)
}

// ---------------------------------------------------------------------
// Application status, decision type, audit event type
// ---------------------------------------------------------------------
abstract sig Status {}
one sig PendingReview, Approved, Rejected extends Status {}

abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

abstract sig EventType {}
one sig Submitted, EvApproved, EvRejected extends EventType {}

// ---------------------------------------------------------------------
// Outcome / flag values
// ---------------------------------------------------------------------
abstract sig Bool {}
one sig True, False extends Bool {}

// ---------------------------------------------------------------------
// Dynamic sigs
// ---------------------------------------------------------------------
sig User {
  role: one Role
}

sig Decision {
  decisionType: one DecisionType,
  decidedBy: one User,
  reasonPresent: one Bool
}

sig LoanApplication {
  customer: one User,
  status: one Status,
  decision: set Decision   // 'set' so F_AtMostOneDecisionPerApp can be a removable fact
}

sig AuditEntry {
  application: one LoanApplication,
  eventType: one EventType,
  actor: one User
}

// An Operation models one in-flight authenticated request reaching a handler.
sig Operation {
  caller: one User,
  kind: one OperationKind,
  authenticated: one Bool,
  target: lone LoanApplication,
  visibleResult: one Bool   // True = caller saw the resource; False = 404/denied
}

// =====================================================================
// Structural facts (named, mutation-testable)
// =====================================================================

fact F_CustomerOwnership {
  all a: LoanApplication | a.customer.role = Customer
}

fact F_StaffDecisions {
  all d: Decision | d.decidedBy.role = BankStaff
}

fact F_AtMostOneDecisionPerApp {
  all a: LoanApplication | lone a.decision
}

fact F_DecisionOwnership {
  all d: Decision | one a: LoanApplication | d in a.decision
}

fact F_DecisionMatchesStatus {
  all a: LoanApplication | (some a.decision) iff a.status != PendingReview
  all a: LoanApplication |
    a.status = Approved implies a.decision.decisionType = DecApproved
  all a: LoanApplication |
    a.status = Rejected implies a.decision.decisionType = DecRejected
}

fact F_NonEmptyReason {
  all d: Decision | d.reasonPresent = True
}

fact F_OnePendingPerCustomer {
  all u: User | (lone a: LoanApplication | a.customer = u and a.status = PendingReview)
}

fact F_AuditCompleteness {
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and e.eventType = Submitted)
  all a: LoanApplication |
    a.status = Approved implies
      (some e: AuditEntry | e.application = a and e.eventType = EvApproved)
  all a: LoanApplication |
    a.status = Rejected implies
      (some e: AuditEntry | e.application = a and e.eventType = EvRejected)
  all e: AuditEntry |
    e.eventType = EvApproved implies e.application.status = Approved
  all e: AuditEntry |
    e.eventType = EvRejected implies e.application.status = Rejected
}

fact F_AppendOnlyAuditEntries {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}

fact F_AuditAttribution {
  all e: AuditEntry |
    e.eventType = Submitted implies e.actor = e.application.customer
  all e: AuditEntry |
    e.eventType = EvApproved implies
      (some d: e.application.decision | e.actor = d.decidedBy)
  all e: AuditEntry |
    e.eventType = EvRejected implies
      (some d: e.application.decision | e.actor = d.decidedBy)
}

fact F_AuthRequired {
  all op: Operation | op.authenticated = True
}

fact F_LeastPrivilege {
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}

fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById and some op.target)
      implies (op.visibleResult = True iff op.target.customer = op.caller)
}

fact F_StaffSeesAnyApplication {
  all op: Operation |
    (op.caller.role = BankStaff and op.kind = GetApplicationById and some op.target)
      implies op.visibleResult = True
}

fact F_OperationTargetShape {
  all op: Operation |
    (op.kind = GetApplicationById or op.kind = PostDecision or op.kind = GetAudit)
      implies some op.target
  all op: Operation |
    (op.kind = PostApplications or op.kind = GetApplications)
      implies no op.target
}

// =====================================================================
// Catalogue patterns
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // explicit allow cells
  Customer  -> PostApplications     in PermMatrix.Allowed
  Customer  -> GetApplications      in PermMatrix.Allowed
  Customer  -> GetApplicationById   in PermMatrix.Allowed
  BankStaff -> GetApplications      in PermMatrix.Allowed
  BankStaff -> GetApplicationById   in PermMatrix.Allowed
  BankStaff -> PostDecision         in PermMatrix.Allowed
  BankStaff -> GetAudit             in PermMatrix.Allowed
  // explicit deny cells (closed-world: anything not listed above must be denied)
  Customer  -> PostDecision     not in PermMatrix.Allowed
  Customer  -> GetAudit         not in PermMatrix.Allowed
  BankStaff -> PostApplications not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md Authentication section; FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.authenticated = True
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and e.eventType = Submitted)
  all a: LoanApplication |
    a.status = Approved implies
      (some e: AuditEntry | e.application = a and e.eventType = EvApproved)
  all a: LoanApplication |
    a.status = Rejected implies
      (some e: AuditEntry | e.application = a and e.eventType = EvRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md application_events.actor_user_id; FR-016
pred AttributionCorrectness {
  all e: AuditEntry |
    e.eventType = Submitted implies e.actor = e.application.customer
  all e: AuditEntry |
    (e.eventType = EvApproved or e.eventType = EvRejected) implies e.actor.role = BankStaff
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id NOT NULL
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById
      and some op.target and op.visibleResult = True)
        implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md (404, not 403, on non-owner)
pred NoInformationLeakage {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById
      and some op.target and op.target.customer != op.caller)
        implies op.visibleResult = False
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// =====================================================================
// Feature-specific (per-FR) predicates
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — every endpoint requires authentication
pred FR_001_AuthRequired {
  all op: Operation | op.authenticated = True
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 — submitter recorded; status reflects decision presence
pred FR_004_SubmitterRecorded {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
  all a: LoanApplication | (some a.decision) iff a.status != PendingReview
}
assert FR_004_SubmitterRecorded { FR_004_SubmitterRecorded }
check FR_004_SubmitterRecorded for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — at most one Pending Review application per customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    (lone a: LoanApplication | a.customer = u and a.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 — staff can view any application (no ownership filter)
pred FR_008_StaffCanView {
  all op: Operation |
    (op.caller.role = BankStaff and op.kind = GetApplicationById and some op.target)
      implies op.visibleResult = True
}
assert FR_008_StaffCanView { FR_008_StaffCanView }
check FR_008_StaffCanView for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 — every recorded decision has a non-empty reason
pred FR_009_NonEmptyReason {
  all d: Decision | d.reasonPresent = True
}
assert FR_009_NonEmptyReason { FR_009_NonEmptyReason }
check FR_009_NonEmptyReason for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 — decided applications carry a matching decision
pred FR_010_DecisionRecorded {
  all a: LoanApplication |
    a.status = Approved implies (some d: a.decision | d.decisionType = DecApproved)
  all a: LoanApplication |
    a.status = Rejected implies (some d: a.decision | d.decisionType = DecRejected)
  all a: LoanApplication | a.status != PendingReview implies some a.decision
}
assert FR_010_DecisionRecorded { FR_010_DecisionRecorded }
check FR_010_DecisionRecorded for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 — decided status/type coherent; pending implies no decision
pred FR_011_DecidedImmutable {
  all a: LoanApplication |
    a.status = Approved implies a.decision.decisionType = DecApproved
  all a: LoanApplication |
    a.status = Rejected implies a.decision.decisionType = DecRejected
  all a: LoanApplication | a.status = PendingReview implies no a.decision
}
assert FR_011_DecidedImmutable { FR_011_DecidedImmutable }
check FR_011_DecidedImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 — at most one decision per application (concurrency winner)
pred FR_012_AtMostOneDecision {
  all a: LoanApplication | lone a.decision
}
assert FR_012_AtMostOneDecision { FR_012_AtMostOneDecision }
check FR_012_AtMostOneDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 — customer can only see their own application
pred FR_013_CustomerOwnAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById
      and some op.target and op.visibleResult = True)
        implies op.target.customer = op.caller
}
assert FR_013_CustomerOwnAccess { FR_013_CustomerOwnAccess }
check FR_013_CustomerOwnAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — only bank staff can decide or read audit
pred FR_015_StaffOnlyDecision {
  all op: Operation | op.kind = PostDecision implies op.caller.role = BankStaff
  all op: Operation | op.kind = GetAudit     implies op.caller.role = BankStaff
}
assert FR_015_StaffOnlyDecision { FR_015_StaffOnlyDecision }
check FR_015_StaffOnlyDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit append-only and at minimum a Submitted entry per application
pred FR_016_AuditAppendOnly {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and e.eventType = Submitted)
}
assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 8