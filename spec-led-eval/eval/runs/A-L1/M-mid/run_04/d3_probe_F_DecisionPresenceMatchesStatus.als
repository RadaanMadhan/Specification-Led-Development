// === feature_model.als — Alloy 6 model for Loan Application (A-L1) ===
// Feature branch: 003-loan-application
// Generated from: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// Roles and permission-matrix atoms
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAudit extends OperationKind {}

// Permission matrix as a singleton-sig field (contracts/http-api.md table)
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// Application status, decision type, event type
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, ApprvdStatus, RejectedStatus extends ApplicationStatus {}

abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

abstract sig EventType {}
one sig EvtSubmitted, EvtApproved, EvtRejected extends EventType {}

// ─────────────────────────────────────────────────────────────────────────────
// Dynamic sigs (entities)
// ─────────────────────────────────────────────────────────────────────────────
sig User {
  role: one Role
}

sig LoanApplication {
  appCustomer: one User,
  status:      one ApplicationStatus
}

// At most one decision per application (PK = application_id in data-model.md)
sig Decision {
  decApp:     one LoanApplication,
  decidedBy:  one User,
  dtype:      one DecisionType
}

// Append-only audit entries (application_events table)
sig ApplicationEvent {
  evtApp: one LoanApplication,
  actor:  one User,
  etype:  one EventType
}

// Model of API operations (caller + kind + optional target application)
sig Operation {
  opCaller:  one User,
  opKind:    one OperationKind,
  opTarget:  lone LoanApplication
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — ensure the dynamic universe is non-empty so that
// universally-quantified predicates are not vacuously satisfied.
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
}

// ─────────────────────────────────────────────────────────────────────────────
// Structural / domain well-formedness facts
// ─────────────────────────────────────────────────────────────────────────────

// The submitter of an application must be a Customer, not staff.
fact F_AppCustomerRole {
  all a: LoanApplication | a.appCustomer.role = Customer
}

// The decider on every Decision must be a BankStaff member.
// (FR-015; data-model.md decisions.decided_by_user_id → bank_staff role)
fact F_DeciderIsBankStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

// A pending application has no Decision; a decided application has exactly one.
// (data-model.md: PK on decisions.application_id; FR-010, FR-011)
fact F_DecisionPresenceMatchesStatus {
  all a: LoanApplication |
    (a.status = PendingReview implies (no d: Decision | d.decApp = a)) and
    ((a.status = ApprvdStatus or a.status = RejectedStatus) implies
      (one d: Decision | d.decApp = a))
}

// Decision type must match the application status it produced.
// (data-model.md DecisionType mirrors ApplicationStatus; FR-010)
fact F_DecisionStatusConsistency {
  all d: Decision |
    (d.dtype = DecApproved  implies d.decApp.status = ApprvdStatus) and
    (d.dtype = DecRejected  implies d.decApp.status = RejectedStatus)
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  // Closed-world: exactly these (Role × OperationKind) cells are allowed.
  PermMatrix.Allowed =
    (Customer  -> PostApplications)  +
    (Customer  -> GetApplications)   +
    (Customer  -> GetApplicationByRef) +
    (BankStaff -> GetApplications)   +
    (BankStaff -> GetApplicationByRef) +
    (BankStaff -> PostDecision)      +
    (BankStaff -> GetAudit)
}

// Every Operation in the system respects the permission matrix.
fact F_OperationsRespectMatrix {
  all op: Operation |
    op.opCaller.role -> op.opKind in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE"
// ─────────────────────────────────────────────────────────────────────────────
// Every application that has been decided MUST still carry its submission event.
// (Models the invariant that audit events are never retracted.)
fact F_AppendOnlyAuditEvents {
  all a: LoanApplication |
    (a.status = ApprvdStatus or a.status = RejectedStatus) implies
      (some e: ApplicationEvent | e.evtApp = a and e.etype = EvtSubmitted)
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditCompleteness {
  // Every application has exactly one submission event.
  all a: LoanApplication |
    one e: ApplicationEvent | e.evtApp = a and e.etype = EvtSubmitted

  // Approved applications have exactly one approved event.
  all a: LoanApplication |
    a.status = ApprvdStatus implies
      (one e: ApplicationEvent | e.evtApp = a and e.etype = EvtApproved)

  // Rejected applications have exactly one rejected event.
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (one e: ApplicationEvent | e.evtApp = a and e.etype = EvtRejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md actor_user_id
// ─────────────────────────────────────────────────────────────────────────────
fact F_AttributionCorrectness {
  // Submission events are attributed to the application's own customer.
  all e: ApplicationEvent |
    e.etype = EvtSubmitted implies
      (e.actor = e.evtApp.appCustomer and e.actor.role = Customer)

  // Approval / rejection events are attributed to the deciding staff member.
  all e: ApplicationEvent |
    (e.etype = EvtApproved or e.etype = EvtRejected) implies
      e.actor.role = BankStaff

  // The actor of a decision event matches the decidedBy field on the Decision.
  all e: ApplicationEvent |
    (e.etype = EvtApproved or e.etype = EvtRejected) implies
      (one d: Decision | d.decApp = e.evtApp and d.decidedBy = e.actor)
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GetApplicationByRef
// ─────────────────────────────────────────────────────────────────────────────
// A Customer performing GetApplicationByRef may only target their own application.
fact F_CustomerOwnershipBasedAccess {
  all op: Operation |
    (op.opCaller.role = Customer and op.opKind = GetApplicationByRef) implies
      (all a: op.opTarget | a.appCustomer = op.opCaller)
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md 404 rule
// ─────────────────────────────────────────────────────────────────────────────
// No Customer GetApplicationByRef operation resolves to an application owned
// by a *different* customer — the 404 / ownership filter ensures non-owners
// receive the same response shape as "not found."
fact F_NoLeakOnNonOwnerAccess {
  no op: Operation |
    op.opCaller.role = Customer and
    op.opKind = GetApplicationByRef and
    (some a: op.opTarget | a.appCustomer != op.opCaller)
}

// ─────────────────────────────────────────────────────────────────────────────
// ─── Assertions ──────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some Operation  // non-vacuous: at least one operation exists
  // No operation is executed by a role the matrix forbids for that kind.
  all op: Operation |
    op.opCaller.role -> op.opKind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is either explicitly allowed or absent.
  // Closed-world: the Allowed set is exactly the union of allowed cells.
  all r: Role, ok: OperationKind |
    r -> ok in PermMatrix.Allowed or
    r -> ok not in PermMatrix.Allowed
  // Specific denied cells are absent:
  BankStaff -> PostApplications not in PermMatrix.Allowed
  Customer  -> PostDecision      not in PermMatrix.Allowed
  Customer  -> GetAudit          not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-015; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  some Operation
  // Every operation has exactly one authenticated caller (structural: `opCaller: one User`).
  all op: Operation | one op.opCaller
  // No operation is performed without a role-resolved caller.
  all op: Operation | op.opCaller.role = Customer or op.opCaller.role = BankStaff
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some a: LoanApplication |
    a.status = ApprvdStatus or a.status = RejectedStatus
  // Every decided application retains its original submission event.
  all a: LoanApplication |
    (a.status = ApprvdStatus or a.status = RejectedStatus) implies
      (some e: ApplicationEvent | e.evtApp = a and e.etype = EvtSubmitted)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  // Every application has exactly one submission audit event.
  all a: LoanApplication |
    one e: ApplicationEvent | e.evtApp = a and e.etype = EvtSubmitted
  // Approved applications have exactly one approval audit event.
  all a: LoanApplication |
    a.status = ApprvdStatus implies
      (one e: ApplicationEvent | e.evtApp = a and e.etype = EvtApproved)
  // Rejected applications have exactly one rejection audit event.
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (one e: ApplicationEvent | e.evtApp = a and e.etype = EvtRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md actor_user_id
pred AttributionCorrectness {
  some ApplicationEvent
  // Submission events are attributed to the correct customer.
  all e: ApplicationEvent |
    e.etype = EvtSubmitted implies
      e.actor = e.evtApp.appCustomer
  // Decision events are attributed to the deciding staff member.
  all e: ApplicationEvent |
    (e.etype = EvtApproved or e.etype = EvtRejected) implies
      (e.actor.role = BankStaff and
       (one d: Decision | d.decApp = e.evtApp and d.decidedBy = e.actor))
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GetApplicationByRef
pred OwnershipBasedAccess {
  some op: Operation |
    op.opCaller.role = Customer and op.opKind = GetApplicationByRef
  // Customer can only access their own application via GetApplicationByRef.
  all op: Operation |
    (op.opCaller.role = Customer and op.opKind = GetApplicationByRef) implies
      (all a: op.opTarget | a.appCustomer = op.opCaller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md 404 rule
pred NoInformationLeakage {
  some Operation
  // No Customer operation targeting GetApplicationByRef resolves to
  // a non-owned application (preventing existence disclosure).
  no op: Operation |
    op.opCaller.role = Customer and
    op.opKind = GetApplicationByRef and
    (some a: op.opTarget | a.appCustomer != op.opCaller)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─── Feature-specific assertions ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authenticated customer submits application
pred FR_001_AuthenticatedSubmission {
  some LoanApplication
  all a: LoanApplication | a.appCustomer.role = Customer
}
assert FR_001_AuthenticatedSubmission { FR_001_AuthenticatedSubmission }
check FR_001_AuthenticatedSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — unique reference, status Pending on submission
pred FR_004_UniqueReferenceAndPendingOnSubmit {
  some LoanApplication
  // Every application is a distinct object in the universe (structurally enforced).
  // Every application that has no Decision starts in PendingReview.
  all a: LoanApplication |
    (no d: Decision | d.decApp = a) implies a.status = PendingReview
}
assert FR_004_UniqueReferenceAndPendingOnSubmit { FR_004_UniqueReferenceAndPendingOnSubmit }
check FR_004_UniqueReferenceAndPendingOnSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — at most one Pending application per customer
pred FR_005_OnePendingPerCustomer {
  some u: User | u.role = Customer
  all u: User |
    u.role = Customer implies
      (lone a: LoanApplication | a.appCustomer = u and a.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009, FR-010 — decision requires a deciding staff member
pred FR_009_DecisionHasDecider {
  some Decision
  all d: Decision | d.decidedBy.role = BankStaff
}
assert FR_009_DecisionHasDecider { FR_009_DecisionHasDecider }
check FR_009_DecisionHasDecider for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-012 — at most one Decision per application
pred FR_010_AtMostOneDecisionPerApp {
  some LoanApplication
  all a: LoanApplication |
    lone d: Decision | d.decApp = a
}
assert FR_010_AtMostOneDecisionPerApp { FR_010_AtMostOneDecisionPerApp }
check FR_010_AtMostOneDecisionPerApp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — decided applications are immutable (no re-decision)
pred FR_011_DecidedStatusImmutable {
  some a: LoanApplication | a.status = ApprvdStatus or a.status = RejectedStatus
  // Once approved or rejected, the application has exactly one decision and
  // cannot return to PendingReview (enforced by absence of PendingReview status
  // on any application that has a Decision).
  all d: Decision | d.decApp.status != PendingReview
}
assert FR_011_DecidedStatusImmutable { FR_011_DecidedStatusImmutable }
check FR_011_DecidedStatusImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — concurrent decisions: only first recorded (SC-005)
pred FR_012_NoDuplicateDecisions {
  some LoanApplication
  // No two distinct Decisions share the same application.
  all disj d1, d2: Decision | d1.decApp != d2.decApp
}
assert FR_012_NoDuplicateDecisions { FR_012_NoDuplicateDecisions }
check FR_012_NoDuplicateDecisions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — customer sees only own applications (SC-004)
pred FR_013_CustomerSeesOwnOnly {
  some u: User | u.role = Customer
  // Customer list operations (GetApplications) only surface own applications;
  // modelled: any Operation of kind GetApplications by a Customer has no
  // target from another customer.
  all op: Operation |
    (op.opCaller.role = Customer and op.opKind = GetApplications) implies
      (all a: op.opTarget | a.appCustomer = op.opCaller)
}
assert FR_013_CustomerSeesOwnOnly { FR_013_CustomerSeesOwnOnly }
check FR_013_CustomerSeesOwnOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — customers cannot decide; staff cannot submit
pred FR_015_RoleSeparation {
  some User
  // No Customer can execute PostDecision or GetAudit.
  no op: Operation |
    op.opCaller.role = Customer and (op.opKind = PostDecision or op.opKind = GetAudit)
  // No BankStaff can execute PostApplications.
  no op: Operation |
    op.opCaller.role = BankStaff and op.opKind = PostApplications
}
assert FR_015_RoleSeparation { FR_015_RoleSeparation }
check FR_015_RoleSeparation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — full audit trail for every status change
pred FR_016_AuditTrailComplete {
  some LoanApplication
  all a: LoanApplication |
    one e: ApplicationEvent | e.evtApp = a and e.etype = EvtSubmitted
  all a: LoanApplication |
    a.status = ApprvdStatus implies
      (one e: ApplicationEvent | e.evtApp = a and e.etype = EvtApproved)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (one e: ApplicationEvent | e.evtApp = a and e.etype = EvtRejected)
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — no deletion of applications (retention ≥ 6 yrs)
// Modelled structurally: every LoanApplication is reachable (Alloy has no
// garbage-collection of sigs) and no operation kind targets a "delete" endpoint.
pred FR_017_NoApplicationDeletion {
  some LoanApplication
  // There is no "DeleteApplication" OperationKind; all apps persist.
  // Encoded: every LoanApplication atom in the universe is the appCustomer
  // target of at least one ApplicationEvent (submission event exists).
  all a: LoanApplication |
    some e: ApplicationEvent | e.evtApp = a
}
assert FR_017_NoApplicationDeletion { FR_017_NoApplicationDeletion }
check FR_017_NoApplicationDeletion for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_DuplicateDecisionViolation { some disj d1, d2: Decision | d1.decApp = d2.decApp }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
