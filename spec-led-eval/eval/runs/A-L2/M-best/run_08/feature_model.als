// === feature_model.als — Alloy model for 004-loan-application-rbac ===
// Self-contained Alloy 6 model for the loan-application feature.
// Encodes: three-role permission matrix (customer / loan_officer /
// compliance_reviewer), claim-then-decide workflow, append-only audit
// trail, customer ownership, and officer-identity scrubbing.

// ----- Tag sigs -----

abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

abstract sig Status {}
one sig Submitted, UnderReview, Approved, Rejected extends Status {}

abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationsList, GetApplicationById,
        PostClaim, PostDecision, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig Allowed, Denied extends Outcome {}

// ----- Domain sigs -----

sig User { role: one Role }

sig LoanApplication {
  customer: one User,
  status: one Status,
  assignedOfficer: lone User,
  events: set ApplicationEvent,
  decision: lone Decision
}

sig Decision {
  app: one LoanApplication,
  decisionType: one DecisionType,
  decidedBy: one User,
  reasonNonEmpty: one Bool
}

sig ApplicationEvent {
  app: one LoanApplication,
  prevStatus: lone Status,
  newStatus: one Status,
  actor: one User
}

sig Operation {
  kind: one OperationKind,
  caller: one User,
  authenticated: one Bool,
  target: lone LoanApplication,
  outcome: one Outcome,
  revealsOfficer: lone User
}

// Permission matrix (contracts/http-api.md) as a singleton-sig field.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// =====================================================================
// FACTS (named, mutation-testable)
// =====================================================================

// Force at least one atom of each dynamic sig so quantified predicates
// aren't vacuously satisfied by an empty universe.
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
}

// Closed-world enumeration of the permission matrix from
// contracts/http-api.md "Permission matrix" table.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer -> PostApplications) +
    (Customer -> GetApplicationsList) +
    (Customer -> GetApplicationById) +
    (LoanOfficer -> GetApplicationsList) +
    (LoanOfficer -> GetApplicationById) +
    (LoanOfficer -> PostClaim) +
    (LoanOfficer -> PostDecision) +
    (LoanOfficer -> GetAudit) +
    (ComplianceReviewer -> GetApplicationsList) +
    (ComplianceReviewer -> GetApplicationById) +
    (ComplianceReviewer -> GetAudit)
}

// FR-001 — unauthenticated requests are refused before business logic.
fact F_AuthRequired {
  all op: Operation | op.authenticated = False implies op.outcome = Denied
}

// FR-002/003/004/023 — Least privilege: every allowed operation
// corresponds to an "allow" cell in the permission matrix.
fact F_LeastPrivilege {
  all op: Operation |
    op.outcome = Allowed implies
      (op.caller.role -> op.kind in PermMatrix.Allowed)
}

// FR-020 — Customer reads scoped to applications they own.
fact F_CustomerOwnsAppOnRead {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = Customer
     and op.kind = GetApplicationById and some op.target)
      implies op.target.customer = op.caller
}

// FR-013 — Only the assigned officer may decide a given application.
fact F_OfficerAssignedToDecide {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = LoanOfficer
     and op.kind = PostDecision and some op.target)
      implies op.caller = op.target.assignedOfficer
}

// FR-021 — Officer identity is never disclosed to customers.
fact F_OfficerIdentityHiddenFromCustomer {
  all op: Operation |
    op.caller.role = Customer implies no op.revealsOfficer
}

// Customer of an application has role = customer (data-model.md).
fact F_CustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

// Assigned officer (if any) has role = loan_officer (data-model.md).
fact F_OfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

// data-model.md CHECK ((status='Submitted') = (assigned_officer_id IS NULL))
fact F_StatusOfficerCoupling {
  all a: LoanApplication | (a.status = Submitted) iff (no a.assignedOfficer)
}

// FR-008 — partial unique index: at most one in-flight application per customer.
fact F_OneInFlightPerCustomer {
  all u: User |
    lone a: LoanApplication |
      a.customer = u and a.status in (Submitted + UnderReview)
}

// Bidirectional decision/application link.
fact F_DecisionAppLink {
  all d: Decision | d.app.decision = d
}

// FR-015 — A Decision exists iff the application is decided.
fact F_DecisionImpliesDecided {
  all a: LoanApplication |
    (some a.decision) iff (a.status in (Approved + Rejected))
}

// Decision type lines up with the final status.
fact F_DecisionTypeMatchesStatus {
  all a: LoanApplication | some a.decision implies
    ((a.decision.decisionType = DecApproved iff a.status = Approved) and
     (a.decision.decisionType = DecRejected iff a.status = Rejected))
}

// FR-013 — Recorded decider equals the application's assigned officer.
fact F_DecisionByAssignedOfficer {
  all d: Decision | d.decidedBy = d.app.assignedOfficer
}

// FR-014 — Decisions carry a non-empty reason (structural backstop).
fact F_DecisionReasonNonEmpty {
  all d: Decision | d.reasonNonEmpty = True
}

// Events belong to exactly the application that lists them.
fact F_EventBelongsToApp {
  all e: ApplicationEvent | e in e.app.events
  all a: LoanApplication, e: ApplicationEvent |
    e in a.events implies e.app = a
}

// Only the four reachable transitions exist in the audit log.
fact F_OnlyValidTransitions {
  all e: ApplicationEvent |
    (no e.prevStatus and e.newStatus = Submitted) or
    (e.prevStatus = Submitted and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
}

// FR-018 (defence-in-depth) — no no-op events.
fact F_NoNoopEvents {
  all e: ApplicationEvent |
    some e.prevStatus implies e.prevStatus != e.newStatus
}

// FR-018 / FR-019 — at most one event per (app, prev, new) transition.
fact F_EventTransitionUniqueness {
  all a: LoanApplication |
    all disj e1, e2: a.events |
      e1.prevStatus != e2.prevStatus or e1.newStatus != e2.newStatus
}

// FR-017 — Every applied transition produces at least one event.
fact F_AppEventsForwardCompleteness {
  all a: LoanApplication |
    (some e: a.events | no e.prevStatus and e.newStatus = Submitted)
  all a: LoanApplication |
    a.status != Submitted implies
      (some e: a.events | e.prevStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
      (some e: a.events | e.prevStatus = UnderReview and e.newStatus = a.status)
}

// No spurious "claim" event on a still-Submitted application.
fact F_NoSpuriousClaimEvents {
  all a: LoanApplication, e: a.events |
    (e.prevStatus = Submitted and e.newStatus = UnderReview)
      implies a.status != Submitted
}

// No spurious "decision" event unless application is in that decided status.
fact F_NoSpuriousDecisionEvents {
  all a: LoanApplication, e: a.events |
    (e.prevStatus = UnderReview and e.newStatus in (Approved + Rejected))
      implies a.status = e.newStatus
}

// FR-017 — Attribution of the initial submission event.
fact F_InitialActorIsCustomer {
  all a: LoanApplication, e: a.events |
    (no e.prevStatus and e.newStatus = Submitted) implies e.actor = a.customer
}

// FR-017 — Attribution of the claim event.
fact F_ClaimActorIsAssignedOfficer {
  all a: LoanApplication, e: a.events |
    (e.prevStatus = Submitted and e.newStatus = UnderReview)
      implies e.actor = a.assignedOfficer
}

// FR-017 — Attribution of the decision event.
fact F_DecisionActorIsAssignedOfficer {
  all a: LoanApplication, e: a.events |
    (e.prevStatus = UnderReview and e.newStatus in (Approved + Rejected))
      implies e.actor = a.assignedOfficer
}

// =====================================================================
// PATTERN PREDICATES & ASSERTIONS
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  no op: Operation |
    op.outcome = Allowed and (op.caller.role -> op.kind) not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  no op: Operation | op.authenticated = False and op.outcome = Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer / assigned_officer_id
pred OwnershipExclusivity {
  all a: LoanApplication | one a.customer and a.customer.role = Customer
  all a: LoanApplication |
    some a.assignedOfficer implies (a.assignedOfficer.role = LoanOfficer)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; data-model.md customer_id filter
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = Customer
     and op.kind = GetApplicationById and some op.target)
      implies op.target.customer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020 (404 not 403 on non-owner reads)
pred NoInformationLeakage {
  all op: Operation |
    (op.caller.role = Customer and op.kind = GetApplicationById
     and some op.target and op.target.customer != op.caller)
      implies op.outcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  all a: LoanApplication |
    (some e: a.events | no e.prevStatus and e.newStatus = Submitted)
  all a: LoanApplication |
    a.status != Submitted implies
      (some e: a.events | e.prevStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
      (some e: a.events | e.prevStatus = UnderReview and e.newStatus = a.status)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md no UPDATE/DELETE on application_events
pred AppendOnly {
  all a: LoanApplication |
    all disj e1, e2: a.events |
      e1.prevStatus != e2.prevStatus or e1.newStatus != e2.newStatus
  all e: ApplicationEvent |
    some e.prevStatus implies e.prevStatus != e.newStatus
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017 (actor/role match transition)
pred AttributionCorrectness {
  all a: LoanApplication, e: a.events |
    (no e.prevStatus and e.newStatus = Submitted) implies e.actor = a.customer
  all a: LoanApplication, e: a.events |
    (e.prevStatus = Submitted and e.newStatus = UnderReview)
      implies e.actor = a.assignedOfficer
  all a: LoanApplication, e: a.events |
    (e.prevStatus = UnderReview and e.newStatus in (Approved + Rejected))
      implies e.actor = a.assignedOfficer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// =====================================================================
// FEATURE-SPECIFIC ASSERTIONS (one per FR-NNN)
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  no op: Operation | op.authenticated = False and op.outcome = Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (customer role scope)
pred FR_002_CustomerScope {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = Customer)
      implies op.kind in (PostApplications + GetApplicationsList + GetApplicationById)
}
assert FR_002_CustomerScope { FR_002_CustomerScope }
check FR_002_CustomerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (loan-officer role scope; assignment-gated decide)
pred FR_003_OfficerScope {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = LoanOfficer)
      implies op.kind != PostApplications
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = LoanOfficer
     and op.kind = PostDecision and some op.target)
      implies op.caller = op.target.assignedOfficer
}
assert FR_003_OfficerScope { FR_003_OfficerScope }
check FR_003_OfficerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (compliance read-only)
pred FR_004_ComplianceReadOnly {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = ComplianceReviewer)
      implies op.kind in (GetApplicationsList + GetApplicationById + GetAudit)
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (customer identity taken from auth context)
pred FR_005_CustomerIdFromAuth {
  all a: LoanApplication, e: a.events |
    (no e.prevStatus and e.newStatus = Submitted) implies e.actor = a.customer
}
assert FR_005_CustomerIdFromAuth { FR_005_CustomerIdFromAuth }
check FR_005_CustomerIdFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 (at most one in-flight per customer)
pred FR_008_OneInFlight {
  all u: User |
    lone a: LoanApplication |
      a.customer = u and a.status in (Submitted + UnderReview)
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (initial (none)->Submitted event with customer as actor)
pred FR_009_InitialSubmitted {
  all a: LoanApplication |
    (one e: a.events |
       no e.prevStatus and e.newStatus = Submitted and e.actor = a.customer)
}
assert FR_009_InitialSubmitted { FR_009_InitialSubmitted }
check FR_009_InitialSubmitted for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (claim transition records Submitted->UnderReview by claimer)
pred FR_011_ClaimTransition {
  all a: LoanApplication |
    a.status != Submitted implies
      (some e: a.events |
         e.prevStatus = Submitted and e.newStatus = UnderReview
         and e.actor = a.assignedOfficer)
}
assert FR_011_ClaimTransition { FR_011_ClaimTransition }
check FR_011_ClaimTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (exactly one officer can claim)
pred FR_012_OneClaimWins {
  all a: LoanApplication |
    lone e: a.events |
      e.prevStatus = Submitted and e.newStatus = UnderReview
}
assert FR_012_OneClaimWins { FR_012_OneClaimWins }
check FR_012_OneClaimWins for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (only assigned officer decides)
pred FR_013_OnlyAssignedDecides {
  all d: Decision | d.decidedBy = d.app.assignedOfficer
}
assert FR_013_OnlyAssignedDecides { FR_013_OnlyAssignedDecides }
check FR_013_OnlyAssignedDecides for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (non-empty reason)
pred FR_014_NonEmptyReason {
  all d: Decision | d.reasonNonEmpty = True
}
assert FR_014_NonEmptyReason { FR_014_NonEmptyReason }
check FR_014_NonEmptyReason for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (decision exists iff status is decided)
pred FR_015_DecisionAtomicity {
  all a: LoanApplication |
    (some a.decision) iff (a.status in (Approved + Rejected))
}
assert FR_015_DecisionAtomicity { FR_015_DecisionAtomicity }
check FR_015_DecisionAtomicity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (no transitions out of Approved/Rejected)
pred FR_016_ImmutabilityAfterDecided {
  all e: ApplicationEvent | e.prevStatus not in (Approved + Rejected)
}
assert FR_016_ImmutabilityAfterDecided { FR_016_ImmutabilityAfterDecided }
check FR_016_ImmutabilityAfterDecided for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit entry per status change)
pred FR_017_AuditPerStatusChange {
  all a: LoanApplication |
    (some e: a.events | no e.prevStatus and e.newStatus = Submitted)
  all a: LoanApplication |
    a.status != Submitted implies
      (some e: a.events | e.prevStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    a.status in (Approved + Rejected) implies
      (some e: a.events | e.prevStatus = UnderReview and e.newStatus = a.status)
}
assert FR_017_AuditPerStatusChange { FR_017_AuditPerStatusChange }
check FR_017_AuditPerStatusChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (audit trail append-only)
pred FR_018_AppendOnly {
  all a: LoanApplication |
    all disj e1, e2: a.events |
      e1.prevStatus != e2.prevStatus or e1.newStatus != e2.newStatus
  all e: ApplicationEvent |
    some e.prevStatus implies e.prevStatus != e.newStatus
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (exactly one event per applied transition)
pred FR_019_ExactlyOnePerChange {
  all a: LoanApplication |
    (one e: a.events | no e.prevStatus and e.newStatus = Submitted)
  all a: LoanApplication |
    lone e: a.events |
      e.prevStatus = Submitted and e.newStatus = UnderReview
  all a: LoanApplication |
    lone e: a.events |
      e.prevStatus = UnderReview and e.newStatus in (Approved + Rejected)
}
assert FR_019_ExactlyOnePerChange { FR_019_ExactlyOnePerChange }
check FR_019_ExactlyOnePerChange for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 (customer sees only own applications)
pred FR_020_CustomerOwnOnly {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = Customer
     and op.kind = GetApplicationById and some op.target)
      implies op.target.customer = op.caller
}
assert FR_020_CustomerOwnOnly { FR_020_CustomerOwnOnly }
check FR_020_CustomerOwnOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-021 (officer identity hidden from customer)
pred FR_021_OfficerHidden {
  all op: Operation |
    op.caller.role = Customer implies no op.revealsOfficer
}
assert FR_021_OfficerHidden { FR_021_OfficerHidden }
check FR_021_OfficerHidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023 (compliance role cannot perform writes)
pred FR_023_ComplianceNoWrites {
  all op: Operation |
    (op.outcome = Allowed and op.caller.role = ComplianceReviewer)
      implies op.kind not in (PostApplications + PostClaim + PostDecision)
}
assert FR_023_ComplianceNoWrites { FR_023_ComplianceNoWrites }
check FR_023_ComplianceNoWrites for 8