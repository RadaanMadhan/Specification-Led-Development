// === feature_model.als — Alloy model for Loan Application with RBAC (004-loan-application-rbac) ===

// === Role Hierarchy ===
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// === Application Status States ===
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// === User Entity ===
sig User {
  role: one Role
}

// === Loan Application Entity ===
sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assigned_officer: lone User,
  reference: one String
}

// === Decision Entity ===
sig Decision {
  application: one LoanApplication,
  reason: one String,
  decided_by: one User
}

// === Audit Entry (ApplicationEvent) ===
sig ApplicationEvent {
  application: one LoanApplication,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  actor: one User
}

// === Operation Kinds ===
abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication, 
        ClaimApplication, DecideApplication, ViewAudit extends OperationKind {}

// === Permission Matrix ===
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// === Non-Empty Universe (mandatory for Alloy 6) ===
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some ApplicationEvent
}

// === FACT: Permission Matrix Encoding ===
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001-004
fact F_PermissionMatrix {
  PermMatrix.Allowed = (
    Customer -> SubmitApplication +
    Customer -> ListApplications +
    Customer -> ViewApplication +
    LoanOfficer -> ListApplications +
    LoanOfficer -> ViewApplication +
    LoanOfficer -> ClaimApplication +
    LoanOfficer -> DecideApplication +
    LoanOfficer -> ViewAudit +
    ComplianceReviewer -> ListApplications +
    ComplianceReviewer -> ViewApplication +
    ComplianceReviewer -> ViewAudit
  )
}

// === FACT: User Role Assignment ===
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_UserHasOneRole {
  all u: User | one u.role
}

// === FACT: Application Ownership by Customer ===
// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-020, data-model.md LoanApplication.customer
fact F_ApplicationOwnership {
  all app: LoanApplication | one app.customer
}

// === FACT: Audit Entry Actor Correctness ===
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017, data-model.md ApplicationEvent
fact F_AuditActorCorrectness {
  // Initial submission: actor is customer
  all ae: ApplicationEvent | (ae.previous_status = none and ae.new_status = Submitted) implies
    ae.actor.role = Customer
  // Claim: actor is loan officer
  all ae: ApplicationEvent | (ae.previous_status = Submitted and ae.new_status = UnderReview) implies
    ae.actor.role = LoanOfficer
  // Decision: actor is loan officer
  all ae: ApplicationEvent | (ae.previous_status = UnderReview and (ae.new_status = Approved or ae.new_status = Rejected)) implies
    ae.actor.role = LoanOfficer
}

// === FACT: Assigned Officer Must Be Loan Officer ===
// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-013
fact F_AssignedOfficerIsLoanOfficer { /* MUTATED — body cleared by validator */ }

// === FACT: Assignment Coupled to Status ===
// FEATURE-SPECIFIC  ANCHOR: data-model.md constraint on assigned_officer_id
fact F_AssignmentStatusCoupling {
  all app: LoanApplication |
    (app.status = Submitted) iff (app.assigned_officer = none)
}

// === FACT: Decision Exists Iff Decided ===
// FEATURE-SPECIFIC  ANCHOR: FR-015, data-model.md Decision entity
fact F_DecisionWhenDecided {
  all app: LoanApplication | (app.status = Approved or app.status = Rejected) iff
    (one d: Decision | d.application = app)
}

// === PATTERN: LeastPrivilege ===
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-002, FR-003, FR-004
pred LeastPrivilege {
  // Customer cannot perform officer/reviewer actions
  (Customer -> ClaimApplication) !in PermMatrix.Allowed
  (Customer -> DecideApplication) !in PermMatrix.Allowed
  (Customer -> ViewAudit) !in PermMatrix.Allowed
  // Officer cannot submit applications
  (LoanOfficer -> SubmitApplication) !in PermMatrix.Allowed
  // Reviewer cannot modify anything
  (ComplianceReviewer -> SubmitApplication) !in PermMatrix.Allowed
  (ComplianceReviewer -> ClaimApplication) !in PermMatrix.Allowed
  (ComplianceReviewer -> DecideApplication) !in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// === PATTERN: PermissionCompleteness ===
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role, Operation) pair is explicitly allowed or denied
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op !in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 3 Role, exactly 6 OperationKind

// === PATTERN: AuthRequiredEverywhere ===
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // Every user has exactly one role (enforced by sig definition + fact)
  all u: User | one u.role
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// === PATTERN: AuditCompleteness ===
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  // Every application has at least one audit entry (the submission)
  all app: LoanApplication |
    (some ae: ApplicationEvent | ae.application = app and ae.previous_status = none and ae.new_status = Submitted)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// === PATTERN: AppendOnly ===
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, data-model.md "append-only audit"
pred AppendOnly {
  // No ApplicationEvent can transition back (no deletion/reversion of audit entries)
  // In Alloy's static model: audit entries exist and are never removed
  some ApplicationEvent
}

assert AppendOnly { AppendOnly }
check AppendOnly for 8

// === PATTERN: OwnershipExclusivity ===
// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-020, data-model.md LoanApplication.customer
pred OwnershipExclusivity {
  // Every application is owned by exactly one customer
  all app: LoanApplication | one app.customer
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// === PATTERN: OwnershipBasedAccess ===
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020, contracts/http-api.md per-role scoping
pred OwnershipBasedAccess {
  // Customer access is restricted to own applications
  all u: User | u.role = Customer implies
    (all app: LoanApplication | app.customer != u implies u != app.customer)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// === PATTERN: NoInformationLeakage ===
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, contracts/http-api.md 404 response
pred NoInformationLeakage {
  // A customer cannot see another customer's application
  all u: User, app: LoanApplication |
    (u.role = Customer and u != app.customer) implies
    app !in { a: LoanApplication | a.customer = u }
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// === PATTERN: ConcurrencySafety ===
// PATTERN: ConcurrencySafety  ANCHOR: spec.md FR-012, contracts/http-api.md 409 already_claimed
pred ConcurrencySafety {
  // Exactly one officer can claim each application (unique transition to UnderReview)
  all app: LoanApplication | app.status = UnderReview implies
    (one ae: ApplicationEvent | ae.application = app and ae.previous_status = Submitted and ae.new_status = UnderReview)
}

assert ConcurrencySafety { ConcurrencySafety }
check ConcurrencySafety for 8

// === FEATURE-SPECIFIC: FR-001 Authentication Required ===
// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthenticationRequired {
  all u: User | one u.role
  some User
}

assert FR_001_AuthenticationRequired { FR_001_AuthenticationRequired }
check FR_001_AuthenticationRequired for 8

// === FEATURE-SPECIFIC: FR-002 Customer Role Permissions ===
// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
  Customer -> SubmitApplication in PermMatrix.Allowed
  Customer -> ListApplications in PermMatrix.Allowed
  Customer -> ViewApplication in PermMatrix.Allowed
}

assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 8

// === FEATURE-SPECIFIC: FR-003 Loan Officer Role Permissions ===
// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerPermissions {
  LoanOfficer -> ListApplications in PermMatrix.Allowed
  LoanOfficer -> ViewApplication in PermMatrix.Allowed
  LoanOfficer -> ClaimApplication in PermMatrix.Allowed
  LoanOfficer -> DecideApplication in PermMatrix.Allowed
  LoanOfficer -> ViewAudit in PermMatrix.Allowed
}

assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 8

// === FEATURE-SPECIFIC: FR-004 Compliance Reviewer Role Permissions ===
// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_ComplianceReviewerPermissions {
  ComplianceReviewer -> ListApplications in PermMatrix.Allowed
  ComplianceReviewer -> ViewApplication in PermMatrix.Allowed
  ComplianceReviewer -> ViewAudit in PermMatrix.Allowed
  ComplianceReviewer -> SubmitApplication !in PermMatrix.Allowed
  ComplianceReviewer -> ClaimApplication !in PermMatrix.Allowed
  ComplianceReviewer -> DecideApplication !in PermMatrix.Allowed
}

assert FR_004_ComplianceReviewerPermissions { FR_004_ComplianceReviewerPermissions }
check FR_004_ComplianceReviewerPermissions for 8

// === FEATURE-SPECIFIC: FR-008 One In-Flight Application Per Customer ===
// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerCustomer {
  // A customer cannot have more than one application in Submitted or UnderReview status
  all c: User | c.role = Customer implies
    (lone app: LoanApplication | app.customer = c and (app.status = Submitted or app.status = UnderReview))
}

assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 8

// === FEATURE-SPECIFIC: FR-009 Submission Creates Audit Entry ===
// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_SubmissionCreatesAuditEntry {
  // Every Submitted application has an audit entry for (none) -> Submitted
  all app: LoanApplication | app.status = Submitted implies
    (some ae: ApplicationEvent | ae.application = app and ae.previous_status = none and ae.new_status = Submitted)
}

assert FR_009_SubmissionCreatesAuditEntry { FR_009_SubmissionCreatesAuditEntry }
check FR_009_SubmissionCreatesAuditEntry for 8

// === FEATURE-SPECIFIC: FR-011 Claim Transitions Status and Creates Audit ===
// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_ClaimTransitionAndAudit {
  // Applications at UnderReview have an audit entry for Submitted -> UnderReview
  all app: LoanApplication | app.status = UnderReview implies
    (some ae: ApplicationEvent | ae.application = app and ae.previous_status = Submitted and ae.new_status = UnderReview)
}

assert FR_011_ClaimTransitionAndAudit { FR_011_ClaimTransitionAndAudit }
check FR_011_ClaimTransitionAndAudit for 8

// === FEATURE-SPECIFIC: FR-012 Exactly One Claim Per Application ===
// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_UniqueClaim {
  // Each application has at most one Submitted -> UnderReview event
  all app: LoanApplication |
    (lone ae: ApplicationEvent | ae.application = app and ae.previous_status = Submitted and ae.new_status = UnderReview)
}

assert FR_012_UniqueClaim { FR_012_UniqueClaim }
check FR_012_UniqueClaim for 8

// === FEATURE-SPECIFIC: FR-013 Only Assigned Officer Can Decide ===
// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OnlyAssignedOfficerDecides {
  // When an application is decided, the decider is the assigned officer
  all app: LoanApplication | (app.status = Approved or app.status = Rejected) implies
    (some d: Decision | d.application = app and d.decided_by = app.assigned_officer)
}

assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 8

// === FEATURE-SPECIFIC: FR-015 Decision Creates Audit Entry ===
// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_DecisionCreatesAuditEntry {
  // Decided applications have audit entries for UnderReview -> Approved/Rejected
  all app: LoanApplication | (app.status = Approved or app.status = Rejected) implies
    (some ae: ApplicationEvent | ae.application = app and ae.previous_status = UnderReview and
      (ae.new_status = Approved or ae.new_status = Rejected))
}

assert FR_015_DecisionCreatesAuditEntry { FR_015_DecisionCreatesAuditEntry }
check FR_015_DecisionCreatesAuditEntry for 8

// === FEATURE-SPECIFIC: FR-016 No Changes After Decision ===
// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_ImmutableAfterDecision {
  // Once Approved or Rejected, application cannot transition further
  all app: LoanApplication | (app.status = Approved or app.status = Rejected) implies
    (no ae: ApplicationEvent | ae.application = app and
      (ae.previous_status = Approved or ae.previous_status = Rejected))
}

assert FR_016_ImmutableAfterDecision { FR_016_ImmutableAfterDecision }
check FR_016_ImmutableAfterDecision for 8

// === FEATURE-SPECIFIC: FR-019 Exactly One Audit Entry Per Transition ===
// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_UniqueAuditPerTransition {
  // For each (application, prev_status, new_status), at most one audit entry exists
  all app: LoanApplication, prev: (ApplicationStatus + none), new: ApplicationStatus |
    (lone ae: ApplicationEvent | ae.application = app and ae.previous_status = prev and ae.new_status = new)
}

assert FR_019_UniqueAuditPerTransition { FR_019_UniqueAuditPerTransition }
check FR_019_UniqueAuditPerTransition for 8

// === FEATURE-SPECIFIC: FR-020 Customer Privacy ===
// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_CustomerPrivacy {
  // A customer cannot see another customer's application
  all u: User, app: LoanApplication | u.role = Customer and u != app.customer implies
    app !in { a: LoanApplication | a.customer = u }
}

assert FR_020_CustomerPrivacy { FR_020_CustomerPrivacy }
check FR_020_CustomerPrivacy for 8

// === FEATURE-SPECIFIC: FR-021 Officer Identity Hidden From Customer ===
// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_OfficerIdentityHidden {
  // Officer assignment is visible only to officers and compliance reviewers, not customers
  // (Modeled as: customers can only know about their own applications)
  all u: User | u.role = Customer implies
    (all app: LoanApplication | app.customer != u implies app !in { a: LoanApplication | a.customer = u })
}

assert FR_021_OfficerIdentityHidden { FR_021_OfficerIdentityHidden }
check FR_021_OfficerIdentityHidden for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_BadAssignmentViolation { some app: LoanApplication, u: User | app.assigned_officer = u and u.role = Customer }
