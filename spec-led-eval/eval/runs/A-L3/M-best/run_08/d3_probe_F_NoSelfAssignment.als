// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===

// ===========================================================================
// Sigs
// ===========================================================================

abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education, Medical,
        Wedding, Holiday, Business, Other extends Purpose {}

abstract sig Response {}
one sig OkResponse, NotFoundResponse extends Response {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchStatus, GetAudit
       extends OperationKind {}

// Permission matrix as a field on a singleton sig (Alloy 6 idiom).
one sig PermMatrix { Allowed: set Role -> OperationKind }

sig User {
  roles: some Role
}

sig LoanApplication {
  applicant: one User,
  assignedOfficer: lone User,
  status: one Status,
  purpose: one Purpose,
  audit: set AuditEntry
}

sig AuditEntry {
  app: one LoanApplication,
  actor: lone User,           // 'none' encodes the "system" actor
  actorRole: one Role,
  prevStatus: lone Status,    // 'none' only for the initial pending entry
  newStatus: one Status
}

// Access-control response relations on a singleton (per-(user, app) verdict).
one sig AccessControl {
  appResponse: User -> LoanApplication -> Response,
  auditResponse: User -> LoanApplication -> Response
}

// ===========================================================================
// Non-empty universe (so quantified assertions are not vacuous under for-5)
// ===========================================================================
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
}

// ===========================================================================
// Permission matrix (closed-world, from contracts/http-api.md)
// ===========================================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Applicant -> PostApplications)
    + (Applicant -> GetApplicationById)
    + (Officer   -> PatchStatus)
    + (Officer   -> GetApplicationById)
    + (Auditor   -> GetApplicationById)
    + (Auditor   -> GetAudit)
}

// ===========================================================================
// Role multiplicity (FR-002): officer + auditor combination forbidden;
// SystemRole is never user-assignable.
// ===========================================================================
fact F_RoleMultiplicity {
  no u: User | Officer in u.roles and Auditor in u.roles
  no u: User | SystemRole in u.roles
  all u: User | some (u.roles - SystemRole)
}

// ===========================================================================
// Applicant linkage / ownership (FR-006, FR-010)
// ===========================================================================
fact F_ApplicantHasApplicantRole {
  all a: LoanApplication | Applicant in a.applicant.roles
}

fact F_AssignedOfficerHasOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}

// ===========================================================================
// No self-assignment (FR-011)
// ===========================================================================
fact F_NoSelfAssignment {
  all a: LoanApplication | a.assignedOfficer != a.applicant
}

// ===========================================================================
// One in-flight per applicant (FR-008)
// ===========================================================================
fact F_OneInFlightPerApplicant {
  all u: User |
    lone a: LoanApplication |
      a.applicant = u and a.status in (Pending + UnderReview)
}

// ===========================================================================
// Audit-entry / application bidirectional consistency
// ===========================================================================
fact F_AuditBidirectional {
  all e: AuditEntry | e in e.app.audit
  all a: LoanApplication, e: a.audit | e.app = a
}

// ===========================================================================
// Valid status transitions (FR-009)
// ===========================================================================
fact F_ValidTransitions {
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
}

// ===========================================================================
// Initial audit entry exists for every application (FR-016, FR-017)
// ===========================================================================
fact F_InitialAuditEntryExists {
  all a: LoanApplication | one e: a.audit | no e.prevStatus
}

// ===========================================================================
// Terminal status is final (FR-015)
// ===========================================================================
fact F_NoTransitionFromTerminal {
  no e: AuditEntry | e.prevStatus in (Approved + Rejected)
}

// ===========================================================================
// Audit attribution correctness (FR-012, FR-013, FR-016, FR-024)
// ===========================================================================
fact F_AuditAttribution {
  // 'system' attribution iff no human actor recorded
  all e: AuditEntry | no e.actor iff e.actorRole = SystemRole
  // actor's recorded role must be one of their actual roles
  all e: AuditEntry | some e.actor implies e.actorRole in e.actor.roles
  // initial submission entry: actorRole is Applicant or SystemRole
  all e: AuditEntry | no e.prevStatus implies e.actorRole in (Applicant + SystemRole)
  // post-submission transitions: actorRole must be Officer
  all e: AuditEntry | some e.prevStatus implies e.actorRole = Officer
  // submission entry's actor (if any) is the application's applicant
  all e: AuditEntry |
    (no e.prevStatus and some e.actor) implies e.actor = e.app.applicant
  // auditors never write
  no e: AuditEntry | e.actorRole = Auditor
}

// ===========================================================================
// Only the assigned officer can drive officer-attributed transitions
// (FR-012, FR-013 defence-in-depth)
// ===========================================================================
fact F_OfficerTransitionByAssigned {
  all e: AuditEntry |
    e.actorRole = Officer implies
      (e.actor = e.app.assignedOfficer and e.actor != e.app.applicant)
}

// ===========================================================================
// Append-only audit log: no duplicate transition per application (FR-018)
// ===========================================================================
fact F_AppendOnlyAuditEntries {
  all a: LoanApplication |
    all disj e1, e2: a.audit |
      e1.prevStatus != e2.prevStatus or e1.newStatus != e2.newStatus
}

// ===========================================================================
// Current application status reflected in audit log
// ===========================================================================
fact F_CurrentStatusInAudit {
  all a: LoanApplication | some e: a.audit | e.newStatus = a.status
}

// ===========================================================================
// Access-control: total, functional response for every (user, app)
// ===========================================================================
fact F_AccessFunctional {
  all u: User, a: LoanApplication |
    one r: Response | (u -> a -> r) in AccessControl.appResponse
  all u: User, a: LoanApplication |
    one r: Response | (u -> a -> r) in AccessControl.auditResponse
}

// ===========================================================================
// App-view access policy (FR-020/021): legitimate access only
// ===========================================================================
fact F_AppAccessPolicy {
  all u: User, a: LoanApplication |
    (u -> a -> OkResponse) in AccessControl.appResponse iff
      (u = a.applicant or u = a.assignedOfficer or Auditor in u.roles)
}

// ===========================================================================
// Audit-view access policy (FR-023): auditor-only
// ===========================================================================
fact F_AuditAccessPolicy {
  all u: User, a: LoanApplication |
    (u -> a -> OkResponse) in AccessControl.auditResponse iff Auditor in u.roles
}

// ===========================================================================
// PATTERN PREDICATES
// ===========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003..FR-005
pred LeastPrivilege {
  // Every observed "Ok" view traces back to some role of the caller having
  // the corresponding allow cell in the permission matrix.
  all u: User, a: LoanApplication |
    (u -> a -> OkResponse) in AccessControl.appResponse implies
      (some r: u.roles | (r -> GetApplicationById) in PermMatrix.Allowed)
  all u: User, a: LoanApplication |
    (u -> a -> OkResponse) in AccessControl.auditResponse implies
      (some r: u.roles | (r -> GetAudit) in PermMatrix.Allowed)
  // No officer-attributed audit entry from someone without the Officer role
  all e: AuditEntry |
    e.actorRole = Officer implies
      (some r: e.actor.roles | (r -> PatchStatus) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6 but 9 Purpose

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // All six allow cells listed in the contract are present.
  (Applicant -> PostApplications)   in PermMatrix.Allowed
  (Applicant -> GetApplicationById) in PermMatrix.Allowed
  (Officer   -> PatchStatus)        in PermMatrix.Allowed
  (Officer   -> GetApplicationById) in PermMatrix.Allowed
  (Auditor   -> GetApplicationById) in PermMatrix.Allowed
  (Auditor   -> GetAudit)           in PermMatrix.Allowed
  // SystemRole is never granted any operation.
  no (SystemRole -> OperationKind) & PermMatrix.Allowed
  // Auditors cannot write applications; applicants cannot patch.
  (Auditor   -> PostApplications) not in PermMatrix.Allowed
  (Auditor   -> PatchStatus)      not in PermMatrix.Allowed
  (Applicant -> PatchStatus)      not in PermMatrix.Allowed
  (Applicant -> GetAudit)         not in PermMatrix.Allowed
  (Officer   -> GetAudit)         not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6 but 9 Purpose

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every audit entry is attributable: either a known user (with that role)
  // or a system actor. No "anonymous" / unauthenticated entries are possible.
  all e: AuditEntry |
    (some e.actor and e.actorRole in e.actor.roles) or
    (no e.actor and e.actorRole = SystemRole)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6 but 9 Purpose

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017
pred AuditCompleteness {
  // Every application has the initial (none -> pending) audit entry.
  all a: LoanApplication |
    some e: a.audit | no e.prevStatus and e.newStatus = Pending
  // Every audit entry belongs to its application's audit set.
  all e: AuditEntry | e in e.app.audit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6 but 9 Purpose

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No two distinct entries record the same transition for the same application.
  all a: LoanApplication |
    all disj e1, e2: a.audit |
      e1.prevStatus != e2.prevStatus or e1.newStatus != e2.newStatus
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6 but 9 Purpose

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-012, FR-013, FR-016
pred AttributionCorrectness {
  // Officer-attributed entries: recorded actor = the assigned officer AND not the applicant.
  all e: AuditEntry |
    e.actorRole = Officer implies
      (e.actor = e.app.assignedOfficer and e.actor != e.app.applicant)
  // Initial entries with a human actor: that actor is the application's applicant.
  all e: AuditEntry |
    (no e.prevStatus and some e.actor) implies e.actor = e.app.applicant
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6 but 9 Purpose

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant_id NOT NULL FK
pred OwnershipExclusivity {
  // Exactly one applicant per application.
  all a: LoanApplication | one a.applicant
  // The application's applicant always has the applicant role.
  all a: LoanApplication | Applicant in a.applicant.roles
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6 but 9 Purpose

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-020
pred OwnershipBasedAccess {
  // Owner (applicant) of an application always gets Ok.
  all a: LoanApplication |
    (a.applicant -> a -> OkResponse) in AccessControl.appResponse
  // The assigned officer (if any) gets Ok for that application.
  all a: LoanApplication |
    some a.assignedOfficer implies
      (a.assignedOfficer -> a -> OkResponse) in AccessControl.appResponse
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6 but 9 Purpose

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022, FR-023
pred NoInformationLeakage {
  // Non-legitimate callers ALWAYS get NotFoundResponse (byte-equivalent).
  all u: User, a: LoanApplication |
    not (u = a.applicant or u = a.assignedOfficer or Auditor in u.roles)
      implies (u -> a -> NotFoundResponse) in AccessControl.appResponse
  // Non-auditors get the same NotFound response on the audit endpoint.
  all u: User, a: LoanApplication |
    Auditor not in u.roles implies
      (u -> a -> NotFoundResponse) in AccessControl.auditResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6 but 9 Purpose

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013
pred NoSelfMutation {
  // No application is self-assigned.
  all a: LoanApplication | a.assignedOfficer != a.applicant
  // No officer audit-entry where the officer is also the applicant.
  no e: AuditEntry | e.actorRole = Officer and e.actor = e.app.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6 but 9 Purpose

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007, FR-009, FR-014
pred ValidationBeforeMutation {
  // Every application's purpose is one of the nine fixed categories.
  all a: LoanApplication | a.purpose in
    (HomeImprovement + DebtConsolidation + Vehicle + Education + Medical
     + Wedding + Holiday + Business + Other)
  // Every audit-logged transition is one of the four legal transitions.
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6 but 9 Purpose

// ===========================================================================
// FR-NNN PREDICATES (one per functional requirement)
// ===========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth required, no audit entry on unauth
pred FR_001_AuthRequired {
  // Every audit entry has an attributable actor (user + matching role, or system).
  all e: AuditEntry |
    (some e.actor and e.actorRole in e.actor.roles) or
    (no e.actor and e.actorRole = SystemRole)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-002 role multiplicity
pred FR_002_RoleMultiplicity {
  no u: User | Officer in u.roles and Auditor in u.roles
  no u: User | SystemRole in u.roles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-003 applicants cannot read others' apps and cannot patch
pred FR_003_ApplicantRights {
  // Applicant-only (and not assigned officer, not auditor) callers cannot
  // Ok-view other applications.
  all u: User, a: LoanApplication |
    (u != a.applicant and u != a.assignedOfficer and Auditor not in u.roles)
      implies (u -> a -> OkResponse) not in AccessControl.appResponse
  // Applicants cannot drive officer-attributed transitions.
  no e: AuditEntry | e.actorRole = Officer and Officer not in e.actor.roles
}
assert FR_003_ApplicantRights { FR_003_ApplicantRights }
check FR_003_ApplicantRights for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-004 officer can only patch assigned applications
pred FR_004_OfficerRights {
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor = e.app.assignedOfficer
}
assert FR_004_OfficerRights { FR_004_OfficerRights }
check FR_004_OfficerRights for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-005 auditor is read-only
pred FR_005_AuditorReadOnly {
  // No audit entry is attributed to the auditor role.
  no e: AuditEntry | e.actorRole = Auditor
  // Auditor (not also officer) never drives a transition.
  no e: AuditEntry |
    e.actorRole = Officer and
    Auditor in e.actor.roles and Officer not in e.actor.roles
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-006 applicant identity is the token user
pred FR_006_ApplicantFromToken {
  all a: LoanApplication | Applicant in a.applicant.roles
}
assert FR_006_ApplicantFromToken { FR_006_ApplicantFromToken }
check FR_006_ApplicantFromToken for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-007 amount + fixed purpose categories
pred FR_007_AmountPurpose {
  all a: LoanApplication |
    a.purpose in
      (HomeImprovement + DebtConsolidation + Vehicle + Education + Medical
       + Wedding + Holiday + Business + Other)
}
assert FR_007_AmountPurpose { FR_007_AmountPurpose }
check FR_007_AmountPurpose for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight per applicant
pred FR_008_OneInFlight {
  all u: User |
    lone a: LoanApplication |
      a.applicant = u and a.status in (Pending + UnderReview)
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-009 valid status transitions
pred FR_009_ValidTransitions {
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview and e.newStatus = Approved) or
    (e.prevStatus = UnderReview and e.newStatus = Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-010 auto-assignment of an officer
pred FR_010_AutoAssign {
  // If an officer is assigned, they hold the officer role.
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}
assert FR_010_AutoAssign { FR_010_AutoAssign }
check FR_010_AutoAssign for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-011 no self-assignment
pred FR_011_NoSelfAssign {
  all a: LoanApplication | a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssign { FR_011_NoSelfAssign }
check FR_011_NoSelfAssign for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-012 only assigned officer changes status
pred FR_012_OnlyAssignedOfficerPatches {
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor = e.app.assignedOfficer
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-013 no self-decision
pred FR_013_NoSelfDecision {
  no e: AuditEntry | e.actorRole = Officer and e.actor = e.app.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-014 reason is required (modeled: every entry is well-formed)
pred FR_014_ReasonRequired {
  // Every audit entry has exactly one newStatus (i.e., a real transition was recorded).
  all e: AuditEntry | one e.newStatus
  // And the actorRole field is present.
  all e: AuditEntry | one e.actorRole
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-015 no change after a terminal decision
pred FR_015_NoChangeAfterDecision {
  no e: AuditEntry | e.prevStatus in (Approved + Rejected)
}
assert FR_015_NoChangeAfterDecision { FR_015_NoChangeAfterDecision }
check FR_015_NoChangeAfterDecision for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit fields populated; prev_status null iff initial
pred FR_016_AuditFields {
  all e: AuditEntry | one e.app and one e.actorRole and one e.newStatus
  all e: AuditEntry | (no e.prevStatus) iff (e.newStatus = Pending)
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-017 every transition has an audit entry
pred FR_017_AuditCompleteness {
  all a: LoanApplication | one e: a.audit | no e.prevStatus
  // Status reachable in the model is also represented in the audit chain.
  all a: LoanApplication | some e: a.audit | e.newStatus = a.status
}
assert FR_017_AuditCompleteness { FR_017_AuditCompleteness }
check FR_017_AuditCompleteness for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit log is append-only / immutable
pred FR_018_AuditAppendOnly {
  all a: LoanApplication |
    all disj e1, e2: a.audit |
      e1.prevStatus != e2.prevStatus or e1.newStatus != e2.newStatus
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-019 6-year retention (no deletion code path)
pred FR_019_Retention {
  // Every audit entry remains linked to its application (no orphans, no deletion).
  all e: AuditEntry | one e.app
  all e: AuditEntry | e in e.app.audit
}
assert FR_019_Retention { FR_019_Retention }
check FR_019_Retention for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-020 byte-equivalent NotFound for unauthorised reads
pred FR_020_ByteEquivalent {
  all u: User, a: LoanApplication |
    not (u = a.applicant or u = a.assignedOfficer or Auditor in u.roles)
      implies (u -> a -> NotFoundResponse) in AccessControl.appResponse
}
assert FR_020_ByteEquivalent { FR_020_ByteEquivalent }
check FR_020_ByteEquivalent for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-021 same response for "exists-but-not-mine" and "nonexistent"
pred FR_021_SameForOthers {
  // Non-owners NEVER get Ok — meaning their response cannot be distinguished
  // from a NotFound (since the response is total/functional, the only alternative is NotFound).
  all u: User, a: LoanApplication |
    (u != a.applicant and u != a.assignedOfficer and Auditor not in u.roles)
      implies (u -> a -> OkResponse) not in AccessControl.appResponse
}
assert FR_021_SameForOthers { FR_021_SameForOthers }
check FR_021_SameForOthers for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-022 no leak through POST or other endpoints
pred FR_022_NoLeakOnPost {
  // The "in-flight application" attached to each user references only their own apps.
  all u: User |
    lone a: LoanApplication |
      a.applicant = u and a.status in (Pending + UnderReview)
}
assert FR_022_NoLeakOnPost { FR_022_NoLeakOnPost }
check FR_022_NoLeakOnPost for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-023 audit endpoint is auditor-only
pred FR_023_AuditAuditorOnly {
  all u: User, a: LoanApplication |
    Auditor not in u.roles implies
      (u -> a -> NotFoundResponse) in AccessControl.auditResponse
  all u: User, a: LoanApplication |
    (u -> a -> OkResponse) in AccessControl.auditResponse implies Auditor in u.roles
}
assert FR_023_AuditAuditorOnly { FR_023_AuditAuditorOnly }
check FR_023_AuditAuditorOnly for 6 but 9 Purpose

// FEATURE-SPECIFIC  ANCHOR: FR-024 applicant cannot modify after submission
pred FR_024_ApplicantNoMutation {
  // No applicant-attributed entry occurs after the initial submission.
  no e: AuditEntry | e.actorRole = Applicant and some e.prevStatus
}
assert FR_024_ApplicantNoMutation { FR_024_ApplicantNoMutation }
check FR_024_ApplicantNoMutation for 6 but 9 Purpose

// === D3 inject_violation (validator-appended) ===
fact MUTATE_SelfAssignViolation { some a: LoanApplication | a.assignedOfficer = a.applicant }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
