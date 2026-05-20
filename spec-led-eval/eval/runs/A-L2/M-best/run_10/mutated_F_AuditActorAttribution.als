// === feature_model.als — Alloy 6 model for Loan Application with RBAC + Audit Trail ===
// Feature: 004-loan-application-rbac
// Self-contained: no imports.

// ---------- Roles ----------
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ---------- Operation kinds (the six endpoints in contracts/http-api.md) ----------
abstract sig OperationKind {}
one sig SubmitApp, ListApps, GetApp, ClaimApp, DecideApp, ViewAudit extends OperationKind {}

// ---------- Permission matrix (singleton-sig field) ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Application status enum ----------
abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

// ---------- Bool ----------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Users ----------
sig User { role: one Role }

// ---------- Loan applications ----------
sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User
}

// ---------- Decision ----------
sig Decision {
  application: one LoanApplication,
  decisionType: one Status,
  decidedBy: one User,
  hasReason: one Bool
}

// ---------- Audit entries (application_events) ----------
sig AuditEntry {
  app: one LoanApplication,
  actor: one User,
  prevStatus: lone Status,
  newStatus: one Status
}

// ---------- Operations (attempted requests) ----------
sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication,
  authenticated: one Bool,
  succeeded: one Bool
}

// =========================================================================
// NON-EMPTY UNIVERSE
// =========================================================================
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// =========================================================================
// PERMISSION MATRIX (closed-world; from contracts/http-api.md)
// =========================================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer -> SubmitApp) +
    (Customer -> ListApps) +
    (Customer -> GetApp) +
    (LoanOfficer -> ListApps) +
    (LoanOfficer -> GetApp) +
    (LoanOfficer -> ClaimApp) +
    (LoanOfficer -> DecideApp) +
    (LoanOfficer -> ViewAudit) +
    (ComplianceReviewer -> ListApps) +
    (ComplianceReviewer -> GetApp) +
    (ComplianceReviewer -> ViewAudit)
}

// =========================================================================
// STRUCTURAL DATA-MODEL FACTS
// =========================================================================

fact F_AppCustomerHasCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

fact F_AssignedOfficerHasOfficerRole {
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

fact F_StatusOfficerCoupling {
  // data-model.md CHECK ((status='Submitted') = (assigned_officer_id IS NULL))
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

fact F_DecisionExistsIffDecided {
  all d: Decision | d.application.status in (Approved + Rejected)
  all d: Decision | d.decisionType = d.application.status
  all a: LoanApplication |
    a.status in (Approved + Rejected) iff (some d: Decision | d.application = a)
}

fact F_AtMostOneDecisionPerApp {
  // PK on decisions.application_id
  all a: LoanApplication | (lone d: Decision | d.application = a)
}

fact F_DecisionByAssignedOfficer {
  all d: Decision | d.decidedBy = d.application.assignedOfficer
}

fact F_DecisionReasonRequired {
  all d: Decision | d.hasReason = BTrue
}

fact F_AuditPrevNewDistinct {
  all e: AuditEntry | some e.prevStatus implies e.prevStatus != e.newStatus
}

fact F_AuditInitialIsSubmitted {
  all e: AuditEntry | (no e.prevStatus) iff (e.newStatus = Submitted)
}

fact F_AuditValidTransitions {
  all e: AuditEntry | e.newStatus = UnderReview implies e.prevStatus = Submitted
  all e: AuditEntry | e.newStatus in (Approved + Rejected) implies e.prevStatus = UnderReview
}

fact F_AuditCompleteness {
  // FR-017: every status change produces an audit entry.
  all a: LoanApplication | (some e: AuditEntry | e.app = a and no e.prevStatus)
  all a: LoanApplication | a.status != Submitted implies
    (some e: AuditEntry | e.app = a and e.newStatus = UnderReview)
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (some e: AuditEntry | e.app = a and e.newStatus = a.status)
}

fact F_AuditNoDuplicates {
  // FR-018 / FR-019: append-only, exactly one entry per (app, transition).
  all a: LoanApplication, s: Status |
    (lone e: AuditEntry | e.app = a and e.newStatus = s)
}

fact F_AuditNoSpuriousEntries {
  // Each entry corresponds to a transition that actually applied.
  all e: AuditEntry | e.newStatus = UnderReview implies e.app.status != Submitted
  all e: AuditEntry | e.newStatus = Approved implies e.app.status = Approved
  all e: AuditEntry | e.newStatus = Rejected implies e.app.status = Rejected
}

fact F_AuditActorAttribution { /* MUTATED — body cleared by validator */ }

fact F_OneInFlightPerCustomer {
  // FR-008: idx_one_in_flight_per_customer partial unique index.
  all u: User | u.role = Customer implies
    (lone a: LoanApplication | a.customer = u and a.status in (Submitted + UnderReview))
}

// =========================================================================
// OPERATION / RUNTIME FACTS
// =========================================================================

fact F_AuthBeforeBusiness {
  all op: Operation | op.succeeded = BTrue implies op.authenticated = BTrue
}

fact F_PermissionsEnforced {
  all op: Operation | op.succeeded = BTrue implies
    op.caller.role -> op.kind in PermMatrix.Allowed
}

fact F_OperationTargetShape {
  all op: Operation |
    op.kind in (GetApp + ClaimApp + DecideApp + ViewAudit) implies some op.target
  all op: Operation |
    op.kind in (SubmitApp + ListApps) implies no op.target
}

fact F_CustomerSeesOwnOnly {
  // FR-020: customer GetApp succeeds only on their own application.
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = Customer and op.kind = GetApp)
      implies op.target.customer = op.caller
}

fact F_OnlyAssignedOfficerDecides {
  // FR-013: only the assigned officer can successfully decide.
  all op: Operation |
    (op.succeeded = BTrue and op.kind = DecideApp)
      implies op.caller = op.target.assignedOfficer
}

fact F_NoChangeAfterDecided {
  // FR-016: no further claim/decide on Approved/Rejected.
  all op: Operation |
    (op.succeeded = BTrue and op.kind in (ClaimApp + DecideApp))
      implies op.target.status not in (Approved + Rejected)
}

// =========================================================================
// PATTERN PREDICATES
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some Operation
  all op: Operation | op.succeeded = BTrue implies
    op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Documented allows are present; documented denies are absent.
  Customer -> SubmitApp in PermMatrix.Allowed
  Customer -> ListApps in PermMatrix.Allowed
  Customer -> GetApp in PermMatrix.Allowed
  Customer -> ClaimApp not in PermMatrix.Allowed
  Customer -> DecideApp not in PermMatrix.Allowed
  Customer -> ViewAudit not in PermMatrix.Allowed
  LoanOfficer -> SubmitApp not in PermMatrix.Allowed
  LoanOfficer -> ClaimApp in PermMatrix.Allowed
  LoanOfficer -> DecideApp in PermMatrix.Allowed
  LoanOfficer -> ViewAudit in PermMatrix.Allowed
  ComplianceReviewer -> SubmitApp not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApp not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApp not in PermMatrix.Allowed
  ComplianceReviewer -> ViewAudit in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.succeeded = BTrue implies op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  some LoanApplication
  all a: LoanApplication | (some e: AuditEntry | e.app = a and no e.prevStatus)
  all a: LoanApplication | a.status != Submitted implies
    (some e: AuditEntry | e.app = a and e.newStatus = UnderReview)
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (some e: AuditEntry | e.app = a and e.newStatus = a.status)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some AuditEntry
  // Duplicate entries for the same (app, transition) would indicate mutation/re-write.
  all a: LoanApplication, s: Status |
    (lone e: AuditEntry | e.app = a and e.newStatus = s)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry | (no e.prevStatus) implies e.actor = e.app.customer
  all e: AuditEntry | (some e.prevStatus) implies e.actor = e.app.assignedOfficer
  all e: AuditEntry | (no e.prevStatus) implies e.actor.role = Customer
  all e: AuditEntry | (some e.prevStatus) implies e.actor.role = LoanOfficer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id NOT NULL FK→users.id
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = Customer and op.kind = GetApp)
      implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-014; data-model.md reason CHECK
pred ValidationBeforeMutation {
  some Decision
  // A persisted decision has a non-empty reason (validation must have passed).
  all d: Decision | d.hasReason = BTrue
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// =========================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required on every request)
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.succeeded = BTrue implies op.authenticated = BTrue
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (customer is restricted to customer actions)
pred FR_002_CustomerLimited {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = Customer) implies
      op.kind in (SubmitApp + ListApps + GetApp)
}
assert FR_002_CustomerLimited { FR_002_CustomerLimited }
check FR_002_CustomerLimited for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (loan officer surface)
pred FR_003_OfficerLimited {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = LoanOfficer) implies
      op.kind in (ListApps + GetApp + ClaimApp + DecideApp + ViewAudit)
}
assert FR_003_OfficerLimited { FR_003_OfficerLimited }
check FR_003_OfficerLimited for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (compliance reviewer read-only)
pred FR_004_ComplianceReadOnly {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = ComplianceReviewer) implies
      op.kind in (ListApps + GetApp + ViewAudit)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (customer identity taken from auth, not payload)
pred FR_005_CustomerFromAuth {
  some LoanApplication
  all a: LoanApplication | a.customer.role = Customer
}
assert FR_005_CustomerFromAuth { FR_005_CustomerFromAuth }
check FR_005_CustomerFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (validation backstop on persisted records)
pred FR_006_ValidationStructural {
  some Decision
  // Validation enforces a non-empty reason; persisted decisions reflect that.
  all d: Decision | d.hasReason = BTrue
}
assert FR_006_ValidationStructural { FR_006_ValidationStructural }
check FR_006_ValidationStructural for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 (one in-flight application per customer)
pred FR_008_OneInFlight {
  some LoanApplication
  all u: User | u.role = Customer implies
    (lone a: LoanApplication | a.customer = u and a.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (submission produces initial audit entry by customer)
pred FR_009_SubmissionInitialState {
  some LoanApplication
  all a: LoanApplication |
    (one e: AuditEntry | e.app = a and no e.prevStatus and e.actor = a.customer)
}
assert FR_009_SubmissionInitialState { FR_009_SubmissionInitialState }
check FR_009_SubmissionInitialState for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (unassigned queue = apps at status=Submitted)
pred FR_010_QueueIsUnassigned {
  some LoanApplication
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}
assert FR_010_QueueIsUnassigned { FR_010_QueueIsUnassigned }
check FR_010_QueueIsUnassigned for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (claim sets officer, audits transition)
pred FR_011_ClaimSetsOfficer {
  some LoanApplication
  all a: LoanApplication | a.status != Submitted implies (some a.assignedOfficer)
  all a: LoanApplication | a.status != Submitted implies
    (some e: AuditEntry | e.app = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
}
assert FR_011_ClaimSetsOfficer { FR_011_ClaimSetsOfficer }
check FR_011_ClaimSetsOfficer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (at most one claimer wins)
pred FR_012_AtMostOneClaimer {
  some LoanApplication
  all a: LoanApplication | lone a.assignedOfficer
  all a: LoanApplication | (lone e: AuditEntry | e.app = a and e.newStatus = UnderReview)
}
assert FR_012_AtMostOneClaimer { FR_012_AtMostOneClaimer }
check FR_012_AtMostOneClaimer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (only the assigned officer can decide)
pred FR_013_OnlyAssignedDecides {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.kind = DecideApp)
      implies op.caller = op.target.assignedOfficer
}
assert FR_013_OnlyAssignedDecides { FR_013_OnlyAssignedDecides }
check FR_013_OnlyAssignedDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (decision reason required)
pred FR_014_ReasonRequired {
  some Decision
  all d: Decision | d.hasReason = BTrue
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (decision + status + audit are atomic)
pred FR_015_DecisionAtomic {
  some LoanApplication
  all a: LoanApplication |
    a.status in (Approved + Rejected) iff (some d: Decision | d.application = a)
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (one d: Decision | d.application = a and d.decisionType = a.status
                       and d.decidedBy = a.assignedOfficer)
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (one e: AuditEntry | e.app = a and e.prevStatus = UnderReview and e.newStatus = a.status)
}
assert FR_015_DecisionAtomic { FR_015_DecisionAtomic }
check FR_015_DecisionAtomic for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (no changes once decided)
pred FR_016_NoChangeAfterDecided {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.kind in (ClaimApp + DecideApp))
      implies op.target.status not in (Approved + Rejected)
}
assert FR_016_NoChangeAfterDecided { FR_016_NoChangeAfterDecided }
check FR_016_NoChangeAfterDecided for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (every status change audited with required fields)
pred FR_017_AuditAllChanges {
  some LoanApplication
  all a: LoanApplication | (some e: AuditEntry | e.app = a and no e.prevStatus)
  all a: LoanApplication | a.status != Submitted implies
    (some e: AuditEntry | e.app = a and e.newStatus = UnderReview)
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (some e: AuditEntry | e.app = a and e.newStatus = a.status)
  all e: AuditEntry | some e.actor and some e.newStatus and some e.app
}
assert FR_017_AuditAllChanges { FR_017_AuditAllChanges }
check FR_017_AuditAllChanges for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit append-only)
pred FR_018_AuditAppendOnly {
  some AuditEntry
  all a: LoanApplication, s: Status |
    (lone e: AuditEntry | e.app = a and e.newStatus = s)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (exactly one entry per applied change; none for unapplied)
pred FR_019_ExactlyOnePerChange {
  some LoanApplication
  all a: LoanApplication | (one e: AuditEntry | e.app = a and no e.prevStatus)
  all a: LoanApplication | a.status != Submitted implies
    (one e: AuditEntry | e.app = a and e.newStatus = UnderReview)
  all a: LoanApplication | a.status = Submitted implies
    (no e: AuditEntry | e.app = a and e.newStatus = UnderReview)
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (one e: AuditEntry | e.app = a and e.newStatus = a.status)
  all a: LoanApplication | a.status not in (Approved + Rejected) implies
    (no e: AuditEntry | e.app = a and e.newStatus in (Approved + Rejected))
}
assert FR_019_ExactlyOnePerChange { FR_019_ExactlyOnePerChange }
check FR_019_ExactlyOnePerChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 (customer can only see their own applications)
pred FR_020_CustomerOwnOnly {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = Customer and op.kind = GetApp)
      implies op.target.customer = op.caller
}
assert FR_020_CustomerOwnOnly { FR_020_CustomerOwnOnly }
check FR_020_CustomerOwnOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 (officer identity hidden from customer — no audit view)
pred FR_021_OfficerIdentityHiddenFromCustomer {
  some Operation
  // Audit responses carry officer actor IDs; customers cannot view them.
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = Customer) implies op.kind != ViewAudit
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-022 (retention — no public delete path; audit immutability)
pred FR_022_NoDelete {
  some AuditEntry
  // Structurally manifest as append-only audit (no overwriting / no removal).
  all a: LoanApplication, s: Status |
    (lone e: AuditEntry | e.app = a and e.newStatus = s)
}
assert FR_022_NoDelete { FR_022_NoDelete }
check FR_022_NoDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023 (compliance role cannot write anything)
pred FR_023_ComplianceNoWrites {
  some Operation
  all op: Operation |
    (op.succeeded = BTrue and op.caller.role = ComplianceReviewer) implies
      op.kind not in (SubmitApp + ClaimApp + DecideApp)
}
assert FR_023_ComplianceNoWrites { FR_023_ComplianceNoWrites }
check FR_023_ComplianceNoWrites for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AttributionViolation { some e: AuditEntry | (no e.prevStatus) and e.actor.role = LoanOfficer }
