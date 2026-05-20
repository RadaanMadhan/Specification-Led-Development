// === feature_model.als — Alloy model for FCA-Regulated Loan Application (005) ===
// Self-contained Alloy 6 encoding of the structural invariants over users, roles,
// loan applications, the status state machine, the audit log, the API permission
// matrix, and the byte-equivalent unauthorised-read property.

// ---------------- Static enumerations ----------------

abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

abstract sig OperationKind {}
one sig PostApplication, GetApplication, PatchStatus, GetAudit extends OperationKind {}

abstract sig Response {}
one sig OkResp, NotFoundResp, UnauthResp, ForbiddenResp extends Response {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// Permission matrix as a singleton-sig field (Role x OperationKind -> {in, out}).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------------- Dynamic sigs ----------------

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
  actor: lone User,             // 'none' encodes the system-actor case
  actorRole: one Role,
  prevStatus: lone Status,      // 'none' encodes the initial (none -> Pending) event
  newStatus: one Status
}

sig Operation {
  caller: lone User,            // 'none' encodes an unauthenticated request
  kind: one OperationKind,
  target: lone LoanApplication, // 'none' encodes a fabricated / nonexistent id
  requestedStatus: lone Status, // for PatchStatus, the target status
  hasReason: one Bool,
  succeeded: one Bool,
  response: one Response,
  produces: lone AuditEntry
}

// ---------------- Non-empty universe ----------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------------- Permission matrix (closed-world) ----------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RApplicant -> PostApplication) +
    (RApplicant -> GetApplication) +
    (ROfficer  -> GetApplication) +
    (ROfficer  -> PatchStatus) +
    (RAuditor  -> GetApplication) +
    (RAuditor  -> GetAudit)
}

// ---------------- Domain facts ----------------

fact F_RoleMultiplicity {
  // FR-002: forbid simultaneous officer + auditor; no real user holds the system pseudo-role.
  no u: User | ROfficer in u.roles and RAuditor in u.roles
  no u: User | RSystem in u.roles
}

fact F_ApplicantHasApplicantRole {
  // data-model.md: applicant_id references a user whose roles include applicant.
  all a: LoanApplication | RApplicant in a.applicant.roles
}

fact F_AssignedIsOfficer {
  // data-model.md: assigned_officer_id, when set, references a user with role officer.
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.roles
}

fact F_NoSelfAssignment {
  // FR-011: no application has its applicant as its assigned officer.
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

fact F_OneInFlightPerApplicant { /* MUTATED — body cleared by validator */ }

fact F_AuditAttribution {
  // FR-016: actor and actor_role consistent.
  all e: AuditEntry | (no e.actor) iff (e.actorRole = RSystem)
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
}

fact F_AuditTransitions {
  // FR-009 / FR-015 / FR-016: only the four allowed transitions are recordable.
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
}

fact F_AuthRequired {
  // FR-001: no operation succeeds without an authenticated caller; unauthenticated
  // requests must yield UnauthResp.
  all op: Operation | op.succeeded = BTrue implies some op.caller
  all op: Operation | no op.caller implies (op.succeeded = BFalse and op.response = UnauthResp)
}

fact F_LeastPrivilege {
  // contracts/http-api.md permission matrix: every successful operation matches an
  // (allowed role, kind) cell.
  all op: Operation |
    op.succeeded = BTrue implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}

fact F_OnlyAssignedOfficerPatch {
  // FR-012: only the assigned officer can PATCH.
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies (
      some op.target and op.target.assignedOfficer = op.caller
    )
}

fact F_NoSelfDecision {
  // FR-013: an officer cannot act as deciding officer on their own application.
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies
      op.target.applicant != op.caller
}

fact F_PatchReasonRequired {
  // FR-014: a successful PATCH must carry a non-empty reason.
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies op.hasReason = BTrue
}

fact F_AuditPairing {
  // FR-017 + FR-018: a successful state-changing op produces exactly one audit entry,
  // and every audit entry is produced by exactly one such operation.
  all op: Operation |
    (op.succeeded = BTrue and op.kind in (PostApplication + PatchStatus))
      iff some op.produces
  all e: AuditEntry | one op: Operation | op.produces = e
}

fact F_AuditMatchesOp {
  // FR-016: audit-entry contents match the producing operation.
  all op: Operation | some op.produces implies (
    op.produces.app = op.target and
    (op.kind = PostApplication implies (
       op.produces.newStatus = Pending and
       no op.produces.prevStatus and
       (
         (op.produces.actorRole = RApplicant and op.produces.actor = op.caller)
         or
         (op.produces.actorRole = RSystem and no op.produces.actor)
       )
    )) and
    (op.kind = PatchStatus implies (
       op.produces.newStatus = op.requestedStatus and
       op.produces.actorRole = ROfficer and
       op.produces.actor = op.caller
    ))
  )
}

fact F_OwnershipBasedAccess {
  // FR-003 / FR-004 / FR-005: successful reads only via owner / assigned officer / auditor.
  all op: Operation |
    (op.succeeded = BTrue and op.kind = GetApplication) implies (
      some op.target and (
        RAuditor in op.caller.roles or
        op.caller = op.target.applicant or
        op.caller = op.target.assignedOfficer
      )
    )
  all op: Operation |
    (op.succeeded = BTrue and op.kind = GetAudit) implies
      (some op.target and RAuditor in op.caller.roles)
}

fact F_NoInfoLeakage {
  // FR-020 / FR-021 / FR-022 / FR-023: unauthorised reads and nonexistent-id reads
  // return the same byte-equivalent NotFound response.
  all op: Operation |
    (some op.caller and op.kind in (GetApplication + GetAudit) and op.succeeded = BFalse)
      implies op.response = NotFoundResp
  all op: Operation |
    (some op.caller and op.kind = GetApplication and no op.target)
      implies (op.response = NotFoundResp and op.succeeded = BFalse)
}

// ---------------- Predicates & assertions ----------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  all op: Operation |
    op.succeeded = BTrue implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: Operation | op.succeeded = BTrue implies some op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017; data-model.md audit_entries
pred AuditCompleteness {
  all e: AuditEntry | one op: Operation | op.produces = e
  all op: Operation |
    (op.succeeded = BTrue and op.kind in (PostApplication + PatchStatus))
      implies some op.produces
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md no UPDATE/DELETE on audit_entries
pred AppendOnly {
  all disj op1, op2: Operation |
    (some op1.produces and some op2.produces) implies op1.produces != op2.produces
  all e: AuditEntry | some op: Operation | op.produces = e
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md AuditEntry fields
pred AttributionCorrectness {
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
  all e: AuditEntry | (no e.actor) iff (e.actorRole = RSystem)
  all op: Operation | (some op.produces and op.kind = PatchStatus) implies
    (op.produces.actor = op.caller and op.produces.actorRole = ROfficer)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id
pred OwnershipExclusivity {
  all a: LoanApplication | one a.applicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 / FR-004 / FR-005
pred OwnershipBasedAccess {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = GetApplication) implies (
      some op.target and (
        RAuditor in op.caller.roles or
        op.caller = op.target.applicant or
        op.caller = op.target.assignedOfficer
      )
    )
  all op: Operation |
    (op.succeeded = BTrue and op.kind = GetAudit) implies
      RAuditor in op.caller.roles
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020/021/022; contracts/http-api.md not-found shape
pred NoInformationLeakage {
  all op: Operation |
    (some op.caller and op.kind in (GetApplication + GetAudit) and op.succeeded = BFalse)
      implies op.response = NotFoundResp
  all op: Operation |
    (some op.caller and op.kind = GetApplication and no op.target)
      implies op.response = NotFoundResp
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013
pred NoSelfMutation {
  no a: LoanApplication | some a.assignedOfficer and a.assignedOfficer = a.applicant
  no op: Operation |
    op.succeeded = BTrue and op.kind = PatchStatus and op.caller = op.target.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007, FR-014, FR-017
pred ValidationBeforeMutation {
  all op: Operation | op.succeeded = BFalse implies no op.produces
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies op.succeeded = BFalse
  all op: Operation | no op.caller implies op.response = UnauthResp
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMultiplicity {
  no u: User | ROfficer in u.roles and RAuditor in u.roles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantScope {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = GetApplication and op.caller.roles = RApplicant)
      implies op.caller = op.target.applicant
  no op: Operation |
    op.succeeded = BTrue and op.kind in (PatchStatus + GetAudit) and
    op.caller.roles = RApplicant
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerScope {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies
      (op.target.assignedOfficer = op.caller and op.target.applicant != op.caller)
}
assert FR_004_OfficerScope { FR_004_OfficerScope }
check FR_004_OfficerScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  no op: Operation |
    op.succeeded = BTrue and op.kind in (PostApplication + PatchStatus) and
    op.caller.roles = RAuditor
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlight {
  all u: User |
    lone a: LoanApplication | a.applicant = u and a.status in (Pending + UnderReview)
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ValidTransitions {
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AutoAssignment {
  all a: LoanApplication | lone a.assignedOfficer
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.roles
}
assert FR_010_AutoAssignment { FR_010_AutoAssignment }
check FR_010_AutoAssignment for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerPatches {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies
      op.caller = op.target.assignedOfficer
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfDecision {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies
      op.caller != op.target.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ReasonRequired {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = PatchStatus) implies op.hasReason = BTrue
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoPostDecisionTransition {
  no e: AuditEntry | e.prevStatus in (Approved + Rejected)
}
assert FR_015_NoPostDecisionTransition { FR_015_NoPostDecisionTransition }
check FR_015_NoPostDecisionTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditFields {
  all e: AuditEntry | (no e.prevStatus) iff (e.newStatus = Pending)
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
  all e: AuditEntry | (no e.actor) iff (e.actorRole = RSystem)
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditPairedWithTransition {
  all op: Operation |
    (op.succeeded = BTrue and op.kind in (PostApplication + PatchStatus))
      implies some op.produces
  all op: Operation | op.succeeded = BFalse implies no op.produces
}
assert FR_017_AuditPairedWithTransition { FR_017_AuditPairedWithTransition }
check FR_017_AuditPairedWithTransition for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditAppendOnly {
  all disj op1, op2: Operation |
    (some op1.produces and some op2.produces) implies op1.produces != op2.produces
  all e: AuditEntry | some op: Operation | op.produces = e
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (no public delete path on audit log)
pred FR_019_NoAuditDeletion {
  // Static analogue: no orphan audit entry; every entry traces back to a producing op,
  // so a deletion would manifest as a missing producer and be detectable.
  all e: AuditEntry | some op: Operation | op.produces = e
}
assert FR_019_NoAuditDeletion { FR_019_NoAuditDeletion }
check FR_019_NoAuditDeletion for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 / FR-021 / FR-022
pred FR_020_ByteEquivalentUnauthorisedRead {
  all op: Operation |
    (some op.caller and op.kind = GetApplication and op.succeeded = BFalse)
      implies op.response = NotFoundResp
  all op: Operation |
    (some op.caller and op.kind = GetApplication and no op.target)
      implies op.response = NotFoundResp
}
assert FR_020_ByteEquivalentUnauthorisedRead { FR_020_ByteEquivalentUnauthorisedRead }
check FR_020_ByteEquivalentUnauthorisedRead for 8

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditEndpointAuditorOnly {
  all op: Operation |
    (op.succeeded = BTrue and op.kind = GetAudit) implies RAuditor in op.caller.roles
  all op: Operation |
    (some op.caller and op.kind = GetAudit and not RAuditor in op.caller.roles)
      implies (op.succeeded = BFalse and op.response = NotFoundResp)
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantCannotModify {
  no op: Operation |
    op.succeeded = BTrue and op.kind = PatchStatus and op.caller.roles = RApplicant
}
assert FR_024_ApplicantCannotModify { FR_024_ApplicantCannotModify }
check FR_024_ApplicantCannotModify for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_TwoInFlight { some disj a1, a2: LoanApplication | a1.applicant = a2.applicant and a1.status = Pending and a2.status = Pending }
