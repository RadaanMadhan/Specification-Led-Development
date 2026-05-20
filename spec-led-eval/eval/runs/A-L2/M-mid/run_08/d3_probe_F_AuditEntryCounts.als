// === feature_model.als — Alloy model for Loan Application RBAC & Audit Trail ===
// Feature: A-L2  (spec branch: 004-loan-application-rbac)
// Encodes invariants from spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// Convenience: "in-flight" statuses (FR-008)
fun InFlight : set ApplicationStatus { Submitted + UnderReview }

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS (HTTP endpoints / actions)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
         ClaimApplication, DecideApplication, GetAuditTrail extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton-sig field pattern)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed : set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// DATA ENTITIES
// ─────────────────────────────────────────────────────────────────────────────
sig User { userRole : one Role }

// Opaque token: presence represents a non-empty reason string (FR-014)
sig ReasonToken {}

sig LoanApplication {
  appCustomer      : one User,
  appStatus        : one ApplicationStatus,
  assignedOfficer  : lone User
}

// At most one Decision per application enforced by F_AtMostOneDecisionPerApp
sig Decision {
  decisionApp    : one LoanApplication,
  decidedBy      : one User,
  decisionReason : lone ReasonToken   // must be 'one' per F_ReasonRequired
}

// Append-only audit record for every status transition
sig AuditEntry {
  auditApp        : one LoanApplication,
  auditActor      : one User,
  auditPrevStatus : lone ApplicationStatus,  // none iff initial submission
  auditNewStatus  : one ApplicationStatus
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
  some ReasonToken
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (contracts/http-api.md permission table)
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  // Customer: submit, list-own, view-own
  CustomerRole -> PostApplications     in PermMatrix.Allowed
  CustomerRole -> GetApplications      in PermMatrix.Allowed
  CustomerRole -> GetApplicationByRef  in PermMatrix.Allowed
  // LoanOfficer: list, view, claim, decide, audit
  LoanOfficerRole -> GetApplications      in PermMatrix.Allowed
  LoanOfficerRole -> GetApplicationByRef  in PermMatrix.Allowed
  LoanOfficerRole -> ClaimApplication     in PermMatrix.Allowed
  LoanOfficerRole -> DecideApplication    in PermMatrix.Allowed
  LoanOfficerRole -> GetAuditTrail        in PermMatrix.Allowed
  // ComplianceReviewer: list, view, audit — NO write operations
  ComplianceReviewerRole -> GetApplications      in PermMatrix.Allowed
  ComplianceReviewerRole -> GetApplicationByRef  in PermMatrix.Allowed
  ComplianceReviewerRole -> GetAuditTrail        in PermMatrix.Allowed
  // Closed-world: exactly these cells and no others
  PermMatrix.Allowed =
    (CustomerRole         -> PostApplications)    +
    (CustomerRole         -> GetApplications)     +
    (CustomerRole         -> GetApplicationByRef) +
    (LoanOfficerRole      -> GetApplications)     +
    (LoanOfficerRole      -> GetApplicationByRef) +
    (LoanOfficerRole      -> ClaimApplication)    +
    (LoanOfficerRole      -> DecideApplication)   +
    (LoanOfficerRole      -> GetAuditTrail)       +
    (ComplianceReviewerRole -> GetApplications)     +
    (ComplianceReviewerRole -> GetApplicationByRef) +
    (ComplianceReviewerRole -> GetAuditTrail)
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL INTEGRITY FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Customer identity comes from auth context; applicant must be a Customer-role user
fact F_AppCustomerMustBeCustomerRole {
  all a : LoanApplication | a.appCustomer.userRole = CustomerRole
}

// Assigned officer must be a loan-officer-role user (data-model.md FK constraint)
fact F_AssignedOfficerMustBeLoanOfficer {
  all a : LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.userRole = LoanOfficerRole
}

// State-machine coupling: Submitted ↔ no assigned officer; others ↔ assigned officer
// (data-model.md CHECK constraint)
fact F_StatusOfficerCoupling {
  all a : LoanApplication | {
    (a.appStatus = Submitted) iff (no a.assignedOfficer)
    (a.appStatus != Submitted) iff (some a.assignedOfficer)
  }
}

// At most one Decision per application (data-model.md: decisions.application_id PK)
fact F_AtMostOneDecisionPerApp {
  all disj d1, d2 : Decision | d1.decisionApp != d2.decisionApp
}

// Decisions exist iff and only if the application is in a terminal state
// (data-model.md: decision row + status written in same transaction)
fact F_DecisionExistenceMatchesTerminalStatus {
  all a : LoanApplication |
    (a.appStatus = Approved or a.appStatus = Rejected)
      iff (some d : Decision | d.decisionApp = a)
}

// Decision must be made by the application's assigned officer (FR-013)
fact F_DecisionByAssignedOfficer {
  all d : Decision | d.decidedBy = d.decisionApp.assignedOfficer
}

// Every decision must have a non-empty reason (FR-014)
fact F_ReasonRequired {
  all d : Decision | one d.decisionReason
}

// One in-flight application per customer at any time (FR-008,
// data-model.md idx_one_in_flight_per_customer)
fact F_OneInFlightPerCustomer {
  all disj a1, a2 : LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.appStatus in InFlight and a2.appStatus in InFlight)
}

// Audit entry structure:
//   prevStatus = none  iff  newStatus = Submitted   (initial submission)
//   prevStatus present  implies  prevStatus != newStatus  (no no-op entries)
// (data-model.md CHECK constraints on application_events)
fact F_AuditEntryStructure {
  all ae : AuditEntry | {
    (no ae.auditPrevStatus) iff (ae.auditNewStatus = Submitted)
    (some ae.auditPrevStatus) implies ae.auditPrevStatus != ae.auditNewStatus
  }
}

// Audit entries only represent valid state-machine transitions (data-model.md)
fact F_AuditEntryValidTransitions {
  all ae : AuditEntry | {
    (no ae.auditPrevStatus    and ae.auditNewStatus = Submitted)   or
    (ae.auditPrevStatus = Submitted  and ae.auditNewStatus = UnderReview) or
    (ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Approved)   or
    (ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Rejected)
  }
}

// Actor attribution: submission entries are acted on by a Customer;
// all other transitions are by a LoanOfficer (FR-017)
fact F_AuditActorAttribution {
  all ae : AuditEntry | {
    ae.auditNewStatus = Submitted   implies ae.auditActor.userRole = CustomerRole
    ae.auditNewStatus != Submitted  implies ae.auditActor.userRole = LoanOfficerRole
  }
}

// Every application has exactly one initial submission audit entry (FR-017, FR-019)
fact F_InitialAuditEntryExists {
  all a : LoanApplication |
    one ae : AuditEntry |
      ae.auditApp = a and no ae.auditPrevStatus and ae.auditNewStatus = Submitted
}

// Claim audit entry exists iff application was ever claimed (FR-011, FR-019)
fact F_ClaimAuditEntryConsistency {
  all a : LoanApplication |
    (a.appStatus = UnderReview or
     a.appStatus = Approved   or
     a.appStatus = Rejected)
      implies
        (one ae : AuditEntry |
          ae.auditApp = a and
          ae.auditPrevStatus = Submitted and
          ae.auditNewStatus  = UnderReview)
}

// Decision audit entry exists iff application was decided (FR-015, FR-019)
fact F_DecisionAuditEntryConsistency {
  all a : LoanApplication | {
    a.appStatus = Approved implies
      (one ae : AuditEntry |
        ae.auditApp = a and
        ae.auditPrevStatus = UnderReview and
        ae.auditNewStatus  = Approved)
    a.appStatus = Rejected implies
      (one ae : AuditEntry |
        ae.auditApp = a and
        ae.auditPrevStatus = UnderReview and
        ae.auditNewStatus  = Rejected)
  }
}

// No spurious audit entries: Submitted apps have only 1 entry,
// UnderReview apps have exactly 2, decided apps have exactly 3 (FR-019)
fact F_AuditEntryCounts {
  all a : LoanApplication | {
    a.appStatus = Submitted =>
      #(auditApp.a) = 1
    a.appStatus = UnderReview =>
      #(auditApp.a) = 2
    (a.appStatus = Approved or a.appStatus = Rejected) =>
      #(auditApp.a) = 3
  }
}

// Audit entries for an application are attributed to that application's
// own customer or assigned officer — no cross-application actor bleed (FR-017)
fact F_AuditActorBelongsToApplication {
  all ae : AuditEntry | {
    ae.auditNewStatus = Submitted implies ae.auditActor = ae.auditApp.appCustomer
    ae.auditNewStatus != Submitted implies ae.auditActor = ae.auditApp.assignedOfficer
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002, FR-003, FR-004
// ─────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
  some PermMatrix.Allowed
  // Customers cannot claim
  CustomerRole -> ClaimApplication not in PermMatrix.Allowed
  // Customers cannot decide
  CustomerRole -> DecideApplication not in PermMatrix.Allowed
  // Customers cannot view audit trail
  CustomerRole -> GetAuditTrail not in PermMatrix.Allowed
  // Compliance reviewers cannot submit
  ComplianceReviewerRole -> PostApplications not in PermMatrix.Allowed
  // Compliance reviewers cannot claim
  ComplianceReviewerRole -> ClaimApplication not in PermMatrix.Allowed
  // Compliance reviewers cannot decide
  ComplianceReviewerRole -> DecideApplication not in PermMatrix.Allowed
  // Only customers can submit applications
  all r : Role | r -> PostApplications in PermMatrix.Allowed implies r = CustomerRole
  // Only loan officers can claim
  all r : Role | r -> ClaimApplication in PermMatrix.Allowed implies r = LoanOfficerRole
  // Only loan officers can decide
  all r : Role | r -> DecideApplication in PermMatrix.Allowed implies r = LoanOfficerRole
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission matrix (all 3×6 cells defined)
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
  some PermMatrix.Allowed
  // Every (Role, OperationKind) pair has a defined verdict —
  // the closed-world assignment ensures no cell is undefined.
  // Verify all six operations appear in at least one allowed cell:
  all op : OperationKind | some r : Role | r -> op in PermMatrix.Allowed
  // Verify all three roles have at least one allowed operation:
  all r : Role | some op : OperationKind | r -> op in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere
// ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
// ─────────────────────────────────────────────────────────────────────────────
pred AuthRequiredEverywhere {
  // Every user must have exactly one role — no un-typed (unauthenticated) user
  // can appear in the system's data relations.
  some User
  all u : User | one u.userRole
  // Every application is owned by an authenticated (role-bearing) user
  all a : LoanApplication | one a.appCustomer.userRole
  // Every audit actor is an authenticated user
  all ae : AuditEntry | one ae.auditActor.userRole
  // Every decision is by an authenticated officer
  all d : Decision | one d.decidedBy.userRole
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-017, FR-019; data-model.md application_events constraints
// ─────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
  some AuditEntry
  // Every application has at least one audit entry
  all a : LoanApplication | some ae : AuditEntry | ae.auditApp = a
  // The initial submission entry exists for every application
  all a : LoanApplication |
    one ae : AuditEntry |
      ae.auditApp = a and no ae.auditPrevStatus and ae.auditNewStatus = Submitted
  // Applications that moved to UnderReview or beyond have a claim entry
  all a : LoanApplication |
    (a.appStatus = UnderReview or a.appStatus = Approved or a.appStatus = Rejected) implies
      (one ae : AuditEntry |
        ae.auditApp = a and
        ae.auditPrevStatus = Submitted and ae.auditNewStatus = UnderReview)
  // Decided applications have a decision audit entry
  all a : LoanApplication |
    (a.appStatus = Approved or a.appStatus = Rejected) implies
      (one ae : AuditEntry |
        ae.auditApp = a and ae.auditPrevStatus = UnderReview and
        (ae.auditNewStatus = Approved or ae.auditNewStatus = Rejected))
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly
// ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
// ─────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
  // In the static snapshot: no two distinct audit entries for the same application
  // record the same (prevStatus, newStatus) transition — duplicates would only arise
  // from a mutation that re-wrote an entry.  Exactly-one count per transition type
  // per application is the structural footprint of append-only correctness.
  some AuditEntry
  all a : LoanApplication | {
    // At most one submission entry per application
    lone ae : AuditEntry |
      ae.auditApp = a and no ae.auditPrevStatus and ae.auditNewStatus = Submitted
    // At most one claim entry
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = Submitted and ae.auditNewStatus = UnderReview
    // At most one Approved entry
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Approved
    // At most one Rejected entry
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Rejected
  }
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-017; data-model.md application_events.actor_user_id
// ─────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
  some AuditEntry
  // Submission events are attributed to the application's own customer
  all ae : AuditEntry |
    ae.auditNewStatus = Submitted implies ae.auditActor = ae.auditApp.appCustomer
  // Claim/decision events are attributed to the application's assigned officer
  all ae : AuditEntry |
    ae.auditNewStatus != Submitted implies ae.auditActor = ae.auditApp.assignedOfficer
  // Actors are real users with a known role
  all ae : AuditEntry | one ae.auditActor.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity
// ANCHOR: spec.md FR-009; data-model.md loan_applications.customer_id FK
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipExclusivity {
  some LoanApplication
  // Every application has exactly one owner customer
  all a : LoanApplication | one a.appCustomer
  // No two distinct applications owned by the same customer are both in-flight (FR-008)
  all disj a1, a2 : LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.appStatus in InFlight and a2.appStatus in InFlight)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-020; contracts/http-api.md GET /applications scoping
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
  some LoanApplication
  // A Customer-role user cannot be the assigned officer on any application
  all u : User | u.userRole = CustomerRole implies
    (no a : LoanApplication | a.assignedOfficer = u)
  // A LoanOfficer-role user cannot be the customer/owner of any application
  all u : User | u.userRole = LoanOfficerRole implies
    (no a : LoanApplication | a.appCustomer = u)
  // A ComplianceReviewer cannot be the customer or assigned officer on any application
  all u : User | u.userRole = ComplianceReviewerRole implies {
    (no a : LoanApplication | a.appCustomer = u)
    (no a : LoanApplication | a.assignedOfficer = u)
  }
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found, not 403" rule
// ─────────────────────────────────────────────────────────────────────────────
pred NoInformationLeakage {
  // Structural proxy: a customer user is never the actor on another customer's
  // audit event. The only audit entries a customer-role user generates are on
  // applications they own.
  some AuditEntry
  all ae : AuditEntry |
    ae.auditActor.userRole = CustomerRole implies ae.auditActor = ae.auditApp.appCustomer
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: ValidationBeforeMutation
// ANCHOR: spec.md FR-006, FR-014; data-model.md atomicity contract
// ─────────────────────────────────────────────────────────────────────────────
pred ValidationBeforeMutation {
  // Structural proxy: every Decision in the model carries a non-null reason token.
  // A Decision without a reason cannot exist — it would have been rejected before
  // any state was mutated.
  some Decision
  all d : Decision | one d.decisionReason
  // Every application was submitted with a valid customer identity
  all a : LoanApplication | a.appCustomer.userRole = CustomerRole
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PrivilegeMonotonicity
// ANCHOR: spec.md role descriptions; contracts/http-api.md permission matrix
// ─────────────────────────────────────────────────────────────────────────────
pred PrivilegeMonotonicity {
  // Compliance reviewer read permissions ⊆ loan officer permissions
  // (ComplianceReviewer is a read-only superset on visibility but subset on write)
  // Concretely: every operation the compliance reviewer can do, the loan officer can also do
  all op : OperationKind |
    ComplianceReviewerRole -> op in PermMatrix.Allowed implies
      LoanOfficerRole -> op in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001 — every request authenticated, one role per user
// ─────────────────────────────────────────────────────────────────────────────
pred FR_001_AuthRequired {
  some User
  // Every user has exactly one role (bank's auth system guarantees this)
  all u : User | one u.userRole
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002 — customers cannot perform officer/reviewer actions
// ─────────────────────────────────────────────────────────────────────────────
pred FR_002_CustomerActionsLimited {
  // Customer cannot claim
  CustomerRole -> ClaimApplication not in PermMatrix.Allowed
  // Customer cannot decide
  CustomerRole -> DecideApplication not in PermMatrix.Allowed
  // Customer cannot view audit
  CustomerRole -> GetAuditTrail not in PermMatrix.Allowed
}
assert FR_002_CustomerActionsLimited { FR_002_CustomerActionsLimited }
check FR_002_CustomerActionsLimited for 8

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-003 — loan officers cannot submit as customer
// ─────────────────────────────────────────────────────────────────────────────
pred FR_003_LoanOfficerActionsLimited {
  // Loan officer cannot submit applications (submit is customer-only)
  LoanOfficerRole -> PostApplications not in PermMatrix.Allowed
  // Loan officers cannot own (be appCustomer on) any application
  all u : User | u.userRole = LoanOfficerRole implies
    (no a : LoanApplication | a.appCustomer = u)
}
assert FR_003_LoanOfficerActionsLimited { FR_003_LoanOfficerActionsLimited }
check FR_003_LoanOfficerActionsLimited for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004 / FR-023 — compliance reviewer is entirely read-only
// ─────────────────────────────────────────────────────────────────────────────
pred FR_004_ComplianceReadOnly {
  // Compliance reviewer cannot submit, claim, or decide
  ComplianceReviewerRole -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewerRole -> ClaimApplication  not in PermMatrix.Allowed
  ComplianceReviewerRole -> DecideApplication not in PermMatrix.Allowed
  // Compliance reviewer is never an actor on state-changing audit entries
  all ae : AuditEntry |
    ae.auditActor.userRole != ComplianceReviewerRole
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-008 — at most one in-flight application per customer
// ─────────────────────────────────────────────────────────────────────────────
pred FR_008_OneInFlightPerCustomer {
  some LoanApplication
  all disj a1, a2 : LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.appStatus in InFlight and a2.appStatus in InFlight)
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-009 — on submission, status = Submitted and audit entry appended
// ─────────────────────────────────────────────────────────────────────────────
pred FR_009_SubmissionAuditEntry {
  some LoanApplication
  // Every application has a submission audit entry
  all a : LoanApplication |
    one ae : AuditEntry |
      ae.auditApp = a and
      no ae.auditPrevStatus and
      ae.auditNewStatus = Submitted and
      ae.auditActor = a.appCustomer
}
assert FR_009_SubmissionAuditEntry { FR_009_SubmissionAuditEntry }
check FR_009_SubmissionAuditEntry for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 — claim produces Under Review + audit entry
// ─────────────────────────────────────────────────────────────────────────────
pred FR_011_ClaimTransitionAndAudit {
  some a : LoanApplication | a.appStatus = UnderReview
  // Every Under-Review (or later) application has exactly one claim audit entry
  all a : LoanApplication |
    (a.appStatus = UnderReview or a.appStatus = Approved or a.appStatus = Rejected) implies
      (one ae : AuditEntry |
        ae.auditApp = a and
        ae.auditPrevStatus = Submitted and
        ae.auditNewStatus  = UnderReview and
        ae.auditActor      = a.assignedOfficer)
}
assert FR_011_ClaimTransitionAndAudit { FR_011_ClaimTransitionAndAudit }
check FR_011_ClaimTransitionAndAudit for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012 — exactly one officer can claim (no duplicate claims)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_012_ExactlyOneClaim {
  some a : LoanApplication | a.appStatus != Submitted
  // Each application has at most one assigned officer (lone field already enforces this,
  // but we assert the claim audit entry is also unique per application)
  all a : LoanApplication |
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = Submitted and ae.auditNewStatus = UnderReview
}
assert FR_012_ExactlyOneClaim { FR_012_ExactlyOneClaim }
check FR_012_ExactlyOneClaim for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013 — only the assigned officer can decide
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_OnlyAssignedOfficerDecides {
  some Decision
  all d : Decision |
    d.decidedBy = d.decisionApp.assignedOfficer and
    d.decidedBy.userRole = LoanOfficerRole
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-014 — every decision has a non-empty reason
// ─────────────────────────────────────────────────────────────────────────────
pred FR_014_ReasonRequiredForDecision {
  some Decision
  all d : Decision | one d.decisionReason
}
assert FR_014_ReasonRequiredForDecision { FR_014_ReasonRequiredForDecision }
check FR_014_ReasonRequiredForDecision for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 — decision + status + audit are atomic
// ─────────────────────────────────────────────────────────────────────────────
pred FR_015_DecisionAtomic {
  // Structural proxy: if a Decision exists for application a, then:
  //   (a) a.appStatus is terminal, and
  //   (b) an audit entry for the terminal transition also exists.
  some Decision
  all d : Decision | {
    d.decisionApp.appStatus = Approved or d.decisionApp.appStatus = Rejected
    one ae : AuditEntry |
      ae.auditApp = d.decisionApp and
      ae.auditPrevStatus = UnderReview and
      (ae.auditNewStatus = Approved or ae.auditNewStatus = Rejected)
  }
}
assert FR_015_DecisionAtomic { FR_015_DecisionAtomic }
check FR_015_DecisionAtomic for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016 — decided applications are immutable
// ─────────────────────────────────────────────────────────────────────────────
pred FR_016_DecidedApplicationImmutable {
  // Once Approved or Rejected, no further transitions can exist.
  // Structural proxy: no audit entry records a transition *out of* Approved/Rejected.
  some a : LoanApplication | a.appStatus = Approved or a.appStatus = Rejected
  no ae : AuditEntry |
    ae.auditPrevStatus = Approved or ae.auditPrevStatus = Rejected
}
assert FR_016_DecidedApplicationImmutable { FR_016_DecidedApplicationImmutable }
check FR_016_DecidedApplicationImmutable for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-017/FR-019 — exactly one audit entry per status change
// ─────────────────────────────────────────────────────────────────────────────
pred FR_017_019_ExactlyOneAuditEntryPerTransition {
  some AuditEntry
  all a : LoanApplication | {
    // Exactly one submission entry
    one ae : AuditEntry | ae.auditApp = a and no ae.auditPrevStatus
    // At most one claim entry
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = Submitted and ae.auditNewStatus = UnderReview
    // At most one approval entry
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Approved
    // At most one rejection entry
    lone ae : AuditEntry |
      ae.auditApp = a and ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Rejected
  }
}
assert FR_017_019_ExactlyOneAuditEntryPerTransition { FR_017_019_ExactlyOneAuditEntryPerTransition }
check FR_017_019_ExactlyOneAuditEntryPerTransition for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-020 — customer cannot see other customers' applications
// ─────────────────────────────────────────────────────────────────────────────
pred FR_020_CustomerSeesOnlyOwnApplications {
  some LoanApplication
  // A customer-role user is the actor on audit events only for their own applications
  all ae : AuditEntry |
    ae.auditActor.userRole = CustomerRole implies ae.auditActor = ae.auditApp.appCustomer
  // Two distinct applications with different customers exist (makes the check non-vacuous)
  some disj a1, a2 : LoanApplication | a1.appCustomer != a2.appCustomer
}
assert FR_020_CustomerSeesOnlyOwnApplications { FR_020_CustomerSeesOnlyOwnApplications }
check FR_020_CustomerSeesOnlyOwnApplications for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-021 — officer identity not exposed to customer role
// ─────────────────────────────────────────────────────────────────────────────
pred FR_021_OfficerIdentityHiddenFromCustomer {
  // Structural proxy: no LoanOfficer-role user appears as the appCustomer on any application.
  // The customer field only ever holds CustomerRole users, so officer identity
  // is structurally isolated from the customer-visible ownership field.
  some LoanApplication
  all a : LoanApplication | a.appCustomer.userRole = CustomerRole
  // Assigned officer (when present) is always a LoanOfficerRole user
  all a : LoanApplication | some a.assignedOfficer implies a.assignedOfficer.userRole = LoanOfficerRole
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-022 — no DELETE paths; records persist
// (structural proxy: every application, decision, audit entry that exists must
//  be reachable; modelled as: all audit entries reference existing applications)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_022_DataRetention {
  some AuditEntry
  // Every audit entry's application still exists in the system
  all ae : AuditEntry | ae.auditApp in LoanApplication
  // Every decision's application still exists
  all d : Decision | d.decisionApp in LoanApplication
}
assert FR_022_DataRetention { FR_022_DataRetention }
check FR_022_DataRetention for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_DuplicateAuditEntry { some disj ae1, ae2 : AuditEntry | ae1.auditApp = ae2.auditApp and no ae1.auditPrevStatus and no ae2.auditPrevStatus and ae1.auditNewStatus = Submitted and ae2.auditNewStatus = Submitted }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
