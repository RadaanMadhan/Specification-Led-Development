// === feature_model.als — Alloy model for 005-fca-loan-applications (FCA Loan Application) ===
// Encodes the structural invariants from spec.md, data-model.md, and contracts/http-api.md.

// ---------------------------------------------------------------
// Non-empty universe (one named fact at top — rule 9).
// ---------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------------------------------------------------------------
// Static enumerations
// ---------------------------------------------------------------
abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchStatus, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig OK, Unauthenticated, PermDenied, NotFoundOut, ValidationErr, ConflictOut, AuditFail extends Outcome {}

abstract sig ResponseShape {}
one sig OkBody, NotFoundBody, OtherErrorBody extends ResponseShape {}

// ---------------------------------------------------------------
// Domain entities (dynamic)
// ---------------------------------------------------------------
sig User {
  roles: some Role
}

sig LoanApplication {
  applicant: one User,
  assignedOfficer: lone User,
  status: one Status
}

sig AuditEntry {
  app: one LoanApplication,
  actor: one User,
  actorRole: one Role,
  prevStatus: lone Status,
  newStatus: one Status
}

sig Operation {
  caller: lone User,
  kind: one OperationKind,
  target: lone LoanApplication,
  outcome: one Outcome,
  audit: lone AuditEntry,
  response: one ResponseShape
}

// ---------------------------------------------------------------
// Permission matrix (singleton-sig field — rule 7)
// ---------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Applicant -> PostApplications) +
    (Applicant -> GetApplicationById) +
    (Officer  -> GetApplicationById) +
    (Officer  -> PatchStatus) +
    (Auditor  -> GetApplicationById) +
    (Auditor  -> GetAudit)
}

// ---------------------------------------------------------------
// Named, mutation-testable facts
// ---------------------------------------------------------------

fact F_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
  all u: User | SystemRole not in u.roles
}

fact F_ApplicantHasApplicantRole {
  all a: LoanApplication | Applicant in a.applicant.roles
}

fact F_AssignedOfficerHasOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}

fact F_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview)
           and a2.status in (Pending + UnderReview))
}

fact F_ValidTransitionsInAudit {
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Pending) or
    (ae.prevStatus = Pending      and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview  and ae.newStatus = Approved) or
    (ae.prevStatus = UnderReview  and ae.newStatus = Rejected)
}

fact F_AuditAttributionCorrect {
  all ae: AuditEntry |
    ae.actorRole = SystemRole or ae.actorRole in ae.actor.roles
}

fact F_AuthRequired {
  all o: Operation | (no o.caller) iff (o.outcome = Unauthenticated)
}

fact F_LeastPrivilege {
  all o: Operation |
    o.outcome = OK implies
      (some r: o.caller.roles | r -> o.kind in PermMatrix.Allowed)
}

fact F_PatchOnlyAssignedOfficer {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.target and o.caller = o.target.assignedOfficer)
}

fact F_NoSelfDecision {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.target and o.caller != o.target.applicant)
}

fact F_AuditCompletenessOnSuccess {
  all o: Operation |
    (o.outcome = OK and o.kind in (PostApplications + PatchStatus))
      implies (some o.audit)
  all o: Operation | o.outcome != OK implies no o.audit
  all o: Operation | o.kind in (GetApplicationById + GetAudit) implies no o.audit
}

fact F_AuditBindsToOperation {
  all o: Operation |
    some o.audit implies
      (o.audit.app = o.target and o.audit.actor = o.caller)
}

fact F_PostProducesInitialAudit {
  all o: Operation |
    (o.outcome = OK and o.kind = PostApplications) implies
      (no o.audit.prevStatus and o.audit.newStatus = Pending)
}

fact F_PatchProducesTransitionAudit {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.audit.prevStatus and o.audit.prevStatus != o.audit.newStatus)
}

fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

fact F_ByteEquivalentNotFound {
  all o: Operation |
    (o.kind = GetApplicationById and o.outcome = OK)
      implies o.response = OkBody
  all o: Operation |
    (o.kind = GetApplicationById
     and o.outcome != OK
     and o.outcome != Unauthenticated)
      implies o.response = NotFoundBody
}

fact F_AuditEndpointResponseShape {
  all o: Operation |
    (o.kind = GetAudit and o.outcome = OK) implies o.response = OkBody
  all o: Operation |
    (o.kind = GetAudit
     and o.outcome != OK
     and o.outcome != Unauthenticated)
      implies o.response = NotFoundBody
}

fact F_ApplicantCannotPatch {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies Officer in o.caller.roles
}

fact F_PostConflictReferencesCallerOwn {
  all o: Operation |
    (o.kind = PostApplications and o.outcome = ConflictOut and some o.target)
      implies o.target.applicant = o.caller
}

// ===============================================================
// PATTERN PREDICATES + ASSERTIONS
// ===============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003/FR-004/FR-005
pred LeastPrivilege {
  all o: Operation |
    o.outcome = OK implies
      (some r: o.caller.roles | r -> o.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // SystemRole is never an authorising role at the API surface.
  no ((SystemRole -> OperationKind) & PermMatrix.Allowed)
  // Every concrete user-role authorises at least one endpoint.
  some ((Applicant -> OperationKind) & PermMatrix.Allowed)
  some ((Officer  -> OperationKind) & PermMatrix.Allowed)
  some ((Auditor  -> OperationKind) & PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003/004/005/012/023
pred PermissionGrounding {
  Applicant -> PostApplications    in PermMatrix.Allowed
  Officer   -> PatchStatus         in PermMatrix.Allowed
  Auditor   -> GetAudit            in PermMatrix.Allowed
  Auditor   -> GetApplicationById  in PermMatrix.Allowed
  Applicant -> GetApplicationById  in PermMatrix.Allowed
  Officer   -> GetApplicationById  in PermMatrix.Allowed
  // Forbidden cells must remain forbidden.
  Applicant -> PatchStatus      not in PermMatrix.Allowed
  Applicant -> GetAudit         not in PermMatrix.Allowed
  Officer   -> PostApplications not in PermMatrix.Allowed
  Officer   -> GetAudit         not in PermMatrix.Allowed
  Auditor   -> PostApplications not in PermMatrix.Allowed
  Auditor   -> PatchStatus      not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-010
pred AuthRequiredEverywhere {
  all o: Operation | o.outcome = OK implies (some o.caller)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017
pred AuditCompleteness {
  all o: Operation |
    (o.outcome = OK and o.kind in (PostApplications + PatchStatus))
      implies (some o.audit)
  all o: Operation |
    (o.kind in (GetApplicationById + GetAudit)) implies (no o.audit)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018, FR-019; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.app = ae2.app
         and ae1.prevStatus = ae2.prevStatus
         and ae1.newStatus  = ae2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit-entry fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.actorRole = SystemRole or ae.actorRole in ae.actor.roles
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant_id NOT NULL; spec.md FR-006
pred OwnershipExclusivity {
  all a: LoanApplication |
    one a.applicant and Applicant in a.applicant.roles
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012/FR-013
pred OwnershipBasedAccess {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.target
       and o.caller = o.target.assignedOfficer
       and o.caller != o.target.applicant)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020/FR-021/FR-022/FR-023
pred NoInformationLeakage {
  all o: Operation |
    (o.kind = GetApplicationById
     and o.outcome != OK
     and o.outcome != Unauthenticated)
      implies o.response = NotFoundBody
  all o: Operation |
    (o.kind = GetAudit
     and o.outcome != OK
     and o.outcome != Unauthenticated)
      implies o.response = NotFoundBody
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013
pred NoSelfMutation {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.target and o.caller != o.target.applicant)
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007/008/014/017
pred ValidationBeforeMutation {
  all o: Operation |
    o.outcome in (ValidationErr + ConflictOut + Unauthenticated
                  + PermDenied + NotFoundOut + AuditFail)
      implies no o.audit
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ===============================================================
// FEATURE-SPECIFIC PREDICATES (one per FR)
// ===============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all o: Operation | o.outcome = OK implies (some o.caller)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
  all u: User | SystemRole not in u.roles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantScope {
  Applicant -> PostApplications in PermMatrix.Allowed
  Applicant -> PatchStatus      not in PermMatrix.Allowed
  Applicant -> GetAudit         not in PermMatrix.Allowed
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerScope {
  Officer -> PatchStatus      in PermMatrix.Allowed
  Officer -> PostApplications not in PermMatrix.Allowed
  Officer -> GetAudit         not in PermMatrix.Allowed
}
assert FR_004_OfficerScope { FR_004_OfficerScope }
check FR_004_OfficerScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorScope {
  Auditor -> GetAudit           in PermMatrix.Allowed
  Auditor -> GetApplicationById in PermMatrix.Allowed
  Auditor -> PostApplications   not in PermMatrix.Allowed
  Auditor -> PatchStatus        not in PermMatrix.Allowed
}
assert FR_005_AuditorScope { FR_005_AuditorScope }
check FR_005_AuditorScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_IdentityFromCaller {
  all o: Operation | some o.audit implies o.audit.actor = o.caller
}
assert FR_006_IdentityFromCaller { FR_006_IdentityFromCaller }
check FR_006_IdentityFromCaller for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (status set; amount/purpose ranges abstracted as the legal status enumeration)
pred FR_007_ValidStatusSet {
  all ae: AuditEntry | ae.newStatus in (Pending + UnderReview + Approved + Rejected)
  all a: LoanApplication | a.status in (Pending + UnderReview + Approved + Rejected)
}
assert FR_007_ValidStatusSet { FR_007_ValidStatusSet }
check FR_007_ValidStatusSet for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant implies
      not (a1.status in (Pending + UnderReview)
           and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AllowedTransitions {
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Pending) or
    (ae.prevStatus = Pending      and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview  and ae.newStatus = Approved) or
    (ae.prevStatus = UnderReview  and ae.newStatus = Rejected)
}
assert FR_009_AllowedTransitions { FR_009_AllowedTransitions }
check FR_009_AllowedTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AssignedIsOfficer {
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}
assert FR_010_AssignedIsOfficer { FR_010_AssignedIsOfficer }
check FR_010_AssignedIsOfficer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_AssignedOfficerOnly {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.target and o.caller = o.target.assignedOfficer)
}
assert FR_012_AssignedOfficerOnly { FR_012_AssignedOfficerOnly }
check FR_012_AssignedOfficerOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfDecision {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies
      (some o.target and o.caller != o.target.applicant)
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (transition audit has non-trivial prev->new pair)
pred FR_014_TransitionIsRealChange {
  all ae: AuditEntry |
    some ae.prevStatus implies ae.prevStatus != ae.newStatus
}
assert FR_014_TransitionIsRealChange { FR_014_TransitionIsRealChange }
check FR_014_TransitionIsRealChange for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoChangeAfterTerminal {
  all ae: AuditEntry | ae.prevStatus not in (Approved + Rejected)
}
assert FR_015_NoChangeAfterTerminal { FR_015_NoChangeAfterTerminal }
check FR_015_NoChangeAfterTerminal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditFields {
  all ae: AuditEntry |
    (no ae.prevStatus implies ae.newStatus = Pending) and
    (some ae.prevStatus implies ae.prevStatus != ae.newStatus) and
    (ae.actorRole = SystemRole or ae.actorRole in ae.actor.roles)
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditAtomic {
  all o: Operation |
    (o.outcome = OK and o.kind in (PostApplications + PatchStatus))
      implies (some o.audit)
  all o: Operation | o.outcome = AuditFail implies (no o.audit)
}
assert FR_017_AuditAtomic { FR_017_AuditAtomic }
check FR_017_AuditAtomic for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.app = ae2.app
         and ae1.prevStatus = ae2.prevStatus
         and ae1.newStatus  = ae2.newStatus)
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 (retention: every successful state change retains an audit entry)
pred FR_019_AuditRetained {
  all o: Operation |
    (o.outcome = OK and o.kind in (PostApplications + PatchStatus))
      implies (some o.audit)
}
assert FR_019_AuditRetained { FR_019_AuditRetained }
check FR_019_AuditRetained for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_ByteEquivalentNotFound {
  all o: Operation |
    (o.kind = GetApplicationById
     and o.outcome != OK
     and o.outcome != Unauthenticated)
      implies o.response = NotFoundBody
}
assert FR_020_ByteEquivalentNotFound { FR_020_ByteEquivalentNotFound }
check FR_020_ByteEquivalentNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_OwnerVsNonexistent {
  all o: Operation |
    (o.kind = GetApplicationById and o.outcome = NotFoundOut)
      implies o.response = NotFoundBody
  all o: Operation |
    (o.kind = GetApplicationById and o.outcome = PermDenied)
      implies o.response = NotFoundBody
}
assert FR_021_OwnerVsNonexistent { FR_021_OwnerVsNonexistent }
check FR_021_OwnerVsNonexistent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-022
pred FR_022_NoLeakInPost {
  all o: Operation |
    (o.kind = PostApplications and o.outcome = ConflictOut and some o.target)
      implies o.target.applicant = o.caller
}
assert FR_022_NoLeakInPost { FR_022_NoLeakInPost }
check FR_022_NoLeakInPost for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditAuditorOnly {
  all o: Operation |
    (o.kind = GetAudit and o.outcome = OK) implies Auditor in o.caller.roles
  all o: Operation |
    (o.kind = GetAudit
     and o.outcome != OK
     and o.outcome != Unauthenticated)
      implies o.response = NotFoundBody
}
assert FR_023_AuditAuditorOnly { FR_023_AuditAuditorOnly }
check FR_023_AuditAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantCannotPatch {
  all o: Operation |
    (o.outcome = OK and o.kind = PatchStatus) implies Officer in o.caller.roles
}
assert FR_024_ApplicantCannotPatch { FR_024_ApplicantCannotPatch }
check FR_024_ApplicantCannotPatch for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.app = ae2.app and ae1.prevStatus = ae2.prevStatus and ae1.newStatus = ae2.newStatus }
