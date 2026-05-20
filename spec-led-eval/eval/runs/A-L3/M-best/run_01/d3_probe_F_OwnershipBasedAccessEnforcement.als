// === feature_model.als — Alloy model for 005-fca-loan-applications ===
// FCA-regulated loan applications: roles, ownership-based access,
// audit log append-only, byte-equivalent not-found responses.

// ---------------------------------------------------------------------
// Sigs
// ---------------------------------------------------------------------

abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

abstract sig OperationKind {}
one sig OpPost, OpGetApp, OpPatch, OpGetAudit extends OperationKind {}

abstract sig Status {}
one sig SPending, SUnderReview, SApproved, SRejected extends Status {}

abstract sig Response {}
one sig OkResp, NotFoundResp, UnauthResp, ForbiddenResp extends Response {}

// Permission matrix as a singleton-sig field (Hard rule 7).
one sig PermMatrix {
  RoleAllowed: set Role -> OperationKind,
  RoleDenied:  set Role -> OperationKind
}

sig User {
  roles: some Role
}

sig LoanApplication {
  applicant:       one  User,
  assignedOfficer: lone User,
  status:          one  Status
}

sig AuditEntry {
  application:    one  LoanApplication,
  actor:          lone User,           // empty iff system-actor
  actorRole:      one  Role,
  prevStatus:     lone Status,         // empty only for the initial (none)->pending entry
  newStatus:      one  Status,
  reasonNonEmpty: one  Bool
}

sig Operation {
  caller:        one  User,
  kind:          one  OperationKind,
  target:        lone LoanApplication,
  authenticated: one  Bool,
  granted:       one  Bool,
  response:      one  Response
}

// ---------------------------------------------------------------------
// Non-empty universe (Hard rule 9)
// ---------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------------------------------------------------------------------
// Permission matrix (contracts/http-api.md permission table)
// ---------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.RoleAllowed =
    (RApplicant -> OpPost) +
    (RApplicant -> OpGetApp) +
    (ROfficer   -> OpGetApp) +
    (ROfficer   -> OpPatch) +
    (RAuditor   -> OpGetApp) +
    (RAuditor   -> OpGetAudit)

  PermMatrix.RoleDenied =
    (RApplicant -> OpPatch) +
    (RApplicant -> OpGetAudit) +
    (ROfficer   -> OpPost) +
    (ROfficer   -> OpGetAudit) +
    (RAuditor   -> OpPost) +
    (RAuditor   -> OpPatch)
}

// ---------------------------------------------------------------------
// Structural facts
// ---------------------------------------------------------------------

// FR-002: officer + auditor mutually exclusive; system role never on a User.
fact F_RoleMutualExclusion {
  no u: User | ROfficer in u.roles and RAuditor in u.roles
  no u: User | RSystem in u.roles
}

// data-model.md: every applicant carries the applicant role.
fact F_ApplicantHasApplicantRole {
  all a: LoanApplication | RApplicant in a.applicant.roles
}

// FR-010: assigned officer (if any) carries the officer role.
fact F_AssignedOfficerHasOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.roles
}

// FR-011: no self-assignment of officer.
fact F_NoSelfAssignment {
  all a: LoanApplication | a.assignedOfficer != a.applicant
}

// FR-008: at most one in-flight application per applicant.
fact F_OneInFlightPerApplicant {
  all u: User |
    lone a: LoanApplication |
      a.applicant = u and a.status in (SPending + SUnderReview)
}

// FR-009: only the allowed status transitions are recorded.
fact F_ValidStatusTransitions {
  all e: AuditEntry | no e.prevStatus implies e.newStatus = SPending
  all e: AuditEntry | e.prevStatus = SPending implies e.newStatus = SUnderReview
  all e: AuditEntry | e.prevStatus = SUnderReview implies e.newStatus in (SApproved + SRejected)
  all e: AuditEntry | e.prevStatus not in (SApproved + SRejected)
  all e: AuditEntry | some e.prevStatus implies e.prevStatus != e.newStatus
}

// FR-014/FR-016: every audit entry has a non-empty reason.
fact F_AuditEntryReasonRequired {
  all e: AuditEntry | e.reasonNonEmpty = True
}

// FR-016: actor / actor-role consistency (system actor iff no user attached).
fact F_AuditEntryActorConsistency {
  all e: AuditEntry | (no e.actor) iff e.actorRole = RSystem
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
}

// FR-016 / data-model.md: exactly one initial audit entry per application.
fact F_AuditInitialEntry {
  all a: LoanApplication |
    one e: AuditEntry | e.application = a and no e.prevStatus
}

// FR-018: audit log append-only — each (application, newStatus) transition
// can only be recorded once (the state machine has no self-loops).
fact F_AuditAppendOnly {
  all disj e1, e2: AuditEntry |
    e1.application = e2.application implies e1.newStatus != e2.newStatus
}

// FR-001: OAuth-bearer required; granted ops must be authenticated, and
// unauthenticated ops must produce the canonical 401 response.
fact F_AuthRequired {
  all op: Operation | op.granted = True implies op.authenticated = True
  all op: Operation | op.authenticated = False implies op.response = UnauthResp
}

// FR-003/4/5: a granted op requires the caller to hold a role that
// allows that kind in the permission matrix.
fact F_LeastPrivilegeEnforcement {
  all op: Operation | op.granted = True implies
    (some r: op.caller.roles | r -> op.kind in PermMatrix.RoleAllowed)
}

// FR-012/FR-020/FR-023: ownership / assignment must match for granted reads & writes.
fact F_OwnershipBasedAccessEnforcement {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    (some op.target and op.target.assignedOfficer = op.caller)
  all op: Operation | (op.granted = True and op.kind = OpGetApp) implies
    (some op.target and
     ((RAuditor in op.caller.roles)
      or op.target.applicant = op.caller
      or op.target.assignedOfficer = op.caller))
  all op: Operation | (op.granted = True and op.kind = OpGetAudit) implies
    RAuditor in op.caller.roles
}

// FR-013: defence-in-depth no-self-decision predicate at decision time.
fact F_NoSelfDecisionEnforcement {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    op.target.applicant != op.caller
}

// FR-015: no PATCH on an already-decided application.
fact F_NoChangesAfterDecided {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    op.target.status in (SPending + SUnderReview)
}

// FR-020/021/023: every denied authenticated read returns the canonical
// byte-equivalent not-found response.
fact F_NoInformationLeakageEnforcement {
  all op: Operation |
    (op.authenticated = True and op.granted = False and op.kind in (OpGetApp + OpGetAudit))
    implies op.response = NotFoundResp
}

// Granted operations always yield the OK response.
fact F_GrantedResponseIsOk {
  all op: Operation | op.granted = True implies op.response = OkResp
}

// =====================================================================
// Catalogue patterns
// =====================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  no op: Operation | op.granted = True and op.authenticated = False
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-003,4,5; contracts/http-api.md permission table
pred LeastPrivilege {
  all op: Operation | op.granted = True implies
    (some r: op.caller.roles | r -> op.kind in PermMatrix.RoleAllowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  all r: (RApplicant + ROfficer + RAuditor), k: OperationKind |
    (r -> k) in (PermMatrix.RoleAllowed + PermMatrix.RoleDenied)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  no disj e1, e2: AuditEntry |
    e1.application = e2.application and e1.newStatus = e2.newStatus
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016; data-model.md initial audit entry
pred AuditCompleteness {
  all a: LoanApplication |
    one e: AuditEntry | e.application = a and no e.prevStatus
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016 (actor / actor_role fields)
pred AttributionCorrectness {
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
  all e: AuditEntry | (no e.actor) iff e.actorRole = RSystem
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md user / loan_application relations
pred OwnershipExclusivity {
  all a: LoanApplication | RApplicant in a.applicant.roles
  all a: LoanApplication | some a.assignedOfficer implies ROfficer in a.assignedOfficer.roles
  all a: LoanApplication | a.assignedOfficer != a.applicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-012, FR-020
pred OwnershipBasedAccess {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    (some op.target and op.target.assignedOfficer = op.caller)
  all op: Operation | (op.granted = True and op.kind = OpGetApp) implies
    (some op.target and
     ((RAuditor in op.caller.roles)
      or op.target.applicant = op.caller
      or op.target.assignedOfficer = op.caller))
  all op: Operation | (op.granted = True and op.kind = OpGetAudit) implies
    RAuditor in op.caller.roles
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-023
pred NoInformationLeakage {
  all op: Operation |
    (op.authenticated = True and op.granted = False and op.kind in (OpGetApp + OpGetAudit))
    implies op.response = NotFoundResp
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013
pred NoSelfMutation {
  all a: LoanApplication | a.assignedOfficer != a.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// =====================================================================
// Feature-specific FR coverage
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer required
pred FR_001_AuthRequired {
  no op: Operation | op.granted = True and op.authenticated = False
  all op: Operation | op.authenticated = False implies op.response = UnauthResp
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 officer+auditor mutually exclusive
pred FR_002_RoleMutex {
  no u: User | ROfficer in u.roles and RAuditor in u.roles
}
assert FR_002_RoleMutex { FR_002_RoleMutex }
check FR_002_RoleMutex for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 applicants cannot patch / read audit
pred FR_003_ApplicantScope {
  all op: Operation |
    (op.granted = True and op.kind in (OpPatch + OpGetAudit))
    implies (some r: op.caller.roles | r != RApplicant and r -> op.kind in PermMatrix.RoleAllowed)
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 officers cannot post / read audit
pred FR_004_OfficerScope {
  all op: Operation |
    (op.granted = True and op.kind in (OpPost + OpGetAudit))
    implies (some r: op.caller.roles | r != ROfficer and r -> op.kind in PermMatrix.RoleAllowed)
}
assert FR_004_OfficerScope { FR_004_OfficerScope }
check FR_004_OfficerScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 auditors cannot post / patch
pred FR_005_AuditorScope {
  all op: Operation |
    (op.granted = True and op.kind in (OpPost + OpPatch))
    implies (some r: op.caller.roles | r != RAuditor and r -> op.kind in PermMatrix.RoleAllowed)
}
assert FR_005_AuditorScope { FR_005_AuditorScope }
check FR_005_AuditorScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 status value enumeration backstop (amount range modelled in DB CHECK, not Alloy)
pred FR_007_StatusEnum {
  Status = SPending + SUnderReview + SApproved + SRejected
}
assert FR_007_StatusEnum { FR_007_StatusEnum }
check FR_007_StatusEnum for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight application per applicant
pred FR_008_OneInFlight {
  all u: User |
    lone a: LoanApplication |
      a.applicant = u and a.status in (SPending + SUnderReview)
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 valid status transitions
pred FR_009_ValidTransitions {
  all e: AuditEntry | no e.prevStatus implies e.newStatus = SPending
  all e: AuditEntry | e.prevStatus = SPending implies e.newStatus = SUnderReview
  all e: AuditEntry | e.prevStatus = SUnderReview implies e.newStatus in (SApproved + SRejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 assigned officer carries officer role
pred FR_010_OfficerHasRole {
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.roles
}
assert FR_010_OfficerHasRole { FR_010_OfficerHasRole }
check FR_010_OfficerHasRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 no self-assignment
pred FR_011_NoSelfAssignment {
  all a: LoanApplication | a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 only assigned officer may PATCH status
pred FR_012_OnlyAssignedOfficerPatches {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    (some op.target and op.target.assignedOfficer = op.caller)
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 no self-decision
pred FR_013_NoSelfDecision {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    op.target.applicant != op.caller
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 reason required on every transition
pred FR_014_ReasonRequired {
  all e: AuditEntry | e.reasonNonEmpty = True
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 no transitions after approved/rejected
pred FR_015_NoChangesAfterDecided {
  all op: Operation | (op.granted = True and op.kind = OpPatch) implies
    op.target.status in (SPending + SUnderReview)
}
assert FR_015_NoChangesAfterDecided { FR_015_NoChangesAfterDecided }
check FR_015_NoChangesAfterDecided for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry fields well-formed
pred FR_016_AuditFields {
  all e: AuditEntry | e.reasonNonEmpty = True
  all e: AuditEntry | (no e.actor) iff e.actorRole = RSystem
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
  all e: AuditEntry | (no e.prevStatus) iff e.newStatus = SPending
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit log immutable / append-only
pred FR_018_AppendOnly {
  no disj e1, e2: AuditEntry |
    e1.application = e2.application and e1.newStatus = e2.newStatus
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020 byte-equivalent not-found for unauthorised reads
pred FR_020_ByteEquivNotFound {
  all op: Operation |
    (op.authenticated = True and op.granted = False and op.kind = OpGetApp)
    implies op.response = NotFoundResp
}
assert FR_020_ByteEquivNotFound { FR_020_ByteEquivNotFound }
check FR_020_ByteEquivNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023 audit endpoint auditor-only
pred FR_023_AuditOnlyForAuditor {
  all op: Operation | (op.granted = True and op.kind = OpGetAudit) implies
    RAuditor in op.caller.roles
  all op: Operation |
    (op.authenticated = True and op.granted = False and op.kind = OpGetAudit)
    implies op.response = NotFoundResp
}
assert FR_023_AuditOnlyForAuditor { FR_023_AuditOnlyForAuditor }
check FR_023_AuditOnlyForAuditor for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024 applicants cannot modify after submission
pred FR_024_ApplicantCannotModify {
  all op: Operation |
    (op.granted = True and op.kind = OpPatch)
    implies (some r: op.caller.roles | r != RApplicant and r -> op.kind in PermMatrix.RoleAllowed)
}
assert FR_024_ApplicantCannotModify { FR_024_ApplicantCannotModify }
check FR_024_ApplicantCannotModify for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_OwnerLeak { some op: Operation, a: LoanApplication, u: User | op.kind = OpGetApp and op.granted = True and op.target = a and op.caller = u and a.applicant != u and a.assignedOfficer != u and RAuditor not in u.roles and op.authenticated = True }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
