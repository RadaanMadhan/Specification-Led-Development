// === feature_model.als — Alloy model for Loan Application (003-loan-application) ===
// Self-contained Alloy 6 model encoding the structural invariants of the
// loan application feature: roles, permission matrix, ownership-based
// access, audit append-only, single pending application per customer,
// decision/status alignment, and audit attribution.

// -----------------------------------------------------------------------
// Non-empty universe: ensures predicates that look at instances of dynamic
// sigs do not pass vacuously under the default `for 5` scope.
// -----------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
  some Reason
}

// -----------------------------------------------------------------------
// Roles and operations
// -----------------------------------------------------------------------
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

abstract sig OperationKind {}
one sig OpSubmit, OpListApps, OpGetApp, OpDecide, OpGetAudit extends OperationKind {}

abstract sig Status {}
one sig StPending, StApproved, StRejected extends Status {}

abstract sig DecisionType {}
one sig DtApproved, DtRejected extends DecisionType {}

abstract sig EventType {}
one sig EvSubmitted, EvApproved, EvRejected extends EventType {}

abstract sig Outcome {}
one sig OutAllow, OutDeny, OutNotFound extends Outcome {}

// -----------------------------------------------------------------------
// Permission matrix as a singleton-sig field. Mirrors the table in
// contracts/http-api.md exactly: customer can submit/list/get; staff can
// list/get/decide/audit; staff cannot submit; customer cannot decide
// or read audit log.
// -----------------------------------------------------------------------
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole  -> OpSubmit)     +
    (CustomerRole  -> OpListApps)   +
    (CustomerRole  -> OpGetApp)     +
    (BankStaffRole -> OpListApps)   +
    (BankStaffRole -> OpGetApp)     +
    (BankStaffRole -> OpDecide)     +
    (BankStaffRole -> OpGetAudit)
}

// -----------------------------------------------------------------------
// Domain entities
// -----------------------------------------------------------------------
sig User {
  role: one Role
}

sig Reason {} // opaque token for "non-empty reason"

sig LoanApplication {
  customer:    one User,
  status:      one Status,
  appDecision: lone Decision
}

sig Decision {
  decType:    one DecisionType,
  reason:     one Reason,
  decidedBy:  one User
}

sig ApplicationEvent {
  application: one LoanApplication,
  eventType:   one EventType,
  actor:       one User
}

// Abstract API call. invoker is `lone` so "unauthenticated" is encoded
// as absence of invoker. target is `lone` because not every kind has one.
sig Operation {
  invoker: lone User,
  kind:    one OperationKind,
  target:  lone LoanApplication,
  outcome: one Outcome
}

// -----------------------------------------------------------------------
// Structural facts (named so the validator can mutate them by name)
// -----------------------------------------------------------------------

// data-model.md: loan_applications.customer_id references a user; that
// user must have the customer role.
fact F_CustomerHasCustomerRole {
  all a: LoanApplication | a.customer.role = CustomerRole
}

// FR-015 / data-model.md: decisions are made by staff.
fact F_DecisionMadeByStaff {
  all d: Decision | d.decidedBy.role = BankStaffRole
}

// data-model.md: decisions.application_id PRIMARY KEY -> one-to-one with app.
fact F_DecisionBelongsToOneApp {
  all d: Decision | (one a: LoanApplication | a.appDecision = d)
}

// FR-010 + FR-011: a decision exists iff status is decided, and the
// decision type aligns with the post-decision status.
fact F_DecisionStatusAlignment {
  all a: LoanApplication |
    (some a.appDecision) iff (a.status in (StApproved + StRejected))
  all a: LoanApplication |
    some a.appDecision implies (
      (a.appDecision.decType = DtApproved iff a.status = StApproved) and
      (a.appDecision.decType = DtRejected iff a.status = StRejected)
    )
}

// FR-005 / data-model.md idx_one_pending_per_customer: at most one
// Pending Review application per customer at a time.
fact F_OnePendingPerCustomer {
  all c: User | (lone a: LoanApplication | a.customer = c and a.status = StPending)
}

// FR-016: every status-changing event is recorded in the audit log.
// Use `some` (not `one`) so the AppendOnly fact is the only enforcer of
// uniqueness, letting the AppendOnly mutation actually bite.
fact F_AuditEventsExist {
  all a: LoanApplication |
    (some e: ApplicationEvent | e.application = a and e.eventType = EvSubmitted)
  all a: LoanApplication |
    a.status = StApproved implies
      (some e: ApplicationEvent | e.application = a and e.eventType = EvApproved)
  all a: LoanApplication |
    a.status = StRejected implies
      (some e: ApplicationEvent | e.application = a and e.eventType = EvRejected)
}

// FR-016 attribution: submitted events attribute to the customer;
// approve/reject events attribute to the deciding staff member.
fact F_EventActorAttribution {
  all e: ApplicationEvent |
    e.eventType = EvSubmitted implies e.actor = e.application.customer
  all e: ApplicationEvent |
    e.eventType in (EvApproved + EvRejected) implies
      (some e.application.appDecision and
       e.actor = e.application.appDecision.decidedBy)
}

// FR-016 / FR-017 append-only: no two distinct events share the same
// (application, eventType). A second event of the same kind on the same
// application would represent either a duplicate or a rewrite — both
// forbidden.
fact F_AppendOnlyAuditLog {
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}

// LeastPrivilege backbone: any Operation with outcome=Allow requires an
// authenticated invoker whose role grants the operation kind.
fact F_AccessControlOnOperations {
  all op: Operation |
    op.outcome = OutAllow implies
      (some op.invoker and (op.invoker.role -> op.kind) in PermMatrix.Allowed)
}

// FR-013 + contracts: a customer reading a specific application is only
// allowed if the application belongs to them.
fact F_OwnershipForCustomerRead { /* MUTATED — body cleared by validator */ }

// FR-013 + contracts no-leak rule: customer asking about a non-owned
// application gets 404 not_found (not 403 deny). Encoded with
// `not op.outcome = OutAllow` antecedent so the OwnershipBasedAccess
// mutation (Allow + non-owned) doesn't get blocked by this fact, and
// vice-versa: the NoInformationLeakage mutation (Deny + non-owned) isn't
// blocked by F_OwnershipForCustomerRead.
fact F_NoLeakOnNonOwnedRead {
  all op: Operation |
    (op.kind = OpGetApp and some op.invoker
     and op.invoker.role = CustomerRole
     and some op.target and op.target.customer != op.invoker
     and not op.outcome = OutAllow)
    implies op.outcome = OutNotFound
}

// -----------------------------------------------------------------------
// Pattern predicates and assertions
// -----------------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = OutAllow implies
      (some op.invoker and (op.invoker.role -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  (CustomerRole -> OpSubmit)      in PermMatrix.Allowed
  (CustomerRole -> OpListApps)    in PermMatrix.Allowed
  (CustomerRole -> OpGetApp)      in PermMatrix.Allowed
  not ((CustomerRole -> OpDecide)   in PermMatrix.Allowed)
  not ((CustomerRole -> OpGetAudit) in PermMatrix.Allowed)
  (BankStaffRole -> OpListApps)   in PermMatrix.Allowed
  (BankStaffRole -> OpGetApp)     in PermMatrix.Allowed
  (BankStaffRole -> OpDecide)     in PermMatrix.Allowed
  (BankStaffRole -> OpGetAudit)   in PermMatrix.Allowed
  not ((BankStaffRole -> OpSubmit) in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.outcome = OutAllow implies (some op.invoker)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  all a: LoanApplication |
    (some e: ApplicationEvent | e.application = a and e.eventType = EvSubmitted)
  all a: LoanApplication | a.status = StApproved implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvApproved)
  all a: LoanApplication | a.status = StRejected implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some ApplicationEvent
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  some ApplicationEvent
  all e: ApplicationEvent |
    e.eventType = EvSubmitted implies e.actor = e.application.customer
  all e: ApplicationEvent |
    e.eventType in (EvApproved + EvRejected) implies
      (some e.application.appDecision and
       e.actor = e.application.appDecision.decidedBy)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id NOT NULL
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.customer and a.customer.role = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.kind = OpGetApp and some op.invoker
     and op.invoker.role = CustomerRole and op.outcome = OutAllow)
    implies (some op.target and op.target.customer = op.invoker)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md "404 not 403"
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    (op.kind = OpGetApp and some op.invoker
     and op.invoker.role = CustomerRole
     and some op.target and op.target.customer != op.invoker
     and not op.outcome = OutAllow)
    implies op.outcome = OutNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// -----------------------------------------------------------------------
// Feature-specific FR predicates (one per FR-NNN in spec.md)
// -----------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 — only authenticated customers may submit applications
pred FR_001_CustomerSubmits {
  some Operation
  all op: Operation |
    (op.kind = OpSubmit and op.outcome = OutAllow) implies
      (some op.invoker and op.invoker.role = CustomerRole)
}
assert FR_001_CustomerSubmits { FR_001_CustomerSubmits }
check FR_001_CustomerSubmits for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — validation rejects malformed submissions (structural backstop: every persisted app has all mandatory fields populated)
pred FR_002_StructuralValidation {
  some LoanApplication
  all a: LoanApplication | one a.customer and one a.status
  all d: Decision | one d.decType and one d.reason and one d.decidedBy
}
assert FR_002_StructuralValidation { FR_002_StructuralValidation }
check FR_002_StructuralValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — only the defined statuses are reachable
pred FR_003_StatusEnumClosed {
  some LoanApplication
  all a: LoanApplication | a.status in (StPending + StApproved + StRejected)
}
assert FR_003_StatusEnumClosed { FR_003_StatusEnumClosed }
check FR_003_StatusEnumClosed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — every persisted application has a unique owner customer and a status
pred FR_004_AppHasOwnerAndStatus {
  some LoanApplication
  all a: LoanApplication | one a.customer and one a.status and a.customer.role = CustomerRole
}
assert FR_004_AppHasOwnerAndStatus { FR_004_AppHasOwnerAndStatus }
check FR_004_AppHasOwnerAndStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — at most one Pending Review application per customer
pred FR_005_OnePendingPerCustomer {
  some LoanApplication
  all c: User | (lone a: LoanApplication | a.customer = c and a.status = StPending)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 — successful submission produces a Pending Review status
pred FR_006_SubmissionYieldsPending {
  some LoanApplication
  all a: LoanApplication | no a.appDecision implies a.status = StPending
}
assert FR_006_SubmissionYieldsPending { FR_006_SubmissionYieldsPending }
check FR_006_SubmissionYieldsPending for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 — staff can access the pending queue
pred FR_007_StaffCanList {
  (BankStaffRole -> OpListApps) in PermMatrix.Allowed
}
assert FR_007_StaffCanList { FR_007_StaffCanList }
check FR_007_StaffCanList for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 — staff can fetch any application detail
pred FR_008_StaffCanGetApp {
  (BankStaffRole -> OpGetApp) in PermMatrix.Allowed
}
assert FR_008_StaffCanGetApp { FR_008_StaffCanGetApp }
check FR_008_StaffCanGetApp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — every decision carries a reason
pred FR_009_DecisionHasReason {
  some Decision
  all d: Decision | one d.reason
}
assert FR_009_DecisionHasReason { FR_009_DecisionHasReason }
check FR_009_DecisionHasReason for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — decided application status matches decision type
pred FR_010_DecisionStatusAligned {
  some LoanApplication
  all a: LoanApplication |
    (some a.appDecision) iff (a.status in (StApproved + StRejected))
  all a: LoanApplication | some a.appDecision implies
    ((a.appDecision.decType = DtApproved iff a.status = StApproved) and
     (a.appDecision.decType = DtRejected iff a.status = StRejected))
}
assert FR_010_DecisionStatusAligned { FR_010_DecisionStatusAligned }
check FR_010_DecisionStatusAligned for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — decided applications are immutable (exactly one decision; no further state change)
pred FR_011_DecidedImmutable {
  some LoanApplication
  all a: LoanApplication |
    a.status in (StApproved + StRejected) implies (one a.appDecision)
}
assert FR_011_DecidedImmutable { FR_011_DecidedImmutable }
check FR_011_DecidedImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — at most one decision per application (concurrent-decide safety)
pred FR_012_OneDecisionPerApp {
  some LoanApplication
  all a: LoanApplication | lone a.appDecision
  all d: Decision | (one a: LoanApplication | a.appDecision = d)
}
assert FR_012_OneDecisionPerApp { FR_012_OneDecisionPerApp }
check FR_012_OneDecisionPerApp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — a customer cannot read another customer's application
pred FR_013_CustomerOnlySeesOwn {
  some Operation
  all op: Operation |
    (op.kind = OpGetApp and some op.invoker
     and op.invoker.role = CustomerRole and op.outcome = OutAllow)
    implies (some op.target and op.target.customer = op.invoker)
}
assert FR_013_CustomerOnlySeesOwn { FR_013_CustomerOnlySeesOwn }
check FR_013_CustomerOnlySeesOwn for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 — decided applications produce a recorded decision-event for notification
pred FR_014_DecisionEventRecorded {
  some LoanApplication
  all a: LoanApplication | a.status = StApproved implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvApproved)
  all a: LoanApplication | a.status = StRejected implies
    (some e: ApplicationEvent | e.application = a and e.eventType = EvRejected)
}
assert FR_014_DecisionEventRecorded { FR_014_DecisionEventRecorded }
check FR_014_DecisionEventRecorded for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — only bank staff may decide; customers cannot
pred FR_015_OnlyStaffCanDecide {
  some Operation
  all op: Operation |
    (op.kind = OpDecide and op.outcome = OutAllow) implies
      (some op.invoker and op.invoker.role = BankStaffRole)
  not ((CustomerRole -> OpDecide) in PermMatrix.Allowed)
  not ((CustomerRole -> OpGetAudit) in PermMatrix.Allowed)
}
assert FR_015_OnlyStaffCanDecide { FR_015_OnlyStaffCanDecide }
check FR_015_OnlyStaffCanDecide for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-016 — every status change has an audit event with an actor
pred FR_016_AuditTrailComplete {
  some ApplicationEvent
  all a: LoanApplication |
    (some e: ApplicationEvent | e.application = a and e.eventType = EvSubmitted)
  all e: ApplicationEvent | one e.actor
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — retention via append-only: no duplicate or rewritten audit entries
pred FR_017_RetentionAppendOnly {
  some ApplicationEvent
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}
assert FR_017_RetentionAppendOnly { FR_017_RetentionAppendOnly }
check FR_017_RetentionAppendOnly for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OwnershipBased { some op: Operation, c: User, a: LoanApplication | op.invoker = c and c.role = CustomerRole and op.kind = OpGetApp and op.target = a and a.customer != c and op.outcome = OutAllow }
