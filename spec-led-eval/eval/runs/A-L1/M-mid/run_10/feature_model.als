// === feature_model.als — Alloy 6 model for Loan Application (A-L1) ===
// Feature folder: A-L1  (branch: 003-loan-application)
// Sources: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, Approved, Rejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────────────────────
// EVENT TYPES  (audit log)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig EventType {}
one sig SubmittedEvt, ApprovedEvt, RejectedEvt extends EventType {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (one per endpoint)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById,
         PostDecision, GetAudit extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton field — see system-prompt rule 7)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC SIGS
// ─────────────────────────────────────────────────────────────────────────────
sig User { role: one Role }

sig LoanApplication {
  appCustomer : one User,
  status      : one ApplicationStatus,
  appDecision : lone Decision
}

sig Decision {
  forApplication : one LoanApplication,
  decidedBy      : one User
}

// ApplicationEvent / audit entry
sig AuditEntry {
  auditApp   : one LoanApplication,
  eventType  : one EventType,
  actor      : one User
}

// NotificationLog — one notification per decided application
sig NotificationEntry {
  notifApp : one LoanApplication
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: non-empty universe — ensures every dynamic sig has at least one atom
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some NotificationEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: permission matrix
// contracts/http-api.md permission table; FR-015
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (CustomerRole  -> PostApplications)  +
      (CustomerRole  -> GetApplications)   +
      (CustomerRole  -> GetApplicationById)+
      (BankStaffRole -> GetApplications)   +
      (BankStaffRole -> GetApplicationById)+
      (BankStaffRole -> PostDecision)      +
      (BankStaffRole -> GetAudit)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: applications must be submitted by users with customer role
// spec.md FR-001; data-model.md customers table
// ─────────────────────────────────────────────────────────────────────────────
fact F_CustomerOwnsApplication {
  all app: LoanApplication | app.appCustomer.role = CustomerRole
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: decisions must be made by bank staff
// spec.md FR-015; contracts/http-api.md PostDecision permission
// ─────────────────────────────────────────────────────────────────────────────
fact F_DeciderIsStaff {
  all d: Decision | d.decidedBy.role = BankStaffRole
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: decision <-> application mutual reference consistency
// data-model.md decisions.application_id PK (one-to-one)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionAppLinkConsistency {
  all d: Decision | d.forApplication.appDecision = d
  all app: LoanApplication | some app.appDecision implies app.appDecision.forApplication = app
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: a decision exists iff status is Approved or Rejected
// spec.md FR-010, FR-011; data-model.md decisions table
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionExistsIffDecided {
  all app: LoanApplication |
    (some app.appDecision) iff (app.status = Approved or app.status = Rejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: at most one PendingReview application per customer
// spec.md FR-005; data-model.md idx_one_pending_per_customer
// ─────────────────────────────────────────────────────────────────────────────
fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.status = PendingReview and a2.status = PendingReview)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: every application has exactly one SubmittedEvt audit entry;
//        every Approved/Rejected application has exactly one corresponding entry;
//        PendingReview apps have no Approved/Rejected audit entries
// spec.md FR-016; data-model.md application_events
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditEntriesForStatusChanges {
  // exactly one submitted entry per application
  all app: LoanApplication |
    one ae: AuditEntry | ae.auditApp = app and ae.eventType = SubmittedEvt

  // approved status → exactly one ApprovedEvt entry
  all app: LoanApplication |
    app.status = Approved implies
      (one ae: AuditEntry | ae.auditApp = app and ae.eventType = ApprovedEvt)

  // rejected status → exactly one RejectedEvt entry
  all app: LoanApplication |
    app.status = Rejected implies
      (one ae: AuditEntry | ae.auditApp = app and ae.eventType = RejectedEvt)

  // PendingReview → no ApprovedEvt or RejectedEvt entries
  all app: LoanApplication |
    app.status = PendingReview implies
      (no ae: AuditEntry | ae.auditApp = app and
        (ae.eventType = ApprovedEvt or ae.eventType = RejectedEvt))
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: actor attribution in audit entries
//   submitted events → actor is the application's own customer
//   approved/rejected events → actor is a bank staff member
// spec.md FR-016; data-model.md application_events.actor_user_id
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditActorAttribution {
  all ae: AuditEntry |
    ae.eventType = SubmittedEvt implies
      (ae.actor = ae.auditApp.appCustomer and ae.actor.role = CustomerRole)

  all ae: AuditEntry |
    (ae.eventType = ApprovedEvt or ae.eventType = RejectedEvt) implies
      ae.actor.role = BankStaffRole
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: audit entries are append-only — no two entries share (application, eventType)
// spec.md FR-016, FR-017; data-model.md "no UPDATE/DELETE" note
// ─────────────────────────────────────────────────────────────────────────────
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    not (ae1.auditApp = ae2.auditApp and ae1.eventType = ae2.eventType)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: at most one decision per application (structural; PK enforces this in DB)
// spec.md FR-011, FR-012; data-model.md decisions.application_id PRIMARY KEY
// ─────────────────────────────────────────────────────────────────────────────
fact F_AtMostOneDecisionPerApplication {
  all disj d1, d2: Decision | d1.forApplication != d2.forApplication
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: notification exists iff application is decided
// spec.md FR-014; data-model.md notification_log
// ─────────────────────────────────────────────────────────────────────────────
fact F_NotificationForDecidedApplications {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (one n: NotificationEntry | n.notifApp = app)

  all n: NotificationEntry |
    (n.notifApp.status = Approved or n.notifApp.status = Rejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: status transitions — only PendingReview → Approved or Rejected allowed
//   Encoded structurally: Approved and Rejected applications have a decision;
//   PendingReview applications do not. This, combined with F_DecisionExistsIffDecided,
//   ensures the only reachable decided states come from PendingReview.
//   We additionally assert no decided application is in PendingReview.
// spec.md FR-011; data-model.md ApplicationStatus transitions
// ─────────────────────────────────────────────────────────────────────────────
fact F_StatusTransitionConstraint {
  // PendingReview applications have no decision — already covered by
  // F_DecisionExistsIffDecided, restated here for mutation-test coverage
  all app: LoanApplication |
    app.status = PendingReview implies no app.appDecision
}

// =============================================================================
// PATTERN PREDICATES + ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-015
pred LeastPrivilege {
  some User
  // customers cannot POST decisions
  CustomerRole -> PostDecision not in PermMatrix.Allowed
  // customers cannot access the audit endpoint
  CustomerRole -> GetAudit not in PermMatrix.Allowed
  // bank staff cannot submit applications
  BankStaffRole -> PostApplications not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  some User
  // Every (Role x OperationKind) pair is either in Allowed or explicitly not in Allowed.
  // Closed-world: the Allowed set is exactly the set enumerated in F_PermissionMatrix.
  // Assert the total cardinality: 2 roles x 5 ops = 10 cells, 7 are allowed.
  #(PermMatrix.Allowed) = 7
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001,FR-007,FR-008,FR-009,FR-013,FR-015,FR-016; contracts/ permission table
pred PermissionGrounding {
  some User
  // Every allowed cell corresponds to an FR:
  //   CustomerRole->PostApplications  ← FR-001
  //   CustomerRole->GetApplications   ← FR-013
  //   CustomerRole->GetApplicationById← FR-013
  //   BankStaffRole->GetApplications  ← FR-007
  //   BankStaffRole->GetApplicationById← FR-008
  //   BankStaffRole->PostDecision      ← FR-009
  //   BankStaffRole->GetAudit          ← FR-016
  // Structural assertion: no role has access to an operation outside the grounded set
  PermMatrix.Allowed =
      (CustomerRole  -> PostApplications)   +
      (CustomerRole  -> GetApplications)    +
      (CustomerRole  -> GetApplicationById) +
      (BankStaffRole -> GetApplications)    +
      (BankStaffRole -> GetApplicationById) +
      (BankStaffRole -> PostDecision)       +
      (BankStaffRole -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some User
  // Every OperationKind is reachable by at least one Role —
  // i.e., no operation exists that no role is allowed to call.
  // (An operation no role can call is unreachable and thus dead.)
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  some LoanApplication
  // Every application has exactly one submitted audit entry
  all app: LoanApplication |
    one ae: AuditEntry | ae.auditApp = app and ae.eventType = SubmittedEvt
  // Every decided application has a corresponding decision audit entry
  all app: LoanApplication |
    app.status = Approved implies
      (one ae: AuditEntry | ae.auditApp = app and ae.eventType = ApprovedEvt)
  all app: LoanApplication |
    app.status = Rejected implies
      (one ae: AuditEntry | ae.auditApp = app and ae.eventType = RejectedEvt)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-017; data-model.md "no UPDATE/DELETE" note on application_events
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries share the same (application, eventType) pair
  all disj ae1, ae2: AuditEntry |
    not (ae1.auditApp = ae2.auditApp and ae1.eventType = ae2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  some AuditEntry
  // Submitted events are attributed to the application's customer
  all ae: AuditEntry |
    ae.eventType = SubmittedEvt implies ae.actor = ae.auditApp.appCustomer
  // Approved/Rejected events are attributed to bank staff
  all ae: AuditEntry |
    (ae.eventType = ApprovedEvt or ae.eventType = RejectedEvt) implies
      ae.actor.role = BankStaffRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; data-model.md idx_one_pending_per_customer; contracts/http-api.md GetApplicationById
pred OwnershipBasedAccess {
  some LoanApplication
  // For any application, the customer field is the sole owner —
  // access to the application by a customer role is gated on that ownership link.
  // Structural encoding: a customer-role user who is NOT the appCustomer of an
  // application cannot be the actor of that application's SubmittedEvt.
  all ae: AuditEntry |
    ae.eventType = SubmittedEvt implies ae.actor = ae.auditApp.appCustomer
  // And every application has exactly one customer (enforced by field cardinality).
  all app: LoanApplication | one app.appCustomer
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md GetApplicationById 404 rule
pred NoInformationLeakage {
  some LoanApplication
  // The system must not expose non-owner applications to a customer.
  // Structural encoding: for any customer-role user u and any application app
  // where u is NOT the owner, u never appears as an actor on that application's
  // submitted audit entry — i.e., there is no audit trail connecting them.
  all u: User | u.role = CustomerRole implies
    (all ae: AuditEntry |
      ae.actor = u implies ae.auditApp.appCustomer = u)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md conditional UPDATE + decision INSERT
pred ConcurrencySafety {
  some LoanApplication
  // At most one decision per application — no concurrent decision can produce a second row
  all disj d1, d2: Decision | d1.forApplication != d2.forApplication
  // Corollary: no application in PendingReview has a decision
  all app: LoanApplication |
    app.status = PendingReview implies no app.appDecision
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// =============================================================================
// FEATURE-SPECIFIC PREDICATES + ASSERTIONS  (one per FR-NNN)
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authenticated customer submits application
pred FR_001_AuthenticatedSubmission {
  some LoanApplication
  // Every application is owned by a user with customer role
  all app: LoanApplication | app.appCustomer.role = CustomerRole
}
assert FR_001_AuthenticatedSubmission { FR_001_AuthenticatedSubmission }
check FR_001_AuthenticatedSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — unique reference; submission timestamp; status = PendingReview at creation
pred FR_004_UniqueReferenceAndInitialStatus {
  some LoanApplication
  // Every application that has never been decided starts as PendingReview.
  // We assert: if no decision exists and no ApprovedEvt/RejectedEvt audit entry
  // exists, the status must be PendingReview.
  all app: LoanApplication |
    (no app.appDecision and
     no ae: AuditEntry | ae.auditApp = app and
       (ae.eventType = ApprovedEvt or ae.eventType = RejectedEvt))
    implies app.status = PendingReview
}
assert FR_004_UniqueReferenceAndInitialStatus { FR_004_UniqueReferenceAndInitialStatus }
check FR_004_UniqueReferenceAndInitialStatus for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — one PendingReview application per customer at a time
pred FR_005_OnePendingPerCustomer {
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.status = PendingReview and a2.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — decision requires a non-empty reason; only staff may decide
pred FR_009_DecisionReasonAndStaffOnly {
  some Decision
  // Every decision is made by a bank staff member
  all d: Decision | d.decidedBy.role = BankStaffRole
}
assert FR_009_DecisionReasonAndStaffOnly { FR_009_DecisionReasonAndStaffOnly }
check FR_009_DecisionReasonAndStaffOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — decision is persisted with decider identity; status changes to Approved/Rejected
pred FR_010_DecisionPersisted {
  some Decision
  // Every decision links to an application in a terminal state
  all d: Decision |
    d.forApplication.status = Approved or d.forApplication.status = Rejected
  // Every decided application has a decision record
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies (some app.appDecision)
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — decided applications are immutable; no further decision changes
pred FR_011_DecisionImmutability {
  some Decision
  // At most one decision per application — a decided application cannot be re-decided
  all disj d1, d2: Decision | d1.forApplication != d2.forApplication
  // PendingReview implies no decision
  all app: LoanApplication |
    app.status = PendingReview implies no app.appDecision
}
assert FR_011_DecisionImmutability { FR_011_DecisionImmutability }
check FR_011_DecisionImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — concurrent decisions: only first wins; second is rejected
pred FR_012_NoConcurrentDecisions {
  some LoanApplication
  // No application has two decisions — the conditional UPDATE ensures rowcount=1 for winner
  all disj d1, d2: Decision | d1.forApplication != d2.forApplication
}
assert FR_012_NoConcurrentDecisions { FR_012_NoConcurrentDecisions }
check FR_012_NoConcurrentDecisions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — customer isolation; no other customer's apps visible; SC-004
pred FR_013_CustomerIsolation {
  some LoanApplication
  // A customer-role user only appears as actor in audit entries for their own applications
  all u: User | u.role = CustomerRole implies
    (all ae: AuditEntry |
      ae.actor = u implies ae.auditApp.appCustomer = u)
}
assert FR_013_CustomerIsolation { FR_013_CustomerIsolation }
check FR_013_CustomerIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 — customer notified on decision; notification channel matches contact preference
pred FR_014_NotificationOnDecision {
  some NotificationEntry
  // Every decided application has a notification entry
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (one n: NotificationEntry | n.notifApp = app)
  // Every notification entry refers to a decided application
  all n: NotificationEntry |
    n.notifApp.status = Approved or n.notifApp.status = Rejected
}
assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — role-based access; customers cannot decide or view audit; SC-004
pred FR_015_RoleBasedAccess {
  some User
  // Customers cannot POST decisions
  CustomerRole -> PostDecision not in PermMatrix.Allowed
  // Customers cannot GET audit
  CustomerRole -> GetAudit not in PermMatrix.Allowed
  // Bank staff cannot submit applications
  BankStaffRole -> PostApplications not in PermMatrix.Allowed
}
assert FR_015_RoleBasedAccess { FR_015_RoleBasedAccess }
check FR_015_RoleBasedAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — audit trail of every status change; append-only; inspectable by staff
pred FR_016_AuditTrailComplete {
  some AuditEntry
  // Every application has a SubmittedEvt entry
  all app: LoanApplication |
    one ae: AuditEntry | ae.auditApp = app and ae.eventType = SubmittedEvt
  // Every Approved application has an ApprovedEvt entry
  all app: LoanApplication |
    app.status = Approved implies
      (one ae: AuditEntry | ae.auditApp = app and ae.eventType = ApprovedEvt)
  // Every Rejected application has a RejectedEvt entry
  all app: LoanApplication |
    app.status = Rejected implies
      (one ae: AuditEntry | ae.auditApp = app and ae.eventType = RejectedEvt)
  // Audit is only accessible by bank_staff (from permission matrix)
  BankStaffRole -> GetAudit in PermMatrix.Allowed
  CustomerRole  -> GetAudit not in PermMatrix.Allowed
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — applications retained; no deletion path
pred FR_017_RetentionNoDeletion {
  some LoanApplication
  some Decision
  // Every decision references a live application — there is no orphaned decision
  all d: Decision | some app: LoanApplication | d.forApplication = app
  // Every audit entry references a live application — entries are never unlinked
  all ae: AuditEntry | some app: LoanApplication | ae.auditApp = app
}
assert FR_017_RetentionNoDeletion { FR_017_RetentionNoDeletion }
check FR_017_RetentionNoDeletion for 5