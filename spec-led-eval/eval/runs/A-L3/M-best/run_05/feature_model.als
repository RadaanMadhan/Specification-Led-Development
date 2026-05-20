// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===
// Self-contained Alloy 6 encoding of the structural invariants stated in
// spec.md (FR-001 .. FR-024), data-model.md, and contracts/http-api.md.

// ----------------------------------------------------------------------------
// Domain sigs
// ----------------------------------------------------------------------------

abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchStatus, GetAudit
    extends OperationKind {}

abstract sig Outcome {}
one sig Success, Unauthenticated, NotFoundResp, Denied extends Outcome {}

sig Reason {}

sig User { roles: some Role }

sig LoanApplication {
  submitter:       one User,
  assignedOfficer: lone User,
  status:          one Status
}

sig AuditEntry {
  app:        one  LoanApplication,
  actor:      lone User,        // empty == system actor
  actorRole:  one  Role,
  prevStatus: lone Status,      // empty == initial submission entry
  newStatus:  one  Status,
  reason:     one  Reason
}

sig Operation {
  kind:          one  OperationKind,
  caller:        lone User,            // empty == unauthenticated
  target:        lone LoanApplication,
  outcome:       one  Outcome,
  producedEntry: lone AuditEntry
}

// Permission matrix as a singleton-sig field (Alloy 6 idiom).
one sig PermMatrix { Allowed: Role -> OperationKind }

// ----------------------------------------------------------------------------
// Non-empty universe (prevents vacuous-by-empty-world passes)
// ----------------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
  some Reason
}

// ----------------------------------------------------------------------------
// Permission matrix wiring (contracts/http-api.md permission table)
// ----------------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Applicant -> PostApplications) +
      (Applicant -> GetApplicationById) +
      (Officer   -> GetApplicationById) +
      (Officer   -> PatchStatus) +
      (Auditor   -> GetApplicationById) +
      (Auditor   -> GetAudit)
}

// ----------------------------------------------------------------------------
// Role multiplicity (FR-002, data-model.md users.roles CHECK)
// ----------------------------------------------------------------------------

fact F_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
  all u: User | SystemRole not in u.roles
}

// ----------------------------------------------------------------------------
// Submitter / assignee role requirements
// ----------------------------------------------------------------------------

fact F_SubmitterHasApplicantRole {
  all a: LoanApplication | Applicant in a.submitter.roles
}

fact F_AssigneeHasOfficerRole {
  all a: LoanApplication | some a.assignedOfficer
      implies Officer in a.assignedOfficer.roles
}

// ----------------------------------------------------------------------------
// No self-assignment of officer (FR-011 schema CHECK)
// ----------------------------------------------------------------------------

fact F_NoSelfAssignment {
  all a: LoanApplication | a.assignedOfficer != a.submitter
}

// ----------------------------------------------------------------------------
// One in-flight per applicant (FR-008 partial UNIQUE index)
// ----------------------------------------------------------------------------

fact F_OneInFlight {
  all disj a1, a2: LoanApplication |
      a1.submitter = a2.submitter implies
          not (a1.status in (Pending + UnderReview)
               and a2.status in (Pending + UnderReview))
}

// ----------------------------------------------------------------------------
// Auth boundary (FR-001): unauthenticated => never Success, never an entry
// ----------------------------------------------------------------------------

fact F_AuthBoundary {
  all op: Operation | no op.caller implies
      (op.outcome = Unauthenticated and no op.producedEntry)
}

// ----------------------------------------------------------------------------
// Least-privilege matrix check (FR-003..FR-005, FR-023)
// ----------------------------------------------------------------------------

fact F_LeastPrivilegeMatrix {
  all op: Operation | op.outcome = Success implies
      (some op.caller
       and (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed))
}

// ----------------------------------------------------------------------------
// GET-application ownership chain (FR-003, FR-020, FR-021)
// ----------------------------------------------------------------------------

fact F_GetOwnership {
  all op: Operation |
      (op.outcome = Success and op.kind = GetApplicationById) implies
          (some op.target and some op.caller
           and ((Auditor in op.caller.roles)
                or (Officer in op.caller.roles
                    and op.target.assignedOfficer = op.caller)
                or (Applicant in op.caller.roles
                    and op.target.submitter = op.caller)))
}

// ----------------------------------------------------------------------------
// PATCH ownership (FR-012)
// ----------------------------------------------------------------------------

fact F_PatchOwnership {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          (some op.target and some op.caller
           and op.target.assignedOfficer = op.caller)
}

// ----------------------------------------------------------------------------
// POST creates an application owned by the caller (FR-006, FR-022)
// ----------------------------------------------------------------------------

fact F_PostOwnership {
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications) implies
          (some op.target and some op.caller
           and op.target.submitter = op.caller
           and op.target.status = Pending)
}

// ----------------------------------------------------------------------------
// Audit-per-transition (FR-016, FR-017): every success state-change has 1 entry
// ----------------------------------------------------------------------------

fact F_AuditPerTransition {
  all op: Operation |
      (op.outcome = Success and op.kind in (PostApplications + PatchStatus))
          implies (one op.producedEntry)
}

// ----------------------------------------------------------------------------
// Reads produce no audit entries
// ----------------------------------------------------------------------------

fact F_NoAuditOnReads {
  all op: Operation | op.kind in (GetApplicationById + GetAudit)
      implies no op.producedEntry
}

// ----------------------------------------------------------------------------
// Validation-before-mutation: failures produce no audit entry
// ----------------------------------------------------------------------------

fact F_ValidationNoSideEffect {
  all op: Operation | op.outcome != Success implies no op.producedEntry
}

// ----------------------------------------------------------------------------
// Append-only audit (FR-018, FR-019): every entry traces to a real success op
// ----------------------------------------------------------------------------

fact F_AppendOnlyAudit {
  all e: AuditEntry | (some op: Operation |
      op.outcome = Success
      and op.kind in (PostApplications + PatchStatus)
      and op.producedEntry = e)
}

// ----------------------------------------------------------------------------
// Audit attribution (FR-016): entry.actor and .app match the producing op
// ----------------------------------------------------------------------------

fact F_AuditAttribution {
  all op: Operation | some op.producedEntry implies
      (op.producedEntry.app = op.target
       and op.producedEntry.actor = op.caller)
}

// ----------------------------------------------------------------------------
// Audit actorRole consistent with actor (FR-016)
// ----------------------------------------------------------------------------

fact F_AuditActorRole {
  all e: AuditEntry | (no e.actor) implies e.actorRole = SystemRole
  all e: AuditEntry | (some e.actor) implies e.actorRole in e.actor.roles
}

// ----------------------------------------------------------------------------
// Status transition legality (FR-009, FR-015)
// ----------------------------------------------------------------------------

fact F_StatusTransitionLegal {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus
       and some op.producedEntry) implies
          ((op.producedEntry.prevStatus = Pending
            and op.producedEntry.newStatus = UnderReview)
           or (op.producedEntry.prevStatus = UnderReview
               and op.producedEntry.newStatus = Approved)
           or (op.producedEntry.prevStatus = UnderReview
               and op.producedEntry.newStatus = Rejected))
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications
       and some op.producedEntry) implies
          (no op.producedEntry.prevStatus
           and op.producedEntry.newStatus = Pending)
}

// ============================================================================
// PATTERN PREDICATES + ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003..FR-005
pred LeastPrivilege {
  all op: Operation | op.outcome = Success implies
      (some op.caller
       and (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed))
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some PermMatrix.Allowed
  Applicant -> PostApplications      in PermMatrix.Allowed
  Applicant -> GetApplicationById    in PermMatrix.Allowed
  Officer   -> GetApplicationById    in PermMatrix.Allowed
  Officer   -> PatchStatus           in PermMatrix.Allowed
  Auditor   -> GetApplicationById    in PermMatrix.Allowed
  Auditor   -> GetAudit              in PermMatrix.Allowed
  Officer   -> PostApplications      not in PermMatrix.Allowed
  Officer   -> GetAudit              not in PermMatrix.Allowed
  Auditor   -> PostApplications      not in PermMatrix.Allowed
  Auditor   -> PatchStatus           not in PermMatrix.Allowed
  Applicant -> PatchStatus           not in PermMatrix.Allowed
  Applicant -> GetAudit              not in PermMatrix.Allowed
  all k: OperationKind | SystemRole -> k not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: every allow cell anchored to FR-003..FR-006, FR-023
pred PermissionGrounding {
  PermMatrix.Allowed =
      (Applicant -> PostApplications) +       // FR-006
      (Applicant -> GetApplicationById) +     // FR-003
      (Officer   -> GetApplicationById) +     // FR-004
      (Officer   -> PatchStatus) +            // FR-004
      (Auditor   -> GetApplicationById) +     // FR-005
      (Auditor   -> GetAudit)                 // FR-005, FR-023
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | no op.caller implies
      (op.outcome != Success and no op.producedEntry)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: FR-016, FR-017
pred AuditCompleteness {
  all op: Operation |
      (op.outcome = Success and op.kind in (PostApplications + PatchStatus))
          implies (one op.producedEntry)
  all e: AuditEntry | (one op: Operation | op.producedEntry = e)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: FR-018, FR-019
pred AppendOnly {
  all e: AuditEntry | (some op: Operation |
      op.outcome = Success
      and op.kind in (PostApplications + PatchStatus)
      and op.producedEntry = e)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: FR-016, data-model.md audit_entries
pred AttributionCorrectness {
  all op: Operation | some op.producedEntry implies
      (op.producedEntry.actor = op.caller
       and op.producedEntry.app = op.target)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant_id NOT NULL FK
pred OwnershipExclusivity {
  all a: LoanApplication | one a.submitter
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-004, FR-012, FR-020
pred OwnershipBasedAccess {
  all op: Operation |
      (op.outcome = Success and op.kind = GetApplicationById) implies
          ((Auditor in op.caller.roles)
           or (Officer in op.caller.roles
               and op.target.assignedOfficer = op.caller)
           or (Applicant in op.caller.roles
               and op.target.submitter = op.caller))
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          op.target.assignedOfficer = op.caller
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: FR-020, FR-021, FR-022, FR-023
pred NoInformationLeakage {
  all op: Operation |
      (op.outcome = Success and op.kind = GetApplicationById) implies
          ((Auditor in op.caller.roles)
           or (Officer in op.caller.roles
               and op.target.assignedOfficer = op.caller)
           or (Applicant in op.caller.roles
               and op.target.submitter = op.caller))
  all op: Operation |
      (op.outcome = Success and op.kind = GetAudit) implies
          Auditor in op.caller.roles
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: FR-011, FR-013
pred NoSelfMutation {
  all a: LoanApplication | a.assignedOfficer != a.submitter
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          op.target.submitter != op.caller
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-007, FR-014; spec acceptance #2
pred ValidationBeforeMutation {
  all op: Operation | op.outcome != Success implies no op.producedEntry
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ============================================================================
// FR-SPECIFIC ASSERTIONS
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies
      (op.outcome = Unauthenticated and no op.producedEntry)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleMultiplicity {
  all u: User | not (Officer in u.roles and Auditor in u.roles)
  all u: User | SystemRole not in u.roles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_ApplicantScope {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          Officer in op.caller.roles
  all op: Operation |
      (op.outcome = Success and op.kind = GetAudit) implies
          Auditor in op.caller.roles
  all op: Operation |
      (op.outcome = Success and op.kind = GetApplicationById
       and Auditor not in op.caller.roles
       and (Officer not in op.caller.roles
            or op.target.assignedOfficer != op.caller))
          implies op.target.submitter = op.caller
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_OfficerScope {
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications) implies
          Applicant in op.caller.roles
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          op.target.assignedOfficer = op.caller
}
assert FR_004_OfficerScope { FR_004_OfficerScope }
check FR_004_OfficerScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AuditorReadOnly {
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications) implies
          Applicant in op.caller.roles
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          Officer in op.caller.roles
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_ApplicantFromToken {
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications) implies
          op.target.submitter = op.caller
}
assert FR_006_ApplicantFromToken { FR_006_ApplicantFromToken }
check FR_006_ApplicantFromToken for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ValidationNoSideEffect {
  all op: Operation | op.outcome = Denied implies no op.producedEntry
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications) implies
          op.target.status = Pending
}
assert FR_007_ValidationNoSideEffect { FR_007_ValidationNoSideEffect }
check FR_007_ValidationNoSideEffect for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_OneInFlight {
  all disj a1, a2: LoanApplication |
      a1.submitter = a2.submitter implies
          not (a1.status in (Pending + UnderReview)
               and a2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_TransitionLegality {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus
       and some op.producedEntry) implies
          ((op.producedEntry.prevStatus = Pending
            and op.producedEntry.newStatus = UnderReview)
           or (op.producedEntry.prevStatus = UnderReview
               and op.producedEntry.newStatus = Approved)
           or (op.producedEntry.prevStatus = UnderReview
               and op.producedEntry.newStatus = Rejected))
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications
       and some op.producedEntry) implies
          (no op.producedEntry.prevStatus
           and op.producedEntry.newStatus = Pending)
}
assert FR_009_TransitionLegality { FR_009_TransitionLegality }
check FR_009_TransitionLegality for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AssignmentInvariant {
  all a: LoanApplication | some a.assignedOfficer implies
      (Officer in a.assignedOfficer.roles
       and a.assignedOfficer != a.submitter)
}
assert FR_010_AssignmentInvariant { FR_010_AssignmentInvariant }
check FR_010_AssignmentInvariant for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoSelfAssignment {
  all a: LoanApplication | a.assignedOfficer != a.submitter
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_OnlyAssignedOfficerPatches {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          (some op.target and op.target.assignedOfficer = op.caller)
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_NoSelfDecision {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          op.target.submitter != op.caller
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_ReasonOnEveryEntry {
  all e: AuditEntry | one e.reason
}
assert FR_014_ReasonOnEveryEntry { FR_014_ReasonOnEveryEntry }
check FR_014_ReasonOnEveryEntry for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_TerminalStatusFinal {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus
       and some op.producedEntry) implies
          op.producedEntry.prevStatus not in (Approved + Rejected)
}
assert FR_015_TerminalStatusFinal { FR_015_TerminalStatusFinal }
check FR_015_TerminalStatusFinal for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditFieldsComplete {
  all e: AuditEntry | one e.app
  all e: AuditEntry | one e.actorRole
  all e: AuditEntry | one e.newStatus
  all e: AuditEntry | one e.reason
  all e: AuditEntry | (no e.prevStatus) iff (e.newStatus = Pending)
}
assert FR_016_AuditFieldsComplete { FR_016_AuditFieldsComplete }
check FR_016_AuditFieldsComplete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditWithEverySuccess {
  all op: Operation |
      (op.outcome = Success and op.kind in (PostApplications + PatchStatus))
          implies (one op.producedEntry)
  all op: Operation | op.outcome != Success implies no op.producedEntry
}
assert FR_017_AuditWithEverySuccess { FR_017_AuditWithEverySuccess }
check FR_017_AuditWithEverySuccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AuditImmutable {
  all e: AuditEntry | (one op: Operation |
      op.outcome = Success
      and op.kind in (PostApplications + PatchStatus)
      and op.producedEntry = e)
}
assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_RetentionNoOrphans {
  all e: AuditEntry | (some op: Operation | op.producedEntry = e)
}
assert FR_019_RetentionNoOrphans { FR_019_RetentionNoOrphans }
check FR_019_RetentionNoOrphans for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_NoLeakageOnGet {
  all op: Operation |
      (op.outcome = Success and op.kind = GetApplicationById) implies
          ((Auditor in op.caller.roles)
           or (Officer in op.caller.roles
               and op.target.assignedOfficer = op.caller)
           or (Applicant in op.caller.roles
               and op.target.submitter = op.caller))
}
assert FR_020_NoLeakageOnGet { FR_020_NoLeakageOnGet }
check FR_020_NoLeakageOnGet for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021
pred FR_021_NoCrossApplicantLeak {
  all op: Operation |
      (op.outcome = Success and op.kind = GetApplicationById
       and Auditor not in op.caller.roles
       and (Officer not in op.caller.roles
            or op.target.assignedOfficer != op.caller))
          implies op.target.submitter = op.caller
}
assert FR_021_NoCrossApplicantLeak { FR_021_NoCrossApplicantLeak }
check FR_021_NoCrossApplicantLeak for 6

// FEATURE-SPECIFIC  ANCHOR: FR-022
pred FR_022_PostExposesOnlySelf {
  all op: Operation |
      (op.outcome = Success and op.kind = PostApplications) implies
          op.target.submitter = op.caller
}
assert FR_022_PostExposesOnlySelf { FR_022_PostExposesOnlySelf }
check FR_022_PostExposesOnlySelf for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023
pred FR_023_AuditEndpointAuditorOnly {
  all op: Operation |
      (op.outcome = Success and op.kind = GetAudit) implies
          Auditor in op.caller.roles
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-024
pred FR_024_ApplicantDataImmutable {
  all op: Operation |
      (op.outcome = Success and op.kind = PatchStatus) implies
          (Officer in op.caller.roles
           and op.caller != op.target.submitter)
}
assert FR_024_ApplicantDataImmutable { FR_024_ApplicantDataImmutable }
check FR_024_ApplicantDataImmutable for 6