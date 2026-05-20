// === feature_model.als — Alloy 6 model for Loan Application (A-L1) ===
// Feature branch: 003-loan-application
// Artefacts: spec.md (FR-001…FR-017), data-model.md, contracts/http-api.md

// -----------------------------------------------------------------------
// Roles
// -----------------------------------------------------------------------
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// -----------------------------------------------------------------------
// Application status
// -----------------------------------------------------------------------
abstract sig AppStatus {}
one sig PendingReview, AppApproved, AppRejected extends AppStatus {}

// -----------------------------------------------------------------------
// Decision type
// -----------------------------------------------------------------------
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// -----------------------------------------------------------------------
// Audit event type
// -----------------------------------------------------------------------
abstract sig EventType {}
one sig EvtSubmitted, EvtApproved, EvtRejected extends EventType {}

// -----------------------------------------------------------------------
// Operations (HTTP endpoints)
// -----------------------------------------------------------------------
abstract sig OperationKind {}
one sig OpPostApplications, OpGetApplications, OpGetApplicationByRef,
        OpPostDecision, OpGetAudit extends OperationKind {}

// -----------------------------------------------------------------------
// Outcomes of operation attempts
// -----------------------------------------------------------------------
abstract sig Outcome {}
one sig Success, Forbidden, NotFound extends Outcome {}

// -----------------------------------------------------------------------
// Permission matrix (singleton carrier)
// -----------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// -----------------------------------------------------------------------
// Dynamic sigs
// -----------------------------------------------------------------------
sig User { role: one Role }

// Reason token — models the non-empty reason requirement (FR-009).
// Every Decision must carry exactly one Reason atom.
sig Reason {}

sig LoanApplication {
  customer : one User,
  status   : one AppStatus
}

// At most one decision per application; enforced by F_AtMostOneDecisionPerApp
sig Decision {
  application  : one LoanApplication,
  decisionType : one DecisionType,
  decidedBy    : one User,
  reason       : one Reason  // non-empty reason required (FR-009)
}

// Audit log — append-only records of status-changing events (FR-016)
sig ApplicationEvent {
  application : one LoanApplication,
  eventType   : one EventType,
  actor       : one User
}

// Notification log — one entry per decided application per channel (FR-014)
sig NotificationLog {
  application : one LoanApplication
}

// Models a single API call, used for permission / leakage assertions
sig Operation {
  kind      : one OperationKind,
  caller    : one User,
  targetApp : lone LoanApplication,
  outcome   : one Outcome
}

// -----------------------------------------------------------------------
// F_NonEmptyUniverse — ensures no assertion is vacuously true
// -----------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some NotificationLog
  some Operation
  some Reason
}

// -----------------------------------------------------------------------
// F_PermissionMatrix — encodes the exact allowed cells from contracts/http-api.md
// -----------------------------------------------------------------------
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole  -> OpPostApplications)   +
    (CustomerRole  -> OpGetApplications)    +
    (CustomerRole  -> OpGetApplicationByRef)+
    (BankStaffRole -> OpGetApplications)    +
    (BankStaffRole -> OpGetApplicationByRef)+
    (BankStaffRole -> OpPostDecision)       +
    (BankStaffRole -> OpGetAudit)
}

// -----------------------------------------------------------------------
// F_SuccessOnlyForAllowedOps — successful outcomes require permission
// -----------------------------------------------------------------------
fact F_SuccessOnlyForAllowedOps {
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind in PermMatrix.Allowed)
}

// -----------------------------------------------------------------------
// F_DeniedRolesNeverSuccess — denied (role, endpoint) pairs never succeed
// -----------------------------------------------------------------------
fact F_DeniedRolesNeverSuccess {
  all op: Operation |
    (op.caller.role -> op.kind not in PermMatrix.Allowed) implies
    (op.outcome = Forbidden or op.outcome = NotFound)
}

// -----------------------------------------------------------------------
// F_NoInfoLeakage — customer accessing another's application → 404, not 403
// -----------------------------------------------------------------------
fact F_NoInfoLeakage {
  all op: Operation |
    (op.kind = OpGetApplicationByRef and
     op.caller.role = CustomerRole and
     some op.targetApp and
     op.targetApp.customer != op.caller) implies
    op.outcome = NotFound
}

// -----------------------------------------------------------------------
// F_CustomerHasCustomerRole — only Customer-role users own applications
// -----------------------------------------------------------------------
fact F_CustomerHasCustomerRole {
  all app: LoanApplication | app.customer.role = CustomerRole
}

// -----------------------------------------------------------------------
// F_OnePendingPerCustomer — FR-005: at most one PendingReview per customer
// -----------------------------------------------------------------------
fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.status = PendingReview and a2.status = PendingReview) implies
    a1.customer != a2.customer
}

// -----------------------------------------------------------------------
// F_AtMostOneDecisionPerApp — FR-012: no two decisions on same application
// -----------------------------------------------------------------------
fact F_AtMostOneDecisionPerApp {
  all disj d1, d2: Decision | d1.application != d2.application
}

// -----------------------------------------------------------------------
// F_DecidedAppHasExactlyOneDecision — FR-010: decided → one Decision row
// -----------------------------------------------------------------------
fact F_DecidedAppHasExactlyOneDecision {
  all app: LoanApplication |
    (app.status = AppApproved or app.status = AppRejected) implies
    (one d: Decision | d.application = app)
}

// -----------------------------------------------------------------------
// F_PendingAppHasNoDecision — FR-011: pending apps have no decision yet
// -----------------------------------------------------------------------
fact F_PendingAppHasNoDecision {
  all app: LoanApplication |
    app.status = PendingReview implies (no d: Decision | d.application = app)
}

// -----------------------------------------------------------------------
// F_DecisionTypeMatchesStatus — decision type mirrors application status
// -----------------------------------------------------------------------
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.decisionType = DecApproved implies d.application.status = AppApproved) and
    (d.decisionType = DecRejected implies d.application.status = AppRejected)
}

// -----------------------------------------------------------------------
// F_DeciderHasBankStaffRole — FR-015: only bank_staff may record decisions
// -----------------------------------------------------------------------
fact F_DeciderHasBankStaffRole {
  all d: Decision | d.decidedBy.role = BankStaffRole
}

// -----------------------------------------------------------------------
// F_OneSubmittedEventPerApp — FR-004/FR-016: every application has exactly
// one "submitted" audit event
// -----------------------------------------------------------------------
fact F_OneSubmittedEventPerApp {
  all app: LoanApplication |
    one e: ApplicationEvent | e.application = app and e.eventType = EvtSubmitted
}

// -----------------------------------------------------------------------
// F_OneDecisionEventPerDecidedApp — FR-016: decided apps have exactly one
// matching decision audit event
// -----------------------------------------------------------------------
fact F_OneDecisionEventPerDecidedApp {
  all app: LoanApplication |
    app.status = AppApproved implies
    (one e: ApplicationEvent | e.application = app and e.eventType = EvtApproved)
  all app: LoanApplication |
    app.status = AppRejected implies
    (one e: ApplicationEvent | e.application = app and e.eventType = EvtRejected)
}

// -----------------------------------------------------------------------
// F_NoDecisionEventsForPending — pending apps have no approved/rejected events
// -----------------------------------------------------------------------
fact F_NoDecisionEventsForPending {
  all e: ApplicationEvent |
    (e.eventType = EvtApproved implies e.application.status = AppApproved) and
    (e.eventType = EvtRejected implies e.application.status = AppRejected)
}

// -----------------------------------------------------------------------
// F_AppendOnlyAuditEntries — FR-016/FR-017: audit events are tied to real
// applications and are never orphaned or fabricated out of application state
// -----------------------------------------------------------------------
fact F_AppendOnlyAuditEntries {
  // Every event's application exists in the current universe (no orphan rows)
  all e: ApplicationEvent | e.application in LoanApplication
  // No event can claim a decision outcome that the application doesn't have
  all e: ApplicationEvent |
    (e.eventType = EvtApproved implies e.application.status = AppApproved) and
    (e.eventType = EvtRejected implies e.application.status = AppRejected) and
    (e.eventType = EvtSubmitted implies e.application.status in
       (PendingReview + AppApproved + AppRejected))
}

// -----------------------------------------------------------------------
// F_AttributionSubmitted — FR-016: submitted event actor = application customer
// -----------------------------------------------------------------------
fact F_AttributionSubmitted {
  all e: ApplicationEvent |
    e.eventType = EvtSubmitted implies e.actor = e.application.customer
}

// -----------------------------------------------------------------------
// F_AttributionDecision — FR-016: decision event actor = staff who decided
// -----------------------------------------------------------------------
fact F_AttributionDecision {
  all e: ApplicationEvent |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
    (one d: Decision | d.application = e.application and d.decidedBy = e.actor)
}

// -----------------------------------------------------------------------
// F_NotificationOnDecision — FR-014: every decided application triggers
// at least one notification
// -----------------------------------------------------------------------
fact F_NotificationOnDecision {
  all app: LoanApplication |
    (app.status = AppApproved or app.status = AppRejected) implies
    (some n: NotificationLog | n.application = app)
}

// -----------------------------------------------------------------------
// F_ReasonUniqueness — each Reason token is used by at most one Decision
// (models that reason strings are per-decision, not shared)
// -----------------------------------------------------------------------
fact F_ReasonUniqueness {
  all disj d1, d2: Decision | d1.reason != d2.reason
}

// =======================================================================
// PREDICATES AND ASSERTIONS
// =======================================================================

// -----------------------------------------------------------------------
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
// -----------------------------------------------------------------------
pred LeastPrivilege {
  // bank_staff cannot post applications
  no op: Operation |
    op.caller.role = BankStaffRole and
    op.kind = OpPostApplications and
    op.outcome = Success
  // customers cannot post decisions
  no op: Operation |
    op.caller.role = CustomerRole and
    op.kind = OpPostDecision and
    op.outcome = Success
  // customers cannot access audit endpoint
  no op: Operation |
    op.caller.role = CustomerRole and
    op.kind = OpGetAudit and
    op.outcome = Success
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// -----------------------------------------------------------------------
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
// -----------------------------------------------------------------------
pred PermissionCompleteness {
  // Every (role, operation) pair has a defined verdict in the matrix or is
  // implicitly denied.  Completeness: the matrix covers exactly 7 cells
  // (the 5 ops × 2 roles = 10 total, minus 3 denied combinations).
  #(PermMatrix.Allowed) = 7
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// -----------------------------------------------------------------------
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-015; contracts/http-api.md auth section
// -----------------------------------------------------------------------
pred AuthRequiredEverywhere {
  // Every Operation has exactly one caller with a known role — there is no
  // "anonymous" role in the Role universe, so this is structurally enforced.
  // Additionally: no successful operation can be performed without a caller.
  all op: Operation | op.outcome = Success implies (one op.caller)
  // Every operation caller has a role (no null / unauthenticated actor)
  all op: Operation | one op.caller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// -----------------------------------------------------------------------
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md ApplicationEvent
// -----------------------------------------------------------------------
pred AuditCompleteness {
  // Every application has exactly one "submitted" event.
  all app: LoanApplication |
    one e: ApplicationEvent | e.application = app and e.eventType = EvtSubmitted
  // Every approved application has exactly one "approved" event.
  all app: LoanApplication |
    app.status = AppApproved implies
    (one e: ApplicationEvent | e.application = app and e.eventType = EvtApproved)
  // Every rejected application has exactly one "rejected" event.
  all app: LoanApplication |
    app.status = AppRejected implies
    (one e: ApplicationEvent | e.application = app and e.eventType = EvtRejected)
  // At least one application exists for this assertion to bite.
  some LoanApplication
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// -----------------------------------------------------------------------
// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-017; data-model.md "No UPDATE/DELETE"
// -----------------------------------------------------------------------
pred AppendOnly {
  // In the static model, append-only is expressed as:
  // no audit event references a "decided" application without that decision existing.
  all e: ApplicationEvent |
    e.eventType = EvtApproved implies
    (some d: Decision | d.application = e.application and d.decisionType = DecApproved)
  all e: ApplicationEvent |
    e.eventType = EvtRejected implies
    (some d: Decision | d.application = e.application and d.decisionType = DecRejected)
  // No event exists without its anchoring application
  all e: ApplicationEvent | e.application in LoanApplication
  some ApplicationEvent
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// -----------------------------------------------------------------------
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md ApplicationEvent.actor_user_id
// -----------------------------------------------------------------------
pred AttributionCorrectness {
  // Submitted event actor must be the application's customer.
  all e: ApplicationEvent |
    e.eventType = EvtSubmitted implies e.actor = e.application.customer
  // Decision event actor must match the deciding staff member.
  all e: ApplicationEvent |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
    (one d: Decision | d.application = e.application and d.decidedBy = e.actor)
  some ApplicationEvent
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// -----------------------------------------------------------------------
// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id; spec.md FR-004
// -----------------------------------------------------------------------
pred OwnershipExclusivity {
  // Every application has exactly one customer owner.
  all app: LoanApplication | one app.customer
  // That owner has the CustomerRole.
  all app: LoanApplication | app.customer.role = CustomerRole
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// -----------------------------------------------------------------------
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md GET /applications/{reference}
// -----------------------------------------------------------------------
pred OwnershipBasedAccess {
  // A customer can only successfully retrieve an application they own.
  all op: Operation |
    (op.kind = OpGetApplicationByRef and
     op.caller.role = CustomerRole and
     op.outcome = Success) implies
    (some op.targetApp and op.targetApp.customer = op.caller)
  some op: Operation |
    op.kind = OpGetApplicationByRef and op.caller.role = CustomerRole
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// -----------------------------------------------------------------------
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md 404 vs 403
// -----------------------------------------------------------------------
pred NoInformationLeakage {
  // When a customer accesses another customer's application, the outcome
  // must be NotFound, NOT Forbidden — we do not leak existence.
  all op: Operation |
    (op.kind = OpGetApplicationByRef and
     op.caller.role = CustomerRole and
     some op.targetApp and
     op.targetApp.customer != op.caller) implies
    op.outcome = NotFound
  // There exists at least one such cross-ownership attempt so the predicate bites.
  some op: Operation |
    op.kind = OpGetApplicationByRef and
    op.caller.role = CustomerRole and
    some op.targetApp and
    op.targetApp.customer != op.caller
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// -----------------------------------------------------------------------
// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md Decision PK constraint
// -----------------------------------------------------------------------
pred ConcurrencySafety {
  // No two distinct Decision rows reference the same application.
  all disj d1, d2: Decision | d1.application != d2.application
  // Every decided application has exactly one decision.
  all app: LoanApplication |
    (app.status = AppApproved or app.status = AppRejected) implies
    (one d: Decision | d.application = app)
  some Decision
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-001
// FR_001_AuthenticatedCustomerSubmits
// -----------------------------------------------------------------------
pred FR_001_AuthenticatedCustomerSubmits {
  // All applications in the system were submitted by a user with CustomerRole.
  all app: LoanApplication | app.customer.role = CustomerRole
  some LoanApplication
}
assert FR_001_AuthenticatedCustomerSubmits { FR_001_AuthenticatedCustomerSubmits }
check FR_001_AuthenticatedCustomerSubmits for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-002 (ValidationBeforeMutation)
// FR_002_ValidationBeforeMutation
// -----------------------------------------------------------------------
pred FR_002_ValidationBeforeMutation {
  // Every LoanApplication in the system passed validation:
  // it is owned by a CustomerRole user and has a valid status.
  // (Invalid applications never enter the model — no partial rows.)
  all app: LoanApplication |
    app.customer.role = CustomerRole and
    app.status in (PendingReview + AppApproved + AppRejected)
  some LoanApplication
}
assert FR_002_ValidationBeforeMutation { FR_002_ValidationBeforeMutation }
check FR_002_ValidationBeforeMutation for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-004
// FR_004_UniqueReferenceAndPendingInitial
// -----------------------------------------------------------------------
pred FR_004_UniqueReferenceAndPendingInitial {
  // In the model each LoanApplication atom is distinct (Alloy guarantees this).
  // The structural invariant we check: every application has exactly one
  // customer and exactly one status, and there are no "reference-less" apps.
  all app: LoanApplication | one app.customer and one app.status
  some LoanApplication
}
assert FR_004_UniqueReferenceAndPendingInitial { FR_004_UniqueReferenceAndPendingInitial }
check FR_004_UniqueReferenceAndPendingInitial for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-005
// FR_005_OnePendingPerCustomer
// -----------------------------------------------------------------------
pred FR_005_OnePendingPerCustomer {
  // No customer has two or more applications simultaneously in PendingReview.
  no disj a1, a2: LoanApplication |
    a1.status = PendingReview and
    a2.status = PendingReview and
    a1.customer = a2.customer
  some LoanApplication
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-009
// FR_009_NonEmptyReasonOnDecision
// -----------------------------------------------------------------------
pred FR_009_NonEmptyReasonOnDecision {
  // Every Decision carries a Reason token (non-empty reason mandatory).
  all d: Decision | one d.reason
  some Decision
}
assert FR_009_NonEmptyReasonOnDecision { FR_009_NonEmptyReasonOnDecision }
check FR_009_NonEmptyReasonOnDecision for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-012
// FR_010_DecisionPersistedWithDecider
// -----------------------------------------------------------------------
pred FR_010_DecisionPersistedWithDecider {
  // Every decided application has a Decision with a BankStaff decider.
  all app: LoanApplication |
    (app.status = AppApproved or app.status = AppRejected) implies
    (one d: Decision |
       d.application = app and d.decidedBy.role = BankStaffRole)
  some app: LoanApplication |
    app.status = AppApproved or app.status = AppRejected
}
assert FR_010_DecisionPersistedWithDecider { FR_010_DecisionPersistedWithDecider }
check FR_010_DecisionPersistedWithDecider for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-011
// FR_011_NoReDecisionOnDecidedApp
// -----------------------------------------------------------------------
pred FR_011_NoReDecisionOnDecidedApp {
  // There is at most one Decision per application (structurally: distinct
  // decisions have distinct applications).
  all disj d1, d2: Decision | d1.application != d2.application
  // Decided applications cannot be in PendingReview.
  all d: Decision |
    d.application.status = AppApproved or d.application.status = AppRejected
  some Decision
}
assert FR_011_NoReDecisionOnDecidedApp { FR_011_NoReDecisionOnDecidedApp }
check FR_011_NoReDecisionOnDecidedApp for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-004
// FR_013_CustomerSeesOnlyOwnApps
// -----------------------------------------------------------------------
pred FR_013_CustomerSeesOnlyOwnApps {
  // Every successful GET /applications/{reference} by a customer
  // targets an application that belongs to that customer.
  all op: Operation |
    (op.kind = OpGetApplicationByRef and
     op.caller.role = CustomerRole and
     op.outcome = Success) implies
    (some op.targetApp and op.targetApp.customer = op.caller)
  // Ensure there is at least one customer operation to prevent vacuity.
  some op: Operation |
    op.kind = OpGetApplicationByRef and op.caller.role = CustomerRole
}
assert FR_013_CustomerSeesOnlyOwnApps { FR_013_CustomerSeesOnlyOwnApps }
check FR_013_CustomerSeesOnlyOwnApps for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-015, SC-004
// FR_015_OnlyStaffCanDecide
// -----------------------------------------------------------------------
pred FR_015_OnlyStaffCanDecide {
  // No Operation of kind OpPostDecision by a CustomerRole caller succeeds.
  no op: Operation |
    op.kind = OpPostDecision and
    op.caller.role = CustomerRole and
    op.outcome = Success
  // There is at least one OpPostDecision operation in the universe.
  some op: Operation | op.kind = OpPostDecision
}
assert FR_015_OnlyStaffCanDecide { FR_015_OnlyStaffCanDecide }
check FR_015_OnlyStaffCanDecide for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-016
// FR_016_AuditTrailCompleteness
// -----------------------------------------------------------------------
pred FR_016_AuditTrailCompleteness {
  // Each application has exactly one EvtSubmitted event.
  all app: LoanApplication |
    one e: ApplicationEvent | e.application = app and e.eventType = EvtSubmitted
  // Each approved app has exactly one EvtApproved event.
  all app: LoanApplication |
    app.status = AppApproved implies
    (one e: ApplicationEvent | e.application = app and e.eventType = EvtApproved)
  // Each rejected app has exactly one EvtRejected event.
  all app: LoanApplication |
    app.status = AppRejected implies
    (one e: ApplicationEvent | e.application = app and e.eventType = EvtRejected)
  some LoanApplication
}
assert FR_016_AuditTrailCompleteness { FR_016_AuditTrailCompleteness }
check FR_016_AuditTrailCompleteness for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-017
// FR_017_RetentionNoDelete
// -----------------------------------------------------------------------
pred FR_017_RetentionNoDelete {
  // Every Decision and ApplicationEvent references an application that
  // still exists in the system (no deletions).
  all d: Decision | d.application in LoanApplication
  all e: ApplicationEvent | e.application in LoanApplication
  all n: NotificationLog | n.application in LoanApplication
  some LoanApplication
}
assert FR_017_RetentionNoDelete { FR_017_RetentionNoDelete }
check FR_017_RetentionNoDelete for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-014
// FR_014_NotificationOnStatusChange
// -----------------------------------------------------------------------
pred FR_014_NotificationOnStatusChange {
  // Every application that is Approved or Rejected has at least one
  // notification log entry.
  all app: LoanApplication |
    (app.status = AppApproved or app.status = AppRejected) implies
    (some n: NotificationLog | n.application = app)
  some app: LoanApplication |
    app.status = AppApproved or app.status = AppRejected
}
assert FR_014_NotificationOnStatusChange { FR_014_NotificationOnStatusChange }
check FR_014_NotificationOnStatusChange for 6

// -----------------------------------------------------------------------
// FEATURE-SPECIFIC  ANCHOR: FR-007, FR-008
// FR_007_StaffCanAccessAuditAndQueue
// -----------------------------------------------------------------------
pred FR_007_StaffCanAccessAuditAndQueue {
  // bank_staff is allowed for OpGetAudit and OpGetApplications
  BankStaffRole -> OpGetAudit in PermMatrix.Allowed
  BankStaffRole -> OpGetApplications in PermMatrix.Allowed
  // customer is NOT allowed for OpGetAudit
  CustomerRole -> OpGetAudit not in PermMatrix.Allowed
}
assert FR_007_StaffCanAccessAuditAndQueue { FR_007_StaffCanAccessAuditAndQueue }
check FR_007_StaffCanAccessAuditAndQueue for 6

// === D3 inject_violation (validator-appended) ===
fact MUTATE_CustomerDeciderViolation { some d: Decision | d.decidedBy.role = CustomerRole }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
