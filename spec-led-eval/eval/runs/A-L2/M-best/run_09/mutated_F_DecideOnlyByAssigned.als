// === feature_model.als — Alloy model for Loan Application RBAC (A-L2) ===

// --- Non-empty universe to avoid vacuous quantification ---
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
  some Decision
}

// --- Roles ---
abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

// --- Application statuses ---
abstract sig Status {}
one sig SubmittedSt, UnderReviewSt, ApprovedSt, RejectedSt extends Status {}

// --- API operation kinds (six endpoints from contracts/http-api.md) ---
abstract sig OperationKind {}
one sig OpSubmit, OpListApps, OpGetApp, OpClaim, OpDecide, OpGetAudit extends OperationKind {}

// --- Outcomes (Success vs. various failure codes) ---
abstract sig Outcome {}
one sig Success, PermissionDenied, NotFoundOutcome, AlreadyClaimedOutcome,
        AlreadyDecidedOutcome, NotAssignedOfficerOutcome extends Outcome {}

// --- Permission matrix as a singleton-sig field ---
one sig PermMatrix { Allowed: set Role -> OperationKind }

// Closed-world enumeration of the contracts/http-api.md permission table.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CustomerRole -> OpSubmit) +
    (CustomerRole -> OpListApps) +
    (CustomerRole -> OpGetApp) +
    (LoanOfficerRole -> OpListApps) +
    (LoanOfficerRole -> OpGetApp) +
    (LoanOfficerRole -> OpClaim) +
    (LoanOfficerRole -> OpDecide) +
    (LoanOfficerRole -> OpGetAudit) +
    (ComplianceReviewerRole -> OpListApps) +
    (ComplianceReviewerRole -> OpGetApp) +
    (ComplianceReviewerRole -> OpGetAudit)
}

// --- Dynamic entities ---
sig User { role: one Role }

sig Decision { decidedBy: one User }

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User,
  decision: lone Decision
}

sig AuditEntry {
  application: one LoanApplication,
  prevStatus: lone Status,
  newStatus: one Status,
  actor: one User
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone LoanApplication,
  outcome: one Outcome
}

// =====================================================================
// DOMAIN STRUCTURAL FACTS
// =====================================================================

fact F_CustomerHasCustomerRole {
  all a: LoanApplication | a.customer.role = CustomerRole
}

fact F_AssignedOfficerIsLoanOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficerRole
}

fact F_StatusOfficerCoupling {
  all a: LoanApplication | (a.status = SubmittedSt) iff (no a.assignedOfficer)
}

fact F_StatusDecisionCoupling {
  all a: LoanApplication |
    (some a.decision) iff (a.status = ApprovedSt or a.status = RejectedSt)
}

fact F_DecisionByAssignedOfficer {
  all a: LoanApplication |
    some a.decision implies a.decision.decidedBy = a.assignedOfficer
}

fact F_DecisionUniqueToApplication {
  all disj a1, a2: LoanApplication |
    (some a1.decision and some a2.decision) implies a1.decision != a2.decision
}

fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
      not ((a1.status = SubmittedSt or a1.status = UnderReviewSt) and
           (a2.status = SubmittedSt or a2.status = UnderReviewSt))
}

fact F_ValidAuditTransitions {
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = SubmittedSt) or
    (e.prevStatus = SubmittedSt and e.newStatus = UnderReviewSt) or
    (e.prevStatus = UnderReviewSt and e.newStatus = ApprovedSt) or
    (e.prevStatus = UnderReviewSt and e.newStatus = RejectedSt)
}

fact F_AuditActorIdentity {
  all e: AuditEntry |
    (no e.prevStatus) implies (e.actor = e.application.customer)
  all e: AuditEntry |
    (some e.prevStatus) implies (e.actor = e.application.assignedOfficer)
}

fact F_AuditEntryExists {
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and no e.prevStatus and e.newStatus = SubmittedSt)
  all a: LoanApplication |
    (a.status != SubmittedSt) implies
      (some e: AuditEntry |
        e.application = a and e.prevStatus = SubmittedSt and e.newStatus = UnderReviewSt)
  all a: LoanApplication |
    (a.status = ApprovedSt) implies
      (some e: AuditEntry |
        e.application = a and e.prevStatus = UnderReviewSt and e.newStatus = ApprovedSt)
  all a: LoanApplication |
    (a.status = RejectedSt) implies
      (some e: AuditEntry |
        e.application = a and e.prevStatus = UnderReviewSt and e.newStatus = RejectedSt)
}

fact F_AuditNoDuplicates {
  no disj e1, e2: AuditEntry |
    e1.application = e2.application and e1.newStatus = e2.newStatus
}

fact F_AuditNoSpurious {
  all e: AuditEntry |
    (e.prevStatus = SubmittedSt and e.newStatus = UnderReviewSt) implies
      e.application.status != SubmittedSt
  all e: AuditEntry |
    (e.newStatus = ApprovedSt) implies e.application.status = ApprovedSt
  all e: AuditEntry |
    (e.newStatus = RejectedSt) implies e.application.status = RejectedSt
}

// =====================================================================
// OPERATION BEHAVIOR FACTS
// =====================================================================

fact F_PermissionGate {
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}

fact F_SubmitBindsCustomerIdentity {
  all op: Operation |
    (op.kind = OpSubmit and op.outcome = Success) implies
      (some op.target and op.target.customer = op.caller)
}

fact F_NoLeakNotFound {
  // Customer GetApp on a non-owned existing application yields NotFound
  // (same response as a nonexistent reference) — covers both ownership-based
  // access and no-existence-leak.
  all op: Operation |
    (op.kind = OpGetApp and op.caller.role = CustomerRole and
     some op.target and op.target.customer != op.caller) implies
      op.outcome = NotFoundOutcome
}

fact F_ClaimAssignsOfficer {
  all op: Operation |
    (op.kind = OpClaim and op.outcome = Success) implies
      (op.caller.role = LoanOfficerRole and some op.target and
       op.target.assignedOfficer = op.caller)
}

fact F_DecideOnlyByAssigned { /* MUTATED — body cleared by validator */ }

// =====================================================================
// PATTERN-BASED PREDICATES
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-002/003/004
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Documented allow cells
  (CustomerRole -> OpSubmit) in PermMatrix.Allowed
  (CustomerRole -> OpListApps) in PermMatrix.Allowed
  (CustomerRole -> OpGetApp) in PermMatrix.Allowed
  (LoanOfficerRole -> OpClaim) in PermMatrix.Allowed
  (LoanOfficerRole -> OpDecide) in PermMatrix.Allowed
  (LoanOfficerRole -> OpGetAudit) in PermMatrix.Allowed
  (ComplianceReviewerRole -> OpGetApp) in PermMatrix.Allowed
  (ComplianceReviewerRole -> OpGetAudit) in PermMatrix.Allowed
  // Documented deny cells
  (CustomerRole -> OpClaim) not in PermMatrix.Allowed
  (CustomerRole -> OpDecide) not in PermMatrix.Allowed
  (CustomerRole -> OpGetAudit) not in PermMatrix.Allowed
  (LoanOfficerRole -> OpSubmit) not in PermMatrix.Allowed
  (ComplianceReviewerRole -> OpSubmit) not in PermMatrix.Allowed
  (ComplianceReviewerRole -> OpClaim) not in PermMatrix.Allowed
  (ComplianceReviewerRole -> OpDecide) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: contracts/http-api.md auth section; spec.md FR-001
pred AuthRequiredEverywhere {
  // Every operation is bound to exactly one authenticated user with exactly one role
  all op: Operation | one op.caller
  all u: User | one u.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017/FR-019; data-model.md application_events
pred AuditCompleteness {
  all a: LoanApplication |
    (some e: AuditEntry | e.application = a and no e.prevStatus and e.newStatus = SubmittedSt)
  all a: LoanApplication |
    a.status != SubmittedSt implies
      (some e: AuditEntry |
        e.application = a and e.prevStatus = SubmittedSt and e.newStatus = UnderReviewSt)
  all a: LoanApplication |
    a.status = ApprovedSt implies
      (some e: AuditEntry |
        e.application = a and e.prevStatus = UnderReviewSt and e.newStatus = ApprovedSt)
  all a: LoanApplication |
    a.status = RejectedSt implies
      (some e: AuditEntry |
        e.application = a and e.prevStatus = UnderReviewSt and e.newStatus = RejectedSt)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  no disj e1, e2: AuditEntry |
    e1.application = e2.application and e1.newStatus = e2.newStatus
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md application_events.actor_user_id
pred AttributionCorrectness {
  all e: AuditEntry |
    (no e.prevStatus) implies (e.actor = e.application.customer and e.actor.role = CustomerRole)
  all e: AuditEntry |
    (some e.prevStatus) implies (e.actor = e.application.assignedOfficer and e.actor.role = LoanOfficerRole)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.customer_id
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer
  all a: LoanApplication | a.customer.role = CustomerRole
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md customer scoping
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = OpGetApp and op.caller.role = CustomerRole and op.outcome = Success) implies
      (some op.target and op.target.customer = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "no existence leak"
pred NoInformationLeakage {
  all op: Operation |
    (op.kind = OpGetApp and op.caller.role = CustomerRole and
     some op.target and op.target.customer != op.caller) implies
      op.outcome = NotFoundOutcome
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// =====================================================================
// FR-SPECIFIC PREDICATES (one per FR-NNN)
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth required; exactly one role per user)
pred FR_001_AuthAndOneRole {
  all u: User | one u.role
  all op: Operation | one op.caller
}
assert FR_001_AuthAndOneRole { FR_001_AuthAndOneRole }
check FR_001_AuthAndOneRole for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (customer-only actions: submit/list-own/get-own)
pred FR_002_CustomerActionScope {
  all op: Operation |
    (op.caller.role = CustomerRole and op.outcome = Success) implies
      (op.kind = OpSubmit or op.kind = OpListApps or op.kind = OpGetApp)
}
assert FR_002_CustomerActionScope { FR_002_CustomerActionScope }
check FR_002_CustomerActionScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (loan officer cannot submit as customer)
pred FR_003_LoanOfficerNoSubmit {
  all op: Operation |
    (op.caller.role = LoanOfficerRole and op.outcome = Success) implies op.kind != OpSubmit
}
assert FR_003_LoanOfficerNoSubmit { FR_003_LoanOfficerNoSubmit }
check FR_003_LoanOfficerNoSubmit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (compliance reviewer read-only)
pred FR_004_ComplianceReadOnly {
  all op: Operation |
    (op.caller.role = ComplianceReviewerRole and op.outcome = Success) implies
      (op.kind = OpListApps or op.kind = OpGetApp or op.kind = OpGetAudit)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (customer identity bound from auth context, not payload)
pred FR_005_CustomerIdentityBound {
  all op: Operation |
    (op.kind = OpSubmit and op.outcome = Success) implies
      (op.caller.role = CustomerRole and some op.target and op.target.customer = op.caller)
}
assert FR_005_CustomerIdentityBound { FR_005_CustomerIdentityBound }
check FR_005_CustomerIdentityBound for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006/FR-007 (validation backstop: customer/officer role correctness on persisted entities)
pred FR_006_StructuralValidation {
  all a: LoanApplication | a.customer.role = CustomerRole
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficerRole
}
assert FR_006_StructuralValidation { FR_006_StructuralValidation }
check FR_006_StructuralValidation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 (one in-flight application per customer)
pred FR_008_OneInFlightPerCustomer {
  no disj a1, a2: LoanApplication |
    a1.customer = a2.customer and
    (a1.status = SubmittedSt or a1.status = UnderReviewSt) and
    (a2.status = SubmittedSt or a2.status = UnderReviewSt)
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (submission produces a (none)→Submitted audit entry, actor = customer)
pred FR_009_SubmissionAudit {
  all a: LoanApplication |
    (some e: AuditEntry |
      e.application = a and no e.prevStatus and e.newStatus = SubmittedSt and e.actor = a.customer)
}
assert FR_009_SubmissionAudit { FR_009_SubmissionAudit }
check FR_009_SubmissionAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (loan officer can list applications — queue access)
pred FR_010_QueueAccess {
  (LoanOfficerRole -> OpListApps) in PermMatrix.Allowed
}
assert FR_010_QueueAccess { FR_010_QueueAccess }
check FR_010_QueueAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (claim sets the assigned officer to the claimer)
pred FR_011_ClaimAssignsOfficer {
  all op: Operation |
    (op.kind = OpClaim and op.outcome = Success) implies
      (op.caller.role = LoanOfficerRole and some op.target and op.target.assignedOfficer = op.caller)
}
assert FR_011_ClaimAssignsOfficer { FR_011_ClaimAssignsOfficer }
check FR_011_ClaimAssignsOfficer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (at most one assigned officer per application; exactly one after claim)
pred FR_012_OneOfficerPerApp {
  all a: LoanApplication | lone a.assignedOfficer
  all a: LoanApplication | (a.status != SubmittedSt) implies one a.assignedOfficer
  all a: LoanApplication | (a.status = SubmittedSt) implies no a.assignedOfficer
}
assert FR_012_OneOfficerPerApp { FR_012_OneOfficerPerApp }
check FR_012_OneOfficerPerApp for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (only the assigned officer can decide)
pred FR_013_OnlyAssignedDecides {
  all op: Operation |
    (op.kind = OpDecide and op.outcome = Success) implies
      (some op.target and op.target.assignedOfficer = op.caller)
}
assert FR_013_OnlyAssignedDecides { FR_013_OnlyAssignedDecides }
check FR_013_OnlyAssignedDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (every decision records a deciding officer)
pred FR_014_DecisionHasDecider {
  all d: Decision | one d.decidedBy
}
assert FR_014_DecisionHasDecider { FR_014_DecisionHasDecider }
check FR_014_DecisionHasDecider for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (decision atomic with status and assignment)
pred FR_015_DecisionAtomicity {
  all a: LoanApplication | (some a.decision) iff (a.status = ApprovedSt or a.status = RejectedSt)
  all a: LoanApplication | some a.decision implies a.decision.decidedBy = a.assignedOfficer
}
assert FR_015_DecisionAtomicity { FR_015_DecisionAtomicity }
check FR_015_DecisionAtomicity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (no further claim/decide once Approved/Rejected)
pred FR_016_DecidedImmutable {
  all op: Operation |
    ((op.kind = OpClaim or op.kind = OpDecide) and op.outcome = Success and some op.target) implies
      (op.target.status = SubmittedSt or op.target.status = UnderReviewSt)
}
assert FR_016_DecidedImmutable { FR_016_DecidedImmutable }
check FR_016_DecidedImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit-entry field coupling: prev null iff new=Submitted)
pred FR_017_AuditFieldsValid {
  all e: AuditEntry | (no e.prevStatus) iff (e.newStatus = SubmittedSt)
  all e: AuditEntry | (some e.prevStatus) implies (e.prevStatus != e.newStatus)
}
assert FR_017_AuditFieldsValid { FR_017_AuditFieldsValid }
check FR_017_AuditFieldsValid for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit append-only — no duplicate transitions per application)
pred FR_018_AuditAppendOnly {
  no disj e1, e2: AuditEntry |
    e1.application = e2.application and e1.newStatus = e2.newStatus
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (exactly one entry per applied transition; no spurious entries)
pred FR_019_OneAuditPerTransition {
  all a: LoanApplication |
    (one e: AuditEntry | e.application = a and no e.prevStatus)
  all a: LoanApplication |
    (a.status != SubmittedSt) iff
      (some e: AuditEntry |
        e.application = a and e.prevStatus = SubmittedSt and e.newStatus = UnderReviewSt)
  all a: LoanApplication |
    (a.status = ApprovedSt) iff
      (some e: AuditEntry | e.application = a and e.newStatus = ApprovedSt)
  all a: LoanApplication |
    (a.status = RejectedSt) iff
      (some e: AuditEntry | e.application = a and e.newStatus = RejectedSt)
}
assert FR_019_OneAuditPerTransition { FR_019_OneAuditPerTransition }
check FR_019_OneAuditPerTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 (customer sees only own applications)
pred FR_020_CustomerSeesOwnOnly {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = OpGetApp and op.outcome = Success) implies
      (some op.target and op.target.customer = op.caller)
}
assert FR_020_CustomerSeesOwnOnly { FR_020_CustomerSeesOwnOnly }
check FR_020_CustomerSeesOwnOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 (officer identity not exposed to customers — no audit access)
pred FR_021_OfficerIdHiddenFromCustomer {
  all op: Operation |
    (op.caller.role = CustomerRole and op.kind = OpGetAudit) implies op.outcome != Success
}
assert FR_021_OfficerIdHiddenFromCustomer { FR_021_OfficerIdHiddenFromCustomer }
check FR_021_OfficerIdHiddenFromCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-022 (audit retention — at least one entry per application)
pred FR_022_AuditRetained {
  all a: LoanApplication | (some e: AuditEntry | e.application = a)
}
assert FR_022_AuditRetained { FR_022_AuditRetained }
check FR_022_AuditRetained for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023 (compliance reviewer cannot write anything)
pred FR_023_ComplianceNoWrites {
  all op: Operation |
    (op.caller.role = ComplianceReviewerRole and op.outcome = Success) implies
      (op.kind != OpSubmit and op.kind != OpClaim and op.kind != OpDecide)
}
assert FR_023_ComplianceNoWrites { FR_023_ComplianceNoWrites }
check FR_023_ComplianceNoWrites for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NonAssignedDecideViolation { some op: Operation, a: LoanApplication, disj u1, u2: User | u1.role = LoanOfficerRole and u2.role = LoanOfficerRole and op.caller = u1 and op.kind = OpDecide and op.target = a and a.assignedOfficer = u2 and op.outcome = Success }
