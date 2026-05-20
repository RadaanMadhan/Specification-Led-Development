// === feature_model.als — Alloy model for Loan Application (003-loan-application) ===
// Self-contained Alloy 6 model. Encodes structural invariants from spec.md,
// data-model.md, and contracts/http-api.md. Each named fact is mutation-testable.

// ---------------------- Static enum-like sigs ----------------------

abstract sig Role {}
one sig Customer, BankStaff extends Role {}

abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAudit extends OperationKind {}

abstract sig Status {}
one sig PendingReview, ApprovedS, RejectedS extends Status {}

abstract sig DecisionTypeKind {}
one sig DecApproved, DecRejected extends DecisionTypeKind {}

abstract sig EventType {}
one sig EvtSubmitted, EvtApproved, EvtRejected extends EventType {}

abstract sig Outcome {}
one sig OkSuccess, OkUnauthenticated, OkPermissionDenied, OkNotFound,
        OkAlreadyDecided, OkHasPending, OkValidationError extends Outcome {}

abstract sig Reason {}
sig NonEmptyReason extends Reason {}
sig EmptyReason   extends Reason {}

// ---------------------- Permission matrix ----------------------

one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------------------- Dynamic sigs ----------------------

sig User { role: one Role }

sig Reference {}

sig LoanApplication {
  customer:  one User,
  reference: one Reference,
  status:    one Status
}

sig Decision {
  application:  one LoanApplication,
  decisionType: one DecisionTypeKind,
  reason:       one Reason,
  decidedBy:    one User
}

sig ApplicationEvent {
  application: one LoanApplication,
  eventType:   one EventType,
  actor:       one User
}

sig Notification {
  application: one LoanApplication,
  forStatus:   one Status
}

sig Operation {
  kind:      one OperationKind,
  presented: lone User,            // none = unauthenticated
  target:    lone LoanApplication, // none if no resource targeted
  outcome:   one Outcome
}

// ---------------------- Non-empty universe (anchor for all `all`-quantified preds) ----------------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
  some Operation
  some Reference
}

// ---------------------- Permission matrix population (closed world) ----------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Customer  -> PostApplications)
    + (Customer  -> GetApplications)
    + (Customer  -> GetApplicationByRef)
    + (BankStaff -> GetApplications)
    + (BankStaff -> GetApplicationByRef)
    + (BankStaff -> PostDecision)
    + (BankStaff -> GetAudit)
}

// ---------------------- Domain invariants ----------------------

fact F_ApplicantIsCustomer {
  all a: LoanApplication | a.customer.role = Customer
}

fact F_DeciderIsStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

fact F_UniqueReference {
  all disj a, b: LoanApplication | a.reference != b.reference
}

fact F_OnePendingPerCustomer {
  all u: User |
    lone a: LoanApplication | a.customer = u and a.status = PendingReview
}

fact F_AtMostOneDecisionPerApplication {
  all a: LoanApplication | lone d: Decision | d.application = a
}

fact F_DecisionStatusCorrespondence {
  all a: LoanApplication |
    (a.status in (ApprovedS + RejectedS))
      iff (some d: Decision | d.application = a)
}

fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.decisionType = DecApproved iff d.application.status = ApprovedS)
    and
    (d.decisionType = DecRejected iff d.application.status = RejectedS)
}

fact F_DecisionReasonNonEmpty {
  all d: Decision | d.reason in NonEmptyReason
}

fact F_AuditAppendOnly {
  // No two events share the same (application, eventType) pair.
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}

fact F_AuditCompleteness {
  // Every application carries a 'submitted' event.
  all a: LoanApplication |
    some e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted
  // Approved status implies an 'approved' event.
  all a: LoanApplication | a.status = ApprovedS implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvtApproved)
  // Rejected status implies a 'rejected' event.
  all a: LoanApplication | a.status = RejectedS implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvtRejected)
  // Pending applications have no decision events.
  all a: LoanApplication | a.status = PendingReview implies
    (no e: ApplicationEvent | e.application = a and e.eventType in (EvtApproved + EvtRejected))
}

fact F_AuditAttribution {
  // 'submitted' is attributed to the applicant.
  all e: ApplicationEvent | e.eventType = EvtSubmitted implies
    e.actor = e.application.customer
  // decision events come from staff.
  all e: ApplicationEvent | e.eventType in (EvtApproved + EvtRejected) implies
    e.actor.role = BankStaff
  // decision-event actor matches the recorded decider.
  all e: ApplicationEvent, d: Decision |
    (e.application = d.application and e.eventType in (EvtApproved + EvtRejected))
      implies e.actor = d.decidedBy
}

fact F_AuthRequiredOnEveryOperation {
  // No credentials → must be Unauthenticated.
  all op: Operation | no op.presented implies op.outcome = OkUnauthenticated
  // Unauthenticated outcomes have no presented user.
  all op: Operation | op.outcome = OkUnauthenticated implies no op.presented
}

fact F_PermissionEnforced { /* MUTATED — body cleared by validator */ }

fact F_NoLeakageOnUnauthorisedRead {
  // A customer asking about an application owned by someone else gets NotFound,
  // never PermissionDenied — same shape as a truly non-existent reference.
  all op: Operation |
    (op.kind = GetApplicationByRef and some op.presented and
     op.presented.role = Customer and some op.target and
     op.target.customer != op.presented)
      implies op.outcome = OkNotFound
}

fact F_CustomerOwnershipScoping {
  // A customer's successful single-app fetch always returns an owned application.
  all op: Operation |
    (op.kind = GetApplicationByRef and op.outcome = OkSuccess and
     some op.presented and op.presented.role = Customer and some op.target)
      implies op.target.customer = op.presented
}

fact F_NotificationOnDecision {
  all a: LoanApplication | a.status in (ApprovedS + RejectedS) implies
    (some n: Notification | n.application = a and n.forStatus = a.status)
}

// ============================================================================
// Pattern predicates and assertions
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  some Operation
  // Every successful operation is licensed by the matrix.
  all op: Operation | op.outcome = OkSuccess implies
    (some op.presented and op.presented.role -> op.kind in PermMatrix.Allowed)
  // Customer never successfully decides or reads audit.
  all op: Operation |
    (op.kind in (PostDecision + GetAudit) and some op.presented and
     op.presented.role = Customer)
      implies op.outcome != OkSuccess
  // Staff never successfully POSTs an application (customer-only action).
  all op: Operation |
    (op.kind = PostApplications and some op.presented and
     op.presented.role = BankStaff)
      implies op.outcome != OkSuccess
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every documented allow cell is in the matrix.
  Customer  -> PostApplications     in PermMatrix.Allowed
  Customer  -> GetApplications      in PermMatrix.Allowed
  Customer  -> GetApplicationByRef  in PermMatrix.Allowed
  BankStaff -> GetApplications      in PermMatrix.Allowed
  BankStaff -> GetApplicationByRef  in PermMatrix.Allowed
  BankStaff -> PostDecision         in PermMatrix.Allowed
  BankStaff -> GetAudit             in PermMatrix.Allowed
  // Every documented deny cell is not in the matrix.
  Customer  -> PostDecision     not in PermMatrix.Allowed
  Customer  -> GetAudit         not in PermMatrix.Allowed
  BankStaff -> PostApplications not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001/FR-009/FR-013/FR-015/FR-016
pred PermissionGrounding {
  // FR-001 grants customer POST /applications.
  Customer  -> PostApplications    in PermMatrix.Allowed
  // FR-013 grants customer read of own applications.
  Customer  -> GetApplicationByRef in PermMatrix.Allowed
  Customer  -> GetApplications     in PermMatrix.Allowed
  // FR-009 / FR-010 grants staff decisioning.
  BankStaff -> PostDecision        in PermMatrix.Allowed
  // FR-016 grants staff audit access.
  BankStaff -> GetAudit            in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some Operation
  // Unauthenticated requests are always rejected with Unauthenticated.
  all op: Operation | no op.presented implies op.outcome = OkUnauthenticated
  // Successful operations always carry a presented user.
  all op: Operation | op.outcome = OkSuccess implies some op.presented
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  // Each application has a submitted event.
  all a: LoanApplication |
    some e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted
  // Each approved/rejected app has the corresponding decision event.
  all a: LoanApplication | a.status = ApprovedS implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvtApproved)
  all a: LoanApplication | a.status = RejectedS implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvtRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-011; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // No two events share the same (application, eventType) — duplicates are forbidden,
  // which structurally rules out re-write/replacement.
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  all e: ApplicationEvent | e.eventType = EvtSubmitted implies
    e.actor = e.application.customer
  all e: ApplicationEvent | e.eventType in (EvtApproved + EvtRejected) implies
    e.actor.role = BankStaff
  all e: ApplicationEvent, d: Decision |
    (e.application = d.application and e.eventType in (EvtApproved + EvtRejected))
      implies e.actor = d.decidedBy
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id FK; spec.md Customer entity
pred OwnershipExclusivity {
  some LoanApplication
  // Each application has exactly one owner.
  all a: LoanApplication | one a.customer
  // The owner is a customer, not staff.
  all a: LoanApplication | a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts GetApplicationByRef
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = GetApplicationByRef and op.outcome = OkSuccess and
     some op.presented and op.presented.role = Customer and some op.target)
      implies op.target.customer = op.presented
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md 404 vs 403
pred NoInformationLeakage {
  // Customer asking about an unowned application gets NotFound, never PermissionDenied —
  // we must not let the caller distinguish "exists but not yours" from "doesn't exist".
  all op: Operation |
    (op.kind = GetApplicationByRef and some op.presented and
     op.presented.role = Customer and some op.target and
     op.target.customer != op.presented)
      implies op.outcome = OkNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ============================================================================
// FR-specific predicates and assertions
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 customer submits a personal loan application
pred FR_001_CustomerSubmitsApplication {
  some LoanApplication
  all a: LoanApplication | a.customer.role = Customer
  Customer  -> PostApplications     in PermMatrix.Allowed
  BankStaff -> PostApplications not in PermMatrix.Allowed
}
assert FR_001_CustomerSubmitsApplication { FR_001_CustomerSubmitsApplication }
check FR_001_CustomerSubmitsApplication for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 field-level validation produces no side effects
pred FR_002_ValidationBeforeMutation {
  // A validation-error outcome cannot coexist with an audit event for that
  // operation's target application (rejection on submit must not append).
  all op: Operation |
    (op.outcome = OkValidationError and op.kind = PostApplications)
      implies no op.target
}
assert FR_002_ValidationBeforeMutation { FR_002_ValidationBeforeMutation }
check FR_002_ValidationBeforeMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique reference number per application
pred FR_004_UniqueReference {
  some LoanApplication
  all disj a, b: LoanApplication | a.reference != b.reference
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 one pending review per customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    lone a: LoanApplication | a.customer = u and a.status = PendingReview
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 decision requires a non-empty reason
pred FR_009_DecisionReasonNonEmpty {
  all d: Decision | d.reason in NonEmptyReason
}
assert FR_009_DecisionReasonNonEmpty { FR_009_DecisionReasonNonEmpty }
check FR_009_DecisionReasonNonEmpty for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision persisted; status changes accordingly
pred FR_010_DecisionPersistsAndStatusChanges {
  // Decisions only exist on decided applications.
  all d: Decision | d.application.status in (ApprovedS + RejectedS)
  // Decision type aligns with the resulting status.
  all d: Decision |
    (d.decisionType = DecApproved iff d.application.status = ApprovedS) and
    (d.decisionType = DecRejected iff d.application.status = RejectedS)
}
assert FR_010_DecisionPersistsAndStatusChanges { FR_010_DecisionPersistsAndStatusChanges }
check FR_010_DecisionPersistsAndStatusChanges for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 decided application is immutable
pred FR_011_DecidedImmutable {
  // Decided applications must have an associated decision (never reverted).
  all a: LoanApplication | a.status in (ApprovedS + RejectedS) implies
    (one d: Decision | d.application = a)
}
assert FR_011_DecidedImmutable { FR_011_DecidedImmutable }
check FR_011_DecidedImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 at most one decision per application
pred FR_012_OnlyOneDecision {
  all a: LoanApplication | lone d: Decision | d.application = a
}
assert FR_012_OnlyOneDecision { FR_012_OnlyOneDecision }
check FR_012_OnlyOneDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer sees only own application
pred FR_013_CustomerSeesOnlyOwn {
  all op: Operation |
    (op.kind = GetApplicationByRef and op.outcome = OkSuccess and
     some op.presented and op.presented.role = Customer and some op.target)
      implies op.target.customer = op.presented
}
assert FR_013_CustomerSeesOnlyOwn { FR_013_CustomerSeesOnlyOwn }
check FR_013_CustomerSeesOnlyOwn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 notification on decision
pred FR_014_NotificationOnDecision {
  all a: LoanApplication | a.status in (ApprovedS + RejectedS) implies
    (some n: Notification | n.application = a and n.forStatus = a.status)
}
assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 staff-only decision and audit actions
pred FR_015_StaffOnlyDecisions {
  all d: Decision | d.decidedBy.role = BankStaff
  Customer -> PostDecision not in PermMatrix.Allowed
  Customer -> GetAudit     not in PermMatrix.Allowed
  // No successful decision/audit operation by a customer.
  all op: Operation |
    (op.kind in (PostDecision + GetAudit) and op.outcome = OkSuccess and
     some op.presented)
      implies op.presented.role = BankStaff
}
assert FR_015_StaffOnlyDecisions { FR_015_StaffOnlyDecisions }
check FR_015_StaffOnlyDecisions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail of status changes (append-only)
pred FR_016_AuditTrail {
  some LoanApplication
  all a: LoanApplication |
    some e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted
  all a: LoanApplication | a.status = ApprovedS implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvtApproved)
  all a: LoanApplication | a.status = RejectedS implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvtRejected)
  // No duplicate event entries.
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 retention (no DELETE path) — append-only on events and decisions
pred FR_017_RetentionAppendOnly {
  // No two decisions for the same application (no replacement / deletion-then-re-insert).
  all a: LoanApplication | lone d: Decision | d.application = a
  // No two events for the same (app, type).
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}
assert FR_017_RetentionAppendOnly { FR_017_RetentionAppendOnly }
check FR_017_RetentionAppendOnly for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeastPrivilegeViolation { some op: Operation | op.kind = PostDecision and some op.presented and op.presented.role = Customer and op.outcome = OkSuccess }
