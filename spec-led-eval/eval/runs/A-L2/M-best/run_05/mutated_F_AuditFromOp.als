// === feature_model.als — Alloy model for Loan Application with Role-Based Workflow and Audit Trail ===

// -------------------------------------------------------------
// SIGNATURES
// -------------------------------------------------------------

abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig DecisionType {}
one sig DApproved, DRejected extends DecisionType {}

abstract sig OperationKind {}
one sig SubmitApp, ListApps, GetApp, ClaimApp, DecideApp, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig Success, Denied extends Outcome {}

// Permission matrix as a singleton-sig field — see system prompt rule 7.
one sig PermMatrix { Allowed: set Role -> OperationKind }

sig User { role: one Role }

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User
}

sig Reason {}

sig Decision {
  application: one LoanApplication,
  decisionType: one DecisionType,
  decider: one User,
  reason: one Reason
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  prevStatus: lone Status,
  newStatus: one Status
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication,
  outcome: one Outcome,
  createdEvent: lone AuditEntry
}

// -------------------------------------------------------------
// NON-EMPTY UNIVERSE
// -------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
  some Reason
  some Decision
}

// -------------------------------------------------------------
// PERMISSION MATRIX (contracts/http-api.md)
// -------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole -> SubmitApp) +
    (CustomerRole -> ListApps) +
    (CustomerRole -> GetApp) +
    (LoanOfficerRole -> ListApps) +
    (LoanOfficerRole -> GetApp) +
    (LoanOfficerRole -> ClaimApp) +
    (LoanOfficerRole -> DecideApp) +
    (LoanOfficerRole -> GetAudit) +
    (ComplianceReviewerRole -> ListApps) +
    (ComplianceReviewerRole -> GetApp) +
    (ComplianceReviewerRole -> GetAudit)
}

// -------------------------------------------------------------
// ENTITY INVARIANTS (data-model.md)
// -------------------------------------------------------------

fact F_StatusAssignmentCoupling {
  // (status = Submitted) iff (no assigned officer)
  all app: LoanApplication |
    (app.status = Submitted) iff (no app.assignedOfficer)
}

fact F_CustomerHasCustomerRole {
  all app: LoanApplication | app.customer.role = CustomerRole
}

fact F_AssignedIsOfficer {
  all app: LoanApplication |
    (some app.assignedOfficer) implies app.assignedOfficer.role = LoanOfficerRole
}

fact F_DecisionConsistency {
  // Decision rows only on decided applications, matching outcome.
  all d: Decision | d.application.status in (Approved + Rejected)
  all d: Decision | (d.decisionType = DApproved) iff (d.application.status = Approved)
  all d: Decision | (d.decisionType = DRejected) iff (d.application.status = Rejected)
  // At most one decision per application (data-model PK).
  all app: LoanApplication | lone d: Decision | d.application = app
  // Decided application has a decision recorded.
  all app: LoanApplication |
    app.status in (Approved + Rejected) implies (some d: Decision | d.application = app)
  // Decider is the assigned officer (data-model service.py assertion).
  all d: Decision | d.decider = d.application.assignedOfficer
}

fact F_OneInFlightPerCustomer {
  // FR-008 partial unique index.
  all u: User |
    u.role = CustomerRole implies
      (lone app: LoanApplication | app.customer = u and app.status in (Submitted + UnderReview))
}

fact F_AuditPrevStatusShape {
  // CHECK ((previous_status IS NULL) = (new_status = 'Submitted'))
  all ae: AuditEntry | (no ae.prevStatus) iff (ae.newStatus = Submitted)
  // CHECK (previous_status IS NULL OR previous_status <> new_status)
  all ae: AuditEntry | (some ae.prevStatus) implies (ae.prevStatus != ae.newStatus)
}

// -------------------------------------------------------------
// AUTHORISATION (the load-bearing role/operation gate)
// -------------------------------------------------------------

fact F_LeastPrivilege {
  // Every successful operation has its (role, kind) in the permission matrix.
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}

// -------------------------------------------------------------
// OPERATION SEMANTICS — state-changing kinds (spec.md FR-009/011/015)
// -------------------------------------------------------------

fact F_SubmitSemantics {
  // FR-005, FR-009: submitter owns the new application; status Submitted.
  all op: Operation |
    (op.kind = SubmitApp and op.outcome = Success) implies (
      some op.target and
      op.target.customer = op.caller and
      op.target.status = Submitted
    )
}

fact F_ClaimSemantics {
  // FR-011: claim sets assigned officer and moves to Under Review.
  all op: Operation |
    (op.kind = ClaimApp and op.outcome = Success) implies (
      some op.target and
      op.target.status in (UnderReview + Approved + Rejected) and
      op.target.assignedOfficer = op.caller
    )
}

fact F_DecideRequiresAssigned {
  // FR-013: only the assigned officer may decide.
  all op: Operation |
    (op.kind = DecideApp and op.outcome = Success) implies (
      some op.target and
      op.target.assignedOfficer = op.caller and
      op.target.status in (Approved + Rejected)
    )
}

// -------------------------------------------------------------
// AUDIT TRAIL FACTS (spec.md FR-017/018/019)
// -------------------------------------------------------------

fact F_StateChangingProducesAudit {
  // FR-019: every successful state-changing op produces exactly one audit entry.
  all op: Operation |
    (op.outcome = Success and op.kind in (SubmitApp + ClaimApp + DecideApp))
      implies (one op.createdEvent)
}

fact F_ReadOnlyNoAudit {
  all op: Operation |
    op.kind in (ListApps + GetApp + GetAudit) implies no op.createdEvent
}

fact F_DeniedNoAudit {
  all op: Operation |
    op.outcome = Denied implies no op.createdEvent
}

fact F_SubmitAuditDetails {
  all op: Operation |
    (op.kind = SubmitApp and op.outcome = Success and some op.createdEvent) implies (
      op.createdEvent.application = op.target and
      op.createdEvent.actor = op.caller and
      no op.createdEvent.prevStatus and
      op.createdEvent.newStatus = Submitted
    )
}

fact F_ClaimAuditDetails {
  all op: Operation |
    (op.kind = ClaimApp and op.outcome = Success and some op.createdEvent) implies (
      op.createdEvent.application = op.target and
      op.createdEvent.actor = op.caller and
      op.createdEvent.prevStatus = Submitted and
      op.createdEvent.newStatus = UnderReview
    )
}

fact F_DecideAuditDetails {
  all op: Operation |
    (op.kind = DecideApp and op.outcome = Success and some op.createdEvent) implies (
      op.createdEvent.application = op.target and
      op.createdEvent.actor = op.caller and
      op.createdEvent.prevStatus = UnderReview and
      op.createdEvent.newStatus in (Approved + Rejected) and
      op.createdEvent.newStatus = op.target.status
    )
}

fact F_AuditFromOp { /* MUTATED — body cleared by validator */ }

// -------------------------------------------------------------
// OWNERSHIP-CONDITIONAL ACCESS (FR-020)
// -------------------------------------------------------------

fact F_CustomerOwnership {
  // Customers may only successfully Get applications they own.
  all op: Operation |
    (op.caller.role = CustomerRole and op.outcome = Success and op.kind = GetApp)
      implies (some op.target and op.target.customer = op.caller)
}

// -------------------------------------------------------------
// PATTERNS
// -------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002/003/004
pred LeastPrivilege {
  some Operation
  no op: Operation |
    op.outcome = Success and (op.caller.role -> op.kind) not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every documented deny is actually denied (closed-world matrix).
  (CustomerRole -> ClaimApp) not in PermMatrix.Allowed
  (CustomerRole -> DecideApp) not in PermMatrix.Allowed
  (CustomerRole -> GetAudit) not in PermMatrix.Allowed
  (LoanOfficerRole -> SubmitApp) not in PermMatrix.Allowed
  (ComplianceReviewerRole -> SubmitApp) not in PermMatrix.Allowed
  (ComplianceReviewerRole -> ClaimApp) not in PermMatrix.Allowed
  (ComplianceReviewerRole -> DecideApp) not in PermMatrix.Allowed
  // Every documented allow is actually allowed.
  (CustomerRole -> SubmitApp) in PermMatrix.Allowed
  (LoanOfficerRole -> ClaimApp) in PermMatrix.Allowed
  (LoanOfficerRole -> DecideApp) in PermMatrix.Allowed
  (ComplianceReviewerRole -> GetAudit) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model UNIQUE
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (op.outcome = Success and op.kind in (SubmitApp + ClaimApp + DecideApp))
      implies (one op.createdEvent)
  all op: Operation |
    op.kind in (ListApps + GetApp + GetAudit) implies no op.createdEvent
  all op: Operation |
    op.outcome = Denied implies no op.createdEvent
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some AuditEntry
  // Each audit entry is bound to exactly one creating Operation: no orphan rewrites.
  all ae: AuditEntry | one op: Operation | op.createdEvent = ae
  // Audit entries can only be born from a successful state-changing op.
  all ae: AuditEntry |
    some op: Operation |
      op.createdEvent = ae and op.outcome = Success and
      op.kind in (SubmitApp + ClaimApp + DecideApp)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model actor_user_id
pred AttributionCorrectness {
  some AuditEntry
  all op: Operation, ae: AuditEntry |
    op.createdEvent = ae implies (ae.actor = op.caller and ae.application = op.target)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id NOT NULL FK
pred OwnershipExclusivity {
  some LoanApplication
  all app: LoanApplication | one app.customer and app.customer.role = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.caller.role = CustomerRole and op.outcome = Success and op.kind = GetApp)
      implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/ 404 vs 403 rule
pred NoInformationLeakage {
  // A customer never gets a Success on someone else's application.
  no op: Operation |
    op.caller.role = CustomerRole and op.outcome = Success and op.kind = GetApp
    and (some op.target) and op.target.customer != op.caller
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, SC-006
pred ConcurrencySafety {
  some LoanApplication
  // At most one assigned officer per application — even under concurrent claim attempts.
  all app: LoanApplication | lone app.assignedOfficer
  // At most one successful claim per application.
  all app: LoanApplication |
    lone op: Operation | op.kind = ClaimApp and op.outcome = Success and op.target = app
}
assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 8

// -------------------------------------------------------------
// FEATURE-SPECIFIC FR ASSERTIONS
// -------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authenticated caller with exactly one role
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | one op.caller and one op.caller.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 — customers can only do customer actions
pred FR_002_CustomerScopedActions {
  all op: Operation |
    (op.caller.role = CustomerRole and op.outcome = Success)
      implies op.kind in (SubmitApp + ListApps + GetApp)
}
assert FR_002_CustomerScopedActions { FR_002_CustomerScopedActions }
check FR_002_CustomerScopedActions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 — loan officers cannot submit as a customer
pred FR_003_LoanOfficerScope {
  all op: Operation |
    (op.caller.role = LoanOfficerRole and op.outcome = Success)
      implies op.kind != SubmitApp
}
assert FR_003_LoanOfficerScope { FR_003_LoanOfficerScope }
check FR_003_LoanOfficerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023 — compliance reviewers are read-only
pred FR_004_ComplianceReadOnly {
  all op: Operation |
    (op.caller.role = ComplianceReviewerRole and op.outcome = Success)
      implies op.kind in (ListApps + GetApp + GetAudit)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — submitter identity from auth context
pred FR_005_SubmissionIdentity {
  all op: Operation |
    (op.kind = SubmitApp and op.outcome = Success)
      implies (some op.target and op.target.customer = op.caller)
}
assert FR_005_SubmissionIdentity { FR_005_SubmissionIdentity }
check FR_005_SubmissionIdentity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 — one in-flight application per customer
pred FR_008_OneInFlight {
  all u: User |
    u.role = CustomerRole implies
      (lone app: LoanApplication | app.customer = u and app.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 — submission produces (none)->Submitted audit
pred FR_009_SubmitAudit {
  all op: Operation |
    (op.kind = SubmitApp and op.outcome = Success) implies (
      one op.createdEvent and
      no op.createdEvent.prevStatus and
      op.createdEvent.newStatus = Submitted and
      op.createdEvent.actor = op.caller
    )
}
assert FR_009_SubmitAudit { FR_009_SubmitAudit }
check FR_009_SubmitAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 — claim transition and audit shape
pred FR_011_ClaimTransition {
  all op: Operation |
    (op.kind = ClaimApp and op.outcome = Success) implies (
      op.target.assignedOfficer = op.caller and
      op.target.status in (UnderReview + Approved + Rejected) and
      one op.createdEvent and
      op.createdEvent.prevStatus = Submitted and
      op.createdEvent.newStatus = UnderReview
    )
}
assert FR_011_ClaimTransition { FR_011_ClaimTransition }
check FR_011_ClaimTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 — only one officer ever assigned per application
pred FR_012_OneAssignedOfficer {
  all app: LoanApplication | lone app.assignedOfficer
  all app: LoanApplication |
    lone op: Operation | op.kind = ClaimApp and op.outcome = Success and op.target = app
}
assert FR_012_OneAssignedOfficer { FR_012_OneAssignedOfficer }
check FR_012_OneAssignedOfficer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 — only assigned officer decides
pred FR_013_AssignedDecides {
  all op: Operation |
    (op.kind = DecideApp and op.outcome = Success)
      implies (some op.target and op.target.assignedOfficer = op.caller)
  all d: Decision | d.decider = d.application.assignedOfficer
}
assert FR_013_AssignedDecides { FR_013_AssignedDecides }
check FR_013_AssignedDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 — non-empty reason required on every decision
pred FR_014_ReasonRequired {
  all d: Decision | one d.reason
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — atomic decision + status + audit
pred FR_015_DecisionAtomic {
  all op: Operation |
    (op.kind = DecideApp and op.outcome = Success) implies (
      op.target.status in (Approved + Rejected) and
      one op.createdEvent and
      op.createdEvent.prevStatus = UnderReview and
      op.createdEvent.newStatus = op.target.status
    )
  // Every decided application has a Decision row.
  all app: LoanApplication |
    app.status in (Approved + Rejected) implies (one d: Decision | d.application = app)
}
assert FR_015_DecisionAtomic { FR_015_DecisionAtomic }
check FR_015_DecisionAtomic for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 — terminal states are immutable
pred FR_016_DecidedTerminal {
  // No audit entry records leaving a terminal status.
  all ae: AuditEntry | ae.prevStatus not in (Approved + Rejected)
}
assert FR_016_DecidedTerminal { FR_016_DecidedTerminal }
check FR_016_DecidedTerminal for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 — every audit entry has actor / prev / new fields
pred FR_017_AuditFields {
  all ae: AuditEntry |
    one ae.actor and one ae.newStatus and one ae.application
  // No no-op transitions recorded.
  all ae: AuditEntry | (some ae.prevStatus) implies ae.prevStatus != ae.newStatus
}
assert FR_017_AuditFields { FR_017_AuditFields }
check FR_017_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 — audit trail is append-only
pred FR_018_AppendOnly {
  some AuditEntry
  all ae: AuditEntry | one op: Operation | op.createdEvent = ae
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 — exactly one audit per applied status change
pred FR_019_OneAuditPerChange {
  all op: Operation |
    (op.outcome = Success and op.kind in (SubmitApp + ClaimApp + DecideApp))
      implies (one op.createdEvent)
  all disj op1, op2: Operation |
    (some op1.createdEvent and some op2.createdEvent)
      implies op1.createdEvent != op2.createdEvent
}
assert FR_019_OneAuditPerChange { FR_019_OneAuditPerChange }
check FR_019_OneAuditPerChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 — customers see only their own applications
pred FR_020_CustomerOwnOnly {
  all op: Operation |
    (op.caller.role = CustomerRole and op.outcome = Success and op.kind = GetApp)
      implies (some op.target and op.target.customer = op.caller)
}
assert FR_020_CustomerOwnOnly { FR_020_CustomerOwnOnly }
check FR_020_CustomerOwnOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 — officer identity hidden: customers cannot fetch audit trail
pred FR_021_NoAuditForCustomer {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = GetAudit) implies op.outcome = Denied
}
assert FR_021_NoAuditForCustomer { FR_021_NoAuditForCustomer }
check FR_021_NoAuditForCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023 — compliance reviewers have zero write capability
pred FR_023_ComplianceNoWrite {
  all op: Operation |
    (op.caller.role = ComplianceReviewerRole and op.outcome = Success)
      implies op.kind not in (SubmitApp + ClaimApp + DecideApp)
}
assert FR_023_ComplianceNoWrite { FR_023_ComplianceNoWrite }
check FR_023_ComplianceNoWrite for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some ae: AuditEntry | no op: Operation | op.createdEvent = ae }
