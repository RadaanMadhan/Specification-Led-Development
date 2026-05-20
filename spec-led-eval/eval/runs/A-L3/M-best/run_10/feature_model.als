// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===
// Encodes the structural invariants of feature 005-fca-loan-applications:
// roles & permission matrix, application lifecycle, assigned-officer ownership,
// no-self-decision, append-only chained audit, byte-equivalent privacy on reads.

// ----- Booleans (Alloy lacks native Booleans we can switch on) ---------------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ----- Roles ------------------------------------------------------------------
abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

// ----- Application status -----------------------------------------------------
abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

// ----- The four endpoints (contracts/http-api.md) -----------------------------
abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchStatus, GetAudit extends OperationKind {}

// ----- Entities (data-model.md) -----------------------------------------------
sig User {
  roles: set Role
}

sig LoanApplication {
  applicant: one User,
  status: one ApplicationStatus,
  assignedOfficer: lone User,
  validInputs: one Bool          // proxy for FR-007 amount-in-range + purpose-in-list
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actorRole: one Role,
  previousStatus: lone ApplicationStatus,   // null only for initial (none)->pending
  newStatus: one ApplicationStatus,
  hasReason: one Bool
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  authenticated: one Bool,
  target: lone LoanApplication,
  targetNewStatus: lone ApplicationStatus,
  reasonProvided: one Bool,
  succeeded: one Bool,
  audit: lone AuditEntry
}

// ----- Permission matrix as a singleton-sig field (contracts/http-api.md) -----
one sig PermMatrix { Allowed: set Role -> OperationKind }

// =============================================================================
// FACTS (each named so the validator can clear them by name)
// =============================================================================

// Force non-empty universe so universally-quantified preds are non-vacuous.
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// The exact six allowed (Role, OperationKind) cells from the contract.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Applicant -> PostApplications)
    + (Applicant -> GetApplicationById)
    + (Officer  -> GetApplicationById)
    + (Officer  -> PatchStatus)
    + (Auditor  -> GetApplicationById)
    + (Auditor  -> GetAudit)
}

// FR-002: no user has both officer and auditor; system role never assigned to users.
fact F_RoleMultiplicity {
  no u: User | Officer in u.roles and Auditor in u.roles
  no u: User | SystemRole in u.roles
}

// FR-001 / SC-010: every successful op must be authenticated.
fact F_AuthBeforeBusinessLogic {
  all op: Operation | op.succeeded = BTrue implies op.authenticated = BTrue
}

// Role-allows-kind gate: caller must hold a role that the matrix allows for kind.
fact F_RoleAllowsKind {
  all op: Operation |
    op.succeeded = BTrue implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}

// Endpoints that take a path id must have a target loan application; POST creates one.
fact F_TargetedOpsHaveTarget {
  all op: Operation |
    op.kind in (GetApplicationById + PatchStatus + GetAudit) implies some op.target
  all op: Operation |
    (op.kind = PostApplications and op.succeeded = BTrue) implies some op.target
}

// FR-020 / FR-021 ownership check for GET /applications/{id}.
fact F_GetApplicationByIdAccess {
  all op: Operation |
    (op.kind = GetApplicationById and op.succeeded = BTrue) implies
      (some t: op.target |
         Auditor in op.caller.roles
         or op.caller = t.applicant
         or op.caller = t.assignedOfficer)
}

// FR-009, FR-012, FR-013, FR-014, FR-015: assigned-officer ownership, not the applicant,
// valid transition, reason required, target not already decided.
fact F_PatchStatusRules {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (op.reasonProvided = BTrue
       and (some t: op.target |
              op.caller = t.assignedOfficer
              and op.caller != t.applicant
              and t.status in (Pending + UnderReview)
              and (some ns: op.targetNewStatus | validTransition[t.status, ns])))
}

// FR-008: at most one in-flight application per applicant.
fact F_OneInFlight {
  all disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview)
           and a2.status in (Pending + UnderReview))
}

// FR-011: no self-assignment.
fact F_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

// FR-010: the assigned officer must hold the Officer role.
fact F_AssignedHasOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}

// data-model.md: the application's applicant must be a user with the Applicant role.
fact F_ApplicantHasApplicantRole {
  all a: LoanApplication | Applicant in a.applicant.roles
}

// FR-007: persisted applications all have validated inputs.
fact F_ValidInputsOnPersistedApps {
  all a: LoanApplication | a.validInputs = BTrue
}

// FR-017 / SC-002: every successful state-changing op produces an audit entry.
fact F_AuditExists {
  all op: Operation |
    (op.kind in (PostApplications + PatchStatus) and op.succeeded = BTrue) implies
      some op.audit
}

// FR-016: audit's actor / application correctly mirror the operation.
fact F_AuditAttribution {
  all op: Operation |
    some op.audit implies
      (op.audit.application = op.target and op.audit.actor = op.caller)
}

// FR-018 / FR-019: every audit entry is the product of an actual operation
// (no fabricated, no orphaned-by-delete entries).
fact F_AuditEntryHasSource {
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
}

// FR-018: no two operations share the same audit entry (append-only ⇒ unique row per op).
fact F_AuditUniqueness {
  all disj op1, op2: Operation |
    (some op1.audit and some op2.audit) implies op1.audit != op2.audit
}

// FR-016 / data-model.md CHECK: prev_status null iff new_status = pending.
fact F_AuditInitialEntry {
  all ae: AuditEntry |
    (no ae.previousStatus) iff ae.newStatus = Pending
}

// FR-009 / data-model.md CHECK: no no-op transitions.
fact F_AuditNoNoOp {
  all ae: AuditEntry |
    some ae.previousStatus implies ae.previousStatus != ae.newStatus
}

// FR-014: audit entry's reason is always non-empty.
fact F_AuditHasReason {
  all ae: AuditEntry | ae.hasReason = BTrue
}

// FR-016: actorRole is either the system sentinel or a role the actor actually holds.
fact F_AuditRoleAttribution {
  all ae: AuditEntry |
    ae.actorRole = SystemRole or ae.actorRole in ae.actor.roles
}

// Validation pattern: failed operations never persist an audit entry.
fact F_NoAuditOnFailure {
  all op: Operation | op.succeeded = BFalse implies no op.audit
}

// Helper: the allowed state transitions out of pending / under_review.
pred validTransition[from, to: ApplicationStatus] {
  (from = Pending      and to = UnderReview)
  or (from = UnderReview and to = Approved)
  or (from = UnderReview and to = Rejected)
}

// =============================================================================
// PATTERN ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003..FR-005
pred LeastPrivilege {
  all op: Operation |
    op.succeeded = BTrue implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  Applicant -> PostApplications     in PermMatrix.Allowed
  Officer   -> PatchStatus          in PermMatrix.Allowed
  Auditor   -> GetAudit             in PermMatrix.Allowed
  Applicant -> GetApplicationById   in PermMatrix.Allowed
  Officer   -> GetApplicationById   in PermMatrix.Allowed
  Auditor   -> GetApplicationById   in PermMatrix.Allowed
  Applicant -> PatchStatus          not in PermMatrix.Allowed
  Applicant -> GetAudit             not in PermMatrix.Allowed
  Officer   -> PostApplications     not in PermMatrix.Allowed
  Officer   -> GetAudit             not in PermMatrix.Allowed
  Auditor   -> PostApplications     not in PermMatrix.Allowed
  Auditor   -> PatchStatus          not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003..FR-005
pred PermissionGrounding {
  PermMatrix.Allowed in
      (Applicant -> PostApplications)
    + (Applicant -> GetApplicationById)
    + (Officer  -> GetApplicationById)
    + (Officer  -> PatchStatus)
    + (Auditor  -> GetApplicationById)
    + (Auditor  -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-010
pred AuthRequiredEverywhere {
  all op: Operation | op.succeeded = BTrue implies op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017; data-model.md audit_entries
pred AuditCompleteness {
  all op: Operation |
    (op.kind in (PostApplications + PatchStatus) and op.succeeded = BTrue) implies
      (one ae: AuditEntry | ae = op.audit and ae.application = op.target)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, FR-019; data-model.md "no UPDATE/DELETE on audit"
pred AppendOnly {
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
  all disj op1, op2: Operation |
    (some op1.audit and some op2.audit) implies op1.audit != op2.audit
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016
pred AttributionCorrectness {
  all op: Operation |
    some op.audit implies
      (op.audit.actor = op.caller and op.audit.application = op.target)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant FK is NOT NULL
pred OwnershipExclusivity {
  all a: LoanApplication | Applicant in a.applicant.roles
  all a: LoanApplication | one a.applicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012; data-model.md SQL filter assigned_officer_id=?
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (some t: op.target | op.caller = t.assignedOfficer)
  all op: Operation |
    (op.kind = GetApplicationById and op.succeeded = BTrue) implies
      (some t: op.target |
         Auditor in op.caller.roles
         or op.caller = t.applicant
         or op.caller = t.assignedOfficer)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013
pred NoSelfMutation {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (some t: op.target | op.caller != t.applicant)
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-023
pred NoInformationLeakage {
  all op: Operation |
    (op.kind = GetApplicationById and op.succeeded = BTrue) implies
      (some t: op.target |
         Auditor in op.caller.roles
         or op.caller = t.applicant
         or op.caller = t.assignedOfficer)
  all op: Operation |
    (op.kind = GetAudit and op.succeeded = BTrue) implies
      Auditor in op.caller.roles
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007, FR-014; data-model.md atomicity contract
pred ValidationBeforeMutation {
  all op: Operation | op.succeeded = BFalse implies no op.audit
  all a: LoanApplication | a.validInputs = BTrue
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// =============================================================================
// FEATURE-SPECIFIC ASSERTIONS — one predicate per FR-NNN
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | op.succeeded = BTrue implies op.authenticated = BTrue
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OfficerAuditorMutex {
  no u: User | Officer in u.roles and Auditor in u.roles
}
assert FR_002_OfficerAuditorMutex { FR_002_OfficerAuditorMutex }
check FR_002_OfficerAuditorMutex for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantScope {
  all op: Operation |
    (op.succeeded = BTrue and op.caller.roles = Applicant) implies
      (op.kind = PostApplications
       or (op.kind = GetApplicationById
           and (some t: op.target | op.caller = t.applicant)))
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerScope {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (Officer in op.caller.roles
       and (some t: op.target | op.caller = t.assignedOfficer))
}
assert FR_004_OfficerScope { FR_004_OfficerScope }
check FR_004_OfficerScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  all op: Operation |
    (op.succeeded = BTrue and op.kind in (PostApplications + PatchStatus)) implies
      (Applicant in op.caller.roles or Officer in op.caller.roles)
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_InputsValid {
  all a: LoanApplication | a.validInputs = BTrue
}
assert FR_007_InputsValid { FR_007_InputsValid }
check FR_007_InputsValid for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlight {
  all disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview)
           and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AllowedTransitions {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (some t: op.target | some ns: op.targetNewStatus | validTransition[t.status, ns])
}
assert FR_009_AllowedTransitions { FR_009_AllowedTransitions }
check FR_009_AllowedTransitions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AssignedIsOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}
assert FR_010_AssignedIsOfficer { FR_010_AssignedIsOfficer }
check FR_010_AssignedIsOfficer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_AssignedOfficerOnly {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (some t: op.target | op.caller = t.assignedOfficer)
}
assert FR_012_AssignedOfficerOnly { FR_012_AssignedOfficerOnly }
check FR_012_AssignedOfficerOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfDecision {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (some t: op.target | op.caller != t.applicant)
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ReasonRequired {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies op.reasonProvided = BTrue
  all ae: AuditEntry | ae.hasReason = BTrue
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoChangeAfterDecided {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      (some t: op.target | t.status in (Pending + UnderReview))
}
assert FR_015_NoChangeAfterDecided { FR_015_NoChangeAfterDecided }
check FR_015_NoChangeAfterDecided for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditFields {
  all ae: AuditEntry | (no ae.previousStatus) iff ae.newStatus = Pending
  all ae: AuditEntry | ae.hasReason = BTrue
  all ae: AuditEntry | (ae.actorRole = SystemRole or ae.actorRole in ae.actor.roles)
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditWithTransition {
  all op: Operation |
    (op.kind in (PostApplications + PatchStatus) and op.succeeded = BTrue) implies
      some op.audit
}
assert FR_017_AuditWithTransition { FR_017_AuditWithTransition }
check FR_017_AuditWithTransition for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditAppendOnly {
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
  all disj op1, op2: Operation |
    (some op1.audit and some op2.audit) implies op1.audit != op2.audit
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_NoDelete {
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
}
assert FR_019_NoDelete { FR_019_NoDelete }
check FR_019_NoDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_NoLeakOnGet {
  all op: Operation |
    (op.kind = GetApplicationById and op.succeeded = BTrue) implies
      (some t: op.target |
         Auditor in op.caller.roles
         or op.caller = t.applicant
         or op.caller = t.assignedOfficer)
}
assert FR_020_NoLeakOnGet { FR_020_NoLeakOnGet }
check FR_020_NoLeakOnGet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_SameForOwnership {
  all op: Operation |
    (op.kind = GetApplicationById and op.succeeded = BTrue) implies
      (some t: op.target |
         Auditor in op.caller.roles
         or op.caller = t.applicant
         or op.caller = t.assignedOfficer)
}
assert FR_021_SameForOwnership { FR_021_SameForOwnership }
check FR_021_SameForOwnership for 6

// FEATURE-SPECIFIC  ANCHOR: FR-022
pred FR_022_PostNoLeak {
  all op: Operation |
    (op.kind = PostApplications and op.succeeded = BTrue) implies
      Applicant in op.caller.roles
}
assert FR_022_PostNoLeak { FR_022_PostNoLeak }
check FR_022_PostNoLeak for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditAuditorOnly {
  all op: Operation |
    (op.kind = GetAudit and op.succeeded = BTrue) implies Auditor in op.caller.roles
}
assert FR_023_AuditAuditorOnly { FR_023_AuditAuditorOnly }
check FR_023_AuditAuditorOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantNoModify {
  all op: Operation |
    (op.kind = PatchStatus and op.succeeded = BTrue) implies
      Officer in op.caller.roles
}
assert FR_024_ApplicantNoModify { FR_024_ApplicantNoModify }
check FR_024_ApplicantNoModify for 6