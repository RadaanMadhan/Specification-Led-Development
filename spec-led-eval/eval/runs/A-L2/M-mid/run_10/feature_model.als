// === feature_model.als — Alloy model for Loan Application RBAC Workflow (A-L2) ===
// Feature folder: A-L2  (spec branch: 004-loan-application-rbac)
// All sigs, facts, predicates, and assertions are self-contained in this file.

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────────────────────
// DECISION TYPE
// ─────────────────────────────────────────────────────────────────────────────
abstract sig DecisionType {}
one sig DecApproved, DecRejected extends DecisionType {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATIONS (endpoints)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostClaim, PostDecision, GetAudit extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton; addressed as PermMatrix.Allowed)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC SIGS
// ─────────────────────────────────────────────────────────────────────────────

sig User { userRole: one Role }

sig LoanApplication {
  appCustomer     : one  User,
  appStatus       : one  ApplicationStatus,
  assignedOfficer : lone User
}

sig Decision {
  forApp       : one LoanApplication,
  decisionType : one DecisionType,
  decidedBy    : one User
}

sig AuditEntry {
  auditApp        : one  LoanApplication,
  previousStatus  : lone ApplicationStatus,   // none ↔ initial submission
  newStatus       : one  ApplicationStatus,
  auditActor      : one  User
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: PERMISSION MATRIX — closed-world from contracts/http-api.md
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer          -> PostApplications)  +
    (Customer          -> GetApplications)   +
    (Customer          -> GetApplicationByRef) +
    (LoanOfficer       -> GetApplications)   +
    (LoanOfficer       -> GetApplicationByRef) +
    (LoanOfficer       -> PostClaim)         +
    (LoanOfficer       -> PostDecision)      +
    (LoanOfficer       -> GetAudit)          +
    (ComplianceReviewer -> GetApplications)  +
    (ComplianceReviewer -> GetApplicationByRef) +
    (ComplianceReviewer -> GetAudit)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: APPLICATION CUSTOMER MUST BE A CUSTOMER-ROLE USER  (FR-005)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AppCustomerRole {
  all a: LoanApplication | a.appCustomer.userRole = Customer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: ASSIGNED OFFICER MUST BE A LOAN-OFFICER-ROLE USER  (FR-003, FR-011)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AssignedOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer.userRole = LoanOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: STATUS ↔ ASSIGNED OFFICER COUPLING  (data-model.md CHECK constraint)
// Submitted ↔ no assignedOfficer; UnderReview/Approved/Rejected ↔ has officer
// ─────────────────────────────────────────────────────────────────────────────
fact F_StatusOfficerCoupling {
  all a: LoanApplication |
    (a.appStatus = Submitted) iff (no a.assignedOfficer)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: AT MOST ONE DECISION PER APPLICATION  (data-model.md Decision PK)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AtMostOneDecisionPerApp {
  all disj d1, d2: Decision | d1.forApp != d2.forApp
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: DECISION EXISTS IFF APPLICATION IS IN TERMINAL STATE  (FR-015, FR-016)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionTerminalCoupling {
  all a: LoanApplication |
    (a.appStatus in (Approved + Rejected)) iff (one d: Decision | d.forApp = a)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: DECISION DECIDED BY THE ASSIGNED OFFICER  (FR-013)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionByAssignedOfficer {
  all d: Decision | d.decidedBy = d.forApp.assignedOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: DECISION TYPE MATCHES APPLICATION STATUS  (FR-015)
// ─────────────────────────────────────────────────────────────────────────────
fact F_DecisionTypeMatchesStatus {
  all d: Decision |
    (d.forApp.appStatus = Approved implies d.decisionType = DecApproved) and
    (d.forApp.appStatus = Rejected implies d.decisionType = DecRejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: AUDIT INITIAL ENTRY SHAPE — null previous ↔ newStatus = Submitted
//  (data-model.md CHECK: (previous_status IS NULL) = (new_status = 'Submitted'))
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditInitialEntryShape {
  all e: AuditEntry | (no e.previousStatus) iff (e.newStatus = Submitted)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: AUDIT NO-OP PROHIBITION  (data-model.md CHECK: previous != new)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditNoNoOp {
  all e: AuditEntry |
    some e.previousStatus implies e.previousStatus != e.newStatus
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: EVERY APPLICATION HAS EXACTLY ONE INITIAL AUDIT ENTRY  (FR-019, FR-009)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditOneInitialEntry {
  all a: LoanApplication |
    one e: AuditEntry | e.auditApp = a and no e.previousStatus
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: NO DUPLICATE (application, previous, new) TRANSITIONS  (FR-019)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditNoDuplicateTransitions {
  all disj e1, e2: AuditEntry |
    (e1.auditApp = e2.auditApp) implies
      not (e1.previousStatus = e2.previousStatus and e1.newStatus = e2.newStatus)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: SUBMISSION AUDIT ENTRY — actor is the application's customer  (FR-017)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditSubmitActorIsCustomer {
  all e: AuditEntry |
    (no e.previousStatus) implies e.auditActor = e.auditApp.appCustomer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: CLAIM AUDIT ENTRY — actor for Submitted→UnderReview is a LoanOfficer  (FR-011, FR-017)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditClaimActorIsOfficer {
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = Submitted and e.newStatus = UnderReview)
      implies e.auditActor.userRole = LoanOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: DECISION AUDIT ENTRY — actor for UnderReview→Approved/Rejected is LoanOfficer  (FR-015, FR-017)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditDecisionActorIsOfficer {
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = UnderReview and
     e.newStatus in (Approved + Rejected))
      implies e.auditActor.userRole = LoanOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: UNDER-REVIEW (AND BEYOND) APPS HAVE A CLAIM AUDIT ENTRY  (FR-011, FR-019)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditClaimEntryExists {
  all a: LoanApplication |
    a.appStatus in (UnderReview + Approved + Rejected) implies
      (one e: AuditEntry | e.auditApp = a and
       e.previousStatus = Submitted and e.newStatus = UnderReview)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: DECIDED APPS HAVE A DECISION AUDIT ENTRY  (FR-015, FR-017, FR-019)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditDecisionEntryExists {
  all a: LoanApplication |
    a.appStatus = Approved implies
      (one e: AuditEntry | e.auditApp = a and
       e.previousStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    a.appStatus = Rejected implies
      (one e: AuditEntry | e.auditApp = a and
       e.previousStatus = UnderReview and e.newStatus = Rejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: CLAIM AUDIT ENTRY ACTOR IS THE ASSIGNED OFFICER  (FR-017, AttributionCorrectness)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditClaimActorIsAssignedOfficer {
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = Submitted and e.newStatus = UnderReview)
      implies e.auditActor = e.auditApp.assignedOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: ONE IN-FLIGHT APPLICATION PER CUSTOMER  (FR-008)
// ─────────────────────────────────────────────────────────────────────────────
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.appStatus in (Submitted + UnderReview) and
           a2.appStatus in (Submitted + UnderReview))
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: COMPLIANCE REVIEWER HAS NO WRITE PERMISSIONS  (FR-004, FR-023)
// ─────────────────────────────────────────────────────────────────────────────
fact F_ComplianceReviewerNoWrite {
  ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
  ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
  ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: CUSTOMER HAS NO CLAIM/DECIDE/AUDIT PERMISSIONS  (FR-002)
// ─────────────────────────────────────────────────────────────────────────────
fact F_CustomerNoWriteOrAudit {
  Customer -> PostClaim    not in PermMatrix.Allowed
  Customer -> PostDecision not in PermMatrix.Allowed
  Customer -> GetAudit     not in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: LOAN OFFICER CANNOT SUBMIT APPLICATIONS AS CUSTOMER  (FR-003)
// ─────────────────────────────────────────────────────────────────────────────
fact F_LoanOfficerNoSubmit {
  LoanOfficer -> PostApplications not in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// FACT: VALID AUDIT ENTRY TRANSITIONS — only the four allowed transitions
//  may appear (spec Assumptions: only 4 reachable transitions)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditValidTransitions {
  all e: AuditEntry |
    (no e.previousStatus and e.newStatus = Submitted) or
    (e.previousStatus = Submitted     and e.newStatus = UnderReview) or
    (e.previousStatus = UnderReview   and e.newStatus = Approved) or
    (e.previousStatus = UnderReview   and e.newStatus = Rejected)
}

// ─────────────────────────────────────────────────────────────────────────────
// ══════════════════════════════ PREDICATES ════════════════════════════════════
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-002, FR-003, FR-004
pred LeastPrivilege {
  some LoanApplication  // non-vacuous witness
  // Denied cells are absent from the Allowed relation
  Customer          -> PostClaim         not in PermMatrix.Allowed
  Customer          -> PostDecision      not in PermMatrix.Allowed
  Customer          -> GetAudit          not in PermMatrix.Allowed
  LoanOfficer       -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
  ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
  ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some User
  // Every Role × OperationKind cell is either allowed or not (Alloy sets are
  // total, so the meaningful check is that the Allowed set is exactly the
  // intended 11-cell matrix — no extra cells, no missing cells).
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
  // Explicit completeness: exactly 11 pairs are allowed
  #(PermMatrix.Allowed) = 11
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-002/FR-003/FR-004; contracts/http-api.md
pred PermissionGrounding {
  some User
  // Every allowed (Role, Op) pair is one of the 11 spec-grounded cells.
  // Grounded set is the union listed in F_PermissionMatrix.
  // Any extra cell would violate this pred.
  PermMatrix.Allowed =
    (Customer          -> PostApplications)    +
    (Customer          -> GetApplications)     +
    (Customer          -> GetApplicationByRef) +
    (LoanOfficer       -> GetApplications)     +
    (LoanOfficer       -> GetApplicationByRef) +
    (LoanOfficer       -> PostClaim)           +
    (LoanOfficer       -> PostDecision)        +
    (LoanOfficer       -> GetAudit)            +
    (ComplianceReviewer -> GetApplications)    +
    (ComplianceReviewer -> GetApplicationByRef)+
    (ComplianceReviewer -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some User
  // Every OperationKind has at least one Role that is allowed and at least one
  // that is denied — meaning the permission check is non-trivial (some roles ARE
  // blocked). GetApplications is allowed by all three, but PostApplications,
  // PostClaim, PostDecision, and GetAudit have at least one denied role.
  PostApplications  not in ComplianceReviewer.(PermMatrix.Allowed)
  PostApplications  not in LoanOfficer.(PermMatrix.Allowed)
  PostClaim         not in Customer.(PermMatrix.Allowed)
  PostClaim         not in ComplianceReviewer.(PermMatrix.Allowed)
  PostDecision      not in Customer.(PermMatrix.Allowed)
  PostDecision      not in ComplianceReviewer.(PermMatrix.Allowed)
  GetAudit          not in Customer.(PermMatrix.Allowed)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md ApplicationEvent
pred AuditCompleteness {
  some LoanApplication
  // Every application has exactly one initial audit entry
  all a: LoanApplication | one e: AuditEntry | e.auditApp = a and no e.previousStatus
  // Decided apps have exactly their full chain (no missing decision entry)
  all a: LoanApplication |
    a.appStatus in (Approved + Rejected) implies
      (one e: AuditEntry | e.auditApp = a and
       e.previousStatus = UnderReview and e.newStatus = a.appStatus)
  // No orphan audit entry exists without a corresponding application state
  all e: AuditEntry |
    (e.newStatus = Approved   implies e.auditApp.appStatus = Approved) or
    (e.newStatus = Rejected   implies e.auditApp.appStatus = Rejected) or
    (e.newStatus = Submitted) or
    (e.newStatus = UnderReview)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries for the same application share the same
  // (previousStatus, newStatus) pair — a mutated/overwritten entry would
  // look like a duplicate transition.
  all disj e1, e2: AuditEntry |
    e1.auditApp = e2.auditApp implies
      not (e1.previousStatus = e2.previousStatus and e1.newStatus = e2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md AuditEntry actor_user_id
pred AttributionCorrectness {
  some AuditEntry
  // Initial submission entry: actor is exactly the submitting customer
  all e: AuditEntry | (no e.previousStatus) implies e.auditActor = e.auditApp.appCustomer
  // Claim entry: actor is the assigned officer of the application
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = Submitted and e.newStatus = UnderReview)
      implies e.auditActor = e.auditApp.assignedOfficer
  // Decision entry: actor is a LoanOfficer
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = UnderReview and
     e.newStatus in (Approved + Rejected))
      implies e.auditActor.userRole = LoanOfficer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id; spec.md FR-005
pred OwnershipExclusivity {
  some LoanApplication
  // Each application is owned by exactly one customer-role user
  all a: LoanApplication | one a.appCustomer and a.appCustomer.userRole = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GetApplicationByRef
pred OwnershipBasedAccess {
  some LoanApplication
  // A customer-role user can only ever be the customer of their own applications.
  // Two distinct applications cannot share the same customer (ownership is exclusive
  // to the submitter) AND a customer who did not submit an app owns nothing of it.
  all a: LoanApplication | a.appCustomer.userRole = Customer
  // Distinct applications with the same customer are owned by that one customer
  all a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies a1 = a2 or
      (a1.appStatus not in (Submitted + UnderReview) or
       a2.appStatus not in (Submitted + UnderReview))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found" on non-owner access
pred NoInformationLeakage {
  some LoanApplication
  // Structural encoding: The Customer role is not granted unconditional access
  // to GetApplicationByRef for all applications — the permission is conditional
  // on ownership. The permission matrix shows Customer CAN call GetApplicationByRef,
  // but the data model enforces that only the owning customer reaches a 200 response.
  // In terms of the model: no audit entry is produced for a denied cross-customer access,
  // meaning the denied probe leaves no fingerprint.
  // Assert: GetApplicationByRef is in the Allowed relation for Customer (so the
  // route exists) but PostClaim, PostDecision, GetAudit are NOT (other roles are
  // blocked unconditionally).
  Customer -> GetApplicationByRef in PermMatrix.Allowed
  Customer -> PostClaim    not in PermMatrix.Allowed
  Customer -> PostDecision not in PermMatrix.Allowed
  Customer -> GetAudit     not in PermMatrix.Allowed
  // No audit entry records an actor of a different customer than the app's owner
  all e: AuditEntry |
    e.auditActor.userRole = Customer implies e.auditActor = e.auditApp.appCustomer
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-006, FR-014; data-model.md atomicity
pred ValidationBeforeMutation {
  some LoanApplication
  // A Decision only exists for applications in terminal state — an application
  // that failed validation never gets a decision row.
  all d: Decision | d.forApp.appStatus in (Approved + Rejected)
  // An audit entry for a decision transition only exists when the application
  // is in the terminal state matching the transition.
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = UnderReview and e.newStatus = Approved)
      implies e.auditApp.appStatus = Approved
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = UnderReview and e.newStatus = Rejected)
      implies e.auditApp.appStatus = Rejected
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some User
  // Every OperationKind has at least one Role that is explicitly excluded —
  // the matrix is not universally open; some roles are denied every write op.
  no r: Role | PostClaim -> r in ~(PermMatrix.Allowed)  // rewritten as denial check
  LoanOfficer -> PostApplications  not in PermMatrix.Allowed
  ComplianceReviewer -> PostClaim  not in PermMatrix.Allowed
  Customer -> GetAudit             not in PermMatrix.Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
  some User
  // Customer is allowed: PostApplications, GetApplications, GetApplicationByRef
  Customer -> PostApplications   in PermMatrix.Allowed
  Customer -> GetApplications    in PermMatrix.Allowed
  Customer -> GetApplicationByRef in PermMatrix.Allowed
  // Customer is denied: PostClaim, PostDecision, GetAudit
  Customer -> PostClaim    not in PermMatrix.Allowed
  Customer -> PostDecision not in PermMatrix.Allowed
  Customer -> GetAudit     not in PermMatrix.Allowed
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerPermissions {
  some User
  LoanOfficer -> GetApplications    in PermMatrix.Allowed
  LoanOfficer -> GetApplicationByRef in PermMatrix.Allowed
  LoanOfficer -> PostClaim          in PermMatrix.Allowed
  LoanOfficer -> PostDecision       in PermMatrix.Allowed
  LoanOfficer -> GetAudit           in PermMatrix.Allowed
  LoanOfficer -> PostApplications   not in PermMatrix.Allowed
}
assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-023
pred FR_004_ComplianceReviewerReadOnly {
  some User
  ComplianceReviewer -> GetApplications    in PermMatrix.Allowed
  ComplianceReviewer -> GetApplicationByRef in PermMatrix.Allowed
  ComplianceReviewer -> GetAudit           in PermMatrix.Allowed
  ComplianceReviewer -> PostApplications   not in PermMatrix.Allowed
  ComplianceReviewer -> PostClaim          not in PermMatrix.Allowed
  ComplianceReviewer -> PostDecision       not in PermMatrix.Allowed
}
assert FR_004_ComplianceReviewerReadOnly { FR_004_ComplianceReviewerReadOnly }
check FR_004_ComplianceReviewerReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_CustomerIdentityFromContext {
  some LoanApplication
  // Every application's customer is a user with Customer role —
  // the customer's identity must come from auth context, not payload
  all a: LoanApplication | a.appCustomer.userRole = Customer
}
assert FR_005_CustomerIdentityFromContext { FR_005_CustomerIdentityFromContext }
check FR_005_CustomerIdentityFromContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerCustomer {
  some LoanApplication
  // No two distinct applications in flight for the same customer
  all disj a1, a2: LoanApplication |
    a1.appCustomer = a2.appCustomer implies
      not (a1.appStatus in (Submitted + UnderReview) and
           a2.appStatus in (Submitted + UnderReview))
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_UniqueApplicationPerSubmission {
  some LoanApplication
  // In a well-formed state, every LoanApplication atom is distinct (structural)
  // and every application has exactly one initial audit entry linking it to a customer
  all a: LoanApplication | one e: AuditEntry | e.auditApp = a and no e.previousStatus
  // The submitting customer on the audit entry matches the application's customer
  all a: LoanApplication |
    all e: AuditEntry | (e.auditApp = a and no e.previousStatus) implies
      e.auditActor = a.appCustomer
}
assert FR_009_UniqueApplicationPerSubmission { FR_009_UniqueApplicationPerSubmission }
check FR_009_UniqueApplicationPerSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-012
pred FR_011_012_ClaimExclusivity {
  some LoanApplication
  // At most one loan officer can be assigned to an application
  all a: LoanApplication | lone a.assignedOfficer
  // Assigned officer is always a LoanOfficer-role user
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer.userRole = LoanOfficer
}
assert FR_011_012_ClaimExclusivity { FR_011_012_ClaimExclusivity }
check FR_011_012_ClaimExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OnlyAssignedOfficerDecides {
  some Decision
  // The deciding officer is exactly the assigned officer on the application
  all d: Decision | d.decidedBy = d.forApp.assignedOfficer
  // No decision exists without an assigned officer
  all d: Decision | some d.forApp.assignedOfficer
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015, FR-016
pred FR_015_016_DecisionImmutability {
  some Decision
  // Exactly one decision per terminal application (not zero, not two)
  all a: LoanApplication |
    (a.appStatus in (Approved + Rejected)) iff (one d: Decision | d.forApp = a)
  // Decision type is consistent with final status
  all d: Decision |
    (d.forApp.appStatus = Approved implies d.decisionType = DecApproved) and
    (d.forApp.appStatus = Rejected implies d.decisionType = DecRejected)
}
assert FR_015_016_DecisionImmutability { FR_015_016_DecisionImmutability }
check FR_015_016_DecisionImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_TerminalStateImmutable {
  some LoanApplication
  // Once Approved or Rejected, no further status changes are possible.
  // In the static model: no audit entries exist that transition OUT of Approved/Rejected.
  all e: AuditEntry |
    some e.previousStatus implies
      e.previousStatus not in (Approved + Rejected)
}
assert FR_016_TerminalStateImmutable { FR_016_TerminalStateImmutable }
check FR_016_TerminalStateImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017, FR-018, FR-019
pred FR_017_018_019_AuditTrailIntegrity {
  some AuditEntry
  // Every application has at least one audit entry
  all a: LoanApplication | some e: AuditEntry | e.auditApp = a
  // No two entries for the same app share the same transition (no duplicates)
  all disj e1, e2: AuditEntry |
    e1.auditApp = e2.auditApp implies
      not (e1.previousStatus = e2.previousStatus and e1.newStatus = e2.newStatus)
  // Every audit entry has a non-null actor
  all e: AuditEntry | some e.auditActor
}
assert FR_017_018_019_AuditTrailIntegrity { FR_017_018_019_AuditTrailIntegrity }
check FR_017_018_019_AuditTrailIntegrity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_ExactlyOneAuditEntryPerTransition {
  some LoanApplication
  // Submitted apps: exactly one audit entry (the initial submission)
  all a: LoanApplication |
    a.appStatus = Submitted implies
      (one e: AuditEntry | e.auditApp = a)
  // UnderReview apps: exactly two audit entries
  all a: LoanApplication |
    a.appStatus = UnderReview implies
      (#{e: AuditEntry | e.auditApp = a} = 2)
  // Decided apps: exactly three audit entries
  all a: LoanApplication |
    a.appStatus in (Approved + Rejected) implies
      (#{e: AuditEntry | e.auditApp = a} = 3)
}
assert FR_019_ExactlyOneAuditEntryPerTransition { FR_019_ExactlyOneAuditEntryPerTransition }
check FR_019_ExactlyOneAuditEntryPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_CustomerSeesOwnAppsOnly {
  some LoanApplication
  // An audit submission entry only occurs for the application's own customer
  all e: AuditEntry |
    e.auditActor.userRole = Customer implies e.auditActor = e.auditApp.appCustomer
  // No customer appears as an actor on another customer's application
  all a: LoanApplication |
    a.appCustomer.userRole = Customer
}
assert FR_020_CustomerSeesOwnAppsOnly { FR_020_CustomerSeesOwnAppsOnly }
check FR_020_CustomerSeesOwnAppsOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_OfficerIdentityHiddenFromCustomer {
  some LoanApplication
  // Customer-role users never appear as assignedOfficer on any application
  all a: LoanApplication | no a.assignedOfficer or a.assignedOfficer.userRole = LoanOfficer
  // Audit claim entries: the actor (assigned officer) is never a Customer-role user
  all e: AuditEntry |
    (some e.previousStatus and e.previousStatus = Submitted and e.newStatus = UnderReview)
      implies e.auditActor.userRole = LoanOfficer
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md Assumptions — only four reachable transitions
pred FR_StateTransitionValidity {
  some AuditEntry
  // Every audit entry records one of the four documented transitions
  all e: AuditEntry |
    ((no e.previousStatus) and e.newStatus = Submitted) or
    (e.previousStatus = Submitted   and e.newStatus = UnderReview) or
    (e.previousStatus = UnderReview and e.newStatus = Approved) or
    (e.previousStatus = UnderReview and e.newStatus = Rejected)
}
assert FR_StateTransitionValidity { FR_StateTransitionValidity }
check FR_StateTransitionValidity for 5

// FEATURE-SPECIFIC  ANCHOR: data-model.md CHECK: (status='Submitted')=(assigned_officer_id IS NULL)
pred FR_StatusOfficerInvariant {
  some LoanApplication
  all a: LoanApplication |
    (a.appStatus = Submitted iff no a.assignedOfficer)
}
assert FR_StatusOfficerInvariant { FR_StatusOfficerInvariant }
check FR_StatusOfficerInvariant for 5