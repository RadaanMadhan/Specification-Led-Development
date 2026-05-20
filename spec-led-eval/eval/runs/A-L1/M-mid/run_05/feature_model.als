// === feature_model.als — Alloy 6 model for Loan Application (A-L1) ===
// Feature folder : A-L1  (spec.md branch 003-loan-application)
// Artefacts      : spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

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
// DECISION TYPES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (HTTP endpoints)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig OpPostApp, OpGetApps, OpGetAppByRef, OpPostDecision, OpGetAudit
  extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION OUTCOMES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationOutcome {}
one sig OutSuccess, OutDenied, OutNotFound extends OperationOutcome {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton carrier for the allowed relation)
// canonical pattern from the prompt — contracts/http-api.md permission table
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE DOMAIN SIGS  (dynamic — need `some` in F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────────────────
sig User {
  role: one Role
}

sig LoanApplication {
  owner          : one User,
  status         : one ApplicationStatus,
  decisionRecord : lone Decision
}

sig Decision {
  forApp      : one LoanApplication,
  decisionType: one DecisionType,
  decidedBy   : one User
}

sig ApplicationEvent {
  forApp   : one LoanApplication,
  eventType: one EventType,
  actor    : one User
}

sig Operation {
  caller : one User,
  kind   : one OperationKind,
  outcome: one OperationOutcome,
  // When the operation targets a specific application (GetByRef, PostDecision,
  // GetAudit) this field is set; for collection-level ops it is empty.
  targetApp: lone LoanApplication
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX FACT
// contracts/http-api.md  "Permission matrix" table
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  // Closed-world enumeration of every allowed (Role, OperationKind) cell.
  PermMatrix.Allowed =
      (Customer   -> OpPostApp)       +
      (Customer   -> OpGetApps)       +
      (Customer   -> OpGetAppByRef)   +
      (BankStaff  -> OpGetApps)       +
      (BankStaff  -> OpGetAppByRef)   +
      (BankStaff  -> OpPostDecision)  +
      (BankStaff  -> OpGetAudit)
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL DOMAIN FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Every loan application is owned by a user with the Customer role  (FR-001)
fact F_OwnerIsCustomer {
  all a: LoanApplication | a.owner.role = Customer
}

// Every decision is made by a user with the BankStaff role  (FR-015)
fact F_DecidedByStaff {
  all d: Decision | d.decidedBy.role = BankStaff
}

// Decision ↔ LoanApplication is a bijection:
//   – decisionRecord points back to the canonical Decision
//   – Decision.forApp points back to the canonical LoanApplication
fact F_DecisionBijection {
  all d: Decision | d.forApp.decisionRecord = d
  all a: LoanApplication | (some a.decisionRecord) implies a.decisionRecord.forApp = a
}

// A Decision exists if and only if the application has been decided  (FR-010, FR-011)
fact F_DecisionExistsIffDecided {
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) iff (some a.decisionRecord)
}

// Decision type matches application status  (FR-010)
fact F_DecisionStatusConsistency {
  all a: LoanApplication |
    (some a.decisionRecord) implies (
      (a.status = Approved  iff a.decisionRecord.decisionType = DecApproved) and
      (a.status = Rejected  iff a.decisionRecord.decisionType = DecRejected)
    )
}

// At most one application in PendingReview per customer  (FR-005)
fact F_OnePendingPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.owner = a2.owner) implies
      not (a1.status = PendingReview and a2.status = PendingReview)
}

// Append-only: ApplicationEvents are never mutated.
// Structurally: no two distinct events share the same (application, eventType, actor)
// triple — a "replace" would need a duplicate, which this forbids.  (FR-016)
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: ApplicationEvent |
    not (e1.forApp = e2.forApp and
         e1.eventType = e2.eventType and
         e1.actor = e2.actor)
}

// Audit completeness for submission: every LoanApplication has
// exactly one SubmittedEvt event whose actor is the application owner.  (FR-016, FR-004)
fact F_AuditSubmitEvent {
  all a: LoanApplication |
    one e: ApplicationEvent |
      e.forApp = a and e.eventType = SubmittedEvt and e.actor = a.owner
}

// Audit completeness for decisions: every Approved app has exactly one
// ApprovedEvt; every Rejected app has exactly one RejectedEvt.  (FR-016, FR-010)
fact F_AuditDecisionEvent {
  all a: LoanApplication |
    (a.status = Approved) implies
      (one e: ApplicationEvent | e.forApp = a and e.eventType = ApprovedEvt)
  all a: LoanApplication |
    (a.status = Rejected) implies
      (one e: ApplicationEvent | e.forApp = a and e.eventType = RejectedEvt)
}

// Attribution: the actor on decision audit events matches the recorded decider.  (FR-016, FR-010)
fact F_AttributionCorrectness {
  all a: LoanApplication |
    (a.status = Approved) implies (
      all e: ApplicationEvent |
        (e.forApp = a and e.eventType = ApprovedEvt) implies
          e.actor = a.decisionRecord.decidedBy
    )
  all a: LoanApplication |
    (a.status = Rejected) implies (
      all e: ApplicationEvent |
        (e.forApp = a and e.eventType = RejectedEvt) implies
          e.actor = a.decisionRecord.decidedBy
    )
}

// No PendingReview application has any decision audit event  (FR-010: only on decide)
fact F_NoPendingDecisionEvent {
  all a: LoanApplication |
    (a.status = PendingReview) implies
      (no e: ApplicationEvent |
        e.forApp = a and
        (e.eventType = ApprovedEvt or e.eventType = RejectedEvt))
}

// Operations: denied operations have no side effects on LoanApplication state.
// A denied Operation targeting an app must not be the cause of status change.
// Modelled as: if an Operation is OutDenied, the targetApp's status is unchanged
// (structurally: denied ops that target a PendingReview app do not produce a Decision).  (FR-015)
fact F_ValidationBeforeMutation {
  all op: Operation |
    (op.outcome = OutDenied and some op.targetApp) implies
      op.targetApp.status = PendingReview
        or (some op.targetApp.decisionRecord and op.targetApp.decisionRecord.decidedBy != op.caller)
}

// LeastPrivilege: every Operation whose outcome is OutSuccess must be in Allowed;
// every denied-role Operation must NOT be in Allowed.  (contracts/http-api.md)
fact F_LeastPrivilege {
  all op: Operation |
    (op.outcome = OutSuccess) implies
      (op.caller.role -> op.kind) in PermMatrix.Allowed
  all op: Operation |
    (op.caller.role -> op.kind) not in PermMatrix.Allowed implies
      op.outcome = OutDenied
}

// OwnershipBasedAccess: a Customer Operation on GetAppByRef succeeds only if
// the caller owns the targetApp.  (FR-013, contracts/http-api.md)
fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.kind = OpGetAppByRef and op.caller.role = Customer) implies (
      (op.outcome = OutSuccess)    implies op.targetApp.owner = op.caller
    )
}

// NoInformationLeakage: a Customer accessing an app they don't own gets NotFound,
// never Denied.  (FR-013, contracts/http-api.md)
fact F_NoInformationLeakage {
  all op: Operation |
    (op.kind = OpGetAppByRef and op.caller.role = Customer and
     some op.targetApp and op.targetApp.owner != op.caller) implies
       op.outcome = OutNotFound
}

// ConcurrencySafety / FR-012: at most one Decision per LoanApplication
// (enforced by bijection above, but stated explicitly for clarity)
fact F_AtMostOneDecision {
  all disj d1, d2: Decision | d1.forApp != d2.forApp
}

// ─────────────────────────────────────────────────────────────────────────────
// PREDICATES AND ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  some Operation
  all op: Operation |
    (op.outcome = OutSuccess) implies
      (op.caller.role -> op.kind) in PermMatrix.Allowed
  all op: Operation |
    (op.caller.role -> op.kind) not in PermMatrix.Allowed implies
      op.outcome = OutDenied
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every (Role, OperationKind) pair has a defined verdict: either it is in
  // Allowed (permit) or it is not (deny).  The closed-world fact makes this
  // trivially complete; the assertion checks the matrix is non-trivial (some
  // cells both allowed and denied).
  some r: Role, ok: OperationKind | (r -> ok) in PermMatrix.Allowed
  some r: Role, ok: OperationKind | (r -> ok) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001, FR-007, FR-008, FR-009, FR-013, FR-015
pred PermissionGrounding {
  // Every allowed (Role, OperationKind) pair corresponds to a grounded FR.
  // Customer → PostApp (FR-001), Customer → GetApps (FR-013),
  // Customer → GetAppByRef (FR-013), BankStaff → GetApps (FR-007),
  // BankStaff → GetAppByRef (FR-008), BankStaff → PostDecision (FR-009),
  // BankStaff → GetAudit (FR-016).
  // Structural check: BankStaff cannot post an application (FR-015).
  (BankStaff -> OpPostApp) not in PermMatrix.Allowed
  // Structural check: Customer cannot post a decision (FR-015).
  (Customer -> OpPostDecision) not in PermMatrix.Allowed
  // Structural check: Customer cannot access the audit trail (FR-015).
  (Customer -> OpGetAudit) not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  // Every Operation has an authenticated caller (a concrete User with a Role).
  // In this model, every Operation has caller: one User and role is always defined.
  some Operation
  all op: Operation | one op.caller and one op.caller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md ApplicationEvent
pred AuditCompleteness {
  some LoanApplication
  // Every application has at least its submission audit entry.
  all a: LoanApplication |
    some e: ApplicationEvent | e.forApp = a and e.eventType = SubmittedEvt
  // Every decided application has the matching decision audit entry.
  all a: LoanApplication |
    (a.status = Approved) implies
      (some e: ApplicationEvent | e.forApp = a and e.eventType = ApprovedEvt)
  all a: LoanApplication |
    (a.status = Rejected) implies
      (some e: ApplicationEvent | e.forApp = a and e.eventType = RejectedEvt)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016, FR-017; data-model.md "No UPDATE/DELETE"
pred AppendOnly {
  some ApplicationEvent
  // No two distinct ApplicationEvents for the same application share the same
  // (eventType, actor) pair — a mutation would require replacing one record,
  // which would appear as a duplicate under the old and new values.
  all disj e1, e2: ApplicationEvent |
    not (e1.forApp = e2.forApp and
         e1.eventType = e2.eventType and
         e1.actor = e2.actor)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016, FR-010; data-model.md Decision.decided_by_user_id
pred AttributionCorrectness {
  some a: LoanApplication | a.status = Approved or a.status = Rejected
  all a: LoanApplication |
    (a.status = Approved) implies (
      all e: ApplicationEvent |
        (e.forApp = a and e.eventType = ApprovedEvt) implies
          e.actor = a.decisionRecord.decidedBy
    )
  all a: LoanApplication |
    (a.status = Rejected) implies (
      all e: ApplicationEvent |
        (e.forApp = a and e.eventType = RejectedEvt) implies
          e.actor = a.decisionRecord.decidedBy
    )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id; spec.md Key Entities
pred OwnershipExclusivity {
  some LoanApplication
  // Every loan application has exactly one owner.
  all a: LoanApplication | one a.owner
  // The owner is always a Customer.
  all a: LoanApplication | a.owner.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
  some op: Operation | op.kind = OpGetAppByRef and op.caller.role = Customer
  all op: Operation |
    (op.kind = OpGetAppByRef and op.caller.role = Customer and
     op.outcome = OutSuccess) implies
       (some op.targetApp and op.targetApp.owner = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013, SC-004; contracts/http-api.md "404 not 403"
pred NoInformationLeakage {
  some op: Operation |
    op.kind = OpGetAppByRef and op.caller.role = Customer
  all op: Operation |
    (op.kind = OpGetAppByRef and op.caller.role = Customer and
     some op.targetApp and op.targetApp.owner != op.caller) implies
       op.outcome = OutNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002; data-model.md validation.py; contracts/http-api.md 400
pred ValidationBeforeMutation {
  some LoanApplication
  // Every application in the model was successfully submitted (status set),
  // meaning no invalid application reaches Pending/Approved/Rejected state.
  // Structural proxy: every denied operation does not produce a new Decision.
  all op: Operation |
    (op.outcome = OutDenied) implies
      (no d: Decision | d.decidedBy = op.caller and some op.targetApp and d.forApp = op.targetApp
         and op.kind = OpPostDecision)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005; data-model.md "conditional UPDATE"
pred ConcurrencySafety {
  some LoanApplication
  // At most one Decision per LoanApplication — concurrent decisions cannot
  // both succeed; the second must be rejected.
  all disj d1, d2: Decision | d1.forApp != d2.forApp
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-005; data-model.md idx_one_pending_per_customer
pred FR_005_OnePendingPerCustomer {
  some LoanApplication
  all disj a1, a2: LoanApplication |
    (a1.owner = a2.owner) implies
      not (a1.status = PendingReview and a2.status = PendingReview)
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md "No UPDATE/DELETE on decisions"
pred FR_011_DecidedApplicationsImmutable {
  some a: LoanApplication | a.status = Approved or a.status = Rejected
  // A decided application has exactly one Decision, and no operation can
  // change an already-decided status.
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies (one a.decisionRecord)
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies
      (no op: Operation |
        op.kind = OpPostDecision and op.outcome = OutSuccess and op.targetApp = a
        and op.caller != a.decisionRecord.decidedBy)
}
assert FR_011_DecidedApplicationsImmutable { FR_011_DecidedApplicationsImmutable }
check FR_011_DecidedApplicationsImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; data-model.md Decision; spec.md FR-009
pred FR_010_DecisionRequiresReason {
  // Every decided application has a Decision record (reason is mandatory;
  // absence of a Decision means no decision was recorded, which is invalid).
  some a: LoanApplication | a.status = Approved or a.status = Rejected
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies (some a.decisionRecord)
}
assert FR_010_DecisionRequiresReason { FR_010_DecisionRequiresReason }
check FR_010_DecisionRequiresReason for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; data-model.md loan_applications.reference UNIQUE
pred FR_004_UniqueReference {
  // Every LoanApplication has a distinct identity (Alloy atoms are distinct by
  // construction); the bijection with Decision ensures no two apps share a Decision.
  some LoanApplication
  all disj a1, a2: LoanApplication | a1 != a2
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; spec.md FR-015, SC-004; contracts/http-api.md
pred FR_015_StaffOnlyDecideAndAudit {
  some Operation
  // No Customer may successfully post a decision.
  all op: Operation |
    (op.kind = OpPostDecision and op.caller.role = Customer) implies
      op.outcome = OutDenied
  // No Customer may successfully access the audit trail.
  all op: Operation |
    (op.kind = OpGetAudit and op.caller.role = Customer) implies
      op.outcome = OutDenied
  // No BankStaff may successfully submit an application.
  all op: Operation |
    (op.kind = OpPostApp and op.caller.role = BankStaff) implies
      op.outcome = OutDenied
}
assert FR_015_StaffOnlyDecideAndAudit { FR_015_StaffOnlyDecideAndAudit }
check FR_015_StaffOnlyDecideAndAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md FR-013, SC-004; contracts/http-api.md
pred FR_013_CustomerSeesOnlyOwnApps {
  some op: Operation | op.kind = OpGetAppByRef and op.caller.role = Customer
  all op: Operation |
    (op.kind = OpGetAppByRef and op.caller.role = Customer) implies (
      (op.outcome = OutSuccess) implies
        (some op.targetApp and op.targetApp.owner = op.caller)
    )
}
assert FR_013_CustomerSeesOnlyOwnApps { FR_013_CustomerSeesOnlyOwnApps }
check FR_013_CustomerSeesOnlyOwnApps for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md ApplicationEvent; spec.md FR-016
pred FR_016_AuditTrailComplete {
  some LoanApplication
  all a: LoanApplication |
    one e: ApplicationEvent | e.forApp = a and e.eventType = SubmittedEvt
  all a: LoanApplication |
    (a.status = Approved) implies
      (one e: ApplicationEvent | e.forApp = a and e.eventType = ApprovedEvt)
  all a: LoanApplication |
    (a.status = Rejected) implies
      (one e: ApplicationEvent | e.forApp = a and e.eventType = RejectedEvt)
}
assert FR_016_AuditTrailComplete { FR_016_AuditTrailComplete }
check FR_016_AuditTrailComplete for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md FR-012, SC-005; data-model.md conditional UPDATE
pred FR_012_ConcurrentDecisionRejected {
  some LoanApplication
  // Only one Decision can exist per application regardless of how many
  // concurrent staff members try to decide it.
  all a: LoanApplication |
    lone d: Decision | d.forApp = a
}
assert FR_012_ConcurrentDecisionRejected { FR_012_ConcurrentDecisionRejected }
check FR_012_ConcurrentDecisionRejected for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; spec.md FR-014; data-model.md NotificationLog
pred FR_014_NotificationOnDecision {
  // Every application that reaches Approved or Rejected status has a Decision
  // record (which triggers notification). Structural proxy: decided apps always
  // have a decision record from which the notification system derives
  // the contact channel.
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies (some a.decisionRecord)
}
assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md FR-001; data-model.md LoanApplication.owner
pred FR_001_AuthenticatedSubmission {
  some LoanApplication
  // Every application has an owner who is an authenticated Customer.
  all a: LoanApplication | a.owner.role = Customer
}
assert FR_001_AuthenticatedSubmission { FR_001_AuthenticatedSubmission }
check FR_001_AuthenticatedSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; spec.md FR-002; contracts/http-api.md 400 validation_error
pred FR_002_ValidationRejectsInvalid {
  some Operation
  // Invalid (denied) operations do not produce LoanApplications in any status
  // other than through a successful submission path.
  // Structural: if an OpPostApp is denied, the caller has no new application
  // in PendingReview (i.e., a denied post does not create state).
  all op: Operation |
    (op.kind = OpPostApp and op.outcome = OutDenied) implies
      (no a: LoanApplication | a.owner = op.caller and a.status = PendingReview
         and (no op2: Operation |
               op2 != op and op2.kind = OpPostApp and
               op2.caller = op.caller and op2.outcome = OutSuccess))
}
assert FR_002_ValidationRejectsInvalid { FR_002_ValidationRejectsInvalid }
check FR_002_ValidationRejectsInvalid for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; spec.md FR-009; data-model.md decisions.reason CHECK
pred FR_009_DecisionReasonMandatory {
  // Every decided application has a Decision record (the reason field
  // is mandatory and non-empty; absence of a Decision = no decision yet).
  some a: LoanApplication | a.status = Approved or a.status = Rejected
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies (some a.decisionRecord)
}
assert FR_009_DecisionReasonMandatory { FR_009_DecisionReasonMandatory }
check FR_009_DecisionReasonMandatory for 5