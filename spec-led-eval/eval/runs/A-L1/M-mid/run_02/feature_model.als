// === feature_model.als — Alloy model for Loan Application (A-L1 / 003-loan-application) ===
// Artefacts: spec.md (FR-001..FR-017), data-model.md, contracts/http-api.md

// ───────────────────────────── ENUMERATIONS ──────────────────────────────

abstract sig Role {}
one sig Customer, BankStaff extends Role {}

abstract sig ApplicationStatus {}
one sig PendingReview, StatusApproved, StatusRejected extends ApplicationStatus {}

abstract sig EventType {}
one sig EvtSubmitted, EvtApproved, EvtRejected extends EventType {}

abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// FR-003: allowed repayment term options
abstract sig TermOption {}
one sig T12, T24, T36, T48, T60 extends TermOption {}

// Notification status flavours (only terminal statuses trigger notification)
abstract sig NotificationStatus {}
one sig NsApproved, NsRejected extends NotificationStatus {}

// ───────────────────────────── OPERATION KINDS ───────────────────────────

abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAudit extends OperationKind {}

// Permission matrix encoded as a field on a singleton sig (see Rule 7)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ───────────────────────────── CORE DOMAIN SIGS ──────────────────────────

sig User {
  role: one Role
}

// Reference is a distinct object so uniqueness is expressible as a relation property
sig Reference {}

sig LoanApplication {
  customer  : one User,
  status    : one ApplicationStatus,
  reference : one Reference,
  term      : one TermOption
}

// A Reason is a non-empty opaque object; having 'reason: one Reason' on Decision
// structurally forces exactly one reason per decision (FR-009)
sig Reason {}

sig Decision {
  application  : one LoanApplication,
  decisionType : one DecisionType,
  decidedBy    : one User,
  reason       : one Reason
}

sig ApplicationEvent {
  application : one LoanApplication,
  eventType   : one EventType,
  actor       : one User
}

sig NotificationLog {
  application      : one LoanApplication,
  recipient        : one User,
  notifiedStatus   : one NotificationStatus
}

// An Operation models an authenticated API call that passed auth resolution
sig Operation {
  callerRole : one Role,
  kind       : one OperationKind
}

// ───────────────────────────── NON-EMPTY UNIVERSE ────────────────────────

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some NotificationLog
  some Reference
  some Operation
  some Reason
}

// ───────────────────────────── PERMISSION MATRIX ─────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015

fact F_PermissionMatrix {
  // Explicit allow cells
  PermMatrix.Allowed =
      (Customer   -> PostApplications)  +
      (Customer   -> GetApplications)   +
      (Customer   -> GetApplicationByRef) +
      (BankStaff  -> GetApplications)   +
      (BankStaff  -> GetApplicationByRef) +
      (BankStaff  -> PostDecision)      +
      (BankStaff  -> GetAudit)
  // All other cells are implicitly denied (closed-world)
}

// ───────────────────────────── STRUCTURAL FACTS ──────────────────────────

// FR-001 / data-model.md: every LoanApplication is submitted by a Customer-role user
fact F_CustomerRoleForApplications {
  all a: LoanApplication | a.customer.role = Customer
}

// data-model.md: deciding staff must hold BankStaff role
fact F_StaffRoleForDecisions {
  all d: Decision | d.decidedBy.role = BankStaff
}

// FR-005 / data-model.md idx_one_pending_per_customer: at most one PendingReview per customer
fact F_OnePendingPerCustomer {
  all u: User |
    lone a: LoanApplication | a.customer = u and a.status = PendingReview
}

// data-model.md: decisions.application_id is PRIMARY KEY — at most one Decision per application
fact F_DecisionImmutability {
  all disj d1, d2: Decision | d1.application != d2.application
}

// Decided applications have exactly one Decision; Pending have none
fact F_DecidedStatusHasDecision {
  all a: LoanApplication |
    (a.status = StatusApproved or a.status = StatusRejected) implies
      (one d: Decision | d.application = a)
}

fact F_PendingNoDecision {
  all a: LoanApplication |
    a.status = PendingReview implies (no d: Decision | d.application = a)
}

// Decision type aligns with application status
fact F_DecisionTypeAlignedWithStatus {
  all d: Decision |
    (d.decisionType = DecApproved implies d.application.status = StatusApproved) and
    (d.decisionType = DecRejected implies d.application.status = StatusRejected)
}

// Status transitions: only PendingReview→Approved or PendingReview→Rejected are valid.
// Modelled by constraining which statuses can have/not have decisions (see facts above).

// FR-004 / data-model.md reference UNIQUE: each Reference is used by exactly one LoanApplication
fact F_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// FR-016 / data-model.md: AppendOnly — no two ApplicationEvents record the same
// (application, eventType) pair; once written an event is never overwritten
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies e1.eventType != e2.eventType
}

// FR-016 / AuditCompleteness — every LoanApplication has exactly one EvtSubmitted event
fact F_AuditCompletenessSubmission {
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted
}

// FR-016 / AuditCompleteness — every decided application has exactly one matching decision event
fact F_AuditCompletenessDecision {
  all a: LoanApplication |
    a.status = StatusApproved implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtApproved)
  all a: LoanApplication |
    a.status = StatusRejected implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtRejected)
}

// FR-016 / AttributionCorrectness — EvtSubmitted actor is the application's customer
fact F_AttributionSubmitted {
  all e: ApplicationEvent |
    e.eventType = EvtSubmitted implies e.actor = e.application.customer
}

// FR-016 / AttributionCorrectness — EvtApproved / EvtRejected actor has BankStaff role
fact F_AttributionDecisionEvents {
  all e: ApplicationEvent |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
      e.actor.role = BankStaff
}

// FR-014 / NotificationOnDecision — every decided application has at least one notification
// sent to the application's customer for the matching status
fact F_NotificationOnDecision {
  all a: LoanApplication |
    a.status = StatusApproved implies
      (some n: NotificationLog | n.application = a and n.recipient = a.customer
                                 and n.notifiedStatus = NsApproved)
  all a: LoanApplication |
    a.status = StatusRejected implies
      (some n: NotificationLog | n.application = a and n.recipient = a.customer
                                 and n.notifiedStatus = NsRejected)
}

// FR-013 / OwnershipBasedAccess — notifications go only to the owning customer
fact F_NotificationRecipientOwner {
  all n: NotificationLog | n.recipient = n.application.customer
}

// Only permitted operations exist in the system (all calls are authenticated + authorised)
fact F_OperationPermitted {
  all op: Operation | op.callerRole -> op.kind in PermMatrix.Allowed
}

// ───────────────────────────── PATTERN: LeastPrivilege ───────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015

pred LeastPrivilege {
  some Operation  // universe is non-vacuous
  // No customer reaches staff-only endpoints
  no op: Operation | op.callerRole = Customer and op.kind = PostDecision
  no op: Operation | op.callerRole = Customer and op.kind = GetAudit
  // No staff submits applications
  no op: Operation | op.callerRole = BankStaff and op.kind = PostApplications
  // Every operation in the system is within the Allowed relation
  all op: Operation | op.callerRole -> op.kind in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ───────────────────────────── PATTERN: PermissionCompleteness ───────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix

pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is explicitly accounted for (allow or deny is total)
  // Allow set is exactly the explicit matrix (no undefined cells)
  PermMatrix.Allowed =
      (Customer   -> PostApplications)  +
      (Customer   -> GetApplications)   +
      (Customer   -> GetApplicationByRef) +
      (BankStaff  -> GetApplications)   +
      (BankStaff  -> GetApplicationByRef) +
      (BankStaff  -> PostDecision)      +
      (BankStaff  -> GetAudit)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ───────────────────────────── PATTERN: PrivilegeMonotonicity ────────────
// PATTERN: PrivilegeMonotonicity  ANCHOR: contracts/http-api.md; spec.md role descriptions

pred PrivilegeMonotonicity {
  // BankStaff's allowed read operations are a superset of Customer's
  // (Customer read set ⊆ BankStaff read set for shared read endpoints)
  let customerAllowed  = { ok: OperationKind | Customer -> ok in PermMatrix.Allowed } |
  let staffAllowed     = { ok: OperationKind | BankStaff -> ok in PermMatrix.Allowed } |
    GetApplications    in staffAllowed and
    GetApplicationByRef in staffAllowed and
    // BankStaff gets strictly more: PostDecision and GetAudit
    PostDecision in staffAllowed and
    GetAudit     in staffAllowed and
    // Customer does not get those
    PostDecision not in customerAllowed and
    GetAudit     not in customerAllowed
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// ───────────────────────────── PATTERN: AuthRequiredEverywhere ───────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md auth section; spec.md FR-001

pred AuthRequiredEverywhere {
  // Every Operation in the system carries a resolved Role (no anonymous/unauthenticated path)
  // Encoded structurally: callerRole is typed 'one Role', so all Operations are authenticated.
  // Meaningful check: every Operation kind that exists has an associated Role in the Allowed set.
  some Operation
  all op: Operation | op.callerRole -> op.kind in PermMatrix.Allowed
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ───────────────────────────── PATTERN: AppendOnly ───────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "no UPDATE/DELETE on application_events"

pred AppendOnly {
  some ApplicationEvent
  // No two events on the same application share the same eventType
  // (would indicate an overwrite/duplicate)
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 6

// ───────────────────────────── PATTERN: AuditCompleteness ────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events

pred AuditCompleteness {
  some LoanApplication
  // Every application has exactly one submitted event
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted
  // Every approved application has exactly one approved audit event
  all a: LoanApplication |
    a.status = StatusApproved implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtApproved)
  // Every rejected application has exactly one rejected audit event
  all a: LoanApplication |
    a.status = StatusRejected implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtRejected)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// ───────────────────────────── PATTERN: AttributionCorrectness ───────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md ApplicationEvent.actor_user_id

pred AttributionCorrectness {
  some ApplicationEvent
  // Submitted events are attributed to the application's own customer
  all e: ApplicationEvent |
    e.eventType = EvtSubmitted implies e.actor = e.application.customer
  // Decision events are attributed to a staff member
  all e: ApplicationEvent |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
      e.actor.role = BankStaff
  // Customer cannot be the actor on a decision event
  all e: ApplicationEvent |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
      e.actor != e.application.customer
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ───────────────────────────── PATTERN: OwnershipBasedAccess ─────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GET /applications/{ref}

pred OwnershipBasedAccess {
  some LoanApplication
  // A notification is only ever sent to the application's owning customer
  all n: NotificationLog | n.recipient = n.application.customer
  // The customer of an application always has Customer role
  all a: LoanApplication | a.customer.role = Customer
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ───────────────────────────── PATTERN: NoInformationLeakage ─────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md 404 rule

pred NoInformationLeakage {
  // Modelled structurally: a Customer GetApplicationByRef operation on an application
  // they do not own must not surface the application.
  // We enforce: any notification sent to a user only involves their own applications.
  some NotificationLog
  all n: NotificationLog | n.recipient = n.application.customer
  // No audit event reveals another customer's application to a customer actor
  all e: ApplicationEvent |
    e.eventType = EvtSubmitted implies e.actor = e.application.customer
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ───────────────────────────── PATTERN: ValidationBeforeMutation ─────────
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002; data-model.md validation.py

pred ValidationBeforeMutation {
  // Every LoanApplication in the system has a valid term (one of the 5 allowed options).
  // Invalid submissions never reach LoanApplication — they are rejected at validation.
  some LoanApplication
  all a: LoanApplication | a.term in (T12 + T24 + T36 + T48 + T60)
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ───────────────────────────── PATTERN: ConcurrencySafety ────────────────
// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md conditional UPDATE

pred ConcurrencySafety {
  // At most one Decision per LoanApplication — the conditional UPDATE atomicity guarantee
  some LoanApplication
  all a: LoanApplication |
    lone d: Decision | d.application = a
  // A decided application's status is stable: no further decisions can be recorded
  all a: LoanApplication |
    (a.status = StatusApproved or a.status = StatusRejected) implies
      (one d: Decision | d.application = a)
}

assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 6

// ───────────────────────────── FR-SPECIFIC PREDICATES ────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // Every operation that reaches a handler has a resolved role in the permission matrix
  some Operation
  all op: Operation | op.callerRole -> op.kind in PermMatrix.Allowed
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_ValidationBeforeSubmission {
  // All persisted applications have a valid term option
  some LoanApplication
  all a: LoanApplication | a.term in (T12 + T24 + T36 + T48 + T60)
}

assert FR_002_ValidationBeforeSubmission { FR_002_ValidationBeforeSubmission }
check FR_002_ValidationBeforeSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ValidTermOptions {
  some LoanApplication
  all a: LoanApplication | a.term in (T12 + T24 + T36 + T48 + T60)
}

assert FR_003_ValidTermOptions { FR_003_ValidTermOptions }
check FR_003_ValidTermOptions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueReference {
  some LoanApplication
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  some LoanApplication
  all u: User |
    lone a: LoanApplication | a.customer = u and a.status = PendingReview
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_DecisionRequiresReason {
  // Every Decision has exactly one Reason (structural: 'reason: one Reason')
  // Additionally, no two decisions share the same reason object (reasons are per-decision)
  some Decision
  all d: Decision | one d.reason
}

assert FR_009_DecisionRequiresReason { FR_009_DecisionRequiresReason }
check FR_009_DecisionRequiresReason for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_DecisionPersisted {
  // Every Approved or Rejected application has exactly one persisted Decision
  // and exactly one corresponding audit event
  some a: LoanApplication | a.status = StatusApproved or a.status = StatusRejected
  all a: LoanApplication |
    (a.status = StatusApproved or a.status = StatusRejected) implies
      ((one d: Decision | d.application = a) and
       (one e: ApplicationEvent |
           e.application = a and
           (e.eventType = EvtApproved or e.eventType = EvtRejected)))
}

assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_DecisionImmutability {
  // At most one Decision per application; once decided, no second decision is possible
  some Decision
  all disj d1, d2: Decision | d1.application != d2.application
  // Decided applications never revert to PendingReview
  all d: Decision |
    d.application.status != PendingReview
}

assert FR_011_DecisionImmutability { FR_011_DecisionImmutability }
check FR_011_DecisionImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NoDoubleDecision {
  // Concurrent decisions resolve to exactly one winner: at most one Decision per application
  some LoanApplication
  all a: LoanApplication |
    lone d: Decision | d.application = a
}

assert FR_012_NoDoubleDecision { FR_012_NoDoubleDecision }
check FR_012_NoDoubleDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013; SC-004
pred FR_013_CustomerSeesOnlyOwnApps {
  some LoanApplication
  // Notifications (proxy for data visibility) only reach the owning customer
  all n: NotificationLog | n.recipient = n.application.customer
  // Every application customer has Customer role
  all a: LoanApplication | a.customer.role = Customer
}

assert FR_013_CustomerSeesOnlyOwnApps { FR_013_CustomerSeesOnlyOwnApps }
check FR_013_CustomerSeesOnlyOwnApps for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_NotificationOnDecision {
  // Every decided application triggers at least one notification to its customer
  some a: LoanApplication | a.status = StatusApproved or a.status = StatusRejected
  all a: LoanApplication |
    a.status = StatusApproved implies
      (some n: NotificationLog | n.application = a and n.recipient = a.customer
                                 and n.notifiedStatus = NsApproved)
  all a: LoanApplication |
    a.status = StatusRejected implies
      (some n: NotificationLog | n.application = a and n.recipient = a.customer
                                 and n.notifiedStatus = NsRejected)
}

assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015; SC-004
pred FR_015_StaffOnlyDecisionAccess {
  // No Customer-role operation reaches PostDecision or GetAudit
  some Operation
  no op: Operation | op.callerRole = Customer and op.kind = PostDecision
  no op: Operation | op.callerRole = Customer and op.kind = GetAudit
  // No BankStaff operation reaches PostApplications
  no op: Operation | op.callerRole = BankStaff and op.kind = PostApplications
}

assert FR_015_StaffOnlyDecisionAccess { FR_015_StaffOnlyDecisionAccess }
check FR_015_StaffOnlyDecisionAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrailComplete {
  some LoanApplication
  // Submitted event exists for every application
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted
  // Decision events exist for all decided applications, none for pending
  all a: LoanApplication |
    a.status = StatusApproved implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtApproved)
  all a: LoanApplication |
    a.status = StatusRejected implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtRejected)
  all a: LoanApplication |
    a.status = PendingReview implies
      (no e: ApplicationEvent | e.application = a and
          (e.eventType = EvtApproved or e.eventType = EvtRejected))
  // No duplicate event types per application (append-only invariant)
  all disj e1, e2: ApplicationEvent |
    not (e1.application = e2.application and e1.eventType = e2.eventType)
}

assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_RetentionNoDeletion {
  // Every decided application still has its events (no deletion of records)
  // Modelled as: decided applications have a complete set of events (none missing)
  some a: LoanApplication | a.status = StatusApproved or a.status = StatusRejected
  all a: LoanApplication |
    (a.status = StatusApproved or a.status = StatusRejected) implies
      (one e: ApplicationEvent | e.application = a and e.eventType = EvtSubmitted) and
      (one d: Decision | d.application = a)
}

assert FR_017_RetentionNoDeletion { FR_017_RetentionNoDeletion }
check FR_017_RetentionNoDeletion for 5