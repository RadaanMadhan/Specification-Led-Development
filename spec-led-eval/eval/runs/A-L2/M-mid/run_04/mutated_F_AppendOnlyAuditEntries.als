// === feature_model.als — Alloy model for Loan Application RBAC & Audit Trail ===
// Feature: 004-loan-application-rbac / A-L2
// Patterns: LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//           AuditCompleteness, AppendOnly, AttributionCorrectness,
//           OwnershipExclusivity, OwnershipBasedAccess, NoInformationLeakage

// ─────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// ─────────────────────────────────────────────────────────────
// OPERATIONS (endpoints)
// ─────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostApplications, GetApplications, GetApplicationByRef,
        PostClaim, PostDecision, GetAudit extends OperationKind {}

// ─────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton carrier)
// ─────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────
// APPLICATION STATUS
// ─────────────────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ─────────────────────────────────────────────────────────────
// USERS
// ─────────────────────────────────────────────────────────────
sig User { role: one Role }

// ─────────────────────────────────────────────────────────────
// LOAN APPLICATIONS
// ─────────────────────────────────────────────────────────────
sig LoanApplication {
  customer     : one User,
  status       : one ApplicationStatus,
  assignedOfficer : lone User
}

// ─────────────────────────────────────────────────────────────
// DECISIONS  (at most one per application)
// ─────────────────────────────────────────────────────────────
sig Decision {
  application : one LoanApplication,
  decidedBy   : one User
}

// ─────────────────────────────────────────────────────────────
// AUDIT EVENTS  (append-only log entries)
// ─────────────────────────────────────────────────────────────
sig ApplicationEvent {
  application  : one LoanApplication,
  actor        : one User,
  prevStatus   : lone ApplicationStatus,   // none ↔ initial submission
  newStatus    : one ApplicationStatus
}

// ─────────────────────────────────────────────────────────────
// OPERATIONS (modelled requests)
// ─────────────────────────────────────────────────────────────
abstract sig Outcome {}
one sig Success, Denied, NotFound, Conflict, ValidationFailed extends Outcome {}

sig Operation {
  caller    : lone User,             // none = unauthenticated
  kind      : one OperationKind,
  outcome   : one Outcome,
  targetApp : lone LoanApplication
}

// ─────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE  (makes all-quantified assertions non-vacuous)
// ─────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Decision
  some ApplicationEvent
  some Operation
}

// ─────────────────────────────────────────────────────────────
// PERMISSION MATRIX FACT
// contracts/http-api.md § Permission matrix
// ─────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Customer        -> PostApplications)  +
    (Customer        -> GetApplications)   +
    (Customer        -> GetApplicationByRef) +
    (LoanOfficer     -> GetApplications)   +
    (LoanOfficer     -> GetApplicationByRef) +
    (LoanOfficer     -> PostClaim)         +
    (LoanOfficer     -> PostDecision)      +
    (LoanOfficer     -> GetAudit)          +
    (ComplianceReviewer -> GetApplications)   +
    (ComplianceReviewer -> GetApplicationByRef) +
    (ComplianceReviewer -> GetAudit)
}

// ─────────────────────────────────────────────────────────────
// STRUCTURAL DOMAIN FACTS
// ─────────────────────────────────────────────────────────────

// spec.md Assumptions: a user has exactly one role — enforced by sig field, but
// we also require the customer field on an application to be a Customer-role user.
fact F_ApplicationCustomerRole {
  all a: LoanApplication | a.customer.role = Customer
}

// data-model.md: assigned_officer must have role loan_officer
fact F_AssignedOfficerRole {
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer.role = LoanOfficer
}

// data-model.md CHECK: (status='Submitted') = (assigned_officer_id IS NULL)
fact F_StatusAssignmentCoupling {
  all a: LoanApplication |
    (a.status = Submitted) iff (no a.assignedOfficer)
}

// data-model.md: Decision PK = application_id → at most one decision per app
fact F_AtMostOneDecisionPerApp {
  all disj d1, d2: Decision | d1.application != d2.application
}

// data-model.md state machine: decision ↔ terminal status
fact F_DecisionIffTerminal {
  all a: LoanApplication |
    (a.status = Approved or a.status = Rejected)
    iff
    (one d: Decision | d.application = a)
}

// data-model.md: decided_by must be a loan officer
fact F_DecisionByOfficerRole {
  all d: Decision | d.decidedBy.role = LoanOfficer
}

// spec.md FR-013 / data-model.md: decider must be the assigned officer
fact F_DecisionByAssignedOfficer {
  all d: Decision | d.decidedBy = d.application.assignedOfficer
}

// data-model.md audit CHECK: (prevStatus IS NULL) = (newStatus = 'Submitted')
fact F_AuditNullPrevOnlyForSubmission {
  all e: ApplicationEvent |
    (no e.prevStatus) iff (e.newStatus = Submitted)
}

// data-model.md audit CHECK: prevStatus <> newStatus
fact F_AuditNoNoop {
  all e: ApplicationEvent |
    some e.prevStatus implies e.prevStatus != e.newStatus
}

// data-model.md state machine: only four valid transition shapes
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// spec.md FR-009: exactly one initial submission event per application
fact F_OneInitialAuditPerApp {
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and no e.prevStatus
}

// spec.md FR-019: no duplicate audit entries for the same (app, prevStatus, newStatus)
fact F_AuditNoDuplicates {
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies
    not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
}

// spec.md FR-017: actor for initial submission must be the customer
fact F_AuditSubmissionActorIsCustomer {
  all e: ApplicationEvent |
    (no e.prevStatus) implies e.actor = e.application.customer
}

// spec.md FR-017: actor for claim/decision transitions must be a loan officer
fact F_AuditTransitionActorIsOfficer {
  all e: ApplicationEvent |
    (some e.prevStatus) implies e.actor.role = LoanOfficer
}

// spec.md FR-017: audit entries for transitions beyond Submitted exist iff the
// application has reached that status
fact F_AuditCompletenessForStatus {
  // Submitted→UnderReview event ↔ status is UnderReview or beyond
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected)
    iff
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = Submitted and e.newStatus = UnderReview)

  // UnderReview→Approved event ↔ status is Approved
  all a: LoanApplication |
    (a.status = Approved)
    iff
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = UnderReview and e.newStatus = Approved)

  // UnderReview→Rejected event ↔ status is Rejected
  all a: LoanApplication |
    (a.status = Rejected)
    iff
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = UnderReview and e.newStatus = Rejected)
}

// spec.md FR-008: at most one in-flight application per customer
fact F_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
    not (
      (a1.status = Submitted or a1.status = UnderReview) and
      (a2.status = Submitted or a2.status = UnderReview)
    )
}

// Operation auth: unauthenticated calls (no caller) are always Denied
fact F_AuthRequiredAlways {
  all op: Operation | no op.caller implies op.outcome = Denied
}

// Operation permission: authenticated call with a forbidden role → Denied
fact F_RolePermissionEnforcement {
  all op: Operation |
    (some op.caller and
     (op.caller.role -> op.kind) not in PermMatrix.Allowed)
    implies op.outcome = Denied
}

// spec.md FR-020: customer accessing another customer's app → NotFound (not Denied)
fact F_CustomerOwnershipAccessReturnsNotFound {
  all op: Operation |
    (some op.caller and
     op.caller.role = Customer and
     op.kind = GetApplicationByRef and
     some op.targetApp and
     op.targetApp.customer != op.caller)
    implies op.outcome = NotFound
}

// spec.md FR-013: PostDecision succeeds only for the assigned officer
fact F_OnlyAssignedOfficerSucceeds {
  all op: Operation |
    (some op.caller and
     op.kind = PostDecision and
     op.outcome = Success and
     some op.targetApp)
    implies op.caller = op.targetApp.assignedOfficer
}

// spec.md FR-016: PostDecision and PostClaim cannot succeed on terminal apps
fact F_TerminalStatusImmutable {
  all op: Operation |
    (some op.targetApp and
     (op.targetApp.status = Approved or op.targetApp.status = Rejected) and
     (op.kind = PostDecision or op.kind = PostClaim))
    implies op.outcome != Success
}

// spec.md FR-021: compliance reviewer and loan officer can see officer identity;
// customer-targeted GetApplicationByRef for their own app does NOT expose the
// officer via the permission check (modelled as: customer operations on GetAudit
// are always Denied, enforced by the permission matrix)
fact F_CustomerCannotAccessAuditEndpoint {
  all op: Operation |
    (some op.caller and
     op.caller.role = Customer and
     op.kind = GetAudit)
    implies op.outcome = Denied
}

// ─────────────────────────────────────────────────────────────
// PREDICATES AND ASSERTIONS
// ─────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md § Permission matrix; spec.md FR-002 FR-003 FR-004
pred LeastPrivilege {
  // Every denied cell in the matrix produces Denied on an authenticated operation
  all op: Operation |
    (some op.caller and
     (op.caller.role -> op.kind) not in PermMatrix.Allowed)
    implies op.outcome = Denied
  // At least one denied pair exists to make this non-vacuous
  some op: Operation |
    some op.caller and
    (op.caller.role -> op.kind) not in PermMatrix.Allowed and
    op.outcome = Denied
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md § Permission matrix
pred PermissionCompleteness {
  // Every Role × OperationKind cell is either in Allowed or not — the matrix
  // is total; verify by checking Allowed is a sub-relation of the full product
  PermMatrix.Allowed in Role -> OperationKind
  // Allowed is non-empty and strictly less than the full product (some denials exist)
  some PermMatrix.Allowed
  PermMatrix.Allowed != Role -> OperationKind
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md § Authentication
pred AuthRequiredEverywhere {
  all op: Operation | no op.caller implies op.outcome = Denied
  // Non-vacuous: at least one unauthenticated operation is Denied
  some op: Operation | no op.caller and op.outcome = Denied
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017 FR-019; data-model.md application_events
pred AuditCompleteness {
  // Every application has exactly one initial audit entry
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and no e.prevStatus
  // Applications that have progressed have the matching audit entry
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected)
    implies
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    a.status = Approved implies
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    a.status = Rejected implies
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = UnderReview and e.newStatus = Rejected)
  some LoanApplication
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on application_events"
pred AppendOnly {
  // All audit entries have valid, well-formed transition shapes (no mutation of shape)
  all e: ApplicationEvent |
    ((no e.prevStatus) and e.newStatus = Submitted) or
    (e.prevStatus = Submitted and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
  // No two entries for the same application record the same transition
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies
    not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
  some ApplicationEvent
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
pred AttributionCorrectness {
  // Initial submission attributed to the customer of that application
  all e: ApplicationEvent |
    (no e.prevStatus) implies e.actor = e.application.customer
  // Status-change entries attributed to a loan officer
  all e: ApplicationEvent |
    (some e.prevStatus) implies e.actor.role = LoanOfficer
  some ApplicationEvent
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id NOT NULL FK; spec.md Key Entities Customer
pred OwnershipExclusivity {
  // Every application is owned by exactly one user with role Customer
  all a: LoanApplication | a.customer.role = Customer
  // No two distinct applications share the same in-flight status for the same customer
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
    not (
      (a1.status = Submitted or a1.status = UnderReview) and
      (a2.status = Submitted or a2.status = UnderReview)
    )
  some LoanApplication
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GetApplicationByRef customer row
pred OwnershipBasedAccess {
  // A customer operation on GetApplicationByRef against a non-owned app → NotFound
  all op: Operation |
    (some op.caller and
     op.caller.role = Customer and
     op.kind = GetApplicationByRef and
     some op.targetApp and
     op.targetApp.customer != op.caller)
    implies op.outcome = NotFound
  some op: Operation |
    some op.caller and
    op.caller.role = Customer and
    op.kind = GetApplicationByRef and
    some op.targetApp and
    op.targetApp.customer != op.caller and
    op.outcome = NotFound
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "404 not_found (no existence leak)"
pred NoInformationLeakage {
  // Customer accessing a non-owned application gets NotFound, not Denied
  // i.e. the outcome is indistinguishable from a non-existent reference
  all op: Operation |
    (some op.caller and
     op.caller.role = Customer and
     op.kind = GetApplicationByRef and
     some op.targetApp and
     op.targetApp.customer != op.caller)
    implies op.outcome = NotFound
  // NotFound is never produced for the customer's own application solely due to role check
  all op: Operation |
    (some op.caller and
     op.caller.role = Customer and
     op.kind = GetApplicationByRef and
     some op.targetApp and
     op.targetApp.customer = op.caller)
    implies op.outcome != Denied
  some op: Operation |
    some op.caller and
    op.caller.role = Customer and
    op.kind = GetApplicationByRef and
    some op.targetApp and
    op.targetApp.customer != op.caller
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES
// ─────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies op.outcome = Denied
  some op: Operation | no op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
  // Customer cannot claim, decide, or view audit
  all op: Operation |
    some op.caller and op.caller.role = Customer implies
    op.kind not in (PostClaim + PostDecision + GetAudit) or
    op.outcome = Denied
  some op: Operation | some op.caller and op.caller.role = Customer
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_OfficerPermissions {
  // Loan officer cannot submit applications as a customer
  all op: Operation |
    some op.caller and op.caller.role = LoanOfficer and op.kind = PostApplications
    implies op.outcome = Denied
  // Loan officer PostDecision success requires they are the assigned officer
  all op: Operation |
    some op.caller and op.caller.role = LoanOfficer and
    op.kind = PostDecision and op.outcome = Success and some op.targetApp
    implies op.caller = op.targetApp.assignedOfficer
  some op: Operation | some op.caller and op.caller.role = LoanOfficer
}
assert FR_003_OfficerPermissions { FR_003_OfficerPermissions }
check FR_003_OfficerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_ComplianceReadOnly {
  all op: Operation |
    some op.caller and op.caller.role = ComplianceReviewer and
    op.kind in (PostApplications + PostClaim + PostDecision)
    implies op.outcome = Denied
  some op: Operation | some op.caller and op.caller.role = ComplianceReviewer
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
pred FR_008_OneInFlightPerCustomer {
  all disj a1, a2: LoanApplication |
    a1.customer = a2.customer implies
    not (
      (a1.status = Submitted or a1.status = UnderReview) and
      (a2.status = Submitted or a2.status = UnderReview)
    )
  some LoanApplication
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md state machine table row 1
pred FR_009_InitialAuditEntry {
  all a: LoanApplication |
    one e: ApplicationEvent |
      e.application = a and no e.prevStatus and e.newStatus = Submitted
  all e: ApplicationEvent |
    no e.prevStatus implies e.actor = e.application.customer
  some LoanApplication
}
assert FR_009_InitialAuditEntry { FR_009_InitialAuditEntry }
check FR_009_InitialAuditEntry for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md conditional UPDATE WHERE status='Submitted'
pred FR_012_ExactlyOneClaimPerApp {
  // At most one Submitted→UnderReview audit entry per application
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies
    not (
      e1.prevStatus = Submitted and e1.newStatus = UnderReview and
      e2.prevStatus = Submitted and e2.newStatus = UnderReview
    )
  // The application has exactly one assignedOfficer once claimed
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected)
    implies one a.assignedOfficer
  some a: LoanApplication | a.status = UnderReview
}
assert FR_012_ExactlyOneClaimPerApp { FR_012_ExactlyOneClaimPerApp }
check FR_012_ExactlyOneClaimPerApp for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md conditional UPDATE WHERE assigned_officer_id=?
pred FR_013_OnlyAssignedOfficerDecides {
  all d: Decision | d.decidedBy = d.application.assignedOfficer
  all op: Operation |
    some op.caller and op.kind = PostDecision and op.outcome = Success and some op.targetApp
    implies op.caller = op.targetApp.assignedOfficer
  some Decision
}
assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; data-model.md "no SQL path accepts Approved/Rejected as source"
pred FR_016_TerminalStatusImmutable {
  // No successful claim or decision on an already-terminal application
  all op: Operation |
    some op.targetApp and
    (op.targetApp.status = Approved or op.targetApp.status = Rejected) and
    (op.kind = PostDecision or op.kind = PostClaim)
    implies op.outcome != Success
  // No audit entry whose prevStatus is Approved or Rejected
  no e: ApplicationEvent |
    e.prevStatus = Approved or e.prevStatus = Rejected
  some a: LoanApplication | a.status = Approved or a.status = Rejected
}
assert FR_016_TerminalStatusImmutable { FR_016_TerminalStatusImmutable }
check FR_016_TerminalStatusImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 FR-019; data-model.md one INSERT per successful conditional UPDATE
pred FR_017_AuditEveryStatusChange {
  // Every application has exactly the right number and type of audit entries for its status
  all a: LoanApplication |
    one e: ApplicationEvent | e.application = a and no e.prevStatus and e.newStatus = Submitted
  all a: LoanApplication |
    (a.status = UnderReview or a.status = Approved or a.status = Rejected) iff
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = Submitted and e.newStatus = UnderReview)
  all a: LoanApplication |
    (a.status = Approved) iff
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = UnderReview and e.newStatus = Approved)
  all a: LoanApplication |
    (a.status = Rejected) iff
    (one e: ApplicationEvent |
      e.application = a and e.prevStatus = UnderReview and e.newStatus = Rejected)
  some LoanApplication
}
assert FR_017_AuditEveryStatusChange { FR_017_AuditEveryStatusChange }
check FR_017_AuditEveryStatusChange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE code path on application_events"
pred FR_018_AuditAppendOnly {
  // Only valid transition shapes exist — no entry can represent a retraction or rewrite
  all e: ApplicationEvent |
    ((no e.prevStatus) and e.newStatus = Submitted)  or
    (e.prevStatus = Submitted and e.newStatus = UnderReview)  or
    (e.prevStatus = UnderReview and e.newStatus = Approved)   or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
  // No two entries for the same app record the same transition (no duplicates = no re-insertion)
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies
    not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
  some ApplicationEvent
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019; data-model.md one row per applied transition
pred FR_019_ExactlyOneAuditPerTransition {
  all disj e1, e2: ApplicationEvent |
    e1.application = e2.application implies
    not (e1.prevStatus = e2.prevStatus and e1.newStatus = e2.newStatus)
  some ApplicationEvent
}
assert FR_019_ExactlyOneAuditPerTransition { FR_019_ExactlyOneAuditPerTransition }
check FR_019_ExactlyOneAuditPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020; contracts/http-api.md "404 not_found (no existence leak)"
pred FR_020_CustomerOwnershipAccess {
  all op: Operation |
    some op.caller and
    op.caller.role = Customer and
    op.kind = GetApplicationByRef and
    some op.targetApp and
    op.targetApp.customer != op.caller
    implies op.outcome = NotFound
  all op: Operation |
    some op.caller and
    op.caller.role = Customer and
    op.kind = GetApplicationByRef and
    some op.targetApp and
    op.targetApp.customer = op.caller
    implies op.outcome != Denied
  some op: Operation |
    some op.caller and
    op.caller.role = Customer and
    op.kind = GetApplicationByRef
}
assert FR_020_CustomerOwnershipAccess { FR_020_CustomerOwnershipAccess }
check FR_020_CustomerOwnershipAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021; contracts/http-api.md scrub_for_role; spec.md FR-021
// Model: customer cannot access GetAudit (enforced by permission matrix);
// the permission matrix entry for Customer × GetAudit is absent.
pred FR_021_OfficerIdentityHiddenFromCustomer {
  // Customer role is not permitted to call GetAudit
  (Customer -> GetAudit) not in PermMatrix.Allowed
  // Any customer operation on GetAudit is Denied
  all op: Operation |
    some op.caller and op.caller.role = Customer and op.kind = GetAudit
    implies op.outcome = Denied
  some op: Operation | some op.caller and op.caller.role = Customer
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023; contracts/http-api.md compliance row in permission matrix
pred FR_023_ComplianceNoWriteAtAll {
  all op: Operation |
    some op.caller and op.caller.role = ComplianceReviewer and
    op.kind in (PostApplications + PostClaim + PostDecision)
    implies op.outcome = Denied
  // Non-vacuous: a compliance reviewer attempting a write exists and is denied
  some op: Operation |
    some op.caller and op.caller.role = ComplianceReviewer and
    op.kind in (PostApplications + PostClaim + PostDecision) and
    op.outcome = Denied
}
assert FR_023_ComplianceNoWriteAtAll { FR_023_ComplianceNoWriteAtAll }
check FR_023_ComplianceNoWriteAtAll for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some e: ApplicationEvent | e.prevStatus = Approved and e.newStatus = Rejected }
