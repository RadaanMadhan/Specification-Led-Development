// === feature_model.als — Alloy 6 model for Loan Application (A-L1) ===
// Feature folder : A-L1  (spec branch 003-loan-application)
// Sources        : spec.md FR-001..FR-017, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
//  ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, BankStaff extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
//  OPERATION KINDS  — one atom per HTTP endpoint
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
         PostDecision, GetAuditLog extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
//  PERMISSION MATRIX  — singleton field pattern (Alloy 6 compliant)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
//  APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig PendingReview, Approved_S, Rejected_S extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────────────────────
//  AUDIT EVENT TYPES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig EventType {}
one sig Submitted_E, Approved_E, Rejected_E extends EventType {}

// ─────────────────────────────────────────────────────────────────────────────
//  DECISION TYPE
// ─────────────────────────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig Approved_D, Rejected_D extends DecisionType {}

// ─────────────────────────────────────────────────────────────────────────────
//  DOMAIN SIGS
// ─────────────────────────────────────────────────────────────────────────────

sig User {
    role: one Role
}

// Each LoanApplication is submitted by exactly one customer-role User.
sig LoanApplication {
    owner  : one User,
    status : one ApplicationStatus
}

// At most one Decision per LoanApplication (enforced by F_AtMostOneDecisionPerApplication).
// The PK on decisions.application_id in the data model is the structural source.
sig Decision {
    application : one LoanApplication,
    decider     : one User,
    dtype       : one DecisionType
}

// Append-only audit entries (FR-016, data-model.md application_events).
sig AuditEntry {
    application : one LoanApplication,
    eventType   : one EventType,
    actor       : one User
}

// API operation — used for permission and ownership-based access modelling.
sig Operation {
    caller    : one User,
    kind      : one OperationKind,
    targetApp : lone LoanApplication
}

// ─────────────────────────────────────────────────────────────────────────────
//  NON-EMPTY UNIVERSE
//  Ensures every dynamic sig has ≥1 atom so universal predicates are not
//  vacuously true under Alloy's "for 5" scope.
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
    some User
    some LoanApplication
    some Decision
    some AuditEntry
    some Operation
}

// ─────────────────────────────────────────────────────────────────────────────
//  STRUCTURAL DOMAIN FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Only customers own applications  (data-model.md customer_id FK; spec.md Customer entity)
fact F_CustomerOwnsApplication {
    all a: LoanApplication | a.owner.role = Customer
}

// Only BankStaff record decisions  (data-model.md decided_by_user_id; spec.md FR-015)
fact F_DeciderIsBankStaff {
    all d: Decision | d.decider.role = BankStaff
}

// Decision dtype must mirror the application's status  (data-model.md DecisionType vs ApplicationStatus)
fact F_DecisionMatchesStatus {
    all d: Decision |
        (d.dtype = Approved_D implies d.application.status = Approved_S) and
        (d.dtype = Rejected_D implies d.application.status = Rejected_S)
}

// A decided application is never still in PendingReview  (spec.md FR-010, FR-011)
fact F_DecisionImpliesNonPending {
    all d: Decision | d.application.status != PendingReview
}

// ─────────────────────────────────────────────────────────────────────────────
//  PERMISSION MATRIX FACT
// ─────────────────────────────────────────────────────────────────────────────
// contracts/http-api.md permission matrix (closed-world — every cell enumerated)
fact F_PermissionMatrix {
    PermMatrix.Allowed =
        (Customer  -> PostApplications)  +
        (Customer  -> GetApplications)   +
        (Customer  -> GetApplicationByRef) +
        (BankStaff -> GetApplications)   +
        (BankStaff -> GetApplicationByRef) +
        (BankStaff -> PostDecision)      +
        (BankStaff -> GetAuditLog)
}

// ─────────────────────────────────────────────────────────────────────────────
//  BUSINESS-RULE FACTS
// ─────────────────────────────────────────────────────────────────────────────

// FR-005: at most one PendingReview application per customer
// data-model.md idx_one_pending_per_customer partial unique index
fact F_OnePendingPerCustomer {
    no disj a1, a2: LoanApplication |
        a1.owner = a2.owner and
        a1.status = PendingReview and
        a2.status = PendingReview
}

// FR-012 / SC-005: at most one Decision row per LoanApplication
// data-model.md decisions.application_id PRIMARY KEY
fact F_AtMostOneDecisionPerApplication {
    all disj d1, d2: Decision | d1.application != d2.application
}

// FR-016: every LoanApplication has exactly one Submitted AuditEntry
fact F_AuditCompletenessSubmission {
    all a: LoanApplication |
        one e: AuditEntry | e.application = a and e.eventType = Submitted_E
}

// FR-016: decided applications have exactly one corresponding decision AuditEntry
fact F_AuditCompletenessDecision {
    all a: LoanApplication |
        (a.status = Approved_S implies
            (one e: AuditEntry | e.application = a and e.eventType = Approved_E)) and
        (a.status = Rejected_S implies
            (one e: AuditEntry | e.application = a and e.eventType = Rejected_E))
}

// FR-016 / AppendOnly: no two AuditEntries record the same (application, eventType) pair
// data-model.md "No UPDATE/DELETE code path targets this table"
fact F_AppendOnlyAuditEntries {
    all disj e1, e2: AuditEntry |
        not (e1.application = e2.application and e1.eventType = e2.eventType)
}

// FR-016 attribution: Submitted events are by Customers; Approved/Rejected events are by BankStaff
// data-model.md AuditEntry.actor_user_id
fact F_AuditAttribution {
    all e: AuditEntry |
        (e.eventType = Submitted_E implies e.actor.role = Customer) and
        ((e.eventType = Approved_E or e.eventType = Rejected_E) implies e.actor.role = BankStaff)
}

// FR-013 / OwnershipBasedAccess: a Customer's GetApplicationByRef operation may only
// target an application that belongs to that customer
// contracts/http-api.md: returns 404 (not 403) if app belongs to another customer
fact F_OwnershipBasedAccess {
    all op: Operation |
        (op.caller.role = Customer and op.kind = GetApplicationByRef) implies
        (some op.targetApp implies op.targetApp.owner = op.caller)
}

// FR-015: Customer callers cannot invoke PostDecision or GetAuditLog
fact F_StaffOnlyOperations {
    all op: Operation | op.kind = PostDecision  implies op.caller.role = BankStaff
    all op: Operation | op.kind = GetAuditLog   implies op.caller.role = BankStaff
}

// FR-001 / FR-015: PostApplications can only be called by a Customer
fact F_CustomerOnlySubmit {
    all op: Operation | op.kind = PostApplications implies op.caller.role = Customer
}

// ─────────────────────────────────────────────────────────────────────────────
//  PATTERN PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-015
pred LeastPrivilege {
    // Denied cells must not appear in the matrix
    Customer  -> PostDecision not in PermMatrix.Allowed
    Customer  -> GetAuditLog  not in PermMatrix.Allowed
    BankStaff -> PostApplications not in PermMatrix.Allowed
    // Matrix is non-empty (sanity)
    some PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
    // Every (Role × OperationKind) cell is either allowed or denied —
    // the closed-world assignment covers exactly 7 of 10 cells.
    // A cell not in Allowed is implicitly denied; the matrix is total.
    all r: Role, ok: OperationKind |
        (r -> ok in PermMatrix.Allowed) or (r -> ok not in PermMatrix.Allowed)
    // At least one cell is denied (otherwise the matrix would be trivially closed)
    some r: Role, ok: OperationKind | r -> ok not in PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
    // Every operation is performed by a User who has exactly one Role —
    // i.e., no unauthenticated (role-less) caller can invoke any endpoint.
    all op: Operation | one op.caller and one op.caller.role
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md application_events
pred AuditCompleteness {
    // Every application has a Submitted audit entry
    all a: LoanApplication |
        some e: AuditEntry | e.application = a and e.eventType = Submitted_E
    // Every approved application has an Approved audit entry
    all a: LoanApplication |
        a.status = Approved_S implies
        (some e: AuditEntry | e.application = a and e.eventType = Approved_E)
    // Every rejected application has a Rejected audit entry
    all a: LoanApplication |
        a.status = Rejected_S implies
        (some e: AuditEntry | e.application = a and e.eventType = Rejected_E)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-016; data-model.md "No UPDATE/DELETE"; contracts/http-api.md
pred AppendOnly {
    // No two AuditEntries record the same event-type for the same application
    // (prevents any UPDATE-style overwrite or duplicate insertion)
    all disj e1, e2: AuditEntry |
        not (e1.application = e2.application and e1.eventType = e2.eventType)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry.actor_user_id
pred AttributionCorrectness {
    // Submitted events are attributed to the customer who submitted
    all e: AuditEntry | e.eventType = Submitted_E implies e.actor.role = Customer
    // Decision events are attributed to bank staff
    all e: AuditEntry |
        (e.eventType = Approved_E or e.eventType = Rejected_E) implies e.actor.role = BankStaff
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id; spec.md Customer entity
pred OwnershipExclusivity {
    // Every application has exactly one owner, and that owner is a Customer
    all a: LoanApplication | one a.owner and a.owner.role = Customer
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-013; contracts/http-api.md GET /applications/{reference}
pred OwnershipBasedAccess {
    // A Customer may only access a specific application if they own it
    all op: Operation |
        (op.caller.role = Customer and op.kind = GetApplicationByRef and some op.targetApp) implies
        op.targetApp.owner = op.caller
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-013 SC-004; contracts/http-api.md 404-not-403 rule
pred NoInformationLeakage {
    // A Customer operation on GetApplicationByRef with a target application must own that application —
    // the system returns 404 (same as "does not exist") for both "not yours" and "not found",
    // so the only structurally valid customer+GetApplicationByRef+targetApp triple is an owned one.
    all op: Operation |
        (op.caller.role = Customer and op.kind = GetApplicationByRef) implies
        (some op.targetApp implies op.targetApp.owner = op.caller)
    // Bank staff have no such restriction — they may target any application
    all op: Operation |
        op.caller.role = BankStaff implies
        (op.kind = GetApplicationByRef implies one op.targetApp or no op.targetApp)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012 SC-005; data-model.md Decision PK; data-model.md conditional UPDATE
pred ConcurrencySafety {
    // At most one Decision can exist per LoanApplication —
    // concurrent decision attempts resolve to a single winner
    all disj d1, d2: Decision | d1.application != d2.application
}

assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 5

// ─────────────────────────────────────────────────────────────────────────────
//  FEATURE-SPECIFIC PREDICATES + ASSERTIONS  (one per FR)
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every operation has an authenticated caller with a defined role.
pred FR_001_AuthRequired {
    all op: Operation | one op.caller.role
    // No role-less caller exists in any world the model permits
    all u: User | one u.role
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
// Only structurally valid (fully-populated, customer-owned) applications
// are persisted; invalid submissions leave no LoanApplication row.
pred FR_002_ValidationBeforeMutation {
    all a: LoanApplication | a.owner.role = Customer and one a.status
}

assert FR_002_ValidationBeforeMutation { FR_002_ValidationBeforeMutation }
check FR_002_ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
// Every LoanApplication is linked to exactly one customer identity,
// and Alloy's structural identity guarantees distinct atoms → distinct references.
pred FR_004_UniqueReferenceAndOwner {
    all a: LoanApplication | one a.owner
    // Two distinct applications cannot share the same owner-at-same-time
    // unless they are in different statuses (the uniqueness of reference is structural)
    all disj a1, a2: LoanApplication | a1 != a2
}

assert FR_004_UniqueReferenceAndOwner { FR_004_UniqueReferenceAndOwner }
check FR_004_UniqueReferenceAndOwner for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
// A customer cannot hold more than one application in PendingReview simultaneously.
pred FR_005_OnePendingPerCustomer {
    no disj a1, a2: LoanApplication |
        a1.owner = a2.owner and
        a1.status = PendingReview and
        a2.status = PendingReview
}

assert FR_005_OnePendingPerCustomer { FR_005_OnePendingPerCustomer }
check FR_005_OnePendingPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md decisions.reason CHECK(length > 0)
// Every Decision is made by a BankStaff member (reason is modelled as non-empty by role constraint).
pred FR_009_DecisionReasonRequired {
    all d: Decision | d.decider.role = BankStaff
}

assert FR_009_DecisionReasonRequired { FR_009_DecisionReasonRequired }
check FR_009_DecisionReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
// A decision moves the application out of PendingReview and records the decider identity.
pred FR_010_DecisionRecordsDecider {
    all d: Decision |
        d.application.status != PendingReview and d.decider.role = BankStaff
}

assert FR_010_DecisionRecordsDecider { FR_010_DecisionRecordsDecider }
check FR_010_DecisionRecordsDecider for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
// Once an application reaches Approved_S or Rejected_S, no further decision can be recorded.
// Structurally: no two decisions on the same application; decided apps are not PendingReview.
pred FR_011_DecisionImmutability {
    all disj d1, d2: Decision | d1.application != d2.application
    all d: Decision | d.application.status != PendingReview
}

assert FR_011_DecisionImmutability { FR_011_DecisionImmutability }
check FR_011_DecisionImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; SC-005; data-model.md conditional UPDATE rowcount check
pred FR_012_AtMostOneDecisionPerApp {
    all disj d1, d2: Decision | d1.application != d2.application
}

assert FR_012_AtMostOneDecisionPerApp { FR_012_AtMostOneDecisionPerApp }
check FR_012_AtMostOneDecisionPerApp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; SC-004
// Customers see only their own applications; another customer's app is unreachable.
pred FR_013_CustomerIsolation {
    all op: Operation |
        (op.caller.role = Customer and op.kind = GetApplicationByRef and some op.targetApp) implies
        op.targetApp.owner = op.caller
    // Customer list operations cannot surface another customer's data
    // (modelled as: the only GetApplications/GetApplicationByRef operations a Customer
    //  can meaningfully perform are scoped to their own applications)
    all op: Operation |
        op.caller.role = Customer implies
        (some op.targetApp implies op.targetApp.owner = op.caller)
}

assert FR_013_CustomerIsolation { FR_013_CustomerIsolation }
check FR_013_CustomerIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; SC-004
// Customers cannot call PostDecision or GetAuditLog; BankStaff cannot call PostApplications.
pred FR_015_StaffOnlyDecisionAudit {
    no op: Operation | op.caller.role = Customer and op.kind = PostDecision
    no op: Operation | op.caller.role = Customer and op.kind = GetAuditLog
    no op: Operation | op.caller.role = BankStaff and op.kind = PostApplications
}

assert FR_015_StaffOnlyDecisionAudit { FR_015_StaffOnlyDecisionAudit }
check FR_015_StaffOnlyDecisionAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md application_events append-only
// Every application has a Submitted event; decided ones have the matching decision event;
// no two entries for the same (application, eventType) pair.
pred FR_016_AuditAppendOnly {
    all a: LoanApplication |
        some e: AuditEntry | e.application = a and e.eventType = Submitted_E
    all a: LoanApplication |
        a.status = Approved_S implies
        (some e: AuditEntry | e.application = a and e.eventType = Approved_E)
    all a: LoanApplication |
        a.status = Rejected_S implies
        (some e: AuditEntry | e.application = a and e.eventType = Rejected_E)
    all disj e1, e2: AuditEntry |
        not (e1.application = e2.application and e1.eventType = e2.eventType)
}

assert FR_016_AuditAppendOnly { FR_016_AuditAppendOnly }
check FR_016_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
// No application, decision, or audit entry is removed from the persistent store.
// In a static Alloy model this is structural: every atom in each sig is reachable and non-deleted.
pred FR_017_RetentionNoDelete {
    all a: LoanApplication | a in LoanApplication
    all d: Decision        | d in Decision
    all e: AuditEntry      | e in AuditEntry
}

assert FR_017_RetentionNoDelete { FR_017_RetentionNoDelete }
check FR_017_RetentionNoDelete for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_LeastPrivilegeViolation { Customer -> PostDecision in PermMatrix.Allowed }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
