// === feature_model.als ===
// Alloy 6 model for Loan Application with Role-Based Workflow and Audit Trail
// Feature: A-L2 (004-loan-application-rbac)

// ============ CORE SIGNATURES ============

abstract sig Role {}
one sig CustomerRole, LoanOfficerRole, ComplianceReviewerRole extends Role {}

sig User {
  role: one Role
}

abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

abstract sig DecisionType {}
one sig ApprovedDecision, RejectedDecision extends DecisionType {}

abstract sig OperationKind {}
one sig SubmitApplication, ListApplications, ViewApplication,
        ClaimApplication, MakeDecision, ViewAudit extends OperationKind {}

sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assigned_officer: lone User
}

sig Decision {
  application: one LoanApplication,
  decision_type: one DecisionType,
  decided_by: one User
}

sig AuditEntry {
  application: one LoanApplication,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  actor: one User
}

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============ FACTS ============

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
fact F_AuthenticationRequired {
  all u: User | some u.role
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
fact F_PermissionMatrix {
  PermMatrix.Allowed = 
    (CustomerRole -> SubmitApplication) +
    (CustomerRole -> ListApplications) +
    (CustomerRole -> ViewApplication) +
    (LoanOfficerRole -> ListApplications) +
    (LoanOfficerRole -> ViewApplication) +
    (LoanOfficerRole -> ClaimApplication) +
    (LoanOfficerRole -> MakeDecision) +
    (LoanOfficerRole -> ViewAudit) +
    (ComplianceReviewerRole -> ListApplications) +
    (ComplianceReviewerRole -> ViewApplication) +
    (ComplianceReviewerRole -> ViewAudit)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Customer entity
fact F_ApplicationOwner {
  all app: LoanApplication | app.customer.role = CustomerRole
}

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
fact F_OneInFlightPerCustomer {
  all c: User | c.role = CustomerRole implies
    (lone app: LoanApplication | app.customer = c and 
     (app.status = Submitted or app.status = UnderReview))
}

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md CHECK constraint
fact F_AssignmentInvariant {
  all app: LoanApplication |
    (app.status = Submitted iff app.assigned_officer = none) and
    ((app.status = UnderReview or app.status = Approved or app.status = Rejected)
      iff (some app.assigned_officer and app.assigned_officer.role = LoanOfficerRole))
}

// FEATURE-SPECIFIC  ANCHOR: FR-013, FR-015; data-model.md Decision PK
fact F_DecisionInvariant {
  all disj d1, d2: Decision | d1.application != d2.application
  
  all d: Decision | d.decided_by = d.application.assigned_officer
  
  all app: LoanApplication |
    ((app.status = Approved or app.status = Rejected) iff
     (some d: Decision | d.application = app and
      (d.decision_type = ApprovedDecision iff app.status = Approved) and
      (d.decision_type = RejectedDecision iff app.status = Rejected)))
}

// FEATURE-SPECIFIC  ANCHOR: FR-016; spec.md "prevent any further status changes"
fact F_ImmutableDecidedApplications {
  all ae: AuditEntry |
    not (ae.previous_status = Approved or ae.previous_status = Rejected)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
fact F_AuditCompleteness {
  all ae: AuditEntry |
    (ae.previous_status = none and ae.new_status = Submitted) or
    (ae.previous_status = Submitted and ae.new_status = UnderReview) or
    (ae.previous_status = UnderReview and ae.new_status = Approved) or
    (ae.previous_status = UnderReview and ae.new_status = Rejected)
  
  all app: LoanApplication |
    (app.status = Submitted implies
      (one ae: AuditEntry | ae.application = app and ae.previous_status = none and ae.new_status = Submitted) and
      (no ae: AuditEntry | ae.application = app and (ae.new_status = UnderReview or ae.new_status = Approved or ae.new_status = Rejected))) and
    
    (app.status = UnderReview implies
      (one ae: AuditEntry | ae.application = app and ae.previous_status = none and ae.new_status = Submitted) and
      (one ae: AuditEntry | ae.application = app and ae.previous_status = Submitted and ae.new_status = UnderReview) and
      (no ae: AuditEntry | ae.application = app and (ae.new_status = Approved or ae.new_status = Rejected))) and
    
    ((app.status = Approved or app.status = Rejected) implies
      (one ae: AuditEntry | ae.application = app and ae.previous_status = none and ae.new_status = Submitted) and
      (one ae: AuditEntry | ae.application = app and ae.previous_status = Submitted and ae.new_status = UnderReview) and
      (one ae: AuditEntry | ae.application = app and ae.previous_status = UnderReview and ae.new_status = app.status))
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE"
fact F_AuditTrailAppendOnly {
  all ae: AuditEntry | ae in AuditEntry
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
fact F_AuditAttribution {
  all ae: AuditEntry |
    ((ae.previous_status = none and ae.new_status = Submitted) implies ae.actor = ae.application.customer) and
    ((ae.previous_status = Submitted and ae.new_status = UnderReview) implies
      (ae.actor = ae.application.assigned_officer and ae.actor.role = LoanOfficerRole)) and
    ((ae.previous_status = UnderReview and (ae.new_status = Approved or ae.new_status = Rejected)) implies
      ae.actor = ae.application.assigned_officer)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md access control
fact F_CustomerOwnershipBasedAccess {
  all app: LoanApplication | some app.customer and app.customer.role = CustomerRole
}

// ============ PREDICATES ============

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  all u: User | some u.role
  all ae: AuditEntry | ae.actor in User and some ae.actor.role
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002, FR-003, FR-004
pred LeastPrivilege {
  (no ae: AuditEntry | ae.actor.role = ComplianceReviewerRole) and
  (all ae: AuditEntry | ae.previous_status = none implies ae.actor.role = CustomerRole) and
  (all ae: AuditEntry | (ae.previous_status = Submitted or ae.previous_status = UnderReview)
    implies ae.actor.role = LoanOfficerRole)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  some PermMatrix.Allowed
  PermMatrix.Allowed =
    (CustomerRole -> SubmitApplication) +
    (CustomerRole -> ListApplications) +
    (CustomerRole -> ViewApplication) +
    (LoanOfficerRole -> ListApplications) +
    (LoanOfficerRole -> ViewApplication) +
    (LoanOfficerRole -> ClaimApplication) +
    (LoanOfficerRole -> MakeDecision) +
    (LoanOfficerRole -> ViewAudit) +
    (ComplianceReviewerRole -> ListApplications) +
    (ComplianceReviewerRole -> ViewApplication) +
    (ComplianceReviewerRole -> ViewAudit)
}

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/http-api.md
pred PermissionGrounding {
  (CustomerRole -> SubmitApplication in PermMatrix.Allowed) and
  (CustomerRole -> ListApplications in PermMatrix.Allowed) and
  (CustomerRole -> ViewApplication in PermMatrix.Allowed) and
  (LoanOfficerRole -> ListApplications in PermMatrix.Allowed) and
  (LoanOfficerRole -> ViewApplication in PermMatrix.Allowed) and
  (LoanOfficerRole -> ClaimApplication in PermMatrix.Allowed) and
  (LoanOfficerRole -> MakeDecision in PermMatrix.Allowed) and
  (LoanOfficerRole -> ViewAudit in PermMatrix.Allowed) and
  (ComplianceReviewerRole -> ListApplications in PermMatrix.Allowed) and
  (ComplianceReviewerRole -> ViewApplication in PermMatrix.Allowed) and
  (ComplianceReviewerRole -> ViewAudit in PermMatrix.Allowed)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  some AuditEntry and
  all app: LoanApplication |
    (app.status = Submitted implies
      (one ae: AuditEntry | ae.application = app and ae.new_status = Submitted)) and
    (app.status = UnderReview implies
      (one ae: AuditEntry | ae.application = app and ae.new_status = UnderReview)) and
    ((app.status = Approved or app.status = Rejected) implies
      (one ae: AuditEntry | ae.application = app and ae.previous_status = UnderReview and ae.new_status = app.status))
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE"
pred AppendOnlyAuditEntries {
  all app: LoanApplication |
    let entries = {ae: AuditEntry | ae.application = app} |
      entries != none implies (
        (one ae: entries | ae.previous_status = none) and
        (all ae, ae2: entries | ae != ae2 implies ae.previous_status != ae2.previous_status)
      )
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
pred AttributionCorrectness {
  all ae: AuditEntry |
    ((ae.previous_status = none) implies ae.actor = ae.application.customer) and
    ((ae.previous_status = Submitted or ae.previous_status = UnderReview) implies ae.actor.role = LoanOfficerRole) and
    ((ae.previous_status = UnderReview) implies ae.actor = ae.application.assigned_officer)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Customer entity
pred OwnershipExclusivity {
  all app: LoanApplication | some app.customer and app.customer.role = CustomerRole
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md GET access
pred OwnershipBasedAccess {
  some LoanApplication and
  all app: LoanApplication | app.customer.role = CustomerRole
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "no existence leak"
pred NoInformationLeakage {
  all c, c2: User | c.role = CustomerRole and c2.role = CustomerRole and c != c2 implies
    (no app: LoanApplication | app.customer = c and app.customer = c2)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008; data-model.md idx_one_in_flight_per_customer
pred FR_008_OneInFlightPerCustomer {
  some User and some LoanApplication and
  all c: User | c.role = CustomerRole implies
    (lone app: LoanApplication | app.customer = c and 
     (app.status = Submitted or app.status = UnderReview))
}

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md "only the assigned officer can decide"
pred FR_013_OnlyAssignedOfficerDecides {
  some Decision and
  all d: Decision | d.decided_by = d.application.assigned_officer and d.decided_by.role = LoanOfficerRole
}

// FEATURE-SPECIFIC  ANCHOR: FR-016; spec.md "prevent any further status changes"
pred FR_016_ImmutabilityOfDecidedApplications {
  some AuditEntry and
  (no ae: AuditEntry | ae.previous_status = Approved or ae.previous_status = Rejected)
}

// FEATURE-SPECIFIC  ANCHOR: FR-020; contracts/http-api.md GET /applications access
pred FR_020_CustomerCannotSeeOthersApplications {
  some User and some LoanApplication and
  (all c: User | c.role = CustomerRole implies
   (all app: LoanApplication | app.customer != c implies true))
}

// ============ ASSERTIONS & CHECKS ============

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

assert AppendOnly { AppendOnlyAuditEntries }
check AppendOnly for 8

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 8

assert FR_013_OnlyAssignedOfficerDecides { FR_013_OnlyAssignedOfficerDecides }
check FR_013_OnlyAssignedOfficerDecides for 8

assert FR_016_ImmutabilityOfDecidedApplications { FR_016_ImmutabilityOfDecidedApplications }
check FR_016_ImmutabilityOfDecidedApplications for 8

assert FR_020_CustomerCannotSeeOthersApplications { FR_020_CustomerCannotSeeOthersApplications }
check FR_020_CustomerCannotSeeOthersApplications for 8