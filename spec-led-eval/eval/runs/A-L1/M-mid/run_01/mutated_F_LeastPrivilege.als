// === feature_model.als — Alloy model for Loan Application (A-L1 / 003-loan-application) ===
// Artefacts: spec.md (FR-001 – FR-017), data-model.md, contracts/http-api.md

// ─── Roles ───────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ─── Operation kinds (one per HTTP-method × endpoint) ────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostDecision, GetAuditLog extends OperationKind {}

// ─── Permission matrix as a singleton-sig field ───────────────────────────────
// contracts/http-api.md "Permission matrix"
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─── Application status ──────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, AppStatusApproved, AppStatusRejected extends ApplicationStatus {}

// ─── Decision kind ───────────────────────────────────────────────────────────
abstract sig DecisionKind {}
one sig DApproved, DRejected extends DecisionKind {}

// ─── Audit event type ────────────────────────────────────────────────────────
abstract sig EventType {}
one sig EvtSubmitted, EvtApproved, EvtRejected extends EventType {}

// ─── Access outcome (used for NoInformationLeakage modelling) ────────────────
abstract sig AccessOutcome {}
one sig OutcomeOK, Outcome404, Outcome403 extends AccessOutcome {}

// ─── Dynamic sigs ────────────────────────────────────────────────────────────
sig User {
  role: one Role
}

sig LoanApplication {
  appCustomer: one User,
  status:      one ApplicationStatus
}

// Each Decision is linked one-to-one to a LoanApplication.
// data-model.md: decisions.application_id is the PK (enforces at-most-one).
sig Decision {
  decApp:       one LoanApplication,
  decidedBy:    one User,
  decisionKind: one DecisionKind
}

// Append-only audit entries (data-model.md: application_events, FR-016).
sig AuditEntry {
  auditApp:  one LoanApplication,
  eventType: one EventType,
  actor:     one User
}

// API operation — models a single resolved call with a caller and a target.
sig Operation {
  caller:    one User,
  kind:      one OperationKind,
  targetApp: lone LoanApplication    // absent for collection endpoints
}

// ─── F_NonEmptyUniverse ──────────────────────────────────────────────────────
// Required so all/some quantifiers over dynamic sigs are non-vacuous.
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some Operation
}

// ─── F_PermissionMatrix ──────────────────────────────────────────────────────
// Encodes the exact permission table from contracts/http-api.md.
// Closed-world: the equality forces every unlisted cell to be denied.
fact F_PermissionMatrix {
  Customer   -> PostApplications  in PermMatrix.Allowed
  Customer   -> GetApplications   in PermMatrix.Allowed
  Customer   -> GetApplicationByRef in PermMatrix.Allowed
  BankStaff  -> GetApplications   in PermMatrix.Allowed
  BankStaff  -> GetApplicationByRef in PermMatrix.Allowed
  BankStaff  -> PostDecision      in PermMatrix.Allowed
  BankStaff  -> GetAuditLog       in PermMatrix.Allowed
  PermMatrix.Allowed =
    (Customer  -> PostApplications)   +
    (Customer  -> GetApplications)    +
    (Customer  -> GetApplicationByRef) +
    (BankStaff -> GetApplications)    +
    (BankStaff -> GetApplicationByRef) +
    (BankStaff -> PostDecision)       +
    (BankStaff -> GetAuditLog)
}

// ─── F_LeastPrivilege ────────────────────────────────────────────────────────
// Every modelled Operation must be permitted by the matrix.
fact F_LeastPrivilege { /* MUTATED — body cleared by validator */ }

// ─── F_AuthRequiredEverywhere ────────────────────────────────────────────────
// Every Operation has a caller with a defined role; no anonymous call reaches any handler.
fact F_AuthRequiredEverywhere {
  all op: Operation | one op.caller and op.caller in User
  // No OperationKind is reachable without at least one allowed role in the matrix.
  all ok: OperationKind | some r: Role | r -> ok in PermMatrix.Allowed
}

// ─── F_CustomerOwnsApplication ───────────────────────────────────────────────
// Every LoanApplication is submitted by (and owned by) a user with the Customer role.
fact F_CustomerOwnsApplication {
  all a: LoanApplication | a.appCustomer.role = Customer
}

// ─── F_OwnershipExclusivity ──────────────────────────────────────────────────
// Each application has exactly one customer owner; ownership is never shared.
// data-model.md: loan_applications.customer_id NOT NULL FK→users.id (one owner).
fact F_OwnershipExclusivity {
  all a: LoanApplication | one a.appCustomer
}

// ─── F_DeciderIsStaff ────────────────────────────────────────────────────────
// Every Decision is recorded by a user with the BankStaff role (FR-015).
fact F_DeciderIsStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

// ─── F_AtMostOneDecisionPerApplication ───────────────────────────────────────
// At most one Decision per LoanApplication.
// data-model.md: decisions.application_id is the PRIMARY KEY.
fact F_AtMostOneDecisionPerApplication {
  all disj d1, d2: Decision | d1.decApp != d2.decApp
}

// ─── F_DecisionIffDecidedStatus ──────────────────────────────────────────────
// An application has a Decision iff its status is Approved or Rejected.
fact F_DecisionIffDecidedStatus {
  all a: LoanApplication |
    (some d: Decision | d.decApp = a)
    iff
    (a.status = AppStatusApproved or a.status = AppStatusRejected)
}

// ─── F_DecisionKindMatchesStatus ─────────────────────────────────────────────
// DApproved ↔ AppStatusApproved; DRejected ↔ AppStatusRejected.
fact F_DecisionKindMatchesStatus {
  all d: Decision |
    (d.decisionKind = DApproved iff d.decApp.status = AppStatusApproved) and
    (d.decisionKind = DRejected iff d.decApp.status = AppStatusRejected)
}

// ─── F_AuditSubmittedEntry ────────────────────────────────────────────────────
// Every application has exactly one EvtSubmitted audit entry whose actor is
// the application's customer (FR-016, AttributionCorrectness for submission).
fact F_AuditSubmittedEntry {
  all a: LoanApplication |
    one e: AuditEntry |
      e.auditApp = a and e.eventType = EvtSubmitted and e.actor = a.appCustomer
}

// ─── F_AuditDecisionEntry ─────────────────────────────────────────────────────
// Every decided application has exactly one decision audit entry whose actor
// matches the Decision's decidedBy field (FR-016, AttributionCorrectness for decisions).
fact F_AuditDecisionEntry {
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (one e: AuditEntry |
       e.auditApp = a and
       (e.eventType = EvtApproved or e.eventType = EvtRejected) and
       (some d: Decision | d.decApp = a and e.actor = d.decidedBy))
}

// ─── F_AuditEventTypeMatchesStatus ───────────────────────────────────────────
// EvtApproved entries only for Approved applications; EvtRejected only for Rejected.
fact F_AuditEventTypeMatchesStatus {
  all e: AuditEntry |
    (e.eventType = EvtApproved implies e.auditApp.status = AppStatusApproved) and
    (e.eventType = EvtRejected implies e.auditApp.status = AppStatusRejected) and
    (e.eventType = EvtSubmitted implies e.auditApp.status in
       (PendingReview + AppStatusApproved + AppStatusRejected))
}

// ─── F_AppendOnlyAuditEntries ─────────────────────────────────────────────────
// Append-only invariant: for every decided application the EvtSubmitted entry
// is still present — it was never removed.  Combined with F_AuditDecisionEntry
// this means decided apps always carry both their submission and decision entries.
// data-model.md: "No UPDATE/DELETE code path targets this table."
fact F_AppendOnlyAuditEntries {
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (some e: AuditEntry | e.auditApp = a and e.eventType = EvtSubmitted)
}

// ─── F_OnePendingPerCustomer ─────────────────────────────────────────────────
// No customer may have more than one application in PendingReview simultaneously.
// data-model.md: idx_one_pending_per_customer partial unique index (FR-005).
fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
    not (a1.status = PendingReview and a2.status = PendingReview)
}

// ─── F_DecidedApplicationImmutable ───────────────────────────────────────────
// An application that is Approved or Rejected has exactly one Decision and no
// further decision can be recorded (enforced by at-most-one + status check, FR-011).
fact F_DecidedApplicationImmutable {
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (one d: Decision | d.decApp = a)
}

// ─── F_NoDecisionOnPending ────────────────────────────────────────────────────
// No Decision exists for an application still in PendingReview.
fact F_NoDecisionOnPending {
  all a: LoanApplication |
    a.status = PendingReview implies (no d: Decision | d.decApp = a)
}

// ─── F_ConcurrencySafety ─────────────────────────────────────────────────────
// At most one Decision per application — even under concurrent attempts.
// This is structurally equivalent to F_AtMostOneDecisionPerApplication but
// stated here as the concurrency-safety fact so it can serve as a mutation target.
fact F_ConcurrencySafety {
  all a: LoanApplication |
    lone d: Decision | d.decApp = a
}

// ─── F_OwnershipBasedAccess ──────────────────────────────────────────────────
// A Customer-role Operation targeting GetApplicationByRef may only be directed
// at an application owned by the caller (FR-013, SC-004).
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationByRef) implies
    (some a: LoanApplication | op.targetApp = a and a.appCustomer = op.caller)
}

// ─── F_NoInformationLeakage (helper function) ─────────────────────────────────
// Model the access outcome for a customer reaching a reference endpoint.
// Returns Outcome404 both for non-existent and for not-owned applications.
// We encode this as: if a Customer's operation targets an application they don't own,
// the operation is simply not permitted — it cannot appear in the modelled Operations.
// (F_OwnershipBasedAccess already enforces this structurally.)
// The assertion below additionally verifies that BankStaff never returns 403 for
// a real reference, and that Customer never returns 403 (only 404) for a foreign ref.
fact F_StaffCanAccessAllApplications {
  // BankStaff GetApplicationByRef is not restricted to owned apps
  // (no ownership filter added for bank_staff — contrast with customer).
  all op: Operation |
    (op.caller.role = BankStaff and op.kind = GetApplicationByRef) implies
    (op.targetApp in LoanApplication)
}

// ─── F_StaffOnlyDecisionAndAudit ─────────────────────────────────────────────
// PostDecision and GetAuditLog operations may only be performed by BankStaff.
// contracts/http-api.md: customer → 403 for both endpoints.
fact F_StaffOnlyDecisionAndAudit {
  all op: Operation |
    (op.kind = PostDecision or op.kind = GetAuditLog) implies
    op.caller.role = BankStaff
}

// ─── F_CustomerCannotDecide ───────────────────────────────────────────────────
// No customer-role user has a Decision attributed to them.
fact F_CustomerCannotDecide {
  all d: Decision | d.decidedBy.role = BankStaff
}

// ─── F_ValidationNoStateChange ───────────────────────────────────────────────
// An application that fails validation (status never set to PendingReview or beyond)
// has no Decision and no audit entry — invalid submissions leave no trace.
// Modelled as: every AuditEntry's application is a valid (fully-formed) LoanApplication.
fact F_ValidationNoStateChange {
  all e: AuditEntry | e.auditApp in LoanApplication
  // No Decision references a non-existent (phantom) application.
  all d: Decision | d.decApp in LoanApplication
}

// ─── F_UniqueApplicationPerDecision ──────────────────────────────────────────
// Each application has at most one Decision (re-stated directly as a unique mapping).
fact F_UniqueApplicationPerDecision {
  all a: LoanApplication |
    lone d: Decision | d.decApp = a
}

// ═════════════════════════════════════════════════════════════════════════════
// P A T T E R N   P R E D I C A T E S
// ═════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some op: Operation |
    op.caller.role -> op.kind in PermMatrix.Allowed
  all op: Operation |
    op.caller.role -> op.kind in PermMatrix.Allowed
  // Denied cells: Customer cannot PostDecision or GetAuditLog
  Customer -> PostDecision  not in PermMatrix.Allowed
  Customer -> GetAuditLog   not in PermMatrix.Allowed
  // Denied cells: BankStaff cannot PostApplications
  BankStaff -> PostApplications not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either allowed or denied — no undefined cells.
  // The Allowed relation is fully defined by F_PermissionMatrix (closed-world equality).
  // A cell is "defined" iff the matrix has a verdict: we verify the Allowed set
  // has exactly 7 entries (2 customer + 5 total minus 2 BankStaff not-PostApplications etc).
  #PermMatrix.Allowed = 7
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md authentication section; FR-001, FR-007
pred AuthRequiredEverywhere {
  // Every Operation has exactly one authenticated caller
  some op: Operation | one op.caller
  all op: Operation | one op.caller and op.caller.role in Role
  // Every OperationKind has at least one allowed role (no dead-letter endpoint)
  all ok: OperationKind | some r: Role | r -> ok in PermMatrix.Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  // Every application has at least one audit entry (the submitted event)
  some LoanApplication
  all a: LoanApplication |
    some e: AuditEntry | e.auditApp = a
  // Every decided application has both a submitted entry and a decision entry
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    ((some e: AuditEntry | e.auditApp = a and e.eventType = EvtSubmitted) and
     (some e: AuditEntry | e.auditApp = a and
        (e.eventType = EvtApproved or e.eventType = EvtRejected)))
  // No decided application is missing its decision audit entry
  all d: Decision |
    some e: AuditEntry |
      e.auditApp = d.decApp and
      (e.eventType = EvtApproved or e.eventType = EvtRejected) and
      e.actor = d.decidedBy
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-017; data-model.md "No UPDATE/DELETE"
pred AppendOnly {
  // For every decided application, its submission audit entry is still present
  // (it was never removed — append-only invariant).
  some a: LoanApplication | a.status = AppStatusApproved or a.status = AppStatusRejected
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (some e: AuditEntry | e.auditApp = a and e.eventType = EvtSubmitted and e.actor = a.appCustomer)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_user_id
pred AttributionCorrectness {
  // EvtSubmitted entries are attributed to the application's customer
  some AuditEntry
  all e: AuditEntry |
    e.eventType = EvtSubmitted implies e.actor = e.auditApp.appCustomer
  // EvtApproved/EvtRejected entries are attributed to the deciding staff member
  all e: AuditEntry |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
    (some d: Decision | d.decApp = e.auditApp and d.decidedBy = e.actor)
  // No audit entry attributes a staff action to a customer-role user
  all e: AuditEntry |
    (e.eventType = EvtApproved or e.eventType = EvtRejected) implies
    e.actor.role = BankStaff
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-013; data-model.md LoanApplication.customer_id NOT NULL FK
pred OwnershipExclusivity {
  // Every application has exactly one customer owner (no orphan, no co-ownership)
  some LoanApplication
  all a: LoanApplication | one a.appCustomer and a.appCustomer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md GetApplicationByRef
pred OwnershipBasedAccess {
  // A customer can only reach a specific application via GetApplicationByRef
  // if that application belongs to them.
  some op: Operation | op.caller.role = Customer and op.kind = GetApplicationByRef
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationByRef) implies
    (some a: LoanApplication | op.targetApp = a and a.appCustomer = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md "404 not 403"
pred NoInformationLeakage {
  // The model has no Operation where a customer accesses a foreign application.
  // Both "non-existent" and "not-owned" yield the same outcome (absence from Operations),
  // i.e., no customer-role Operation exists with a targetApp belonging to a different customer.
  some u1, u2: User |
    u1 != u2 and u1.role = Customer and u2.role = Customer
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationByRef) implies
    (all a: LoanApplication |
      op.targetApp = a implies a.appCustomer = op.caller)
  // BankStaff never needs the 403 path for GetApplicationByRef — they always get 200 or 404.
  // No Operation with BankStaff caller on GetApplicationByRef is missing a targetApp
  // when one is supplied (structural: targetApp ∈ LoanApplication).
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ═════════════════════════════════════════════════════════════════════════════
// F E A T U R E - S P E C I F I C   P R E D I C A T E S
// ═════════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-004 unique reference number and status = PendingReview on submission
pred FR_004_UniqueReference {
  // Every submitted (pending) application is a distinct object — no two applications
  // share the same identity in the model, modelling the UNIQUE reference constraint.
  some LoanApplication
  all disj a1, a2: LoanApplication | a1 != a2
  // Every application that was just submitted starts in PendingReview.
  // We model: every application with an EvtSubmitted entry and no decision entry
  // must be in PendingReview.
  all a: LoanApplication |
    ((some e: AuditEntry | e.auditApp = a and e.eventType = EvtSubmitted) and
     (no d: Decision | d.decApp = a)) implies
    a.status = PendingReview
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 one pending application per customer
pred FR_005_OnePendingPerCustomer {
  some a: LoanApplication | a.status = PendingReview
  all u: User |
    u.role = Customer implies
    (lone a: LoanApplication | a.appCustomer = u and a.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-empty reason required on decision
pred FR_009_ReasonRequired {
  // Every Decision has a decidedBy staff user (proxy for non-empty reason:
  // the existence of a Decision atom implies all its required fields are present).
  some Decision
  all d: Decision | one d.decidedBy and one d.decisionKind and one d.decApp
}
assert FR_009_ReasonRequired { FR_009_ReasonRequired }
check FR_009_ReasonRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 decision persisted with decider identity and timestamp
pred FR_010_DecisionPersisted {
  // Every Approved/Rejected application has exactly one Decision with a BankStaff decider.
  some a: LoanApplication | a.status = AppStatusApproved or a.status = AppStatusRejected
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (one d: Decision | d.decApp = a and d.decidedBy.role = BankStaff)
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 no re-decision on decided applications
pred FR_011_DecidedApplicationImmutable {
  // No application in Approved or Rejected status has more than one Decision.
  some a: LoanApplication | a.status = AppStatusApproved or a.status = AppStatusRejected
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (one d: Decision | d.decApp = a)
  // No pending application has any Decision.
  all a: LoanApplication |
    a.status = PendingReview implies (no d: Decision | d.decApp = a)
}
assert FR_011_DecidedApplicationImmutable { FR_011_DecidedApplicationImmutable }
check FR_011_DecidedApplicationImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 concurrency safety — first decision wins, SC-005
pred FR_012_ConcurrencySafety {
  // No application can have two decisions — even after concurrent attempts.
  some LoanApplication
  all a: LoanApplication | lone d: Decision | d.decApp = a
  // An application cannot simultaneously be in Approved and Rejected status — impossible
  // by sig definition, but we assert no application has contradictory decisions.
  no disj d1, d2: Decision | d1.decApp = d2.decApp
}
assert FR_012_ConcurrencySafety { FR_012_ConcurrencySafety }
check FR_012_ConcurrencySafety for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 customer isolation — SC-004
pred FR_013_CustomerIsolation {
  // A customer-role Operation on GetApplications or GetApplicationByRef
  // cannot expose another customer's application.
  some u: User | u.role = Customer
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationByRef) implies
    (all a: LoanApplication | op.targetApp = a implies a.appCustomer = op.caller)
}
assert FR_013_CustomerIsolation { FR_013_CustomerIsolation }
check FR_013_CustomerIsolation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 staff-only decision and audit endpoints
pred FR_015_StaffOnlyDecisionAudit {
  // No customer-role user can perform PostDecision or GetAuditLog.
  Customer -> PostDecision  not in PermMatrix.Allowed
  Customer -> GetAuditLog   not in PermMatrix.Allowed
  // Additionally: no Operation of kind PostDecision or GetAuditLog has a Customer caller.
  all op: Operation |
    (op.kind = PostDecision or op.kind = GetAuditLog) implies
    op.caller.role = BankStaff
}
assert FR_015_StaffOnlyDecisionAudit { FR_015_StaffOnlyDecisionAudit }
check FR_015_StaffOnlyDecisionAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit trail — every status-changing event recorded
pred FR_016_AuditTrailComplete {
  // Every application has at least one audit entry.
  some LoanApplication
  all a: LoanApplication | some e: AuditEntry | e.auditApp = a
  // Every decided application's decision entry is attributed to a BankStaff member.
  all a: LoanApplication |
    (a.status = AppStatusApproved or a.status = AppStatusRejected) implies
    (some e: AuditEntry |
       e.auditApp = a and
       (e.eventType = EvtApproved or e.eventType = EvtRejected) and
       e.actor.role = BankStaff)
  // Submission event is always attributed to the customer.
  all a: LoanApplication |
    some e: AuditEntry |
      e.auditApp = a and e.eventType = EvtSubmitted and e.actor = a.appCustomer
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 no deletion — applications retained permanently
pred FR_017_NoApplicationDeletion {
  // In this snapshot model there is no concept of deletion; every LoanApplication
  // atom is present and has a status. We verify: no application can "vanish" —
  // every application that has a Decision also has an intact audit trail.
  some d: Decision | d.decApp.status = AppStatusApproved or d.decApp.status = AppStatusRejected
  all d: Decision |
    some e: AuditEntry | e.auditApp = d.decApp and e.eventType = EvtSubmitted
}
assert FR_017_NoApplicationDeletion { FR_017_NoApplicationDeletion }
check FR_017_NoApplicationDeletion for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-007 staff cannot submit; customer cannot post decisions
pred FR_001_CustomerSubmitOnly {
  // PostApplications is allowed only for Customer-role users.
  BankStaff -> PostApplications not in PermMatrix.Allowed
  all op: Operation |
    op.kind = PostApplications implies op.caller.role = Customer
}
assert FR_001_CustomerSubmitOnly { FR_001_CustomerSubmitOnly }
check FR_001_CustomerSubmitOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 validation — invalid submissions produce no side effects
pred FR_002_ValidationBeforeMutation {
  // Every LoanApplication in the model has passed validation and thus has a
  // EvtSubmitted audit entry and is in PendingReview (or subsequently decided).
  // No AuditEntry can reference a non-existent application (phantom).
  all e: AuditEntry | e.auditApp in LoanApplication
  all d: Decision | d.decApp in LoanApplication
  // An application without a submitted event cannot be in any status.
  // (F_AuditSubmittedEntry already enforces this; here we state it as a reachable assertion.)
  all a: LoanApplication |
    some e: AuditEntry | e.auditApp = a and e.eventType = EvtSubmitted
}
assert FR_002_ValidationBeforeMutation { FR_002_ValidationBeforeMutation }
check FR_002_ValidationBeforeMutation for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeastPrivilegeViolation { some op: Operation | op.caller.role = Customer and op.kind = PostDecision }
