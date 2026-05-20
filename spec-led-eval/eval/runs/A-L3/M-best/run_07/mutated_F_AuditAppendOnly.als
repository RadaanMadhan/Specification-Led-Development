// === feature_model.als — Alloy model for FCA-Regulated Loan Application (005) ===
// Self-contained Alloy 6 model. Encodes role-based permission matrix,
// state-machine transitions, append-only audit log, ownership-based reads,
// byte-equivalent unauthorized response, and no-self-decision controls.

// ---------- Universe must be non-empty ----------
// (Without this, "all x: T | P[x]" predicates are vacuously true under
//  Alloy's default empty universe.)
sig User { roles: some Role }
sig LoanApplication {
  applicant: one User,
  assignedOfficer: lone User,
  status: one ApplicationStatus
}
sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actorRole: one Role,
  prevStatus: lone ApplicationStatus,
  newStatus: one ApplicationStatus
}
sig Operation {
  kind: one OperationKind,
  caller: lone User,
  authenticated: one Bool,
  target: lone LoanApplication,
  response: one Response,
  resultingAudit: lone AuditEntry
}

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------- Closed enums ----------

abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig Role {}
one sig ApplicantRole, OfficerRole, AuditorRole, SystemRole extends Role {}

abstract sig OperationKind {}
one sig PostApplication, GetApplication, PatchStatus, GetAudit extends OperationKind {}

abstract sig ApplicationStatus {}
one sig Pending, UnderReview, Approved, Rejected extends ApplicationStatus {}

abstract sig Response {}
one sig Ok, NotFound, ValidationError, Forbidden, Conflict, Unauthenticated, AuditUnavailable extends Response {}

// ---------- Permission matrix as singleton-sig field ----------

one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  // contracts/http-api.md permission table.
  PermMatrix.Allowed =
    (ApplicantRole -> PostApplication) +
    (ApplicantRole -> GetApplication) +
    (OfficerRole  -> GetApplication) +
    (OfficerRole  -> PatchStatus)    +
    (AuditorRole  -> GetApplication) +
    (AuditorRole  -> GetAudit)
}

// ---------- Helper predicate ----------

pred legitimateApplicationRead[op: Operation] {
  AuditorRole in op.caller.roles or
  op.caller = op.target.applicant or
  op.caller = op.target.assignedOfficer
}

// ---------- Domain facts (named, mutation-testable) ----------

fact F_AuthenticatedIffCaller {
  all op: Operation | (op.authenticated = True iff some op.caller)
}

fact F_RoleExclusivity {
  // FR-002: officer and auditor are mutually exclusive bank-staff roles.
  all u: User | not (OfficerRole in u.roles and AuditorRole in u.roles)
  // SystemRole is never assigned to a user.
  all u: User | SystemRole not in u.roles
}

fact F_ApplicantHasApplicantRole {
  // data-model.md: loan_applications.applicant_id references a user with applicant role.
  all a: LoanApplication | ApplicantRole in a.applicant.roles
}

fact F_AssignedOfficerIsOfficer {
  // FR-010: assigned officer must hold officer role.
  all a: LoanApplication |
    some a.assignedOfficer implies OfficerRole in a.assignedOfficer.roles
}

fact F_NoSelfAssignment {
  // FR-011: applicant can never be auto-assigned as their own officer.
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

fact F_OneInFlightPerApplicant {
  // FR-008: structurally enforced partial unique index.
  all u: User |
    (lone a: LoanApplication |
       a.applicant = u and (a.status = Pending or a.status = UnderReview))
}

fact F_ValidTransitionsInAudit {
  // FR-009: only the four allowed transitions appear as audit entries.
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Pending) or
    (ae.prevStatus = Pending      and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview  and ae.newStatus = Approved)    or
    (ae.prevStatus = UnderReview  and ae.newStatus = Rejected)
}

fact F_AuditAppendOnly { /* MUTATED — body cleared by validator */ }

fact F_AuditOperationLink {
  // FR-016: every audit entry was produced by exactly one Operation.
  all ae: AuditEntry | (one op: Operation | op.resultingAudit = ae)
}

fact F_AuditOnlyOnSuccessfulStateChange {
  // FR-017: audit entries exist only for successful state-changing operations.
  // (Atomic commit: either both state and audit happen, or neither.)
  all op: Operation |
    some op.resultingAudit implies
      (op.response = Ok and op.kind in (PostApplication + PatchStatus))
}

fact F_AuditAttribution {
  // FR-016: audit entry's actor / application / transition match the producing op.
  all op: Operation, ae: AuditEntry |
    op.resultingAudit = ae implies (
      ae.actor = op.caller and
      ae.application = op.target and
      (op.kind = PostApplication implies (no ae.prevStatus and ae.newStatus = Pending)) and
      (op.kind = PatchStatus implies some ae.prevStatus)
    )
}

fact F_AuthBeforeBusinessLogic {
  // FR-001: unauthenticated requests get 401 with no business logic and no audit.
  all op: Operation |
    op.authenticated = False implies
      (op.response = Unauthenticated and no op.resultingAudit and no op.target)
}

fact F_PostRequiresApplicantRoleAndCallerIsApplicant {
  // FR-003, FR-006: successful POST requires applicant role; applicant taken from token.
  all op: Operation |
    (op.response = Ok and op.kind = PostApplication) implies (
      some op.caller and
      ApplicantRole in op.caller.roles and
      some op.target and
      op.target.applicant = op.caller
    )
}

fact F_PatchRequiresAssignedOfficerNotApplicant {
  // FR-004, FR-012, FR-013: successful PATCH only by the assigned officer,
  // who must not be the application's applicant.
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies (
      some op.caller and
      some op.target and
      OfficerRole in op.caller.roles and
      op.caller = op.target.assignedOfficer and
      op.caller != op.target.applicant
    )
}

fact F_AuditEndpointAuditorOnly {
  // FR-023: only auditors can successfully read the audit endpoint.
  all op: Operation |
    (op.response = Ok and op.kind = GetAudit) implies
      (some op.caller and AuditorRole in op.caller.roles)
}

fact F_NotFoundForUnauthorizedReads {
  // FR-020, FR-021, FR-023: unauthorized authenticated reads return byte-equivalent NotFound.
  all op: Operation |
    (op.kind = GetApplication and op.authenticated = True and some op.target and
     not legitimateApplicationRead[op])
       implies op.response = NotFound
  all op: Operation |
    (op.kind = GetAudit and op.authenticated = True and some op.caller and
     AuditorRole not in op.caller.roles)
       implies op.response = NotFound
}

// ============================================================
// PATTERNS
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003..FR-005
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.response = Ok implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some PermMatrix.Allowed
  all k: OperationKind | (some r: Role | r -> k in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, SC-010
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.response = Ok implies (op.authenticated = True and some op.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: FR-016; data-model.md audit_entries
pred AuditCompleteness {
  some AuditEntry
  // Every audit entry has exactly one producing successful op.
  all ae: AuditEntry |
    (one op: Operation | op.resultingAudit = ae and op.response = Ok)
  // Every successful state-changing op has exactly one resulting audit entry.
  all op: Operation |
    (op.response = Ok and op.kind in (PostApplication + PatchStatus))
      implies (one op.resultingAudit)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: FR-016 audit-entry fields
pred AttributionCorrectness {
  some AuditEntry
  all op: Operation, ae: AuditEntry |
    op.resultingAudit = ae implies
      (ae.actor = op.caller and ae.application = op.target)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.applicant_id FK
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.applicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-004, FR-020
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = GetApplication and some op.target) implies
      legitimateApplicationRead[op]
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: FR-020, FR-021, FR-022, FR-023
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    (op.kind = GetApplication and op.authenticated = True and some op.target and
     not legitimateApplicationRead[op])
       implies op.response = NotFound
  all op: Operation |
    (op.kind = GetAudit and op.authenticated = True and some op.caller and
     AuditorRole not in op.caller.roles)
       implies op.response = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: FR-011, FR-013
pred NoSelfMutation {
  some LoanApplication
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies
      op.caller != op.target.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-007, FR-014, FR-017
pred ValidationBeforeMutation {
  some Operation
  all op: Operation |
    op.response != Ok implies no op.resultingAudit
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ============================================================
// FEATURE-SPECIFIC FR predicates
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    op.authenticated = False implies
      (op.response = Unauthenticated and no op.resultingAudit)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleExclusivity {
  some User
  all u: User | not (OfficerRole in u.roles and AuditorRole in u.roles)
}
assert FR_002_RoleExclusivity { FR_002_RoleExclusivity }
check FR_002_RoleExclusivity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantCannotPatch {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies
      OfficerRole in op.caller.roles
}
assert FR_003_ApplicantCannotPatch { FR_003_ApplicantCannotPatch }
check FR_003_ApplicantCannotPatch for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OnlyAssignedOfficerPatches {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies
      (some op.target and op.caller = op.target.assignedOfficer)
}
assert FR_004_OnlyAssignedOfficerPatches { FR_004_OnlyAssignedOfficerPatches }
check FR_004_OnlyAssignedOfficerPatches for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorCannotWrite {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies
      AuditorRole not in op.caller.roles
  all op: Operation |
    (op.response = Ok and op.kind = PostApplication) implies
      ApplicantRole in op.caller.roles
}
assert FR_005_AuditorCannotWrite { FR_005_AuditorCannotWrite }
check FR_005_AuditorCannotWrite for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_ApplicantIdentityFromCaller {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PostApplication) implies
      (some op.target and op.target.applicant = op.caller)
}
assert FR_006_ApplicantIdentityFromCaller { FR_006_ApplicantIdentityFromCaller }
check FR_006_ApplicantIdentityFromCaller for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (structural backstop; amount/purpose enums encoded)
pred FR_007_ValidationBackstop {
  some Operation
  all op: Operation |
    op.response = ValidationError implies no op.resultingAudit
}
assert FR_007_ValidationBackstop { FR_007_ValidationBackstop }
check FR_007_ValidationBackstop for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication
  all u: User |
    (lone a: LoanApplication |
       a.applicant = u and (a.status = Pending or a.status = UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ValidTransitions {
  some AuditEntry
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Pending) or
    (ae.prevStatus = Pending      and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview  and ae.newStatus = Approved)    or
    (ae.prevStatus = UnderReview  and ae.newStatus = Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AssignedOfficerHasOfficerRole {
  some LoanApplication
  all a: LoanApplication |
    some a.assignedOfficer implies OfficerRole in a.assignedOfficer.roles
}
assert FR_010_AssignedOfficerHasOfficerRole { FR_010_AssignedOfficerHasOfficerRole }
check FR_010_AssignedOfficerHasOfficerRole for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerCanPatch {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies
      (some op.target.assignedOfficer and op.caller = op.target.assignedOfficer)
}
assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check FR_012_OnlyAssignedOfficerCanPatch for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfDecision {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies
      op.caller != op.target.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ReasonOnTransitions {
  // Every successful PATCH must produce an audit entry (which carries the reason field).
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies (one op.resultingAudit)
}
assert FR_014_ReasonOnTransitions { FR_014_ReasonOnTransitions }
check FR_014_ReasonOnTransitions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoChangesAfterDecided {
  some AuditEntry
  // No audit entry records a transition FROM an already-decided state.
  all ae: AuditEntry |
    ae.prevStatus != Approved and ae.prevStatus != Rejected
}
assert FR_015_NoChangesAfterDecided { FR_015_NoChangesAfterDecided }
check FR_015_NoChangesAfterDecided for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditEntryPerTransition {
  some AuditEntry
  all ae: AuditEntry | (one op: Operation | op.resultingAudit = ae)
  all op: Operation |
    (op.response = Ok and op.kind in (PostApplication + PatchStatus))
      implies (one op.resultingAudit)
}
assert FR_016_AuditEntryPerTransition { FR_016_AuditEntryPerTransition }
check FR_016_AuditEntryPerTransition for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditAtomicWithTransition {
  some Operation
  all op: Operation |
    some op.resultingAudit implies op.response = Ok
  all op: Operation |
    op.response != Ok implies no op.resultingAudit
}
assert FR_017_AuditAtomicWithTransition { FR_017_AuditAtomicWithTransition }
check FR_017_AuditAtomicWithTransition for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditAppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry |
    ae1.application = ae2.application implies
      not (ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_RetentionStructural {
  // No public action deletes audit entries; every audit entry traces back to a successful op.
  some AuditEntry
  all ae: AuditEntry |
    (some op: Operation | op.resultingAudit = ae and op.response = Ok)
}
assert FR_019_RetentionStructural { FR_019_RetentionStructural }
check FR_019_RetentionStructural for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_NotFoundForUnauthorizedReads {
  some Operation
  all op: Operation |
    (op.kind = GetApplication and op.authenticated = True and some op.target and
     not legitimateApplicationRead[op])
       implies op.response = NotFound
}
assert FR_020_NotFoundForUnauthorizedReads { FR_020_NotFoundForUnauthorizedReads }
check FR_020_NotFoundForUnauthorizedReads for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_NoCrossApplicantLeak {
  some Operation
  // Same wire-level NotFound for "exists but not yours" as for "doesn't exist".
  all op: Operation |
    (op.kind = GetApplication and op.authenticated = True and some op.target and
     not legitimateApplicationRead[op])
       implies op.response = NotFound
}
assert FR_021_NoCrossApplicantLeak { FR_021_NoCrossApplicantLeak }
check FR_021_NoCrossApplicantLeak for 6

// FEATURE-SPECIFIC  ANCHOR: FR-022
pred FR_022_NoLeakViaPostResponse {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PostApplication and some op.target) implies
      op.target.applicant = op.caller
}
assert FR_022_NoLeakViaPostResponse { FR_022_NoLeakViaPostResponse }
check FR_022_NoLeakViaPostResponse for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditEndpointAuditorOnly {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = GetAudit) implies AuditorRole in op.caller.roles
  all op: Operation |
    (op.kind = GetAudit and op.authenticated = True and some op.caller and
     AuditorRole not in op.caller.roles)
       implies op.response = NotFound
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantCannotModify {
  some Operation
  all op: Operation |
    (op.response = Ok and op.kind = PatchStatus) implies (
      OfficerRole in op.caller.roles and
      op.caller != op.target.applicant
    )
}
assert FR_024_ApplicantCannotModify { FR_024_ApplicantCannotModify }
check FR_024_ApplicantCannotModify for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.application = ae2.application and ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus }
