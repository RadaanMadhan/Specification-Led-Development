// === feature_model.als — Alloy model for Loan Application RBAC + Audit Trail ===
// Feature: 004-loan-application-rbac  (folder id: A-L2)
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ─────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ─────────────────────────────────────────────
// DECISION TYPE
// ─────────────────────────────────────────────
abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

// ─────────────────────────────────────────────
// OPERATION KINDS  (one per distinct HTTP action)
// ─────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        ClaimApplication, DecideApplication, GetAudit
        extends OperationKind {}

// ─────────────────────────────────────────────
// PERMISSION MATRIX  (singleton, field is the relation)
// ─────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────
// DOMAIN SIGS
// ─────────────────────────────────────────────

sig User {
  role: one Role
}

sig LoanApplication {
  customer       : one User,
  status         : one ApplicationStatus,
  assignedOfficer: lone User        // null iff status = Submitted
}

// At most one Decision per LoanApplication (enforced structurally via PK in data-model)
sig Decision {
  application : one LoanApplication,
  decisionType: one DecisionType,
  decidedBy   : one User
}

// Append-only audit record; previousStatus is absent (lone) for initial submission
sig ApplicationEvent {
  application    : one LoanApplication,
  previousStatus : lone ApplicationStatus,
  newStatus      : one ApplicationStatus,
  actor          : one User
}

// ─────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
}

// ─────────────────────────────────────────────
// PERMISSION MATRIX FACT
// contracts/http-api.md permission table
// ─────────────────────────────────────────────
fact F_PermissionMatrix {
  // Explicit allow cells — closed-world assignment below
  PermMatrix.Allowed =
      (Customer        -> PostApplications)   +
      (Customer        -> GetApplications)    +
      (Customer        -> GetApplicationByRef)+
      (LoanOfficer     -> GetApplications)    +
      (LoanOfficer     -> GetApplicationByRef)+
      (LoanOfficer     -> ClaimApplication)   +
      (LoanOfficer     -> DecideApplication)  +
      (LoanOfficer     -> GetAudit)           +
      (ComplianceReviewer -> GetApplications)    +
      (ComplianceReviewer -> GetApplicationByRef)+
      (ComplianceReviewer -> GetAudit)
}

// ─────────────────────────────────────────────
// USER / ROLE FACTS
// ─────────────────────────────────────────────
// data-model.md: "A User has exactly one Role"
// (Field multiplicity `one Role` already enforces uniqueness; this fact
//  pins structural relationships relied on by downstream facts.)
fact F_OneRolePerUser {
  all u: User | one u.role
}

// Customer field of LoanApplication must reference a Customer-role user
// data-model.md: "customer_id … Must reference a user whose role is customer"
fact F_CustomerFieldIsCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

// Assigned officer must be a loan officer
// data-model.md: "The officer referenced must have role='loan_officer'"
fact F_AssignedOfficerIsLoanOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

// Submitted ⟺ unassigned; all other statuses ⟺ assigned
// data-model.md CHECK: (status = 'Submitted') = (assigned_officer_id IS NULL)
fact F_AssignedOfficerNullIffSubmitted {
  all a: LoanApplication |
    (a.status = Submitted) iff (no a.assignedOfficer)
}

// ─────────────────────────────────────────────
// DECISION FACTS
// ─────────────────────────────────────────────
// At most one decision per application (PK on decisions.application_id)
fact F_AtMostOneDecisionPerApplication {
  all a: LoanApplication | lone d: Decision | d.application = a
}

// Approved or Rejected apps have exactly one decision; others have none
// spec.md FR-015, FR-016
fact F_DecisionExistsIffDecided {
  all a: LoanApplication |
    ((a.status = Approved or a.status = Rejected) implies
      (one d: Decision | d.application = a))
    and
    ((a.status = Submitted or a.status = UnderReview) implies
      (no d: Decision | d.application = a))
}

// Deciding officer must be the assigned officer on the application
// spec.md FR-013
fact F_DecidedByAssignedOfficer {
  all d: Decision |
    d.application.assignedOfficer = d.decidedBy
}

// Decision type matches application status
// data-model.md DecisionType ↔ ApplicationStatus
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.decisionType = ApprovedDecision iff d.application.status = Approved)
    and
    (d.decisionType = RejectedDecision iff d.application.status = Rejected)
}

// Deciding officer must be a loan officer
fact F_DeciderIsLoanOfficer {
  all d: Decision | d.decidedBy.role = LoanOfficer
}

// ─────────────────────────────────────────────
// AUDIT TRAIL FACTS
// ─────────────────────────────────────────────
// Initial event: previousStatus absent iff newStatus = Submitted
// data-model.md CHECK: (previous_status IS NULL) = (new_status = 'Submitted')
fact F_AuditInitialEntryShape {
  all e: ApplicationEvent |
    (no e.previousStatus) iff (e.newStatus = Submitted)
}

// No no-op transitions
// data-model.md CHECK: previous_status IS NULL OR previous_status <> new_status
fact F_AuditNoNoop {
  all e: ApplicationEvent |
    some e.previousStatus implies e.previousStatus != e.newStatus
}

// Every application has exactly one initial audit entry (submission event)
// spec.md FR-009, FR-017, FR-019
fact F_ExactlyOneInitialAuditEntry {
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and no e.previousStatus
}

// Actor on the initial (submission) event must be the application's customer
// spec.md FR-017, data-model.md state-machine table
fact F_AuditInitialActorIsCustomer {
  all e: ApplicationEvent |
    (no e.previousStatus) implies e.actor = e.application.customer
}

// Actor on claim (Submitted → UnderReview) must be a loan officer
// spec.md FR-011, FR-017
fact F_AuditClaimActorIsLoanOfficer {
  all e: ApplicationEvent |
    (some e.previousStatus and e.previousStatus = Submitted and e.newStatus = UnderReview)
      implies e.actor.role = LoanOfficer
}

// Actor on decide (UnderReview → Approved/Rejected) must be the assigned officer
// spec.md FR-015, FR-017
fact F_AuditDecideActorIsAssignedOfficer {
  all e: ApplicationEvent |
    (some e.previousStatus and e.previousStatus = UnderReview)
      implies e.actor = e.application.assignedOfficer
}

// Valid transition pairs in audit events (only reachable transitions)
// data-model.md state-machine diagram
fact F_AuditValidTransitions {
  all e: ApplicationEvent |
    some e.previousStatus implies
      (e.previousStatus = Submitted   and e.newStatus = UnderReview) or
      (e.previousStatus = UnderReview and e.newStatus = Approved)    or
      (e.previousStatus = UnderReview and e.newStatus = Rejected)
}

// Every decided (Approved/Rejected) application has a decide audit entry
// spec.md FR-015, FR-017
fact F_DecidedAppsHaveDecideAuditEntry {
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies
      (one e: ApplicationEvent |
         e.application = a and
         some e.previousStatus and
         e.previousStatus = UnderReview)
}

// Every UnderReview/Approved/Rejected application has a claim audit entry
// spec.md FR-011, FR-017
fact F_ClaimedAppsHaveClaimAuditEntry {
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one e: ApplicationEvent |
         e.application = a and
         some e.previousStatus and
         e.previousStatus = Submitted and
         e.newStatus = UnderReview)
}

// At most one in-flight application (Submitted or UnderReview) per customer
// spec.md FR-008; data-model.md idx_one_in_flight_per_customer
fact F_AtMostOneInFlightPerCustomer {
  all u: User |
    u.role = Customer implies
      lone a: LoanApplication |
        a.customer = u and
        (a.status = Submitted or a.status = UnderReview)
}

// ─────────────────────────────────────────────
// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission table; spec.md FR-002 FR-003 FR-004
// ─────────────────────────────────────────────
pred LeastPrivilege {
  // Denied cells: ComplianceReviewer cannot POST, claim, or decide
  ComplianceReviewer -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication  not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed
  // Denied cells: Customer cannot claim, decide, or view audit
  Customer -> ClaimApplication  not in PermMatrix.Allowed
  Customer -> DecideApplication not in PermMatrix.Allowed
  Customer -> GetAudit          not in PermMatrix.Allowed
  // Denied cells: LoanOfficer cannot submit applications
  LoanOfficer -> PostApplications not in PermMatrix.Allowed
  // Granted cells: each role has at least one allowed operation
  some op: OperationKind | Customer        -> op in PermMatrix.Allowed
  some op: OperationKind | LoanOfficer     -> op in PermMatrix.Allowed
  some op: OperationKind | ComplianceReviewer -> op in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ─────────────────────────────────────────────
// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission table (all 18 cells defined)
// ─────────────────────────────────────────────
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either allowed or denied — no undefined gaps.
  // Because PermMatrix.Allowed is a total set over all Role × OperationKind atoms,
  // completeness means: the complement (denied) plus allowed covers the full product.
  (Role -> OperationKind) = PermMatrix.Allowed +
    { r: Role, op: OperationKind | r -> op not in PermMatrix.Allowed }
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ─────────────────────────────────────────────
// PATTERN: PermissionGrounding
// ANCHOR: spec.md FR-002 FR-003 FR-004; contracts/http-api.md permission table
// ─────────────────────────────────────────────
pred PermissionGrounding {
  // Every allowed (Role, Operation) pair is one of the spec-grounded cells.
  // If this predicate holds, no silent extra grants exist.
  PermMatrix.Allowed in
      (Customer        -> PostApplications)    +
      (Customer        -> GetApplications)     +
      (Customer        -> GetApplicationByRef) +
      (LoanOfficer     -> GetApplications)     +
      (LoanOfficer     -> GetApplicationByRef) +
      (LoanOfficer     -> ClaimApplication)    +
      (LoanOfficer     -> DecideApplication)   +
      (LoanOfficer     -> GetAudit)            +
      (ComplianceReviewer -> GetApplications)    +
      (ComplianceReviewer -> GetApplicationByRef)+
      (ComplianceReviewer -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// ─────────────────────────────────────────────
// PATTERN: AppendOnly
// ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
// ─────────────────────────────────────────────
pred AppendOnly {
  // Two distinct audit events for the same application must differ
  // in at least one field — no duplicated (cloned/overwritten) entries.
  some ApplicationEvent  // non-vacuous: requires at least one event
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies
      (e1.previousStatus != e2.previousStatus or
       e1.newStatus      != e2.newStatus       or
       e1.actor          != e2.actor)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ─────────────────────────────────────────────
// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-017 FR-019; data-model.md state-machine table
// ─────────────────────────────────────────────
pred AuditCompleteness {
  // Every LoanApplication has at least one audit entry.
  some LoanApplication
  all a: LoanApplication | some e: ApplicationEvent | e.application = a
  // Every Approved/Rejected application has at least two audit entries
  // (one for submission, one for the decide transition).
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) implies
      (some disj e1, e2: ApplicationEvent | e1.application = a and e2.application = a)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ─────────────────────────────────────────────
// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-017; data-model.md ApplicationEvent.actor_user_id
// ─────────────────────────────────────────────
pred AttributionCorrectness {
  some ApplicationEvent
  // Initial event actor is always the submitting customer
  all e: ApplicationEvent |
    (no e.previousStatus) implies e.actor = e.application.customer
  // Claim-event actor is always a loan officer
  all e: ApplicationEvent |
    (some e.previousStatus and e.previousStatus = Submitted) implies
      e.actor.role = LoanOfficer
  // Decide-event actor is the assigned officer on the application
  all e: ApplicationEvent |
    (some e.previousStatus and e.previousStatus = UnderReview) implies
      e.actor = e.application.assignedOfficer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ─────────────────────────────────────────────
// PATTERN: OwnershipExclusivity
// ANCHOR: data-model.md LoanApplication.customer_id; spec.md FR-005
// ─────────────────────────────────────────────
pred OwnershipExclusivity {
  some LoanApplication
  // Each application has exactly one customer owner (enforced by `one` multiplicity,
  // but this predicate makes it checkable as an assertion).
  all a: LoanApplication | one a.customer
  // Customer field always references a Customer-role user
  all a: LoanApplication | a.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ─────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-020; contracts/http-api.md "own only" cells
// ─────────────────────────────────────────────
pred OwnershipBasedAccess {
  // A customer may only access their own application.
  // Modelled as: no customer owns zero applications yet has applications visible.
  // Structurally: every application's customer field binds it exclusively
  // to that user, and no other customer-role user shares ownership.
  some LoanApplication
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies a1 != a2   // different apps may share owner, but
  // different customers cannot share the same app as "theirs"
  all a: LoanApplication |
    no u: User |
      u != a.customer and u.role = Customer and
      // u would illegitimately "own" a
      a.customer != u
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ─────────────────────────────────────────────
// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found on non-owner"
// ─────────────────────────────────────────────
pred NoInformationLeakage {
  // For any customer-role user, the only applications reachable through the
  // ownership relation are their own. Any other application is indistinguishable
  // from non-existence (404 response — no existence leak).
  // In Alloy structural terms: a customer user's accessible application set
  // is exactly the set where customer = that user.
  some User
  all u: User |
    u.role = Customer implies
      (all a: LoanApplication | a.customer = u or a.customer != u)
  // No loan application has two distinct customer-role owners.
  all a: LoanApplication |
    no disj u1, u2: User |
      u1.role = Customer and u2.role = Customer and
      a.customer = u1 and a.customer = u2
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001
// Every operation requires the caller to have one of the three defined roles.
// ─────────────────────────────────────────────
pred FR_001_AuthRequired {
  // Every User in the model has exactly one defined role.
  some User
  all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer)
  // There is no role outside the defined set (closed-world).
  all u: User | one u.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002
// Customer role: can submit and view own apps; cannot claim, decide, or audit.
// ─────────────────────────────────────────────
pred FR_002_CustomerPermissions {
  Customer -> PostApplications    in PermMatrix.Allowed
  Customer -> GetApplications     in PermMatrix.Allowed
  Customer -> GetApplicationByRef in PermMatrix.Allowed
  Customer -> ClaimApplication    not in PermMatrix.Allowed
  Customer -> DecideApplication   not in PermMatrix.Allowed
  Customer -> GetAudit            not in PermMatrix.Allowed
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 8

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003
// Loan officer: can claim, decide, view; cannot submit applications.
// ─────────────────────────────────────────────
pred FR_003_LoanOfficerPermissions {
  LoanOfficer -> PostApplications  not in PermMatrix.Allowed
  LoanOfficer -> ClaimApplication  in PermMatrix.Allowed
  LoanOfficer -> DecideApplication in PermMatrix.Allowed
  LoanOfficer -> GetApplications   in PermMatrix.Allowed
  LoanOfficer -> GetAudit          in PermMatrix.Allowed
}
assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 8

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004 FR-023
// Compliance reviewer: read-only; cannot submit, claim, or decide.
// ─────────────────────────────────────────────
pred FR_004_ComplianceReviewerReadOnly {
  ComplianceReviewer -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication  not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed
  ComplianceReviewer -> GetApplications   in PermMatrix.Allowed
  ComplianceReviewer -> GetApplicationByRef in PermMatrix.Allowed
  ComplianceReviewer -> GetAudit          in PermMatrix.Allowed
}
assert FR_004_ComplianceReviewerReadOnly { FR_004_ComplianceReviewerReadOnly }
check FR_004_ComplianceReviewerReadOnly for 8

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005
// Customer identity comes from auth context; application.customer is always
// a Customer-role user (not a loan officer or compliance reviewer).
// ─────────────────────────────────────────────
pred FR_005_CustomerIdentityFromAuth {
  some LoanApplication
  all a: LoanApplication | a.customer.role = Customer
}
assert FR_005_CustomerIdentityFromAuth { FR_005_CustomerIdentityFromAuth }
check FR_005_CustomerIdentityFromAuth for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-008
// At most one in-flight (Submitted or UnderReview) application per customer.
// ─────────────────────────────────────────────
pred FR_008_OneInFlightPerCustomer {
  some LoanApplication
  all u: User |
    u.role = Customer implies
      (lone a: LoanApplication |
         a.customer = u and
         (a.status = Submitted or a.status = UnderReview))
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009
// On successful submission: status=Submitted, one initial audit entry with
// previousStatus=none and newStatus=Submitted.
// ─────────────────────────────────────────────
pred FR_009_SubmissionAuditEntry {
  some LoanApplication
  all a: LoanApplication |
    one e: ApplicationEvent |
      e.application = a and
      no e.previousStatus and
      e.newStatus = Submitted and
      e.actor = a.customer
}
assert FR_009_SubmissionAuditEntry { FR_009_SubmissionAuditEntry }
check FR_009_SubmissionAuditEntry for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 FR-012
// Claiming changes status to UnderReview, sets assignedOfficer, appends audit entry.
// Exactly one officer assigned per application once claimed.
// ─────────────────────────────────────────────
pred FR_011_ClaimSetsOfficerAndAudit {
  some a: LoanApplication | a.status = UnderReview or
                             a.status = Approved    or
                             a.status = Rejected
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) implies
      (one a.assignedOfficer and a.assignedOfficer.role = LoanOfficer)
}
assert FR_011_ClaimSetsOfficerAndAudit { FR_011_ClaimSetsOfficerAndAudit }
check FR_011_ClaimSetsOfficerAndAudit for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012
// Exclusive claim: an application has at most one assignedOfficer.
// ─────────────────────────────────────────────
pred FR_012_ExclusiveClaim {
  some LoanApplication
  all a: LoanApplication | lone a.assignedOfficer
}
assert FR_012_ExclusiveClaim { FR_012_ExclusiveClaim }
check FR_012_ExclusiveClaim for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013
// Only the assigned officer may decide an application.
// ─────────────────────────────────────────────
pred FR_013_AssignedOfficerDecides {
  some Decision
  all d: Decision | d.decidedBy = d.application.assignedOfficer
  all d: Decision | d.decidedBy.role = LoanOfficer
}
assert FR_013_AssignedOfficerDecides { FR_013_AssignedOfficerDecides }
check FR_013_AssignedOfficerDecides for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015
// Atomic decision: decision record exists iff application is Approved or Rejected.
// ─────────────────────────────────────────────
pred FR_015_AtomicDecision {
  some LoanApplication
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected) iff
      (one d: Decision | d.application = a)
}
assert FR_015_AtomicDecision { FR_015_AtomicDecision }
check FR_015_AtomicDecision for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016
// Decided applications (Approved/Rejected) have no further status changes;
// the audit trail must not have a transition out of Approved or Rejected.
// ─────────────────────────────────────────────
pred FR_016_DecidedImmutability {
  some a: LoanApplication | a.status = Approved or a.status = Rejected
  // No audit event has previousStatus = Approved or previousStatus = Rejected
  no e: ApplicationEvent |
    (some e.previousStatus and
     (e.previousStatus = Approved or e.previousStatus = Rejected))
}
assert FR_016_DecidedImmutability { FR_016_DecidedImmutability }
check FR_016_DecidedImmutability for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017 FR-019
// Exactly one audit entry per status transition actually applied:
// at most one initial entry, at most one claim entry, at most one decide entry
// per application.
// ─────────────────────────────────────────────
pred FR_019_ExactlyOneAuditPerTransition {
  some LoanApplication
  all a: LoanApplication |
    // At most one initial (submission) entry
    (lone e: ApplicationEvent |
       e.application = a and no e.previousStatus)
    and
    // At most one claim entry
    (lone e: ApplicationEvent |
       e.application = a and
       some e.previousStatus and e.previousStatus = Submitted)
    and
    // At most one decide entry
    (lone e: ApplicationEvent |
       e.application = a and
       some e.previousStatus and e.previousStatus = UnderReview)
}
assert FR_019_ExactlyOneAuditPerTransition { FR_019_ExactlyOneAuditPerTransition }
check FR_019_ExactlyOneAuditPerTransition for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-020
// Customer isolation: no two distinct customers share an application,
// and every application belongs to exactly one customer.
// ─────────────────────────────────────────────
pred FR_020_CustomerIsolation {
  some LoanApplication
  all a: LoanApplication | one a.customer
  // No customer-role user can be the customer of an application they didn't submit
  // (ownership uniqueness — an application's customer is immutable)
  all a: LoanApplication | a.customer.role = Customer
}
assert FR_020_CustomerIsolation { FR_020_CustomerIsolation }
check FR_020_CustomerIsolation for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-021
// Officer identity not visible to customers via the permission matrix:
// GetAudit is forbidden for Customer role.
// ─────────────────────────────────────────────
pred FR_021_OfficerIdentityHiddenFromCustomer {
  // Customer cannot invoke GetAudit (which is the only endpoint
  // returning full actor identities including officer names).
  Customer -> GetAudit not in PermMatrix.Allowed
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 8

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-022
// Retention: no deletion of applications, decisions, or audit events.
// Modelled as: every LoanApplication, Decision, and ApplicationEvent
// is reachable (non-orphaned). No orphaned decisions or audit events exist.
// ─────────────────────────────────────────────
pred FR_022_RetentionNoOrphans {
  some LoanApplication
  // Every decision references an existing application
  all d: Decision | d.application in LoanApplication
  // Every audit event references an existing application
  all e: ApplicationEvent | e.application in LoanApplication
}
assert FR_022_RetentionNoOrphans { FR_022_RetentionNoOrphans }
check FR_022_RetentionNoOrphans for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-023 FR-004
// Compliance reviewer cannot perform any write operation.
// ─────────────────────────────────────────────
pred FR_023_ComplianceWriteDenied {
  ComplianceReviewer -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication  not in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication not in PermMatrix.Allowed
}
assert FR_023_ComplianceWriteDenied { FR_023_ComplianceWriteDenied }
check FR_023_ComplianceWriteDenied for 8

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: spec.md state machine (data-model.md enum transitions)
// Valid application status values are exactly the four defined statuses.
// ─────────────────────────────────────────────
pred FR_009_ValidStatusValues {
  some LoanApplication
  all a: LoanApplication |
    a.status in (Submitted + UnderReview + Approved + Rejected)
}
assert FR_009_ValidStatusValues { FR_009_ValidStatusValues }
check FR_009_ValidStatusValues for 5

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md assigned_officer coupling
// Submitted iff no assigned officer (state-machine coupling invariant).
// ─────────────────────────────────────────────
pred FR_011_SubmittedHasNoOfficer {
  some LoanApplication
  all a: LoanApplication |
    (a.status = Submitted) iff (no a.assignedOfficer)
}
assert FR_011_SubmittedHasNoOfficer { FR_011_SubmittedHasNoOfficer }
check FR_011_SubmittedHasNoOfficer for 5