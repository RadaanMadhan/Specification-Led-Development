// === feature_model.als — Alloy 6 model for Loan Application (A-L1 / 003-loan-application) ===
// Generated from: spec.md, data-model.md, contracts/http-api.md
// Patterns applied: LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//   AuditCompleteness, AppendOnly, AttributionCorrectness, OwnershipExclusivity,
//   OwnershipBasedAccess, NoInformationLeakage, ValidationBeforeMutation, ConcurrencySafety

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// USERS
// ─────────────────────────────────────────────────────────────────────────────
sig User {
  userRole: one Role
}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, StatusApproved, StatusRejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────────────────────
// TERM OPTIONS (FR-003)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig TermOption {}
one sig T12, T24, T36, T48, T60 extends TermOption {}

// ─────────────────────────────────────────────────────────────────────────────
// AMOUNT VALIDITY (FR-003)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig AmountValidity {}
one sig AmountInRange, AmountOutOfRange extends AmountValidity {}

// ─────────────────────────────────────────────────────────────────────────────
// LOAN APPLICATION
// ─────────────────────────────────────────────────────────────────────────────
sig LoanApplication {
  appOwner      : one User,
  appStatus     : one ApplicationStatus,
  appTerm       : one TermOption,
  appAmount     : one AmountValidity
}

// ─────────────────────────────────────────────────────────────────────────────
// DECISION  (data-model: at most one per application; PK = application_id)
// ─────────────────────────────────────────────────────────────────────────────
sig Decision {
  decidedApp : one LoanApplication,
  decidedBy  : one User
  // reason non-emptiness is enforced by F_DecisionReasonNonEmpty below
}

// Reason token — existence of a Reason linked to a Decision models non-empty reason
sig Reason {
  forDecision: one Decision
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT / EVENT TYPE
// ─────────────────────────────────────────────────────────────────────────────
abstract sig EventType {}
one sig EvtSubmitted, EvtApproved, EvtRejected extends EventType {}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT ENTRY  (data-model: append-only application_events; FR-016)
// ─────────────────────────────────────────────────────────────────────────────
sig AuditEntry {
  auditApp   : one LoanApplication,
  eventType  : one EventType,
  actor      : one User
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (contracts/http-api.md permission table)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig OpPostApplications,
        OpGetApplications,
        OpGetApplicationByRef,
        OpPostDecision,
        OpGetAudit extends OperationKind {}

// Permission matrix as a singleton-sig field (Rule 7 canonical pattern)
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// ACCESS RESPONSE SHAPE  (for NoInformationLeakage)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig AccessResponse {}
one sig Resp200, Resp404 extends AccessResponse {}

// Models: for a given (User, LoanApplication) pair, what the caller sees
sig AccessAttempt {
  caller   : one User,
  target   : one LoanApplication,
  response : one AccessResponse
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — ensure dynamic sigs are non-empty so predicates bite
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some Reason
  some AccessAttempt
}

// ─────────────────────────────────────────────────────────────────────────────
// F_PermissionMatrix — closed-world encoding of the contracts/ permission table
// spec.md FR-015; contracts/http-api.md permission matrix
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole  -> OpPostApplications)  +
    (CustomerRole  -> OpGetApplications)   +
    (CustomerRole  -> OpGetApplicationByRef) +
    (BankStaffRole -> OpGetApplications)   +
    (BankStaffRole -> OpGetApplicationByRef) +
    (BankStaffRole -> OpPostDecision)      +
    (BankStaffRole -> OpGetAudit)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OwnerIsCustomer — application owner must have the CustomerRole
// spec.md FR-001; data-model.md LoanApplication.customer_id FK→users
// ─────────────────────────────────────────────────────────────────────────────
fact F_OwnerIsCustomer {
  all la: LoanApplication | la.appOwner.userRole = CustomerRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionByStaffOnly — decisions may only be made by bank staff
// spec.md FR-015; contracts/http-api.md PostDecision permission row
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionByStaffOnly {
  all d: Decision | d.decidedBy.userRole = BankStaffRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AtMostOneDecisionPerApp — PK constraint from data-model.md decisions table
// data-model.md "application_id INTEGER PK"; spec.md FR-012
// ─────────────────────────────────────────────────────────────────────────────
fact F_AtMostOneDecisionPerApp {
  all disj d1, d2: Decision | d1.decidedApp != d2.decidedApp
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionReasonNonEmpty — every Decision must have exactly one Reason token
// spec.md FR-009; data-model.md decisions.reason CHECK(length(reason)>0)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionReasonNonEmpty {
  all d: Decision | one r: Reason | r.forDecision = d
}

// ─────────────────────────────────────────────────────────────────────────────
// F_StatusConsistencyWithDecision — decided status iff Decision exists
// data-model.md ApplicationStatus transitions; spec.md FR-010, FR-011
// ─────────────────────────────────────────────────────────────────────────────
fact F_StatusConsistencyWithDecision {
  all la: LoanApplication |
    (la.appStatus = StatusApproved or la.appStatus = StatusRejected)
      iff (some d: Decision | d.decidedApp = la)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OnePendingPerCustomer — partial unique index from data-model.md
// spec.md FR-005; data-model.md idx_one_pending_per_customer
// ─────────────────────────────────────────────────────────────────────────────
fact F_OnePendingPerCustomer {
  all disj la1, la2: LoanApplication |
    (la1.appOwner = la2.appOwner) implies
      not (la1.appStatus = PendingReview and la2.appStatus = PendingReview)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ValidAmountRange — amount must be in the allowed range
// spec.md FR-003; data-model.md requested_amount_minor CHECK BETWEEN
// ─────────────────────────────────────────────────────────────────────────────
fact F_ValidAmountRange {
  all la: LoanApplication | la.appAmount = AmountInRange
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditCompletenessSubmitted — every application has exactly one Submitted event
// spec.md FR-016; data-model.md application_events EventType.SUBMITTED
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditCompletenessSubmitted {
  all la: LoanApplication |
    one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtSubmitted
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditCompletenessDecided — every decided application has exactly one
//   approval or rejection audit event matching its status
// spec.md FR-016; data-model.md EventType.APPROVED / REJECTED
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditCompletenessDecided {
  all la: LoanApplication |
    la.appStatus = StatusApproved implies
      (one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtApproved)
  all la: LoanApplication |
    la.appStatus = StatusRejected implies
      (one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtRejected)
  all la: LoanApplication |
    la.appStatus = PendingReview implies
      no ae: AuditEntry | ae.auditApp = la and
        (ae.eventType = EvtApproved or ae.eventType = EvtRejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AttributionCorrectness — actor role matches event type
// spec.md FR-016; data-model.md AuditEntry.actor_user_id semantics
// ─────────────────────────────────────────────────────────────────────────────
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.eventType = EvtSubmitted implies ae.actor.userRole = CustomerRole
  all ae: AuditEntry |
    (ae.eventType = EvtApproved or ae.eventType = EvtRejected) implies
      ae.actor.userRole = BankStaffRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditActorMatchesAppOwner — Submitted audit actor IS the application owner
// spec.md FR-004; data-model.md "Customer for submitted"
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditActorMatchesAppOwner {
  all ae: AuditEntry |
    ae.eventType = EvtSubmitted implies ae.actor = ae.auditApp.appOwner
}

// ─────────────────────────────────────────────────────────────────────────────
// F_DecisionActorMatchesAuditActor — the staff member in the Decision and the
//   corresponding audit event must be the same person
// spec.md FR-010, FR-016
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionActorMatchesAuditActor {
  all d: Decision |
    let la = d.decidedApp |
      (la.appStatus = StatusApproved implies
        (all ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtApproved
          implies ae.actor = d.decidedBy)) and
      (la.appStatus = StatusRejected implies
        (all ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtRejected
          implies ae.actor = d.decidedBy))
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AppendOnlyAuditEntries — no two AuditEntry atoms share (app, eventType)
//   (structural encoding: each event slot is unique; no overwrite)
// spec.md FR-016, FR-017; data-model.md "No UPDATE/DELETE … application_events"
// ─────────────────────────────────────────────────────────────────────────────
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// F_OwnershipBasedAccess — AccessAttempt response rules
//   customer sees their own app → 200; non-owner → 404 (not 403)
//   staff always see any app → 200
// spec.md FR-013, SC-004; contracts/http-api.md GET /applications/{reference}
// ─────────────────────────────────────────────────────────────────────────────
fact F_OwnershipBasedAccess {
  all a: AccessAttempt |
    a.caller.userRole = CustomerRole implies
      (a.caller = a.target.appOwner iff a.response = Resp200)
  all a: AccessAttempt |
    a.caller.userRole = CustomerRole implies
      (a.caller != a.target.appOwner iff a.response = Resp404)
  all a: AccessAttempt |
    a.caller.userRole = BankStaffRole implies a.response = Resp200
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ValidationBeforeMutation — only AmountInRange apps exist in the system
//   (invalid submissions are rejected; no partial application enters the queue)
// spec.md FR-002, FR-003; data-model.md validation.py + column CHECKs
// ─────────────────────────────────────────────────────────────────────────────
fact F_ValidationBeforeMutation {
  no la: LoanApplication | la.appAmount = AmountOutOfRange
}

// ─────────────────────────────────────────────────────────────────────────────
// F_UniqueAuditSubmittedOwner — Submitted event actor is unique per application
//   (each app has exactly one submission event with the owner as actor)
// spec.md FR-004; data-model.md loan_applications.reference UNIQUE
// ─────────────────────────────────────────────────────────────────────────────
fact F_UniqueAuditSubmittedOwner {
  all disj ae1, ae2: AuditEntry |
    (ae1.eventType = EvtSubmitted and ae2.eventType = EvtSubmitted) implies
      ae1.auditApp != ae2.auditApp or ae1.actor != ae2.actor
}

// =============================================================================
// PREDICATES AND ASSERTIONS
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
// ─────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
  // Customer cannot access decision or audit operations
  CustomerRole -> OpPostDecision not in PermMatrix.Allowed
  CustomerRole -> OpGetAudit not in PermMatrix.Allowed
  // BankStaff cannot submit applications
  BankStaffRole -> OpPostApplications not in PermMatrix.Allowed
  // Positive: staff can decide and view audit
  BankStaffRole -> OpPostDecision in PermMatrix.Allowed
  BankStaffRole -> OpGetAudit in PermMatrix.Allowed
  // Positive: customer can submit
  CustomerRole -> OpPostApplications in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 2 Role, exactly 5 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair has a defined verdict (allow or deny);
  // the matrix covers the full cross-product
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
  // Additionally: every operation has at least one role that may perform it
  all op: OperationKind | some r: Role | r -> op in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 2 Role, exactly 5 OperationKind

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
// ─────────────────────────────────────────────────────────────────────────────
pred AuthRequiredEverywhere {
  // Every operation in the matrix is associated with a specific role;
  // there is no "anonymous" role that has any allowed operation
  // (modeled: no Role atom other than CustomerRole and BankStaffRole exists,
  //  and every Allowed entry names one of the two concrete roles)
  all r: Role, op: OperationKind |
    r -> op in PermMatrix.Allowed implies (r = CustomerRole or r = BankStaffRole)
  // Every user has a concrete role (no untyped user exists)
  all u: User | u.userRole = CustomerRole or u.userRole = BankStaffRole
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
// ─────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
  some LoanApplication
  // Every application has a submitted audit entry
  all la: LoanApplication |
    one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtSubmitted
  // Every approved application has exactly one approval audit entry
  all la: LoanApplication |
    la.appStatus = StatusApproved implies
      (one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtApproved)
  // Every rejected application has exactly one rejection audit entry
  all la: LoanApplication |
    la.appStatus = StatusRejected implies
      (one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-017; data-model.md "No UPDATE/DELETE … application_events"
// ─────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
  some AuditEntry
  // No two audit entries occupy the same (application, eventType) slot —
  // no overwriting of an existing entry is possible
  all disj ae1, ae2: AuditEntry |
    not (ae1.auditApp = ae2.auditApp and ae1.eventType = ae2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016, FR-010; data-model.md AuditEntry.actor_user_id
// ─────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
  some AuditEntry
  // Submitted events are attributed to customers
  all ae: AuditEntry |
    ae.eventType = EvtSubmitted implies ae.actor.userRole = CustomerRole
  // Approved/rejected events are attributed to bank staff
  all ae: AuditEntry |
    (ae.eventType = EvtApproved or ae.eventType = EvtRejected) implies
      ae.actor.userRole = BankStaffRole
  // The submitting customer in the audit entry is the actual owner
  all ae: AuditEntry |
    ae.eventType = EvtSubmitted implies ae.actor = ae.auditApp.appOwner
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id NOT NULL; spec.md "Customer" entity
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipExclusivity {
  some LoanApplication
  // Every application has exactly one owner (enforced by `one appOwner`)
  all la: LoanApplication | one la.appOwner
  // The owner is always a customer (not staff)
  all la: LoanApplication | la.appOwner.userRole = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md GET /applications/{reference}
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
  some AccessAttempt
  // A customer gets 200 iff the application belongs to them
  all a: AccessAttempt |
    a.caller.userRole = CustomerRole implies
      (a.response = Resp200 iff a.caller = a.target.appOwner)
  // Bank staff always gets 200
  all a: AccessAttempt |
    a.caller.userRole = BankStaffRole implies a.response = Resp200
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md "→404, not 403, to avoid leaking existence"
// ─────────────────────────────────────────────────────────────────────────────
pred NoInformationLeakage {
  some AccessAttempt
  // A customer denied access to another's application receives 404 — the same
  // response shape as "application does not exist" — never 403
  all a: AccessAttempt |
    (a.caller.userRole = CustomerRole and a.caller != a.target.appOwner) implies
      a.response = Resp404
  // In particular, 403 is NEVER the response shape for a customer's access
  // attempt on any application (ownership check, not permission check)
  all a: AccessAttempt |
    a.caller.userRole = CustomerRole implies a.response != Resp200 or
      a.caller = a.target.appOwner
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002, FR-003; data-model.md validation.py
// ─────────────────────────────────────────────────────────────────────────────
pred ValidationBeforeMutation {
  // No LoanApplication with an out-of-range amount exists in the system;
  // invalid submissions are rejected before any state is written
  no la: LoanApplication | la.appAmount = AmountOutOfRange
  // All persisted applications have a valid term
  all la: LoanApplication | some la.appTerm  // term is always one of the defined TermOptions
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md "conditional UPDATE … rowcount=1"
// ─────────────────────────────────────────────────────────────────────────────
pred ConcurrencySafety {
  some Decision
  // At most one Decision per application — concurrent decision attempts cannot
  // both succeed; the structural uniqueness enforces the "first wins" guarantee
  all disj d1, d2: Decision | d1.decidedApp != d2.decidedApp
  // Every decided application was in PendingReview before (it cannot be decided twice)
  all la: LoanApplication |
    (some d: Decision | d.decidedApp = la) implies
      (la.appStatus = StatusApproved or la.appStatus = StatusRejected)
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001 — authenticated customer submits application
// ─────────────────────────────────────────────────────────────────────────────
pred FR_001_CustomerSubmit {
  // Customer role is allowed to POST /applications
  CustomerRole -> OpPostApplications in PermMatrix.Allowed
  // Bank staff are NOT allowed to submit
  BankStaffRole -> OpPostApplications not in PermMatrix.Allowed
  // Every application has a customer owner
  some LoanApplication
  all la: LoanApplication | la.appOwner.userRole = CustomerRole
}
assert FR_001_CustomerSubmit { FR_001_CustomerSubmit }
check FR_001_CustomerSubmit for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002 — validation rejects invalid submissions before state change
// ─────────────────────────────────────────────────────────────────────────────
pred FR_002_ValidationBeforeStateChange {
  no la: LoanApplication | la.appAmount = AmountOutOfRange
  some LoanApplication
}
assert FR_002_ValidationBeforeStateChange { FR_002_ValidationBeforeStateChange }
check FR_002_ValidationBeforeStateChange for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003 — amount range and term set enforced structurally
// ─────────────────────────────────────────────────────────────────────────────
pred FR_003_ValidAmountAndTerm {
  some LoanApplication
  all la: LoanApplication | la.appAmount = AmountInRange
  all la: LoanApplication |
    la.appTerm = T12 or la.appTerm = T24 or la.appTerm = T36 or
    la.appTerm = T48 or la.appTerm = T60
}
assert FR_003_ValidAmountAndTerm { FR_003_ValidAmountAndTerm }
check FR_003_ValidAmountAndTerm for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004 — each application has a unique reference and records submitter
// ─────────────────────────────────────────────────────────────────────────────
pred FR_004_UniqueReferenceAndSubmitter {
  some LoanApplication
  // In Alloy, atoms are structurally distinct; model uniqueness of reference
  // by the fact that no two LoanApplication atoms are identical
  all disj la1, la2: LoanApplication | la1 != la2
  // Every application records exactly one owner (submitter)
  all la: LoanApplication | one la.appOwner
  // Initial status is PendingReview (captured by: submitted app has no Decision yet)
  all la: LoanApplication |
    la.appStatus = PendingReview implies (no d: Decision | d.decidedApp = la)
}
assert FR_004_UniqueReferenceAndSubmitter { FR_004_UniqueReferenceAndSubmitter }
check FR_004_UniqueReferenceAndSubmitter for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005 — at most one Pending Review application per customer
// ─────────────────────────────────────────────────────────────────────────────
pred FR_005_OnePendingPerCustomer {
  some LoanApplication
  all disj la1, la2: LoanApplication |
    la1.appOwner = la2.appOwner implies
      not (la1.appStatus = PendingReview and la2.appStatus = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009 — decision reason must be non-empty
// ─────────────────────────────────────────────────────────────────────────────
pred FR_009_DecisionReasonRequired {
  some Decision
  all d: Decision | one r: Reason | r.forDecision = d
}
assert FR_009_DecisionReasonRequired { FR_009_DecisionReasonRequired }
check FR_009_DecisionReasonRequired for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-010 — decision persisted with decider identity; status transitions
// ─────────────────────────────────────────────────────────────────────────────
pred FR_010_DecisionPersisted {
  some Decision
  all d: Decision |
    (d.decidedApp.appStatus = StatusApproved or
     d.decidedApp.appStatus = StatusRejected)
  all d: Decision | d.decidedBy.userRole = BankStaffRole
  // Decided apps exit the pending queue
  all la: LoanApplication |
    (some d: Decision | d.decidedApp = la) implies la.appStatus != PendingReview
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 — decided application status is immutable; no re-decision
// ─────────────────────────────────────────────────────────────────────────────
pred FR_011_DecidedAppImmutable {
  some Decision
  // An application that already has a Decision cannot receive a second one
  all disj d1, d2: Decision | d1.decidedApp != d2.decidedApp
  // A decided application's status is not PendingReview
  all d: Decision | d.decidedApp.appStatus != PendingReview
}
assert FR_011_DecidedAppImmutable { FR_011_DecidedAppImmutable }
check FR_011_DecidedAppImmutable for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012 — concurrent decisions: only one wins
// ─────────────────────────────────────────────────────────────────────────────
pred FR_012_ConcurrentDecisionOnlyOneWins {
  some Decision
  // Structural guarantee: at most one Decision per LoanApplication atom
  all la: LoanApplication | lone d: Decision | d.decidedApp = la
}
assert FR_012_ConcurrentDecisionOnlyOneWins { FR_012_ConcurrentDecisionOnlyOneWins }
check FR_012_ConcurrentDecisionOnlyOneWins for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013 — customer cannot see another customer's application
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_CustomerOwnershipAccess {
  some AccessAttempt
  all a: AccessAttempt |
    a.caller.userRole = CustomerRole implies
      (a.response = Resp200 iff a.caller = a.target.appOwner)
}
assert FR_013_CustomerOwnershipAccess { FR_013_CustomerOwnershipAccess }
check FR_013_CustomerOwnershipAccess for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 — customers cannot make decisions; decision ops are staff-only
// ─────────────────────────────────────────────────────────────────────────────
pred FR_015_StaffOnlyDecision {
  CustomerRole -> OpPostDecision not in PermMatrix.Allowed
  CustomerRole -> OpGetAudit not in PermMatrix.Allowed
  BankStaffRole -> OpPostDecision in PermMatrix.Allowed
  some Decision
  all d: Decision | d.decidedBy.userRole = BankStaffRole
}
assert FR_015_StaffOnlyDecision { FR_015_StaffOnlyDecision }
check FR_015_StaffOnlyDecision for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016 — every status-changing event has an audit record
// ─────────────────────────────────────────────────────────────────────────────
pred FR_016_AuditTrailComplete {
  some LoanApplication
  all la: LoanApplication |
    one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtSubmitted
  all la: LoanApplication |
    la.appStatus = StatusApproved implies
      (one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtApproved)
  all la: LoanApplication |
    la.appStatus = StatusRejected implies
      (one ae: AuditEntry | ae.auditApp = la and ae.eventType = EvtRejected)
  all ae: AuditEntry |
    ae.eventType = EvtSubmitted implies ae.actor = ae.auditApp.appOwner
  all ae: AuditEntry |
    (ae.eventType = EvtApproved or ae.eventType = EvtRejected) implies
      ae.actor.userRole = BankStaffRole
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017 — no application or decision is deleted (retention)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_017_RetentionNoDelete {
  // Structural model: every LoanApplication that has a Decision retains
  // the Decision (no orphaned applications, no missing decisions on decided apps)
  all la: LoanApplication |
    (la.appStatus = StatusApproved or la.appStatus = StatusRejected) implies
      (some d: Decision | d.decidedApp = la)
  some LoanApplication
}
assert FR_017_RetentionNoDelete { FR_017_RetentionNoDelete }
check FR_017_RetentionNoDelete for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.auditApp = ae2.auditApp and ae1.eventType = ae2.eventType }
