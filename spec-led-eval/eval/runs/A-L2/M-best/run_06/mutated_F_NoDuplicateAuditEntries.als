// === feature_model.als — Alloy model for 004-loan-application-rbac ===
//
// Loan application feature with three roles (customer, loan_officer,
// compliance_reviewer), a four-state status machine
// (Submitted → Under Review → Approved/Rejected), and an append-only
// audit trail. Sources:
//   - spec.md FR-001..FR-023
//   - data-model.md (tables, CHECK constraints, partial unique index)
//   - contracts/http-api.md (six endpoints, permission matrix,
//     no-existence-leak rule, response scrubbing)

// ----- Roles / Operations / Status / DecisionType -----

abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationsList, GetApplicationById,
        PostClaim, PostDecision, GetAudit extends OperationKind {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// Permission matrix as a singleton-sig field (not `sig ... in ...`).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ----- Dynamic entities -----

sig User { role: one Role }

sig Reason {}
sig Reference {}

sig Decision {
  decisionType: one DecisionType,
  decidedBy: one User,
  reason: set Reason
}

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User,
  decision: lone Decision,
  reference: one Reference
}

sig ApplicationEvent {
  application: one LoanApplication,
  previousStatus: lone Status,
  newStatus: one Status,
  actor: one User
}

sig Operation {
  kind: one OperationKind,
  caller: one User,
  target: lone LoanApplication,
  authenticated: one Bool
}

// ----- Non-empty universe (so `all x | P[x]` doesn't pass vacuously) -----

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
  some Operation
  some Decision
  some Reason
  some Reference
}

// ===================================================================
// PERMISSION MATRIX (from contracts/http-api.md)
// ===================================================================

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Customer           -> PostApplications)
    + (Customer           -> GetApplicationsList)
    + (Customer           -> GetApplicationById)
    + (LoanOfficer        -> GetApplicationsList)
    + (LoanOfficer        -> GetApplicationById)
    + (LoanOfficer        -> PostClaim)
    + (LoanOfficer        -> PostDecision)
    + (LoanOfficer        -> GetAudit)
    + (ComplianceReviewer -> GetApplicationsList)
    + (ComplianceReviewer -> GetApplicationById)
    + (ComplianceReviewer -> GetAudit)
}

// ===================================================================
// CORE STRUCTURAL FACTS
// ===================================================================

fact F_AppCustomerIsCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

fact F_AssignedOfficerCoupledToStatus {
  // CHECK ((status='Submitted') = (assigned_officer_id IS NULL))
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

fact F_AssignedOfficerIsLoanOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

fact F_DecisionPresenceCoupledToStatus {
  all a: LoanApplication |
    (some a.decision) iff (a.status = Approved or a.status = Rejected)
}

fact F_DecisionTypeMatchesStatus {
  all a: LoanApplication |
    (a.status = Approved) implies (a.decision.decisionType = ApprovedDecision)
  all a: LoanApplication |
    (a.status = Rejected) implies (a.decision.decisionType = RejectedDecision)
}

fact F_DecidedByEqualsAssignedOfficer {
  // The deciding officer is the application's assigned officer (FR-013).
  all a: LoanApplication |
    some a.decision implies a.decision.decidedBy = a.assignedOfficer
}

fact F_DecisionUniquePerApplication {
  all d: Decision | (one a: LoanApplication | a.decision = d)
}

fact F_DecisionHasReason {
  // FR-014: every decision carries a non-empty reason.
  all d: Decision | some d.reason
}

fact F_UniqueReferencePerApplication {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}

fact F_OneInFlightPerCustomer {
  // data-model.md partial unique index idx_one_in_flight_per_customer (FR-008).
  all u: User |
    (u.role = Customer) implies
      (lone a: LoanApplication |
        a.customer = u and a.status in (Submitted + UnderReview))
}

// ===================================================================
// AUDIT TRAIL FACTS
// ===================================================================

fact F_AuditEventValidTransition {
  // Only four legal transitions exist (data-model.md state machine).
  all e: ApplicationEvent |
    (no e.previousStatus and e.newStatus = Submitted) or
    (e.previousStatus = Submitted    and e.newStatus = UnderReview) or
    (e.previousStatus = UnderReview and e.newStatus = Approved) or
    (e.previousStatus = UnderReview and e.newStatus = Rejected)
}

fact F_AuditActorCorrectness {
  // FR-017: actor on each event matches who would have triggered it.
  all e: ApplicationEvent |
    (no e.previousStatus) implies (e.actor = e.application.customer)
  all e: ApplicationEvent |
    (e.previousStatus = Submitted) implies (e.actor = e.application.assignedOfficer)
  all e: ApplicationEvent |
    (e.previousStatus = UnderReview) implies (e.actor = e.application.assignedOfficer)
}

fact F_AuditEntryExistsForEveryTransition {
  // FR-017, FR-019: every applied transition has at least one event.
  all a: LoanApplication |
    (one e: ApplicationEvent | e.application = a and no e.previousStatus)
  all a: LoanApplication |
    (a.status in (UnderReview + Approved + Rejected)) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    (a.status = Approved) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    (a.status = Rejected) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Rejected)
}

fact F_NoDuplicateAuditEntries { /* MUTATED — body cleared by validator */ }

fact F_NoSpuriousAuditEntries {
  // FR-019 "never more than one (entries for changes that didn't happen)":
  // an event only exists for a transition the application actually passed.
  all e: ApplicationEvent |
    (e.previousStatus = Submitted) implies
      (e.application.status in (UnderReview + Approved + Rejected))
  all e: ApplicationEvent |
    (e.newStatus = Approved) implies (e.application.status = Approved)
  all e: ApplicationEvent |
    (e.newStatus = Rejected) implies (e.application.status = Rejected)
}

// ===================================================================
// OPERATION-LEVEL FACTS (API behaviour)
// ===================================================================

fact F_OperationAuthRequired {
  // FR-001: every request is authenticated before handler logic.
  all op: Operation | op.authenticated = BTrue
}

fact F_OperationsRespectPermissionMatrix {
  // LeastPrivilege root fact: every op's (role, kind) is in Allowed.
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}

fact F_DecideOpByAssignedOfficer {
  // FR-013: only the assigned loan officer can decide.
  all op: Operation |
    (op.kind = PostDecision) implies
      (some op.target and op.caller = op.target.assignedOfficer)
}

fact F_ClaimOpByLoanOfficer {
  all op: Operation |
    (op.kind = PostClaim) implies
      (some op.target and op.caller.role = LoanOfficer)
}

fact F_SubmitOpByCustomer {
  // FR-005: the customer-id on a new application comes from auth.
  all op: Operation |
    (op.kind = PostApplications) implies (op.caller.role = Customer)
}

fact F_CustomerViewOwnOnly {
  // FR-020: customer's GET by reference only reaches their own apps.
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById and some op.target)
      implies (op.target.customer = op.caller)
}

// ===================================================================
// PATTERN PREDICATES (catalogue)
// ===================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002/003/004
pred LeastPrivilege {
  all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix (3x6 = 18 cells)
pred PermissionCompleteness {
  // The matrix has exactly the 11 allowed cells listed in F_PermissionMatrix.
  #PermMatrix.Allowed = 11
  // Every endpoint has at least one role that may call it.
  some r: Role | r -> PostApplications    in PermMatrix.Allowed
  some r: Role | r -> GetApplicationsList in PermMatrix.Allowed
  some r: Role | r -> GetApplicationById  in PermMatrix.Allowed
  some r: Role | r -> PostClaim           in PermMatrix.Allowed
  some r: Role | r -> PostDecision        in PermMatrix.Allowed
  some r: Role | r -> GetAudit            in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-002/003/004 / FR-011 / FR-013 / FR-018
pred PermissionGrounding {
  Customer           -> PostApplications in PermMatrix.Allowed  // FR-002, FR-005
  LoanOfficer        -> PostClaim        in PermMatrix.Allowed  // FR-003, FR-011
  LoanOfficer        -> PostDecision     in PermMatrix.Allowed  // FR-003, FR-013
  LoanOfficer        -> GetAudit         in PermMatrix.Allowed  // FR-003, FR-017
  ComplianceReviewer -> GetAudit         in PermMatrix.Allowed  // FR-004, FR-018
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md atomicity
pred AuditCompleteness {
  all a: LoanApplication |
    (one e: ApplicationEvent | e.application = a and no e.previousStatus)
  all a: LoanApplication |
    (a.status in (UnderReview + Approved + Rejected)) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    (a.status = Approved) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    (a.status = Rejected) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Rejected)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md (no UPDATE/DELETE on application_events)
pred AppendOnly {
  no disj e1, e2: ApplicationEvent |
    e1.application     = e2.application
    and e1.previousStatus = e2.previousStatus
    and e1.newStatus      = e2.newStatus
  all e: ApplicationEvent |
    (no e.previousStatus and e.newStatus = Submitted) or
    (e.previousStatus = Submitted    and e.newStatus = UnderReview) or
    (e.previousStatus = UnderReview and e.newStatus = Approved) or
    (e.previousStatus = UnderReview and e.newStatus = Rejected)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
pred AttributionCorrectness {
  all e: ApplicationEvent |
    (no e.previousStatus) implies (e.actor = e.application.customer)
  all e: ApplicationEvent |
    (e.previousStatus = Submitted) implies (e.actor = e.application.assignedOfficer)
  all e: ApplicationEvent |
    (e.previousStatus = UnderReview) implies (e.actor = e.application.assignedOfficer)
  // Role of actor matches the kind of transition.
  all e: ApplicationEvent |
    (no e.previousStatus) implies (e.actor.role = Customer)
  all e: ApplicationEvent |
    (some e.previousStatus) implies (e.actor.role = LoanOfficer)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id FK; spec.md FR-005
pred OwnershipExclusivity {
  all a: LoanApplication | (one a.customer) and (a.customer.role = Customer)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020
pred OwnershipBasedAccess {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById and some op.target)
      implies (op.target.customer = op.caller)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020 (404, not 403, for non-owner)
pred NoInformationLeakage {
  // A customer-role operation cannot target an application they don't own
  // (the API surfaces 404 not_found, structurally equivalent to "no such op").
  no op: Operation |
    op.caller.role = Customer
    and op.kind = GetApplicationById
    and some op.target
    and op.target.customer != op.caller
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ===================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// ===================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | op.authenticated = BTrue
  all op: Operation | one op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
  all op: Operation |
    (op.caller.role = Customer) implies
      (op.kind in (PostApplications + GetApplicationsList + GetApplicationById))
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_OfficerPermissions {
  all op: Operation |
    (op.caller.role = LoanOfficer) implies
      (op.kind in (GetApplicationsList + GetApplicationById
                 + PostClaim + PostDecision + GetAudit))
  all op: Operation |
    (op.kind = PostDecision and op.caller.role = LoanOfficer) implies
      (some op.target and op.caller = op.target.assignedOfficer)
}
assert FR_003_OfficerPermissions { FR_003_OfficerPermissions }
check FR_003_OfficerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CompliancePermissions {
  all op: Operation |
    (op.caller.role = ComplianceReviewer) implies
      (op.kind in (GetApplicationsList + GetApplicationById + GetAudit))
}
assert FR_004_CompliancePermissions { FR_004_CompliancePermissions }
check FR_004_CompliancePermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_CustomerIdentityFromAuth {
  all a: LoanApplication | a.customer.role = Customer
  all op: Operation |
    (op.kind = PostApplications) implies (op.caller.role = Customer)
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 / FR-007 (structural backstop on application shape)
pred FR_007_ValidApplicationShape {
  all a: LoanApplication |
    one a.customer and one a.reference and one a.status and
    a.status in (Submitted + UnderReview + Approved + Rejected)
}
assert FR_007_ValidApplicationShape { FR_007_ValidApplicationShape }
check FR_007_ValidApplicationShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerCustomer {
  all u: User |
    (u.role = Customer) implies
      (lone a: LoanApplication |
        a.customer = u and a.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_UniqueReference {
  all disj a1, a2: LoanApplication | a1.reference != a2.reference
}
assert FR_009_UniqueReference { FR_009_UniqueReference }
check FR_009_UniqueReference for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (unassigned queue = apps at Submitted, no officer)
pred FR_010_UnassignedQueue {
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}
assert FR_010_UnassignedQueue { FR_010_UnassignedQueue }
check FR_010_UnassignedQueue for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClaimTransition {
  all a: LoanApplication |
    (a.status != Submitted) implies
      (some a.assignedOfficer and a.assignedOfficer.role = LoanOfficer)
}
assert FR_011_ClaimTransition { FR_011_ClaimTransition }
check FR_011_ClaimTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OneOfficerPerClaim {
  all a: LoanApplication | lone a.assignedOfficer
  all a: LoanApplication |
    (a.status in (UnderReview + Approved + Rejected)) implies
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
}
assert FR_012_OneOfficerPerClaim { FR_012_OneOfficerPerClaim }
check FR_012_OneOfficerPerClaim for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OnlyAssignedOfficerDecides {
  all a: LoanApplication |
    (some a.decision) implies (a.decision.decidedBy = a.assignedOfficer)
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ReasonRequired {
  all d: Decision | some d.reason
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_DecisionAtomic {
  all a: LoanApplication |
    (some a.decision) iff (a.status = Approved or a.status = Rejected)
  all a: LoanApplication |
    (a.status = Approved) implies (a.decision.decisionType = ApprovedDecision)
  all a: LoanApplication |
    (a.status = Rejected) implies (a.decision.decisionType = RejectedDecision)
  all a: LoanApplication |
    (a.status = Approved) implies
      (some e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    (a.status = Rejected) implies
      (some e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Rejected)
}
assert FR_015_DecisionAtomic { FR_015_DecisionAtomic }
check FR_015_DecisionAtomic for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_DecidedImmutable {
  // No event records a transition *out of* a decided state.
  no e: ApplicationEvent | e.previousStatus = Approved or e.previousStatus = Rejected
  // Decided applications retain their decision and assignment.
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies
      (some a.decision and some a.assignedOfficer)
}
assert FR_016_DecidedImmutable { FR_016_DecidedImmutable }
check FR_016_DecidedImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditEntryPerStatusChange {
  all e: ApplicationEvent |
    one e.actor and one e.newStatus and one e.application
  all a: LoanApplication | (some e: ApplicationEvent | e.application = a)
}
assert FR_017_AuditEntryPerStatusChange { FR_017_AuditEntryPerStatusChange }
check FR_017_AuditEntryPerStatusChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AppendOnlyAudit {
  no disj e1, e2: ApplicationEvent |
    e1.application     = e2.application
    and e1.previousStatus = e2.previousStatus
    and e1.newStatus      = e2.newStatus
}
assert FR_018_AppendOnlyAudit { FR_018_AppendOnlyAudit }
check FR_018_AppendOnlyAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_ExactlyOneEntryPerAppliedTransition {
  all a: LoanApplication |
    (one e: ApplicationEvent | e.application = a and no e.previousStatus)
  all a: LoanApplication |
    (a.status in (UnderReview + Approved + Rejected)) iff
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    (a.status = Approved) iff
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    (a.status = Rejected) iff
      (one e: ApplicationEvent |
        e.application = a and e.previousStatus = UnderReview and e.newStatus = Rejected)
}
assert FR_019_ExactlyOneEntryPerAppliedTransition { FR_019_ExactlyOneEntryPerAppliedTransition }
check FR_019_ExactlyOneEntryPerAppliedTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_CustomerSeesOnlyOwn {
  no op: Operation |
    op.caller.role = Customer
    and op.kind in (GetApplicationById + GetApplicationsList)
    and some op.target
    and op.target.customer != op.caller
}
assert FR_020_CustomerSeesOnlyOwn { FR_020_CustomerSeesOnlyOwn }
check FR_020_CustomerSeesOnlyOwn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_OfficerIdentityHidden {
  // Customers cannot reach the audit endpoint where officer identity is exposed.
  no op: Operation | op.caller.role = Customer and op.kind = GetAudit
}
assert FR_021_OfficerIdentityHidden { FR_021_OfficerIdentityHidden }
check FR_021_OfficerIdentityHidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-022 (retention; structural no-deletion)
pred FR_022_NoDeletion {
  all a: LoanApplication | (some e: ApplicationEvent | e.application = a)
  all d: Decision | (some a: LoanApplication | a.decision = d)
}
assert FR_022_NoDeletion { FR_022_NoDeletion }
check FR_022_NoDeletion for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_ComplianceReadOnly {
  all op: Operation |
    (op.caller.role = ComplianceReviewer) implies
      (op.kind not in (PostApplications + PostClaim + PostDecision))
}
assert FR_023_ComplianceReadOnly { FR_023_ComplianceReadOnly }
check FR_023_ComplianceReadOnly for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj e1, e2: ApplicationEvent | e1.application = e2.application and e1.previousStatus = e2.previousStatus and e1.newStatus = e2.newStatus }
