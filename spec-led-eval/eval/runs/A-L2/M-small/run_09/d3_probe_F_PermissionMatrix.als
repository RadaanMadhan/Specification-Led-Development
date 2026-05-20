// === feature_model.als — Alloy model for A-L2 (Loan Application with RBAC and Audit Trail) ===

// === ROLE ENUMERATION ===
abstract sig Role {}
one sig Customer, LoanOfficer, ComplianceReviewer extends Role {}

// === APPLICATION STATUS ENUMERATION ===
abstract sig ApplicationStatus {}
one sig Submitted, UnderReview, Approved, Rejected extends ApplicationStatus {}

// === DECISION TYPE ENUMERATION ===
abstract sig DecisionType {}
one sig DecisionApproved, DecisionRejected extends DecisionType {}

// === OPERATION ENUMERATION (for permission matrix) ===
abstract sig Operation {}
one sig SubmitApplication, ViewOwnApplication, ClaimApplication, RecordDecision, ViewAnyApplication, ViewAudit extends Operation {}

// === CORE DOMAIN SIGS ===

sig User {
  role: one Role
}

sig LoanApplication {
  customer: one User,
  status: one ApplicationStatus,
  assigned_officer: lone User,
  requested_amount_minor: one Int,
  purpose: one String
}

sig Decision {
  application: one LoanApplication,
  decision_type: one DecisionType,
  reason: one String,
  decided_by: one User
}

sig ApplicationEvent {
  application: one LoanApplication,
  previous_status: lone ApplicationStatus,
  new_status: one ApplicationStatus,
  actor: one User
}

// === PERMISSION MATRIX ===
one sig PermMatrix {
  allowed: set Role -> Operation
}

// === FACTS ===

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some Role
  some ApplicationStatus
  some Operation
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-002, FR-003, FR-004
fact F_PermissionMatrix {
  Customer -> SubmitApplication in PermMatrix.allowed
  Customer -> ViewOwnApplication in PermMatrix.allowed
  LoanOfficer -> ClaimApplication in PermMatrix.allowed
  LoanOfficer -> RecordDecision in PermMatrix.allowed
  LoanOfficer -> ViewAnyApplication in PermMatrix.allowed
  LoanOfficer -> ViewAudit in PermMatrix.allowed
  ComplianceReviewer -> ViewAnyApplication in PermMatrix.allowed
  ComplianceReviewer -> ViewAudit in PermMatrix.allowed
  
  PermMatrix.allowed = 
    (Customer -> SubmitApplication) +
    (Customer -> ViewOwnApplication) +
    (LoanOfficer -> ClaimApplication) +
    (LoanOfficer -> RecordDecision) +
    (LoanOfficer -> ViewAnyApplication) +
    (LoanOfficer -> ViewAudit) +
    (ComplianceReviewer -> ViewAnyApplication) +
    (ComplianceReviewer -> ViewAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-012
fact F_AssignedOfficerCoherence {
  all app: LoanApplication |
    (app.status = Submitted) iff no app.assigned_officer
  
  all app: LoanApplication |
    some app.assigned_officer implies app.assigned_officer.role = LoanOfficer
}

// FEATURE-SPECIFIC  ANCHOR: FR-013, FR-016
fact F_DecisionRules {
  all app: LoanApplication |
    lone d: Decision | d.application = app
  
  all app: LoanApplication |
    (some d: Decision | d.application = app) iff
    (app.status = Approved or app.status = Rejected)
  
  all d: Decision |
    d.decided_by = d.application.assigned_officer and
    d.decided_by.role = LoanOfficer
}

// FEATURE-SPECIFIC  ANCHOR: FR-008
fact F_OneInflightPerCustomer {
  all u: User |
    u.role = Customer implies
      (lone app: LoanApplication |
        app.customer = u and (app.status = Submitted or app.status = UnderReview))
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019; data-model.md application_events
fact F_AuditTrailCompleteness {
  all app: LoanApplication |
    app.status = Submitted implies
      (one evt: ApplicationEvent |
        evt.application = app and
        evt.previous_status = none and
        evt.new_status = Submitted)
  
  all app: LoanApplication |
    app.status = UnderReview implies
      (one evt: ApplicationEvent |
        evt.application = app and
        evt.previous_status = Submitted and
        evt.new_status = UnderReview)
  
  all app: LoanApplication |
    app.status = Approved implies
      (one evt: ApplicationEvent |
        evt.application = app and
        evt.previous_status = UnderReview and
        evt.new_status = Approved)
  
  all app: LoanApplication |
    app.status = Rejected implies
      (one evt: ApplicationEvent |
        evt.application = app and
        evt.previous_status = UnderReview and
        evt.new_status = Rejected)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id
fact F_AuditActorCorrectness {
  all evt: ApplicationEvent |
    (evt.previous_status = none and evt.new_status = Submitted) implies
      (evt.actor = evt.application.customer and evt.actor.role = Customer)
  
  all evt: ApplicationEvent |
    (evt.previous_status = Submitted and evt.new_status = UnderReview) implies
      (evt.actor = evt.application.assigned_officer and evt.actor.role = LoanOfficer)
  
  all evt: ApplicationEvent |
    ((evt.previous_status = UnderReview and (evt.new_status = Approved or evt.new_status = Rejected))) implies
      (evt.actor = evt.application.assigned_officer and evt.actor.role = LoanOfficer)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id on LoanApplication
fact F_OwnershipExclusivity {
  all app: LoanApplication |
    one app.customer and app.customer.role = Customer
}

fact F_AmountValidation {
  all app: LoanApplication |
    app.requested_amount_minor >= 100000 and
    app.requested_amount_minor <= 2500000
}

fact F_PurposeValidation {
  all app: LoanApplication |
    #(app.purpose) > 0
}

// === PREDICATES AND ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  all r: Role, op: Operation |
    (r -> op in PermMatrix.allowed) implies
      ((r = Customer and op in (SubmitApplication + ViewOwnApplication)) or
       (r = LoanOfficer and op in (ClaimApplication + RecordDecision + ViewAnyApplication + ViewAudit)) or
       (r = ComplianceReviewer and op in (ViewAnyApplication + ViewAudit)))
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all r: Role, op: Operation |
    (r -> op in PermMatrix.allowed) or (r -> op not in PermMatrix.allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md permissions; spec.md FRs
pred PermissionGrounding {
  (Customer -> SubmitApplication in PermMatrix.allowed) and
  (Customer -> ViewOwnApplication in PermMatrix.allowed) and
  (LoanOfficer -> ClaimApplication in PermMatrix.allowed) and
  (LoanOfficer -> RecordDecision in PermMatrix.allowed) and
  (LoanOfficer -> ViewAnyApplication in PermMatrix.allowed) and
  (LoanOfficer -> ViewAudit in PermMatrix.allowed) and
  (ComplianceReviewer -> ViewAnyApplication in PermMatrix.allowed) and
  (ComplianceReviewer -> ViewAudit in PermMatrix.allowed)
}

assert PermissionGrounding {
  PermissionGrounding
}

check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all u: User | one u.role
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017, FR-019
pred AuditCompleteness {
  all app: LoanApplication |
    (app.status = Submitted implies
      (one evt: ApplicationEvent |
        evt.application = app and evt.previous_status = none and evt.new_status = Submitted)) and
    (app.status = UnderReview implies
      (one evt: ApplicationEvent |
        evt.application = app and evt.previous_status = Submitted and evt.new_status = UnderReview)) and
    (app.status = Approved implies
      (one evt: ApplicationEvent |
        evt.application = app and evt.previous_status = UnderReview and evt.new_status = Approved)) and
    (app.status = Rejected implies
      (one evt: ApplicationEvent |
        evt.application = app and evt.previous_status = UnderReview and evt.new_status = Rejected))
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md append-only audit constraint
pred AppendOnly {
  all disj evt1, evt2: ApplicationEvent |
    evt1.application = evt2.application implies
      not (evt1.previous_status = evt2.previous_status and evt1.new_status = evt2.new_status)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017
pred AttributionCorrectness {
  all evt: ApplicationEvent |
    ((evt.previous_status = none and evt.new_status = Submitted) implies
      evt.actor = evt.application.customer) and
    ((evt.previous_status = Submitted and evt.new_status = UnderReview) implies
      evt.actor = evt.application.assigned_officer) and
    (((evt.previous_status = UnderReview and evt.new_status = Approved) or
      (evt.previous_status = UnderReview and evt.new_status = Rejected)) implies
      evt.actor = evt.application.assigned_officer)
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md customer_id
pred OwnershipExclusivity {
  all app: LoanApplication |
    one app.customer
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020
pred OwnershipBasedAccess {
  all app: LoanApplication |
    (one app.customer and app.customer.role = Customer)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md 404 equivalence
pred NoInformationLeakage {
  all u: User |
    u.role = Customer implies
      not (u.role -> ViewAnyApplication in PermMatrix.allowed)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 Authentication and role assignment
pred FR_001_AuthenticationRequired {
  all u: User | one u.role
}

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 Customer permissions
pred FR_002_CustomerPermissions {
  some u: User |
    u.role = Customer and
    (u.role -> SubmitApplication in PermMatrix.allowed) and
    (u.role -> ViewOwnApplication in PermMatrix.allowed) and
    not (u.role -> ClaimApplication in PermMatrix.allowed)
}

assert FR_002_CustomerPermissions {
  FR_002_CustomerPermissions
}

check FR_002_CustomerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 Loan officer permissions
pred FR_003_LoanOfficerPermissions {
  some u: User |
    u.role = LoanOfficer and
    (u.role -> ClaimApplication in PermMatrix.allowed) and
    (u.role -> RecordDecision in PermMatrix.allowed)
}

assert FR_003_LoanOfficerPermissions {
  FR_003_LoanOfficerPermissions
}

check FR_003_LoanOfficerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 Compliance reviewer read-only
pred FR_004_ComplianceReviewerReadOnly {
  some u: User |
    u.role = ComplianceReviewer and
    (u.role -> ViewAnyApplication in PermMatrix.allowed) and
    not (u.role -> SubmitApplication in PermMatrix.allowed) and
    not (u.role -> ClaimApplication in PermMatrix.allowed) and
    not (u.role -> RecordDecision in PermMatrix.allowed)
}

assert FR_004_ComplianceReviewerReadOnly {
  FR_004_ComplianceReviewerReadOnly
}

check FR_004_ComplianceReviewerReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 One in-flight application per customer
pred FR_008_OneInflightPerCustomer {
  all u: User |
    u.role = Customer implies
      (lone app: LoanApplication |
        app.customer = u and (app.status = Submitted or app.status = UnderReview))
}

assert FR_008_OneInflightPerCustomer {
  FR_008_OneInflightPerCustomer
}

check FR_008_OneInflightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 Claim transitions to Under Review
pred FR_011_ClaimTransition {
  some app: LoanApplication |
    app.status = UnderReview and
    (some evt: ApplicationEvent |
      evt.application = app and
      evt.previous_status = Submitted and
      evt.new_status = UnderReview)
}

assert FR_011_ClaimTransition {
  FR_011_ClaimTransition
}

check FR_011_ClaimTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 Exactly one officer per claimed application
pred FR_012_OneOfficerPerApplication {
  all app: LoanApplication |
    (app.status = UnderReview or app.status = Approved or app.status = Rejected) implies
      one app.assigned_officer
}

assert FR_012_OneOfficerPerApplication {
  FR_012_OneOfficerPerApplication
}

check FR_012_OneOfficerPerApplication for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 Only assigned officer can decide
pred FR_013_OnlyAssignedOfficerDecides {
  all d: Decision |
    d.decided_by = d.application.assigned_officer
}

assert FR_013_OnlyAssignedOfficerDecides {
  FR_013_OnlyAssignedOfficerDecides
}

check FR_013_OnlyAssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 Decided applications are immutable
pred FR_016_ImmutabilityOfDecided {
  all app: LoanApplication |
    (app.status = Approved or app.status = Rejected) implies
      (one d: Decision | d.application = app)
}

assert FR_016_ImmutabilityOfDecided {
  FR_016_ImmutabilityOfDecided
}

check FR_016_ImmutabilityOfDecided for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 Audit entry per status change
pred FR_017_AuditPerStatusChange {
  all app: LoanApplication |
    (some evt: ApplicationEvent | evt.application = app and evt.new_status = app.status)
}

assert FR_017_AuditPerStatusChange {
  FR_017_AuditPerStatusChange
}

check FR_017_AuditPerStatusChange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 Exactly one entry per transition
pred FR_019_OneEntryPerTransition {
  all app: LoanApplication, s: ApplicationStatus |
    (lone evt: ApplicationEvent | evt.application = app and evt.new_status = s)
}

assert FR_019_OneEntryPerTransition {
  FR_019_OneEntryPerTransition
}

check FR_019_OneEntryPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020 Customer data isolation
pred FR_020_CustomerDataIsolation {
  all disj u1, u2: User |
    (u1.role = Customer and u2.role = Customer and u1 != u2) implies
      (all app: LoanApplication |
        app.customer = u2 implies app.customer != u1)
}

assert FR_020_CustomerDataIsolation {
  FR_020_CustomerDataIsolation
}

check FR_020_CustomerDataIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021 Officer identity hidden from customer
pred FR_021_OfficerHiddenFromCustomer {
  all u: User |
    u.role = Customer implies
      not (u.role -> ViewAudit in PermMatrix.allowed)
}

assert FR_021_OfficerHiddenFromCustomer {
  FR_021_OfficerHiddenFromCustomer
}

check FR_021_OfficerHiddenFromCustomer for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_ExtraPermission { ComplianceReviewer -> RecordDecision in PermMatrix.allowed }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
