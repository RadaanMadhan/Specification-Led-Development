// === feature_model.als — Alloy model for Loan Application RBAC + Audit Trail (A-L2 / 004-loan-application-rbac) ===

// ============================================================
// 1. Enum-like singletons
// ============================================================

abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

abstract sig OperationKind {}
one sig OpSubmit, OpListApps, OpGetApp, OpClaim, OpDecide, OpGetAudit extends OperationKind {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig DecisionType {}
one sig DApproved, DRejected extends DecisionType {}

abstract sig Outcome {}
one sig OK, Denied extends Outcome {}

// ============================================================
// 2. Entities
// ============================================================

sig User {
  role: one Role
}

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User
}

sig Decision {
  application: one LoanApplication,
  decType: one DecisionType,
  decidedBy: one User
}

sig AuditEntry {
  application: one LoanApplication,
  previousStatus: lone Status,   // none only for the initial (none)->Submitted entry
  newStatus: one Status,
  actor: one User
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication,
  outcome: one Outcome,
  revealedOfficer: lone User     // models whether response body discloses an officer identity
}

// Permission matrix as a singleton-sig field (Role -> OperationKind cells that are "allow").
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ============================================================
// 3. Non-empty universe (one top-level witness clause per dynamic sig)
// ============================================================

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
  some Decision
}

// ============================================================
// 4. Permission matrix — closed-world from contracts/http-api.md
// ============================================================

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer -> OpSubmit) +
    (Customer -> OpListApps) +
    (Customer -> OpGetApp) +
    (LoanOfficer -> OpListApps) +
    (LoanOfficer -> OpGetApp) +
    (LoanOfficer -> OpClaim) +
    (LoanOfficer -> OpDecide) +
    (LoanOfficer -> OpGetAudit) +
    (ComplianceReviewer -> OpListApps) +
    (ComplianceReviewer -> OpGetApp) +
    (ComplianceReviewer -> OpGetAudit)
}

// ============================================================
// 5. Structural invariants from data-model.md
// ============================================================

fact F_CustomerHasCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

fact F_AssignedOfficerIsLoanOfficer {
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

// data-model.md: CHECK ((status='Submitted') = (assigned_officer_id IS NULL))
fact F_StatusAssignmentCoupling {
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

// data-model.md: decisions.application_id PK ⇒ at most one decision per application
fact F_OneDecisionPerApp {
  all a: LoanApplication | (lone d: Decision | d.application = a)
}

fact F_DecisionImpliesDecided {
  all d: Decision {
    d.application.status in (Approved + Rejected)
    (d.decType = DApproved) iff (d.application.status = Approved)
    (d.decType = DRejected) iff (d.application.status = Rejected)
  }
}

fact F_DecidedHasDecision {
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (some d: Decision | d.application = a)
}

// data-model.md: conditional UPDATE forces decided_by = assigned_officer
fact F_DecisionByAssignedOfficer {
  all d: Decision | d.decidedBy = d.application.assignedOfficer
}

// data-model.md: CHECK ((previous_status IS NULL) = (new_status = 'Submitted'))
fact F_AuditPrevStatusInitial {
  all e: AuditEntry | (no e.previousStatus) iff e.newStatus = Submitted
}

// data-model.md: CHECK (previous_status IS NULL OR previous_status <> new_status)
fact F_AuditNoSelfTransition {
  all e: AuditEntry | some e.previousStatus implies e.previousStatus != e.newStatus
}

// FR-009: initial submission produces exactly one (none)->Submitted entry per app
fact F_AuditHasInitial {
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and no e.previousStatus and e.newStatus = Submitted)
}

// FR-011: claim produces exactly one Submitted->UnderReview entry per claimed app
fact F_AuditClaimEntry {
  all a: LoanApplication | a.status in (UnderReview + Approved + Rejected) implies
    (some e: AuditEntry | e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
}

// FR-015: decision produces exactly one UnderReview->Approved/Rejected entry per decided app
fact F_AuditDecisionEntry {
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    (some e: AuditEntry | e.application = a and e.previousStatus = UnderReview and e.newStatus = a.status)
}

// FR-016/spec state machine: only the four transitions reachable by code paths exist
fact F_AuditNoSpurious {
  all e: AuditEntry |
    (no e.previousStatus and e.newStatus = Submitted) or
    (e.previousStatus = Submitted and e.newStatus = UnderReview
        and e.application.status in (UnderReview + Approved + Rejected)) or
    (e.previousStatus = UnderReview and e.newStatus = Approved
        and e.application.status = Approved) or
    (e.previousStatus = UnderReview and e.newStatus = Rejected
        and e.application.status = Rejected)
}

// FR-018/FR-019: at most one audit entry per (application, prev, new) triple (no duplicates)
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application
         and e1.previousStatus = e2.previousStatus
         and e1.newStatus = e2.newStatus)
}

// FR-017: actor on each entry matches the responsible party for the transition
fact F_AuditAttribution {
  all e: AuditEntry {
    (no e.previousStatus) implies e.actor = e.application.customer
    (e.previousStatus = Submitted and e.newStatus = UnderReview) implies
      (e.actor = e.application.assignedOfficer and e.actor.role = LoanOfficer)
    (e.previousStatus = UnderReview and e.newStatus in (Approved + Rejected)) implies
      (e.actor = e.application.assignedOfficer and e.actor.role = LoanOfficer)
  }
}

// FR-008 / data-model.md idx_one_in_flight_per_customer
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    (a1.customer = a2.customer) implies
    not (a1.status in (Submitted + UnderReview) and a2.status in (Submitted + UnderReview))
}

// ============================================================
// 6. Operation outcome constraints (handlers + permissions table)
// ============================================================

// FR-001/002/003/004: anything outside the matrix is denied before business logic
fact F_LeastPrivilegeOutcome {
  all op: Operation |
    ((op.caller.role -> op.kind) not in PermMatrix.Allowed) implies op.outcome = Denied
}

// FR-020: customer asking about an app they don't own gets 404 (Denied), no existence leak
fact F_CustomerOwnershipForGet {
  all op: Operation |
    (op.caller.role = Customer and op.kind = OpGetApp and some op.target
        and op.target.customer != op.caller)
    implies op.outcome = Denied
}

// FR-020: customer list is scoped to own applications
fact F_CustomerOwnershipForList {
  all op: Operation |
    (op.caller.role = Customer and op.kind = OpListApps and op.outcome = OK and some op.target)
    implies op.target.customer = op.caller
}

// FR-013: decision succeeds only if caller is the application's assigned officer
fact F_DecideRequiresAssignedOfficer {
  all op: Operation |
    (op.kind = OpDecide and op.outcome = OK) implies
    (some op.target and op.target.assignedOfficer = op.caller and op.caller.role = LoanOfficer)
}

// FR-011/FR-012: claim succeeds only into UnderReview, with caller as assigned officer
fact F_ClaimSucceedsToUnderReview {
  all op: Operation |
    (op.kind = OpClaim and op.outcome = OK) implies
    (some op.target and op.target.status = UnderReview and op.target.assignedOfficer = op.caller)
}

// FR-005: submission only by customers
fact F_SubmitByCustomer {
  all op: Operation |
    (op.kind = OpSubmit and op.outcome = OK) implies op.caller.role = Customer
}

// FR-021: response to a customer never discloses officer identity
fact F_OfficerHiddenFromCustomer {
  all op: Operation | op.caller.role = Customer implies no op.revealedOfficer
}

// ============================================================
// 7. Pattern predicates + checks
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002/FR-003/FR-004
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = OK implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role | (some k: OperationKind | (r -> k) in PermMatrix.Allowed)
  all k: OperationKind | (some r: Role | (r -> k) in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017/FR-019; data-model.md audit table
pred AuditCompleteness {
  all a: LoanApplication {
    (some e: AuditEntry | e.application = a and no e.previousStatus and e.newStatus = Submitted)
    a.status in (UnderReview + Approved + Rejected) implies
      (some e: AuditEntry | e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
    a.status in (Approved + Rejected) implies
      (some e: AuditEntry | e.application = a and e.previousStatus = UnderReview and e.newStatus = a.status)
  }
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some AuditEntry
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application
         and e1.previousStatus = e2.previousStatus
         and e1.newStatus = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry {
    (no e.previousStatus) implies e.actor = e.application.customer
    (e.previousStatus = Submitted and e.newStatus = UnderReview) implies e.actor.role = LoanOfficer
    (e.previousStatus = UnderReview and e.newStatus in (Approved + Rejected)) implies e.actor.role = LoanOfficer
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id NOT NULL FK
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.customer and a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md customer-scope rules
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.caller.role = Customer and op.kind = OpGetApp and op.outcome = OK and some op.target)
    implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// ============================================================
// 8. FR-specific predicates + checks
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001 authentication on every request
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    (one op.caller and op.caller.role in (Customer + LoanOfficer + ComplianceReviewer))
    and (((op.caller.role -> op.kind) not in PermMatrix.Allowed) implies op.outcome = Denied)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002 customer permissions
pred FR_002_CustomerLeastPriv {
  some Operation
  all op: Operation |
    (op.caller.role = Customer and op.outcome = OK) implies
    op.kind in (OpSubmit + OpListApps + OpGetApp)
}
assert FR_002_CustomerLeastPriv { FR_002_CustomerLeastPriv }
check FR_002_CustomerLeastPriv for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-003 loan officer permissions
pred FR_003_OfficerOperations {
  some Operation
  all op: Operation |
    (op.caller.role = LoanOfficer and op.outcome = OK) implies
    op.kind in (OpListApps + OpGetApp + OpClaim + OpDecide + OpGetAudit)
}
assert FR_003_OfficerOperations { FR_003_OfficerOperations }
check FR_003_OfficerOperations for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004 compliance reviewer read-only
pred FR_004_ComplianceReadOnly {
  some Operation
  all op: Operation |
    (op.caller.role = ComplianceReviewer and op.outcome = OK) implies
    op.kind in (OpListApps + OpGetApp + OpGetAudit)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005 submission identity from auth context
pred FR_005_CustomerSubmits {
  some Operation
  all op: Operation |
    (op.kind = OpSubmit and op.outcome = OK) implies op.caller.role = Customer
}
assert FR_005_CustomerSubmits { FR_005_CustomerSubmits }
check FR_005_CustomerSubmits for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008 one in-flight application per customer
pred FR_008_OneInFlight {
  all disj a1, a2: LoanApplication |
    (a1.customer = a2.customer) implies
    not (a1.status in (Submitted + UnderReview) and a2.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009 initial audit entry recorded with submitter as actor
pred FR_009_InitialAuditEntry {
  all a: LoanApplication |
    (one e: AuditEntry |
        e.application = a
        and no e.previousStatus
        and e.newStatus = Submitted
        and e.actor = a.customer)
}
assert FR_009_InitialAuditEntry { FR_009_InitialAuditEntry }
check FR_009_InitialAuditEntry for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011 claim transition Submitted->Under Review with officer audit
pred FR_011_ClaimTransition {
  all a: LoanApplication | a.status in (UnderReview + Approved + Rejected) implies
    (some a.assignedOfficer
      and a.assignedOfficer.role = LoanOfficer
      and (one e: AuditEntry |
              e.application = a
              and e.previousStatus = Submitted
              and e.newStatus = UnderReview
              and e.actor = a.assignedOfficer))
}
assert FR_011_ClaimTransition { FR_011_ClaimTransition }
check FR_011_ClaimTransition for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012 one officer per application (claim race resolution)
pred FR_012_OneOfficerPerApp {
  some Operation
  all a: LoanApplication | lone a.assignedOfficer
  all op: Operation | (op.kind = OpClaim and op.outcome = OK) implies
    (some op.target and op.target.assignedOfficer = op.caller)
}
assert FR_012_OneOfficerPerApp { FR_012_OneOfficerPerApp }
check FR_012_OneOfficerPerApp for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013 only the assigned officer may decide
pred FR_013_OnlyAssignedDecides {
  some Operation
  all op: Operation | (op.kind = OpDecide and op.outcome = OK) implies
    (some op.target and op.target.assignedOfficer = op.caller and op.caller.role = LoanOfficer)
  all d: Decision | d.decidedBy = d.application.assignedOfficer
}
assert FR_013_OnlyAssignedDecides { FR_013_OnlyAssignedDecides }
check FR_013_OnlyAssignedDecides for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-015 atomic decision + status + audit entry
pred FR_015_AtomicDecisionAudit {
  all a: LoanApplication | a.status in (Approved + Rejected) implies
    ((one d: Decision | d.application = a and d.decidedBy = a.assignedOfficer)
     and (one e: AuditEntry |
            e.application = a
            and e.previousStatus = UnderReview
            and e.newStatus = a.status
            and e.actor = a.assignedOfficer))
}
assert FR_015_AtomicDecisionAudit { FR_015_AtomicDecisionAudit }
check FR_015_AtomicDecisionAudit for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-016 no further changes once Approved/Rejected
pred FR_016_NoFurtherChanges {
  // No audit entry depicts a transition out of Approved or Rejected.
  all e: AuditEntry | e.previousStatus not in (Approved + Rejected)
  // No claim operation succeeds against an already-decided application post-state.
  all op: Operation |
    (op.kind = OpClaim and op.outcome = OK and some op.target) implies
    op.target.status not in (Approved + Rejected)
}
assert FR_016_NoFurtherChanges { FR_016_NoFurtherChanges }
check FR_016_NoFurtherChanges for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017 every status change has an audit entry with full fields
pred FR_017_AuditEntryPerChange {
  all a: LoanApplication {
    (some e: AuditEntry | e.application = a and no e.previousStatus and e.newStatus = Submitted)
    a.status in (UnderReview + Approved + Rejected) implies
      (some e: AuditEntry | e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
    a.status in (Approved + Rejected) implies
      (some e: AuditEntry | e.application = a and e.previousStatus = UnderReview and e.newStatus = a.status)
  }
  all e: AuditEntry | some e.actor and some e.newStatus
}
assert FR_017_AuditEntryPerChange { FR_017_AuditEntryPerChange }
check FR_017_AuditEntryPerChange for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-018 audit append-only
pred FR_018_AuditAppendOnly {
  some AuditEntry
  all disj e1, e2: AuditEntry |
    not (e1.application = e2.application
         and e1.previousStatus = e2.previousStatus
         and e1.newStatus = e2.newStatus)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-019 exactly one audit entry per applied change
pred FR_019_ExactlyOnePerChange {
  all a: LoanApplication {
    (one e: AuditEntry | e.application = a and no e.previousStatus)
    a.status in (UnderReview + Approved + Rejected) implies
      (one e: AuditEntry | e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
    a.status in (Approved + Rejected) implies
      (one e: AuditEntry | e.application = a and e.previousStatus = UnderReview and e.newStatus = a.status)
  }
}
assert FR_019_ExactlyOnePerChange { FR_019_ExactlyOnePerChange }
check FR_019_ExactlyOnePerChange for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-020 customer sees only own applications
pred FR_020_CustomerOwnAppsOnly {
  some Operation
  all op: Operation |
    (op.caller.role = Customer and op.kind in (OpGetApp + OpListApps) and op.outcome = OK and some op.target)
    implies op.target.customer = op.caller
}
assert FR_020_CustomerOwnAppsOnly { FR_020_CustomerOwnAppsOnly }
check FR_020_CustomerOwnAppsOnly for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-021 officer identity scrubbed for customer responses
pred FR_021_OfficerHiddenFromCustomer {
  some Operation
  all op: Operation | op.caller.role = Customer implies no op.revealedOfficer
}
assert FR_021_OfficerHiddenFromCustomer { FR_021_OfficerHiddenFromCustomer }
check FR_021_OfficerHiddenFromCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-023 compliance reviewer cannot perform write actions
pred FR_023_ComplianceNoWrite {
  some Operation
  all op: Operation |
    (op.caller.role = ComplianceReviewer and op.kind in (OpSubmit + OpClaim + OpDecide))
    implies op.outcome = Denied
}
assert FR_023_ComplianceNoWrite { FR_023_ComplianceNoWrite }
check FR_023_ComplianceNoWrite for 8

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AttributionViolation { some e: AuditEntry | no e.previousStatus and e.newStatus = Submitted and e.actor != e.application.customer }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
