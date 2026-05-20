// === feature_model.als — Alloy model for 003-loan-application ===
// Self-contained Alloy 6 model encoding the structural invariants of the
// Loan Application feature (spec.md FR-001..FR-017, data-model.md entities,
// contracts/http-api.md permission matrix).

// ---------- Roles & Operations (permission matrix domain) ----------

abstract sig Role {}
one sig CustomerRole, BankStaffRole extends Role {}

abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationById,
        PostDecision, GetAudit extends OperationKind {}

// Permission matrix as a singleton-sig field (Alloy 6 idiom).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Booleans ----------

abstract sig Bool {}
one sig True, False extends Bool {}

// ---------- Status / Event / Decision enums ----------

abstract sig ApplicationStatus {}
one sig PendingReview, ApprovedStatus, RejectedStatus extends ApplicationStatus {}

abstract sig EventType {}
one sig EventSubmitted, EventApproved, EventRejected extends EventType {}

abstract sig DecisionType {}
one sig DecisionApproved, DecisionRejected extends DecisionType {}

// ---------- Users ----------

abstract sig User { role: one Role }
sig Customer extends User {}
sig BankStaff extends User {}

// ---------- Domain entities (from data-model.md) ----------

sig Reference {}
sig Reason {}

sig LoanApplication {
  customer:  one Customer,
  status:    one ApplicationStatus,
  reference: one Reference
}

sig Decision {
  application:  one LoanApplication,
  decisionType: one DecisionType,
  reason:       one Reason,
  decidedBy:    one BankStaff
}

sig ApplicationEvent {
  app:       one LoanApplication,
  eventType: one EventType,
  actor:     one User
}

// ---------- Operations (HTTP request envelope) ----------

sig Operation {
  caller:        one User,
  kind:          one OperationKind,
  target:        lone LoanApplication,
  authenticated: one Bool,
  validated:     one Bool,
  succeeded:     one Bool
}

// ---------- Non-empty universe (single named fact, no inline witnesses) ----------

fact F_NonEmptyUniverse {
  some Customer
  some BankStaff
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
  some Reference
  some Reason
}

// ==========================================================================
// FACTS (named so they can be mutation-tested)
// ==========================================================================

// Subtype <-> role tag consistency.
fact F_UserRoles {
  all c: Customer  | c.role = CustomerRole
  all s: BankStaff | s.role = BankStaffRole
}

// Permission matrix exactly as defined in contracts/http-api.md.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (CustomerRole  -> PostApplications)
    + (CustomerRole  -> GetApplications)
    + (CustomerRole  -> GetApplicationById)
    + (BankStaffRole -> GetApplications)
    + (BankStaffRole -> GetApplicationById)
    + (BankStaffRole -> PostDecision)
    + (BankStaffRole -> GetAudit)
}

// FR-004: every application reference is unique.
fact F_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

// FR-005: at most one Pending Review application per customer.
fact F_OnePendingPerCustomer {
  all c: Customer |
    lone a: LoanApplication | a.customer = c and a.status = PendingReview
}

// FR-011 / FR-012 / SC-005: at most one Decision per application.
fact F_OneDecisionPerApplication {
  all a: LoanApplication |
    lone d: Decision | d.application = a
}

// Status <-> Decision consistency (FR-010): non-pending iff a decision exists,
// and decision_type mirrors final status.
fact F_DecisionConsistency {
  all a: LoanApplication |
    (a.status != PendingReview) iff (some d: Decision | d.application = a)
  all d: Decision |
    (d.decisionType = DecisionApproved) iff (d.application.status = ApprovedStatus)
  all d: Decision |
    (d.decisionType = DecisionRejected) iff (d.application.status = RejectedStatus)
}

// FR-016: every application has at least one Submitted event, and each
// decided application has at least one matching decision event.
fact F_AuditCompleteness {
  all a: LoanApplication |
    some e: ApplicationEvent | e.app = a and e.eventType = EventSubmitted
  all a: LoanApplication |
    a.status = ApprovedStatus
      implies (some e: ApplicationEvent | e.app = a and e.eventType = EventApproved)
  all a: LoanApplication |
    a.status = RejectedStatus
      implies (some e: ApplicationEvent | e.app = a and e.eventType = EventRejected)
  all a: LoanApplication |
    a.status = PendingReview
      implies (no e: ApplicationEvent |
                  e.app = a and (e.eventType = EventApproved or e.eventType = EventRejected))
}

// FR-016 audit attribution: submitted by the customer; decision events by
// the staff member who recorded the decision.
fact F_AuditAttribution { /* MUTATED — body cleared by validator */ }

// FR-016 append-only: no two distinct events share (application, eventType).
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: ApplicationEvent |
    not (e1.app = e2.app and e1.eventType = e2.eventType)
}

// Authentication required (contracts/http-api.md "Authentication (all endpoints)").
fact F_AuthRequired {
  all op: Operation | op.succeeded = True implies op.authenticated = True
}

// FR-002: validation gates state-changing success.
fact F_ValidationGate {
  all op: Operation | op.succeeded = True implies op.validated = True
}

// FR-015 + permission matrix: a successful op must be allowed by the matrix.
fact F_LeastPrivilege {
  all op: Operation |
    op.succeeded = True
      implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}

// FR-013: a customer's successful GetApplicationById must target an app they own.
fact F_OwnershipForGet {
  all op: Operation |
    (op.caller in Customer and op.kind = GetApplicationById and op.succeeded = True)
      implies (some op.target and op.target.customer = op.caller)
}

// FR-001: a successful submission attaches the application to its caller.
fact F_SubmitOwnership {
  all op: Operation |
    (op.kind = PostApplications and op.succeeded = True)
      implies (some op.target and op.target.customer = op.caller)
}

// ==========================================================================
// PATTERN PREDICATES + ASSERTIONS
// ==========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
  all op: Operation |
    op.succeeded = True
      implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Every role has at least one allowed operation.
  all r: Role | some k: OperationKind | (r -> k) in PermMatrix.Allowed
  // And at least one denied cell exists (matrix actually discriminates).
  some r: Role, k: OperationKind | (r -> k) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-001/007/008/009/013/015/016
pred PermissionGrounding {
  // Allows that must trace to an FR:
  (CustomerRole  -> PostApplications)    in PermMatrix.Allowed   // FR-001
  (CustomerRole  -> GetApplicationById)  in PermMatrix.Allowed   // FR-013
  (BankStaffRole -> GetApplications)     in PermMatrix.Allowed   // FR-007
  (BankStaffRole -> PostDecision)        in PermMatrix.Allowed   // FR-009/FR-015
  (BankStaffRole -> GetAudit)            in PermMatrix.Allowed   // FR-016
  // Denies mandated by FR-015:
  (CustomerRole  -> PostDecision)        not in PermMatrix.Allowed
  (CustomerRole  -> GetAudit)            not in PermMatrix.Allowed
  (BankStaffRole -> PostApplications)    not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.succeeded = True implies op.authenticated = True
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    some e: ApplicationEvent | e.app = a and e.eventType = EventSubmitted
  all a: LoanApplication |
    a.status = ApprovedStatus
      implies (some e: ApplicationEvent | e.app = a and e.eventType = EventApproved)
  all a: LoanApplication |
    a.status = RejectedStatus
      implies (some e: ApplicationEvent | e.app = a and e.eventType = EventRejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "append-only at code layer"
pred AppendOnly {
  some ApplicationEvent
  all disj e1, e2: ApplicationEvent |
    not (e1.app = e2.app and e1.eventType = e2.eventType)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md application_events.actor
pred AttributionCorrectness {
  all e: ApplicationEvent |
    e.eventType = EventSubmitted implies e.actor = e.app.customer
  all e: ApplicationEvent |
    e.eventType = EventApproved  implies e.actor in BankStaff
  all e: ApplicationEvent |
    e.eventType = EventRejected  implies e.actor in BankStaff
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id NOT NULL
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GET /applications/{ref}
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller in Customer and op.kind = GetApplicationById and op.succeeded = True)
      implies (some op.target and op.target.customer = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013; contracts/http-api.md "404 not_found" for non-owner
pred NoInformationLeakage {
  // A customer asking about an application they do not own cannot succeed
  // (same outcome as a non-existent reference — no existence leak).
  all op: Operation |
    (op.caller in Customer
     and op.kind = GetApplicationById
     and some op.target
     and op.target.customer != op.caller)
      implies op.succeeded = False
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-002; data-model.md validation.py
pred ValidationBeforeMutation {
  some Operation
  all op: Operation | op.succeeded = True implies op.validated = True
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-005
pred ConcurrencySafety {
  all a: LoanApplication |
    lone d: Decision | d.application = a
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ==========================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// ==========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_CustomerSubmits {
  (CustomerRole -> PostApplications) in PermMatrix.Allowed
  all op: Operation |
    (op.kind = PostApplications and op.succeeded = True)
      implies op.caller in Customer
}
assert FR_001_CustomerSubmits { FR_001_CustomerSubmits }
check FR_001_CustomerSubmits for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_ValidationRejection {
  all op: Operation |
    (op.kind in (PostApplications + PostDecision) and op.validated = False)
      implies op.succeeded = False
}
assert FR_002_ValidationRejection { FR_002_ValidationRejection }
check FR_002_ValidationRejection for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (amount range + term set; structurally bound by validated flag)
pred FR_003_RangeAndTermValidated {
  all op: Operation |
    (op.kind = PostApplications and op.succeeded = True)
      implies op.validated = True
}
assert FR_003_RangeAndTermValidated { FR_003_RangeAndTermValidated }
check FR_003_RangeAndTermValidated for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}
assert FR_004_UniqueReference { FR_004_UniqueReference }
check FR_004_UniqueReference for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_OnePendingPerCustomer {
  all c: Customer |
    lone a: LoanApplication | a.customer = c and a.status = PendingReview
}
assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (confirmation on submit = successful submit yields PendingReview app)
pred FR_006_SubmissionConfirmation {
  all op: Operation |
    (op.kind = PostApplications and op.succeeded = True)
      implies (some op.target and op.target.status = PendingReview)
}
assert FR_006_SubmissionConfirmation { FR_006_SubmissionConfirmation }
check FR_006_SubmissionConfirmation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_StaffQueueAccess {
  (BankStaffRole -> GetApplications) in PermMatrix.Allowed
  (CustomerRole  -> PostApplications) in PermMatrix.Allowed  // ensures matrix has both axes populated
}
assert FR_007_StaffQueueAccess { FR_007_StaffQueueAccess }
check FR_007_StaffQueueAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_StaffViewsAny {
  (BankStaffRole -> GetApplicationById) in PermMatrix.Allowed
  all op: Operation |
    (op.caller in BankStaff and op.kind = GetApplicationById and op.succeeded = True)
      implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert FR_008_StaffViewsAny { FR_008_StaffViewsAny }
check FR_008_StaffViewsAny for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ReasonRequired {
  all d: Decision | one d.reason
  some Decision
}
assert FR_009_ReasonRequired { FR_009_ReasonRequired }
check FR_009_ReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_DecisionPersisted {
  all a: LoanApplication |
    a.status = ApprovedStatus
      implies (one d: Decision | d.application = a and d.decisionType = DecisionApproved)
  all a: LoanApplication |
    a.status = RejectedStatus
      implies (one d: Decision | d.application = a and d.decisionType = DecisionRejected)
}
assert FR_010_DecisionPersisted { FR_010_DecisionPersisted }
check FR_010_DecisionPersisted for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSecondDecision {
  all a: LoanApplication |
    lone d: Decision | d.application = a
}
assert FR_011_NoSecondDecision { FR_011_NoSecondDecision }
check FR_011_NoSecondDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_ConcurrentDecisionSafe {
  all a: LoanApplication |
    lone d: Decision | d.application = a
}
assert FR_012_ConcurrentDecisionSafe { FR_012_ConcurrentDecisionSafe }
check FR_012_ConcurrentDecisionSafe for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_CustomerSeesOwnOnly {
  all op: Operation |
    (op.caller in Customer and op.kind = GetApplicationById and op.succeeded = True)
      implies (some op.target and op.target.customer = op.caller)
}
assert FR_013_CustomerSeesOwnOnly { FR_013_CustomerSeesOwnOnly }
check FR_013_CustomerSeesOwnOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (decided applications produce a decision event = notification trigger)
pred FR_014_NotificationOnDecision {
  all a: LoanApplication |
    a.status != PendingReview
      implies (some e: ApplicationEvent |
                  e.app = a and e.eventType in (EventApproved + EventRejected))
}
assert FR_014_NotificationOnDecision { FR_014_NotificationOnDecision }
check FR_014_NotificationOnDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_CustomersCantDecideOrAudit {
  (CustomerRole -> PostDecision) not in PermMatrix.Allowed
  (CustomerRole -> GetAudit)     not in PermMatrix.Allowed
  all op: Operation |
    (op.kind in (PostDecision + GetAudit) and op.succeeded = True)
      implies op.caller in BankStaff
}
assert FR_015_CustomersCantDecideOrAudit { FR_015_CustomersCantDecideOrAudit }
check FR_015_CustomersCantDecideOrAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditTrail {
  all a: LoanApplication |
    some e: ApplicationEvent | e.app = a and e.eventType = EventSubmitted
  all e: ApplicationEvent |
    e.eventType in (EventSubmitted + EventApproved + EventRejected)
}
assert FR_016_AuditTrail { FR_016_AuditTrail }
check FR_016_AuditTrail for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 (retention — events persist; no deletion path)
pred FR_017_Retention {
  all a: LoanApplication |
    some e: ApplicationEvent | e.app = a
}
assert FR_017_Retention { FR_017_Retention }
check FR_017_Retention for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_WrongAttribution { some e: ApplicationEvent | e.eventType = EventApproved and e.actor in Customer }
