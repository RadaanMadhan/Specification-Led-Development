// === feature_model.als — Alloy model for Loan Application RBAC with Audit Trail ===
// Feature: A-L2  (branch 004-loan-application-rbac)
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ── Role hierarchy ────────────────────────────────────────────────────────
abstract sig Role {}
one sig Customer          extends Role {}
one sig LoanOfficer       extends Role {}
one sig ComplianceReviewer extends Role {}

// ── Application status set ────────────────────────────────────────────────
abstract sig ApplicationStatus {}
one sig Submitted   extends ApplicationStatus {}
one sig UnderReview extends ApplicationStatus {}
one sig Approved    extends ApplicationStatus {}
one sig Rejected    extends ApplicationStatus {}

// ── Decision outcome ──────────────────────────────────────────────────────
abstract sig DecisionOutcome {}
one sig DecApproved extends DecisionOutcome {}
one sig DecRejected extends DecisionOutcome {}

// ── Endpoint / operation kinds (from contracts/http-api.md) ──────────────
abstract sig OperationKind {}
one sig PostApplications   extends OperationKind {} // POST /applications
one sig GetApplications    extends OperationKind {} // GET  /applications
one sig GetApplicationById extends OperationKind {} // GET  /applications/{ref}
one sig PostClaim          extends OperationKind {} // POST /applications/{ref}/claim
one sig PostDecision       extends OperationKind {} // POST /applications/{ref}/decision
one sig GetAudit           extends OperationKind {} // GET  /applications/{ref}/audit

// ── Permission matrix (singleton carrier) ────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ── Domain sigs ───────────────────────────────────────────────────────────
sig User { role: one Role }

sig LoanApplication {
    customer        : one  User,
    status          : one  ApplicationStatus,
    assignedOfficer : lone User
}

sig Decision {
    application  : one LoanApplication,
    decisionType : one DecisionOutcome,
    decidedBy    : one User
}

sig AuditEntry {
    application : one  LoanApplication,
    actor       : one  User,
    prevStatus  : lone ApplicationStatus,   // none ↔ initial submission
    newStatus   : one  ApplicationStatus
}

// ═════════════════════════════════════════════════════════════════════════
//  NON-EMPTY UNIVERSE
// ═════════════════════════════════════════════════════════════════════════
fact F_NonEmptyUniverse {
    some User
    some LoanApplication
    some Decision
    some AuditEntry
}

// ═════════════════════════════════════════════════════════════════════════
//  STRUCTURAL DOMAIN FACTS
// ═════════════════════════════════════════════════════════════════════════

// Each application's customer field must reference a Customer-role user.
fact F_CustomerOwnsApplication {
    all app: LoanApplication | app.customer.role = Customer
}

// Any assigned officer must have the LoanOfficer role.
fact F_AssignedOfficerIsLoanOfficer {
    all app: LoanApplication |
        some app.assignedOfficer implies app.assignedOfficer.role = LoanOfficer
}

// data-model.md CHECK: (status='Submitted') ↔ (assignedOfficer IS NULL)
fact F_SubmittedIffNoOfficer {
    all app: LoanApplication |
        (app.status = Submitted) iff (no app.assignedOfficer)
}

// A Decision exists iff the application is Approved or Rejected.
fact F_DecisionIffDecidedStatus {
    all d: Decision | d.application.status in (Approved + Rejected)
    all app: LoanApplication |
        (app.status in (Approved + Rejected)) iff
        (one d: Decision | d.application = app)
}

// At most one Decision per LoanApplication (PK on decisions.application_id).
fact F_OneDecisionPerApplication {
    all disj d1, d2: Decision | d1.application != d2.application
}

// The deciding user must be the application's assigned officer.
fact F_DecisionByAssignedOfficer { /* MUTATED — body cleared by validator */ }

// The deciding user must hold the LoanOfficer role.
fact F_DecisionDeciderIsOfficer {
    all d: Decision | d.decidedBy.role = LoanOfficer
}

// FR-008: a customer may not have more than one in-flight application.
fact F_OneInFlightPerCustomer {
    all disj a1, a2: LoanApplication |
        a1.customer = a2.customer implies
        not (a1.status in (Submitted + UnderReview) and
             a2.status in (Submitted + UnderReview))
}

// ═════════════════════════════════════════════════════════════════════════
//  AUDIT-TRAIL STRUCTURAL FACTS
// ═════════════════════════════════════════════════════════════════════════

// data-model.md CHECK: (previous_status IS NULL) ↔ (new_status = 'Submitted')
fact F_AuditNullPrevOnlyForSubmission {
    all ae: AuditEntry |
        (no ae.prevStatus) iff (ae.newStatus = Submitted)
}

// data-model.md CHECK: previous_status IS NULL OR previous_status <> new_status
fact F_AuditNoNoop {
    all ae: AuditEntry |
        some ae.prevStatus implies ae.prevStatus != ae.newStatus
}

// Valid state-machine transitions only:
//   Submitted → UnderReview
//   UnderReview → Approved | Rejected
//   Approved / Rejected → (nothing)
fact F_ValidStatusTransitions {
    all ae: AuditEntry | some ae.prevStatus implies {
        (ae.prevStatus = Submitted   implies ae.newStatus = UnderReview)
        (ae.prevStatus = UnderReview implies ae.newStatus in (Approved + Rejected))
        ae.prevStatus not in (Approved + Rejected)
    }
}

// FR-016: no audit entry records a transition away from a terminal state.
fact F_DecidedApplicationNoFurtherTransitions {
    all ae: AuditEntry |
        some ae.prevStatus implies ae.prevStatus not in (Approved + Rejected)
}

// FR-019: no two entries for the same application record the same (prev, new) pair.
fact F_AppendOnlyAudit {
    all disj ae1, ae2: AuditEntry |
        ae1.application = ae2.application implies
        not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}

// FR-017/FR-009: every application has exactly one initial submission entry.
fact F_OneSubmissionEntryPerApplication {
    all app: LoanApplication |
        one ae: AuditEntry | ae.application = app and no ae.prevStatus
}

// Actor role attribution:
//   submission entry actor → Customer
//   subsequent entry actor → LoanOfficer
fact F_AuditActorRoleMatchesTransition {
    all ae: AuditEntry |
        (no ae.prevStatus)   implies ae.actor.role = LoanOfficer or ae.actor.role = Customer
    all ae: AuditEntry |
        (no ae.prevStatus)   implies ae.actor.role = Customer
    all ae: AuditEntry |
        (some ae.prevStatus) implies ae.actor.role = LoanOfficer
}

// FR-009: the actor on the submission entry IS the application's customer.
fact F_AuditSubmissionActorIsApplicant {
    all ae: AuditEntry |
        (no ae.prevStatus) implies ae.actor = ae.application.customer
}

// ═════════════════════════════════════════════════════════════════════════
//  PERMISSION-MATRIX FACT
// ═════════════════════════════════════════════════════════════════════════

// contracts/http-api.md permission table (closed-world, 11 allowed cells).
fact F_PermissionMatrix {
    PermMatrix.Allowed =
        (Customer           -> PostApplications)   +
        (Customer           -> GetApplications)    +
        (Customer           -> GetApplicationById) +
        (LoanOfficer        -> GetApplications)    +
        (LoanOfficer        -> GetApplicationById) +
        (LoanOfficer        -> PostClaim)          +
        (LoanOfficer        -> PostDecision)       +
        (LoanOfficer        -> GetAudit)           +
        (ComplianceReviewer -> GetApplications)    +
        (ComplianceReviewer -> GetApplicationById) +
        (ComplianceReviewer -> GetAudit)
}

// FR-004/FR-023: ComplianceReviewer has no write operations in the matrix.
fact F_ComplianceReadOnly {
    ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
    ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
    ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
}

// ═════════════════════════════════════════════════════════════════════════
//  CATALOGUE PATTERN PREDICATES + ASSERTIONS
// ═════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-002/FR-003/FR-004
pred LeastPrivilege {
    some LoanApplication
    // Denied cells must be absent from the allowed relation.
    LoanOfficer        -> PostApplications not in PermMatrix.Allowed
    ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
    Customer           -> PostClaim        not in PermMatrix.Allowed
    ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
    Customer           -> PostDecision     not in PermMatrix.Allowed
    ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
    Customer           -> GetAudit         not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
    some LoanApplication
    // The allowed set must have exactly 11 (Role, Operation) cells.
    #(PermMatrix.Allowed) = 11
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: contracts/http-api.md; spec.md FR-003/FR-004
// ComplianceReviewer read permissions ⊆ LoanOfficer read permissions (on get operations).
pred PrivilegeMonotonicity {
    some LoanApplication
    // Any read op allowed for ComplianceReviewer is also allowed for LoanOfficer.
    all op: GetApplications + GetApplicationById + GetAudit |
        (ComplianceReviewer -> op in PermMatrix.Allowed) implies
        (LoanOfficer -> op in PermMatrix.Allowed)
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
    some User
    // Every user has exactly one role (the auth system resolves it before any handler logic).
    all u: User | one u.role
    // Every user's role is one of the three defined roles.
    all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-017/FR-019; data-model.md UNIQUE application_events
pred AuditCompleteness {
    some LoanApplication
    some AuditEntry
    // Every application has at least one audit entry.
    all app: LoanApplication | some ae: AuditEntry | ae.application = app
    // Every application has exactly one initial submission entry (prevStatus absent).
    all app: LoanApplication | one ae: AuditEntry | ae.application = app and no ae.prevStatus
    // No two entries on the same application share the same (prev, new) pair.
    all app: LoanApplication |
        all disj ae1, ae2: AuditEntry |
            (ae1.application = app and ae2.application = app) implies
            not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE" on application_events
pred AppendOnly {
    some AuditEntry
    // The null-prevStatus ↔ Submitted invariant must hold globally.
    all ae: AuditEntry | (no ae.prevStatus) iff (ae.newStatus = Submitted)
    // No two entries for the same application share the same (prev, new) pair
    // (structural proxy for "no entry was overwritten in place").
    all disj ae1, ae2: AuditEntry |
        ae1.application = ae2.application implies
        not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
    // No entry represents a transition from a terminal status.
    all ae: AuditEntry |
        some ae.prevStatus implies ae.prevStatus not in (Approved + Rejected)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-017; data-model.md actor_user_id field
pred AttributionCorrectness {
    some AuditEntry
    // Submission entries are attributed to a Customer.
    all ae: AuditEntry | (no ae.prevStatus) implies ae.actor.role = Customer
    // Post-submission entries are attributed to a LoanOfficer.
    all ae: AuditEntry | (some ae.prevStatus) implies ae.actor.role = LoanOfficer
    // Submission entry actor IS the application's own customer.
    all ae: AuditEntry | (no ae.prevStatus) implies ae.actor = ae.application.customer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.customer_id; spec.md FR-005
pred OwnershipExclusivity {
    some LoanApplication
    // Each application is owned by exactly one Customer-role user.
    all app: LoanApplication | one app.customer and app.customer.role = Customer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-020; contracts/http-api.md customer ownership conditional
pred OwnershipBasedAccess {
    some LoanApplication
    // Customer may call GetApplicationById (own-only gate enforced at service layer).
    Customer -> GetApplicationById in PermMatrix.Allowed
    // LoanOfficer and ComplianceReviewer may call GetApplicationById unconditionally.
    LoanOfficer        -> GetApplicationById in PermMatrix.Allowed
    ComplianceReviewer -> GetApplicationById in PermMatrix.Allowed
    // Applications belong to one customer only.
    all app: LoanApplication | app.customer.role = Customer
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020; contracts/http-api.md "404 not 403 for non-owner"
pred NoInformationLeakage {
    some LoanApplication
    // Customer cannot call GetAudit (audit trail reveals officer identity and all actors).
    Customer -> GetAudit not in PermMatrix.Allowed
    // Customer cannot call PostClaim or PostDecision (would reveal application state).
    Customer -> PostClaim    not in PermMatrix.Allowed
    Customer -> PostDecision not in PermMatrix.Allowed
    // ComplianceReviewer cannot call any write operation (no modification reveals internal state).
    ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
    ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
    ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ═════════════════════════════════════════════════════════════════════════
//  FEATURE-SPECIFIC PREDICATES + ASSERTIONS (one per FR-NNN)
// ═════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
    some User
    all u: User | one u.role
    all u: User | u.role in (Customer + LoanOfficer + ComplianceReviewer)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_CustomerPermissions {
    some User
    // Allowed for Customer.
    Customer -> PostApplications   in PermMatrix.Allowed
    Customer -> GetApplications    in PermMatrix.Allowed
    Customer -> GetApplicationById in PermMatrix.Allowed
    // Denied for Customer.
    Customer -> PostClaim    not in PermMatrix.Allowed
    Customer -> PostDecision not in PermMatrix.Allowed
    Customer -> GetAudit     not in PermMatrix.Allowed
}
assert FR_002_CustomerPermissions { FR_002_CustomerPermissions }
check FR_002_CustomerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_LoanOfficerPermissions {
    some User
    // Allowed for LoanOfficer.
    LoanOfficer -> GetApplications    in PermMatrix.Allowed
    LoanOfficer -> GetApplicationById in PermMatrix.Allowed
    LoanOfficer -> PostClaim          in PermMatrix.Allowed
    LoanOfficer -> PostDecision       in PermMatrix.Allowed
    LoanOfficer -> GetAudit           in PermMatrix.Allowed
    // Denied for LoanOfficer.
    LoanOfficer -> PostApplications not in PermMatrix.Allowed
}
assert FR_003_LoanOfficerPermissions { FR_003_LoanOfficerPermissions }
check FR_003_LoanOfficerPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 / FR-023
pred FR_004_ComplianceReadOnly {
    some User
    // ComplianceReviewer can read everything.
    ComplianceReviewer -> GetApplications    in PermMatrix.Allowed
    ComplianceReviewer -> GetApplicationById in PermMatrix.Allowed
    ComplianceReviewer -> GetAudit           in PermMatrix.Allowed
    // ComplianceReviewer cannot write anything.
    ComplianceReviewer -> PostApplications not in PermMatrix.Allowed
    ComplianceReviewer -> PostClaim        not in PermMatrix.Allowed
    ComplianceReviewer -> PostDecision     not in PermMatrix.Allowed
}
assert FR_004_ComplianceReadOnly { FR_004_ComplianceReadOnly }
check FR_004_ComplianceReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerCustomer {
    some LoanApplication
    all disj a1, a2: LoanApplication |
        a1.customer = a2.customer implies
        not (a1.status in (Submitted + UnderReview) and
             a2.status in (Submitted + UnderReview))
}
assert FR_008_OneInFlightPerCustomer { FR_008_OneInFlightPerCustomer }
check FR_008_OneInFlightPerCustomer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_SubmissionAuditEntry {
    some LoanApplication
    // Every application has exactly one submission audit entry.
    all app: LoanApplication |
        one ae: AuditEntry |
            ae.application = app and no ae.prevStatus and ae.newStatus = Submitted
    // The actor on that entry is the submitting customer.
    all ae: AuditEntry |
        (no ae.prevStatus) implies ae.actor = ae.application.customer
}
assert FR_009_SubmissionAuditEntry { FR_009_SubmissionAuditEntry }
check FR_009_SubmissionAuditEntry for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 / FR-012
pred FR_012_ExclusiveClaim {
    some LoanApplication
    // At most one Submitted→UnderReview audit entry per application.
    all app: LoanApplication |
        lone ae: AuditEntry |
            ae.application = app and
            ae.prevStatus = Submitted and
            ae.newStatus = UnderReview
    // Non-Submitted applications have exactly one assigned officer.
    all app: LoanApplication |
        app.status in (UnderReview + Approved + Rejected) implies
        (one app.assignedOfficer)
}
assert FR_012_ExclusiveClaim { FR_012_ExclusiveClaim }
check FR_012_ExclusiveClaim for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AssignedOfficerDecides {
    some Decision
    // The deciding officer on every decision is the application's assigned officer.
    all d: Decision | d.decidedBy = d.application.assignedOfficer
    // That officer holds the LoanOfficer role.
    all d: Decision | d.decidedBy.role = LoanOfficer
}
assert FR_013_AssignedOfficerDecides { FR_013_AssignedOfficerDecides }
check FR_013_AssignedOfficerDecides for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_DecisionAuditEntry {
    some Decision
    // Every decided application has exactly one terminal-transition audit entry.
    all d: Decision |
        one ae: AuditEntry |
            ae.application = d.application and
            ae.newStatus in (Approved + Rejected)
}
assert FR_015_DecisionAuditEntry { FR_015_DecisionAuditEntry }
check FR_015_DecisionAuditEntry for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_ImmutableDecided {
    some LoanApplication
    // No audit entry has a prevStatus that is a terminal state.
    all ae: AuditEntry |
        some ae.prevStatus implies ae.prevStatus not in (Approved + Rejected)
}
assert FR_016_ImmutableDecided { FR_016_ImmutableDecided }
check FR_016_ImmutableDecided for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditEntryForEveryChange {
    some LoanApplication
    some AuditEntry
    all app: LoanApplication | some ae: AuditEntry | ae.application = app
    all app: LoanApplication |
        one ae: AuditEntry | ae.application = app and no ae.prevStatus
}
assert FR_017_AuditEntryForEveryChange { FR_017_AuditEntryForEveryChange }
check FR_017_AuditEntryForEveryChange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditAppendOnly {
    some AuditEntry
    all ae: AuditEntry | (no ae.prevStatus) iff (ae.newStatus = Submitted)
    all ae: AuditEntry |
        some ae.prevStatus implies (
            ae.prevStatus != ae.newStatus and
            ae.prevStatus not in (Approved + Rejected)
        )
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_ExactlyOneAuditPerTransition {
    some AuditEntry
    all app: LoanApplication |
        all disj ae1, ae2: AuditEntry |
            (ae1.application = app and ae2.application = app) implies
            not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert FR_019_ExactlyOneAuditPerTransition { FR_019_ExactlyOneAuditPerTransition }
check FR_019_ExactlyOneAuditPerTransition for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_CustomerIsolation {
    some LoanApplication
    // Every application is owned by exactly one Customer-role user.
    all app: LoanApplication | app.customer.role = Customer
    // Customer cannot call GetAudit (cross-customer audit trail access).
    Customer -> GetAudit not in PermMatrix.Allowed
}
assert FR_020_CustomerIsolation { FR_020_CustomerIsolation }
check FR_020_CustomerIsolation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_OfficerIdentityHiddenFromCustomer {
    some LoanApplication
    // The only way to observe officer identity is via GetAudit or the full
    // application body — both require LoanOfficer or ComplianceReviewer role.
    Customer -> GetAudit     not in PermMatrix.Allowed
    Customer -> PostClaim    not in PermMatrix.Allowed
    Customer -> PostDecision not in PermMatrix.Allowed
}
assert FR_021_OfficerIdentityHiddenFromCustomer { FR_021_OfficerIdentityHiddenFromCustomer }
check FR_021_OfficerIdentityHiddenFromCustomer for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NonAssignedDecision { some d: Decision | some d.application.assignedOfficer and d.decidedBy != d.application.assignedOfficer }
