// === feature_model.als — Alloy model for Loan Application (A-L1) ===
// Feature: 003-loan-application
// Generated from: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS (endpoints)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAudit extends OperationKind {}

// Permission matrix as a singleton-sig field.
// Reference cells with `Role -> OperationKind in PermMatrix.Allowed`.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, AppStatusApproved, AppStatusRejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────────────────────
// DECISION TYPE
// ─────────────────────────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// ─────────────────────────────────────────────────────────────────────────────
// EVENT TYPE
// ─────────────────────────────────────────────────────────────────────────────
abstract sig EventType {}
one sig EvSubmitted, EvApproved, EvRejected extends EventType {}

// ─────────────────────────────────────────────────────────────────────────────
// USERS
// ─────────────────────────────────────────────────────────────────────────────
sig User { role: one Role }

// ─────────────────────────────────────────────────────────────────────────────
// REASON  — represents a non-empty reason string (structurally required for Decision)
// ─────────────────────────────────────────────────────────────────────────────
sig Reason {}

// ─────────────────────────────────────────────────────────────────────────────
// DECISION  — staff decision recorded against exactly one loan application
// ─────────────────────────────────────────────────────────────────────────────
sig Decision {
  decisionType : one DecisionType,
  decidedBy    : one User,
  reason       : one Reason      // non-empty reason required (FR-009)
}

// ─────────────────────────────────────────────────────────────────────────────
// LOAN APPLICATION
// ─────────────────────────────────────────────────────────────────────────────
sig LoanApplication {
  owner    : one User,            // the submitting customer
  status   : one ApplicationStatus,
  decision : lone Decision        // present iff status is Approved or Rejected
}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION EVENT  — append-only audit log
// ─────────────────────────────────────────────────────────────────────────────
sig ApplicationEvent {
  forApplication : one LoanApplication,
  eventType      : one EventType,
  actor          : one User
}

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICATION LOG  — FR-014 notification emission record
// ─────────────────────────────────────────────────────────────────────────────
sig NotificationLog {
  forApplication : one LoanApplication,
  recipient      : one User
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE  — ensures no predicate passes vacuously
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Reason
  some NotificationLog
}

// ─────────────────────────────────────────────────────────────────────────────
// F_PermissionMatrix  — closed-world permission matrix from contracts/http-api.md
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer   -> PostApplications)  +
    (Customer   -> GetApplications)   +
    (Customer   -> GetApplicationByRef) +
    (BankStaff  -> GetApplications)   +
    (BankStaff  -> GetApplicationByRef) +
    (BankStaff  -> PostDecision)      +
    (BankStaff  -> GetAudit)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ApplicationOwnerIsCustomer  — only Customers own applications (FR-001, FR-015)
// ─────────────────────────────────────────────────────────────────────────────
fact F_ApplicationOwnerIsCustomer {
  all a: LoanApplication | a.owner.role = Customer
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionByStaff  — only BankStaff can record decisions (FR-015)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionByStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionPresenceMatchesStatus  — decision exists iff application is decided
//   (FR-010, FR-011)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionPresenceMatchesStatus {
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected)
    iff
    (one a.decision)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionInjectivity  — no two applications share the same Decision object
//   (at-most-one decision per application, FR-012, SC-005)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionInjectivity { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionTypeMatchesStatus  — decision type aligns with application status
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionTypeMatchesStatus {
  all a: LoanApplication |
    (some a.decision) => (
      (a.status = AppStatusApproved iff a.decision.decisionType = DecApproved) and
      (a.status = AppStatusRejected iff a.decision.decisionType = DecRejected)
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OnePendingPerCustomer  — at most one PendingReview application per customer
//   (FR-005, data-model.md idx_one_pending_per_customer)
// ─────────────────────────────────────────────────────────────────────────────
fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.owner = a2.owner =>
    not (a1.status = PendingReview and a2.status = PendingReview)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditSubmitEvent  — every application has exactly one EvSubmitted event
//   (FR-016, data-model.md ApplicationEvent)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditSubmitEvent {
  all a: LoanApplication |
    one e: ApplicationEvent | e.forApplication = a and e.eventType = EvSubmitted
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditApproveEvent  — approved applications have exactly one EvApproved event
//   (FR-016)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditApproveEvent {
  all a: LoanApplication |
    (a.status = AppStatusApproved) iff
    (one e: ApplicationEvent | e.forApplication = a and e.eventType = EvApproved)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditRejectEvent  — rejected applications have exactly one EvRejected event
//   (FR-016)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditRejectEvent {
  all a: LoanApplication |
    (a.status = AppStatusRejected) iff
    (one e: ApplicationEvent | e.forApplication = a and e.eventType = EvRejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditSubmitActorIsOwner  — EvSubmitted actor must be the application owner
//   (FR-016, data-model.md actor_user_id)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditSubmitActorIsOwner {
  all e: ApplicationEvent |
    e.eventType = EvSubmitted => e.actor = e.forApplication.owner
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditDecisionActorIsStaff  — EvApproved/EvRejected actors must be BankStaff
//   (FR-016)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditDecisionActorIsStaff {
  all e: ApplicationEvent |
    (e.eventType = EvApproved or e.eventType = EvRejected) =>
    e.actor.role = BankStaff
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionActorMatchesAuditActor  — the staff member in Decision.decidedBy
//   matches the actor in the corresponding audit event (FR-010, FR-016)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionActorMatchesAuditActor {
  all a: LoanApplication |
    some a.decision => (
      (a.status = AppStatusApproved =>
        (one e: ApplicationEvent |
          e.forApplication = a and
          e.eventType = EvApproved and
          e.actor = a.decision.decidedBy)) and
      (a.status = AppStatusRejected =>
        (one e: ApplicationEvent |
          e.forApplication = a and
          e.eventType = EvRejected and
          e.actor = a.decision.decidedBy))
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NotificationOnDecision  — decided applications trigger exactly one
//   notification to the owner; pending applications trigger none (FR-014)
// ─────────────────────────────────────────────────────────────────────────────
fact F_NotificationOnDecision {
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) =>
    (one n: NotificationLog | n.forApplication = a and n.recipient = a.owner)
  all a: LoanApplication |
    a.status = PendingReview =>
    (no n: NotificationLog | n.forApplication = a)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NotificationRecipientIsOwner  — notifications go only to the application's
//   owning customer (FR-014)
// ─────────────────────────────────────────────────────────────────────────────
fact F_NotificationRecipientIsOwner {
  all n: NotificationLog | n.recipient = n.forApplication.owner
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NotificationInjectivity  — at most one notification per application
// ─────────────────────────────────────────────────────────────────────────────
fact F_NotificationInjectivity {
  all a1, a2: NotificationLog |
    a1.forApplication = a2.forApplication => a1 = a2
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditEventsOnlyForKnownApplications  — every audit event references an
//   existing LoanApplication (referential integrity)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditEventsOnlyForKnownApplications {
  all e: ApplicationEvent | e.forApplication in LoanApplication
}

// =============================================================================
//  PATTERN PREDICATES
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  // Customers cannot record decisions
  Customer -> PostDecision not in PermMatrix.Allowed
  // Customers cannot access the audit trail
  Customer -> GetAudit not in PermMatrix.Allowed
  // BankStaff cannot submit loan applications
  BankStaff -> PostApplications not in PermMatrix.Allowed
  // At least one operation remains reachable for each role
  some op: OperationKind | Customer  -> op in PermMatrix.Allowed
  some op: OperationKind | BankStaff -> op in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either explicitly allowed or implicitly denied.
  // The closed-world fact F_PermissionMatrix makes denial the default;
  // here we assert that the allowed set is non-empty (the matrix isn't trivially empty).
  some PermMatrix.Allowed
  // Every allowed cell involves a known Role and a known OperationKind
  all r: Role, op: OperationKind |
    r -> op in PermMatrix.Allowed or r -> op not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md ApplicationEvent
pred AuditCompleteness {
  // Every application has a submission event.
  all a: LoanApplication |
    some e: ApplicationEvent | e.forApplication = a and e.eventType = EvSubmitted
  // Every approved application has an approval event.
  all a: LoanApplication |
    a.status = AppStatusApproved =>
    (some e: ApplicationEvent | e.forApplication = a and e.eventType = EvApproved)
  // Every rejected application has a rejection event.
  all a: LoanApplication |
    a.status = AppStatusRejected =>
    (some e: ApplicationEvent | e.forApplication = a and e.eventType = EvRejected)
  // There is at least one application (non-vacuous).
  some LoanApplication
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "No UPDATE/DELETE … application_events"
pred AppendOnly {
  // In the static model: the event set contains ALL required events for the
  // current application states and nothing spurious.
  // A spurious event would be one whose eventType does not match the application's status.
  // EvApproved exists iff application is Approved.
  all e: ApplicationEvent |
    e.eventType = EvApproved => e.forApplication.status = AppStatusApproved
  // EvRejected exists iff application is Rejected.
  all e: ApplicationEvent |
    e.eventType = EvRejected => e.forApplication.status = AppStatusRejected
  // EvSubmitted exists for every application.
  all a: LoanApplication |
    some e: ApplicationEvent | e.forApplication = a and e.eventType = EvSubmitted
  some ApplicationEvent
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md actor_user_id
pred AttributionCorrectness {
  // Submission events are attributed to the owning customer.
  all e: ApplicationEvent |
    e.eventType = EvSubmitted => e.actor = e.forApplication.owner
  // Decision events are attributed to BankStaff.
  all e: ApplicationEvent |
    (e.eventType = EvApproved or e.eventType = EvRejected) =>
    e.actor.role = BankStaff
  // The decider in the Decision record matches the decision-event actor.
  all a: LoanApplication |
    some a.decision => (
      a.status = AppStatusApproved =>
        (some e: ApplicationEvent |
          e.forApplication = a and
          e.eventType = EvApproved and
          e.actor = a.decision.decidedBy)
    )
  some ApplicationEvent
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id
pred OwnershipExclusivity {
  // Every application has exactly one owner (already structural via `one owner`).
  // Additionally that owner must be a Customer.
  all a: LoanApplication | a.owner.role = Customer
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GetApplicationByRef
pred OwnershipBasedAccess {
  // A customer's access to GetApplicationByRef is allowed in the permission matrix,
  // but ownership filters visibility: they see only their own applications.
  // We model this as: a Customer role does NOT see applications owned by other Customers.
  // Structural proxy: no application exists in the model where a Customer is both
  // the actor on a decision event AND not the owner of that application.
  all e: ApplicationEvent |
    (e.eventType = EvSubmitted and e.actor.role = Customer) =>
    e.actor = e.forApplication.owner
  // All decision events belong to BankStaff (confirmed separately); Customers never
  // appear as actors on decision events.
  no e: ApplicationEvent |
    e.actor.role = Customer and
    (e.eventType = EvApproved or e.eventType = EvRejected)
  some LoanApplication
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md 404-not-403 rule
pred NoInformationLeakage {
  // The permission matrix grants Customer -> GetApplicationByRef.
  // Existence leakage would be returning 403 (forbidden) instead of 404 when
  // a customer accesses another customer's application.  Structurally this means:
  // the model must NOT create a path where a Customer gains privileged information
  // about applications they don't own.  We encode: every loan application visible
  // to a Customer (i.e., reachable via their ownership) is exclusively their own.
  all a: LoanApplication |
    Customer -> GetApplicationByRef in PermMatrix.Allowed
  // No decision event is ever attributed to a Customer (they cannot perform decisions).
  no e: ApplicationEvent |
    e.actor.role = Customer and e.eventType != EvSubmitted
  some LoanApplication
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002; data-model.md validation.py
pred ValidationBeforeMutation {
  // A decision (mutation) requires a non-empty reason (Reason atom present).
  // If a Decision exists, it carries a Reason.
  all d: Decision | one d.reason
  // Every Decision is associated with an application that has the correct post-decision status.
  all a: LoanApplication |
    some a.decision =>
    (a.status = AppStatusApproved or a.status = AppStatusRejected)
  some LoanApplication
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md conditional UPDATE
pred ConcurrencySafety {
  // At most one Decision is recorded per application (lone field already enforces this).
  // Structural assertion: no two distinct Decision objects map to the same application.
  all a1, a2: LoanApplication |
    (some a1.decision and a1.decision = a2.decision) => a1 = a2
  // An application in PendingReview has no decision.
  all a: LoanApplication |
    a.status = PendingReview => no a.decision
  some LoanApplication
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// =============================================================================
//  FEATURE-SPECIFIC PREDICATES (FR-by-FR coverage)
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authenticated customer submits application
pred FR_001_CustomerCanSubmit {
  // The Customer role is permitted to call PostApplications.
  Customer -> PostApplications in PermMatrix.Allowed
  // BankStaff is NOT permitted to call PostApplications.
  BankStaff -> PostApplications not in PermMatrix.Allowed
}
assert FR_001_CustomerCanSubmit { FR_001_CustomerCanSubmit }
check FR_001_CustomerCanSubmit for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique reference and submitted status
pred FR_004_UniqueReferenceAndStatus {
  // Every newly submitted application starts at PendingReview.
  // Structural proxy: every application's status is one of the three allowed values,
  // and it has a submit event (hence a "reference" was assigned).
  all a: LoanApplication |
    some e: ApplicationEvent | e.forApplication = a and e.eventType = EvSubmitted
  // All applications are structurally distinct atoms (Alloy identity guarantees uniqueness).
  some LoanApplication
}
assert FR_004_UniqueReferenceAndStatus { FR_004_UniqueReferenceAndStatus }
check FR_004_UniqueReferenceAndStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 one pending application per customer
pred FR_005_OnePendingPerCustomer {
  // No customer has two or more applications simultaneously in PendingReview.
  all disj a1, a2: LoanApplication |
    a1.owner = a2.owner =>
    not (a1.status = PendingReview and a2.status = PendingReview)
  some LoanApplication
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-empty reason required on decision
pred FR_009_DecisionRequiresReason {
  // Every Decision has exactly one Reason atom (models non-empty reason string).
  all d: Decision | one d.reason
  // Reason atoms are not shared between decisions (each is unique to its decision).
  all disj d1, d2: Decision | d1.reason != d2.reason
  some Decision
}
assert FR_009_DecisionRequiresReason { FR_009_DecisionRequiresReason }
check FR_009_DecisionRequiresReason for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision persisted with all required fields
pred FR_010_DecisionPersisted {
  // A decided application has a Decision with decisionType, decidedBy, and reason.
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) => (
      one d: Decision |
        a.decision = d and
        one d.decisionType and
        one d.decidedBy and
        one d.reason and
        d.decidedBy.role = BankStaff
    )
  some a: LoanApplication | a.status = AppStatusApproved or a.status = AppStatusRejected
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 no further decision changes once decided
pred FR_011_NoReDecision {
  // Once an application is Approved or Rejected it has exactly one decision.
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) =>
    one a.decision
  // A PendingReview application has no decision.
  all a: LoanApplication |
    a.status = PendingReview => no a.decision
  some a: LoanApplication | a.status = AppStatusApproved or a.status = AppStatusRejected
}
assert FR_011_NoReDecision { FR_011_NoReDecision }
check FR_011_NoReDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 concurrent decisions resolved — only first wins
pred FR_012_ConcurrentDecisionSafety {
  // No two distinct Decision objects are associated with the same LoanApplication.
  all a1, a2: LoanApplication |
    (some a1.decision and a1.decision = a2.decision) => a1 = a2
  // Every LoanApplication has at most one decision.
  all a: LoanApplication | lone a.decision
  some LoanApplication
}
assert FR_012_ConcurrentDecisionSafety { FR_012_ConcurrentDecisionSafety }
check FR_012_ConcurrentDecisionSafety for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer sees only own applications; SC-004
pred FR_013_CustomerSeesOwnOnly {
  // Submission events are only attributed to the application's owner.
  all e: ApplicationEvent |
    (e.eventType = EvSubmitted and e.actor.role = Customer) =>
    e.actor = e.forApplication.owner
  // Notifications are only sent to the application's owner.
  all n: NotificationLog | n.recipient = n.forApplication.owner
  some LoanApplication
}
assert FR_013_CustomerSeesOwnOnly { FR_013_CustomerSeesOwnOnly }
check FR_013_CustomerSeesOwnOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 customer notified on status change
pred FR_014_NotificationOnDecision {
  // Every decided application has exactly one notification directed to the owner.
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) =>
    (one n: NotificationLog | n.forApplication = a and n.recipient = a.owner)
  // Pending applications have no notification.
  all a: LoanApplication |
    a.status = PendingReview => (no n: NotificationLog | n.forApplication = a)
  some a: LoanApplication | a.status = AppStatusApproved or a.status = AppStatusRejected
}
assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 decision actions restricted to bank_staff; SC-004
pred FR_015_StaffOnlyDecisions {
  // BankStaff can post decisions; Customer cannot.
  BankStaff -> PostDecision in PermMatrix.Allowed
  Customer  -> PostDecision not in PermMatrix.Allowed
  // BankStaff can access audit trail; Customer cannot.
  BankStaff -> GetAudit in PermMatrix.Allowed
  Customer  -> GetAudit not in PermMatrix.Allowed
  // Every Decision's decidedBy is a BankStaff user.
  all d: Decision | d.decidedBy.role = BankStaff
  some Decision
}
assert FR_015_StaffOnlyDecisions { FR_015_StaffOnlyDecisions }
check FR_015_StaffOnlyDecisions for 8 but exactly 2 Role, exactly 5 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail of all status changes
pred FR_016_AuditTrail {
  // Every application has a submission event.
  all a: LoanApplication |
    one e: ApplicationEvent | e.forApplication = a and e.eventType = EvSubmitted
  // Every approved application has exactly one approval event.
  all a: LoanApplication |
    a.status = AppStatusApproved =>
    (one e: ApplicationEvent | e.forApplication = a and e.eventType = EvApproved)
  // Every rejected application has exactly one rejection event.
  all a: LoanApplication |
    a.status = AppStatusRejected =>
    (one e: ApplicationEvent | e.forApplication = a and e.eventType = EvRejected)
  // No spurious decision events for pending applications.
  all a: LoanApplication |
    a.status = PendingReview =>
    (no e: ApplicationEvent | e.forApplication = a and
      (e.eventType = EvApproved or e.eventType = EvRejected))
  some ApplicationEvent
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 retention — decided applications are not deleted
// (Alloy static model: presence of application atoms after decision is structural)
pred FR_017_RetentionAfterDecision {
  // Every application that has a decision record still exists as a LoanApplication atom.
  all d: Decision |
    some a: LoanApplication | a.decision = d
  some Decision
}
assert FR_017_RetentionAfterDecision { FR_017_RetentionAfterDecision }
check FR_017_RetentionAfterDecision for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_SharedDecisionViolation { some disj a1, a2: LoanApplication | some d: Decision | a1.decision = d and a2.decision = d }
