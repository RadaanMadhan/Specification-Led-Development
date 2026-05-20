// === feature_model.als — Alloy model for Loan Application (003-loan-application) ===
//
// Self-contained Alloy 6 model encoding the structural invariants of the
// loan-application feature: roles, the (Role × OperationKind) permission matrix,
// loan applications, decisions, and the append-only audit log.

// -------------------------------------------------------------------------
// Non-empty universe so that universal predicates have bite
// -------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
}

// -------------------------------------------------------------------------
// Roles (spec.md "Key Entities"; data-model.md Role enum)
// -------------------------------------------------------------------------
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// -------------------------------------------------------------------------
// Operation kinds — the five endpoints from contracts/http-api.md
// -------------------------------------------------------------------------
abstract sig OperationKind {}
one sig PostApplication, GetApplicationsList, GetApplicationById,
        PostDecision, GetAudit extends OperationKind {}

// -------------------------------------------------------------------------
// Permission matrix as a singleton-sig field
// -------------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer  -> PostApplication)     +
    (Customer  -> GetApplicationsList) +
    (Customer  -> GetApplicationById)  +
    (BankStaff -> GetApplicationsList) +
    (BankStaff -> GetApplicationById)  +
    (BankStaff -> PostDecision)        +
    (BankStaff -> GetAudit)
}

// -------------------------------------------------------------------------
// Enums for status / decision-type / event-type
// -------------------------------------------------------------------------
abstract sig ApplicationStatus {}
one sig PendingReview, ApprovedStatus, RejectedStatus extends ApplicationStatus {}

abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

abstract sig EventType {}
one sig SubmittedEvent, ApprovedEvent, RejectedEvent extends EventType {}

// -------------------------------------------------------------------------
// Entities
// -------------------------------------------------------------------------
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
  decidedBy:    one User,
  reason:       lone Reason
}

sig ApplicationEvent {
  application: one LoanApplication,
  eventType:   one EventType,
  actor:       one User
}

// Operation models a single in-flight API call after authentication has resolved.
sig Operation {
  caller: one User,
  kind:   one OperationKind,
  target: lone LoanApplication
}

// -------------------------------------------------------------------------
// Structural facts (each named so a mutation harness can clear its body)
// -------------------------------------------------------------------------

// Customers are the only applicants (data-model.md customer_id FK + Role enum)
fact F_ApplicantIsCustomer {
  all a: LoanApplication | a.customer.role = Customer
}

// Only staff record decisions (FR-015; data-model.md decided_by_user_id)
fact F_DecidersAreStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

// Unique reference per application (FR-004; data-model.md reference UNIQUE)
fact F_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// At most one Decision per application (FR-011, FR-012; PK on decisions.application_id)
fact F_AtMostOneDecisionPerApplication {
  all a: LoanApplication | lone d: Decision | d.application = a
}

// Decision presence and decisionType match application status (FR-010)
fact F_DecisionMatchesStatus {
  all a: LoanApplication |
    a.status = ApprovedStatus implies
      (one d: Decision | d.application = a and d.decisionType = ApprovedDecision)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (one d: Decision | d.application = a and d.decisionType = RejectedDecision)
  all d: Decision | d.application.status != PendingReview
}

// At most one application in Pending Review per customer (FR-005)
fact F_OnePendingPerCustomer {
  all u: User |
    lone a: LoanApplication | a.customer = u and a.status = PendingReview
}

// Every decision has a recorded reason (FR-009)
fact F_DecisionHasReason {
  all d: Decision | one d.reason
}

// Every application has exactly one Submitted event whose actor is the customer
fact F_SubmittedEventPerApplication {
  all a: LoanApplication |
    one e: ApplicationEvent |
      e.application = a and e.eventType = SubmittedEvent and e.actor = a.customer
}

// Every decided application has its decision-event, with staff actor
fact F_DecisionEventPerDecidedApplication {
  all a: LoanApplication |
    a.status = ApprovedStatus implies
      (one e: ApplicationEvent |
         e.application = a and e.eventType = ApprovedEvent and
         e.actor.role = BankStaff)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (one e: ApplicationEvent |
         e.application = a and e.eventType = RejectedEvent and
         e.actor.role = BankStaff)
  all e: ApplicationEvent |
    e.eventType = ApprovedEvent implies e.application.status = ApprovedStatus
  all e: ApplicationEvent |
    e.eventType = RejectedEvent implies e.application.status = RejectedStatus
}

// Decision-event actor must be the user who actually decided (attribution)
fact F_DecisionEventActorMatchesDecider {
  all e: ApplicationEvent |
    (e.eventType = ApprovedEvent or e.eventType = RejectedEvent) implies
      (some d: Decision | d.application = e.application and d.decidedBy = e.actor)
}

// Audit log canonicality: at most one event per (application, event_type).
// This is the append-only structural witness — a "mutated" entry would
// surface here as two distinct events for the same status change.
fact F_AtMostOneEventPerStatusChange {
  all a: LoanApplication, et: EventType |
    lone e: ApplicationEvent | e.application = a and e.eventType = et
}

// Every operation must satisfy the permission matrix
fact F_OperationsRespectMatrix { /* MUTATED — body cleared by validator */ }

// Customer operations against a specific target only succeed if they own it
fact F_CustomerOpsScopedToOwnedApps {
  all op: Operation |
    (op.caller.role = Customer and some op.target) implies
      op.target.customer = op.caller
}

// =========================================================================
// CATALOGUE PATTERNS
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-015
pred LeastPrivilege {
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
  no op: Operation | op.caller.role = BankStaff and op.kind = PostApplication
  no op: Operation | op.caller.role = Customer  and op.kind = PostDecision
  no op: Operation | op.caller.role = Customer  and op.kind = GetAudit
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md tables; spec.md FRs 001/007/008/013/015
pred PermissionGrounding {
  // Every allowed cell is one of the seven grounded in the contract / FRs.
  PermMatrix.Allowed in
    (Customer  -> PostApplication)     +
    (Customer  -> GetApplicationsList) +
    (Customer  -> GetApplicationById)  +
    (BankStaff -> GetApplicationsList) +
    (BankStaff -> GetApplicationById)  +
    (BankStaff -> PostDecision)        +
    (BankStaff -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8 but exactly 2 Role, exactly 5 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Every operation has a resolved caller with exactly one role.
  all op: Operation | one op.caller and one op.caller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-016; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    (one e: ApplicationEvent |
       e.application = a and e.eventType = SubmittedEvent and e.actor = a.customer)
  all a: LoanApplication |
    a.status = ApprovedStatus implies
      (some e: ApplicationEvent | e.application = a and e.eventType = ApprovedEvent)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (some e: ApplicationEvent | e.application = a and e.eventType = RejectedEvent)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: FR-016; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  // No two distinct events for the same (application, eventType) — i.e. no
  // overwriting / duplicate-rewrite of a status-change entry.
  all a: LoanApplication, et: EventType |
    lone e: ApplicationEvent | e.application = a and e.eventType = et
  // And decision events only exist for applications that actually reached
  // the corresponding status — no fabricated entries.
  all e: ApplicationEvent |
    e.eventType = ApprovedEvent implies e.application.status = ApprovedStatus
  all e: ApplicationEvent |
    e.eventType = RejectedEvent implies e.application.status = RejectedStatus
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: FR-016; data-model.md actor_user_id
pred AttributionCorrectness {
  all e: ApplicationEvent |
    e.eventType = SubmittedEvent implies e.actor = e.application.customer
  all e: ApplicationEvent |
    (e.eventType = ApprovedEvent or e.eventType = RejectedEvent) implies
      e.actor.role = BankStaff
  all e: ApplicationEvent |
    (e.eventType = ApprovedEvent or e.eventType = RejectedEvent) implies
      (some d: Decision | d.application = e.application and d.decidedBy = e.actor)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id FK NOT NULL
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-013; contracts/http-api.md GET /applications/{ref}
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and some op.target) implies
      op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: FR-013; contracts/http-api.md 404-on-non-owner
// Structural surrogate: a customer caller never reaches a foreign application.
// Externally, this is what gives 404 (not 403) the same shape for "doesn't exist"
// as for "exists but not yours" — the foreign app is simply unreachable.
pred NoInformationLeakage {
  no op: Operation |
    op.caller.role = Customer and some op.target and op.target.customer != op.caller
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-002; validation.py "all violations in one response"
pred ValidationBeforeMutation {
  // Every persisted application has a real Customer-roled customer; no half-built
  // record exists with the wrong actor type.
  all a: LoanApplication | a.customer.role = Customer
  all a: LoanApplication | one a.reference
  // Every persisted decision has a non-empty reason.
  all d: Decision | one d.reason
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: FR-012; SC-005
pred ConcurrencySafety {
  all a: LoanApplication | lone d: Decision | d.application = a
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// =========================================================================
// PER-FR ASSERTIONS
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 customer-only submission
pred FR_001_CustomerCanSubmit {
  Customer  -> PostApplication in PermMatrix.Allowed
  BankStaff -> PostApplication not in PermMatrix.Allowed
}
assert FR_001_CustomerCanSubmit { FR_001_CustomerCanSubmit }
check FR_001_CustomerCanSubmit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 field-level validation before state change
pred FR_002_NoInvalidPersistedApplications {
  all a: LoanApplication | a.customer.role = Customer
  all a: LoanApplication | one a.status
  all a: LoanApplication | one a.reference
}
assert FR_002_NoInvalidPersistedApplications { FR_002_NoInvalidPersistedApplications }
check FR_002_NoInvalidPersistedApplications for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 status enum is closed
pred FR_003_StatusEnumClosed {
  ApplicationStatus = PendingReview + ApprovedStatus + RejectedStatus
  all a: LoanApplication | a.status in ApplicationStatus
}
assert FR_003_StatusEnumClosed { FR_003_StatusEnumClosed }
check FR_003_StatusEnumClosed for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique reference per application
pred FR_004_UniqueReferencePerApplication {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}
assert FR_004_UniqueReferencePerApplication { FR_004_UniqueReferencePerApplication }
check FR_004_UniqueReferencePerApplication for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 one Pending Review application per customer
pred FR_005_OnePendingPerCustomer {
  all u: User |
    lone a: LoanApplication | a.customer = u and a.status = PendingReview
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 confirmation surface (reference + status snapshot)
pred FR_006_ApplicationHasReferenceAndStatus {
  all a: LoanApplication | (one a.reference and one a.status)
}
assert FR_006_ApplicationHasReferenceAndStatus { FR_006_ApplicationHasReferenceAndStatus }
check FR_006_ApplicationHasReferenceAndStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 staff queue access
pred FR_007_StaffCanListApplications {
  BankStaff -> GetApplicationsList in PermMatrix.Allowed
}
assert FR_007_StaffCanListApplications { FR_007_StaffCanListApplications }
check FR_007_StaffCanListApplications for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 staff can view application detail
pred FR_008_StaffCanViewApplicationDetail {
  BankStaff -> GetApplicationById in PermMatrix.Allowed
}
assert FR_008_StaffCanViewApplicationDetail { FR_008_StaffCanViewApplicationDetail }
check FR_008_StaffCanViewApplicationDetail for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-empty reason mandatory on every decision
pred FR_009_DecisionRequiresReason {
  all d: Decision | one d.reason
}
assert FR_009_DecisionRequiresReason { FR_009_DecisionRequiresReason }
check FR_009_DecisionRequiresReason for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision atomically changes status & persists outcome
pred FR_010_DecisionChangesStatus {
  all a: LoanApplication |
    a.status = ApprovedStatus implies
      (one d: Decision | d.application = a and d.decisionType = ApprovedDecision)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (one d: Decision | d.application = a and d.decisionType = RejectedDecision)
  all d: Decision | d.application.status != PendingReview
}
assert FR_010_DecisionChangesStatus { FR_010_DecisionChangesStatus }
check FR_010_DecisionChangesStatus for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 decided application is immutable (no second decision, no revert)
pred FR_011_NoSecondDecision {
  all a: LoanApplication | lone d: Decision | d.application = a
  no d: Decision | d.application.status = PendingReview
}
assert FR_011_NoSecondDecision { FR_011_NoSecondDecision }
check FR_011_NoSecondDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 concurrent decisions: at most one ever recorded
pred FR_012_SingleDecisionUnderConcurrency {
  all a: LoanApplication | lone d: Decision | d.application = a
}
assert FR_012_SingleDecisionUnderConcurrency { FR_012_SingleDecisionUnderConcurrency }
check FR_012_SingleDecisionUnderConcurrency for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer cannot see another customer's application
pred FR_013_CustomerScopedToOwnApps {
  all op: Operation |
    (op.caller.role = Customer and some op.target) implies
      op.target.customer = op.caller
}
assert FR_013_CustomerScopedToOwnApps { FR_013_CustomerScopedToOwnApps }
check FR_013_CustomerScopedToOwnApps for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 notification fires on decision (event presence proxy)
pred FR_014_NotificationEventOnDecision {
  all a: LoanApplication |
    a.status = ApprovedStatus implies
      (some e: ApplicationEvent | e.application = a and e.eventType = ApprovedEvent)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (some e: ApplicationEvent | e.application = a and e.eventType = RejectedEvent)
}
assert FR_014_NotificationEventOnDecision { FR_014_NotificationEventOnDecision }
check FR_014_NotificationEventOnDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 decide / audit endpoints restricted to staff
pred FR_015_DecisionStaffOnly {
  Customer  -> PostDecision not in PermMatrix.Allowed
  Customer  -> GetAudit      not in PermMatrix.Allowed
  BankStaff -> PostDecision  in PermMatrix.Allowed
  BankStaff -> GetAudit      in PermMatrix.Allowed
  all d: Decision | d.decidedBy.role = BankStaff
}
assert FR_015_DecisionStaffOnly { FR_015_DecisionStaffOnly }
check FR_015_DecisionStaffOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail of every status change
pred FR_016_AuditEveryStatusChange {
  all a: LoanApplication |
    (some e: ApplicationEvent | e.application = a and e.eventType = SubmittedEvent)
  all a: LoanApplication |
    a.status = ApprovedStatus implies
      (some e: ApplicationEvent | e.application = a and e.eventType = ApprovedEvent)
  all a: LoanApplication |
    a.status = RejectedStatus implies
      (some e: ApplicationEvent | e.application = a and e.eventType = RejectedEvent)
}
assert FR_016_AuditEveryStatusChange { FR_016_AuditEveryStatusChange }
check FR_016_AuditEveryStatusChange for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 retention => referential integrity (no orphan decisions/events)
pred FR_017_ReferentialIntegrityForRetention {
  all d: Decision         | one d.application
  all e: ApplicationEvent | one e.application
}
assert FR_017_ReferentialIntegrityForRetention { FR_017_ReferentialIntegrityForRetention }
check FR_017_ReferentialIntegrityForRetention for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PermissionViolation { some op: Operation | op.caller.role = Customer and op.kind = PostDecision }
